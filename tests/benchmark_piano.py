"""Automated multi-configuration piano transcription benchmark.

Loads isolated piano note recordings (Godot calibration .pcm files, .wav files,
a JSON manifest, or built-in synthetic fallback notes), mixes them into controlled
musical configurations (single notes, soft/loud octaves, staggered octaves,
intervals, triads, 4-note chords, repeated strikes), and evaluates:
  - Live GDScript β-NMF + NoteConfirmation (via headless Godot)
  - Attack/Decay NMF (chord/attack_decay/model.py)

Reports Onset Precision, Recall, F1, Exact-Case Accuracy, Frame F1 (live),
Octave False-Positive Rate, and Mean/P95 Latency.
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import subprocess
import sys
import tempfile
import time
import wave
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from chord.attack_decay import model as ad_model
from run_all_tests import find_godot

SAMPLE_RATE = 44100
NOTE_RE = re.compile(r"^([A-Ga-g])([#♯sb♭]?)(-?\d+)$")
SEMITONES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


@dataclass
class RecordedNote:
    midi: int
    audio: np.ndarray  # mono float32 at SAMPLE_RATE, RMS-normalized at attack
    onset_sample: int


@dataclass
class ExpectedOnset:
    midi: int
    onset_ms: float
    gain: float


@dataclass
class TestCase:
    case_id: str
    category: str
    label: str
    audio: np.ndarray
    expected: list[ExpectedOnset]
    eval_start_ms: float
    eval_end_ms: float


def midi_to_name(midi: int) -> str:
    return f"{NAMES[midi % 12]}{midi // 12 - 1}"


def parse_midi_from_stem(stem: str) -> int | None:
    if stem.isdigit():
        val = int(stem)
        return val if 21 <= val <= 108 else None
    m = NOTE_RE.match(stem.strip())
    if not m:
        return None
    letter, accidental, octave = m.group(1).upper(), m.group(2), int(m.group(3))
    semi = SEMITONES[letter]
    if accidental in ("#", "♯", "s"):
        semi += 1
    elif accidental in ("b", "♭"):
        semi -= 1
    midi = (octave + 1) * 12 + semi
    return midi if 21 <= midi <= 108 else None


def detect_onset(audio: np.ndarray, rate: int) -> int:
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak <= 1e-8:
        return 0
    hits = np.flatnonzero(np.abs(audio) > 0.015 * peak)
    return int(hits[0]) if hits.size else 0


def normalize_note(audio: np.ndarray, rate: int, onset: int) -> RecordedNote | tuple[np.ndarray, int]:
    if rate != SAMPLE_RATE:
        audio = ad_model._resample(audio.astype(np.float32), rate)
        onset = round(onset * SAMPLE_RATE / rate)
    audio = audio.astype(np.float32, copy=False)
    attack = audio[onset:onset + round(0.25 * SAMPLE_RATE)]
    rms = float(np.sqrt(np.mean(attack ** 2))) if attack.size else 0.0
    if rms > 1e-8:
        audio = audio * (0.20 / rms)
    return audio, onset


def load_wav_mono(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as wf:
        rate = wf.getframerate()
        width = wf.getsampwidth()
        channels = wf.getnchannels()
        raw = wf.readframes(wf.getnframes())
    if width == 2:
        data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    elif width == 4:
        data = np.frombuffer(raw, dtype="<i4").astype(np.float32) / 2147483648.0
    else:
        raise ValueError(f"Unsupported WAV sample width ({width} bytes) in {path}")
    return data.reshape(-1, channels).mean(axis=1), rate


def load_recorded_notes(source: Path | None) -> dict[int, RecordedNote]:
    if source is None:
        return synthesize_fallback_notes()

    notes: dict[int, RecordedNote] = {}
    if source.is_file() and source.suffix.lower() == ".json":
        manifest = json.loads(source.read_text(encoding="utf-8"))
        for entry in manifest:
            midi = int(entry["midi"])
            audio, rate = load_wav_mono(source.parent / entry["wav"])
            if "offset" in entry:
                audio = audio[:round(rate * float(entry["offset"]))]
            onset = round(rate * float(entry["onset"]))
            norm_audio, norm_onset = normalize_note(audio, rate, onset)
            notes[midi] = RecordedNote(midi=midi, audio=norm_audio, onset_sample=norm_onset)
        return notes

    if not source.is_dir():
        raise FileNotFoundError(f"Notes path not found: {source}")

    # Load Godot KeyCalibration .pcm files (<II rate, onset + stereo float32)
    for pcm_file in sorted(source.glob("*.pcm")):
        midi = parse_midi_from_stem(pcm_file.stem)
        if midi is None:
            continue
        with pcm_file.open("rb") as fh:
            rate, onset = struct.unpack("<II", fh.read(8))
            stereo = np.fromfile(fh, dtype="<f4").reshape(-1, 2)
        mono = stereo.mean(axis=1)
        norm_audio, norm_onset = normalize_note(mono, rate, onset)
        notes[midi] = RecordedNote(midi=midi, audio=norm_audio, onset_sample=norm_onset)

    # Load .wav files (named like 60.wav or C4.wav)
    for wav_file in sorted(source.glob("*.wav")):
        midi = parse_midi_from_stem(wav_file.stem)
        if midi is None or midi in notes:
            continue
        mono, rate = load_wav_mono(wav_file)
        onset = detect_onset(mono, rate)
        norm_audio, norm_onset = normalize_note(mono, rate, onset)
        notes[midi] = RecordedNote(midi=midi, audio=norm_audio, onset_sample=norm_onset)

    if not notes:
        raise ValueError(f"No valid .pcm or .wav piano notes found in {source}")
    return notes


def synthesize_fallback_notes() -> dict[int, RecordedNote]:
    """Generate realistic inharmonic piano-like notes when no user recordings are provided."""
    notes: dict[int, RecordedNote] = {}
    lead = round(0.20 * SAMPLE_RATE)
    duration = round(1.50 * SAMPLE_RATE)
    t = np.arange(duration, dtype=np.float32) / SAMPLE_RATE
    rng = np.random.default_rng(7)
    for midi in [21, 22, 48, 55, 60, 63, 64, 67, 71, 72, 76, 79, 84, 108]:
        f0 = 440.0 * (2.0 ** ((midi - 69) / 12.0))
        inharm = 0.00015 * (2.0 ** ((midi - 60) / 24.0))
        base_decay = 1.6 * (2.0 ** ((midi - 60) / 30.0))
        wave_out = np.zeros_like(t)
        for n in range(1, 10):
            fn = n * f0 * np.sqrt(1.0 + inharm * n * n)
            if fn >= SAMPLE_RATE * 0.45:
                break
            amp = (1.0 / (n ** 1.15)) * (1.0 + 0.15 * (n % 2 == 0))
            env = np.minimum(1.0, t / 0.004) * np.exp(-(base_decay * (1.0 + 0.25 * (n - 1))) * t)
            wave_out += amp * env * np.sin(2.0 * np.pi * fn * t + rng.uniform(0, 2 * np.pi))
        # Subtle hammer thud at onset
        hammer = rng.normal(0, 0.06, size=duration).astype(np.float32) * np.exp(-t / 0.008)
        full = np.concatenate([np.zeros(lead, dtype=np.float32), wave_out + hammer])
        norm_audio, norm_onset = normalize_note(full, SAMPLE_RATE, lead)
        notes[midi] = RecordedNote(midi=midi, audio=norm_audio, onset_sample=norm_onset)
    return notes


def mix_case(
    case_id: str,
    category: str,
    label: str,
    notes: dict[int, RecordedNote],
    events: list[tuple[int, float, float]],
    lead_ms: float = 250.0,
    tail_ms: float = 800.0,
) -> TestCase:
    """Mix isolated notes at specified (midi, onset_offset_ms, relative_gain)."""
    max_onset_ms = max(onset for _, onset, _ in events)
    total_ms = lead_ms + max_onset_ms + tail_ms
    total_samples = round(total_ms * SAMPLE_RATE / 1000.0)
    mix = np.zeros(total_samples, dtype=np.float32)
    expected: list[ExpectedOnset] = []

    for midi, offset_ms, gain in events:
        rec = notes[midi]
        target_onset = round((lead_ms + offset_ms) * SAMPLE_RATE / 1000.0)
        clip_start = max(0, rec.onset_sample - round(0.02 * SAMPLE_RATE))
        clip = rec.audio[clip_start:]
        onset_in_clip = rec.onset_sample - clip_start
        dst_start = target_onset - onset_in_clip
        src_start = 0
        if dst_start < 0:
            src_start = -dst_start
            dst_start = 0
        length = min(len(clip) - src_start, total_samples - dst_start)
        if length > 0:
            segment = clip[src_start:src_start + length].copy()
            fade = min(length, round(0.025 * SAMPLE_RATE))
            if fade > 0:
                segment[-fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)
            mix[dst_start:dst_start + length] += gain * segment
        expected.append(ExpectedOnset(midi=midi, onset_ms=lead_ms + offset_ms, gain=gain))

    peak = float(np.max(np.abs(mix)))
    if peak > 0.92:
        mix *= 0.92 / peak
    return TestCase(
        case_id=case_id,
        category=category,
        label=label,
        audio=mix,
        expected=sorted(expected, key=lambda e: (e.onset_ms, e.midi)),
        eval_start_ms=lead_ms,
        eval_end_ms=lead_ms + max_onset_ms + 500.0,
    )


def build_configurations(notes: dict[int, RecordedNote]) -> list[TestCase]:
    available = sorted(notes.keys())
    avail_set = set(available)
    cases: list[TestCase] = []

    def add(cat: str, label: str, evs: list[tuple[int, float, float]]) -> None:
        cases.append(mix_case(f"{cat}_{len(cases):02d}", cat, label, notes, evs))

    # 1. Single notes (firm & soft) - sample up to 8 representative keys across range
    stride = max(1, len(available) // 8)
    sample_keys = available[::stride][:8]
    for k in sample_keys:
        add("single_firm", f"{midi_to_name(k)} firm", [(k, 0.0, 1.0)])
        add("single_soft", f"{midi_to_name(k)} soft", [(k, 0.0, 0.35)])

    # 2. Octaves (simultaneous equal, loud+soft, staggered over ringing root)
    octaves = [(k, k + 12) for k in available if (k + 12) in avail_set]
    for lo, hi in octaves[:6]:
        add("octave_equal", f"{midi_to_name(lo)}+{midi_to_name(hi)} equal", [(lo, 0.0, 1.0), (hi, 0.0, 0.9)])
        add("octave_loud_soft", f"{midi_to_name(lo)} loud + {midi_to_name(hi)} soft", [(lo, 0.0, 1.0), (hi, 0.0, 0.40)])
        add("octave_staggered", f"{midi_to_name(lo)} ringing + {midi_to_name(hi)} at +300ms", [(lo, 0.0, 1.0), (hi, 300.0, 0.55)])

    # 3. Intervals (fifths & adjacent semitones)
    fifths = [(k, k + 7) for k in available if (k + 7) in avail_set]
    for lo, hi in fifths[:4]:
        add("interval_fifth", f"{midi_to_name(lo)}+{midi_to_name(hi)}", [(lo, 0.0, 1.0), (hi, 0.0, 0.85)])

    semitones = [(k, k + 1) for k in available if (k + 1) in avail_set]
    for lo, hi in semitones[:3]:
        add("interval_semitone", f"{midi_to_name(lo)}+{midi_to_name(hi)}", [(lo, 0.0, 1.0), (hi, 0.0, 0.85)])

    # 4. Triads (major, minor, soft inner voice)
    maj_triads = [(k, k + 4, k + 7) for k in available if (k + 4) in avail_set and (k + 7) in avail_set]
    for r, t3, f5 in maj_triads[:3]:
        add("triad_major", f"{midi_to_name(r)}+{midi_to_name(t3)}+{midi_to_name(f5)}",
            [(r, 0.0, 1.0), (t3, 0.0, 0.85), (f5, 0.0, 0.85)])
        add("triad_soft_inner", f"{midi_to_name(r)} + soft {midi_to_name(t3)} + {midi_to_name(f5)}",
            [(r, 0.0, 1.0), (t3, 0.0, 0.45), (f5, 0.0, 0.85)])

    min_triads = [(k, k + 3, k + 7) for k in available if (k + 3) in avail_set and (k + 7) in avail_set]
    for r, t3, f5 in min_triads[:3]:
        add("triad_minor", f"{midi_to_name(r)}+{midi_to_name(t3)}+{midi_to_name(f5)}",
            [(r, 0.0, 1.0), (t3, 0.0, 0.85), (f5, 0.0, 0.85)])

    # 5. 4-note chords
    chords4 = [(k, k + 4, k + 7, k + 12) for k in available
               if (k + 4) in avail_set and (k + 7) in avail_set and (k + 12) in avail_set]
    for r, t3, f5, oct8 in chords4[:3]:
        add("chord_4note", f"{midi_to_name(r)}+{midi_to_name(t3)}+{midi_to_name(f5)}+{midi_to_name(oct8)}",
            [(r, 0.0, 1.0), (t3, 0.0, 0.80), (f5, 0.0, 0.80), (oct8, 0.0, 0.70)])

    # 6. Repeated strikes on the same ringing key
    for k in sample_keys[:4]:
        add("repeated_strike", f"{midi_to_name(k)} repeated (+350ms)", [(k, 0.0, 1.0), (k, 350.0, 0.95)])

    return cases


def match_onsets(
    expected: list[ExpectedOnset],
    predicted: list[dict],
    tolerance_ms: float,
) -> dict:
    """1-to-1 greedy pitch+time onset matching within tolerance_ms."""
    used_pred: set[int] = set()
    tp = 0
    latencies: list[float] = []
    abs_errors: list[float] = []

    for exp in expected:
        best_idx = -1
        best_err = tolerance_ms + 1.0
        for i, pred in enumerate(predicted):
            if i in used_pred or int(pred["midi"]) != exp.midi:
                continue
            err = abs(float(pred["onset_ms"]) - exp.onset_ms)
            if err <= tolerance_ms and err < best_err:
                best_err = err
                best_idx = i
        if best_idx >= 0:
            used_pred.add(best_idx)
            tp += 1
            pred = predicted[best_idx]
            abs_errors.append(best_err)
            # Detection latency is when the algorithm actually emitted the decision (if available), else onset error
            decided_at = float(pred.get("detected_at_ms", pred["onset_ms"]))
            latencies.append(decided_at - exp.onset_ms)

    fn = len(expected) - tp
    fp_events = [pred for i, pred in enumerate(predicted) if i not in used_pred]
    fp = len(fp_events)
    expected_midis = {e.midi for e in expected}
    octave_fps = sum(
        1 for pred in fp_events
        if (int(pred["midi"]) - 12) in expected_midis or (int(pred["midi"]) + 12) in expected_midis
    )
    return {
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "exact": int(fp == 0 and fn == 0),
        "octave_fp": octave_fps,
        "latencies_ms": latencies,
        "abs_errors_ms": abs_errors,
    }


def summarize_metrics(case_results: list[dict]) -> dict:
    by_cat: dict[str, list[dict]] = defaultdict(list)
    for r in case_results:
        by_cat[r["category"]].append(r)

    def agg(items: list[dict]) -> dict:
        tp = sum(x["tp"] for x in items)
        fp = sum(x["fp"] for x in items)
        fn = sum(x["fn"] for x in items)
        exact = sum(x["exact"] for x in items)
        oct_fp = sum(x["octave_fp"] for x in items)
        lats = [v for x in items for v in x["latencies_ms"]]
        prec = tp / (tp + fp) if (tp + fp) > 0 else 0.0
        rec = tp / (tp + fn) if (tp + fn) > 0 else 0.0
        f1 = 2 * prec * rec / (prec + rec) if (prec + rec) > 0 else 0.0
        acc = exact / len(items) if items else 0.0
        return {
            "cases": len(items),
            "tp": tp,
            "fp": fp,
            "fn": fn,
            "accuracy": acc,
            "precision": prec,
            "recall": rec,
            "f1": f1,
            "octave_fp": oct_fp,
            "mean_latency_ms": float(np.mean(lats)) if lats else None,
            "p95_latency_ms": float(np.percentile(lats, 95)) if lats else None,
            "mean_compute_ms": float(np.mean([x["compute_ms"] for x in items])) if items else 0.0,
        }

    return {
        "overall": agg(case_results),
        "by_category": {cat: agg(items) for cat, items in sorted(by_cat.items())},
        "cases": case_results,
    }


def run_live_detector(
    cases: list[TestCase],
    notes: dict[int, RecordedNote],
    godot_bin: str,
    beta: float,
    taper: int,
    attack_ms: float,
    spectral_ms: float,
    use_personal_templates: bool,
    tolerance_ms: float,
) -> dict:
    with tempfile.TemporaryDirectory(prefix="piano_bench_") as tmp:
        tmp_dir = Path(tmp)
        personal_spec = {}
        if use_personal_templates:
            for midi, rec in notes.items():
                p = tmp_dir / f"tpl_{midi}.f32"
                rec.audio.astype("<f4").tofile(p)
                personal_spec[str(midi)] = {
                    "pcm_path": str(p),
                    "rate": SAMPLE_RATE,
                    "onset_sample": rec.onset_sample,
                }
        case_specs = []
        for c in cases:
            p = tmp_dir / f"{c.case_id}.f32"
            c.audio.astype("<f4").tofile(p)
            case_specs.append({"id": c.case_id, "pcm_path": str(p), "rate": SAMPLE_RATE})

        job_path = tmp_dir / "job.json"
        out_path = tmp_dir / "out.json"
        job_path.write_text(json.dumps({
            "beta": beta,
            "taper": taper,
            "a4_hz": 440.0,
            "attack_ms": attack_ms,
            "spectral_ms": spectral_ms,
            "personal_templates": personal_spec,
            "cases": case_specs,
        }), encoding="utf-8")

        proc = subprocess.run(
            [godot_bin, "--headless", "--audio-driver", "Dummy", "--path", str(ROOT),
             "--script", "res://tests/benchmark_live_detector.gd", "--", str(job_path), str(out_path)],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0 or not out_path.exists():
            raise RuntimeError(f"Godot benchmark runner failed (rc={proc.returncode}):\n{proc.stdout}\n{proc.stderr}")
        raw = json.loads(out_path.read_text(encoding="utf-8"))

    by_id = {item["id"]: item for item in raw["results"]}
    evaluated = []
    for c in cases:
        res = by_id[c.case_id]
        m = match_onsets(c.expected, res["onsets"], tolerance_ms)
        evaluated.append({
            "id": c.case_id,
            "category": c.category,
            "label": c.label,
            "compute_ms": res["mean_analysis_ms"],
            **m,
        })
    return summarize_metrics(evaluated)


def run_attack_decay_detector(
    cases: list[TestCase],
    bank: ad_model.Bank,
    attack_ms: float,
    spectral_ms: float,
    tolerance_ms: float,
) -> dict:
    evaluated = []
    for c in cases:
        t0 = time.perf_counter()
        events = ad_model.analyze_microphone(c.audio, SAMPLE_RATE, bank, attack_ms=attack_ms, spectral_ms=spectral_ms)
        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        predicted = [{"midi": e["midi"], "onset_ms": e["onset"] * 1000.0, "strength": e["strength"]} for e in events]
        m = match_onsets(c.expected, predicted, tolerance_ms)
        evaluated.append({
            "id": c.case_id,
            "category": c.category,
            "label": c.label,
            "compute_ms": elapsed_ms,
            **m,
        })
    return summarize_metrics(evaluated)


def print_table(title: str, summary: dict) -> None:
    print(f"\n=== {title} ===")
    header = f"{'Category':<20} {'Cases':>5} {'Acc':>7} {'Prec':>7} {'Rec':>7} {'F1':>7} {'OctFP':>6} {'Lat(ms)':>9} {'Comp(ms)':>9}"
    print(header)
    print("-" * len(header))
    for cat, m in summary["by_category"].items():
        lat = f"{m['mean_latency_ms']:.1f}" if m["mean_latency_ms"] is not None else "—"
        print(
            f"{cat:<20} {m['cases']:>5} {m['accuracy']*100:>6.1f}% {m['precision']*100:>6.1f}% "
            f"{m['recall']*100:>6.1f}% {m['f1']*100:>6.1f}% {m['octave_fp']:>6} {lat:>9} {m['mean_compute_ms']:>9.2f}"
        )
    print("-" * len(header))
    o = summary["overall"]
    lat = f"{o['mean_latency_ms']:.1f}" if o["mean_latency_ms"] is not None else "—"
    print(
        f"{'OVERALL':<20} {o['cases']:>5} {o['accuracy']*100:>6.1f}% {o['precision']*100:>6.1f}% "
        f"{o['recall']*100:>6.1f}% {o['f1']*100:>6.1f}% {o['octave_fp']:>6} {lat:>9} {o['mean_compute_ms']:>9.2f}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes", type=Path, default=None,
                        help="Directory of .pcm/.wav isolated piano notes, or JSON manifest. Omit for synthetic fallback.")
    parser.add_argument("--detector", choices=("live", "attack_decay", "both"), default="both")
    parser.add_argument("--godot", help="Path to Godot console executable")
    parser.add_argument("--beta", type=float, default=0.5, help="Live β-NMF divergence parameter")
    parser.add_argument("--taper", type=int, default=0, choices=(0, 1, 2, 3),
                        help="Live window taper: 0=Hann, 1=Hamming, 2=Blackman, 3=Kaiser4")
    parser.add_argument("--attack-ms", type=float, default=20.0)
    parser.add_argument("--spectral-ms", type=float, default=40.0)
    parser.add_argument("--tolerance-ms", type=float, default=100.0,
                        help="Onset matching tolerance in milliseconds")
    parser.add_argument("--use-personal-templates", action="store_true",
                        help="Build live personal templates from the supplied notes")
    parser.add_argument("--bank", type=Path, default=ROOT / "chord" / "attack_decay" / "salamander.npz",
                        help="Attack/decay .npz bank to evaluate")
    parser.add_argument("--train-bank", action="store_true",
                        help="Train an attack/decay bank on the supplied notes before benchmarking")
    parser.add_argument("--output", type=Path, default=None, help="Optional JSON report path")
    args = parser.parse_args()

    notes = load_recorded_notes(args.notes)
    cases = build_configurations(notes)
    src_desc = str(args.notes) if args.notes else "built-in synthetic piano notes"
    print(f"Loaded {len(notes)} notes from {src_desc}; generated {len(cases)} benchmark cases.")

    report: dict = {
        "source": src_desc,
        "midi_notes": sorted(notes.keys()),
        "case_count": len(cases),
        "tolerance_ms": args.tolerance_ms,
        "detectors": {},
    }

    if args.detector in ("live", "both"):
        godot = find_godot(args.godot)
        if not godot:
            print("ERROR: Could not find Godot executable for live detector benchmark.", file=sys.stderr)
            return 1
        live_summary = run_live_detector(
            cases, notes, godot, args.beta, args.taper, args.attack_ms,
            args.spectral_ms, args.use_personal_templates, args.tolerance_ms,
        )
        report["detectors"]["live_nmf"] = live_summary
        print_table(f"Live GDScript β-NMF (β={args.beta}, personal={args.use_personal_templates})", live_summary)

    if args.detector in ("attack_decay", "both"):
        if args.train_bank:
            print("\nTraining Attack/Decay bank on supplied notes...")
            bank = ad_model.train(
                (m, r.audio, SAMPLE_RATE, r.onset_sample / SAMPLE_RATE) for m, r in sorted(notes.items())
            )
        else:
            bank = ad_model.Bank.load(args.bank)
        ad_summary = run_attack_decay_detector(cases, bank, args.attack_ms, args.spectral_ms, args.tolerance_ms)
        report["detectors"]["attack_decay_nmf"] = ad_summary
        print_table(f"Attack/Decay NMF ({'trained' if args.train_bank else args.bank.name})", ad_summary)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"\nSaved JSON report to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

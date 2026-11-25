"""Train the demo's 88-key bank from the same decoded Salamander clips as the live detector."""
import argparse
import json
import os
import sys
import wave
from pathlib import Path

os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "chord" / "attack_decay"))
from model import train


def notes(directory):
    rate = 44100
    for midi in range(21, 109):
        anchor = 21 + 3 * round((midi - 21) / 3)
        samples = np.fromfile(directory / f"{anchor}.mp3.f32", dtype="<f4")
        if samples.size == 0 or not np.isfinite(samples).all() or not np.any(samples):
            raise ValueError(f"Empty or invalid sample for MIDI {anchor}")
        # MP3 samples have no score annotations. Estimate the onset once on the
        # source waveform, before transposition, and retain a quiet lead-in.
        onset = int(np.flatnonzero(np.abs(samples) > 0.012 * np.max(np.abs(samples)))[0])
        speed = 2 ** ((midi - anchor) / 12)
        position = np.arange(onset, len(samples) - 1, speed)
        waveform = np.interp(position, np.arange(len(samples)), samples)
        lead = rate // 5
        yield midi, np.pad(waveform[:3 * rate], (lead, 0)), rate, lead / rate


def annotated_notes(manifest):
    for entry in json.loads(manifest.read_text(encoding="utf-8")):
        with wave.open(str(manifest.parent / entry["wav"]), "rb") as recording:
            if recording.getsampwidth() != 2:
                raise ValueError(f"Export {entry['wav']} as 16-bit PCM WAV")
            rate = recording.getframerate()
            pcm = np.frombuffer(recording.readframes(recording.getnframes()), dtype="<i2")
            audio = pcm.reshape(-1, recording.getnchannels()).mean(axis=1) / 32768
        if "offset" in entry:
            audio = audio[:round(rate * entry["offset"])]
        yield int(entry["midi"]), audio, rate, float(entry["onset"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", type=Path, help="Decoded Salamander directory or a JSON manifest of isolated piano WAVs")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    dataset = notes(args.samples) if args.samples.is_dir() else annotated_notes(args.samples)
    train(dataset).save(args.output)

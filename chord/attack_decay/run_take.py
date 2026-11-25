"""Godot worker entry point. PCM input contains interleaved stereo float32 samples."""
import argparse
import json
import os
import struct
import sys
from pathlib import Path

# Keep processing a take from occupying all cores while the live detector runs.
for variable in ("OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "OMP_NUM_THREADS"):
    os.environ[variable] = "1" if len(sys.argv) > 2 and sys.argv[2] == "train" else "2"


def train_profile(directory, output, temporary, attack_ms, spectral_ms):
    import numpy as np
    from model import analyze_microphone, normalize_calibration, train

    def read_recordings():
        for recording in sorted(directory.glob("*.pcm")):
            midi = int(recording.stem)
            with recording.open("rb") as stream:
                rate, onset = struct.unpack("<II", stream.read(8))
                stereo = np.fromfile(stream, dtype="<f4").reshape(-1, 2)
            if not 21 <= midi <= 108 or rate <= 0:
                raise ValueError(f"Invalid calibration clip {recording.name}")
            mono = stereo.mean(axis=1)
            if not 0 <= onset < len(mono):
                raise ValueError(f"Invalid onset in {recording.name}")
            yield midi, mono, rate, onset

    bank = train((midi, normalize_calibration(audio, rate, onset), rate, onset / rate)
                 for midi, audio, rate, onset in read_recordings())
    checks = []
    for midi, audio, rate, onset in read_recordings():
        events = analyze_microphone(audio, rate, bank, attack_ms, spectral_ms)
        hits = [event for event in events
                if event["midi"] == midi and abs(event["onset"] - onset / rate) <= 0.10]
        checks.append({"expected_midi": midi, "expected_onset": onset / rate,
                       "hit": bool(hits), "clean": len(hits) == len(events) == 1, "events": events})
    bank.save(temporary)
    temporary.replace(output)
    return {"trained_keys": len(bank.midi), "self_check": checks,
            "attack_ms": attack_ms, "spectral_ms": spectral_ms}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pcm", type=Path)
    parser.add_argument("sample_rate", help="Capture sample rate, or 'train' to train a calibration profile")
    parser.add_argument("bank", type=Path)
    parser.add_argument("result", type=Path)
    parser.add_argument("--attack-ms", type=float, default=20)
    parser.add_argument("--spectral-ms", type=float, default=40)
    args = parser.parse_args()
    try:
        import numpy as np
        from model import Bank, analyze_microphone

        if args.sample_rate == "train":
            result = train_profile(args.pcm, args.bank, args.result.with_suffix(".npz"),
                                   args.attack_ms, args.spectral_ms)
        else:
            stereo = np.fromfile(args.pcm, dtype="<f4").reshape(-1, 2)
            bank = Bank.load(args.bank)
            events = analyze_microphone(stereo.mean(axis=1), int(args.sample_rate), bank,
                                        args.attack_ms, args.spectral_ms)
            result = {"events": events, "bank_keys": len(bank.midi)}
    except Exception as exc:
        result = {"error": f"{type(exc).__name__}: {exc}"}
    temporary = args.result.with_suffix(".part")
    temporary.write_text(json.dumps(result, allow_nan=False), encoding="utf-8")
    temporary.replace(args.result)
    return int("error" in result)


if __name__ == "__main__":
    raise SystemExit(main())

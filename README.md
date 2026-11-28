# PianoHero — Piano Input Lab

**Piano Input Lab** is a Godot 4.7 acoustic piano pitch and polyphonic chord detection workbench built as the audio-input foundation for a mobile piano rhythm game (*Deadnote Saloon*).

It lets you test, calibrate, record, and benchmark real-time microphone pitch/chord recognition across desktop, Android, and iOS.

## What Is Implemented

- **Single-Note Pitch Detection (`Single note` mode)** — Monophonic YIN estimator for C3–C6 ([audio/pitch_detector.gd](audio/pitch_detector.gd)) with persistent **A4 tuning calibration** (`user://piano_tuning.cfg`).
- **Live Polyphonic Template NMF (`Chord mode`)** — Fixed-dictionary $\beta$-divergence NMF (Dessein et al. 2010, Eq. 12) running on a background thread ([chord/chord_detector.gd](chord/chord_detector.gd), [chord/live_chord_worker.gd](chord/live_chord_worker.gd)):
  - 50 ms analysis window, 10 ms hop, zero-padded 2,048-point FFT (10 Hz grid)
  - Four selectable window tapers (Hann, Hamming, Blackman, Kaiser shape 4) with prebuilt 88-key Salamander Grand templates ([chord/templates/](chord/templates/))
  - Tunable $\beta$ divergence slider (`0.0` to `2.0`, default `0.5`) with fast paths for $\beta \in \{0, 0.5, 1, 2\}$
  - Temporal attack & spectral confirmation with backdated onset events and repeated-strike detection ([chord/note_confirmation.gd](chord/note_confirmation.gd))
  - Per-key personal piano calibration with harmonic masking ([chord/key_calibration.gd](chord/key_calibration.gd))
- **Attack/Decay NMF Experiment (Desktop only)** — NumPy implementation of Cheng et al. (ISMIR 2016) ([chord/attack_decay/model.py](chord/attack_decay/model.py)) supporting whole-take analysis, sliding-window strike following, and training/self-checking a personal bank from saved calibration clips.
- **Built-in Evaluation & Recording Tools:**
  - **Replay test** ([chord/chord_replay.gd](chord/chord_replay.gd)) — Silent deterministic 7-case benchmark using MS Basic piano fixtures.
  - **Guided microphone test** ([chord/guided_chord_test.gd](chord/guided_chord_test.gd)) — 10-trial prompted recording saving synchronized `.wav` and `.json` telemetry under `user://guided-chord-tests`.
  - **Automated multi-configuration piano benchmark** ([tests/benchmark_piano.py](tests/benchmark_piano.py)) — Mixes your recorded piano notes into single notes, octaves, intervals, triads, dense chords, and repeated strikes, evaluating both detectors with **Accuracy, Precision, Recall, F1, Octave FP Rate, and Latency**.

## Project Layout

| Path | Contents |
| --- | --- |
| [lab.tscn](lab.tscn), [lab.gd](lab.gd) | Main Godot scene and UI/audio controller |
| [audio/](audio/) | Shared music/RMS utilities (`music_utils.gd`) and YIN pitch detector |
| [chord/](chord/) | Live β-NMF detector, note confirmation, worker thread, calibration, replay, guided test |
| [chord/templates/](chord/templates/) | 88-key Salamander `.tres` dictionaries, `replay.wav`, and MS Basic license |
| [chord/attack_decay/](chord/attack_decay/) | Desktop Cheng et al. (2016) Python/NumPy worker and Godot UI panel |
| [docs/](docs/) | NMF math guide, audio credits, attack/decay notes, and research proposals |
| [tests/](tests/) | Godot headless boot/core tests, Python unit tests, and piano accuracy/F1 benchmark |
| [tools/](tools/) | Offline template & bank builder scripts |
| [AGENTS.md](AGENTS.md) | Codebase architecture and engineering rules for contributors & AI agents |

## Running the App

1. Open the project in **Godot 4.7+** and press **Play** (main scene: `res://lab.tscn`).
2. For desktop **Attack/Decay NMF**, ensure Python 3.10+ with `numpy` is on `PATH` (or set `PIANO_NMF_PYTHON`).
3. For Android/iOS builds, use the presets in [export_presets.cfg](export_presets.cfg). Mobile builds expose the single-note detector, live polyphonic NMF, replay test, guided test, and key calibration.

## Running Automated Tests

Run all Godot headless tests (scene boot, A4 tuning calibration, YIN pitch, chord NMF, confirmation/re-strikes, key calibration, replay) and Python unit tests in one command:

```sh
python tests/run_all_tests.py
```

If Godot is not on your `PATH`, pass `--godot` or set `GODOT_BIN`:

```sh
python tests/run_all_tests.py --godot "C:\Program Files\Godot\Godot_v4.7.2-stable_win64_console.exe"
```

## Benchmarking Against Your Recorded Piano Notes

Record isolated notes in the app using **Calibrate keys** (saved as `<midi>.pcm` under Godot's `user://attack-decay/calibration/`) or supply a folder of 16-bit mono/stereo WAV files (`60.wav`, `C4.wav`, etc.) or a JSON manifest (`[{"midi": 60, "wav": "C4.wav", "onset": 0.38}]`), then run:

```sh
python tests/benchmark_piano.py --notes path/to/your/notes --detector both
```

The script mixes your recorded piano notes into multiple musical configurations:
- Isolated single notes (firm and soft)
- Simultaneous octaves (equal and loud-lower + soft-upper)
- Staggered octaves (soft upper note added over a ringing lower note)
- Intervals (fifths, thirds, semitone clusters)
- Major/minor triads and 4-note chords (including soft inner voices)
- Repeated strikes of the same key while still ringing

It prints per-configuration and overall **Onset Precision, Recall, F1, Exact-Case Accuracy, Octave False-Positive Rate, and Mean/P95 Latency**, and can save a JSON report via `--output report.json`.

Running `python tests/benchmark_piano.py` without `--notes` automatically uses built-in synthetic piano notes so you can verify the full pipeline out of the box.

## Further Documentation

- [docs/NMF_GUIDE.md](docs/NMF_GUIDE.md) — Why octave phantoms happen and how template NMF works
- [docs/SOURCES.md](docs/SOURCES.md) — Controls, recording format, and audio licensing/regeneration
- [docs/ATTACK_DECAY.md](docs/ATTACK_DECAY.md) — Attack/decay NMF model details and personal bank training
- [docs/IMPROVEMENTS_V1.md](docs/IMPROVEMENTS_V1.md) & [docs/IMPROVEMENTS_V2.md](docs/IMPROVEMENTS_V2.md) — Research notes and proposed NMF constraints

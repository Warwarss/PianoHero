# AGENTS.md — PianoHero / Piano Input Lab

Guidance and non-negotiable engineering rules for AI agents and contributors working in this repository.

## 1. Repository Overview

**PianoHero** is currently **Piano Input Lab**, a Godot 4.7 (`GL Compatibility`) application and DSP testbed for real-time acoustic piano pitch and polyphonic chord transcription (targeting mobile + desktop, with the goal of powering the *Deadnote Saloon* piano rhythm game).

### Directory Structure

```
PianoHero/
├── AGENTS.md                        # Agent instructions and repo standards (this file)
├── README.md                        # Project overview, setup, and test/benchmark commands
├── project.godot                    # Godot 4.7 project config (main scene: res://lab.tscn)
├── export_presets.cfg               # Android / iOS export presets (excludes tools/ and tests/)
├── lab.tscn                         # Main UI scene
├── lab.gd                           # Main UI and capture coordinator
├── audio/                           # Shared music/DSP utilities & monophonic pitch detection
│   ├── music_utils.gd               # Shared constants (GATE_DB, KEYS, A4), note names, Hz/MIDI, RMS/dBFS
│   └── pitch_detector.gd            # Single-note YIN estimator (C3–C6)
├── chord/                           # Polyphonic detection & calibration modules
│   ├── chord_detector.gd            # Live fixed-dictionary β-NMF (Dessein et al. 2010, Eq. 12)
│   ├── note_confirmation.gd         # Temporal attack/spectral confirmation, onset backdating, re-strike detection
│   ├── live_chord_worker.gd         # Background thread wrapper for live chord analysis
│   ├── key_calibration.gd           # Isolated per-key recording & adaptive onset capture
│   ├── chord_replay.gd              # Built-in 7-case silent replay harness
│   ├── guided_chord_test.gd         # 10-trial guided microphone recorder (.wav + .json)
│   ├── templates/                   # Binary/resource templates & replay fixture
│   │   ├── templates*.tres          # 88-key Salamander templates (Hann, Hamming, Blackman, Kaiser-4)
│   │   ├── replay.wav               # MS Basic labeled replay audio
│   │   └── MS-Basic-LICENSE.txt     # License attribution
│   └── attack_decay/                # Desktop-only Cheng et al. (ISMIR 2016) experiment
│       ├── model.py                 # NumPy STFT + attack/decay KL-NMF + DP offset model
│       ├── run_take.py              # Subprocess CLI entry point called by Godot
│       ├── take_panel.gd            # Godot UI panel managing worker & training processes
│       └── salamander.npz           # Prebuilt 88-key attack/decay bank
├── docs/                            # Technical guides, audio credits, and research specs
│   ├── NMF_GUIDE.md
│   ├── SOURCES.md
│   ├── ATTACK_DECAY.md
│   ├── IMPROVEMENTS_V1.md
│   └── IMPROVEMENTS_V2.md
├── tests/                           # All automated tests & real-piano evaluation benchmarks
│   ├── run_all_tests.py             # Unified test runner (Godot headless + Python unittest)
│   ├── test_boot_and_core.gd        # Godot scene boot, A4 tuning, YIN, NMF, confirmation, replay tests
│   ├── test_attack_decay_model.py   # Python unit tests for attack/decay NMF math
│   ├── benchmark_live_detector.gd   # Godot headless harness evaluating WAVs with live GDScript detector
│   └── benchmark_piano.py           # Multi-configuration piano benchmark (Accuracy, Precision, Recall, F1)
└── tools/                           # Offline asset generation scripts
    ├── build_chord_assets.mjs
    └── build_attack_decay_bank.py
```

---

## 2. Engineering Rules (Mandatory)

1. **Delete Obsolete Code Immediately**
   - Whenever a new feature or refactor supersedes an old code path, migration shim, or experiment, **delete the obsolete code** instead of leaving it commented out or unused.
   - Never leave dead files, unused variables, or fallback code paths for formats no longer supported.

2. **Zero Duplication**
   - Do not duplicate classes, helper functions, or shared constants across files.
   - Shared pitch/note-name/RMS/tuning logic belongs in `audio/music_utils.gd`.
   - Before adding a helper or constant, search the repo first and reuse or extract it cleanly.

3. **Separate Unrelated Features into Dedicated Files**
   - Keep `lab.gd` focused on UI orchestration and audio routing.
   - Put independent algorithms, calibration helpers, game modes, or evaluation tools in their own files under the appropriate directory (`audio/`, `chord/`, `tests/`, `tools/`, etc.).

4. **Strict Folder Discipline (No Clutter)**
   - Scripts live in `audio/` or `chord/` (and future `game/` when gameplay is added).
   - Templates, `.tres`, `.wav`, and licenses live in `chord/templates/` (not mixed with scripts).
   - All documentation `.md` files (except root `README.md` and `AGENTS.md`) live in `docs/`.
   - All tests and benchmark scripts live in `tests/`.
   - All offline asset builders live in `tools/`.
   - Never commit build outputs (`build/`), `.godot/` caches, or temporary recordings.

5. **Keep Tests Green & Add Tests for Every Change**
   - Every change must keep the automated test suite passing:
     ```sh
     python tests/run_all_tests.py
     ```
   - Core invariants tested in `tests/test_boot_and_core.gd`:
     - Main scene (`res://lab.tscn`) instantiates, enters the scene tree, and tears down cleanly without errors.
     - Single-note YIN pitch estimator and A4 tuning calibration converge accurately on known tones (including detuned A4).
     - `ChordDetector` + `NoteConfirmation` detect isolated notes, chords, octaves, re-strikes on sustained notes, survive transient noise frames without wiping state, and handle variable worker intervals (`dt > 40 ms`) without resetting.
     - `KeyCalibration` detects onset and completes capture on valid strikes while rejecting brief knocks.
     - `ChordReplay` runs end-to-end against `chord/templates/replay.wav`.
   - When adding a new feature or bug fix, add a focused regression test in `tests/`.

6. **Keep Documentation Synchronized**
   - Update `README.md` and relevant files in `docs/` whenever user-facing behavior, file paths, or algorithms change.
   - Clearly label unimplemented research proposals (such as `docs/IMPROVEMENTS_V2.md`) as proposals/specs, not implemented behavior.

---

## 3. Running Tests & Benchmarks

- **Full test suite (Godot headless + Python unit tests):**
  ```sh
  python tests/run_all_tests.py
  ```
- **Godot headless tests only:**
  ```sh
  godot --headless --path . --script res://tests/test_boot_and_core.gd
  ```
  *(Set `GODOT_BIN` if Godot is not on `PATH`; `tests/run_all_tests.py` also auto-detects `C:\Program Files\Godot\Godot_v*_console.exe`.)*
- **Python Attack/Decay unit tests only:**
  ```sh
  python tests/test_attack_decay_model.py -v
  ```
- **Automated Piano Benchmark (Accuracy, Precision, Recall, F1 across configurations):**
  ```sh
  # Uses your recorded piano notes (.pcm from user://attack-decay/calibration, or .wav files / JSON manifest)
  python tests/benchmark_piano.py --notes path/to/your/piano_notes

  # Or run immediately with built-in synthetic/fallback piano notes to verify pipeline:
  python tests/benchmark_piano.py
  ```

---

## 4. Known Architectural Constraints & Next Priorities

- **Latency vs. Rhythm-Game Target:** Target end-to-end detection latency for *Deadnote Saloon* is `< 40 ms` (Virtuosic Hit = ±45 ms). Live GDScript NMF currently pays STFT window + confirmation + interpreted GDScript compute; moving live FFT + β-NMF into a C++/Rust GDExtension or benchmarking a lightweight causal neural onset model is the highest-leverage next step.
- **Desktop vs. Mobile Split:** `chord/attack_decay/` runs locally via Python + NumPy on desktop only; Android/iOS run only the GDScript live detector.
- **Acoustic Bleed:** Once game audio plays from speakers alongside microphone detection, headphones mode, muted accompaniment, or acoustic echo cancellation (AEC) will be required.

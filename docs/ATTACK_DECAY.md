# Attack/decay NMF experiment

In Godot, open **Chord mode → Record a take**. Play a phrase, then press **Finish and analyze**. Recording also finishes at eight seconds. The first card shows the live template detector. The second shows the estimated time of each strike from the start of the take. Notes in the same 20 ms frame share a row. A second strike of C4 gets its own row. Use **Replay test** to send the bundled labeled audio to both methods.

**Follow strikes** continuously fits overlapping 1.6-second excerpts and keeps eight seconds of strike history. Each result shows the audio time analyzed so far. The fit waits for at least 400 ms of following audio, plus computation time. A coverage-gap message means the worker fell behind and skipped audio. This preview uses a fresh peak threshold for each excerpt. **Record a take** gives the paper-style whole-excerpt result with one threshold for the phrase.

The lab also checks the microphone level. A reported strike needs at least two consecutive 20 ms blocks above −55 dBFS RMS near its onset. For quiet or steady input, the threshold also needs to clear the estimated noise floor by about 6 dB. If no block pair clears the gate, the lab skips the fit. This is an app-level check in addition to the paper’s relative onset threshold.

**Attack** (default 20 ms) and **Spectrum** (default 40 ms) set the minimum time spanned by consecutive observations in both panels. In the attack/decay panel, the fitted attack must remain above its onset threshold and at least half its local peak. Near that attack, removing the pitch must worsen the fit by at least 0.05 on the normalized KL-cost scale for the spectrum duration. The worker has a 20 ms hop, so these controls round up to whole hops. The event list keeps the estimated attack time, even though the decision uses later frames. Calibration self-checks use the selected durations at training time.

The live template panel uses the fitted gain for each pitch as its attack cue. It looks for a rise of at least 35% over the recent baseline, then requires the gain to hold at least 65% of its level at the start of the rise. The pitch must also pass the existing spectral checks continuously for the selected spectrum duration. The two requirements can overlap within a 120 ms confirmation window. The displayed percentages are relative fitted strengths. Both panels confirm their own pitches, so the live panel can run during a background attack/decay fit.

The attack/decay worker runs locally on desktop and requires Python 3.10+ with NumPy. The game can use a Python executable on PATH, or an explicit executable supplied in the `PIANO_NMF_PYTHON` environment variable. The editor also reads a machine-local interpreter path from `.godot/attack_decay_python.txt`. For a desktop PCK export, include `chord/attack_decay/*.py,chord/attack_decay/*.npz` as non-resource files. Android and iOS builds currently expose only the live detector for acoustic testing.

## What the second card measures

Each key has a hammer-attack spectrum, a ringing-string spectrum, and a decay rate. Both spectra are driven by one sequence of strike amplitudes. A large strike can explain many later frames of ringing. A second strike requires a new peak. The model fits the whole take and uses its maximum attack activation to set the threshold. Its timestamps locate events *within* the recording. They do not measure live response latency. [Cheng et al., ISMIR 2016, §§2–3](https://archives.ismir.net/ismir2016/paper/000085.pdf)

| Stage | Implementation |
| --- | --- |
| Input | Mono at 44,100 Hz. A 4,096-sample Hamming window, an 882-sample hop, and an 8,192-point FFT produce 4,097 one-sided magnitude bins. Each bin is median-filtered across five frames. |
| First training pass | A labeled onset fixes the strike activation for each isolated note. Fit attack and decay spectra, the decay rate, and a transient envelope for 50 iterations. Normalize each envelope to unit peak after each update, then average the envelopes across pitches. |
| Second training pass | Fix the labeled strikes and the shared envelope. Refit both spectra and the decay rate for 50 iterations. |
| Transcription | Fix the bank. Fit strike amplitudes for 50 multiplicative KL updates (β = 1). After each update, raise activations to a power that rises linearly from 1.00 to 1.04. This is the comparison setting in §3.2. |
| Onsets | Find attack peaks above the 20-frame moving average plus −30 dB relative to the take-wide peak. Merge same-key peaks less than 100 ms apart using amplitude-weighted time, then repeat the merge once. Fast repetitions inside that interval can merge. |
| Offsets | Compare per-frame KL costs with and without each pitch. Normalize, segment, and backtrack the two-state minimum-cost path with self/switch weights 0.50/0.55. The worker computes offsets. The strike list displays onsets. |

The article leaves a few conventions open. This implementation uses a **symmetric** Hamming window, centered frames with zero padding at the recording boundaries, edge replication for the spectrogram median, a nine-frame transient pattern, and reproducible initialization. Offset segmentation uses a ten-frame median and a 0.05 cutoff on the smoothed normalized cost difference. The eight-second capture limit is a UI choice. The published comparison evaluated 30-second excerpts. [Paper](https://archives.ismir.net/ismir2016/paper/000085.pdf) · [Cheng’s thesis, chapter 5 and appendix B](https://webspace.eecs.qmul.ac.uk/s.e.dixon/phd/TianCheng-PhD-Thesis.pdf)

## Testing your piano

In **Chord mode**, choose a key or **All keys (A0–C8)** and press **Calibrate keys**. Release the keys and pedal. When prompted, play the named key once and hold it until the next release prompt. **Finish calibration** keeps completed keys if you want to stop partway through.

Calibration tracks the room level while waiting. Two consecutive 5 ms blocks above the adaptive threshold mark an onset, and the next 120 ms help filter out short knocks. If a strike is missed, release the key and pedal and try again, or use **Retry current key** to reset the onset detector. The app keeps about 180 ms of lead-in and 1.4 seconds after the onset. The live detector averages four spectra taken 50–200 ms after the onset and builds templates for all four selectable windows. On desktop, attack/decay training starts in the background when calibration ends. You can run either detector during training. The new **My piano** bank becomes active when the attack/decay panel is idle. **Train from saved calibration** retries training using the recordings already on disk.

Before attack/decay training, the app measures the 99th-percentile amplitude in the first 250 ms after each onset and applies one gain to the whole clip. This reduces differences in calibration loudness and preserves the relative levels of the attack and decay. **Train from saved calibration** applies normalization to the existing recordings. The live detector already normalizes each training spectrum by its peak.

If saved recordings are newer than **My piano**, Godot rebuilds the bank on startup. The panel flags the stale personal bank until the replacement is ready. After training, it replays each raw calibration recording through the entire trained bank. A pitch counts as found if it lands within 100 ms of the recorded onset. A clean take contains exactly that one strike. The per-key results are saved in `attack-decay/calibration-check.json` inside the app’s user data folder. This check can reveal training, labeling, and false-strike problems on the saved material. The paper measured accuracy on separate musical pieces.

The prompt supplies the pitch label. Play only the named key. Onset timing is measured within the captured audio. Measuring the delay from the physical key press would need a reference such as a synchronized MIDI signal. Mobile builds can capture the calibration and build the live templates. Attack/decay training and analysis require desktop Python with NumPy.

The bundled bank uses Alexander Holm’s Salamander grand. We estimate onsets in the source recordings and transpose the closest sampled key for the intervening semitones. The published experiment used isolated notes and test music from the *same* piano. For an out-of-tune piano, the bundled bank can give the wrong pitch or miss a strike. The live detector’s A4 setting and averaged spectra apply to the first card. An attack/decay bank needs the original time-varying audio. [Salamander recordings](https://github.com/Tonejs/audio/tree/master/salamander) · [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/)

To train from existing recordings, use isolated notes as 16-bit PCM WAVs with a short silent lead-in. Mark each audible onset in seconds from the start of its WAV. Optionally mark the release as `offset` to trim the training clip. A small bank is useful for a controlled C4/C5 experiment. It can report only the keys it contains.

```json
[
  {"midi": 60, "wav": "C4.wav", "onset": 0.38, "offset": 2.8},
  {"midi": 72, "wav": "C5.wav", "onset": 0.46, "offset": 2.6}
]
```

Save this as `notes.json` next to the WAVs, edit the example times, then run the following from the project root. Open the piano-bank menu in the second card and choose **Browse for trained bank…**. The editor also lists local banks from `build/attack-decay/` at startup.

```sh
python tools/build_attack_decay_bank.py path/to/notes.json --output my-piano.npz
```

To rebuild the bundled bank, pass the decoded Salamander directory described in [the audio credits](SOURCES.md) in place of the manifest.

# Chord experiment audio

In the lab, select **Chord mode** and start the microphone. Percentages under the keys are relative fitted strengths. **Calibrate** uses the existing single-note A4 prompt and applies the saved reference to the entire dictionary.

**Replay test** stops the microphone and feeds labeled audio directly to the same detector at A4 = 440 Hz. The first result per case is the elapsed audio time until three consecutive 10 ms updates contain exactly the expected keys. The second result is the percentage of exact updates during the 500 ms target segment. The replay runs silently and restores your tuning afterward. Live input also uses 50 ms windows and 10 ms hops. If the UI falls behind, it skips old hops and reports the loss.

The 88-column spectral dictionary in `templates.tres` is adapted from **Salamander Grand Piano** by Alexander Holm, distributed by Tone.js under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). The source piano is a Yamaha C5 sampled in minor thirds. Each column uses the closest sampled key, transposed as needed, with five short magnitude spectra averaged and quantized. [Original recordings and attribution](https://github.com/Tonejs/audio/tree/master/salamander)

`replay.wav` is a labeled mix of **MS Basic** piano recordings from a separate bank. The supplied license and credits accompany this file in `MS-Basic-LICENSE.txt`. The recordings were trimmed, level-matched, mixed, and faded. The lowest pair and highest key are pitch-shifted fixtures. The ringing-C4 case overlaps recordings to simulate sustain. These fixtures measure algorithm behavior with known labels. They do not measure a phone's acoustic latency.

To regenerate, decode the Salamander clips at MIDI keys 21, 24, …, 108 to mono 44.1 kHz float32 little-endian files named `<midi>.mp3.f32`. Decode the left MF channel from the MS Basic recordings to `mf-<midi>.ogg.f32` at the same rate. Supply the first three seconds, or the full clip if shorter. From the project root run `node tools/build_chord_assets.mjs <decoded-directory>`.

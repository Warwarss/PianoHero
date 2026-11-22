# Deadnote Saloon

Deadnote Saloon is a piano rhythm game set in a pixel-art Western saloon. You play a ragtime melody to duel a zombie cowboy. Each well-timed note sounds the piano and knocks down his health. At four consecutive hits, glasses start clinking on the offbeat. At eight, the cowboy staggers in time. The player gets to hear and see the room respond to their playing.

This repository, `PianoHero`, is the starting point for the mobile app. The gameplay below comes from the web prototype in the sibling folder `../deadnote/dist/`. The mobile milestone is a proposal.

## How a run plays

1. **Try the piano.** Before the duel, all 24 keys from C4 through B5 are playable. Five light up for the run. The game picks a root from C4, D4, F4 or G4 and uses pitches 2, 3, 4, 11 and 12 semitones above it. All three duels use those same five pitches. A replay picks a different root.
2. **Follow the falling notes.** Two wooden knocks count you in. A colored tile travels for two beats toward a gold frame above its piano key. Strike the key when the tile fits the frame. The melody is a looping, five-pitch arrangement of the A strain of *The Entertainer*. The chart times the start of each note. Releasing a key controls the piano sound.
3. **Win three duels on five hearts.** Empty the cowboy’s health bar to win a duel. A note that passes its window costs one heart and breaks the streak. A wrong or mistimed press during play breaks the streak and lowers accuracy, but the pending note can still be hit before it expires. Losing the last heart ends the run.
4. **Choose a reward.** After each of the first two wins, choose +2 damage per hit, +25 ms on the outer hit window, or a full heal if any hearts are missing. Damage and timing upgrades stack. Hearts, upgrades, score and accuracy carry into the next duel. The streak resets. The final screen shows the run’s score and accuracy and offers a replay.

| Duel | Prototype title | Tempo | Cowboy health |
| --- | --- | ---: | ---: |
| 1 | Salonda İlk Düello | 96 BPM | 349 |
| 2 | Öğle Vakti | 108 BPM | 361 |
| 3 | Son Hesaplaşma | 120 BPM | 373 |

## Timing and scoring

Match the press to the nearest pending note of the same pitch. Early and late hits use the same limits. The player sees the grade, damage and timing error in milliseconds. More accurate hits produce a stronger recoil, and the best hit pops the cowboy’s hat into the air.

| Grade shown in game | Maximum timing error | Base damage | Base points |
| --- | ---: | ---: | ---: |
| Virtuosic Hit | 45 ms | 12 | 100 |
| Perfect | 90 ms | 11 | 90 |
| Good | 150 ms | 9 | 70 |
| Zayıf (Weak) | 210 ms | 6 | 40 |

Each hit adds its base points plus three times the current streak, capped at 60 bonus points per hit. Accuracy is the average base points per judgment, displayed as a percentage. Misses and off-beat presses count as zero. For example, a first hit 80 ms late earns **Perfect**, deals **11 damage**, scores **93 points** and shows **90% accuracy**. A timing upgrade extends only the Zayıf window.

## Suggested first mobile milestone

Build one playable 96 BPM duel on a phone, from free play through the first reward choice. Use the original phrase, piano recordings and layered saloon art so collaborators can compare the feel of the same duel across versions.

- **Touch layout.** Try landscape first to give adjacent black and white keys room. Keep each falling tile, target and playable key on the same horizontal center. Use pitch labels on touch. Test the full two-octave keyboard on a small phone before settling on the layout.
- **Timing and sound.** Timestamp each touch as it arrives. Use one song clock for note positions, accompaniment and hit judgments so a late animation frame cannot change a grade. Bundle a playable piano bank and try the first duel offline. Check the 80 ms example above and play repeated notes quickly enough to hear whether each tap has a distinct attack.
- **Interruptions and feedback.** Pause and release sounding notes when the app loses focus. On return, resume from the paused beat. Keep the gold targets, pitch labels and timing text readable with sound muted or reduced motion enabled.

Once that duel feels right, carry over the faster rounds, stacking rewards and replay. The mobile framework, target platforms, final orientation and external MIDI support are open decisions. The web version already supports touch, computer keys and a MIDI keyboard. Its MIDI controls include velocity, sustain, octave shift and an option to silence local piano playback when the keyboard provides its own sound.

## Where to find the original

Open `../deadnote/dist/index.html` in a browser to try the touch or computer-key version. The interface and duel titles are in Turkish. Paths below are relative to `deadnote/dist/`.

| File | What to reuse or inspect |
| --- | --- |
| `game.js` | `hook` and `phrase` store the melody as semitone offsets and beat lengths. `grades`, `down`, `startRound` and `finish` contain timing, scoring and progression. |
| `index.html`, `style.css` | Original copy, help screen, key and target positioning, and reduced-motion behavior. |
| `saloon-empty.png`, `cowboy-body.png`, `cowboy-hat.png` | Separate background, body and hat layers. Give all three the same crop so the hat sits on the cowboy across screen sizes. |
| `audio.js`, `audio/recordings.js` | Piano playback, bass, wooden knocks and glass clinks. The prototype bundles a MuseScore MS Basic piano and can fetch the FreePats Upright Piano KW recordings. Keep the bundled bank’s accompanying notice in `audio/MS-Basic-LICENSE.md` when reusing it. |
| `midi.js` | Device selection, note press and release, sustain, transposition and disconnect handling. |

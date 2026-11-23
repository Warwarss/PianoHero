# Improvements to the algorithm

When playing C4 also triggers C5, the first question is **when C5 appears**. A one-frame flash, an extra note that persists throughout the sound, and a missed C5 struck over a ringing C4 point to different experiments. This guide connects those observations to four extensions cited by Dessein, Cont and Lemaitre. The Bayesian method is Bertin et al. [3]. The separate 2016 paper by Cheng et al. models the hammer attack and the ringing string. [Original bibliography](https://archives.ismir.net/ismir2010/paper/000083.pdf#page=6)

## Where is the gain in NMF?

For one instant, our detector fits $v_t \approx W h_t$. Stacking those instants as columns gives $V \approx WH$ for the recording.

| Symbol | Meaning in our detector |
|---|---|
| $V_{f,t}$ | Measured strength in frequency bin $f$ during frame $t$. One column $v_t$ is the microphone spectrum for that frame. |
| $W_{f,k}$ | Strength of bin $f$ in the template for key $k$. One column $w_k$ is the spectral signature of that key. |
| $H_{k,t}$ | **Gain** of key $k$ at frame $t$. Column $h_t$ holds the 88 key gains at that instant. Reading one row across time shows how that key’s fitted strength evolves. |

For example, suppose you play C4 and E4. A possible fit is

$$
v_t \approx 0.8\,w_{\mathrm{C4}} + 0.3\,w_{\mathrm{E4}}.
$$

Here 0.8 and 0.3 are gains. Multiplying the C4 template by 0.8 scales **every harmonic in that template together**. In this example, the demo displays C4 at 100% and E4 at about 38%, because it divides by the largest fitted gain. That percentage measures relative contribution on the detector’s gain scale. It cannot tell us the probability that a key was pressed. The implementation uses a 50 ms analysis window, a 10 ms hop, and one template per key with optional recordings of the player's own piano. [Godot detector](chord_detector.gd) · [Detailed NMF walkthrough](NMF_GUIDE.md)

### Why C4 can produce a C5 gain

At standard tuning, C4 has partials near **262, 523, 785, 1047, 1308 and 1570 Hz**. C5 contributes near **523, 1047 and 1570 Hz**. C4’s odd partials help establish that C4 is sounding. To decide whether C5 is *also* sounding, we need to estimate how much energy C4 alone should produce at the shared frequencies.

Suppose C4’s 262 Hz peak already fits, but the measured 523 Hz peak is stronger than the template predicts. Turning up C4 would overshoot 262 Hz. Giving C5 a small gain can improve the overall fit. This also explains why dropping C4’s even partials loses useful evidence. Those partials tell us how much of the apparent C5 our piano can produce from a single C4 strike. A template mismatch is one plausible cause of the reported error. [Vincent et al., example in §2.3](https://perso.telecom-paristech.fr/rbadeau/assets/irisa-09.pdf#page=7)

## The four cited methods

| Citation | What changes | Where it could help our game |
|---|---|---|
| [24] Virtanen & Klapuri | Split a template into a pitched source and a filter that colors its sound. | Adapt a generic piano bank when a piano or microphone consistently emphasizes the same frequency region. |
| [20] Raczyński, Ono & Sagayama | Restrict a pitch template to frequency regions where its harmonics can occur. | Keep unrelated noise out of a learned template. Octave-related keys still share valid harmonic regions. |
| [3] Bertin, Badeau & Vincent | Model harmonic components and link each key’s gains across time with a Bayesian prior. | Suppress brief false notes and stabilize ringing notes. |
| [23] Vincent, Bertin & Badeau | Model the spectral envelope of a note with overlapping groups of partials. | Explain a brighter or darker C4 without automatically assigning energy to C5. |

### [24] Source–filter model

Virtanen and Klapuri represent a template as the product of a source spectrum and a filter response. In simplified form, $w_k(f)=s_k(f)\,q(f)$. The source $s_k$ places energy at the frequencies produced by the vibrating string. The filter $q$ emphasizes or attenuates parts of the spectrum. Reusing a filter across sources reduces the number of parameters to estimate. The authors’ preliminary experiments used singing signals. [Virtanen & Klapuri, 2006](https://homepages.tuni.fi/tuomas.virtanen/papers/virtanen-AMAC2006.pdf)

**Practical fit.** A moderate calibration change would estimate a smooth correction from several isolated keys and apply it to the generic bank. This could shorten setup for an unfamiliar piano. Individually recorded templates already capture much of the piano and microphone response, so the benefit there is less clear. A shared correction can also miss a peculiarity of one string or register. I would prioritize this when quick setup with generic templates is the goal.

### [20] Harmonic constraint

Raczyński and colleagues initialize a key’s template with zeros outside its allowed harmonic bins. Under multiplicative NMF updates, a zero stays zero. The template can learn the strengths of the allowed partials while excluding unrelated peaks. The authors also explore sparsity and decorrelation penalties on note activities. Dessein’s reference [20] is the ASJ Autumn Meeting paper. The linked ISMIR paper by the same authors describes the method in detail. [ASJ citation in the project bibliography](https://crestmuse.jp/crestmuse_public2007_j.html) · [Raczyński et al., ISMIR 2007](https://archives.ismir.net/ismir2007/paper/000381.pdf)

**Practical fit.** A small calibration experiment would give more weight to bins close to *measured* partials. Allow tolerance for FFT peak width, tuning and piano-string inharmonicity. An exact integer-frequency mask can throw away genuine energy, particularly high partials. Keep even and odd partials. Both C4 and C5 can legitimately explain a peak near 523 Hz, so a harmonic mask alone cannot settle the octave. I would also avoid a blanket decorrelation penalty in a chord game, where several real keys often start together.

### [3] and [23] compared

| Question | [3] Temporal smoothness | [23] Spectral smoothness |
|---|---|---|
| What becomes smooth? | A key’s gain across neighboring frames, along a row of $H$. | The relative strengths of neighboring partials within a template, inside a column of $W$. |
| Which symptom fits? | C5 flashes briefly, or a held note drops out for one update. | C5 stays visible through a bright C4 strike because one fixed harmonic balance fits poorly. |
| Main risk | A quiet new strike can register late, or a note can linger after release. | Too much flexibility lets C4 absorb a genuinely played soft C5. |
| Effort | Small for a causal penalty in our squared-error solver. Substantial for the full Bayesian estimator. | Moderate to learn band weights during calibration. More involved to let them adapt safely during play. |
| Published result | Recorded-piano note-onset F1 was **41.3%** for harmonic-only and **45.0%** for the combined model, a **3.7-point** difference. [Table V](https://perso.telecom-paristech.fr/rbadeau/assets/bertin10.pdf#page=7) | Piano frame-level pitch F1 was **60.5%** for harmonic-only and **67.0%** with spectral smoothness, a **6.5-point** difference. A trained-template baseline reached **66.0%**. [Table 1](https://perso.telecom-paristech.fr/rbadeau/assets/irisa-09.pdf#page=13) |

F1 balances precision and recall. **Onset F1** scores whether the right key was detected near the strike. **Frame-level F1** scores which pitches were sounding at each instant. The two reported gains use different baselines and metrics. Neither gives a percentage improvement we can promise for a calibrated phone recording.

### [3] The Bayesian harmonic model with temporal smoothness

Imagine C5’s fitted gain over five updates is **0.00, 0.01, 0.32, 0.02, 0.00**. A brief spike could improve one frame’s fit. A model that considers neighboring frames also weighs how plausible it is for a piano note to rise and almost vanish in 20 ms.

Bertin et al. model a pitch through harmonic components. For a previous gain $g>0$, they use an inverse-Gamma prior on the next gain,

$$
h_t \mid h_{t-1}=g \sim \operatorname{InvGamma}\bigl(\alpha,(\alpha+1)g\bigr).
$$

The most likely next gain is $g$. Larger $\alpha$ favors tighter continuity. The asymmetric distribution allows an upward jump more readily than an equally abrupt collapse. The Bayesian fit combines this expectation with the evidence in the audio. A strong strike can outweigh the prior. Their full estimator iteratively fits a recording using harmonic initialization and a SAGE algorithm. The authors found that smoothing alone could hurt transcription, particularly around transients. [Bertin et al., §III-C and §IV](https://perso.telecom-paristech.fr/rbadeau/assets/bertin10.pdf)

**An easier live addition.** Our default solver already starts each update with the previous gains. That gives it a starting guess. To give continuity an explicit weight in the decision, we could minimize

$$
\tfrac12\|v_t-Wh_t\|_2^2
+\lambda\sum_k h_{k,t}
+\tfrac{\mu}{2}\|h_t-h_{t-1}\|_2^2,\qquad h_t\geq 0.
$$

The first term fits the audio. The second favors fewer active keys. The proposed third term charges for gain changes between frames. It uses only past audio, so it requires no extra FFT window or look-ahead. A large $\mu$ can still delay an attack. I would test relaxing it when fresh strike evidence appears. This is a simpler engineering adaptation than the paper’s inverse-Gamma estimator. A persistent false C5 can satisfy continuity just as well as a genuine one.

### [23] The harmonic model with spectral smoothness

Vincent et al. give each key several overlapping band shapes. Each band covers a few adjacent partials of that key. For one template per key, the construction is

$$
w_k(f)=\sum_b e_{k,b}\,B_{k,b}(f).
$$

Here $B_{k,b}$ is a fixed band pattern and $e_{k,b}$ sets its strength. The band weights determine the note’s *shape*. The separate gain $H_{k,t}$ scales that whole shape at time $t$. The paper estimates band weights using evidence across the recording while fitting the gains frame by frame. Overlap lets a template become broadly brighter while limiting its ability to boost arbitrary individual partials. A genuine C5 tends to add energy at *alternating* C4 partials, a different pattern from broad brightening. [Vincent et al., equations 9–13](https://perso.telecom-paristech.fr/rbadeau/assets/irisa-09.pdf#page=8)

**An addition to our calibration.** Record isolated soft and firm C4 strikes. Preserve the actual partial locations, including tuning deviations, and estimate how much their balance changes across strikes. During gameplay, compare the C4-only and C4+C5 fits while allowing C4 to vary within that measured range. Learning one improved template is cheaper but gives every subsequent strike one fixed brightness. Allowing bounded variation costs more and directly tests the suspected mismatch. The most revealing control is a soft, genuine C5 played over a loud C4.

## The additional paper on attack and decay

Cheng, Mauch, Benetos and Dixon model two sounds from one keystroke. The hammer produces a brief attack. The strings then ring with a different spectrum and decay rate. Each key has an attack template and a decay template driven by one shared strike activation. A strike therefore predicts some of the energy the microphone will hear later. In this paper the activation represents a **strike**, whereas our current $H_{k,t}$ represents how strongly a template contributes **during a frame**. [Cheng et al., ISMIR 2016](https://archives.ismir.net/ismir2016/paper/000085.pdf)

**How the published system works.** It learns spectral shapes, an attack envelope and per-key decay rates from isolated notes. During transcription it estimates sparse strikes. The strike sequence is convolved with the attack envelope and an exponential decay. The authors then pick onset peaks, merge nearby detections, and use the change in fit when a note is removed to estimate its end by dynamic programming and backtracking. Their experiments used approximately 93 ms windows, 20 ms hops, 100 ms median smoothing, and 50 fitting iterations with KL divergence ($\beta=1$). The published fit uses future frames. [Model and experimental setup, §§2–3](https://archives.ismir.net/ismir2016/paper/000085.pdf#page=2)

**What the results mean for calibration.** On real MAPS ENSTDkCl recordings with templates trained on the same piano, onset F1 reached **81.80%** and frame F1 reached **79.01%**. Training on synthetic piano notes and testing on real recordings brought both measures to around **65%**. The authors also describe fast passages where predicted ringing can mask later strikes. These results motivate testing templates from the player’s piano. They do not establish live accuracy or latency on a phone. [Results, Table 2 and discussion](https://archives.ismir.net/ismir2016/paper/000085.pdf#page=6)

**What I would build in Godot.** A full port would replace the frame fitter and note tracker and would serve as an offline comparison. A smaller live experiment can reuse microphone capture, FFT, UI and the squared-error solver. Our calibration currently skips the first few updates and averages the ringing sound. Capture the attack separately and estimate a decay factor from the sustained portion. For a causal prototype, let $s_{k,t}$ be a new strike, $d_{k,t}$ the predicted ringing strength, and $\rho_k$ the fraction carried into the next hop. [Current calibration](../lab.gd)

$$
d_{k,t}=\rho_k d_{k,t-1}+s_{k,t},\qquad 0<\rho_k<1.
$$

The live fit can first account for the expected ringing of C4, then ask whether the unexplained sound supports a fresh C5 strike. This is especially useful when the second key arrives later. Simultaneous C4 and C5 share an onset and many partials, so their calibrated spectral shapes still matter. Cheng’s thesis gives the detailed derivation, and a third-party Python implementation is available for an offline comparison. [Cheng’s thesis](https://www.eecs.qmul.ac.uk/~simond/phd/TianCheng-PhD-Thesis.pdf) · [Python implementation](https://github.com/beiciliang/modelAttackDecay-for-piano-transcription)

## How to choose the next experiment

Use the same phone position and replay the same recordings through the current squared-error solver and each proposed variant. Keep calibration strikes separate from evaluation strikes.

| Recording from the player's piano | What to measure | First experiment |
|---|---|---|
| C4 alone, played softly and firmly several times | False C5 triggers per C4 strike and how long each persists | Brief flashes suggest [3]. Persistent errors that vary with brightness suggest [23]. |
| Loud C4 and soft C5 struck together | Fraction of real C5 strikes detected and time to first correct chord | Check whether spectral flexibility suppresses a genuine octave. |
| Soft C5 added while C4 is already ringing | Missed C5 strikes and delay from the second strike to detection | Try the causal attack/decay model. |

The built-in replay exercises other chords and registers, but its lone C4 example did not reproduce the reported extra C5. A recording that reproduces it is necessary to measure progress on this piano. For gameplay, the deciding evidence is fewer false attacks **together with** prompt detection of real ones. [Replay fixtures and metrics](chord_replay.gd)

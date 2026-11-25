# Research Task: Improving Piano Transcription NMF Using Three Constraints

## 1. Project Context

We are developing a real-time polyphonic piano transcription system capable of recognizing all 88 piano notes, including simultaneous chords, with a target detection latency below 40 ms.

Our baseline is Dessein et al. (2010), *Real-Time Polyphonic Music Transcription with NMF and Beta-Divergence*. The algorithm decomposes each incoming magnitude spectrum using 88 prerecorded piano-note templates:

\[
V \approx WH
\]

- \(V\): observed magnitude spectrogram.
- \(W\): fixed nonnegative spectral dictionary.
- \(H\): nonnegative note-activation matrix.

The baseline minimizes \(D_\beta(V\|WH)\), with \(\beta=0.5\), using multiplicative updates.

Investigate three NMF improvements: **sparsity, temporal continuity, and harmonicity**. Explain their theory, reproduce their mathematical formulations, and implement them incrementally without breaking the existing baseline.

## 2. Sparsity — Cont (2006)

**Source:** *Realtime Multiple Pitch Observation Using Sparse Non-negative Constraints.*

[Original paper](https://ismir2006.ismir.net/PAPERS/ISMIR06170_Paper.pdf)

**Principle:** Only a relatively small subset of the 88 piano notes is normally active simultaneously. Unconstrained NMF may activate incorrect notes to explain overlapping harmonics.

A practical regularized formulation is:

\[
\min_{H\geq0}D_\beta(V\|WH)+\lambda_s\|H\|_1
\]

The \(L_1\) penalty discourages weak, unnecessary activations.

**Original approach:** Cont instead uses sparse nonnegative constraints, including a smooth approximation to the number of significant activations and projected-gradient optimization. Do not confuse this with ordinary \(L_1\)-NMF.

**Advantages:**
- Can reduce false-positive notes and harmonic ghost detections.
- Encourages interpretable, concentrated activations.
- Compatible with fixed dictionaries and streaming optimization.

**Disadvantages:**
- Excessive sparsity suppresses quiet notes and dense chords.
- Requires tuning the regularization strength.
- Cont's method assumes known pitch templates and does not directly solve note-onset timing.

**Evidence:** Cont demonstrated a real-time multiple-pitch observation implementation. However, Dessein et al. (2010) observed that sparse NMF could reduce false detections while increasing missed notes, without improving overall F1.

**Implementation:** First add optional \(L_1\) regularization to the existing beta-NMF solver. Use scale-normalized templates and an optimizer appropriate for the modified objective. Compare several \(\lambda_s\) values; do not impose a fixed chord-size limit.

## 3. Temporal Continuity — Virtanen (2007)

**Source:** *Monaural Sound Source Separation by NMF With Temporal Continuity and Sparseness Criteria.*

[Original paper](https://www.ee.columbia.edu/~dpwe/e4896/papers/Virtanen07-NMF.pdf)

**Principle:** Sustained musical notes generally evolve gradually. Independent framewise NMF may produce unstable activations, causing notes to flicker.

A simplified penalty is:

\[
R_t(H)=\sum_{k,t>1}(h_{k,t}-h_{k,t-1})^2
\]

The objective becomes:

\[
\min_{H\geq0}D_\beta(V\|WH)+\lambda_tR_t(H)
\]

Virtanen additionally normalizes each component's smoothness penalty by its squared RMS activation to address scaling ambiguity.

**Advantages:**
- Reduces unstable note activations.
- Improves temporal consistency for sustained sounds.
- May reduce false note interruptions.

**Disadvantages:**
- Penalizes rapid changes, potentially suppressing note attacks.
- Excessive smoothing creates detection delay.
- Full-sequence optimization may depend on future frames.

**Evidence:** Virtanen reported improved source separation, particularly for pitched sounds, compared with baseline approaches. Sparsity contributed less improvement in that study. These results concern sound-source separation, not guaranteed sub-40 ms piano transcription.

**Implementation:** Use causal temporal regularization or historical activation estimates. Avoid centered smoothing requiring future samples. Test onset-aware regularization that permits abrupt attacks while stabilizing sustained notes. Verify that smoothing does not increase onset latency.

## 4. Harmonicity — Bertin et al. (2010)

**Source:** *Enforcing Harmonicity and Smoothness in Bayesian NMF Applied to Polyphonic Music Transcription.*

[Original paper](https://perso.telecom-paristech.fr/rbadeau/assets/bertin10.pdf)

**Principle:** Piano notes produce structured partials near integer multiples of their fundamental frequency. Unconstrained NMF may learn arbitrary, physically implausible spectral templates.

A simplified harmonic dictionary is:

\[
W_k(f)=\sum_{m=1}^{M}a_{k,m}G(f-mf_{0,k})
\]

Bertin et al. use a structured representation:

\[
W_k(f)=\sum_m e_{m,k}P_{k,m}(f)
\]

where \(P_{k,m}\) are predefined harmonic spectral patterns and \(e_{m,k}\) are learned coefficients.

Their Bayesian model additionally introduces temporal smoothness using an inverse-Gamma Markov-chain prior.

**Advantages:**
- Produces physically interpretable pitch templates.
- Helps distinguish notes with overlapping harmonics.
- Ensures representation of predefined pitches, including rarely played notes.

**Disadvantages:**
- Ideal harmonics do not perfectly represent piano-string inharmonicity.
- Hammer attacks contain broadband, nonstationary components.
- Bayesian parameter estimation is more computationally demanding.

**Evidence:** Bertin et al. reported improvements over benchmark NMF systems for polyphonic piano transcription when combining harmonicity and smoothness. However, smoothing alone could harm transients, and strict low-latency performance was not established.

**Implementation:** Initially preserve the existing NMF optimizer. Replace or augment \(W\) with harmonically structured piano-note templates, preferably calibrated using real recordings. Consider inharmonicity and separate attack templates.

## 5. Required Implementation and Evaluation

Implement the improvements as independent, configurable modules.

Compare baseline beta-NMF, each individual constraint, and combinations. Keep input audio, templates, evaluation thresholds, and test splits consistent.

Measure:
- Note-onset precision, recall, and F1.
- False positives and missed notes.
- Performance for isolated notes, triads, octaves, and dense chords.
- Accuracy across bass, middle, and treble registers.
- Processing time, actual acoustic-onset-to-output latency, and memory usage.

**Important:** Do not assume published offline F1 scores demonstrate reliable recognition within 40 ms. Report algorithmic lookahead, processing throughput, and actual detection latency separately.

Preserve the baseline implementation, document every mathematical modification, and produce an ablation table showing whether each constraint improves transcription accuracy or latency. Prefer a simple, verifiable implementation before introducing more complex optimization procedures.
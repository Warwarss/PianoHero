# Why a piano detector hears C5 when you play C4

Your odd/even observation is correct. In an ideal harmonic series, **C4's odd harmonics are evidence for C4. C4's even harmonics can come from either C4 or C5.** That gives us a method. Estimate how much C4 is present from its odd harmonics, predict how much of the shared spectrum that C4 should produce, then look for a coherent C5 pattern in what is left.

The difficult part is the word *should*. The answer depends on how accurately we know the balance between the odd and even harmonics of this particular C4 strike. I'll build up to that uncertainty, show how the current code handles it, and work through an octave-aware alternative by hand.

| Time | Read and work through |
|---|---|
| 0–12 min | Sections 1–2, from the microphone to the odd/even pattern |
| 12–27 min | Sections 3–4, templates and the false C5 calculation |
| 27–40 min | Section 5, how the Godot solver implements the math |
| 40–53 min | Sections 6–7, the odd/even detector and its limits |
| 53–60 min | Section 8, check your understanding |

## 1. What the microphone measures

Play C4. Your microphone measures air pressure changing over time. A digital recording is a list of samples of that pressure. At 44,100 samples per second, 50 milliseconds of audio contains 2,205 samples. In Godot, each microphone frame has two values, one per channel.

A pure tone is a sine wave. At 261.6 Hz, it oscillates 261.6 times per second, so one cycle lasts about 3.82 ms. A real note is more complicated. An idealized C4 signal can be written as a sum of sine waves.

$$
x(t)=a_1\sin(2\pi ft+\phi_1)
+a_2\sin(2\pi(2f)t+\phi_2)
+a_3\sin(2\pi(3f)t+\phi_3)+\cdots
$$

Here \(f\) is the fundamental frequency, \(a_n\) is the amplitude of harmonic \(n\), and \(\phi_n\) is its phase, the point in its cycle at time zero. The fundamental **is harmonic 1**. The first overtone is harmonic 2. Frequency tells us *where* a component appears. Amplitude tells us *how strong* it is. Two instruments can play the same pitch and produce very different balances of those amplitudes.

### From samples to a spectrum

The Fourier transform asks how much the signal resembles oscillations at different frequencies. The FFT is an efficient way to compute that transform. For each frequency bin, the FFT returns a complex number that carries magnitude and phase. Taking the absolute value leaves a magnitude for each bin.

In our code, a typical 50 ms recording window is averaged into 1,024 mono samples at an analysis rate of 20,480 samples per second. We apply a Hann window, which fades the edges of the 50 ms segment, before taking the FFT. The bin spacing is \(20{,}480/1{,}024=20\) Hz. The resulting array keeps 512 magnitude bins, zeros the DC bin, and applies a small weighting that increases with frequency.

You can read a spectrum like a bar chart. A tone at 261.6 Hz contributes most near the 260 Hz bin. A tone near 523.3 Hz contributes most near the 520 Hz bin. A real tone usually spreads over several nearby bins because we measured a finite window and the frequency may land between bin centers. An FFT peak tells us where the sound has energy. It carries no label for the key that produced it. [Godot spectral processing](chord_detector.gd#L114)

## 2. Which harmonics are shared?

Assume ideal strings, and let C4 have fundamental \(f\). C5, one octave higher, has fundamental \(2f\).

| Frequency | Harmonic of C4 | Harmonic of C5 |
|---:|---:|---:|
| \(f\) ≈ 262 Hz | 1 | |
| \(2f\) ≈ 523 Hz | 2 | 1 |
| \(3f\) ≈ 785 Hz | 3 | |
| \(4f\) ≈ 1,047 Hz | 4 | 2 |
| \(5f\) ≈ 1,308 Hz | 5 | |
| \(6f\) ≈ 1,570 Hz | 6 | 3 |
| \(7f\) ≈ 1,831 Hz | 7 | |
| \(8f\) ≈ 2,093 Hz | 8 | 4 |

C5's harmonic \(m\) lands at \(m(2f)=2mf\), which is C4 harmonic \(2m\). The index \(2m\) is always even. The blank cells are why your observation matters.

- If we see peaks at \(f,3f,5f\), C4 has evidence C5 cannot explain under this two-note model.
- If we see peaks at \(2f,4f,6f\), both candidates can explain those peaks.
- If C4 and C5 really are played together, C5 contributes primarily in the **shared** locations in this ideal model. Once we establish that C4 is present, the question becomes how much of the shared spectrum C4 accounts for.

With other keys in the chord, a peak in a C4 odd-harmonic region can have another source. For example, G5's fundamental is close to C4's third harmonic. The odd/even distinction is specific to an octave pair. A polyphonic detector has to check the rest of the chord too. [Multipitch estimation by summing harmonic amplitudes](https://www.ee.columbia.edu/~dpwe/papers/Klap06-multif0.pdf)

## 3. What a template is and how we use it

A template is a stored spectrum. Think of an array such as \([8,6,4,3]\) for an idealized C4, with each position corresponding to one of the first four C4 harmonic regions. This numbers the harmonic *regions* for illustration. The code uses a much longer array with regularly spaced FFT bins.

Each of the 88 keys gets a column in a matrix \(W\). The live spectrum is \(y\). The solver chooses a vector \(h\) of 88 gains. If C4 and C5 are the only active candidates, the model is

$$
\underbrace{y}_{\text{measured spectrum}}
\approx
\underbrace{h_4w_4+h_5w_5}_{\text{predicted spectrum}}.
$$

Here \(w_4\) means the C4 template, and \(w_5\) means the C5 template. The gains \(h_4,h_5\) are at least zero. A gain of zero contributes nothing. A gain of two doubles every component of its template. The same gain applies to the template's odd and even harmonics together.

For your piano, the learning step records several 50 ms windows of one isolated note. It skips the first five above-threshold updates, divides each captured spectrum by its largest bin, and averages the rest. This gives a representative *shape* for one strike. When building the dictionary, we drop learned bins below 2% of that template's peak and normalize the resulting column so its squared components sum to one.

Learned columns already reflect the tuning captured by the microphone. Unlearned keys use the generic Salamander templates, shifted according to the A4 setting. In a partially learned profile, the optimizer can fit a learned C4 and a generic C5 in the same window. [Learning code](../lab.gd#L182) · [Dictionary code](chord_detector.gd#L43) · [Template sources](SOURCES.md)

## 4. Walk through a false C5 with a calculator

Use two representative bins. Bin 1 is C4-only within the pair. Bin 2 is shared. Both template columns have length one.

| | C4-only bin | Shared bin |
|---|---:|---:|
| Saved C4, \(w_4\) | 0.8 | 0.6 |
| Saved C5, \(w_5\) | 0 | 1 |
| Live strike, \(y\) | 0.8 | 1.0 |

Suppose you played only C4. Its live shared bin is stronger than the saved C4 predicts. Maybe you hit the key harder, or this analysis window is at a different point in the strike. The solver sees the two numbers in \(y\), with no information about which key you physically pressed.

### First fit C4 alone

Try \(h_4=1\) and \(h_5=0\). The predicted spectrum is \([0.8,0.6]\). Subtract it from the live spectrum to get the **residual**, the part still unexplained.

$$
r=y-Wh=[0,\ 0.4].
$$

If we increase the C4 gain, both bins get stronger. We would improve the shared bin at the cost of overshooting the C4-only bin. If we increase the C5 gain, only the shared bin gets stronger in this example. The residual therefore offers the solver a reason to add C5.

### Now include the actual penalty

The code minimizes this objective for each window.

$$
J(h)=\frac12\sum_b\big(y_b-(Wh)_b\big)^2+\lambda\sum_j h_j,
\qquad h_j\ge0.
$$

- The first sum charges for errors in the bins. Squaring makes positive and negative errors both count.
- The second sum charges for the total gain. The fitter will add a note if the drop in squared error is worth the extra gain.

Before fitting the window, the code takes the dot product of each template with the measured spectrum. Multiply corresponding bins and add their products. This measures how much the live spectrum aligns with the template. In the example, C4 gives \(0.8(0.8)+0.6(1)=1.24\), and C5 gives \(0(0.8)+1(1)=1\). The penalty is 10% of the stronger score, so \(\lambda=0.124\).

Now calculate two candidate costs.

| Gains | Residual | Squared-error cost | Gain cost | Total |
|---|---|---:|---:|---:|
| \(h_4=1,\ h_5=0\) | \([0,0.4]\) | 0.0800 | 0.1240 | 0.2040 |
| \(h_4=1,\ h_5=0.3\) | \([0,0.1]\) | 0.0050 | 0.1612 | 0.1662 |

The two-key fit wins this comparison. Even if we give the one-key fit its best possible gain, \(h_4=1.24-0.124=1.116\), its cost is about 0.1973. The best two-key fit is approximately \((h_4,h_5)=(0.9225,0.3225)\). C5 reaches about 35% of C4's gain, clearing the code's 21% display threshold.

**The fitter can solve its math correctly and still report the wrong key.** Its objective rewards a good match to the measured spectrum. If the C4 template's shape is inaccurate for this strike, a combination of columns can fit better than the physical explanation. Octave insertions are a documented issue in fixed-template piano transcription. [Real-time piano NMF paper, Sections 3–4](https://archives.ismir.net/ismir2010/paper/000083.pdf)

## 5. Map the math to the Godot code

| Code | What it means |
|---|---|
| `_spectrum(frames)` | Builds the measured spectrum \(y\). |
| `configure(a4, personal_templates)` | Builds and normalizes the template columns \(w_j\). |
| `gains[key]` | The current value of \(h_j\). |
| `correlation[key]` at initialization | \(w_j^\top y\), the match against the original measurement. |
| `correlation[key]` after subtracting fitted contributions | \(w_j^\top(y-Wh)=w_j^\top r\), the match against the residual. |
| `gram[key][other]` | \(w_j^\top w_k\), how much two templates overlap. |
| `delta := maxf(-gains[key], correlation[key] - penalty)` | The change that best improves that one gain, clamped so the gain stays nonnegative. |
| `gains[key] <= 0.21 * peak` | Suppresses keys at or below 21% of the strongest fitted gain. It compares fitted amplitudes. |

### Why one update is a dot product minus the penalty

Hold every gain fixed except \(h_j\). If we change it by \(\delta\), the new residual is \(r-\delta w_j\). Because each column has length one, expanding the objective gives the change in cost.

$$
J(h+\delta e_j)-J(h)
= -\delta w_j^\top r+\frac12\delta^2+\lambda\delta.
$$

Here \(e_j\) is the vector that changes only gain \(j\). The three terms have simple meanings. The first is the benefit of moving toward the residual. The second charges for moving too far. The last is the extra gain cost. Differentiate with respect to \(\delta\) and set the derivative to zero.

$$
-w_j^\top r+\delta+\lambda=0
\quad\Longrightarrow\quad
\delta=w_j^\top r-\lambda.
$$

That is the expression in the code. The clamp \(\delta\ge-h_j\) stops the new gain from becoming negative. The solver looks at the proposed change for each key, takes the largest absolute change, and repeats for a maximum of 24 updates. The previous window's gains are the starting point.

### Why we store the Gram matrix

Suppose we add \(\delta w_{\mathrm{C4}}\) to the fit. The residual becomes \(r-\delta w_{\mathrm{C4}}\). The residual-match score of C5 changes by

$$
-\delta\,w_{\mathrm{C5}}^\top w_{\mathrm{C4}}.
$$

That inner product is already in the Gram matrix. The code can update every candidate score without rebuilding the whole residual spectrum after each gain change. A large dot product is exactly what you expect for templates with shared partials. It also means the two columns can trade off some gain with only a small change in the fit.

### Where the current octave rule comes in

After fitting the gains, the code applies a separate filter for weak candidates that line up with harmonics **3 through 10** of a lower reported key. C5 is about **2 times** C4, so it bypasses this filter. Including harmonic 2 would suppress some phantom C5s. It would also suppress some deliberately played soft C5s because both can produce a small gain. Your odd/even proposal provides evidence for deciding which case we have instead of using only a gain ratio. [Optimization and post-filter code](chord_detector.gd#L144)

## 6. Put your odd/even idea into an explicit detector

Consider just C4 and C5 and group the harmonic regions into two sets. \(O\) contains the odd-numbered C4 harmonics. \(E\) contains the even-numbered regions. Within this simplified pair, \(w_{5,O}\) is zero. Start by fitting C4 using only \(O\). Least squares gives

$$
\widehat h_4=
\max\!\left(0,\frac{w_{4,O}^\top y_O}{w_{4,O}^\top w_{4,O}}\right).
$$

The numerator measures the agreement in the odd regions. The denominator corrects for the strength of the selected part of the template. The whole template has unit length, but the odd part on its own usually does not. If the odd part has almost no measurable energy, we have weak evidence for this estimate. We would need to avoid dividing by a very small number and leave the pair uncertain.

Then predict the even regions and subtract.

$$
r_E=y_E-\widehat h_4w_{4,E}.
$$

Finally, check whether that **residual pattern across several regions** looks like C5. Here is one calculation with three odd and three even regions.

| | \(f,3f,5f\) | \(2f,4f,6f\) |
|---|---|---|
| C4 template | \([8,4,2]\) | \([6,3,2]\) |
| C5 template | \([0,0,0]\) | \([5,2,1]\) |
| Live measurement | \([8,4,2]\) | \([11,5,3]\) |

The odd region gives \(\widehat h_4=(64+16+4)/(64+16+4)=1\). Subtract C4's predicted even region and you get \([5,2,1]\). That is exactly the C5 template, so this model would infer a C5 gain of 1.

The important question is whether **your C4 alone could reasonably produce \([11,5,3]\)** while its odd harmonics stay at \([8,4,2]\). If it could, the same measurement admits both explanations. To make this test robust, we need to measure how much the even harmonics normally vary for C4 alone, and require extra C5 evidence beyond that variation.

One way to do this would be to capture C4 softly and firmly, including frames at the attack and later in the decay. Suppose a single C4 with the observed odd-harmonic levels normally produces a shared pattern between \([5,2,1]\) and \([8,4,3]\). The live \([11,5,3]\) then exceeds that range in two regions. This makes C5 more plausible. Use the expected C5 pattern as a whole when judging those deviations, since one oversized peak has many possible explanations. These ranges are illustrative, not measurements of your piano.

## 7. Where this helps and where we still need evidence

**One spectrum has a real ambiguity.** Let \(u\) be a possible change to C4's even harmonics, with zeros in its odd regions. The observation

$$
y=h_4w_4+u
$$

looks exactly like a C4+C5 mixture if \(u=h_5w_5\) in the ideal model. The spectrum by itself cannot distinguish those explanations. Odd harmonics anchor the lower key. The decision about the upper key depends on the expected shape and variability of the shared regions.

**Real piano partials can differ slightly in frequency.** Stiff strings have inharmonicity, so the \(n\)th partial need not sit exactly at \(nf\). C4's second partial and C5's fundamental can also differ due to how the piano is tuned. Those offsets may provide extra evidence when they are large enough to resolve. With our current 50 ms FFT, peaks a few hertz apart can spread across largely the same bins. The code's templates can reflect some recorded differences, but this analysis has limited ability to separate close peaks directly. [Fletcher's measurements of piano-string inharmonicity](https://pubs.aip.org/asa/jasa/article-abstract/24/3/267/660100/Inharmonicity-of-Plain-Wire-Piano-Strings)

**Waveforms add exactly. FFT magnitudes generally add only approximately.** If two sources have complex FFT coefficients \(X_4\) and \(X_5\) at one bin, the mixture's magnitude is \(|X_4+X_5|\). Two equal coefficients with the same phase reinforce each other. With opposite phases they can cancel. The NMF model adds *magnitudes* using \(Wh\), which is an approximation. The difference is most relevant where partials overlap. [NMF paper, Section 4.1](https://archives.ismir.net/ismir2010/paper/000083.pdf)

**Time gives us another clue.** Play C4 and let it ring. Then strike C5. If the even regions jump together while the C4 odd regions continue their previous decay, that favors a new C5 strike. If you play the two keys simultaneously, that clue is weaker because all the regions rise together. The current solver starts with the previous gains for speed, but its objective has no model of an independent hammer strike. An analysis of changes between windows would add information the current fit does not explicitly use.

For the octave problem in this project, I would use the current NMF to propose candidates and then check suspicious octave pairs. Estimate C4 from regions where C5 contributes little, account for known other notes, and ask whether the shared residual is supported by several C5 partials or a fresh attack. This keeps a real octave playable while targeting the specific error you heard.

## 8. Check your understanding

Try these on paper before opening the answers. Use ideal strings unless stated otherwise.

1. C4 produces a peak around 1,570 Hz. Which harmonic of C4 is it? Which harmonic of C5 could also explain it? What would a nearby peak around 1,308 Hz tell you?
2. A learned C4 template has odd-region values \([4,2]\) and even-region values \([3,1]\). A live frame has odd values \([8,4]\) and even values \([8,3]\). Compute the lower-note gain and the even residual. What further information do you need before claiming C5?
3. Use the two-bin example from Section 4 with \(h_4=1\) and \(h_5=0\). Compute the C5 coordinate update using \(\lambda=0.124\). If C4's gain stays at 1 for this update, does C5 clear the 21% display threshold?
4. If we add C5 to the harmonic filter and the phantom disappears, what recording would you use to check whether the change also removed a real note?
5. Suppose C4 alone produces the same spectrum as a different C4 strike plus a soft C5 in one window. What new evidence could distinguish the cases?

<details>
<summary>Worked answers</summary>

1. About 1,570 Hz is C4 harmonic 6 and C5 harmonic 3. About 1,308 Hz is C4 harmonic 5, which supports C4 over C5 in the octave pair. A different key can still contribute there in a larger chord.
2. The odd values are twice the template values, so \(\widehat h_4=2\). Predicted even values are \([6,2]\), leaving \([2,1]\). Compare this residual with a C5 template, and measure whether such deviations are common for C4 alone.
3. The C5 column is \([0,1]\), so its dot product with the residual \([0,0.4]\) is 0.4. Subtract 0.124 to get a gain increase of 0.276. With C4 still at 1, C5 is at 27.6%, which clears the threshold. Further solver steps may change both gains.
4. Use C4 plus a quiet real C5. Record simultaneous strikes and a C5 added after C4 starts ringing. Count how often C5 is missed as well as how often it appears for C4 alone.
5. A separate change in the shared regions when C5 is struck can help, as can resolvable differences in partial frequencies or templates measured at more than one playing force. If the two cases yield the same available observations, the detector has no basis for choosing between them.

</details>

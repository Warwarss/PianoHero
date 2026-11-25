"""Cheng et al. (ISMIR 2016) supervised attack/decay piano transcription.

Arrays use [frequency, time], [frequency, pitch], or [pitch, time].
Time zero is the centre of the first analysis window.
"""
from contextlib import nullcontext
from dataclasses import dataclass

import numpy as np

try:
    from threadpoolctl import threadpool_limits
except ImportError:
    threadpool_limits = None


RATE = 44100
WINDOW = 4096
FFT = 8192
HOP = 882
STEP = HOP / RATE
RADIUS = WINDOW // HOP
ITERATIONS = 50
EPS = 1e-20


def _blas():
    return threadpool_limits(limits=1, user_api="blas") if threadpool_limits else nullcontext()


def normalize_calibration(audio, rate, onset):
    """Apply one gain to the whole clip, using the first 250 ms of the note."""
    if not 0 <= onset < audio.size or rate <= 0:
        raise ValueError("Invalid calibration onset or sample rate")
    attack = audio[onset:onset + max(1, round(0.25 * rate))]
    level = np.quantile(np.abs(attack), 0.99)
    if not np.isfinite(level) or level <= EPS:
        raise ValueError("No usable signal after the calibration onset")
    # A percentile ignores isolated spikes. Keep the lead-in, transient and
    # tail at their original relative levels, even if a sample exceeds 1.
    return audio * (0.5 / level)


def analyze_microphone(audio, rate, bank, attack_ms=20.0, spectral_ms=40.0):
    """Require audible input near a fitted strike before reporting it."""
    hop = max(1, round(rate * 0.020))
    frame_count = len(audio) // hop
    if frame_count < 2:
        return []
    frames = audio[:frame_count * hop].reshape(frame_count, hop)
    rms = np.sqrt(np.mean(frames ** 2, axis=1))
    floor, upper = np.quantile(rms, [0.25, 0.90])
    threshold = 10 ** (-55 / 20)
    # Use the lower quartile as room noise when it is quiet or levels are
    # steady. In a loud, varied phrase it can include actual piano notes.
    if floor <= 10 ** (-45 / 20) or upper <= 2 * floor:
        threshold = max(threshold, 2 * floor)
    audible = rms >= threshold
    sustained = audible[:-1] & audible[1:]
    if not sustained.any():
        return []

    events = analyze(audio, rate, bank, confirmation_ms=(attack_ms, spectral_ms))
    accepted = []
    for event in events:
        frame = round(event["onset"] * rate / hop)
        # The fitted attack peak can land a few frames after the key strike.
        if sustained[max(0, frame - 3):frame + 3].any():
            accepted.append(event)
    return accepted


def spectrogram(audio, sr):
    """Mono magnitude STFT followed by the 100-ms temporal median."""
    wave = np.asarray(audio, dtype=np.float32)
    if wave.ndim != 1 or not wave.size or not np.all(np.isfinite(wave)):
        raise ValueError("Expected nonempty finite mono audio")
    if sr <= 0 or int(sr) != sr:
        raise ValueError("Expected a positive integer sample rate")
    if sr != RATE:
        wave = _resample(wave, int(sr))
    padded = np.pad(wave, (WINDOW // 2, WINDOW // 2 - 1))
    frames = np.lib.stride_tricks.sliding_window_view(padded, WINDOW)[::HOP]
    window = np.hamming(WINDOW).astype(np.float32)
    magnitude = np.abs(np.fft.rfft(frames * window, n=FFT, axis=1)).astype(np.float32)
    padded = np.pad(magnitude, ((2, 2), (0, 0)), mode="edge")
    windows = np.lib.stride_tricks.sliding_window_view(padded, 5, axis=0)
    return np.ascontiguousarray(np.median(windows, axis=-1).T)


@dataclass
class Bank:
    midi: np.ndarray
    attack: np.ndarray
    decay: np.ndarray
    alpha: np.ndarray
    pattern: np.ndarray

    def __post_init__(self):
        self.midi = np.asarray(self.midi)
        for name in ("attack", "decay", "alpha", "pattern"):
            value = np.ascontiguousarray(getattr(self, name), dtype=np.float32)
            if not np.all(np.isfinite(value)) or np.any(value < 0):
                raise ValueError(f"Invalid {name} values")
            setattr(self, name, value)
        if self.midi.ndim != 1 or not self.midi.size or not np.issubdtype(self.midi.dtype, np.integer):
            raise ValueError("Expected integer MIDI pitches")
        if len(np.unique(self.midi)) != self.midi.size or np.any((self.midi < 0) | (self.midi > 127)):
            raise ValueError("Invalid MIDI pitches")
        if self.attack.shape != (FFT // 2 + 1, self.midi.size) or self.decay.shape != self.attack.shape:
            raise ValueError("Invalid template dimensions")
        if self.alpha.shape != self.midi.shape or self.pattern.shape != (2 * RADIUS + 1,):
            raise ValueError("Invalid envelope dimensions")

    def save(self, path):
        np.savez_compressed(path, midi=self.midi, attack=self.attack, decay=self.decay,
                            alpha=self.alpha, pattern=self.pattern)

    @classmethod
    def load(cls, path):
        with np.load(path, allow_pickle=False) as data:
            return cls(*(data[key] for key in ("midi", "attack", "decay", "alpha", "pattern")))


def _fit_pitch(x, lag, pattern, learn_pattern, rng, iterations):
    """Fixed unit onset impulses. Concatenated takes retain independent boundaries via lag."""
    attack = np.ones(x.shape[0])
    decay = rng.random(x.shape[0]) + EPS
    alpha = 1.0
    pattern = pattern.copy()
    valid = np.abs(lag) <= RADIUS
    indices = lag[valid] + RADIUS
    counts = np.bincount(indices, minlength=len(pattern))
    after = lag >= 0
    attack_env = np.zeros(lag.size)
    decay_env = np.zeros(lag.size)
    def observed_ratio():
        estimate = attack[:, None] * attack_env + decay[:, None] * decay_env
        return x / np.maximum(estimate, EPS)

    for _ in range(iterations):
        attack_env[valid] = pattern[indices]
        decay_env[after] = np.exp(-alpha * lag[after])
        # Alternate multiplicative updates and reconstruct after each parameter.
        ratio = observed_ratio()
        decay *= np.einsum("ft,t->f", ratio, decay_env) / max(decay_env.sum(), EPS)
        ratio = observed_ratio()
        attack *= np.einsum("ft,t->f", ratio, attack_env) / max(attack_env.sum(), EPS)
        ratio = observed_ratio()
        weighted_lag = np.maximum(lag, 0) * decay_env
        decay_projection = np.einsum("f,ft->t", decay, ratio)
        numerator = decay.sum() * weighted_lag.sum()
        denominator = decay_projection @ weighted_lag
        if denominator > EPS:
            alpha *= numerator / denominator
        if learn_pattern:
            decay_env[after] = np.exp(-alpha * lag[after])
            # P affects only frames within its support.
            estimate = attack[:, None] * attack_env[valid] + decay[:, None] * decay_env[valid]
            ratio = x[:, valid] / np.maximum(estimate, EPS)
            attack_projection = np.einsum("f,ft->t", attack, ratio)
            numer = np.bincount(indices, weights=attack_projection, minlength=len(pattern))
            denom = counts * attack.sum()
            pattern *= np.divide(numer, denom, out=np.ones_like(numer), where=denom > EPS)
            pattern /= max(pattern.max(), EPS)
    return attack, decay, alpha, pattern


def train(notes, *, iterations=ITERATIONS, seed=0):
    """Train both rounds using (MIDI pitch, mono float waveform, Hz, onset seconds)."""
    grouped = {}
    for midi, wave, sr, onset in notes:
        if not np.isfinite(onset) or not 0 <= onset < len(wave) / sr:
            raise ValueError("Training onset outside recording")
        x = spectrogram(wave, sr)
        if x.max() <= EPS:
            raise ValueError(f"Silent training note {midi}")
        lag = np.arange(x.shape[1]) - int(np.floor(onset / STEP + 0.5))
        grouped.setdefault(midi, []).append((x, lag))
    if not grouped or iterations < 1:
        raise ValueError("Expected training notes and a positive iteration count")
    midi = np.array(sorted(grouped))
    data = [(np.concatenate([x for x, _ in grouped[k]], axis=1),
             np.concatenate([lag for _, lag in grouped[k]])) for k in midi]
    del grouped
    rng = np.random.default_rng(seed)
    with _blas():
        initial = np.ones(2 * RADIUS + 1)
        patterns = [_fit_pitch(x, lag, initial, True, rng, iterations)[3] for x, lag in data]
        shared = np.mean(patterns, axis=0)
        fits = [_fit_pitch(x, lag, shared, False, rng, iterations) for x, lag in data]
    return Bank(midi, np.column_stack([f[0] for f in fits]), np.column_stack([f[1] for f in fits]),
                np.array([f[2] for f in fits]), shared)


def _decay_filter(values, alpha):
    # Exact causal exponential convolution, including the full past (Eq. 4).
    rate = np.exp(-alpha)
    out = values.copy()
    for t in range(1, values.shape[1]):
        out[:, t] += rate * out[:, t - 1]
    return out


def _attack_filter(values, pattern):
    radius = len(pattern) // 2
    padded = np.pad(values, ((0, 0), (radius, radius)))
    windows = np.lib.stride_tricks.sliding_window_view(padded, len(pattern), axis=1)
    return np.einsum("ktp,p->kt", windows, pattern[::-1])


def _average(row, length, mode):
    padded = np.pad(row, (length // 2, (length - 1) // 2), mode=mode)
    return np.convolve(padded, np.ones(length) / length, mode="valid")


def _resample(wave, sr):
    """Bandlimited sample-rate conversion using a Kaiser-windowed sinc FIR."""
    cutoff = min(1.0, RATE / sr)
    radius = int(np.ceil(16 / cutoff))
    taps = np.arange(-radius, radius + 1)
    output = np.empty(int(np.ceil(len(wave) * RATE / sr)), dtype=np.float32)
    for start in range(0, len(output), 4096):
        stop = min(start + 4096, len(output))
        # Reuse identical filter phases, e.g. only 147 phases at 48 kHz.
        centres, remainder = np.divmod(np.arange(start, stop, dtype=np.int64) * sr, RATE)
        phases, inverse = np.unique(remainder, return_inverse=True)
        distance = phases[:, None] / RATE - taps
        kernel = cutoff * np.sinc(cutoff * distance)
        window = np.sqrt(np.maximum(0.0, 1.0 - (distance / radius) ** 2))
        kernel *= np.i0(8.6 * window) / np.i0(8.6)
        kernel *= np.abs(distance) <= radius
        indices = centres[:, None] + taps
        kernel = kernel[inverse] * ((indices >= 0) & (indices < len(wave)))
        samples = wave[np.clip(indices, 0, len(wave) - 1)]
        output[start:stop] = (kernel * samples).sum(axis=1) / kernel.sum(axis=1)
    return output


def activations(x, bank, *, iterations=ITERATIONS, gamma_end=1.04, seed=0):
    """Return H, Ha, Hd and reconstructed V; fit H with templates held fixed."""
    if iterations < 1:
        raise ValueError("Expected a positive iteration count")
    h = np.random.default_rng(seed).random((len(bank.midi), x.shape[1]), dtype=np.float32)
    # The adjoint of a causal decay filter runs backward in time; both
    # denominators account for partial kernels at the recording edges.
    def adjoint(attack, decay):
        return (_attack_filter(attack, bank.pattern[::-1])
                + _decay_filter(decay[:, ::-1], bank.alpha)[:, ::-1])

    ones = np.ones_like(h)
    denominator = adjoint(bank.attack.sum(axis=0)[:, None] * ones,
                          bank.decay.sum(axis=0)[:, None] * ones)
    with _blas():
        for gamma in np.linspace(1.0, gamma_end, iterations):
            ha = _attack_filter(h, bank.pattern)
            hd = _decay_filter(h, bank.alpha)
            estimate = bank.attack @ ha + bank.decay @ hd
            ratio = x / np.maximum(estimate, EPS)
            h *= adjoint(bank.attack.T @ ratio, bank.decay.T @ ratio) / np.maximum(denominator, EPS)
            np.power(h, gamma, out=h)
        ha = _attack_filter(h, bank.pattern)
        hd = _decay_filter(h, bank.alpha)
        return h, ha, hd, bank.attack @ ha + bank.decay @ hd


def _peaks(row, threshold):
    # Zero padding includes onset candidates on the recording boundaries.
    # Collapse flat-topped local maxima to their midpoint.
    edges = np.r_[0, np.flatnonzero(np.diff(row) != 0) + 1, len(row)]
    levels = np.pad(row[edges[:-1]], 1)
    maxima = np.flatnonzero((levels[1:-1] > levels[:-2]) & (levels[1:-1] > levels[2:]))
    peaks = (edges[maxima] + edges[maxima + 1] - 1) // 2
    baseline = _average(row, 20, "constant")
    pairs = [(float(p), float(row[p])) for p in peaks if row[p] > baseline[p] + threshold]
    for _ in range(2):
        merged = []
        i = 0
        while i < len(pairs):
            t, a = pairs[i]
            if i + 1 < len(pairs) and (pairs[i + 1][0] - t) * STEP < 0.1:
                s, b = pairs[i + 1]
                t, a = (t * a + s * b) / (a + b), a + b
                i += 1
            merged.append((t, a))
            i += 1
        pairs = merged
    return pairs


def _states(cost):
    """Backtrack the two-state minimum-cost path, equations 11–13."""
    weights = np.array([[0.50, 0.55], [0.55, 0.50]])
    total = cost[:, 0]
    previous = np.zeros(cost.shape, dtype=np.int8)
    states = np.zeros(cost.shape[1], dtype=np.int8)
    for t in range(1, cost.shape[1]):
        paths = total[:, None] + weights * cost[:, t]
        previous[:, t] = paths.argmin(axis=0)
        total = paths.min(axis=0)
    states[-1] = total.argmin()
    for t in range(len(states) - 1, 0, -1):
        states[t - 1] = previous[states[t], t]
    return states


def _kl(x, estimate):
    estimate = np.maximum(estimate, EPS)
    divergence = x * (np.log(np.maximum(x, EPS)) - np.log(estimate)) - x + estimate
    return np.maximum(divergence, 0).sum(axis=0, dtype=np.float64)


def analyze(audio, sr, bank, *, iterations=ITERATIONS, gamma_end=1.04, threshold_db=-30.0,
            confirmation_ms=None):
    """Extract sorted note events; strength is the summed attack-peak amplitude."""
    x = spectrogram(audio, sr)
    if x.max() <= EPS:
        return []
    _, ha, hd, estimate = activations(x, bank, iterations=iterations, gamma_end=gamma_end)
    threshold = 10 ** (threshold_db / 20) * ha.max()
    cost_on = _kl(x, estimate)
    events = []
    duration = len(audio) / sr
    if confirmation_ms is not None:
        attack_frames, spectral_frames = (1 + int(np.ceil(ms / (1000 * STEP))) for ms in confirmation_ms)
    for k, midi in enumerate(bank.midi):
        peaks = _peaks(ha[k], threshold)
        if not peaks:
            continue
        if confirmation_ms is not None:
            baseline = _average(ha[k], 20, "constant")
        contribution = bank.attack[:, k, None] * ha[k] + bank.decay[:, k, None] * hd[k]
        cost_off = _kl(x, estimate - contribution)
        costs = np.stack([cost_off, cost_on])
        total = costs.sum(axis=0)
        costs = np.divide(costs, total, out=np.full_like(costs, 0.5), where=total > EPS)
        evidence = costs[0] - costs[1]
        gap = np.pad(evidence, (5, 4), mode="edge")
        difference = np.abs(np.median(np.lib.stride_tricks.sliding_window_view(gap, 10), axis=1))
        for i, (time, strength) in enumerate(peaks):
            start = int(np.floor(time + 0.5))
            end = int(np.floor(peaks[i+1][0] + 0.5)) if i+1 < len(peaks) else x.shape[1]
            if confirmation_ms is not None:
                # Merging peaks can put the weighted onset between attack frames.
                left, right = max(0, start - 1), min(end, start + 2)
                anchor = left + int(np.argmax(ha[k, left:right]))
                support = (ha[k] > baseline + threshold) & (ha[k] >= 0.50 * ha[k, anchor])
                if not any(support[a:a + attack_frames].all()
                           for a in range(max(0, anchor - attack_frames + 1),
                                          min(anchor, end - attack_frames) + 1)):
                    continue
                if not any((evidence[a:a + spectral_frames] >= 0.05).all()
                           for a in range(left, min(start + 2, end - spectral_frames) + 1)):
                    continue
            quiet = np.flatnonzero(difference[start+1:end] < 0.05)
            if quiet.size:
                end = start + 1 + quiet[0]
            states = _states(costs[:, start:end])
            active = np.flatnonzero(states)
            if active.size:
                # End of the first contiguous active run associated with this onset.
                off = np.flatnonzero(states[active[0]:] == 0)
                if off.size:
                    end = start + active[0] + off[0]
            else:
                end = start + 1
            offset = min(end * STEP, duration)
            events.append(dict(midi=int(midi), onset=time * STEP, offset=float(offset), strength=strength))
    return sorted(events, key=lambda event: (event["onset"], event["midi"]))

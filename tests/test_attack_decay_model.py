"""Numerical regression checks for the paper's convolution, DP and training pipeline."""
import itertools
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from chord.attack_decay import model


class TestAttackDecay(unittest.TestCase):
    def test_strike_needs_consecutive_attack_and_spectral_frames(self):
        bins = model.FFT // 2 + 1
        template = np.ones((bins, 1), dtype=np.float32)
        bank = model.Bank(np.array([60]), template, template, np.array([0.1]),
                          np.ones(2 * model.RADIUS + 1))
        audio = np.zeros(model.RATE, dtype=np.float32)
        for attack_bins, spectral_bins in [(1, 4), (2, 2), (2, 4)]:
            attack = np.zeros((1, 20), dtype=np.float32)
            attack[0, 4:4 + attack_bins] = 1
            decay = np.zeros_like(attack)
            decay[0, 4:4 + spectral_bins] = 1
            estimate = np.zeros((bins, 20), dtype=np.float32)
            estimate[:, 4:4 + spectral_bins] = 1
            with patch.object(model, "spectrogram", return_value=estimate), patch.object(
                    model, "activations", return_value=(attack, attack, decay, estimate)):
                events = model.analyze(audio, model.RATE, bank, confirmation_ms=(20, 40))
            self.assertEqual([event["midi"] for event in events],
                             [60] if (attack_bins, spectral_bins) == (2, 4) else [])

    def test_microphone_gate_rejects_stationary_noise_and_quiet_events(self):
        rate = 44100
        noise = np.random.default_rng(3).normal(0, 0.008, rate)
        with patch.object(model, "analyze") as fit:
            self.assertEqual(model.analyze_microphone(noise, rate, None), [])
            fit.assert_not_called()
        take = noise * 0.05
        tone_time = np.arange(rate // 5) / rate
        take[rate // 5:2 * rate // 5] += 0.004 * np.sin(2 * np.pi * 260 * tone_time)
        with patch.object(model, "analyze", return_value=[{"onset": 0.24}, {"onset": 0.80}]):
            self.assertEqual(model.analyze_microphone(take, rate, None), [{"onset": 0.24}])

    def test_calibration_normalization_preserves_relative_envelope(self):
        rate = 44100
        t = np.arange(rate) / rate
        onset = rate // 5
        audio = np.sin(2 * np.pi * 440 * t) * np.exp(-5 * t)
        expected = model.normalize_calibration(audio, rate, onset)
        np.testing.assert_allclose(model.normalize_calibration(0.2 * audio, rate, onset), expected)
        gain = expected[100] / audio[100]
        np.testing.assert_allclose(expected, gain * audio)
        with self.assertRaises(ValueError):
            model.normalize_calibration(np.zeros_like(audio), rate, onset)

    def test_published_stft_and_temporal_median(self):
        sr = 44100
        audio = np.random.default_rng(7).normal(size=8500).astype(np.float32)
        received = model.spectrogram(audio, sr)
        self.assertEqual(received.shape, (4097, 10))
        # Independent reference for an interior frame, including the exact
        # taper, centering, magnitude convention, FFT padding and median axis.
        taper = 0.54 - 0.46 * np.cos(2 * np.pi * np.arange(4096) / 4095)
        spectra = []
        for frame in range(3, 8):
            start = 882 * frame - 2048
            spectra.append(np.abs(np.fft.rfft(audio[start:start + 4096] * taper, n=8192)))
        np.testing.assert_allclose(received[:, 5], np.median(spectra, axis=0), atol=1e-5, rtol=1e-6)

    def test_temporal_operators_and_adjoints_at_edges(self):
        rng = np.random.default_rng(4)
        h = rng.random((3, 14))
        y = rng.random(h.shape)
        alpha = np.array([0.03, 0.1, 1.0])
        pattern = rng.random(2 * model.RADIUS + 1)
        attack = model._attack_filter(h, pattern)
        decay = model._decay_filter(h, alpha)
        for k in range(len(alpha)):
            np.testing.assert_allclose(attack[k], np.convolve(h[k], pattern, mode="same"))
            kernel = np.exp(-alpha[k] * np.arange(h.shape[1]))
            np.testing.assert_allclose(decay[k], np.convolve(h[k], kernel)[:h.shape[1]])
        adjoint = (model._attack_filter(y, pattern[::-1]) +
                   model._decay_filter(y[:, ::-1], alpha)[:, ::-1])
        self.assertAlmostEqual(np.sum((attack + decay) * y), np.sum(h * adjoint))

    def test_offset_path_minimizes_equation_11(self):
        costs = np.array([[0.8, 0.6, 0.1, 0.2, 0.9], [0.2, 0.4, 0.9, 0.8, 0.1]])
        def path_cost(path):
            total = costs[path[0], 0]
            for t in range(1, len(path)):
                total += costs[path[t], t] * (0.5 if path[t] == path[t-1] else 0.55)
            return total
        best = min(itertools.product((0, 1), repeat=5), key=path_cost)
        np.testing.assert_array_equal(model._states(costs), best)

    def test_two_round_training_chord_and_bank_roundtrip(self):
        sr = 22050
        time = np.arange(sr) / sr
        since = np.maximum(time - 0.16, 0)
        def note(hz):
            return (np.sin(2*np.pi*hz*since) + 0.15*np.sin(4*np.pi*hz*since)) * np.exp(-3*since)
        a, b = note(440), note(523.25)
        bank = model.train([(69, a, sr, 0.16), (72, b, sr, 0.16)])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bank.npz"
            bank.save(path)
            bank = model.Bank.load(path)
        result = model.analyze(a+b, sr, bank)
        self.assertEqual(sorted(event["midi"] for event in result), [69, 72])
        for event in result:
            self.assertLess(abs(event["onset"] - 0.16), 0.05)
            self.assertGreater(event["offset"], 0.7)
        self.assertEqual(model.analyze(np.zeros(300), sr, bank), [])


if __name__ == "__main__":
    unittest.main()

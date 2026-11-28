// Input: 44.1 kHz mono float32 little-endian files (first three seconds).
// See chord/SOURCES.md for names and sources. Run from the project root.
import fs from 'node:fs';
import path from 'node:path';

const input = process.argv[2];
const size = 1024;
const fftSize = 2 * size;
const rate = 20480;
const sourceRate = 44100;
const read = name => {
  const data = fs.readFileSync(path.join(input, name));
  return new Float32Array(data.buffer, data.byteOffset, data.length / 4);
};
function interpolate(samples, pos) {
  const left = Math.floor(pos);
  return (samples[left] ?? 0) * (1 - (pos - left)) + (samples[left + 1] ?? 0) * (pos - left);
}
function onset(samples) {
  const peak = samples.reduce((p, x) => Math.max(p, Math.abs(x)), 0);
  if (peak === 0) throw new Error('Silent source');
  return samples.findIndex(x => Math.abs(x) > peak * 0.012);
}
const cos = [], sin = [];
for (let i = 0; i < fftSize; i++) {
  cos.push(Math.cos(2 * Math.PI * i / fftSize));
  sin.push(Math.sin(2 * Math.PI * i / fftSize));
}
function besselI0(x) {
  let sum = 1;
  let term = 1;
  for (let order = 1; order <= 12; order++) {
    term *= (x / (2 * order)) ** 2;
    sum += term;
  }
  return sum;
}

function buildTemplates(windowAt, output) {
  const taper = Array.from({length: size}, (_, i) => windowAt(i / size));
  const templates = Buffer.alloc(88 * fftSize / 2);
  for (let midi = 21; midi <= 108; midi++) {
    const anchor = 21 + 3 * Math.round((midi - 21) / 3);
    const source = read(anchor + '.mp3.f32');
    const start = onset(source);
    const speed = sourceRate / rate * 2 ** ((midi - anchor) / 12);
    const spectrum = new Float64Array(fftSize / 2);
    for (const seconds of [0.015, 0.045, 0.085, 0.14, 0.22]) {
      const frame = taper.map((w, i) => w * interpolate(source, start + (seconds * rate + i) * speed));
      for (let bin = 1; bin < spectrum.length; bin++) {
        let x = 0, y = 0;
        for (let i = 0; i < size; i++) {
          const angle = (bin * i) % fftSize;
          x += frame[i] * cos[angle];
          y += frame[i] * sin[angle];
        }
        spectrum[bin] += Math.hypot(x, y);
      }
    }
    // Remove broadband hammer noise and room rumble from pitched templates.
    // Leave room on the sharp side of higher partials for piano inharmonicity.
    const f0 = 440 * 2 ** ((midi - 69) / 12);
    const binHz = rate / fftSize;
    const windowHz = rate / size;
    for (let b = 0; b < spectrum.length; b++) {
      const hz = b * binHz;
      const partial = Math.max(1, Math.round(hz / f0));
      const distance = hz - partial * f0;
      if (distance < -1.7 * windowHz - 0.006 * hz || distance > 1.7 * windowHz + 0.02 * hz)
        spectrum[b] = 0;
    }
    const peak = Math.max(...spectrum);
    // Blend a modest harmonic prior with the measured spectrum. A deep notch
    // at the fundamental on one piano should not imply the same on all pianos.
    for (let b = 1; b < spectrum.length; b++) {
      const harmonic = Math.max(1, Math.round(b * binHz / f0));
      const distance = (b * binHz - harmonic * f0) / windowHz;
      const prior = Math.exp(-distance * distance / 0.95) / harmonic;
      spectrum[b] = 0.72 * spectrum[b] / peak + 0.28 * prior;
    }
    const scale = Math.max(...spectrum);
    for (let i = 0; i < spectrum.length; i++)
      templates[(midi - 21) * spectrum.length + i] = Math.round(255 * Math.sqrt(spectrum[i] / scale));
  }
  fs.writeFileSync(output, '[gd_resource type="Resource" format=3]\n\n[resource]\nmetadata/spectra = PackedByteArray("' + templates.toString('base64') + '")\n');
}

buildTemplates(x => 0.5 - 0.5 * Math.cos(2 * Math.PI * x), 'chord/templates/templates.tres');
buildTemplates(x => 0.54 - 0.46 * Math.cos(2 * Math.PI * x), 'chord/templates/templates_hamming.tres');
buildTemplates(x => 0.42 - 0.5 * Math.cos(2 * Math.PI * x) + 0.08 * Math.cos(4 * Math.PI * x), 'chord/templates/templates_blackman.tres');
const kaiserShape = 4;
const kaiserCenter = besselI0(kaiserShape);
buildTemplates(x => besselI0(kaiserShape * Math.sqrt(1 - (2 * x - 1) ** 2)) / kaiserCenter, 'chord/templates/templates_kaiser4.tres');

// Independent MS Basic recordings. Its available anchors span B1–C#6,
// so the two extreme-register fixtures use transposed recordings.
const anchors = [35, 38, 43, 48, 52, 55, 57, 59, 60, 62, 64, 67, 69, 71, 72, 76, 79, 80, 83, 85];
// Each voice is [MIDI, relative amplitude, start time in seconds].
const cases = [
  [[60, 1, 0]], [[60, 1, 0], [67, 0.8, 0]],
  [[60, 1, 0], [64, 0.45, 0], [67, 0.85, 0]],
  [[60, 1, 0], [72, 0.7, 0]],
  [[60, 1, -0.15], [64, 0.7, 0], [67, 0.8, 0]],
  [[21, 1, 0], [22, 0.85, 0]], [[108, 1, 0]]
];
const wavRate = 22050;
const segment = wavRate;
const lead = 0.25;
const duration = 0.5;
const mix = new Float32Array(segment * cases.length);
for (const [n, voices] of cases.entries()) {
  for (const [key, gain, delay] of voices) {
    const anchor = anchors.reduce((a, b) => Math.abs(b - key) < Math.abs(a - key) ? b : a);
    const source = read('mf-' + anchor + '.ogg.f32');
    const first = onset(source);
    const peak = source.reduce((p, x) => Math.max(p, Math.abs(x)), 0);
    const speed = sourceRate / wavRate * 2 ** ((key - anchor) / 12);
    const start = Math.round((lead + delay) * wavRate);
    const length = Math.round((duration - delay) * wavRate);
    for (let i = 0; i < length; i++) {
      const fade = Math.min(1, (length - i) / (wavRate * 0.02));
      mix[n * segment + start + i] += gain * fade * interpolate(source, first + i * speed) / peak;
    }
  }
}
const wav = Buffer.alloc(44 + mix.length * 2);
wav.write('RIFF'); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8);
wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
wav.writeUInt32LE(wavRate, 24); wav.writeUInt32LE(2 * wavRate, 28);
wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write('data', 36);
wav.writeUInt32LE(mix.length * 2, 40);
for (let i = 0; i < mix.length; i++) wav.writeInt16LE(Math.round(11000 * mix[i]), 44 + 2 * i);
fs.writeFileSync('chord/templates/replay.wav', wav);

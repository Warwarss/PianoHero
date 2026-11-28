extends RefCounted
## Online fixed-dictionary NMF. Each 50 ms spectrum is fitted as W * h,
## where W contains measured piano spectra and h contains nonnegative gains.

const MusicUtils := preload("res://audio/music_utils.gd")
const BANKS := [
	preload("res://chord/templates/templates.tres"),
	preload("res://chord/templates/templates_hamming.tres"),
	preload("res://chord/templates/templates_blackman.tres"),
	preload("res://chord/templates/templates_kaiser4.tres"),
]
const KAISER_SHAPE := 4.0
const FRAME_SIZE := 1024
const FFT_SIZE := FRAME_SIZE * 2
const BINS := FFT_SIZE >> 1
const RATE := 20480.0
const WINDOW_SECONDS := FRAME_SIZE / RATE
const HOP_SECONDS := 0.010
const KEYS := MusicUtils.KEYS
const FIRST_KEY := MusicUtils.FIRST_KEY
const BETA_UPDATES := 12
const GATE_DB := MusicUtils.GATE_DB
const OCTAVE_SEMITONES := 12
const SOFT_OCTAVE_GAIN_RATIO := 0.10
const SOFT_OCTAVE_CONFIRMATIONS := 3

enum Taper { HANN, HAMMING, BLACKMAN, KAISER_4 }

var permutation := PackedInt32Array()
var tapers: Array[PackedFloat32Array] = []
var roots := PackedVector2Array()
var fft := PackedVector2Array()
var spectrum := PackedFloat32Array()
var bin_weights := PackedFloat32Array()
var indices: Array[PackedInt32Array] = []
var columns: Array[PackedFloat32Array] = []
var measured_columns: Array[PackedFloat32Array] = []
var predicted := PackedFloat32Array()
var numerator_bins := PackedFloat32Array()
var denominator_bins := PackedFloat32Array()
var gains := PackedFloat32Array()
var confirmation := preload("res://chord/note_confirmation.gd").new()
var analysis_ms := 0.0
var octave_confirmations := PackedInt32Array()
var tuning := 0.0
var configured_templates := {}
var window := Taper.HANN
var beta := 0.5

func _init() -> void:
	fft.resize(FFT_SIZE)
	spectrum.resize(BINS)
	predicted.resize(BINS)
	numerator_bins.resize(BINS)
	denominator_bins.resize(BINS)
	gains.resize(KEYS)
	octave_confirmations.resize(KEYS)
	for _bank in BANKS:
		tapers.append(PackedFloat32Array())
	var kaiser_center := _bessel_i0(KAISER_SHAPE)
	for i in FFT_SIZE:
		var reversed := 0
		var bits := i
		var remaining := FFT_SIZE
		while remaining > 1:
			reversed = (reversed << 1) | (bits & 1)
			bits >>= 1
			remaining >>= 1
		permutation.append(reversed)
		if i < FRAME_SIZE:
			var position := float(i) / FRAME_SIZE
			var angle := TAU * position
			var cosine := cos(angle)
			tapers[Taper.HANN].append(0.5 - 0.5 * cosine)
			tapers[Taper.HAMMING].append(0.54 - 0.46 * cosine)
			tapers[Taper.BLACKMAN].append(0.42 - 0.5 * cosine + 0.08 * cos(2.0 * angle))
			var centered := 2.0 * position - 1.0
			tapers[Taper.KAISER_4].append(_bessel_i0(KAISER_SHAPE * sqrt(1.0 - centered * centered)) / kaiser_center)
		if i < BINS:
			roots.append(Vector2(cos(TAU * i / FFT_SIZE), -sin(TAU * i / FFT_SIZE)))
			bin_weights.append(pow(maxf(i * float(FRAME_SIZE) / FFT_SIZE, 2.0), 0.10))

static func _bessel_i0(x: float) -> float:
	var sum := 1.0
	var term := 1.0
	for order in range(1, 13):
		var ratio := x / (2.0 * order)
		term *= ratio * ratio
		sum += term
	return sum

static func _in_harmonic_band(bin: int, midi: int, a4_hz: float) -> bool:
	# Mirror the inharmonicity-aware harmonic mask used in tools/build_chord_assets.mjs
	# so personal templates exclude broadband room noise and hum.
	var f0 := MusicUtils.midi_to_hz(midi, a4_hz)
	var bin_hz := RATE / FFT_SIZE
	var window_hz := RATE / FRAME_SIZE
	var hz := bin * bin_hz
	var partial := maxi(1, roundi(hz / f0))
	var distance := hz - partial * f0
	return not (distance < -1.7 * window_hz - 0.006 * hz or distance > 1.7 * window_hz + 0.02 * hz)

func configure(a4: float, personal_templates: Dictionary = {}, analysis_window := Taper.HANN) -> void:
	reset()
	if is_equal_approx(a4, tuning) and personal_templates == configured_templates and window == analysis_window:
		return
	tuning = a4
	window = analysis_window
	configured_templates = personal_templates.duplicate()
	indices.clear()
	columns.clear()
	measured_columns.clear()
	var bank: PackedByteArray = BANKS[window].get_meta("spectra")
	for key in KEYS:
		var midi := FIRST_KEY + key
		var bins := PackedInt32Array()
		var values := PackedFloat32Array()
		var norm := 0.0
		var personal: PackedFloat32Array = personal_templates.get(midi, PackedFloat32Array())
		var personal_peak := 0.0
		for b in range(1, mini(BINS, personal.size())):
			if _in_harmonic_band(b, midi, a4):
				personal_peak = maxf(personal_peak, personal[b])
		var use_personal := not personal.is_empty() and personal_peak > 0.0
		for b in range(1, BINS):
			var value := 0.0
			if not use_personal:
				var source := b * MusicUtils.STANDARD_A4 / a4
				var left := floori(source)
				if left + 1 >= BINS:
					break
				var row := key * BINS + left
				var amplitude := lerpf(bank[row], bank[row + 1], source - left) / 255.0
				if amplitude >= 0.13:
					value = amplitude * amplitude * bin_weights[b]
			elif b < personal.size() and _in_harmonic_band(b, midi, a4) and personal[b] >= 0.02 * personal_peak:
				# These bins already contain the recorded tuning and weighting.
				value = personal[b]
			if value <= 0.0:
				continue
			norm += value * value
			bins.append(b)
			values.append(value)
		norm = sqrt(norm)
		if norm > 0.0:
			for i in values.size():
				values[i] /= norm
		indices.append(bins)
		columns.append(values)
		var products := PackedFloat32Array()
		products.resize(bins.size())
		measured_columns.append(products)

func reset() -> void:
	gains.fill(0.0)
	octave_confirmations.fill(0)
	confirmation.reset()
	analysis_ms = 0.0

func analyze_frame(frames: PackedVector2Array, audio_ms := -1.0) -> Dictionary:
	var start := Time.get_ticks_usec()
	var db := MusicUtils.input_level_db(frames)
	var silent := db < GATE_DB
	var keys := {}
	if silent:
		gains.fill(0.0)
		octave_confirmations.fill(0)
	else:
		keys = estimate(frames)
	analysis_ms = audio_ms if audio_ms >= 0.0 else analysis_ms + 1000.0 * HOP_SECONDS
	var confirmed := confirmation.update(keys, gains, FIRST_KEY, analysis_ms, silent)
	return {
		"db": db,
		"keys": confirmed,
		"raw_keys": keys,
		"onsets": confirmation.last_onsets.duplicate(),
		"usec": Time.get_ticks_usec() - start,
	}

func measure_template(frames: PackedVector2Array, analysis_window: Taper) -> PackedFloat32Array:
	_spectrum(frames, analysis_window)
	var peak := 0.0
	for value in spectrum:
		peak = maxf(peak, value)
	var measured := PackedFloat32Array()
	if peak > 0.0:
		for value in spectrum:
			measured.append(value / peak)
	return measured

func _spectrum(frames: PackedVector2Array, analysis_window: Taper) -> void:
	var taper := tapers[analysis_window]
	var step := float(frames.size()) / FRAME_SIZE
	for i in FRAME_SIZE:
		var begin := i * step
		var end := (i + 1) * step
		var sum := 0.0
		for j in range(floori(begin), mini(ceili(end), frames.size())):
			var weight := minf(end, j + 1) - maxf(begin, j)
			sum += (frames[j].x + frames[j].y) * weight
		var value := Vector2(sum * taper[i] / (2.0 * step), 0.0)
		var index := permutation[i]
		# Bit reversal pairs each sample with a padding zero. The first
		# butterfly maps (sample, 0) to (sample, sample).
		fft[index] = value
		fft[index + 1] = value
	var width := 4
	while width <= FFT_SIZE:
		var half := width >> 1
		var root_step := FFT_SIZE / width
		for block in range(0, FFT_SIZE, width):
			for j in half:
				var index := block + j
				var a := fft[index]
				var b := fft[index + half]
				var w := roots[j * root_step]
				var product := Vector2(w.x * b.x - w.y * b.y, w.x * b.y + w.y * b.x)
				fft[index] = a + product
				fft[index + half] = a - product
		width <<= 1
	for b in BINS:
		spectrum[b] = fft[b].length() * bin_weights[b]
	spectrum[0] = 0.0

## Returns {MIDI key: fitted strength relative to the strongest active key}.
func estimate(frames: PackedVector2Array) -> Dictionary:
	if frames.is_empty() or columns.is_empty():
		gains.fill(0.0)
		octave_confirmations.fill(0)
		return {}
	_spectrum(frames, window)
	var correlation := PackedFloat32Array()
	var strongest := 0.0
	var power := 0.0
	for value in spectrum:
		power += value * value
	for key in KEYS:
		var score := 0.0
		var bins := indices[key]
		var column := columns[key]
		for i in bins.size():
			score += column[i] * spectrum[bins[i]]
		correlation.append(score)
		strongest = maxf(strongest, score)
	if strongest <= 0.001 or strongest < 0.32 * sqrt(power):
		# Damp gains on a noisy/transient frame without wiping confirmation state.
		for key in KEYS:
			gains[key] *= 0.5
		octave_confirmations.fill(0)
		return {}

	_fit_beta(correlation, strongest)
	var peak := 0.0
	for gain in gains:
		peak = maxf(peak, gain)
	var minimum_gain := 0.21 * peak
	var result := {}
	for key in KEYS:
		var octave_lower := key - OCTAVE_SEMITONES
		# A weak octave can have too little gain for either immediate gate.
		# Anchor the exception to the strongest detected key to protect chords
		# whose quieter notes can leave weak residuals at several octaves.
		if octave_lower >= 0 and gains[octave_lower] == peak and result.has(FIRST_KEY + octave_lower) and gains[key] >= SOFT_OCTAVE_GAIN_RATIO * peak:
			octave_confirmations[key] = mini(octave_confirmations[key] + 1, SOFT_OCTAVE_CONFIRMATIONS)
		else:
			octave_confirmations[key] = 0
		var confirmed_octave := octave_confirmations[key] >= SOFT_OCTAVE_CONFIRMATIONS
		if gains[key] <= minimum_gain and not confirmed_octave:
			continue
		# With a different piano, one strong upper partial can remain after
		# fitting its key. Require stronger evidence at overlapping partials.
		var ambiguous := false
		for lower: int in result:
			var ratio := pow(2.0, (FIRST_KEY + key - lower) / 12.0)
			var partial := roundi(ratio)
			if partial >= 2 and partial <= 10 and absf(ratio - partial) < 0.012 * partial:
				if gains[key] < 0.38 * gains[lower - FIRST_KEY]:
					if confirmed_octave and lower == FIRST_KEY + octave_lower:
						continue
					ambiguous = true
					break
		if not ambiguous:
			result[FIRST_KEY + key] = gains[key] / peak
	return result

func _fit_beta(correlation: PackedFloat32Array, strongest: float) -> void:
	var floor_val := 0.001 * strongest
	# Itakura–Saito divergence at beta = 0 requires positive observations.
	var observation_floor := 0.000001 * strongest if is_zero_approx(beta) else 0.0
	for key in KEYS:
		# Positive seeds let a key enter the fit again after fading out.
		gains[key] = maxf(minf(gains[key], strongest), 0.15 * correlation[key] + floor_val)
		var bins := indices[key]
		var shape := columns[key]
		for i in bins.size():
			# Equation 12 folds the observed spectrum into W once per frame.
			measured_columns[key][i] = shape[i] * maxf(spectrum[bins[i]], observation_floor)
	var beta_mode := 4
	if is_equal_approx(beta, 0.5):
		beta_mode = 0
	elif is_equal_approx(beta, 1.0):
		beta_mode = 1
	elif is_equal_approx(beta, 2.0):
		beta_mode = 2
	elif is_zero_approx(beta):
		beta_mode = 3
	for _iteration in BETA_UPDATES:
		predicted.fill(floor_val)
		for key in KEYS:
			var bins := indices[key]
			var shape := columns[key]
			var gain := gains[key]
			for i in bins.size():
				predicted[bins[i]] += gain * shape[i]
		match beta_mode:
			0:
				for bin in range(1, BINS):
					var p := predicted[bin]
					var inv_sqrt := 1.0 / sqrt(p)
					denominator_bins[bin] = inv_sqrt
					numerator_bins[bin] = inv_sqrt / p
			1:
				for bin in range(1, BINS):
					denominator_bins[bin] = 1.0
					numerator_bins[bin] = 1.0 / predicted[bin]
			2:
				for bin in range(1, BINS):
					denominator_bins[bin] = predicted[bin]
					numerator_bins[bin] = 1.0
			3:
				for bin in range(1, BINS):
					var inv := 1.0 / predicted[bin]
					denominator_bins[bin] = inv
					numerator_bins[bin] = inv * inv
			_:
				for bin in range(1, BINS):
					var p := predicted[bin]
					denominator_bins[bin] = pow(p, beta - 1.0)
					numerator_bins[bin] = denominator_bins[bin] / p
		for key in KEYS:
			var numerator := 0.0
			var denominator := 0.0
			var bins := indices[key]
			var shape := columns[key]
			var products := measured_columns[key]
			for i in bins.size():
				var bin := bins[i]
				numerator += products[i] * numerator_bins[bin]
				denominator += shape[i] * denominator_bins[bin]
			gains[key] = gains[key] * numerator / denominator if denominator > 0.0 else 0.0

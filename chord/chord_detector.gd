extends RefCounted
## Online fixed-dictionary NMF. Each 50 ms spectrum is fitted as W * h,
## where W contains measured piano spectra and h contains nonnegative gains.
const BANK := preload("res://chord/templates.tres")
const SIZE := 1024
const BINS := SIZE >> 1
const RATE := 20480.0
const WINDOW_SECONDS := SIZE / RATE
const HOP_SECONDS := 0.010
const KEYS := 88
const FIRST_KEY := 21
const MAX_UPDATES := 24
const MIN_NOTE_FITNESS := 0.04
const BETA_UPDATES := 12

enum Solver { SQUARED_ERROR, BETA_HALF }

var permutation := PackedInt32Array()
var taper := PackedFloat32Array()
var roots := PackedVector2Array()
var fft := PackedVector2Array()
var spectrum := PackedFloat32Array()
var bin_weights := PackedFloat32Array()
var indices: Array[PackedInt32Array] = []
var columns: Array[PackedFloat32Array] = []
var gram: Array[PackedFloat32Array] = []
var gains := PackedFloat32Array()
var tuning := 0.0
var configured_templates := {}
var solver := Solver.SQUARED_ERROR

func _init() -> void:
	fft.resize(SIZE)
	spectrum.resize(BINS)
	gains.resize(KEYS)
	for i in SIZE:
		var reversed := 0
		var bits := i
		for _bit in 10:
			reversed = (reversed << 1) | (bits & 1)
			bits >>= 1
		permutation.append(reversed)
		taper.append(0.5 - 0.5 * cos(TAU * i / SIZE))
		if i < BINS:
			roots.append(Vector2(cos(TAU * i / SIZE), -sin(TAU * i / SIZE)))
			bin_weights.append(pow(maxf(i, 2), 0.10))

func configure(a4: float, personal_templates: Dictionary = {}) -> void:
	reset()
	if is_equal_approx(a4, tuning) and personal_templates == configured_templates:
		return
	tuning = a4
	configured_templates = personal_templates.duplicate()
	indices.clear()
	columns.clear()
	gram.clear()
	var bank: PackedByteArray = BANK.get_meta("spectra")
	var template_spectra: Array[PackedFloat32Array] = []
	for key in KEYS:
		var bins := PackedInt32Array()
		var values := PackedFloat32Array()
		var column := PackedFloat32Array()
		column.resize(BINS)
		var norm := 0.0
		var personal: PackedFloat32Array = personal_templates.get(FIRST_KEY + key, PackedFloat32Array())
		var personal_peak := 0.0
		for value in personal:
			personal_peak = maxf(personal_peak, value)
		for b in range(1, BINS):
			var value := 0.0
			if personal.is_empty():
				var source := b * 440.0 / a4
				var left := floori(source)
				if left + 1 >= BINS:
					break
				var row := key * BINS + left
				var amplitude := lerpf(bank[row], bank[row + 1], source - left) / 255.0
				if amplitude >= 0.13:
					value = amplitude * amplitude * bin_weights[b]
			elif personal[b] >= 0.02 * personal_peak:
				# These bins already contain the recorded tuning and weighting.
				value = personal[b]
			if value <= 0.0:
				continue
			column[b] = value
			norm += value * value
			bins.append(b)
		norm = sqrt(norm)
		for b in bins:
			column[b] /= norm
			values.append(column[b])
		template_spectra.append(column)
		indices.append(bins)
		columns.append(values)
	# Precompute W'W. The bounded solver only visits 88 values per update.
	for key in KEYS:
		var overlaps := PackedFloat32Array()
		for other in KEYS:
			var overlap := 0.0
			for i in indices[key].size():
				overlap += columns[key][i] * template_spectra[other][indices[key][i]]
			overlaps.append(overlap)
		gram.append(overlaps)

func reset() -> void:
	gains.fill(0.0)

func measure_template(frames: PackedVector2Array) -> PackedFloat32Array:
	_spectrum(frames)
	var peak := 0.0
	for value in spectrum:
		peak = maxf(peak, value)
	var measured := PackedFloat32Array()
	if peak > 0.0:
		for value in spectrum:
			measured.append(value / peak)
	return measured

func _spectrum(frames: PackedVector2Array) -> void:
	# Area-average the source window into SIZE mono samples at the analysis rate.
	var step := float(frames.size()) / SIZE
	for i in SIZE:
		var begin := i * step
		var end := (i + 1) * step
		var sum := 0.0
		for j in range(floori(begin), mini(ceili(end), frames.size())):
			var weight := minf(end, j + 1) - maxf(begin, j)
			sum += (frames[j].x + frames[j].y) * weight
		fft[permutation[i]] = Vector2(sum * taper[i] / (2.0 * step), 0.0)
	var width := 2
	while width <= SIZE:
		var half := width >> 1
		var root_step := SIZE / width
		for block in range(0, SIZE, width):
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
		reset()
		return {}
	_spectrum(frames)
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
		reset()
		return {}

	if solver == Solver.BETA_HALF:
		_fit_beta_half(correlation, strongest)
	else:
		_fit_squared_error(correlation, strongest)
	var peak := 0.0
	for gain in gains:
		peak = maxf(peak, gain)
	var minimum_gain := 0.21 * peak
	var result := {}
	for key in KEYS:
		if gains[key] <= minimum_gain:
			continue
		if _note_fitness(gains[key], correlation[key], power) < MIN_NOTE_FITNESS:
			continue
		# With a different piano, one strong upper partial can remain after
		# fitting its key. Require stronger evidence at overlapping partials.
		var ambiguous := false
		for lower: int in result:
			var ratio := pow(2.0, (FIRST_KEY + key - lower) / 12.0)
			var partial := roundi(ratio)
			if partial >= 3 and partial <= 10 and absf(ratio - partial) < 0.012 * partial:
				if gains[key] < 0.38 * gains[lower - FIRST_KEY]:
					ambiguous = true
					break
		if not ambiguous:
			result[FIRST_KEY + key] = gains[key] / peak
	return result

func _fit_squared_error(correlation: PackedFloat32Array, strongest: float) -> void:
	# Coordinate descent on 0.5 * ||W*h - spectrum||² + penalty * sum(h).
	var penalty := 0.10 * strongest
	for key in KEYS:
		if gains[key] > 0:
			_subtract_column(correlation, key, gains[key])
	for _iteration in MAX_UPDATES:
		var best := -1
		var change := 0.0
		for key in KEYS:
			var delta := maxf(-gains[key], correlation[key] - penalty)
			if absf(delta) > absf(change):
				best = key
				change = delta
		if absf(change) < 0.003 * strongest:
			break
		gains[best] = maxf(0.0, gains[best] + change)
		_subtract_column(correlation, best, change)

func _fit_beta_half(correlation: PackedFloat32Array, strongest: float) -> void:
	var predicted := PackedFloat32Array()
	var numerator_bins := PackedFloat32Array()
	var denominator_bins := PackedFloat32Array()
	predicted.resize(BINS)
	numerator_bins.resize(BINS)
	denominator_bins.resize(BINS)
	var floor := 0.001 * strongest
	for key in KEYS:
		# Positive seeds let a key enter the fit again after fading out.
		gains[key] = maxf(minf(gains[key], strongest), 0.15 * correlation[key] + floor)
	for _iteration in BETA_UPDATES:
		predicted.fill(floor)
		for key in KEYS:
			var bins := indices[key]
			var shape := columns[key]
			for i in bins.size():
				predicted[bins[i]] += gains[key] * shape[i]
		for bin in range(1, BINS):
			var inverse_root := 1.0 / sqrt(predicted[bin])
			denominator_bins[bin] = inverse_root
			numerator_bins[bin] = spectrum[bin] / predicted[bin] * inverse_root
		# Fixed-dictionary multiplicative update at beta = 0.5.
		# The 2/3 exponent is the majorization-minimization step.
		for key in KEYS:
			var numerator := 0.0
			var denominator := 0.0
			var bins := indices[key]
			var shape := columns[key]
			for i in bins.size():
				numerator += shape[i] * numerator_bins[bins[i]]
				denominator += shape[i] * denominator_bins[bins[i]]
			gains[key] = gains[key] * pow(numerator / denominator, 2.0 / 3.0) if denominator > 0.0 else 0.0
	# Both solvers use the same squared-error fitness check.
	for key in KEYS:
		if gains[key] > 0.0:
			_subtract_column(correlation, key, gains[key])

func _note_fitness(gain: float, residual_match: float, observed_energy: float) -> float:
	# Removing this unit-length column changes r to r + gain * column.
	# Measure the error it prevents as a fraction of the observed spectrum.
	return gain * (gain + 2.0 * residual_match) / observed_energy

func _subtract_column(residual: PackedFloat32Array, key: int, change: float) -> void:
	var overlap := gram[key]
	for other in KEYS:
		residual[other] -= change * overlap[other]

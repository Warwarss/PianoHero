extends RefCounted
## Single-pitch YIN estimator for isolated notes C3–C6.
## Returns Hz, or zero when the window has no sufficiently periodic signal.

const WINDOW_SECONDS := 0.040
const MIN_HZ := 125.0
const MAX_HZ := 1100.0
const THRESHOLD := 0.15

func estimate(frames: PackedVector2Array, sample_rate: float, tuning_ratio := 1.0) -> float:
	var stride := maxi(1, roundi(sample_rate / 11025.0))
	var rate := sample_rate / stride
	var samples := PackedFloat32Array()
	samples.resize(floori(float(frames.size()) / stride))
	# Average before decimating to reduce the contribution of high harmonics.
	for i in samples.size():
		var sum := 0.0
		for j in stride:
			var frame := frames[i * stride + j]
			sum += frame.x + frame.y
		samples[i] = sum / (2.0 * stride)

	var min_hz := MIN_HZ * tuning_ratio
	var max_hz := MAX_HZ * tuning_ratio
	var max_lag := ceili(rate / min_hz) + 1
	var span := samples.size() - max_lag
	if span <= max_lag:
		return 0.0
	var differences := PackedFloat32Array([1.0])
	var total := 0.0
	for lag in range(1, max_lag + 1):
		var difference := 0.0
		for i in span:
			var delta := samples[i] - samples[i + lag]
			difference += delta * delta
		total += difference
		differences.append(difference * lag / total if total > 0.0 else 1.0)
		# Use the first clear minimum to keep upper harmonics from winning.
		var k := lag - 1
		if k < floori(rate / max_hz) or differences[k] >= THRESHOLD:
			continue
		var left := differences[k - 1]
		var center := differences[k]
		var right := differences[lag]
		if center <= left and center < right:
			var offset := 0.5 * (left - right) / (left + right - 2.0 * center)
			var hz := rate / (k + offset)
			if hz >= min_hz and hz <= max_hz:
				return hz
	return 0.0

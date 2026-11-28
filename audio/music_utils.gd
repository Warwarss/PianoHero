extends RefCounted
## Shared music-theory constants and audio-level utilities used across all detectors and UI panels.

const NAMES := ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
const STANDARD_A4 := 440.0
const FIRST_KEY := 21
const KEYS := 88
const GATE_DB := -55.0

static func note_name(midi: int) -> String:
	var pitch_index := posmod(midi, 12)
	return "%s%d" % [NAMES[pitch_index], floori(midi / 12.0) - 1]

static func midi_to_hz(midi: float, a4_hz := STANDARD_A4) -> float:
	return a4_hz * pow(2.0, (midi - 69.0) / 12.0)

static func hz_to_midi(hz: float, a4_hz := STANDARD_A4) -> float:
	return 69.0 + 12.0 * log(hz / a4_hz) / log(2.0)

static func cents_diff(hz: float, ref_hz: float) -> float:
	return 1200.0 * log(hz / ref_hz) / log(2.0)

static func stereo_rms(frames: PackedVector2Array) -> float:
	if frames.is_empty():
		return 0.0
	var power := 0.0
	for frame in frames:
		power += frame.length_squared() * 0.5
	return sqrt(power / frames.size())

static func mono_rms(frames: PackedVector2Array) -> float:
	if frames.is_empty():
		return 0.0
	var power := 0.0
	for frame in frames:
		var mono := (frame.x + frame.y) * 0.5
		power += mono * mono
	return sqrt(power / frames.size())

static func rms_to_dbfs(rms: float, floor_val := 0.000001) -> float:
	return linear_to_db(maxf(rms, floor_val))

static func input_level_db(frames: PackedVector2Array) -> float:
	return rms_to_dbfs(stereo_rms(frames))

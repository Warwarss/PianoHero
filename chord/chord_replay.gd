extends RefCounted
## Labeled, silent replay in audio time. Scoring begins at each case's
## scheduled onset. The solver sees only samples preceding each decision.
const AUDIO: AudioStreamWAV = preload("res://chord/replay.wav")
const CASES := [
	["C4", [60]], ["C4 G4", [60, 67]], ["Soft E4 in C major", [60, 64, 67]],
	["C4 C5", [60, 72]], ["E4 G4 over ringing C4", [60, 64, 67]],
	["A0 A♯0", [21, 22]], ["C8", [108]]
]
const HOP_MS := 10
const WINDOW_MS := 50
const ONSET_MS := 250
const END_MS := 750

var samples := PackedVector2Array()
var cursor_ms := WINDOW_MS
var delays := PackedInt32Array()
var matches := PackedInt32Array()
var scored := PackedInt32Array()
var streak := 0
var total_usec := 0
var windows := 0

func _init() -> void:
	var bytes := AUDIO.data
	samples.resize(bytes.size() >> 1)
	for i in samples.size():
		var mono := bytes.decode_s16(i * 2) / 32768.0
		samples[i] = Vector2(mono, mono)
	delays.resize(CASES.size())
	delays.fill(-1)
	matches.resize(CASES.size())
	scored.resize(CASES.size())

func finished() -> bool:
	return cursor_ms >= CASES.size() * 1000

func next_window() -> PackedVector2Array:
	var first := roundi((cursor_ms - WINDOW_MS) * AUDIO.mix_rate / 1000.0)
	var end := roundi(cursor_ms * AUDIO.mix_rate / 1000.0)
	return samples.slice(first, end)

func score(keys: Array, analysis_usec: int) -> void:
	var index := floori(cursor_ms / 1000.0)
	var phase := cursor_ms % 1000
	total_usec += analysis_usec
	windows += 1
	if phase >= ONSET_MS and phase < END_MS:
		scored[index] += 1
		if keys == CASES[index][1]:
			matches[index] += 1
			streak += 1
			if streak == 3 and delays[index] < 0:
				delays[index] = phase - ONSET_MS
		else:
			streak = 0
	else:
		streak = 0
	cursor_ms += HOP_MS

func report() -> String:
	var lines := PackedStringArray()
	for i in CASES.size():
		var delay := "%d ms" % delays[i] if delays[i] >= 0 else "miss"
		lines.append("%s · %s · %d%%" % [CASES[i][0], delay, roundi(100.0 * matches[i] / maxi(1, scored[i]))])
	lines.append("\nMean analysis %.1f ms per window" % (total_usec / (1000.0 * maxi(1, windows))))
	return "\n".join(lines)

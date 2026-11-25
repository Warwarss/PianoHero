extends RefCounted

const OUTPUT_DIR := "user://guided-chord-tests"
const TRIALS := [
	["Play C4 softly (middle C) and hold", [60]],
	["Play C4 firmly and hold", [60]],
	["Play C5 (one octave above middle C) and hold", [72]],
	["Play C4 and G4 together and hold", [60, 67]],
	["Play C4, E4 and G4 together and hold", [60, 64, 67]],
	["Play C4 firmly and C5 softly, together", [60, 72]],
	["Hold C4", [60], "Keep holding C4 and add C5 softly"],
	["Repeat: C4 firmly and C5 softly, together", [60, 72]],
	["Play A0 and A♯0 together and hold", [21, 22]],
	["Play C8 (the highest C) and hold", [108]]
]

var samples := PackedVector2Array()
var prompts: Array[Dictionary] = []
var shown_prompts: Array[Dictionary] = []
var frames: Array[Dictionary] = []
var prompt_index := 0
var trial_index := 0
var metadata: Dictionary
var sample_rate: int
var output_path := ""

func _init(rate: int, settings: Dictionary) -> void:
	sample_rate = rate
	metadata = settings

func start_trial() -> void:
	if recording() or finished():
		return
	var trial: Array = TRIALS[trial_index]
	prompt_index = 0
	prompts.append({"text": "Get ready · Release all keys and the pedal", "expected_midi": [], "seconds": 1.0})
	prompts.append({"text": trial[0], "expected_midi": trial[1], "seconds": 3.0 if trial.size() == 2 else 2.0})
	if trial.size() == 3:
		prompts.append({"text": trial[2], "expected_midi": [60, 72], "seconds": 3.0})
	prompts.append({"text": "Release all keys and the pedal", "expected_midi": [], "seconds": 1.25})
	_show_prompt()

func recording() -> bool:
	return not prompts.is_empty()

func prompt_text() -> String:
	var prefix := "%d/%d · " % [trial_index + 1, TRIALS.size()]
	if recording():
		return prefix + str(prompts[prompt_index]["text"])
	var trial: Array = TRIALS[trial_index]
	var instructions := str(trial[0])
	if trial.size() == 3:
		instructions += "\n" + str(trial[2])
	return prefix + instructions + "\nPress Record when ready."

func advance_prompt() -> bool:
	if not recording():
		return false
	var current := shown_prompts[-1]
	if samples.size() - int(current["start_sample"]) < roundi(float(current["seconds"]) * sample_rate):
		return false
	current["end_sample"] = samples.size()
	prompt_index += 1
	if prompt_index < prompts.size():
		_show_prompt()
	else:
		prompts.clear()
		trial_index += 1
	return true

func finished() -> bool:
	return trial_index >= TRIALS.size()

func _show_prompt() -> void:
	var current := prompts[prompt_index].duplicate()
	current["start_sample"] = samples.size()
	current["trial"] = trial_index + 1
	shown_prompts.append(current)

func record_frame(end_sample: int, db: float, usec: int, gains: PackedFloat32Array, detected: Dictionary, raw := {}) -> void:
	frames.append({
		"end_sample": end_sample,
		"trial": trial_index + 1,
		"dbfs": db,
		"analysis_usec": usec,
		"gains": Array(gains),
		"raw_midi": raw.keys(),
		"detected_midi": detected.keys()
	})

func save(discarded: int, skipped: int) -> Error:
	var absolute_dir := ProjectSettings.globalize_path(OUTPUT_DIR)
	var error := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if error != OK:
		return error
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	output_path = absolute_dir.path_join("%s-%d" % [stamp, Time.get_ticks_msec()])
	if not shown_prompts[-1].has("end_sample"):
		shown_prompts[-1]["end_sample"] = samples.size()

	var audio := AudioStreamWAV.new()
	audio.format = AudioStreamWAV.FORMAT_16_BITS
	audio.stereo = true
	audio.mix_rate = sample_rate
	var pcm := PackedByteArray()
	pcm.resize(samples.size() * 4)
	for i in samples.size():
		var frame := samples[i]
		pcm.encode_s16(i * 4, roundi(clampf(frame.x, -1.0, 1.0) * 32767.0))
		pcm.encode_s16(i * 4 + 2, roundi(clampf(frame.y, -1.0, 1.0) * 32767.0))
	audio.data = pcm
	error = audio.save_to_wav(output_path + ".wav")
	if error != OK:
		return error

	var report := FileAccess.open(output_path + ".json", FileAccess.WRITE)
	if report == null:
		return FileAccess.get_open_error()
	report.store_string(JSON.stringify({
		"format_version": 2,
		"audio_file": output_path.get_file() + ".wav",
		"sample_rate_hz": sample_rate,
		"settings": metadata,
		"completed": finished(),
		"capture_frames_discarded": discarded,
		"analysis_hops_skipped": skipped,
		"prompts": shown_prompts,
		"frames": frames
	}))
	report.flush()
	return report.get_error()

extends SceneTree
## Headless Godot runner invoked by tests/benchmark_piano.py.
## Reads a benchmark job JSON, feeds each case's float32 mono PCM audio through
## the actual GDScript ChordDetector + NoteConfirmation, and writes detected
## onsets + frame-level predictions + timing stats back to JSON.

const ChordDetector := preload("res://chord/chord_detector.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("Usage: godot --headless --path . --script res://tests/benchmark_live_detector.gd -- <job.json> <output.json>")
		quit(2)
		return
	var job_path := args[0]
	var out_path := args[1]
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(job_path))
	if not (parsed is Dictionary):
		printerr("Invalid job JSON: %s" % job_path)
		quit(2)
		return
	var job: Dictionary = parsed

	var detector := ChordDetector.new()
	detector.beta = float(job.get("beta", 0.5))
	var taper := int(job.get("taper", ChordDetector.Taper.HANN)) as ChordDetector.Taper
	var a4_hz := float(job.get("a4_hz", 440.0))
	detector.confirmation.attack_ms = float(job.get("attack_ms", 20.0))
	detector.confirmation.spectral_ms = float(job.get("spectral_ms", 40.0))

	var personal_templates := {}
	var personal_raw: Dictionary = job.get("personal_templates", {})
	for midi_str in personal_raw:
		var midi := int(midi_str)
		var pcm_path := str(personal_raw[midi_str]["pcm_path"])
		var sample_rate := int(personal_raw[midi_str]["rate"])
		var onset_sample := int(personal_raw[midi_str]["onset_sample"])
		var audio := _load_mono_f32_as_stereo(pcm_path)
		var win_size := roundi(sample_rate * ChordDetector.WINDOW_SECONDS)
		var total := PackedFloat32Array()
		total.resize(ChordDetector.BINS)
		var count := 0
		for offset in [0.05, 0.10, 0.15, 0.20]:
			var first := onset_sample + roundi(sample_rate * float(offset))
			if first + win_size <= audio.size():
				var measured := detector.measure_template(audio.slice(first, first + win_size), taper)
				if not measured.is_empty():
					for b in measured.size():
						total[b] += measured[b]
					count += 1
		if count > 0:
			for b in total.size():
				total[b] /= count
			personal_templates[midi] = total

	detector.configure(a4_hz, personal_templates, taper)

	var results := []
	for case_item: Dictionary in job.get("cases", []):
		detector.reset()
		var rate := int(case_item["rate"])
		var audio := _load_mono_f32_as_stereo(str(case_item["pcm_path"]))
		var win_samples := roundi(rate * ChordDetector.WINDOW_SECONDS)
		var hop_samples := roundi(rate * ChordDetector.HOP_SECONDS)
		var onsets := []
		var frames := []
		var total_usec := 0
		var window_count := 0
		var pos := 0
		while pos + win_samples <= audio.size():
			var end_ms := 1000.0 * float(pos + win_samples) / float(rate)
			var res := detector.analyze_frame(audio.slice(pos, pos + win_samples), end_ms)
			total_usec += int(res.usec)
			window_count += 1
			for ev: Dictionary in res.onsets:
				onsets.append({
					"midi": int(ev.midi),
					"onset_ms": float(ev.onset_ms),
					"detected_at_ms": end_ms,
					"strength": float(ev.strength),
				})
			var active_keys: Array = res.keys.keys()
			active_keys.sort()
			frames.append({"time_ms": end_ms, "midi": active_keys})
			pos += hop_samples
		results.append({
			"id": str(case_item["id"]),
			"onsets": onsets,
			"frames": frames,
			"mean_analysis_ms": float(total_usec) / (1000.0 * maxi(1, window_count)),
		})

	var out_file := FileAccess.open(out_path, FileAccess.WRITE)
	if out_file == null:
		printerr("Could not open output file: %s" % out_path)
		quit(1)
		return
	out_file.store_string(JSON.stringify({"results": results}))
	out_file.close()
	quit(0)

static func _load_mono_f32_as_stereo(path: String) -> PackedVector2Array:
	var bytes := FileAccess.get_file_as_bytes(path)
	var floats := bytes.to_float32_array()
	var stereo := PackedVector2Array()
	stereo.resize(floats.size())
	for i in floats.size():
		var v := floats[i]
		stereo[i] = Vector2(v, v)
	return stereo

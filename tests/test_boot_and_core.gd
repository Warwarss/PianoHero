extends SceneTree
## Headless Godot test suite verifying scene boot, tuning calibration, YIN pitch,
## live β-NMF chord detection, note confirmation fixes, key calibration, and replay.

const MusicUtils := preload("res://audio/music_utils.gd")
const PitchDetector := preload("res://audio/pitch_detector.gd")
const ChordDetector := preload("res://chord/chord_detector.gd")
const NoteConfirmation := preload("res://chord/note_confirmation.gd")
const KeyCalibration := preload("res://chord/key_calibration.gd")
const ChordReplay := preload("res://chord/chord_replay.gd")
const LAB_SCENE := preload("res://lab.tscn")

var _passed := 0
var _failed := 0

func _initialize() -> void:
	call_deferred("_run_all")

func _run_all() -> void:
	_run("test_music_utils", _test_music_utils)
	await _run_async("test_scene_boot_and_mode_switch", _test_scene_boot_and_mode_switch)
	_run("test_single_note_yin_pitch_detector", _test_single_note_yin_pitch_detector)
	await _run_async("test_a4_calibration_tuning", _test_a4_calibration_tuning)
	_run("test_key_calibration_onset_and_knock_rejection", _test_key_calibration_onset_and_knock_rejection)
	_run("test_note_confirmation_variable_dt_resilience", _test_note_confirmation_variable_dt_resilience)
	_run("test_note_confirmation_dropout_grace_and_restrike", _test_note_confirmation_dropout_grace_and_restrike)
	_run("test_note_confirmation_treble_decay", _test_note_confirmation_treble_decay)
	_run("test_chord_detector_fast_beta_and_transient_resilience", _test_chord_detector_fast_beta_and_transient_resilience)
	_run("test_chord_replay_end_to_end", _test_chord_replay_end_to_end)

	print("\nGodot test summary: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)

func _run(name: String, fn: Callable) -> void:
	var errors: Array[String] = []
	fn.call(errors)
	_report(name, errors)

func _run_async(name: String, fn: Callable) -> void:
	var errors: Array[String] = []
	await fn.call(errors)
	_report(name, errors)

func _report(name: String, errors: Array[String]) -> void:
	if errors.is_empty():
		_passed += 1
		print("[PASS] %s" % name)
	else:
		_failed += 1
		printerr("[FAIL] %s" % name)
		for err in errors:
			printerr("       %s" % err)

func _expect(cond: bool, msg: String, errors: Array[String]) -> void:
	if not cond:
		errors.append(msg)

static func _synth_piano_tone(hz: float, duration_sec: float, rate: float,
		amplitude := 0.35, decay_rate := 2.5) -> PackedVector2Array:
	var count := roundi(duration_sec * rate)
	var out := PackedVector2Array()
	out.resize(count)
	for i in count:
		var t := float(i) / rate
		var env := minf(1.0, t / 0.004) * exp(-decay_rate * t)
		var sample := (
			1.00 * sin(TAU * hz * t)
			+ 0.45 * sin(TAU * 2.0 * hz * t)
			+ 0.25 * sin(TAU * 3.0 * hz * t)
			+ 0.12 * sin(TAU * 4.0 * hz * t)
		) * amplitude * env
		out[i] = Vector2(sample, sample)
	return out

func _test_music_utils(errors: Array[String]) -> void:
	_expect(MusicUtils.note_name(21) == "A0", "Expected A0 for MIDI 21", errors)
	_expect(MusicUtils.note_name(60) == "C4", "Expected C4 for MIDI 60", errors)
	_expect(MusicUtils.note_name(69) == "A4", "Expected A4 for MIDI 69", errors)
	_expect(MusicUtils.note_name(108) == "C8", "Expected C8 for MIDI 108", errors)
	_expect(is_equal_approx(MusicUtils.midi_to_hz(69, 440.0), 440.0), "A4 should be 440 Hz", errors)
	_expect(absf(MusicUtils.hz_to_midi(261.6256, 440.0) - 60.0) < 0.01, "C4 Hz->MIDI mismatch", errors)
	_expect(absf(MusicUtils.cents_diff(440.0, 440.0)) < 1e-4, "Zero cents expected", errors)
	_expect(absf(MusicUtils.cents_diff(880.0, 440.0) - 1200.0) < 1e-3, "Octave should be 1200 cents", errors)
	var silent := PackedVector2Array()
	silent.resize(128)
	_expect(MusicUtils.input_level_db(silent) < -100.0, "Silence should be below -100 dBFS", errors)

func _test_scene_boot_and_mode_switch(errors: Array[String]) -> void:
	var lab := LAB_SCENE.instantiate()
	_expect(lab != null, "Failed to instantiate lab.tscn", errors)
	if lab == null:
		return
	root.add_child(lab)
	await process_frame
	_expect(lab.mode != null and lab.mode.item_count == 2, "Expected 2 modes in OptionButton", errors)
	_expect(lab.analysis_window != null and lab.analysis_window.item_count == 4, "Expected 4 analysis windows", errors)
	_expect(lab.learn_key != null and lab.learn_key.item_count == 89, "Expected 88 keys + All keys", errors)
	_expect(lab.reference_hz >= lab.MIN_A4 and lab.reference_hz <= lab.MAX_A4, "Reference A4 out of valid range", errors)
	# Switch to Chord mode and back to Single note mode.
	lab.mode.select(1)
	lab._mode_changed(1)
	_expect(lab.replay_button.visible, "Replay button should be visible in Chord mode", errors)
	_expect(lab.get_node("%ChordSettings").visible, "ChordSettings should be visible in Chord mode", errors)
	lab.mode.select(0)
	lab._mode_changed(0)
	_expect(not lab.replay_button.visible, "Replay button should hide in Single note mode", errors)
	lab.queue_free()
	await process_frame

func _test_single_note_yin_pitch_detector(errors: Array[String]) -> void:
	var detector := PitchDetector.new()
	var rate := 44100.0
	for target_hz in [130.81, 261.63, 440.0, 432.0, 523.25, 1046.50]:
		var tone := _synth_piano_tone(target_hz, 0.05, rate, 0.4, 0.5)
		var est := detector.estimate(tone, rate, 1.0)
		var cents := absf(MusicUtils.cents_diff(est, target_hz)) if est > 0.0 else 9999.0
		_expect(cents < 15.0, "YIN failed for %.2f Hz (got %.2f Hz, %.1f cents)" % [target_hz, est, cents], errors)
	var silence := PackedVector2Array()
	silence.resize(roundi(0.05 * rate))
	_expect(detector.estimate(silence, rate, 1.0) == 0.0, "YIN should return 0 on silence", errors)

func _test_a4_calibration_tuning(errors: Array[String]) -> void:
	var tuning_path := ProjectSettings.globalize_path("user://piano_tuning.cfg")
	var had_file := FileAccess.file_exists(tuning_path)
	var backup := FileAccess.get_file_as_string(tuning_path) if had_file else ""

	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	lab.calibrating = true
	# Reject accidental octave A3 (220 Hz).
	lab._sample_calibration(220.0, 0.03)
	_expect(lab.pitches.is_empty() and lab.stable_seconds == 0.0, "A3 should be rejected by A4 calibration", errors)
	# Feed steady detuned A4 = 435.0 Hz for > HOLD_SECONDS (0.45 s).
	for _i in 20:
		if not lab.calibrating:
			break
		lab._sample_calibration(435.0, 0.03)
	_expect(not lab.calibrating, "Calibration should complete after steady hold", errors)
	_expect(absf(lab.reference_hz - 435.0) < 0.1, "Expected calibrated A4 near 435.0 Hz, got %.2f" % lab.reference_hz, errors)
	_expect(lab.tuning_label.text.contains("435.0"), "Tuning label did not update to 435.0 Hz", errors)
	lab.queue_free()
	await process_frame

	# Restore user's original tuning file cleanly.
	if had_file:
		var f := FileAccess.open(tuning_path, FileAccess.WRITE)
		if f != null:
			f.store_string(backup)
			f.close()
	elif FileAccess.file_exists(tuning_path):
		DirAccess.remove_absolute(tuning_path)

func _test_key_calibration_onset_and_knock_rejection(errors: Array[String]) -> void:
	var rate := 44100
	var quiet := PackedVector2Array()
	quiet.resize(roundi(rate * 0.30))
	for i in quiet.size():
		var v := 0.0002 * sin(i * 0.13)
		quiet[i] = Vector2(v, v)

	# 1) Brief 10 ms knock should be rejected after 120 ms sustain window.
	var knock_cal := KeyCalibration.new(rate, false)
	knock_cal.append(quiet)
	_expect(knock_cal.armed, "KeyCalibration should arm after quiet floor", errors)
	var knock := PackedVector2Array()
	knock.resize(roundi(rate * 0.015))
	knock.fill(Vector2(0.25, 0.25))
	knock_cal.append(knock)
	knock_cal.append(quiet)
	_expect(knock_cal.rejected, "Brief knock should be rejected", errors)

	# 2) Valid sustained strike should detect onset and complete capture.
	var good_cal := KeyCalibration.new(rate, false)
	good_cal.append(quiet)
	var strike := _synth_piano_tone(261.63, 1.5, float(rate), 0.3, 1.2)
	good_cal.append(strike)
	_expect(not good_cal.rejected, "Sustained strike should not be rejected", errors)
	_expect(good_cal.onset >= 0, "Sustained strike should set onset index", errors)
	_expect(good_cal.complete, "Sustained strike should complete capture", errors)

func _test_note_confirmation_variable_dt_resilience(errors: Array[String]) -> void:
	var conf := NoteConfirmation.new()
	conf.attack_ms = 20.0
	conf.spectral_ms = 40.0
	var gains := PackedFloat32Array()
	gains.resize(88)
	# Simulate slow mobile worker delivering frames every 50 ms (previously broke at MAX_GAP_MS = 40).
	var midi := 60
	var idx := midi - 21
	var onsets_seen := 0
	var confirmed := {}
	for step in 5:
		gains[idx] = 1.0 if step == 0 else 1.2
		confirmed = conf.update({midi: 1.0}, gains, 21, float(step * 50), false)
		onsets_seen += conf.last_onsets.size()
	_expect(confirmed.has(midi), "Note should still confirm when worker dt is 50 ms", errors)
	_expect(onsets_seen == 1, "Expected exactly 1 onset event, got %d" % onsets_seen, errors)

func _test_note_confirmation_dropout_grace_and_restrike(errors: Array[String]) -> void:
	var conf := NoteConfirmation.new()
	conf.attack_ms = 20.0
	conf.spectral_ms = 40.0
	var gains := PackedFloat32Array()
	gains.resize(88)
	var midi := 60
	var idx := midi - 21
	var t := 0.0
	var onsets: Array[Dictionary] = []

	# Ramp up and confirm initial strike (0..60 ms).
	for _i in 7:
		gains[idx] = 1.0
		var res := conf.update({midi: 1.0}, gains, 21, t, false)
		onsets.append_array(conf.last_onsets)
		t += 10.0
		if t == 70.0:
			_expect(res.has(midi), "Initial strike should be confirmed", errors)
	_expect(onsets.size() == 1, "Expected 1 initial onset, got %d" % onsets.size(), errors)
	if not onsets.is_empty():
		_expect(onsets[0].onset_ms <= 10.0, "Onset should be backdated near 0 ms, got %.1f" % onsets[0].onset_ms, errors)

	# Single-frame (10 ms) non-silent transient dropout should NOT turn off the held note.
	gains[idx] = 0.5
	var after_drop := conf.update({}, gains, 21, t, false)
	_expect(after_drop.has(midi), "Single 10 ms non-silent dropout should not kill held note", errors)
	t += 10.0

	# Decay while still supported for 120 ms to arm re-attack.
	for i in 12:
		gains[idx] = maxf(0.25, 0.85 - 0.05 * i)
		conf.update({midi: 1.0}, gains, 21, t, false)
		onsets.append_array(conf.last_onsets)
		t += 10.0

	# Re-strike the same key while still ringing!
	for _i in 4:
		gains[idx] = 1.2
		conf.update({midi: 1.0}, gains, 21, t, false)
		onsets.append_array(conf.last_onsets)
		t += 10.0
	_expect(onsets.size() == 2, "Repeated strike on ringing note should emit a 2nd onset (got %d)" % onsets.size(), errors)

	# True silence must immediately turn the note off.
	gains.fill(0.0)
	var after_silence := conf.update({}, gains, 21, t, true)
	_expect(after_silence.is_empty(), "True silence should clear visible notes immediately", errors)

func _test_note_confirmation_treble_decay(errors: Array[String]) -> void:
	var conf := NoteConfirmation.new()
	conf.attack_ms = 20.0
	conf.spectral_ms = 40.0
	var gains := PackedFloat32Array()
	gains.resize(88)
	var midi := 108 # C8: decays rapidly
	var idx := midi - 21
	var profile := [1.0, 0.60, 0.45, 0.42, 0.40, 0.38]
	var confirmed := {}
	for i in profile.size():
		gains[idx] = profile[i]
		confirmed = conf.update({midi: 1.0}, gains, 21, float(i * 10), false)
	_expect(confirmed.has(midi), "Fast-decaying treble note C8 should still confirm", errors)

func _test_chord_detector_fast_beta_and_transient_resilience(errors: Array[String]) -> void:
	var det := ChordDetector.new()
	var rate := 44100.0
	var win := roundi(rate * ChordDetector.WINDOW_SECONDS)
	var tone := _synth_piano_tone(261.63, 0.12, rate, 0.4, 1.0)
	var frame := tone.slice(roundi(rate * 0.02), roundi(rate * 0.02) + win)

	# Verify all fast beta paths produce valid finite non-empty detections for C4.
	for b in [0.0, 0.5, 1.0, 1.5, 2.0]:
		det.beta = b
		det.configure(440.0, {}, ChordDetector.Taper.HANN)
		var est := det.estimate(frame)
		_expect(est.has(60), "Expected C4 (60) detected at beta=%.2f (got %s)" % [b, str(est.keys())], errors)
		for g in det.gains:
			_expect(not is_nan(g) and not is_inf(g), "Non-finite gain at beta=%.2f" % b, errors)

	# Verify personal template harmonic masking removes off-harmonic noise bins.
	var noisy_template := PackedFloat32Array()
	noisy_template.resize(ChordDetector.BINS)
	noisy_template.fill(0.5) # Uniform broadband noise everywhere
	noisy_template[26] = 1.0 # ~260 Hz (C4 fundamental)
	det.configure(440.0, {60: noisy_template}, ChordDetector.Taper.HANN)
	var c4_bins := det.indices[60 - 21]
	_expect(c4_bins.has(26), "Harmonic mask must keep C4 fundamental (~260 Hz)", errors)
	_expect(not c4_bins.has(10), "Harmonic mask should reject 100 Hz room hum for C4", errors)
	_expect(not c4_bins.has(39), "Harmonic mask should reject 390 Hz between C4 partials 1 and 2", errors)
	_expect(c4_bins.size() < 800, "Harmonic mask should exclude off-harmonic bins (kept %d)" % c4_bins.size(), errors)

	# Verify a single noisy transient frame does not wipe confirmed held note.
	det.beta = 0.5
	det.configure(440.0, {}, ChordDetector.Taper.HANN)
	var confirmed := {}
	for i in 8:
		confirmed = det.analyze_frame(frame, float(i * 10)).keys
	_expect(confirmed.has(60), "C4 should confirm before transient", errors)
	# Construct an uncorrelated broadband impulse above GATE_DB.
	var noise := PackedVector2Array()
	noise.resize(win)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for i in win:
		var v := rng.randf_range(-0.15, 0.15)
		noise[i] = Vector2(v, v)
	var during_noise: Dictionary = det.analyze_frame(noise, 80.0).keys
	_expect(during_noise.has(60), "Single transient noise frame should not wipe held C4", errors)

func _test_chord_replay_end_to_end(errors: Array[String]) -> void:
	var det := ChordDetector.new()
	det.beta = 0.5
	det.configure(440.0, {}, ChordDetector.Taper.HANN)
	var replay := ChordReplay.new()
	while not replay.finished():
		var res := det.analyze_frame(replay.next_window(), float(replay.cursor_ms))
		replay.score(res.keys.keys(), res.usec)
	var report := replay.report()
	_expect(not report.is_empty(), "Replay report should not be empty", errors)
	# Core non-octave / non-extreme-bass replay cases must hit reliably at default beta=0.5.
	for case_idx in [0, 1, 2, 4, 6]:
		_expect(replay.delays[case_idx] >= 0,
			"Replay case '%s' missed!\n%s" % [ChordReplay.CASES[case_idx][0], report], errors)

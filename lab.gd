extends Control

const MusicUtils := preload("res://audio/music_utils.gd")
const Detector := preload("res://audio/pitch_detector.gd")
const ChordDetector := preload("res://chord/chord_detector.gd")
const LiveChordWorker := preload("res://chord/live_chord_worker.gd")
const ChordReplay := preload("res://chord/chord_replay.gd")
const GuidedChordTest := preload("res://chord/guided_chord_test.gd")
const KeyCalibration := preload("res://chord/key_calibration.gd")
const ANDROID_MIC := "android.permission.RECORD_AUDIO"
const GATE_DB := MusicUtils.GATE_DB
const STANDARD_A4 := MusicUtils.STANDARD_A4
# Allow substantial detuning while excluding an accidental octave.
const MIN_A4 := 390.0
const MAX_A4 := 490.0
const HOLD_SECONDS := 0.45
const MAX_SPREAD_CENTS := 18.0
const TUNING_FILE := "user://piano_tuning.cfg"
const PLAY_A4 := "Play and hold A4, the A above middle C."
const PROFILE_FILE := "user://piano_templates.cfg"
const TEMPLATE_SECTIONS := ["hann", "hamming", "blackman", "kaiser4"]
const WINDOW_LABELS := ["Hann", "Hamming", "Blackman", "Kaiser (shape 4)"]

@onready var note: Label = %Note
@onready var detail: Label = %Detail
@onready var level: ProgressBar = %Level
@onready var status: Label = %Status
@onready var metrics: Label = %Metrics
@onready var toggle: Button = %Toggle
@onready var calibrate: Button = %Calibrate
@onready var tuning_label: Label = %Tuning
@onready var mode: OptionButton = %Mode
@onready var replay_button: Button = %Replay
@onready var beta_slider: HSlider = %Beta
@onready var analysis_window: OptionButton = %AnalysisWindow
@onready var guided_button: Button = %GuidedTest
@onready var guided_record: Button = %GuidedRecord
@onready var profile: CheckButton = %Profile
@onready var learn_key: OptionButton = %LearnKey
@onready var learn: Button = %Learn
@onready var player: AudioStreamPlayer = $Microphone

var detector := Detector.new()
var capture := AudioEffectCapture.new()
var recent := PackedVector2Array()
var take_capture_start := 0
var sample_rate: float
var window_frames: int
var hop_frames: int
var fresh_frames := 0
var bus: int
var waiting_permission := false
var listening := false
var calibrating := false
var reference_hz := STANDARD_A4
var pitches: Array[float] = []
var stable_seconds := 0.0
var chord_detector := ChordDetector.new()
var live_chord_worker := LiveChordWorker.new()
var live_worker_started := false
var live_worker_failed := false
var chord_audio_ms := 0.0
var live_discarded := 0
var replay: ChordReplay
var guided_test: GuidedChordTest
var guided_pending := false
var guided_started_mic := false
var guided_discarded := 0
var guided_capture_start := 0
var replay_time := 0.0
var skipped_hops := 0
var discarded_at_start := 0
var piano_templates: Array[Dictionary] = []
var learning_key := 0
var learning_all := false
var key_calibration: KeyCalibration
var calibration_saved := 0
var learn_deadline := 0

func _ready() -> void:
	AudioServer.add_bus()
	bus = AudioServer.bus_count - 1
	AudioServer.set_bus_name(bus, "Piano microphone")
	AudioServer.add_bus_effect(bus, capture)
	AudioServer.set_bus_mute(bus, true)
	player.bus = AudioServer.get_bus_name(bus)
	toggle.pressed.connect(_toggle_capture)
	calibrate.pressed.connect(_toggle_calibration)
	mode.add_item("Single note")
	mode.add_item("Chord mode")
	mode.item_selected.connect(_mode_changed)
	replay_button.pressed.connect(_toggle_replay)
	%AttackDecay.record_requested.connect(_record_attack_decay)
	guided_button.pressed.connect(_toggle_guided_test)
	guided_record.pressed.connect(_record_guided_trial)
	beta_slider.value_changed.connect(_beta_changed)
	%AttackTime.value_changed.connect(_confirmation_changed)
	%SpectrumTime.value_changed.connect(_confirmation_changed)
	for window_index in WINDOW_LABELS.size():
		analysis_window.add_item("Live window · %s" % WINDOW_LABELS[window_index], window_index)
		piano_templates.append({})
	analysis_window.item_selected.connect(_window_changed)
	learn.pressed.connect(_toggle_learning)
	%RetryKey.pressed.connect(func(): _retry_key("Retrying · Release the key and pedal"))
	profile.toggled.connect(_profile_changed)
	learn_key.add_item("All keys (A0–C8)", 0)
	for key in range(ChordDetector.FIRST_KEY, ChordDetector.FIRST_KEY + ChordDetector.KEYS):
		learn_key.add_item(MusicUtils.note_name(key), key)
	learn_key.select(0)
	_load_templates()
	get_tree().on_request_permissions_result.connect(_permission_result)
	var settings := ConfigFile.new()
	if settings.load(TUNING_FILE) == OK:
		var saved = settings.get_value("tuning", "a4_hz", STANDARD_A4)
		if (saved is float or saved is int) and saved >= MIN_A4 and saved <= MAX_A4:
			reference_hz = saved
	_show_reference()

func _mode_changed(_index: int) -> void:
	var chords := mode.selected == 1
	%LiveHeading.visible = chords
	%AttackDecay.visible = chords
	%AttackDecay.cancel_take("Take canceled when switching modes.")
	replay_button.visible = chords
	%ChordSettings.visible = chords
	profile.visible = chords
	%LearningControls.visible = chords
	%Hint.text = "Play piano notes together, from A0 to C8." if chords else "Play one note at a time, from C3 to C6."
	note.add_theme_font_size_override("font_size", 32 if chords else 76)
	note.text = "—"
	detail.text = "No active keys" if chords else "No pitch"
	metrics.text = ""
	status.text = "Listening" if listening else "Ready to listen"
	_reset_analysis()

func _beta_changed(value: float) -> void:
	chord_detector.beta = value
	%BetaLabel.text = "Live β divergence · %.2f" % value
	chord_detector.reset()
	_configure_live_worker()

func _window_changed(_index: int) -> void:
	_update_profile_label()
	_reset_analysis()

func _confirmation_changed(_value: float) -> void:
	chord_detector.confirmation.attack_ms = %AttackTime.value
	chord_detector.confirmation.spectral_ms = %SpectrumTime.value
	%AttackDecay.attack_ms = %AttackTime.value
	%AttackDecay.spectral_ms = %SpectrumTime.value
	_reset_analysis()

func _set_confirmation_controls(enabled: bool) -> void:
	%AttackTime.editable = enabled
	%SpectrumTime.editable = enabled

func _reset_analysis() -> void:
	%AttackDecay.cancel_take("Capture settings changed. Start again for accurate timing.")
	sample_rate = AudioServer.get_mix_rate()
	var chords := mode.selected == 1 and not calibrating
	window_frames = roundi(sample_rate * (ChordDetector.WINDOW_SECONDS if chords else Detector.WINDOW_SECONDS))
	hop_frames = roundi(sample_rate * (ChordDetector.HOP_SECONDS if chords else 0.015))
	if chords and learning_key == 0:
		var templates := piano_templates[analysis_window.selected] if profile.button_pressed else {}
		chord_detector.configure(reference_hz, templates, analysis_window.selected as ChordDetector.Taper)
		_configure_live_worker()
	else:
		live_chord_worker.clear()
	recent.clear()
	fresh_frames = 0
	chord_audio_ms = 0.0
	skipped_hops = 0
	discarded_at_start = capture.get_discarded_frames()
	live_discarded = discarded_at_start
	capture.clear_buffer()

func _configure_live_worker() -> void:
	var templates := piano_templates[analysis_window.selected] if profile.button_pressed else {}
	live_chord_worker.configure(reference_hz, templates, analysis_window.selected as ChordDetector.Taper, chord_detector.beta,
			chord_detector.confirmation.attack_ms, chord_detector.confirmation.spectral_ms)

func _load_templates() -> void:
	var config := ConfigFile.new()
	if config.load(PROFILE_FILE) == OK:
		for window_index in TEMPLATE_SECTIONS.size():
			var section: String = TEMPLATE_SECTIONS[window_index]
			if not config.has_section(section):
				continue
			for label in config.get_section_keys(section):
				var key := label.to_int()
				var values = config.get_value(section, label)
				if learn_key.get_item_index(key) > 0 and values is PackedFloat32Array and values.size() == ChordDetector.BINS:
					piano_templates[window_index][key] = values
	_update_profile_label()

func _update_profile_label() -> void:
	var templates := piano_templates[analysis_window.selected]
	profile.text = "Use my piano templates (%d/88)" % templates.size()
	for index in range(1, learn_key.item_count):
		var key := learn_key.get_item_id(index)
		learn_key.set_item_text(index, MusicUtils.note_name(key) + (" ✓" if templates.has(key) else ""))

func _profile_changed(_enabled: bool) -> void:
	if listening:
		_reset_analysis()

func _toggle_learning() -> void:
	%AttackDecay.cancel_take("Take canceled when starting template learning.")
	if learning_key != 0:
		_end_learning()
		status.text = "Learning stopped · Recorded keys kept"
		return
	learning_all = learn_key.get_selected_id() == 0
	%AttackDecay.cancel_training()
	calibration_saved = 0
	var key := ChordDetector.FIRST_KEY if learning_all else learn_key.get_selected_id()
	_begin_key(key)
	_set_learning_controls(true)
	if listening:
		_reset_analysis()
	else:
		_toggle_capture()

func _begin_key(key: int, wait_for_release := false) -> void:
	learning_key = key
	key_calibration = KeyCalibration.new(roundi(AudioServer.get_mix_rate()), wait_for_release)
	discarded_at_start = capture.get_discarded_frames()
	learn_deadline = Time.get_ticks_msec() + 25000
	note.text = MusicUtils.note_name(key)
	detail.text = "Release the keys and pedal"
	status.text = "Learning %s" % MusicUtils.note_name(key)

func _set_learning_controls(active: bool) -> void:
	mode.disabled = active
	calibrate.disabled = active
	replay_button.disabled = active
	analysis_window.disabled = active
	guided_button.disabled = active
	profile.disabled = active
	learn_key.disabled = active
	_set_confirmation_controls(not active)
	learn.text = "Finish calibration" if active else "Calibrate keys"
	%RetryKey.visible = active

func _retry_key(message: String) -> void:
	if learning_key == 0:
		return
	var deadline := learn_deadline
	_begin_key(learning_key, true)
	learn_deadline = deadline
	status.text = message

func _end_learning() -> void:
	learning_key = 0
	key_calibration = null
	learning_all = false
	_set_learning_controls(false)
	if listening:
		_reset_analysis()
	if calibration_saved > 0:
		%AttackDecay.train_calibration()
		calibration_saved = 0

func _learn_from_audio(frames: PackedVector2Array) -> void:
	if capture.get_discarded_frames() != discarded_at_start:
		_retry_key("Audio dropped · Release the key and wait for the next prompt")
		return
	key_calibration.append(frames)
	level.value = key_calibration.db
	if key_calibration.rejected:
		_retry_key("Strike was too brief · Release the key and try again at the prompt")
		return
	if key_calibration.onset >= 0:
		detail.text = "Hold %s" % MusicUtils.note_name(learning_key)
	elif key_calibration.armed:
		detail.text = "Play %s once and hold it" % MusicUtils.note_name(learning_key)
	if key_calibration.complete:
		_save_learned_key()

func _save_learned_key() -> void:
	var key := learning_key
	var rate := key_calibration.rate
	var size := roundi(rate * ChordDetector.WINDOW_SECONDS)
	var windows: Array[PackedVector2Array] = []
	for offset in [0.05, 0.10, 0.15, 0.20]:
		var first := key_calibration.onset + roundi(rate * float(offset))
		windows.append(key_calibration.audio.slice(first, first + size))
	for window_index in TEMPLATE_SECTIONS.size():
		var total := PackedFloat32Array()
		total.resize(ChordDetector.BINS)
		var count := 0
		for frames in windows:
			var measured := chord_detector.measure_template(frames, window_index as ChordDetector.Taper)
			if not measured.is_empty():
				for bin in measured.size():
					total[bin] += measured[bin]
				count += 1
		if count > 0:
			for bin in total.size():
				total[bin] /= count
			piano_templates[window_index][key] = total
	var audio_saved := key_calibration.save_note(key) == OK
	if audio_saved:
		calibration_saved += 1
	var config := ConfigFile.new()
	for window_index in TEMPLATE_SECTIONS.size():
		var templates := piano_templates[window_index]
		for learned: int in templates:
			config.set_value(TEMPLATE_SECTIONS[window_index], str(learned), templates[learned])
	var saved := config.save(PROFILE_FILE) == OK
	_update_profile_label()
	profile.set_pressed_no_signal(true)
	if saved and audio_saved and learning_all and key < ChordDetector.FIRST_KEY + ChordDetector.KEYS - 1:
		_begin_key(key + 1, true)
		return
	_end_learning()
	if not audio_saved:
		status.text = "Could not save the strike recording."
	elif not saved:
		status.text = "Strike saved · Live templates could not be saved."
	else:
		status.text = "%s calibration saved" % MusicUtils.note_name(key)
		detail.text = "Release the key"

func _show_reference() -> void:
	var cents := MusicUtils.cents_diff(reference_hz, STANDARD_A4)
	tuning_label.text = "Reference A4   %.1f Hz   ·   %+.0f cents" % [reference_hz, cents]

func _toggle_calibration() -> void:
	%AttackDecay.cancel_take("Take canceled when starting A4 calibration.")
	if calibrating:
		_end_calibration()
		status.text = "Calibration canceled"
		return
	calibrating = true
	mode.disabled = true
	replay_button.disabled = true
	guided_button.disabled = true
	learn.disabled = true
	profile.disabled = true
	calibrate.text = "Cancel"
	status.text = PLAY_A4
	if listening:
		_reset_analysis()
	else:
		_toggle_capture()

func _end_calibration() -> void:
	calibrating = false
	calibrate.text = "Calibrate"
	pitches.clear()
	stable_seconds = 0.0
	mode.disabled = false
	replay_button.disabled = false
	guided_button.disabled = false
	learn.disabled = false
	profile.disabled = false
	if listening:
		_reset_analysis()

func _toggle_capture() -> void:
	if listening:
		_stop()
	elif OS.get_name() == "Android" and not OS.get_granted_permissions().has(ANDROID_MIC):
		waiting_permission = true
		toggle.disabled = true
		calibrate.disabled = true
		mode.disabled = true
		replay_button.disabled = true
		learn.disabled = true
		status.text = "Waiting for microphone permission…"
		if OS.request_permission(ANDROID_MIC):
			_permission_result(ANDROID_MIC, true)
	else:
		_start()

func _permission_result(permission: String, granted: bool) -> void:
	if permission != ANDROID_MIC or not waiting_permission:
		return
	waiting_permission = false
	toggle.disabled = false
	calibrate.disabled = learning_key != 0
	mode.disabled = calibrating or learning_key != 0
	replay_button.disabled = mode.disabled
	learn.disabled = calibrating
	if granted:
		_start()
	else:
		guided_pending = false
		_end_calibration()
		if learning_key != 0:
			_end_learning()
		status.text = "Allow microphone access in Settings, then try again."

func _start() -> void:
	_reset_analysis()
	player.play()
	listening = true
	if learning_key != 0:
		_begin_key(learning_key)
	else:
		status.text = PLAY_A4 if calibrating else "Listening"
	toggle.text = "Stop microphone"
	if guided_pending:
		_begin_guided_test()

func _stop() -> void:
	%AttackDecay.finish_take()
	player.stop()
	listening = false
	live_chord_worker.clear()
	_end_calibration()
	if learning_key != 0:
		_end_learning()
	note.text = "—"
	detail.text = "No pitch"
	level.value = level.min_value
	metrics.text = ""
	status.text = "Microphone stopped"
	toggle.text = "Start microphone"
	if guided_test != null:
		_finish_guided_test()

func _process(delta: float) -> void:
	%AttackDecay.set_input_available(replay == null and not calibrating and learning_key == 0 and guided_test == null and not waiting_permission)
	if replay != null:
		_advance_replay(delta)
		return
	if not listening:
		return
	if mode.selected == 1 and not calibrating and learning_key == 0 and guided_test == null and live_worker_started:
		var result := live_chord_worker.take_latest()
		if not result.is_empty():
			_show_chord_result(result.keys, result.db, result.usec)
	if learning_key != 0 and Time.get_ticks_msec() >= learn_deadline:
		_end_learning()
		status.text = "Learning timed out · Recorded keys kept"
		return
	var count := capture.get_frames_available()
	if count == 0:
		return
	var captured := capture.get_buffer(count)
	if learning_key != 0:
		_learn_from_audio(captured)
		return
	if %AttackDecay.recording or %AttackDecay.following:
		if capture.get_discarded_frames() != take_capture_start:
			%AttackDecay.cancel_take("Audio was dropped. Record another take for accurate strike times.")
		else:
			%AttackDecay.add_samples(captured)
	if guided_test != null and not guided_test.recording():
		return
	if guided_test == null and mode.selected == 1 and not calibrating:
		var discarded := capture.get_discarded_frames()
		if discarded != live_discarded:
			live_discarded = discarded
			recent.clear()
			chord_detector.reset()
			live_chord_worker.clear()
	recent.append_array(captured)
	if guided_test != null:
		guided_test.samples.append_array(captured)
	if mode.selected == 1 and not calibrating:
		_process_chords()
		if guided_test != null and guided_test.advance_prompt():
			if not guided_test.recording():
				guided_discarded += capture.get_discarded_frames() - guided_capture_start
			if guided_test.finished():
				_finish_guided_test()
			else:
				_update_guided_prompt()
		return
	fresh_frames += count
	if recent.size() < window_frames or fresh_frames < hop_frames:
		return
	var elapsed := fresh_frames / sample_rate
	fresh_frames = 0
	recent = recent.slice(-window_frames)
	var db := MusicUtils.input_level_db(recent)
	level.value = db
	var start := Time.get_ticks_usec()
	var tuning_ratio := 1.0 if calibrating else reference_hz / STANDARD_A4
	var hz := detector.estimate(recent, sample_rate, tuning_ratio) if db >= GATE_DB else 0.0
	var analysis_ms := (Time.get_ticks_usec() - start) / 1000.0
	metrics.text = "%.0f dBFS   ·   %.1f ms analysis" % [db, analysis_ms]
	if calibrating:
		_sample_calibration(hz, elapsed)
		return
	if hz <= 0.0:
		note.text = "—"
		detail.text = "No stable pitch"
		status.text = "Low input · Check mic access or play closer" if db < GATE_DB else "Listening · Play one piano key"
		return
	var pitch := MusicUtils.hz_to_midi(hz, reference_hz)
	var midi := roundi(pitch)
	note.text = MusicUtils.note_name(midi)
	detail.text = "%.1f Hz   ·   %+.0f cents" % [hz, (pitch - midi) * 100.0]
	status.text = "Listening · Pitch detected"

func _process_chords() -> void:
	if recent.size() < window_frames:
		return
	var hops := 1 + floori(float(recent.size() - window_frames) / hop_frames)
	if guided_test == null:
		var latest_offset := (hops - 1) * hop_frames
		var frames := recent.slice(latest_offset, latest_offset + window_frames)
		recent = recent.slice(latest_offset + hop_frames)
		chord_audio_ms += 1000.0 * hops * hop_frames / sample_rate
		if not live_worker_started and not live_worker_failed:
			var error := live_chord_worker.start()
			live_worker_started = error == OK
			live_worker_failed = not live_worker_started
			if live_worker_failed:
				push_warning("Could not start chord analysis thread: %s" % error_string(error))
		if live_worker_started:
			live_chord_worker.submit(frames, chord_audio_ms)
		else:
			_analyze_chord(frames, true, -1, chord_audio_ms)
		return

	# Guided tests keep a bounded backlog.
	var skipped := maxi(0, hops - 4)
	var offset := skipped * hop_frames
	if skipped > 0:
		skipped_hops += skipped
		chord_detector.reset()
	for h in range(skipped, hops):
		var end_sample := -1
		if guided_test != null:
			end_sample = guided_test.samples.size() - recent.size() + offset + window_frames
		_analyze_chord(recent.slice(offset, offset + window_frames), h == hops - 1, end_sample, 1000.0 * end_sample / sample_rate)
		if recent.is_empty():
			return
		offset += hop_frames
	recent = recent.slice(offset)

func _analyze_chord(frames: PackedVector2Array, display: bool, end_sample := -1, audio_ms := -1.0) -> void:
	var result := chord_detector.analyze_frame(frames, audio_ms)
	var db: float = result.db
	var keys: Dictionary = result.keys
	var usec: int = result.usec
	if end_sample >= 0:
		guided_test.record_frame(end_sample, db, usec, chord_detector.gains, keys, result.raw_keys)
	if replay != null:
		if display:
			status.text = "Expected · %s" % ChordReplay.CASES[floori(replay.cursor_ms / 1000.0)][0]
		replay.score(keys.keys(), usec)
	if display:
		_show_chord_result(keys, db, usec)

func _show_chord_result(keys: Dictionary, db: float, usec: int) -> void:
	level.value = db
	var names := PackedStringArray()
	var strengths := PackedStringArray()
	for key: int in keys:
		var key_name := MusicUtils.note_name(key)
		names.append(key_name)
		strengths.append("%s %d%%" % [key_name, roundi(100 * keys[key])])
	note.text = "  ".join(names) if not names.is_empty() else "—"
	detail.text = "Fitted strength · " + "   ".join(strengths) if not strengths.is_empty() else "No active keys"
	metrics.text = "%.0f dBFS · %.1f ms analysis" % [db, usec / 1000.0]
	if replay == null:
		status.text = "Listening"
		var discarded := capture.get_discarded_frames() - discarded_at_start
		if skipped_hops > 0 or discarded > 0:
			status.text = "Skipped %d hops · %d capture frames lost" % [skipped_hops, discarded]

func _toggle_guided_test() -> void:
	%AttackDecay.cancel_take("Take canceled when starting the guided test.")
	if guided_test != null:
		_finish_guided_test()
	elif listening:
		guided_started_mic = false
		_reset_analysis()
		_begin_guided_test()
	else:
		guided_started_mic = true
		guided_pending = true
		guided_button.disabled = true
		_toggle_capture()

func _begin_guided_test() -> void:
	guided_pending = false
	var templates := piano_templates[analysis_window.selected] if profile.button_pressed else {}
	guided_test = GuidedChordTest.new(roundi(sample_rate), {
		"beta": chord_detector.beta,
		"window": TEMPLATE_SECTIONS[analysis_window.selected],
		"a4_hz": reference_hz,
		"personal_templates": templates,
		"first_midi_key": ChordDetector.FIRST_KEY,
		"window_samples": window_frames,
		"hop_samples": hop_frames,
		"fft_size": ChordDetector.FFT_SIZE,
		"attack_confirmation_ms": chord_detector.confirmation.attack_ms,
		"spectral_confirmation_ms": chord_detector.confirmation.spectral_ms
	})
	guided_discarded = 0
	_set_guided_controls(true)
	guided_button.text = "Stop and save test"
	guided_record.show()
	_update_guided_prompt()
	%GuidedPrompt.show()

func _record_guided_trial() -> void:
	if guided_test == null or guided_test.recording():
		return
	recent.clear()
	capture.clear_buffer()
	guided_capture_start = capture.get_discarded_frames()
	chord_detector.reset()
	guided_test.start_trial()
	_update_guided_prompt()

func _update_guided_prompt() -> void:
	%GuidedPrompt.text = guided_test.prompt_text()
	guided_record.disabled = guided_test.recording()
	guided_record.text = "Recording…" if guided_test.recording() else "Record"

func _set_guided_controls(active: bool) -> void:
	mode.disabled = active
	replay_button.disabled = active
	toggle.disabled = active
	calibrate.disabled = active
	profile.disabled = active
	learn_key.disabled = active
	learn.disabled = active
	beta_slider.editable = not active
	_set_confirmation_controls(not active)
	analysis_window.disabled = active
	guided_button.disabled = false

func _finish_guided_test() -> void:
	var test := guided_test
	guided_test = null
	if test.recording():
		guided_discarded += capture.get_discarded_frames() - guided_capture_start
	var recorded_skips := skipped_hops
	_set_guided_controls(false)
	guided_record.hide()
	if guided_started_mic and listening:
		_stop()
	elif listening:
		_reset_analysis()
	guided_button.text = "Guided microphone test"
	if test.samples.is_empty():
		%GuidedPrompt.text = "Test ended before any audio was recorded."
		return
	var error := test.save(guided_discarded, recorded_skips)
	if error == OK:
		%GuidedPrompt.text = "Test saved · %s (.wav and .json)" % test.output_path
	else:
		%GuidedPrompt.text = "Could not save the test · %s" % error_string(error)

func _set_replay_controls(active: bool) -> void:
	mode.disabled = active
	toggle.disabled = active
	calibrate.disabled = active
	learn.disabled = active
	learn_key.disabled = active
	profile.disabled = active
	beta_slider.editable = not active
	_set_confirmation_controls(not active)
	analysis_window.disabled = active
	guided_button.disabled = active
	replay_button.text = "Stop replay" if active else "Replay test"

func _toggle_replay() -> void:
	if replay != null:
		_end_replay()
		return
	%AttackDecay.cancel_take("Take canceled when starting the replay.")
	if listening:
		_stop()
	replay = ChordReplay.new()
	%AttackDecay.analyze_replay(replay.samples, ChordReplay.AUDIO.mix_rate, true)
	replay_time = ChordReplay.WINDOW_MS / 1000.0
	chord_detector.configure(STANDARD_A4, {}, analysis_window.selected as ChordDetector.Taper)
	tuning_label.text = "Replay reference A4   440 Hz"
	_set_replay_controls(true)

func _advance_replay(delta: float) -> void:
	replay_time += delta
	for _step in 6:
		if replay.finished():
			var report := replay.report()
			_end_replay()
			%Results.dialog_text = "β %.2f · %s\n3 consecutive exact updates · %% exact\n\n%s" % [chord_detector.beta, analysis_window.text, report]
			%Results.popup_centered()
			return
		if replay.cursor_ms > replay_time * 1000:
			return
		_analyze_chord(replay.next_window(), true, -1, float(replay.cursor_ms))

func _end_replay() -> void:
	replay = null
	_set_replay_controls(false)
	_stop()
	_show_reference()

func _record_attack_decay(follow: bool) -> void:
	if replay != null or calibrating or learning_key != 0 or guided_test != null:
		return
	if not listening:
		_toggle_capture()
	if listening:
		capture.clear_buffer()
		recent.clear()
		take_capture_start = capture.get_discarded_frames()
		%AttackDecay.start_take(roundi(sample_rate), follow)

func _sample_calibration(hz: float, elapsed: float) -> void:
	note.text = "A4"
	if hz < MIN_A4 or hz > MAX_A4:
		pitches.clear()
		stable_seconds = 0.0
		detail.text = "Waiting for A4" if hz <= 0.0 else "Heard %.1f Hz · Try A4" % hz
		status.text = PLAY_A4
		return

	pitches.append(hz)
	if MusicUtils.cents_diff(pitches.max(), pitches.min()) > MAX_SPREAD_CENTS:
		pitches.assign([hz])
		stable_seconds = 0.0
	# A stalled UI frame only provides one analyzed window of evidence.
	stable_seconds += minf(elapsed, Detector.WINDOW_SECONDS)
	detail.text = "%.1f Hz   ·   Hold steady %d%%" % [hz, mini(100, roundi(100 * stable_seconds / HOLD_SECONDS))]
	if stable_seconds < HOLD_SECONDS:
		return

	pitches.sort()
	reference_hz = pitches[pitches.size() >> 1]
	_end_calibration()
	_show_reference()
	var settings := ConfigFile.new()
	settings.set_value("tuning", "a4_hz", reference_hz)
	if settings.save(TUNING_FILE) != OK:
		tuning_label.text += " (this session)"
	detail.text = "%.1f Hz   ·   Calibrated" % reference_hz
	status.text = "Tuning applied · Play any note"

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED and replay != null:
		_end_replay()
	if what == NOTIFICATION_APPLICATION_PAUSED and listening:
		_stop()

func _exit_tree() -> void:
	live_chord_worker.shutdown()
	if bus > 0:
		AudioServer.remove_bus(bus)

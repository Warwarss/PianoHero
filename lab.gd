extends Control

const Detector := preload("res://pitch_detector.gd")
const ChordDetector := preload("res://chord/chord_detector.gd")
const ChordReplay := preload("res://chord/chord_replay.gd")
const NAMES := ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
const ANDROID_MIC := "android.permission.RECORD_AUDIO"
const GATE_DB := -55.0
const STANDARD_A4 := 440.0
# Allow substantial detuning while excluding an accidental octave.
const MIN_A4 := 390.0
const MAX_A4 := 490.0
const HOLD_SECONDS := 0.45
const MAX_SPREAD_CENTS := 18.0
const TUNING_FILE := "user://piano_tuning.cfg"
const PLAY_A4 := "Play and hold A4, the A above middle C."
const PROFILE_FILE := "user://piano_templates.cfg"
const QUIET_HOPS := 12
const TEMPLATE_HOPS := 25
const ATTACK_HOPS := 5
const MIN_TEMPLATE_HOPS := 12
const LEARNING_GATE_DB := -45.0

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
@onready var solver_choice: OptionButton = %Solver
@onready var profile: CheckButton = %Profile
@onready var learn_key: OptionButton = %LearnKey
@onready var learn: Button = %Learn
@onready var player: AudioStreamPlayer = $Microphone

var detector := Detector.new()
var capture := AudioEffectCapture.new()
var recent := PackedVector2Array()
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
var replay: ChordReplay
var replay_time := 0.0
var skipped_hops := 0
var discarded_at_start := 0
var personal_templates := {}
var learning_key := 0
var learning_all := false
var quiet_hops := 0
var template_hops := 0
var template_sum := PackedFloat32Array()
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
	solver_choice.add_item("Solver · Squared error", ChordDetector.Solver.SQUARED_ERROR)
	solver_choice.add_item("Solver · β-divergence (0.5)", ChordDetector.Solver.BETA_HALF)
	solver_choice.item_selected.connect(_solver_changed)
	learn.pressed.connect(_toggle_learning)
	profile.toggled.connect(_profile_changed)
	learn_key.add_item("All keys (A0–C8)", 0)
	for key in range(ChordDetector.FIRST_KEY, ChordDetector.FIRST_KEY + ChordDetector.KEYS):
		learn_key.add_item(_note_name(key), key)
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
	replay_button.visible = chords
	solver_choice.visible = chords
	profile.visible = chords
	%LearningControls.visible = chords
	%Hint.text = "Play piano notes together, from A0 to C8." if chords else "Play one note at a time, from C3 to C6."
	note.add_theme_font_size_override("font_size", 32 if chords else 76)
	note.text = "—"
	detail.text = "No active keys" if chords else "No pitch"
	metrics.text = ""
	status.text = "Listening" if listening else "Ready to listen"
	_reset_analysis()

func _solver_changed(index: int) -> void:
	chord_detector.solver = solver_choice.get_item_id(index) as ChordDetector.Solver
	chord_detector.reset()

func _reset_analysis() -> void:
	sample_rate = AudioServer.get_mix_rate()
	var chords := mode.selected == 1 and not calibrating
	window_frames = roundi(sample_rate * (ChordDetector.WINDOW_SECONDS if chords else Detector.WINDOW_SECONDS))
	hop_frames = roundi(sample_rate * (ChordDetector.HOP_SECONDS if chords else 0.015))
	if chords and learning_key == 0:
		chord_detector.configure(reference_hz, personal_templates if profile.button_pressed else {})
	recent.clear()
	fresh_frames = 0
	skipped_hops = 0
	discarded_at_start = capture.get_discarded_frames()
	capture.clear_buffer()

func _note_name(key: int) -> String:
	return "%s%d" % [NAMES[key % 12], floori(key / 12.0) - 1]

func _load_templates() -> void:
	var config := ConfigFile.new()
	if config.load(PROFILE_FILE) == OK and config.has_section("keys"):
		for label in config.get_section_keys("keys"):
			var key := label.to_int()
			var values = config.get_value("keys", label)
			if learn_key.get_item_index(key) > 0 and values is PackedFloat32Array and values.size() == ChordDetector.BINS:
				personal_templates[key] = values
	_update_profile_label()

func _update_profile_label() -> void:
	profile.text = "Use my piano templates (%d/88)" % personal_templates.size()
	for key: int in personal_templates:
		learn_key.set_item_text(learn_key.get_item_index(key), "%s ✓" % _note_name(key))

func _profile_changed(_enabled: bool) -> void:
	if listening:
		_reset_analysis()

func _toggle_learning() -> void:
	if learning_key != 0:
		_end_learning()
		status.text = "Learning stopped · Recorded keys kept"
		return
	learning_all = learn_key.get_selected_id() == 0
	var key := ChordDetector.FIRST_KEY if learning_all else learn_key.get_selected_id()
	_begin_key(key)
	_set_learning_controls(true)
	if listening:
		_reset_analysis()
	else:
		_toggle_capture()

func _begin_key(key: int) -> void:
	learning_key = key
	quiet_hops = 0
	template_hops = 0
	template_sum.resize(ChordDetector.BINS)
	template_sum.fill(0.0)
	learn_deadline = Time.get_ticks_msec() + 25000
	note.text = _note_name(key)
	detail.text = "Release the keys and pedal"
	status.text = "Learning %s" % _note_name(key)

func _set_learning_controls(active: bool) -> void:
	mode.disabled = active
	calibrate.disabled = active
	replay_button.disabled = active
	profile.disabled = active
	learn_key.disabled = active
	learn.text = "Stop learning" if active else "Learn"

func _end_learning() -> void:
	learning_key = 0
	learning_all = false
	_set_learning_controls(false)
	if listening:
		_reset_analysis()

func _learn_from_frame(frames: PackedVector2Array, db: float) -> void:
	level.value = db
	if quiet_hops < QUIET_HOPS:
		quiet_hops = quiet_hops + 1 if db < LEARNING_GATE_DB else 0
		if quiet_hops == QUIET_HOPS:
			detail.text = "Play %s once and hold it" % _note_name(learning_key)
		return
	if db < LEARNING_GATE_DB:
		if template_hops >= MIN_TEMPLATE_HOPS:
			_save_learned_key()
		elif template_hops > 0:
			_begin_key(learning_key)
		return
	var measured := chord_detector.measure_template(frames)
	if measured.is_empty():
		return
	# Leave the first 50 ms for the attack, then average the next windows.
	if template_hops >= ATTACK_HOPS:
		for bin in measured.size():
			template_sum[bin] += measured[bin]
	template_hops += 1
	detail.text = "Hold %s · %d%%" % [_note_name(learning_key), 4 * template_hops]
	if template_hops == TEMPLATE_HOPS:
		_save_learned_key()

func _save_learned_key() -> void:
	var key := learning_key
	for bin in template_sum.size():
		template_sum[bin] /= template_hops - ATTACK_HOPS
	personal_templates[key] = template_sum.duplicate()
	var config := ConfigFile.new()
	for learned: int in personal_templates:
		config.set_value("keys", str(learned), personal_templates[learned])
	var saved := config.save(PROFILE_FILE) == OK
	_update_profile_label()
	profile.set_pressed_no_signal(true)
	if saved and learning_all and key < ChordDetector.FIRST_KEY + ChordDetector.KEYS - 1:
		_begin_key(key + 1)
		return
	_end_learning()
	status.text = "%s saved" % _note_name(key) if saved else "Templates available for this session · Save failed"

func _show_reference() -> void:
	var cents := 1200.0 * log(reference_hz / STANDARD_A4) / log(2.0)
	tuning_label.text = "Reference A4   %.1f Hz   ·   %+.0f cents" % [reference_hz, cents]

func _toggle_calibration() -> void:
	if calibrating:
		_end_calibration()
		status.text = "Calibration canceled"
		return
	calibrating = true
	mode.disabled = true
	replay_button.disabled = true
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

func _stop() -> void:
	player.stop()
	listening = false
	_end_calibration()
	if learning_key != 0:
		_end_learning()
	note.text = "—"
	detail.text = "No pitch"
	level.value = level.min_value
	metrics.text = ""
	status.text = "Microphone stopped"
	toggle.text = "Start microphone"

func _process(delta: float) -> void:
	if replay != null:
		_advance_replay(delta)
		return
	if not listening:
		return
	if learning_key != 0 and Time.get_ticks_msec() >= learn_deadline:
		_end_learning()
		status.text = "Learning timed out · Recorded keys kept"
		return
	var count := capture.get_frames_available()
	if count == 0:
		return
	recent.append_array(capture.get_buffer(count))
	if mode.selected == 1 and not calibrating:
		_process_chords()
		return
	fresh_frames += count
	if recent.size() < window_frames or fresh_frames < hop_frames:
		return
	var elapsed := fresh_frames / sample_rate
	fresh_frames = 0
	recent = recent.slice(-window_frames)
	var energy := 0.0
	for frame in recent:
		energy += frame.length_squared() * 0.5
	var db := linear_to_db(maxf(0.000001, sqrt(energy / recent.size())))
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
	var pitch := 69.0 + 12.0 * log(hz / reference_hz) / log(2.0)
	var midi := roundi(pitch)
	note.text = "%s%d" % [NAMES[midi % 12], floori(midi / 12.0) - 1]
	detail.text = "%.1f Hz   ·   %+.0f cents" % [hz, (pitch - midi) * 100.0]
	status.text = "Listening · Pitch detected"

func _process_chords() -> void:
	if recent.size() < window_frames:
		return
	var hops := 1 + floori(float(recent.size() - window_frames) / hop_frames)
	# Bound catch-up work after a stalled frame and surface the lost hops.
	var skipped := maxi(0, hops - 4)
	var offset := skipped * hop_frames
	skipped_hops += skipped
	if skipped > 0:
		chord_detector.reset()
	for h in range(skipped, hops):
		_analyze_chord(recent.slice(offset, offset + window_frames), h == hops - 1)
		if recent.is_empty():
			return
		offset += hop_frames
	recent = recent.slice(offset)

func _analyze_chord(frames: PackedVector2Array, display: bool) -> void:
	var start := Time.get_ticks_usec()
	var power := 0.0
	for frame in frames:
		power += frame.length_squared() * 0.5
	var db := linear_to_db(maxf(0.000001, sqrt(power / frames.size())))
	if learning_key != 0:
		_learn_from_frame(frames, db)
		return
	var keys := {}
	if db >= GATE_DB:
		keys = chord_detector.estimate(frames)
	else:
		chord_detector.reset()
	var usec := Time.get_ticks_usec() - start
	if replay != null:
		if display:
			status.text = "Expected · %s" % ChordReplay.CASES[floori(replay.cursor_ms / 1000.0)][0]
		replay.score(keys.keys(), usec)
	if not display:
		return
	level.value = db
	var names := PackedStringArray()
	var strengths := PackedStringArray()
	for key: int in keys:
		var key_name := _note_name(key)
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

func _toggle_replay() -> void:
	if replay != null:
		_end_replay()
		return
	if listening:
		_stop()
	replay = ChordReplay.new()
	replay_time = ChordReplay.WINDOW_MS / 1000.0
	chord_detector.configure(STANDARD_A4)
	tuning_label.text = "Replay reference A4   440 Hz"
	mode.disabled = true
	toggle.disabled = true
	calibrate.disabled = true
	learn.disabled = true
	profile.disabled = true
	solver_choice.disabled = true
	replay_button.text = "Stop replay"

func _advance_replay(delta: float) -> void:
	replay_time += delta
	for _step in 6:
		if replay.finished():
			var report := replay.report()
			_end_replay()
			var solver_name := solver_choice.get_item_text(solver_choice.selected)
			%Results.dialog_text = solver_name + "\n3 consecutive exact updates · % exact\n\n" + report
			%Results.popup_centered()
			return
		if replay.cursor_ms > replay_time * 1000:
			return
		_analyze_chord(replay.next_window(), true)

func _end_replay() -> void:
	replay = null
	mode.disabled = false
	toggle.disabled = false
	calibrate.disabled = false
	solver_choice.disabled = false
	replay_button.text = "Replay test"
	_stop()
	_show_reference()

func _sample_calibration(hz: float, elapsed: float) -> void:
	note.text = "A4"
	if hz < MIN_A4 or hz > MAX_A4:
		pitches.clear()
		stable_seconds = 0.0
		detail.text = "Waiting for A4" if hz <= 0.0 else "Heard %.1f Hz · Try A4" % hz
		status.text = PLAY_A4
		return

	pitches.append(hz)
	if 1200.0 * log(pitches.max() / pitches.min()) / log(2.0) > MAX_SPREAD_CENTS:
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
	if bus > 0:
		AudioServer.remove_bus(bus)

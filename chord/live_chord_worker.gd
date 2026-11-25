extends RefCounted

const Detector := preload("res://chord/chord_detector.gd")

var _thread := Thread.new()
var _mutex := Mutex.new()
var _ready_to_analyze := Semaphore.new()
var _settings := {}
var _generation := 0
var _pending := PackedVector2Array()
var _pending_ms := 0.0
var _latest := {}
var _wake_pending := false
var _stopping := false

func start() -> Error:
	return _thread.start(_run)

func configure(a4: float, templates: Dictionary, taper: Detector.Taper, beta: float,
		attack_ms := 20.0, spectral_ms := 40.0) -> void:
	# Learned templates are replaced on the main thread. Snapshot the dictionary
	# so a running analysis can finish using its previous settings.
	var settings := {"a4": a4, "templates": templates.duplicate(), "taper": taper, "beta": beta,
			"attack_ms": attack_ms, "spectral_ms": spectral_ms}
	_mutex.lock()
	_settings = settings
	_clear_locked()
	_mutex.unlock()

func clear() -> void:
	_mutex.lock()
	_clear_locked()
	_mutex.unlock()

func _clear_locked() -> void:
	_generation += 1
	_pending = PackedVector2Array()
	_latest = {}

func submit(frames: PackedVector2Array, audio_ms: float) -> void:
	_mutex.lock()
	_pending = frames
	_pending_ms = audio_ms
	var should_wake := not _wake_pending
	_wake_pending = true
	_mutex.unlock()
	if should_wake:
		_ready_to_analyze.post()

func take_latest() -> Dictionary:
	_mutex.lock()
	var result := _latest
	_latest = {}
	_mutex.unlock()
	return result

func shutdown() -> void:
	if not _thread.is_started():
		return
	_mutex.lock()
	_stopping = true
	_clear_locked()
	_mutex.unlock()
	_ready_to_analyze.post()
	_thread.wait_to_finish()

func _run() -> void:
	var detector := Detector.new()
	var configured_generation := -1
	while true:
		_ready_to_analyze.wait()
		_mutex.lock()
		var stopping := _stopping
		var frames := _pending
		var audio_ms := _pending_ms
		var settings := _settings
		var generation := _generation
		_pending = PackedVector2Array()
		_wake_pending = false
		_mutex.unlock()
		if stopping:
			return
		if frames.is_empty():
			continue
		if configured_generation != generation:
			detector.configure(settings.a4, settings.templates, settings.taper as Detector.Taper)
			detector.beta = settings.beta
			detector.confirmation.attack_ms = settings.attack_ms
			detector.confirmation.spectral_ms = settings.spectral_ms
			configured_generation = generation
		var result := detector.analyze_frame(frames, audio_ms)
		_mutex.lock()
		if generation == _generation:
			_latest = result
		_mutex.unlock()

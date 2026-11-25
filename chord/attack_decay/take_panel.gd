extends PanelContainer
## Runs the batch fit in a separate process so a take cannot stall the live chord UI.
signal record_requested(follow: bool)

const MAX_SECONDS := 8
const FOLLOW_WINDOW := 1.6
const FOLLOW_MARGIN := 0.4
const ASSET_DIR := "res://chord/attack_decay/"
const WORK_DIR := "user://attack-decay/"
const DEFAULT_BANK := "salamander.npz"
const PERSONAL_BANK := WORK_DIR + "My piano.npz"
const CALIBRATION_REPORT := WORK_DIR + "calibration-check.json"
const STALE_BANK_MESSAGE := "My piano is out of date. Select another bank or wait for training."
const RUNTIME_FILES := ["model.py", "run_take.py", DEFAULT_BANK]
const KeyCalibration := preload("res://chord/key_calibration.gd")

var recording := false
var following := false
var received := 0
var committed := 0
var follow_history: Array = []
var follow_gap := false
var job_is_follow := false
var final_follow_fit := false
var job_origin := 0
var job_from := 0
var job_until := 0
var samples := PackedVector2Array()
var rate := 44100
var worker_pid := -1
var trainer_pid := -1
var training_path := ""
var runtime_dir := ""
var job_path := ""
var bank_override := ""
var input_available := true
var attack_ms := 20.0
var spectral_ms := 40.0
var desktop := OS.get_name() in ["Windows", "macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]

func _ready() -> void:
	%TakeButton.pressed.connect(_on_take_button)
	%FollowButton.pressed.connect(_on_follow_button)
	%ChooseBank.add_item("Salamander grand · 88 keys")
	var local_banks := ProjectSettings.globalize_path("res://build/attack-decay")
	if desktop and DirAccess.dir_exists_absolute(local_banks):
		for file in DirAccess.get_files_at(local_banks):
			if file.get_extension().to_lower() == "npz":
				_add_bank_option(local_banks.path_join(file))
		%BankDialog.current_dir = local_banks
	%ChooseBank.add_item("Browse for trained bank…")
	%ChooseBank.item_selected.connect(_bank_choice)
	%BankDialog.file_selected.connect(_load_bank_file)
	%BankDialog.canceled.connect(_restore_bank_choice)
	%TrainBank.pressed.connect(train_calibration)
	if desktop and FileAccess.file_exists(PERSONAL_BANK):
		_load_bank_file(ProjectSettings.globalize_path(PERSONAL_BANK))
	if not desktop:
		%TakeStatus.text = "The attack/decay experiment currently runs on desktop."
	_refresh_buttons()
	set_process(false)
	if desktop and _personal_bank_outdated():
		train_calibration.call_deferred()
	elif desktop and FileAccess.file_exists(CALIBRATION_REPORT):
		var report: Variant = JSON.parse_string(FileAccess.get_file_as_string(CALIBRATION_REPORT))
		if report is Dictionary:
			_show_calibration_report(report)

func _personal_bank_outdated() -> bool:
	if not DirAccess.dir_exists_absolute(KeyCalibration.PROFILE_DIR):
		return false
	var bank_time := FileAccess.get_modified_time(PERSONAL_BANK)
	for file in DirAccess.get_files_at(KeyCalibration.PROFILE_DIR):
		if file.get_extension() == "pcm" and FileAccess.get_modified_time(KeyCalibration.PROFILE_DIR.path_join(file)) > bank_time:
			return true
	return false

func _refresh_buttons() -> void:
	var stale := desktop and _stale_bank_selected()
	%TakeButton.disabled = not desktop or worker_pid >= 0 or not input_available or following or (stale and not recording)
	%FollowButton.disabled = not desktop or not input_available or recording or ((worker_pid >= 0 or stale) and not following)
	%FollowButton.text = "Stop following" if following else "Follow strikes"
	%ChooseBank.disabled = not desktop or worker_pid >= 0 or recording or following
	%TrainBank.visible = desktop and DirAccess.dir_exists_absolute(KeyCalibration.PROFILE_DIR) and not DirAccess.get_files_at(KeyCalibration.PROFILE_DIR).is_empty()
	%TrainBank.disabled = not training_path.is_empty() or not input_available
	%TakeButton.text = "Finish and analyze" if recording else "Record a take"
	if stale and worker_pid < 0 and not recording and not following:
		%TakeStatus.text = STALE_BANK_MESSAGE
	elif %TakeStatus.text == STALE_BANK_MESSAGE:
		%TakeStatus.text = "Record a take to test this bank."

func _stale_bank_selected() -> bool:
	return bank_override == ProjectSettings.globalize_path(PERSONAL_BANK) and _personal_bank_outdated()

func set_input_available(available: bool) -> void:
	if input_available != available:
		input_available = available
		_refresh_buttons()

func _add_bank_option(path: String) -> void:
	%ChooseBank.add_item(path.get_file().get_basename())
	%ChooseBank.set_item_metadata(%ChooseBank.item_count - 1, path)

func _bank_choice(index: int, clear_result := true) -> void:
	if index == %ChooseBank.item_count - 1:
		%BankDialog.popup_centered_ratio(0.8)
		return
	bank_override = "" if index == 0 else str(%ChooseBank.get_item_metadata(index))
	if clear_result:
		%TakeEvents.text = ""
		%TakeStatus.text = "Record a take to test this bank."
	_refresh_buttons()

func _restore_bank_choice() -> void:
	for index in range(1, %ChooseBank.item_count - 1):
		if %ChooseBank.get_item_metadata(index) == bank_override:
			%ChooseBank.select(index)
			return
	%ChooseBank.select(0)

func _load_bank_file(path: String, clear_result := true) -> void:
	for index in range(1, %ChooseBank.item_count - 1):
		if %ChooseBank.get_item_metadata(index) == path:
			%ChooseBank.select(index)
			_bank_choice(index, clear_result)
			return
	%ChooseBank.remove_item(%ChooseBank.item_count - 1)
	_add_bank_option(path)
	%ChooseBank.add_item("Browse for trained bank…")
	%ChooseBank.select(%ChooseBank.item_count - 2)
	_bank_choice(%ChooseBank.selected, clear_result)

func _on_take_button() -> void:
	if recording:
		finish_take()
	else:
		record_requested.emit(false)

func _on_follow_button() -> void:
	if following:
		_finish_follow()
	else:
		record_requested.emit(true)

func start_take(sample_rate: int, follow := false) -> void:
	if not desktop or recording or following or worker_pid >= 0:
		return
	samples.clear()
	rate = sample_rate
	recording = not follow
	following = follow
	received = 0
	committed = 0
	follow_history.clear()
	follow_gap = false
	%TakeEvents.text = ""
	%TakeStatus.text = "Listening for strikes…" if following else "Recording · play now"
	_refresh_buttons()

func add_samples(frames: PackedVector2Array) -> void:
	if following:
		_append_follow(frames)
		return
	if not recording:
		return
	var remaining := MAX_SECONDS * rate - samples.size()
	samples.append_array(frames if frames.size() <= remaining else frames.slice(0, remaining))
	%TakeStatus.text = "Recording · %.1f / %d s" % [float(samples.size()) / rate, MAX_SECONDS]
	if samples.size() >= MAX_SECONDS * rate:
		finish_take()

func cancel_take(reason: String) -> void:
	if recording or following:
		recording = false
		following = false
		samples.clear()
		%TakeStatus.text = reason
		_refresh_buttons()

func finish_take() -> void:
	if following:
		_finish_follow()
		return
	if not recording:
		return
	recording = false
	if samples.is_empty():
		%TakeStatus.text = "No microphone audio arrived. Try recording again."
	else:
		_analyze(samples, rate, "Microphone")
	samples.clear()
	_refresh_buttons()

func analyze_replay(frames: PackedVector2Array, sample_rate: int) -> void:
	if not desktop:
		return
	_stop_worker()
	_analyze(frames, sample_rate, "Replay")

func _append_follow(frames: PackedVector2Array) -> void:
	samples.append_array(frames)
	received += frames.size()
	var length := roundi(FOLLOW_WINDOW * rate)
	var margin := roundi(FOLLOW_MARGIN * rate)
	# Trim in chunks, keeping the most recent complete window even if the fit falls behind.
	if samples.size() > 2 * length + rate:
		samples = samples.slice(-2 * length)
	var target_end := length if committed == 0 else committed + length - margin
	if worker_pid >= 0 or received < target_end:
		return
	# Account for UI-frame-sized capture chunks without skipping audio between adjacent fits.
	if received - target_end > margin:
		target_end = received
	job_origin = target_end - length
	job_from = maxi(committed, 0 if job_origin == 0 else job_origin + margin)
	if job_from > committed:
		follow_gap = true
	job_until = target_end - margin
	var index := job_origin - (received - samples.size())
	_analyze(samples.slice(index, index + length), rate, "Recent strikes")
	if worker_pid < 0:
		following = false
		_refresh_buttons()

func _finish_follow() -> void:
	if samples.is_empty():
		cancel_take("No microphone audio arrived.")
		return
	_stop_worker()
	var length := mini(samples.size(), roundi(FOLLOW_WINDOW * rate))
	job_origin = received - length
	job_from = maxi(committed, job_origin)
	job_until = received
	follow_gap = follow_gap or job_from > committed
	%TakeStatus.text = "Fitting the final strikes…"
	_analyze(samples.slice(-length), rate, "Recent strikes")
	following = false
	final_follow_fit = worker_pid >= 0
	samples.clear()
	_refresh_buttons()

func _python() -> String:
	var configured := OS.get_environment("PIANO_NMF_PYTHON")
	if not configured.is_empty():
		return configured
	var venv := "res://.venv/Scripts/python.exe" if OS.get_name() == "Windows" else "res://.venv/bin/python"
	if FileAccess.file_exists(venv):
		return ProjectSettings.globalize_path(venv)
	var local := "res://.godot/attack_decay_python.txt"
	if FileAccess.file_exists(local):
		var path := FileAccess.get_file_as_string(local).strip_edges()
		if FileAccess.file_exists(path):
			return path
	return "python" if OS.get_name() == "Windows" else "python3"

func _analyze(frames: PackedVector2Array, sample_rate: int, source: String) -> void:
	job_is_follow = following
	if _stale_bank_selected():
		%TakeEvents.text = ""
		%TakeStatus.text = STALE_BANK_MESSAGE
		return
	if not _prepare_job():
		return
	var bank := runtime_dir.path_join(DEFAULT_BANK) if bank_override.is_empty() else bank_override
	var pcm := FileAccess.open(job_path + ".pcm", FileAccess.WRITE)
	if pcm == null:
		%TakeStatus.text = "Could not write the take."
		return
	var written := pcm.store_buffer(frames.to_byte_array())
	pcm.close()
	if not written:
		%TakeStatus.text = "Could not write the complete take."
		_cleanup()
		return
	if _start_worker(job_path + ".pcm", str(sample_rate), bank):
		if not following:
			%TakeEvents.text = ""
			%TakeStatus.text = "%s · fitting %.1f s of audio…" % [source, float(frames.size()) / sample_rate]
	_refresh_buttons()

func train_calibration() -> void:
	if not desktop or not training_path.is_empty():
		return
	%TrainingStatus.show()
	var path := _prepare_runtime_folder()
	if path.is_empty():
		%TrainingStatus.text = "Could not load the training worker."
		return
	training_path = path.path_join("train-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	trainer_pid = OS.create_process(_python(), PackedStringArray(["-B", runtime_dir.path_join("run_take.py"),
			ProjectSettings.globalize_path(KeyCalibration.PROFILE_DIR), "train",
			training_path + ".bank.npz", training_path + ".json",
			"--attack-ms", str(attack_ms), "--spectral-ms", str(spectral_ms)]))
	if trainer_pid >= 0:
		%TrainingStatus.text = "Training your piano bank and checking each saved strike…"
		set_process(true)
	else:
		cancel_training()
		%TrainingStatus.show()
		%TrainingStatus.text = "Python could not start. Set PIANO_NMF_PYTHON to Python with NumPy."
	_refresh_buttons()

func _prepare_job() -> bool:
	var work := _prepare_runtime_folder()
	if work.is_empty():
		%TakeStatus.text = "Could not load the bundled analysis worker."
		return false
	job_path = work.path_join("take-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	return true

func _prepare_runtime_folder() -> String:
	var work := ProjectSettings.globalize_path(WORK_DIR)
	if DirAccess.make_dir_recursive_absolute(work) != OK:
		return ""
	if runtime_dir.is_empty():
		runtime_dir = _prepare_runtime(work)
	return work if not runtime_dir.is_empty() else ""

func _start_worker(input: String, operation: String, bank: String) -> bool:
	worker_pid = OS.create_process(_python(), PackedStringArray(["-B", runtime_dir.path_join("run_take.py"),
			input, operation, bank, job_path + ".json",
			"--attack-ms", str(attack_ms), "--spectral-ms", str(spectral_ms)]))
	if worker_pid < 0:
		%TakeStatus.text = "Python could not start. Set PIANO_NMF_PYTHON to Python with NumPy."
		_cleanup()
		return false
	set_process(true)
	return true

func _prepare_runtime(work: String) -> String:
	var source := ProjectSettings.globalize_path(ASSET_DIR)
	if OS.has_feature("editor") and FileAccess.file_exists(source.path_join("run_take.py")):
		return source
	# A desktop export puts these files inside the PCK. Python needs filesystem paths.
	var dir := work.path_join("worker-%d" % OS.get_process_id())
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		return ""
	for file in RUNTIME_FILES:
		if _copy_asset(ASSET_DIR + file, dir.path_join(file)) != OK:
			return ""
	return dir

func _copy_asset(source: String, target: String) -> Error:
	var input := FileAccess.open(source, FileAccess.READ)
	if input == null:
		return FileAccess.get_open_error()
	var bytes := input.get_buffer(input.get_length())
	var output := FileAccess.open(target, FileAccess.WRITE)
	if output == null:
		return FileAccess.get_open_error()
	return OK if output.store_buffer(bytes) else ERR_FILE_CANT_WRITE

func _process(_delta: float) -> void:
	if worker_pid >= 0 and not OS.is_process_running(worker_pid):
		_finish_analysis()
	if not training_path.is_empty() and (trainer_pid < 0 or not OS.is_process_running(trainer_pid)):
		_finish_training()
	set_process(worker_pid >= 0 or not training_path.is_empty())

func _finish_analysis() -> void:
	var result: Variant = null
	if FileAccess.file_exists(job_path + ".json"):
		result = JSON.parse_string(FileAccess.get_file_as_string(job_path + ".json"))
	if result is Dictionary and result.get("events") is Array:
		if not job_is_follow:
			_show_events(result.events)
		elif following or final_follow_fit:
			_accept_follow(result.events)
		if result.has("bank_keys"):
			%TakeStatus.text += " · %d bank keys" % int(result.bank_keys)
	elif result is Dictionary and result.has("error"):
		%TakeStatus.text = "Analysis failed · " + str(result.error)
		following = false
	else:
		%TakeStatus.text = "Worker exited without results. Check the configured Python installation."
		following = false
	_cleanup()
	worker_pid = -1
	final_follow_fit = false
	_refresh_buttons()

func _finish_training() -> void:
	trainer_pid = -1
	if (worker_pid >= 0 or recording or following) and FileAccess.file_exists(training_path + ".bank.npz"):
		%TrainingStatus.text = "Training finished. The bank will switch after this take."
		return
	var result: Variant = null
	if FileAccess.file_exists(training_path + ".json"):
		result = JSON.parse_string(FileAccess.get_file_as_string(training_path + ".json"))
	var message := "Training stopped before producing a bank. You can retry from saved calibration."
	if result is Dictionary and result.has("trained_keys"):
		var bank := ProjectSettings.globalize_path(PERSONAL_BANK)
		if DirAccess.rename_absolute(training_path + ".bank.npz", bank) == OK:
			_load_bank_file(bank, false)
			message = "Your piano · %d/88 keys trained" % int(result.trained_keys)
			if result.get("self_check") is Array:
				DirAccess.rename_absolute(training_path + ".json", ProjectSettings.globalize_path(CALIBRATION_REPORT))
				cancel_training()
				_show_calibration_report(result)
				return
		else:
			message = "Could not save the updated piano bank. You can retry from saved calibration."
	elif result is Dictionary and result.has("error"):
		message = "Training failed · " + str(result.error)
	cancel_training()
	%TrainingStatus.show()
	%TrainingStatus.text = message

func _show_calibration_report(report: Dictionary) -> void:
	var checks: Array = report.get("self_check", [])
	if checks.is_empty():
		return
	var clean := 0
	var hits := 0
	var misses := PackedStringArray()
	for check: Dictionary in checks:
		clean += int(check.clean)
		hits += int(check.hit)
		if not check.hit:
			misses.append(_note_name(int(check.expected_midi)))
	%TrainingStatus.show()
	%TrainingStatus.text = "My piano check · %d/%d pitches found · %d clean takes" % [hits, checks.size(), clean]
	%TrainingStatus.tooltip_text = ("Check " + ", ".join(misses) + "\n" if not misses.is_empty() else "") + ProjectSettings.globalize_path(CALIBRATION_REPORT)

func _note_name(midi: int) -> String:
	var pitch: String = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][midi % 12]
	return "%s%d" % [pitch, floori(midi / 12.0) - 1]

func cancel_training() -> void:
	if trainer_pid >= 0 and OS.is_process_running(trainer_pid):
		OS.kill(trainer_pid)
	trainer_pid = -1
	if not training_path.is_empty():
		for suffix in [".json", ".part", ".npz", ".bank.npz"]:
			var path := training_path + str(suffix)
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
	training_path = ""
	%TrainingStatus.hide()
	_refresh_buttons()

func _accept_follow(events: Array) -> void:
	for event: Dictionary in events:
		var sample := job_origin + roundi(float(event.onset) * rate)
		if sample < job_from or sample >= job_until:
			continue
		var absolute_time := float(sample) / rate
		var duplicate := false
		# Adjacent fits can put a boundary strike on opposite sides of the commit point.
		for previous: Dictionary in follow_history:
			if previous.midi == event.midi and absf(previous.onset - absolute_time) < 0.10:
				duplicate = true
				break
		if not duplicate:
			follow_history.append({"midi": event.midi, "onset": absolute_time})
	committed = job_until
	var oldest := float(committed) / rate - MAX_SECONDS
	follow_history = follow_history.filter(func(event): return event.onset >= oldest)
	_show_events(follow_history)
	%TakeStatus.text = "Strikes through %.2f s%s" % [float(committed) / rate, " · coverage gap" if follow_gap else ""]

func _show_events(events: Array) -> void:
	%TakeStatus.text = "%d strikes · latest first" % events.size() if events.size() > 0 else "No strikes detected in this take."
	var groups := {}
	for event: Dictionary in events:
		var frame := roundi(float(event.onset) / 0.02)
		if not groups.has(frame):
			groups[frame] = PackedStringArray()
		groups[frame].append(_note_name(int(event.midi)))
	var times := groups.keys()
	times.sort()
	times.reverse()
	var lines := PackedStringArray()
	for frame: int in times:
		lines.append("%.2f s    %s" % [frame * 0.02, "  ".join(groups[frame])])
	%TakeEvents.text = "\n".join(lines)
	%EventsScroll.scroll_vertical = 0

func _cleanup() -> void:
	if job_path.is_empty():
		return
	for suffix in [".pcm", ".json", ".part", ".npz"]:
		var file := job_path + str(suffix)
		if FileAccess.file_exists(file):
			DirAccess.remove_absolute(file)
	job_path = ""

func _stop_worker() -> void:
	if worker_pid >= 0 and OS.is_process_running(worker_pid):
		OS.kill(worker_pid)
	worker_pid = -1
	final_follow_fit = false
	set_process(not training_path.is_empty())
	_cleanup()

func _exit_tree() -> void:
	_stop_worker()
	cancel_training()
	if not OS.has_feature("editor") and not runtime_dir.is_empty():
		for file in RUNTIME_FILES:
			DirAccess.remove_absolute(runtime_dir.path_join(file))
		DirAccess.remove_absolute(runtime_dir)

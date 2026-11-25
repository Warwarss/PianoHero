extends RefCounted

const PROFILE_DIR := "user://attack-decay/calibration"
const HOLD_SECONDS := 1.4
const QUIET_BLOCKS := 50
const MIN_RMS := 0.00012

var rate: int
var block_size: int
var warmup_blocks: int
var quiet := PackedFloat32Array()
var pending := PackedVector2Array()
var audio := PackedVector2Array()
var onset := -1
var threshold := 0.0
var above := false
var armed := false
var complete := false
var sustained_blocks := 0
var rejected := false
var db := -100.0

func _init(sample_rate: int, wait_for_release: bool) -> void:
	rate = sample_rate
	block_size = maxi(1, roundi(rate * 0.005))
	warmup_blocks = 60 if wait_for_release else 0

func append(frames: PackedVector2Array) -> void:
	pending.append_array(frames)
	var offset := 0
	while offset + block_size <= pending.size() and not complete and not rejected:
		var block := pending.slice(offset, offset + block_size)
		offset += block_size
		if warmup_blocks > 0:
			warmup_blocks -= 1
			continue
		_process_block(block)
	pending = pending.slice(offset) if not complete and not rejected else PackedVector2Array()

func _process_block(block: PackedVector2Array) -> void:
	var power := 0.0
	for frame in block:
		var mono := (frame.x + frame.y) * 0.5
		power += mono * mono
	var rms := sqrt(power / block.size())
	db = linear_to_db(maxf(rms, 0.00001))
	audio.append_array(block)
	if onset >= 0:
		var age := audio.size() - onset
		if age <= 24 * block_size and rms >= threshold * 0.5:
			sustained_blocks += 1
		if age == 24 * block_size and sustained_blocks < 4:
			rejected = true
		complete = audio.size() >= onset + roundi(HOLD_SECONDS * rate)
		return
	if armed and rms >= threshold:
		if above:
			# The second above-threshold block confirms the first.
			onset = audio.size() - 2 * block_size
			return
		above = true
	else:
		above = false
	# Re-estimate the floor while waiting. A strike or leftover ringing can
	# otherwise set an initial threshold that later quiet notes never cross.
	quiet.append(rms)
	if quiet.size() > QUIET_BLOCKS:
		quiet = quiet.slice(-QUIET_BLOCKS)
	if quiet.size() == QUIET_BLOCKS:
		var ranked := quiet.duplicate()
		ranked.sort()
		threshold = maxf(ranked[12] * 2.5, MIN_RMS)
		armed = true
	var limit := roundi(rate * 0.18) + 2 * block_size
	if audio.size() > limit:
		audio = audio.slice(-limit)

func save_note(midi: int) -> Error:
	var dir := ProjectSettings.globalize_path(PROFILE_DIR)
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		return err
	var target := dir.path_join("%d.pcm" % midi)
	var partial := "%s.%d.part" % [target, OS.get_process_id()]
	var file := FileAccess.open(partial, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_32(rate)
	file.store_32(onset)
	var ok := file.store_buffer(audio.to_byte_array())
	file.flush()
	file.close()
	err = DirAccess.rename_absolute(partial, target) if ok else ERR_FILE_CANT_WRITE
	if err != OK:
		DirAccess.remove_absolute(partial)
	return err

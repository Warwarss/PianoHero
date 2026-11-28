extends RefCounted
## Confirms fitted pitches using consecutive observations in audio time,
## emits discrete backdated onset events, and detects repeated strikes on sustained notes.

const MAX_GAP_MS := 150.0
const DROPOUT_GRACE_MS := 15.0
const ATTACK_RISE := 1.35
const REATTACK_RISE := 1.45
const MIN_REATTACK_MS := 80.0
const ATTACK_WINDOW_MS := 120.0
const MIN_GAIN := 0.001

var attack_ms := 20.0
var spectral_ms := 40.0
var last_ms := -1.0
var pitches := {}
var last_onsets: Array[Dictionary] = []

func reset() -> void:
	last_ms = -1.0
	pitches.clear()
	last_onsets.clear()

static func _hold_ratio_for_key(key: int) -> float:
	# High-register treble strings (C6+) decay much faster than middle/bass notes.
	if key < 84:
		return 0.65
	return lerpf(0.65, 0.35, clampf(float(key - 84) / 24.0, 0.0, 1.0))

func update(keys: Dictionary, gains: PackedFloat32Array, first_key: int, time_ms: float,
		silent := false) -> Dictionary:
	last_onsets.clear()
	var dt := time_ms - last_ms
	if last_ms < 0.0 or dt > MAX_GAP_MS or dt <= 0.0:
		reset()
		dt = 0.0
	last_ms = time_ms
	var confirmed := {}
	for index in gains.size():
		var key := first_key + index
		var gain := gains[index]
		var supported := not silent and keys.has(key)
		if gain <= MIN_GAIN and not pitches.has(key):
			continue
		var state: Dictionary = pitches.get(key, {
			"baseline": 0.0,
			"started": -1.0,
			"target": 0.0,
			"previous_gain": 0.0,
			"attack": false,
			"supported": false,
			"spectrum": 0.0,
			"visible": false,
			"drop_ms": 0.0,
			"last_strength": 0.0,
			"last_onset_ms": -1000.0,
			"peak_since_onset": 0.0,
			"reattack_armed": false,
		})
		var hold_ratio := _hold_ratio_for_key(key)
		if supported:
			if state.supported:
				state.spectrum += dt
			state.drop_ms = 0.0
			state.last_strength = float(keys[key])
		elif state.visible and not silent and state.drop_ms + dt <= DROPOUT_GRACE_MS:
			# Ride through a single noisy transient frame without dropping a held note.
			state.drop_ms += dt
		else:
			state.spectrum = 0.0
			state.visible = false
			state.drop_ms = 0.0
			state.reattack_armed = false
		state.supported = supported

		if not state.visible:
			if state.started >= 0.0:
				if time_ms - state.started > ATTACK_WINDOW_MS or (not state.attack and gain < state.target):
					state.started = -1.0
					state.attack = false
				elif time_ms - state.started >= attack_ms:
					state.attack = true
			var rising: bool = gain > maxf(MIN_GAIN, ATTACK_RISE * float(state.baseline)) and (
					gain > 1.03 * float(state.previous_gain) or (supported and float(state.previous_gain) <= MIN_GAIN))
			if state.started < 0.0 and rising:
				state.started = time_ms
				state.target = maxf(gain * hold_ratio, float(state.baseline) * 1.10)
				state.attack = attack_ms <= 0.0
			if supported and state.attack and state.spectrum >= spectral_ms:
				var onset_ms: float = state.started if state.started >= 0.0 else time_ms
				state.visible = true
				state.started = -1.0
				state.attack = false
				state.last_onset_ms = onset_ms
				state.peak_since_onset = gain
				state.reattack_armed = false
				last_onsets.append({"midi": key, "onset_ms": onset_ms, "strength": float(keys[key])})
		elif supported:
			# Track re-attacks so repeated strikes on a ringing note still emit an onset event.
			state.peak_since_onset = maxf(float(state.peak_since_onset), gain)
			if not state.reattack_armed and time_ms - float(state.last_onset_ms) >= MIN_REATTACK_MS and gain < 0.75 * float(state.peak_since_onset):
				state.reattack_armed = true
			if state.started >= 0.0:
				if time_ms - state.started > ATTACK_WINDOW_MS or gain < state.target:
					state.started = -1.0
				elif time_ms - state.started >= attack_ms:
					var onset_ms: float = state.started
					state.started = -1.0
					state.last_onset_ms = onset_ms
					state.peak_since_onset = gain
					state.reattack_armed = false
					last_onsets.append({"midi": key, "onset_ms": onset_ms, "strength": float(keys[key])})
			elif state.reattack_armed and gain > maxf(MIN_GAIN, REATTACK_RISE * float(state.baseline)) and gain > 1.15 * float(state.previous_gain):
				state.started = time_ms
				state.target = maxf(gain * hold_ratio, float(state.baseline) * 1.15)
				if attack_ms <= 0.0:
					state.started = -1.0
					state.last_onset_ms = time_ms
					state.peak_since_onset = gain
					state.reattack_armed = false
					last_onsets.append({"midi": key, "onset_ms": time_ms, "strength": float(keys[key])})

		if state.visible:
			confirmed[key] = float(keys[key]) if supported else float(state.last_strength)
		state.previous_gain = gain
		state.baseline = lerpf(float(state.baseline), gain, 1.0 - exp(-dt / 60.0))
		if gain <= MIN_GAIN and not state.visible and state.started < 0.0 and float(state.baseline) <= MIN_GAIN:
			pitches.erase(key)
		else:
			pitches[key] = state
	return confirmed

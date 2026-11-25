extends RefCounted
## Confirms fitted pitches using consecutive observations in audio time.

const MAX_GAP_MS := 40.0
const ATTACK_RISE := 1.35
const ATTACK_WINDOW_MS := 120.0
const MIN_GAIN := 0.001

var attack_ms := 20.0
var spectral_ms := 40.0
var last_ms := -1.0
var pitches := {}

func reset() -> void:
	last_ms = -1.0
	pitches.clear()

func update(keys: Dictionary, gains: PackedFloat32Array, first_key: int, time_ms: float) -> Dictionary:
	var dt := time_ms - last_ms
	if last_ms < 0.0 or dt > MAX_GAP_MS or dt <= 0.0:
		reset()
		dt = 0.0
	last_ms = time_ms
	var confirmed := {}
	for index in gains.size():
		var key := first_key + index
		var gain := gains[index]
		var supported := keys.has(key)
		if gain <= MIN_GAIN and not pitches.has(key):
			continue
		var state: Dictionary = pitches.get(key, {"baseline": 0.0, "started": -1.0, "target": 0.0,
				"previous_gain": 0.0, "attack": false, "supported": false, "spectrum": 0.0, "visible": false})
		if supported:
			if state.supported:
				state.spectrum += dt
		else:
			state.spectrum = 0.0
			state.visible = false
		state.supported = supported
		if not state.visible:
			if state.started >= 0.0:
				if time_ms - state.started > ATTACK_WINDOW_MS or (not state.attack and gain < state.target):
					state.started = -1.0
					state.attack = false
				elif time_ms - state.started >= attack_ms:
					state.attack = true
			var rising := gain > maxf(MIN_GAIN, ATTACK_RISE * float(state.baseline)) and gain > 1.03 * float(state.previous_gain)
			if state.started < 0.0 and rising:
				state.started = time_ms
				state.target = maxf(gain * 0.65, state.baseline * 1.10)
				state.attack = attack_ms == 0.0
			if supported and state.attack and state.spectrum >= spectral_ms:
				state.visible = true
				state.started = -1.0
				state.attack = false
		if state.visible:
			confirmed[key] = keys[key]
		state.previous_gain = gain
		state.baseline = lerpf(float(state.baseline), gain, 1.0 - exp(-dt / 60.0))
		if gain <= MIN_GAIN and not supported and state.started < 0.0 and state.baseline <= MIN_GAIN:
			pitches.erase(key)
		else:
			pitches[key] = state
	return confirmed

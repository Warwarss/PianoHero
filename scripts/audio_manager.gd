extends Node

const _FART_SOUND = preload("res://resources/audio/fart-wav-1.wav")
const _GUN_SOUND = preload("res://resources/audio/Western-Gunshot.wav")
const EASTWOOD = preload("res://resources/audio/eastwood.ogg")

var _sfx := AudioStreamPlayer.new()
var _music := AudioStreamPlayer.new()

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	add_child(_sfx)
	add_child(_music)

func play_gun() -> void:
	_play_sound(_GUN_SOUND)

func play_fart() -> void:
	_play_sound(_FART_SOUND)
	
func _play_sound(sound: AudioStream) -> void:
	_sfx.stream = sound
	_sfx.play()
	
func play_music(song:AudioStream) -> void:
	if _music.stream == song and _music.playing:
		return
	_music.stream = song
	_music.play()
	
func wait_for_sfx() -> void:
	if _sfx.playing:
		await _sfx.finished

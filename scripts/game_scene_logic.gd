extends Control
@export var lab: PackedScene


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	AudioManager.play_music(AudioManager.EASTWOOD)
	$VBoxContainer/Play.pressed.connect(_on_play_pressed)
	$VBoxContainer/Fart.pressed.connect(_on_fart_pressed)
	
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func _on_play_pressed() -> void:
	AudioManager.play_gun()
	get_tree().change_scene_to_packed(lab)
	
func _on_fart_pressed() -> void:
	AudioManager.play_fart()

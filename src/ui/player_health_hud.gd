class_name PlayerHealthHud
extends CanvasLayer
## Prototype player health HUD. Updates only from HitReceiver.health_changed.

@export var hit_receiver: HitReceiver
@export var health_bar: ProgressBar
@export var health_label: Label


func _ready() -> void:
	if hit_receiver == null:
		push_warning("PlayerHealthHud missing HitReceiver.")
		return
	hit_receiver.health_changed.connect(_on_health_changed)
	_on_health_changed(hit_receiver.health, hit_receiver.max_health)


func _on_health_changed(current_health: float, max_health: float) -> void:
	if health_bar != null:
		health_bar.max_value = max_health
		health_bar.value = current_health
	if health_label != null:
		health_label.text = "%d / %d" % [
				int(roundf(current_health)),
				int(roundf(max_health)),
		]

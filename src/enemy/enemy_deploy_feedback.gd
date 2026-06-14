class_name EnemyDeployFeedback
extends Node
## Shared visual scale-up used by enemy deployment states.

signal deployed

@export var visual_root: Node3D

var _original_scale: Vector3 = Vector3.ONE
var _original_position: Vector3 = Vector3.ZERO
var _tween: Tween = null


func _ready() -> void:
	if visual_root == null:
		return
	_original_scale = visual_root.scale
	_original_position = visual_root.position


func start(duration: float) -> void:
	if visual_root == null:
		push_warning("%s missing visual_root." % name)
		deployed.emit()
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	visual_root.position = _original_position
	visual_root.scale = Vector3(
			_original_scale.x,
			_original_scale.y * 0.01,
			_original_scale.z)
	var tween_duration: float = maxf(duration, 0.01)
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_BACK)
	_tween.set_ease(Tween.EASE_OUT)
	_tween.tween_property(visual_root, "scale", _original_scale, tween_duration)
	_tween.finished.connect(_finish)


func reset_visuals() -> void:
	if visual_root == null:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	visual_root.scale = _original_scale
	visual_root.position = _original_position


func _finish() -> void:
	if visual_root != null:
		visual_root.scale = _original_scale
		visual_root.position = _original_position
	_tween = null
	deployed.emit()

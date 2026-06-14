class_name EnemyDazeFeedback
extends Node
## Shared body-pose feedback for enemies interrupted by a blocked melee attack.

@export var body: Node3D
@export var recoil_pitch_degrees: float = 18.0
@export var wobble_roll_degrees: float = 8.0
@export var drop_height: float = 0.08
@export var settle_fraction: float = 0.25
@export var wobble_cycles: float = 3.0

var _rest_position: Vector3 = Vector3.ZERO
var _rest_rotation: Vector3 = Vector3.ZERO
var _start_position: Vector3 = Vector3.ZERO
var _start_rotation: Vector3 = Vector3.ZERO
var _has_rest_pose: bool = false


func _ready() -> void:
	_capture_rest_pose()


func start() -> void:
	if body == null:
		return
	if not _has_rest_pose:
		_capture_rest_pose()
	_start_position = body.position
	_start_rotation = body.rotation


func apply(elapsed: float, duration: float) -> void:
	if body == null:
		return
	if not _has_rest_pose:
		_capture_rest_pose()
	var duration_safe: float = maxf(duration, 0.001)
	var daze_t: float = clampf(elapsed / duration_safe, 0.0, 1.0)
	var settle_seconds: float = maxf(duration_safe * settle_fraction, 0.001)
	var settle_t: float = clampf(elapsed / settle_seconds, 0.0, 1.0)
	var dazed_position: Vector3 = _rest_position + Vector3(0.0, -drop_height, 0.0)
	var dazed_rotation: Vector3 = _rest_rotation + Vector3(deg_to_rad(recoil_pitch_degrees), 0.0, 0.0)
	var wobble_weight: float = 1.0 - daze_t * 0.45
	var wobble: float = sin(elapsed * TAU * wobble_cycles) * wobble_weight
	body.position = _start_position.lerp(dazed_position, settle_t)
	body.rotation = _start_rotation.lerp(dazed_rotation, settle_t)
	body.rotation.z += deg_to_rad(wobble_roll_degrees) * wobble


func finish() -> void:
	if body == null or not _has_rest_pose:
		return
	body.position = _rest_position
	body.rotation = _rest_rotation


func _capture_rest_pose() -> void:
	if body == null:
		return
	_rest_position = body.position
	_rest_rotation = body.rotation
	_start_position = body.position
	_start_rotation = body.rotation
	_has_rest_pose = true

class_name CameraRig
extends Node3D
## Hades-style tilted spring camera. The rig is a world sibling, never a child
## of the player; it stays south of the map, points north, and springs on XZ
## toward the player's movement-led target point. Kicks are impulses into the
## same spring velocity, so every punch returns naturally.

@export_group("Spring")
@export var stiffness: float = 52.0
@export_range(0.1, 2.0) var damping_ratio: float = 0.90
@export var max_distance: float = 7.0

@export_group("Look Ahead")
@export var lookahead_walk_seconds: float = 0.12
@export var lookahead_run_seconds: float = 0.38
@export_range(0.0, 1.0) var lookahead_run_threshold: float = 0.60
@export var lookahead_max: float = 4.5
@export var lookahead_smooth_time: float = 0.30

@export_group("Kicks")
@export var kick_hit: float = 2.5
@export var kick_slam: float = 4.0

@export_group("Shake")
## Max shake offset at full trauma.
@export var shake_distance: float = 0.4
## Trauma lost per second.
@export var shake_decay: float = 4.0

var _target: Player = null
var _spring_velocity: Vector2 = Vector2.ZERO
var _smoothed_lookahead: Vector2 = Vector2.ZERO
var _initialized: bool = false
var _shake_trauma: float = 0.0
var _camera_rest_position: Vector3 = Vector3.ZERO

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	_camera_rest_position = _camera.position


func _physics_process(delta: float) -> void:
	_acquire_target()
	if _target == null:
		return
	var target_point: Vector3 = _target.global_position + _target_offset(delta)
	if not _initialized:
		global_position = target_point
		rotation.y = 0.0
		_initialized = true
	_integrate_spring(target_point, delta)
	rotation.y = 0.0
	_camera.position = _camera_rest_position + _shake_offset(delta)


func add_kick(impulse: Vector3) -> void:
	_spring_velocity += Vector2(impulse.x, impulse.z)


func kick(direction: Vector2, strength: float) -> void:
	if direction.length_squared() <= 0.0001:
		return
	var impulse: Vector2 = direction.normalized() * kick_hit * strength
	add_kick(Vector3(impulse.x, 0.0, impulse.y))


func shake(strength: float) -> void:
	add_kick(Vector3(0.0, 0.0, -kick_slam * strength))
	_shake_trauma = minf(_shake_trauma + strength, 1.5)


func _acquire_target() -> void:
	if _target == null or not is_instance_valid(_target):
		_target = get_tree().get_first_node_in_group("players") as Player


func _target_offset(delta: float) -> Vector3:
	var velocity: Vector2 = _target.current_velocity_xz()
	var lookahead: Vector2 = _desired_lookahead(velocity)
	_smoothed_lookahead = _smoothed_lookahead.lerp(
			lookahead,
			_smooth_weight(lookahead_smooth_time, delta))
	return Vector3(_smoothed_lookahead.x, 0.0, _smoothed_lookahead.y)


func _desired_lookahead(velocity: Vector2) -> Vector2:
	var speed: float = velocity.length()
	if speed <= 0.01:
		return Vector2.ZERO
	var max_speed: float = maxf(_target.max_speed, 0.001)
	var speed_fraction: float = clampf(speed / max_speed, 0.0, 1.0)
	var run_t: float = clampf(
			(speed_fraction - lookahead_run_threshold) / maxf(1.0 - lookahead_run_threshold, 0.001),
			0.0,
			1.0)
	run_t = run_t * run_t * (3.0 - 2.0 * run_t)
	var lookahead_seconds: float = lerpf(lookahead_walk_seconds, lookahead_run_seconds, run_t)
	var offset: Vector2 = velocity * lookahead_seconds
	if offset.length() > lookahead_max:
		return offset.normalized() * lookahead_max
	return offset


func _integrate_spring(target_point: Vector3, delta: float) -> void:
	var position_xz: Vector2 = Vector2(global_position.x, global_position.z)
	var target_xz: Vector2 = Vector2(target_point.x, target_point.z)
	var damping: float = 2.0 * sqrt(stiffness) * damping_ratio
	var displacement: Vector2 = target_xz - position_xz
	var acceleration: Vector2 = displacement * stiffness - _spring_velocity * damping
	_spring_velocity += acceleration * delta
	position_xz += _spring_velocity * delta
	var from_target: Vector2 = position_xz - target_xz
	if from_target.length() > max_distance:
		position_xz = target_xz + from_target.normalized() * max_distance
		if _spring_velocity.dot(from_target) > 0.0:
			_spring_velocity = _spring_velocity.slide(from_target.normalized())
	global_position = Vector3(position_xz.x, target_point.y, position_xz.y)


func _smooth_weight(smooth_time: float, delta: float) -> float:
	if smooth_time <= 0.0:
		return 1.0
	return 1.0 - exp(-delta / smooth_time)


## Squaring the trauma makes the shake spike hard and tail off soft.
func _shake_offset(delta: float) -> Vector3:
	_shake_trauma = maxf(_shake_trauma - shake_decay * delta, 0.0)
	if _shake_trauma <= 0.0:
		return Vector3.ZERO
	var amount: float = _shake_trauma * _shake_trauma * shake_distance
	return Vector3(randf_range(-amount, amount), 0.0, randf_range(-amount, amount))

class_name DodgeState
extends Node
## Directional dodge state. Locks the camera-relative dodge direction at start
## and asks the character to apply a one-time impulse.

enum Phase {
	IDLE,
	STEERING_LOCK,
}

@export var intents: IntentSource
@export var dodge_impulse: float = 10.0
@export var max_dodge_speed: float = 14.0
@export var steering_lock_seconds: float = 0.14
@export_range(0.0, 1.0) var momentum_redirect_strength: float = 0.85
@export var lean_amount_degrees: float = 18.0

var _phase: Phase = Phase.IDLE
var _phase_time: float = 0.0
var _direction: Vector2 = Vector2.ZERO
var _started_this_frame: bool = false


func sync_from_intents(can_start: bool = true) -> void:
	_started_this_frame = false
	if intents == null:
		return
	if not intents.dodge_just_pressed:
		return
	if not can_start or is_dodging():
		return
	_start_dodge(_dodge_direction_from_input(intents.move_input))


func is_dodging() -> bool:
	return _phase != Phase.IDLE


func is_steering_locked() -> bool:
	return _phase == Phase.STEERING_LOCK


func dodge_direction() -> Vector2:
	return _direction


func consume_started() -> bool:
	if not _started_this_frame:
		return false
	_started_this_frame = false
	return true


func cancel() -> void:
	_started_this_frame = false
	_end_dodge()


func impulse_strength() -> float:
	return dodge_impulse


func speed_cap() -> float:
	return max_dodge_speed


func redirect_strength() -> float:
	return momentum_redirect_strength


func lean_amount_radians() -> float:
	if not is_dodging():
		return 0.0
	return deg_to_rad(lean_amount_degrees)


func step(delta: float) -> void:
	if _phase == Phase.IDLE:
		return
	_phase_time += delta
	if _phase == Phase.STEERING_LOCK and _phase_time >= steering_lock_seconds:
		_end_dodge()


func _start_dodge(direction: Vector2) -> void:
	_direction = direction
	_reset_dodge_timing()
	_started_this_frame = true
	_set_phase(Phase.STEERING_LOCK)


func _set_phase(next_phase: Phase) -> void:
	_phase = next_phase
	_phase_time = 0.0


func _end_dodge() -> void:
	_phase = Phase.IDLE
	_phase_time = 0.0
	_direction = Vector2.ZERO


func _reset_dodge_timing() -> void:
	_phase_time = 0.0


func _dodge_direction_from_input(input: Vector2) -> Vector2:
	if input.length_squared() <= 0.01:
		return _backward_direction()
	var clamped_input: Vector2 = input
	if clamped_input.length_squared() > 1.0:
		clamped_input = clamped_input.normalized()
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return clamped_input.normalized()
	var camera_right3: Vector3 = camera.global_transform.basis.x
	var camera_forward3: Vector3 = -camera.global_transform.basis.z
	camera_right3.y = 0.0
	camera_forward3.y = 0.0
	if camera_right3.length_squared() <= 0.0001 or camera_forward3.length_squared() <= 0.0001:
		return clamped_input.normalized()
	var direction3: Vector3 = camera_right3.normalized() * clamped_input.x \
			+ camera_forward3.normalized() * -clamped_input.y
	var direction: Vector2 = Vector2(direction3.x, direction3.z)
	if direction.length_squared() <= 0.0001:
		return _backward_direction()
	return direction.normalized()


func _backward_direction() -> Vector2:
	var body: Node3D = get_parent() as Node3D
	if body == null:
		return Vector2.DOWN
	var forward3: Vector3 = -body.global_transform.basis.z
	var backward: Vector2 = Vector2(-forward3.x, -forward3.z)
	if backward.length_squared() <= 0.0001:
		return Vector2.DOWN
	return backward.normalized()

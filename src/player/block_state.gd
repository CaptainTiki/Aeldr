class_name BlockState
extends Node
## Held block state. Owns block enter/exit, movement damping, and frontal hit
## tests while leaving damage application inside HitReceiver.take_hit().

signal block_started
signal block_ended
signal hit_blocked(damage: float, knockback: Vector2, source: Node)

enum VisualState {
	NEUTRAL,
	RAISING,
	GUARD,
	HIT_REACT,
	LOWERING,
	INTERRUPTED,
}

@export var intents: IntentSource
@export_range(0.0, 1.0) var movement_speed_multiplier: float = 0.5
@export_range(1.0, 360.0) var block_angle_degrees: float = 180.0
@export_group("Guard Viewmodel")
@export var animation_player: AnimationPlayer
@export var swing_state_machine: SwingStateMachine
@export var block_raise_animation: StringName = &"block_raise"
@export var block_guard_animation: StringName = &"block_guard"
@export var block_hit_animation: StringName = &"block_hit"
@export var block_lower_animation: StringName = &"block_lower"
@export_range(0.0, 0.12) var block_animation_blend_seconds: float = 0.03

var _is_blocking: bool = false
var _visual_state: VisualState = VisualState.NEUTRAL
var _block_active_printed: bool = false
var _action_allows_block: bool = true


func _ready() -> void:
	if animation_player != null:
		animation_player.animation_finished.connect(_on_animation_finished)


func sync_from_intents(action_allows_block: bool = true) -> void:
	_action_allows_block = action_allows_block
	var should_block: bool = false
	if intents != null:
		should_block = intents.block_held and _action_allows_block
	_set_blocking(should_block)
	_sync_block_visual()


func is_blocking() -> bool:
	return _is_blocking


func move_multiplier() -> float:
	if _is_blocking:
		return movement_speed_multiplier
	return 1.0


func cancel_for_dodge() -> void:
	cancel()


func cancel() -> void:
	_action_allows_block = false
	_set_blocking(false)
	_visual_state = VisualState.NEUTRAL


func try_block_hit(damage: float, knockback: Vector2, source: Node) -> bool:
	if not _is_blocking:
		return false
	if not _hit_origin_is_in_front(source):
		print("hit from behind")
		return false
	print("BLOCK HIT")
	hit_blocked.emit(damage, knockback, source)
	_play_block_hit()
	_notify_attacker_blocked(source)
	return true


func _set_blocking(should_block: bool) -> void:
	if _is_blocking == should_block:
		return
	_is_blocking = should_block
	if _is_blocking:
		_block_active_printed = false
		print("BLOCK ENTER")
		block_started.emit()
	else:
		print("BLOCK EXIT")
		block_ended.emit()


func _sync_block_visual() -> void:
	if animation_player == null:
		if _is_blocking:
			_print_block_active_once()
		_visual_state = VisualState.NEUTRAL
		return
	if not _action_allows_block:
		match _visual_state:
			VisualState.RAISING, VisualState.GUARD, VisualState.HIT_REACT:
				if _current_animation_is_block_visual():
					_play_block_lower()
				else:
					_visual_state = VisualState.INTERRUPTED
			_:
				pass
		return
	_mark_visual_interrupted_if_needed()
	if not _can_play_block_visual():
		return
	if _is_blocking:
		match _visual_state:
			VisualState.NEUTRAL, VisualState.LOWERING, VisualState.INTERRUPTED:
				_play_block_raise()
			VisualState.GUARD:
				_print_block_active_once()
			_:
				pass
	else:
		match _visual_state:
			VisualState.RAISING, VisualState.GUARD, VisualState.HIT_REACT:
				_play_block_lower()
			VisualState.INTERRUPTED:
				_visual_state = VisualState.NEUTRAL
			_:
				pass


func _play_block_raise() -> void:
	if _play_visual_animation(block_raise_animation, VisualState.RAISING, block_animation_blend_seconds):
		return
	_play_block_guard()


func _play_block_guard() -> void:
	_print_block_active_once()
	if not _play_visual_animation(block_guard_animation, VisualState.GUARD, 0.0):
		_visual_state = VisualState.GUARD


func _play_block_hit() -> void:
	if not _can_play_block_visual():
		return
	if _play_visual_animation(block_hit_animation, VisualState.HIT_REACT, block_animation_blend_seconds):
		return
	if _is_blocking:
		_play_block_guard()


func _play_block_lower() -> void:
	if _play_visual_animation(block_lower_animation, VisualState.LOWERING, block_animation_blend_seconds):
		return
	_visual_state = VisualState.NEUTRAL


func _play_visual_animation(animation_name: StringName, visual_state: VisualState, blend: float) -> bool:
	if animation_player == null or not animation_player.has_animation(animation_name):
		return false
	_visual_state = visual_state
	animation_player.play(animation_name, blend)
	return true


func _can_play_block_visual() -> bool:
	if animation_player == null:
		return false
	if not _action_allows_block:
		return false
	if swing_state_machine == null or not swing_state_machine.has_method("is_swinging"):
		return true
	return not bool(swing_state_machine.call("is_swinging"))


func _mark_visual_interrupted_if_needed() -> void:
	if _visual_state == VisualState.NEUTRAL or _visual_state == VisualState.INTERRUPTED:
		return
	if not animation_player.is_playing():
		return
	if _current_animation_is_block_visual():
		return
	_visual_state = VisualState.INTERRUPTED


func _current_animation_is_block_visual() -> bool:
	if animation_player == null:
		return false
	var current_animation: StringName = animation_player.current_animation
	return current_animation == block_raise_animation \
			or current_animation == block_guard_animation \
			or current_animation == block_hit_animation \
			or current_animation == block_lower_animation


func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name == block_raise_animation:
		if _is_blocking and _can_play_block_visual():
			_play_block_guard()
		else:
			_sync_block_visual()
	elif animation_name == block_hit_animation:
		if _is_blocking and _can_play_block_visual():
			_play_block_guard()
		else:
			_sync_block_visual()
	elif animation_name == block_guard_animation:
		if _is_blocking:
			_visual_state = VisualState.GUARD
			_print_block_active_once()
		else:
			_sync_block_visual()
	elif animation_name == block_lower_animation:
		_visual_state = VisualState.NEUTRAL


func _print_block_active_once() -> void:
	if _block_active_printed:
		return
	_block_active_printed = true
	print("BLOCK ACTIVE")


func _hit_origin_is_in_front(source: Node) -> bool:
	var blocker: Node3D = get_parent() as Node3D
	if blocker == null:
		return false
	var source_origin: Node3D = _source_origin(source)
	if source_origin == null:
		return false
	var to_source: Vector2 = Vector2(
			source_origin.global_position.x - blocker.global_position.x,
			source_origin.global_position.z - blocker.global_position.z)
	if to_source.length_squared() <= 0.0001:
		return true
	var forward3: Vector3 = -blocker.global_transform.basis.z
	var forward: Vector2 = Vector2(forward3.x, forward3.z).normalized()
	var half_angle_radians: float = deg_to_rad(block_angle_degrees * 0.5)
	var min_dot: float = cos(half_angle_radians)
	return to_source.normalized().dot(forward) >= min_dot


func _source_origin(source: Node) -> Node3D:
	var current: Node = source
	while current != null:
		var node3d: Node3D = current as Node3D
		if node3d != null:
			return node3d
		current = current.get_parent()
	return null


func _notify_attacker_blocked(source: Node) -> void:
	var blocker: Node3D = get_parent() as Node3D
	var current: Node = source
	while current != null:
		if current.has_method("on_attack_blocked"):
			current.call("on_attack_blocked", blocker)
			return
		current = current.get_parent()

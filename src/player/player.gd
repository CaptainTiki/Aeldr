class_name Player
extends CharacterBody3D
## Consumes intents from an IntentSource child and moves on the XZ plane.
## Never reads Input directly. Movement is momentum-driven: input steers and
## accelerates an existing XZ velocity, while swing releases redirect and pulse
## that same momentum economy.

signal player_wall_slam(direction: Vector2, speed: float)

@export_group("Locomotion")
@export var max_speed: float = 6.0
@export var accel_time: float = 0.27
@export var coast_time: float = 0.40
@export var brake_multiplier: float = 2.5
@export var turn_rate_low_speed: float = 24.0
@export var turn_rate_full_speed: float = 5.5
@export_range(0.0, 1.0) var low_speed_turn_fraction: float = 0.30
@export var overspeed_decay_time: float = 0.45

@export_group("Swing Movement")
@export var back_input_cancels_step: bool = false
@export var show_momentum_debug: bool = false

@export_group("Visual Lean")
@export var lean_pitch_max_degrees: float = 16.0
@export var lean_bank_max_degrees: float = 14.0
@export var lean_pitch_smoothing: float = 10.0
@export var lean_bank_smoothing: float = 12.0

@export_group("Wall Slam")
@export var player_wall_slam_enabled: bool = false
@export var wall_slam_speed_threshold: float = 8.0

@export_group("Damage Feedback")
@export var damage_flash_energy: float = 2.0
@export var damage_flash_seconds: float = 0.15
@export var block_flash_energy: float = 2.5
@export var block_flash_seconds: float = 0.10

@export_group("Respawn")
@export var respawn_delay_seconds: float = 1.5

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _lean_pitch: float = 0.0
var _lean_bank: float = 0.0
var _release_step_direction: Vector2 = Vector2.ZERO
var _release_step_remaining: float = 0.0
var _release_step_seconds_remaining: float = 0.0
var _release_step_velocity: Vector2 = Vector2.ZERO
var _debug_phase_name: String = "idle"
var _debug_phase_start_position: Vector2 = Vector2.ZERO
var _next_debug_print_ms: int = 0
var _dodge_debug_active: bool = false
var _dodge_debug_start_position: Vector2 = Vector2.ZERO
var _dodge_debug_peak_speed: float = 0.0
var _damage_flash_tween: Tween = null
var _body_material: StandardMaterial3D = null
var _control_enabled: bool = true
var _respawn_pending: bool = false
var _respawn_elapsed: float = 0.0
var _respawn_triggered: bool = false
var _saved_collision_layer: int = 0
var _saved_collision_mask: int = 0
var _initial_spawn_position: Vector3 = Vector3.ZERO

@onready var _intents: IntentSource = $Intents
@onready var _swing: SwingStateMachine = $SwingStateMachine
@onready var _block_state: Node = $BlockState
@onready var _dodge_state: Node = $DodgeState
@onready var _collision_shape: CollisionShape3D = $CollisionShape3D
@onready var _animation_player: AnimationPlayer = $AnimationPlayer
@onready var _melee_resolver: MeleeAttackResolver = $MeleeAttackResolver
@onready var _lean_rig: Node3D = $Body/LeanRig
@onready var _body_mesh: MeshInstance3D = $Body/LeanRig/Mesh
@onready var _weapon_trail: MeshInstance3D = $Body/WeaponPivot/Greatsword/Trail
@onready var _dust_puff: GPUParticles3D = $DustPuff
@onready var _slam_dust_ring: GPUParticles3D = $SlamDustRing
@onready var _slam_thump: AudioStreamPlayer3D = $SlamThump
@onready var _hit_receiver: HitReceiver = $HitReceiver


func _ready() -> void:
	_swing.swing_release.connect(_on_swing_release)
	_swing.phase_changed.connect(_on_swing_phase_changed)
	_hit_receiver.hit_received.connect(_on_hit_received)
	_hit_receiver.died.connect(_on_died)
	_block_state.connect("hit_blocked", _on_hit_blocked)
	_saved_collision_layer = collision_layer
	_saved_collision_mask = collision_mask
	_initial_spawn_position = global_position
	_debug_phase_name = _swing.current_phase_name()
	_debug_phase_start_position = _position_xz()
	var base_material: StandardMaterial3D = _body_mesh.get_active_material(0) as StandardMaterial3D
	if base_material != null:
		_body_material = base_material.duplicate() as StandardMaterial3D
		_body_mesh.set_surface_override_material(0, _body_material)


func _physics_process(delta: float) -> void:
	if not _control_enabled:
		_intents.poll()
		_process_respawn(delta)
		_intents.clear()
		velocity = Vector3.ZERO
		return
	_intents.poll()
	var dodge_started: bool = _sync_dodge_state()
	if dodge_started:
		_interrupt_actions_for_dodge()
	_sync_swing_action_gate()
	_update_facing()
	_sync_block_state()
	var previous_velocity: Vector2 = current_velocity_xz()
	_update_movement(delta, dodge_started)
	_update_visual_lean(previous_velocity, delta)
	var pre_slide_velocity: Vector2 = current_velocity_xz()
	move_and_slide()
	_check_player_wall_slam(pre_slide_velocity)
	_update_dodge_debug(pre_slide_velocity)
	_update_momentum_debug()
	_step_dodge_state(delta)


func current_velocity_xz() -> Vector2:
	return Vector2(velocity.x, velocity.z)


func respawn() -> void:
	_respawn_pending = false
	_respawn_elapsed = 0.0
	_respawn_triggered = false
	_cancel_actions("respawn")
	_hit_receiver.reset_health()
	_set_collision_enabled(true)
	_set_control_enabled(true)
	if _swing != null and _swing.has_method("set_action_allowed"):
		_swing.call("set_action_allowed", true)


func respawn_at(spawn_position: Vector3) -> void:
	global_position = spawn_position
	respawn()


func _update_facing() -> void:
	if _swing.facing_locked():
		return
	var to_aim: Vector3 = _intents.aim_point - global_position
	to_aim.y = 0.0
	if to_aim.length_squared() > 0.04:
		look_at(global_position + to_aim, Vector3.UP)


func _update_movement(delta: float, dodge_started: bool) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	var input: Vector2 = _intents.move_input
	if input.length_squared() > 1.0:
		input = input.normalized()
	var base_velocity: Vector2 = current_velocity_xz() - _release_step_velocity
	if dodge_started:
		_clear_release_step()
		base_velocity = _apply_dodge_impulse(base_velocity)
	var movement_input: Vector2 = _dodge_limited_input(input)
	var next_velocity: Vector2 = _step_ground_velocity(
			base_velocity,
			movement_input,
			_swing.move_multiplier() * _block_move_multiplier(),
			delta)
	_release_step_velocity = _spend_release_step(delta)
	next_velocity += _release_step_velocity
	velocity.x = next_velocity.x
	velocity.z = next_velocity.y


func _step_ground_velocity(
		current: Vector2,
		input: Vector2,
		input_damp: float,
		delta: float) -> Vector2:
	var input_length: float = minf(input.length(), 1.0)
	var acceleration_rate: float = max_speed / maxf(accel_time, 0.001)
	var coast_rate: float = max_speed / maxf(coast_time, 0.001)
	var current_speed: float = current.length()
	if input_length <= 0.01:
		return _with_speed(current, move_toward(current_speed, 0.0, coast_rate * delta))

	var input_direction: Vector2 = input / input_length
	if current_speed <= 0.01:
		var start_speed: float = minf(
				max_speed * input_damp * input_length,
				acceleration_rate * delta)
		return input_direction * start_speed

	var current_direction: Vector2 = current / current_speed
	var direction_dot: float = current_direction.dot(input_direction)
	var speed_factor: float = clampf(current_speed / maxf(max_speed, 0.001), 0.0, 1.0)
	var turn_t: float = clampf(
			(speed_factor - low_speed_turn_fraction) / maxf(1.0 - low_speed_turn_fraction, 0.001),
			0.0,
			1.0)
	var turn_rate: float = lerpf(turn_rate_low_speed, turn_rate_full_speed, turn_t)
	var next_direction: Vector2 = _rotate_toward(
			current_direction,
			input_direction,
			turn_rate * delta)

	var next_speed: float = current_speed
	if direction_dot < -0.5:
		next_speed = move_toward(
				current_speed,
				0.0,
				coast_rate * brake_multiplier * delta)
	else:
		var target_speed: float = max_speed * input_damp * input_length
		if current_speed < target_speed:
			next_speed = move_toward(
					current_speed,
					target_speed,
					acceleration_rate * delta)
		elif input_damp < 0.99 and current_speed > target_speed:
			var damp_rate: float = coast_rate * (1.0 - input_damp)
			next_speed = move_toward(
					current_speed,
					target_speed,
					damp_rate * delta)

	var next: Vector2 = next_direction * next_speed
	return _decay_overspeed(next, input_length, delta)


func _consume_dodge_started() -> bool:
	if _dodge_state == null or not _dodge_state.has_method("consume_started"):
		return false
	return bool(_dodge_state.call("consume_started"))


func _sync_dodge_state() -> bool:
	if _dodge_state == null or not _dodge_state.has_method("sync_from_intents"):
		return false
	_dodge_state.call("sync_from_intents", true)
	return _consume_dodge_started()


func _apply_dodge_impulse(current: Vector2) -> Vector2:
	var dodge_direction: Vector2 = _dodge_direction()
	if dodge_direction.length_squared() <= 0.0001:
		return current
	var current_speed: float = current.length()
	var redirected: Vector2 = current.lerp(
			dodge_direction * current_speed,
			_dodge_redirect_strength())
	var boosted: Vector2 = redirected + dodge_direction * _dodge_impulse_strength()
	var boosted_speed: float = boosted.length()
	var speed_cap: float = _dodge_speed_cap()
	var next: Vector2 = boosted
	if boosted_speed > speed_cap:
		next = _with_speed(boosted, speed_cap)
	_begin_dodge_debug(next.length())
	return next


func _dodge_limited_input(input: Vector2) -> Vector2:
	if not _dodge_steering_locked():
		return input
	var dodge_direction: Vector2 = _dodge_direction()
	if dodge_direction.length_squared() <= 0.0001:
		return input
	var input_length: float = minf(input.length(), 1.0)
	if input_length <= 0.01:
		return Vector2.ZERO
	return dodge_direction * input_length


func _dodge_direction() -> Vector2:
	if _dodge_state == null or not _dodge_state.has_method("dodge_direction"):
		return Vector2.ZERO
	return _dodge_state.call("dodge_direction")


func _dodge_steering_locked() -> bool:
	if _dodge_state == null or not _dodge_state.has_method("is_steering_locked"):
		return false
	return bool(_dodge_state.call("is_steering_locked"))


func _dodge_action_active() -> bool:
	if _dodge_state == null or not _dodge_state.has_method("is_dodging"):
		return false
	return bool(_dodge_state.call("is_dodging"))


func _step_dodge_state(delta: float) -> void:
	if _dodge_state == null or not _dodge_state.has_method("step"):
		return
	_dodge_state.call("step", delta)


func _dodge_impulse_strength() -> float:
	if _dodge_state == null or not _dodge_state.has_method("impulse_strength"):
		return 0.0
	return float(_dodge_state.call("impulse_strength"))


func _dodge_speed_cap() -> float:
	if _dodge_state == null or not _dodge_state.has_method("speed_cap"):
		return max_speed
	return float(_dodge_state.call("speed_cap"))


func _dodge_redirect_strength() -> float:
	if _dodge_state == null or not _dodge_state.has_method("redirect_strength"):
		return 0.0
	return float(_dodge_state.call("redirect_strength"))


func _block_move_multiplier() -> float:
	if _block_state == null or not _block_state.has_method("move_multiplier"):
		return 1.0
	return float(_block_state.call("move_multiplier"))


func _sync_block_state() -> void:
	if _block_state == null or not _block_state.has_method("sync_from_intents"):
		return
	_block_state.call("sync_from_intents", _block_action_allowed())


func _sync_swing_action_gate() -> void:
	if _swing == null or not _swing.has_method("set_action_allowed"):
		return
	_swing.call("set_action_allowed", not _dodge_action_active())


func _interrupt_actions_for_dodge() -> void:
	if _swing != null and _swing.has_method("cancel_for_dodge"):
		_swing.call("cancel_for_dodge")
	if _block_state != null and _block_state.has_method("cancel_for_dodge"):
		_block_state.call("cancel_for_dodge")
	_clear_release_step()


func _set_control_enabled(is_enabled: bool) -> void:
	_control_enabled = is_enabled
	if _control_enabled:
		_intents.clear()
		return
	_intents.clear()
	velocity = Vector3.ZERO


func _process_respawn(delta: float) -> void:
	if not _respawn_pending or _respawn_triggered:
		return
	_respawn_elapsed += delta
	if _respawn_elapsed < respawn_delay_seconds:
		return
	if not _intents.respawn_held:
		return
	_respawn_triggered = true
	var spawn_position: Vector3 = _player_spawn_position()
	print("player respawn position=(%.2f, %.2f, %.2f)" % [
			spawn_position.x,
			spawn_position.y,
			spawn_position.z,
	])
	respawn_at(spawn_position)


func _player_spawn_position() -> Vector3:
	var spawn: Node3D = get_tree().get_first_node_in_group("player_spawn") as Node3D
	if spawn != null:
		return spawn.global_position
	var parent_node: Node = get_parent()
	if parent_node != null:
		spawn = parent_node.get_node_or_null("PlayerSpawn") as Node3D
		if spawn != null:
			return spawn.global_position
	return _initial_spawn_position


func _set_collision_enabled(is_enabled: bool) -> void:
	if is_enabled:
		collision_layer = _saved_collision_layer
		collision_mask = _saved_collision_mask
	else:
		collision_layer = 0
		collision_mask = 0
	if _collision_shape != null:
		_collision_shape.set_deferred("disabled", not is_enabled)


func _cancel_actions_for_death() -> void:
	_cancel_actions("death")


func _cancel_actions(reason: String) -> void:
	if _swing != null:
		if _swing.has_method("cancel_actions"):
			_swing.call("cancel_actions", reason)
		elif _swing.has_method("cancel_for_dodge"):
			_swing.call("cancel_for_dodge")
	if _block_state != null:
		if _block_state.has_method("cancel"):
			_block_state.call("cancel")
		elif _block_state.has_method("cancel_for_dodge"):
			_block_state.call("cancel_for_dodge")
	if _dodge_state != null and _dodge_state.has_method("cancel"):
		_dodge_state.call("cancel")
	if _melee_resolver != null and _melee_resolver.has_method("cancel_pending_attacks"):
		_melee_resolver.call("cancel_pending_attacks")
	_intents.clear()
	_clear_release_step()
	_dodge_debug_active = false
	_dodge_debug_peak_speed = 0.0
	velocity = Vector3.ZERO
	_lean_pitch = 0.0
	_lean_bank = 0.0
	_lean_rig.rotation = Vector3.ZERO
	_stop_weapon_effects()


func _stop_weapon_effects() -> void:
	if _weapon_trail != null:
		_weapon_trail.visible = false
	if _dust_puff != null:
		_dust_puff.emitting = false
	if _slam_dust_ring != null:
		_slam_dust_ring.emitting = false
	if _slam_thump != null:
		_slam_thump.stop()
	if _animation_player != null:
		_animation_player.stop()


func _block_action_allowed() -> bool:
	if _swing.is_swinging() or _intents.attack_just_pressed:
		return false
	if _dodge_action_active() or _intents.dodge_just_pressed:
		return false
	return true


func _rotate_toward(from: Vector2, to: Vector2, max_angle: float) -> Vector2:
	var angle: float = from.angle_to(to)
	if absf(angle) <= max_angle:
		return to
	var direction: float = 1.0 if angle > 0.0 else -1.0
	return from.rotated(direction * max_angle).normalized()


func _with_speed(vector: Vector2, speed: float) -> Vector2:
	if speed <= 0.0 or vector.length_squared() <= 0.0001:
		return Vector2.ZERO
	return vector.normalized() * speed


func _decay_overspeed(vector: Vector2, input_length: float, delta: float) -> Vector2:
	var speed: float = vector.length()
	if input_length <= 0.01 or speed <= max_speed:
		return vector
	var decay_rate: float = max_speed / maxf(overspeed_decay_time, 0.001)
	return _with_speed(vector, move_toward(speed, max_speed, decay_rate * delta))


func _spend_release_step(delta: float) -> Vector2:
	if _release_step_remaining <= 0.0 or _release_step_seconds_remaining <= 0.0:
		_release_step_remaining = 0.0
		_release_step_seconds_remaining = 0.0
		return Vector2.ZERO
	var step_time: float = minf(delta, _release_step_seconds_remaining)
	var distance: float = minf(
			_release_step_remaining,
			_release_step_remaining * step_time / _release_step_seconds_remaining)
	_release_step_remaining -= distance
	_release_step_seconds_remaining -= step_time
	if delta <= 0.0:
		return Vector2.ZERO
	return _release_step_direction * (distance / delta)


func _clear_release_step() -> void:
	_release_step_direction = Vector2.ZERO
	_release_step_remaining = 0.0
	_release_step_seconds_remaining = 0.0
	_release_step_velocity = Vector2.ZERO


func _on_swing_release(direction: Vector2, impulse_strength: float) -> void:
	if direction.length_squared() <= 0.0001:
		return
	var swing_direction: Vector2 = direction.normalized()
	var impulse_scale: float = _step_cancel_scale(swing_direction)

	var current: Vector2 = current_velocity_xz()
	current -= _release_step_velocity
	var redirected: Vector2 = current.lerp(
			swing_direction * current.length(),
			_swing.stats.redirect_strength)
	var boosted: Vector2 = redirected + swing_direction * impulse_strength * impulse_scale
	velocity.x = boosted.x
	velocity.z = boosted.y
	_release_step_direction = swing_direction
	_release_step_remaining += _swing.stats.release_step_distance * impulse_scale
	_release_step_seconds_remaining = maxf(
			_swing.stats.release_step_seconds,
			_release_step_seconds_remaining)


func _step_cancel_scale(swing_direction: Vector2) -> float:
	if not back_input_cancels_step or _intents.move_input.length_squared() <= 0.01:
		return 1.0
	var input_direction: Vector2 = _intents.move_input.normalized()
	var opposition: float = clampf(-input_direction.dot(swing_direction), 0.0, 1.0)
	var cancel: float = opposition * _swing.stats.release_step_input_cancel_strength
	return 1.0 - clampf(cancel, 0.0, 1.0)


func _update_visual_lean(previous_velocity: Vector2, delta: float) -> void:
	var next_velocity: Vector2 = current_velocity_xz()
	var acceleration_xz: Vector2 = (next_velocity - previous_velocity) / maxf(delta, 0.001)
	var forward3: Vector3 = -global_transform.basis.z
	var forward: Vector2 = Vector2(forward3.x, forward3.z).normalized()
	var acceleration_rate: float = max_speed / maxf(accel_time, 0.001)
	var pitch_target: float = -clampf(
			acceleration_xz.dot(forward) / maxf(acceleration_rate, 0.001),
			-1.0,
			1.0) * deg_to_rad(lean_pitch_max_degrees)

	var bank_target: float = 0.0
	if previous_velocity.length_squared() > 0.01 and next_velocity.length_squared() > 0.01:
		var angular_velocity: float = previous_velocity.normalized().angle_to(
				next_velocity.normalized()) / maxf(delta, 0.001)
		bank_target = -clampf(
				angular_velocity / maxf(turn_rate_full_speed, 0.001),
				-1.0,
				1.0) * deg_to_rad(lean_bank_max_degrees)

	var pitch_weight: float = 1.0 - exp(-lean_pitch_smoothing * delta)
	var bank_weight: float = 1.0 - exp(-lean_bank_smoothing * delta)
	var dodge_lean_direction: Vector2 = _dodge_lean_direction()
	if dodge_lean_direction.length_squared() > 0.01:
		var dodge_lean_amount: float = _dodge_lean_amount()
		var right3: Vector3 = global_transform.basis.x
		var right: Vector2 = Vector2(right3.x, right3.z).normalized()
		pitch_target += -clampf(dodge_lean_direction.dot(forward), -1.0, 1.0) * dodge_lean_amount
		bank_target += clampf(dodge_lean_direction.dot(right), -1.0, 1.0) * dodge_lean_amount
	_lean_pitch = lerpf(_lean_pitch, pitch_target, pitch_weight)
	_lean_bank = lerpf(_lean_bank, bank_target, bank_weight)
	_lean_rig.rotation = Vector3(_lean_pitch, 0.0, _lean_bank)


func _dodge_lean_direction() -> Vector2:
	if _dodge_state == null \
			or not _dodge_state.has_method("is_dodging") \
			or not bool(_dodge_state.call("is_dodging")) \
			or not _dodge_state.has_method("dodge_direction"):
		return Vector2.ZERO
	return _dodge_state.call("dodge_direction")


func _dodge_lean_amount() -> float:
	if _dodge_state == null or not _dodge_state.has_method("lean_amount_radians"):
		return 0.0
	return float(_dodge_state.call("lean_amount_radians"))


func _on_swing_phase_changed(phase_name: String) -> void:
	_debug_phase_name = phase_name
	_debug_phase_start_position = _position_xz()
	_next_debug_print_ms = 0


func _update_momentum_debug() -> void:
	if not show_momentum_debug or not _swing.is_swinging():
		return
	var now_ms: int = Time.get_ticks_msec()
	if now_ms < _next_debug_print_ms:
		return
	_next_debug_print_ms = now_ms + 100
	var phase_distance: float = (_position_xz() - _debug_phase_start_position).length()
	print("momentum phase=%s speed=%.2f mult=%.2f step=%.2f phase_dist=%.2f" % [
			_debug_phase_name,
			current_velocity_xz().length(),
			_swing.move_multiplier(),
			_release_step_remaining,
			phase_distance,
	])


func _begin_dodge_debug(initial_speed: float) -> void:
	_dodge_debug_active = true
	_dodge_debug_start_position = _position_xz()
	_dodge_debug_peak_speed = initial_speed


func _update_dodge_debug(pre_slide_velocity: Vector2) -> void:
	if not _dodge_debug_active:
		return
	_dodge_debug_peak_speed = maxf(_dodge_debug_peak_speed, pre_slide_velocity.length())
	if _dodge_steering_locked():
		return
	if current_velocity_xz().length() > max_speed + 0.05:
		return
	var distance: float = (_position_xz() - _dodge_debug_start_position).length()
	print("dodge debug distance=%.2f peak_speed=%.2f" % [
			distance,
			_dodge_debug_peak_speed,
	])
	_dodge_debug_active = false


func _position_xz() -> Vector2:
	return Vector2(global_position.x, global_position.z)


func _check_player_wall_slam(pre_slide_velocity: Vector2) -> void:
	if not player_wall_slam_enabled:
		return
	var speed: float = pre_slide_velocity.length()
	if speed < wall_slam_speed_threshold:
		return
	var travel_direction: Vector2 = pre_slide_velocity / speed
	for index: int in range(get_slide_collision_count()):
		var collision: KinematicCollision3D = get_slide_collision(index)
		var normal3: Vector3 = collision.get_normal()
		var normal: Vector2 = Vector2(normal3.x, normal3.z)
		if normal.length_squared() <= 0.01:
			continue
		if normal.normalized().dot(-travel_direction) > 0.5:
			player_wall_slam.emit(travel_direction, speed)
			return


func _on_hit_received(damage: float, knockback: Vector2, source: Node) -> void:
	print("player damage=%.2f remaining_health=%.2f/%.2f source=%s" % [
			damage,
			_hit_receiver.health,
			_hit_receiver.max_health,
			_debug_source_name(source),
	])
	velocity.x += knockback.x
	velocity.z += knockback.y
	_flash_damage()


func _on_hit_blocked(_damage: float, _knockback: Vector2, _source: Node) -> void:
	_flash_body(Color(0.35, 0.85, 1.0, 1.0), block_flash_energy, block_flash_seconds)


func _on_died() -> void:
	if _respawn_pending:
		return
	print("player death remaining_health=%.2f/%.2f" % [
			_hit_receiver.health,
			_hit_receiver.max_health,
	])
	_respawn_pending = true
	_respawn_elapsed = 0.0
	_respawn_triggered = false
	_cancel_actions_for_death()
	_set_collision_enabled(false)
	_set_control_enabled(false)


func _debug_source_name(source: Node) -> String:
	if source == null:
		return "<none>"
	return str(source.name)


func _flash_damage() -> void:
	_flash_body(Color.WHITE, damage_flash_energy, damage_flash_seconds)


func _flash_body(color: Color, energy: float, seconds: float) -> void:
	if _body_material == null:
		return
	if _damage_flash_tween != null and _damage_flash_tween.is_valid():
		_damage_flash_tween.kill()
	_body_material.emission_enabled = true
	_body_material.emission = color
	_body_material.emission_energy_multiplier = energy
	_damage_flash_tween = create_tween()
	_damage_flash_tween.tween_property(
			_body_material,
			"emission_energy_multiplier",
			0.0,
			seconds)

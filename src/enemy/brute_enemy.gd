class_name BruteEnemy
extends CharacterBody3D
## Slow pressure enemy. It keeps the existing enemy enum-state shape, adds a
## blockable close melee, and uses a readable unblockable ground lane to punish
## backpedaling or held block.

const EnemyDeployFeedback = preload("res://src/enemy/enemy_deploy_feedback.gd")

enum State {
	DEPLOYING,
	IDLE,
	CHASE,
	MELEE_WINDUP,
	MELEE_ACTIVE,
	MELEE_RECOVERY,
	SLAM_WINDUP,
	SLAM_RELEASE,
	SLAM_RECOVERY,
	DAZED,
}

@export_group("Deploy")
@export var deploy_duration: float = 0.65

@export_group("Detection")
@export var wake_range: float = 11.0
@export var leash_range: float = 17.0
@export var slam_min_range: float = 2.2
@export var slam_max_range: float = 9.5

@export_group("Movement")
@export var chase_speed: float = 1.65
@export var acceleration: float = 7.5
@export var knockback_friction: float = 12.0
@export var windup_turn_rate_degrees: float = 220.0
@export var normal_hit_knockback_max_speed: float = 1.2
@export var slam_hit_knockback_threshold: float = 22.0
@export var slam_hit_knockback_max_speed: float = 6.0

@export_group("Melee")
@export var melee_range: float = 2.8
@export var melee_windup_seconds: float = 0.55
@export var melee_active_seconds: float = 0.20
@export var melee_recovery_seconds: float = 0.45
@export var melee_damage: float = 16.0
@export var melee_hit_radius: float = 2.1
@export var melee_hit_arc_degrees: float = 90.0
@export var melee_knockback_force: float = 5.5

@export_group("Slam")
@export var shockwave_scene: PackedScene
@export var slam_windup_seconds: float = 0.8
@export_range(0.0, 1.0) var slam_windup_move_multiplier: float = 0.45
@export var slam_arm_raise_seconds: float = 0.5
@export var slam_overhead_pause_seconds: float = 0.18
@export var slam_recovery_seconds: float = 1.25
@export var slam_cooldown_seconds: float = 2.75
@export var slam_forward_offset: float = 1.35
@export var slam_travel_speed: float = 14.0
@export var slam_range: float = 16.5
@export var slam_lane_width: float = 1.25
@export var slam_damage: float = 18.0
@export var slam_knockback_force: float = 7.0

@export_group("Daze")
@export var dazed_duration: float = 0.8

@export_group("Player Slam Response")
@export var player_slam_knockback_multiplier: float = 0.16
@export var player_slam_daze_multiplier: float = 0.65

@export_group("Feedback")
@export var flash_energy: float = 2.5
@export var flash_seconds: float = 0.12

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _state: State = State.IDLE
var _state_time: float = 0.0
var _target: Player = null
var _attack_direction: Vector2 = Vector2.UP
var _active_hit_delivered: bool = false
var _slam_spawned: bool = false
var _slam_direction_locked: bool = false
var _slam_cooldown_remaining: float = 0.0
var _movement_velocity: Vector2 = Vector2.ZERO
var _external_knockback: Vector2 = Vector2.ZERO
var _flash_tween: Tween = null
var _body_material: StandardMaterial3D = null
var _receiver_was_damageable: bool = false
var _current_dazed_duration: float = 0.8

@onready var _body: Node3D = $Body
@onready var _mesh: MeshInstance3D = $Body/Mesh
@onready var _left_arm_pivot: Node3D = $Body/LeftArmPivot
@onready var _right_arm_pivot: Node3D = $Body/RightArmPivot
@onready var _melee_tell: Node3D = $MeleeTell
@onready var _slam_tell: Node3D = $SlamTell
@onready var _slam_lane: MeshInstance3D = $SlamTell/Lane
@onready var _receiver: HitReceiver = $HitReceiver
@onready var _hit_particles: GPUParticles3D = $HitParticles
@onready var _daze_feedback: Node = $DazeFeedback
@onready var _deploy_feedback: EnemyDeployFeedback = $DeployFeedback as EnemyDeployFeedback


func _ready() -> void:
	_receiver.hit_received.connect(_on_hit_received)
	_receiver.died.connect(_on_died)
	if _deploy_feedback != null:
		_deploy_feedback.deployed.connect(_on_deploy_finished)
	_set_melee_tell_visible(false)
	_set_slam_tell_visible(false)
	_configure_slam_tell()
	var base_material: StandardMaterial3D = _mesh.get_active_material(0) as StandardMaterial3D
	if base_material != null:
		_body_material = base_material.duplicate() as StandardMaterial3D
		_mesh.set_surface_override_material(0, _body_material)
	_set_state(State.DEPLOYING)


func _physics_process(delta: float) -> void:
	_state_time += delta
	_slam_cooldown_remaining = maxf(_slam_cooldown_remaining - delta, 0.0)
	if _state != State.DEPLOYING:
		_acquire_target()
	match _state:
		State.DEPLOYING:
			_process_deploying()
			return
		State.IDLE:
			_process_idle()
		State.CHASE:
			_process_chase(delta)
		State.MELEE_WINDUP:
			_process_melee_windup(delta)
		State.MELEE_ACTIVE:
			_process_melee_active()
		State.MELEE_RECOVERY:
			_process_melee_recovery()
		State.SLAM_WINDUP:
			_process_slam_windup(delta)
		State.SLAM_RELEASE:
			_process_slam_release()
		State.SLAM_RECOVERY:
			_process_slam_recovery()
		State.DAZED:
			_process_dazed()
	_apply_motion(delta)
	_update_body_pose()


func _process_deploying() -> void:
	_target = null
	_stop_horizontal_motion()


func _process_idle() -> void:
	_approach_velocity(Vector2.ZERO, 0.0)
	if _target == null:
		return
	if _distance_to_target() <= wake_range:
		_set_state(State.CHASE)


func _process_chase(delta: float) -> void:
	if _target == null or _distance_to_target() > leash_range:
		_set_state(State.IDLE)
		return
	var to_target: Vector2 = _to_target_xz()
	var distance: float = to_target.length()
	if distance <= melee_range:
		_set_state(State.MELEE_WINDUP)
		return
	if _can_start_slam(distance):
		_set_state(State.SLAM_WINDUP)
		return
	var direction: Vector2 = to_target / maxf(distance, 0.001)
	_face_direction(direction)
	_approach_velocity(direction, delta)


func _process_melee_windup(delta: float) -> void:
	_approach_velocity(Vector2.ZERO, 0.0)
	_turn_toward_target(delta)
	if _state_time >= melee_windup_seconds:
		_set_state(State.MELEE_ACTIVE)


func _process_melee_active() -> void:
	var hit_time: float = melee_active_seconds * 0.55
	if _state_time >= hit_time and not _active_hit_delivered and _try_deliver_melee_hit():
		_active_hit_delivered = true
	if _state_time >= melee_active_seconds:
		_set_state(State.MELEE_RECOVERY)


func _process_melee_recovery() -> void:
	_approach_velocity(Vector2.ZERO, 0.0)
	if _state_time < melee_recovery_seconds:
		return
	_return_to_awake_state()


func _process_slam_windup(delta: float) -> void:
	var lock_time: float = minf(
			slam_windup_seconds,
			slam_arm_raise_seconds + slam_overhead_pause_seconds)
	if _state_time < lock_time:
		_turn_toward_target(delta)
	else:
		_lock_slam_direction_once()
	var approach_direction: Vector2 = _attack_direction
	if _state_time < lock_time and _target != null:
		var to_target: Vector2 = _to_target_xz()
		if to_target.length_squared() > 0.0001:
			approach_direction = to_target.normalized()
	_approach_velocity_at_speed(approach_direction, chase_speed * slam_windup_move_multiplier, delta)
	if _state_time >= slam_windup_seconds:
		_set_state(State.SLAM_RELEASE)


func _process_slam_release() -> void:
	_approach_velocity(Vector2.ZERO, 0.0)
	if not _slam_spawned:
		_spawn_shockwave()
		_slam_spawned = true
	_set_state(State.SLAM_RECOVERY)


func _process_slam_recovery() -> void:
	_approach_velocity(Vector2.ZERO, 0.0)
	if _state_time < slam_recovery_seconds:
		return
	_return_to_awake_state()


func _process_dazed() -> void:
	_movement_velocity = Vector2.ZERO
	if _state_time < _current_dazed_duration:
		return
	_return_to_awake_state()


func _apply_motion(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	_external_knockback = _external_knockback.move_toward(Vector2.ZERO, knockback_friction * delta)
	var combined_velocity: Vector2 = _movement_velocity + _external_knockback
	velocity.x = combined_velocity.x
	velocity.z = combined_velocity.y
	move_and_slide()


func _approach_velocity(direction: Vector2, delta: float) -> void:
	_approach_velocity_at_speed(direction, chase_speed, delta)


func _approach_velocity_at_speed(direction: Vector2, speed: float, delta: float) -> void:
	var target_velocity: Vector2 = direction * speed
	if delta <= 0.0:
		_movement_velocity = Vector2.ZERO
		return
	var current: Vector2 = _movement_velocity
	current = current.move_toward(target_velocity, acceleration * delta)
	_movement_velocity = current


func _stop_horizontal_motion() -> void:
	_external_knockback = Vector2.ZERO
	_movement_velocity = Vector2.ZERO


func _can_start_slam(distance: float) -> bool:
	if shockwave_scene == null or _slam_cooldown_remaining > 0.0:
		return false
	if distance > slam_max_range:
		return false
	return distance >= slam_min_range or _target_is_blocking()


func _target_is_blocking() -> bool:
	if _target == null:
		return false
	var block_state: Node = _target.get_node_or_null("BlockState")
	if block_state == null or not block_state.has_method("is_blocking"):
		return false
	return bool(block_state.call("is_blocking"))


func _try_deliver_melee_hit() -> bool:
	var origin: Vector2 = Vector2(global_position.x, global_position.z)
	var min_dot: float = cos(deg_to_rad(melee_hit_arc_degrees * 0.5))
	for node: Node in get_tree().get_nodes_in_group("players"):
		var player: Player = node as Player
		if player == null:
			continue
		var receiver: HitReceiver = player.get_node_or_null("HitReceiver") as HitReceiver
		if receiver == null:
			continue
		var to_player: Vector2 = Vector2(player.global_position.x, player.global_position.z) - origin
		var distance: float = to_player.length()
		if distance > melee_hit_radius:
			continue
		var direction: Vector2 = _attack_direction if distance < 0.01 else to_player / distance
		if direction.dot(_attack_direction) < min_dot:
			continue
		receiver.take_hit(melee_damage, direction * melee_knockback_force, self)
		return true
	return false


func _spawn_shockwave() -> void:
	if shockwave_scene == null:
		return
	var spawn_origin: Vector2 = Vector2(global_position.x, global_position.z) \
			+ _attack_direction * slam_forward_offset
	var shockwave: Node = shockwave_scene.instantiate()
	if shockwave == null:
		return
	get_parent().add_child(shockwave)
	var shockwave_body: Node3D = shockwave as Node3D
	if shockwave_body == null or not shockwave.has_method("configure"):
		shockwave.queue_free()
		return
	shockwave_body.global_position = Vector3(spawn_origin.x, global_position.y, spawn_origin.y)
	shockwave.call(
			"configure",
			spawn_origin,
			_attack_direction,
			slam_travel_speed,
			slam_range,
			slam_lane_width,
			slam_damage,
			slam_knockback_force,
			self)
	print("brute shockwave spawn range=%.2f width=%.2f speed=%.2f" % [
			slam_range,
			slam_lane_width,
			slam_travel_speed,
	])


func _acquire_target() -> void:
	if _target != null and is_instance_valid(_target):
		return
	var best_player: Player = null
	var best_distance_squared: float = INF
	for node: Node in get_tree().get_nodes_in_group("players"):
		var player: Player = node as Player
		if player == null:
			continue
		var distance_squared: float = global_position.distance_squared_to(player.global_position)
		if distance_squared >= best_distance_squared:
			continue
		best_distance_squared = distance_squared
		best_player = player
	_target = best_player


func _return_to_awake_state() -> void:
	if _target == null or _distance_to_target() > wake_range:
		_set_state(State.IDLE)
	else:
		_set_state(State.CHASE)


func _distance_to_target() -> float:
	if _target == null:
		return INF
	return _to_target_xz().length()


func _to_target_xz() -> Vector2:
	if _target == null:
		return Vector2.ZERO
	var delta: Vector3 = _target.global_position - global_position
	return Vector2(delta.x, delta.z)


func _turn_toward_target(delta: float) -> void:
	if _target == null:
		return
	var to_target: Vector2 = _to_target_xz()
	if to_target.length_squared() <= 0.0001:
		return
	var desired: Vector2 = to_target.normalized()
	var max_angle: float = deg_to_rad(windup_turn_rate_degrees) * delta
	_attack_direction = _rotate_toward(_attack_direction, desired, max_angle)
	_face_direction(_attack_direction)


func _rotate_toward(from: Vector2, to: Vector2, max_angle: float) -> Vector2:
	if from.length_squared() <= 0.0001:
		return to
	var angle: float = from.normalized().angle_to(to.normalized())
	if absf(angle) <= max_angle:
		return to.normalized()
	var direction: float = 1.0 if angle > 0.0 else -1.0
	return from.normalized().rotated(direction * max_angle).normalized()


func _face_direction(direction: Vector2) -> void:
	if direction.length_squared() <= 0.0001:
		return
	look_at(global_position + Vector3(direction.x, 0.0, direction.y), Vector3.UP)


func _commit_attack_direction() -> void:
	if _target != null:
		var to_target: Vector2 = _to_target_xz()
		if to_target.length_squared() > 0.0001:
			_attack_direction = to_target.normalized()
	_face_direction(_attack_direction)


func _lock_slam_direction() -> void:
	if _attack_direction.length_squared() <= 0.0001:
		_attack_direction = Vector2.UP
	_face_direction(_attack_direction)
	print("brute slam direction_lock dir=(%.2f, %.2f)" % [
			_attack_direction.x,
			_attack_direction.y,
	])


func _lock_slam_direction_once() -> void:
	if _slam_direction_locked:
		return
	_lock_slam_direction()
	_slam_direction_locked = true


func _set_state(next_state: State) -> void:
	if _state == next_state and _state_time > 0.0:
		return
	var previous_state: State = _state
	if previous_state == State.DAZED:
		print("%s DAZED END" % name)
		if _daze_feedback != null and _daze_feedback.has_method("finish"):
			_daze_feedback.call("finish")
	if next_state == State.MELEE_ACTIVE:
		_commit_attack_direction()
	if next_state == State.SLAM_RELEASE:
		_lock_slam_direction_once()
	_state = next_state
	_state_time = 0.0
	_active_hit_delivered = false
	if _state != State.SLAM_RELEASE:
		_slam_spawned = false
	match _state:
		State.DEPLOYING:
			_stop_horizontal_motion()
			_target = null
			_set_melee_tell_visible(false)
			_set_slam_tell_visible(false)
			_set_body_color(Color(0.32, 0.38, 0.42, 1.0))
			_set_damageable(false)
			if _deploy_feedback != null:
				_deploy_feedback.start(deploy_duration)
			else:
				_on_deploy_finished()
		State.IDLE:
			_set_melee_tell_visible(false)
			_set_slam_tell_visible(false)
			_set_body_color(Color(0.32, 0.38, 0.42, 1.0))
		State.CHASE:
			_set_melee_tell_visible(false)
			_set_slam_tell_visible(false)
			_set_body_color(Color(0.42, 0.48, 0.44, 1.0))
		State.MELEE_WINDUP:
			_set_melee_tell_visible(false)
			_set_slam_tell_visible(false)
			_set_body_color(Color(0.95, 0.68, 0.22, 1.0))
		State.MELEE_ACTIVE:
			_set_melee_tell_visible(false)
			_set_slam_tell_visible(false)
			_set_body_color(Color(1.0, 0.28, 0.12, 1.0))
		State.MELEE_RECOVERY:
			_set_melee_tell_visible(false)
			_set_slam_tell_visible(false)
			_set_body_color(Color(0.34, 0.36, 0.34, 1.0))
		State.SLAM_WINDUP:
			_set_melee_tell_visible(false)
			_set_slam_tell_visible(false)
			_set_body_color(Color(0.95, 0.18, 0.10, 1.0))
			_slam_direction_locked = false
			print("brute slam windup time=%.2f" % slam_windup_seconds)
		State.SLAM_RELEASE:
			_set_melee_tell_visible(false)
			_set_slam_tell_visible(false)
			_set_body_color(Color(1.0, 0.92, 0.55, 1.0))
			_slam_cooldown_remaining = slam_cooldown_seconds
		State.SLAM_RECOVERY:
			_set_melee_tell_visible(false)
			_set_slam_tell_visible(false)
			_set_body_color(Color(0.25, 0.28, 0.29, 1.0))
			print("brute slam recovery time=%.2f" % slam_recovery_seconds)
		State.DAZED:
			_stop_horizontal_motion()
			_set_melee_tell_visible(false)
			_set_slam_tell_visible(false)
			_set_body_color(Color(0.35, 0.85, 1.0, 1.0))
			if _daze_feedback != null and _daze_feedback.has_method("start"):
				_daze_feedback.call("start")
			print("%s DAZED START" % name)


func _set_melee_tell_visible(is_visible: bool) -> void:
	_melee_tell.visible = is_visible


func _set_slam_tell_visible(is_visible: bool) -> void:
	_slam_tell.visible = is_visible


func _configure_slam_tell() -> void:
	if _slam_lane == null:
		return
	_slam_lane.position = Vector3(0.0, 0.03, -slam_range * 0.5)
	_slam_lane.scale = Vector3(slam_lane_width, 1.0, slam_range)


func _set_body_color(color: Color) -> void:
	if _body_material == null:
		return
	_body_material.albedo_color = color


func _set_damageable(is_enabled: bool) -> void:
	if _receiver == null:
		return
	if is_enabled:
		if _receiver_was_damageable and not _receiver.is_in_group("damageable"):
			_receiver.add_to_group("damageable")
		return
	_receiver_was_damageable = _receiver.is_in_group("damageable")
	if _receiver_was_damageable:
		_receiver.remove_from_group("damageable")


func _on_deploy_finished() -> void:
	if _state != State.DEPLOYING:
		return
	if _deploy_feedback != null:
		_deploy_feedback.reset_visuals()
	_set_damageable(true)
	_set_state(State.IDLE)


func _update_body_pose() -> void:
	if _body == null:
		return
	var sway: float = sin(Time.get_ticks_msec() * 0.006) * 0.035
	_set_slam_arm_pose(0.0)
	match _state:
		State.CHASE:
			_body.position.y = 0.0 + sway
			_body.rotation.x = deg_to_rad(-3.0)
		State.MELEE_WINDUP:
			_apply_melee_windup_pose()
		State.MELEE_ACTIVE:
			_apply_melee_active_pose()
		State.MELEE_RECOVERY:
			_apply_melee_recovery_pose()
		State.SLAM_WINDUP:
			_apply_slam_windup_pose()
		State.SLAM_RELEASE:
			_body.position.y = -0.16
			_body.rotation.x = deg_to_rad(18.0)
			_set_slam_arm_pose(1.0)
		State.SLAM_RECOVERY:
			var recovery_t: float = clampf(_state_time / maxf(slam_recovery_seconds, 0.001), 0.0, 1.0)
			_body.position.y = lerpf(-0.16, 0.0, recovery_t)
			_body.rotation.x = lerpf(deg_to_rad(18.0), 0.0, recovery_t)
			_set_slam_arm_pose(lerpf(1.0, 0.0, recovery_t))
		State.DAZED:
			if _daze_feedback != null and _daze_feedback.has_method("apply"):
				_daze_feedback.call("apply", _state_time, _current_dazed_duration)
			else:
				_body.position.y = -0.08
				_body.rotation.x = deg_to_rad(18.0)
		_:
			_body.position.y = 0.0
			_body.rotation.x = 0.0


func _apply_melee_windup_pose() -> void:
	var windup_t: float = clampf(_state_time / maxf(melee_windup_seconds, 0.001), 0.0, 1.0)
	_body.position.y = lerpf(0.0, -0.04, windup_t)
	_body.rotation.x = lerpf(0.0, deg_to_rad(-7.0), windup_t)
	_set_melee_arm_pose(windup_t, 0.0)


func _apply_melee_active_pose() -> void:
	var clap_t: float = clampf(_state_time / maxf(melee_active_seconds, 0.001), 0.0, 1.0)
	_body.position.y = -0.06
	_body.rotation.x = lerpf(deg_to_rad(-7.0), deg_to_rad(7.0), clap_t)
	_set_melee_arm_pose(1.0 - clap_t, clap_t)


func _apply_melee_recovery_pose() -> void:
	var recovery_t: float = clampf(_state_time / maxf(melee_recovery_seconds, 0.001), 0.0, 1.0)
	_body.position.y = lerpf(-0.04, 0.0, recovery_t)
	_body.rotation.x = lerpf(deg_to_rad(7.0), 0.0, recovery_t)
	_set_melee_arm_pose(0.0, 1.0 - recovery_t)


func _apply_slam_windup_pose() -> void:
	var lock_time: float = minf(
			slam_windup_seconds,
			slam_arm_raise_seconds + slam_overhead_pause_seconds)
	var impact_seconds: float = maxf(slam_windup_seconds - lock_time, 0.001)
	if _state_time < slam_arm_raise_seconds:
		var raise_t: float = clampf(_state_time / maxf(slam_arm_raise_seconds, 0.001), 0.0, 1.0)
		_body.position.y = lerpf(0.0, 0.16, raise_t)
		_body.rotation.x = lerpf(0.0, deg_to_rad(-14.0), raise_t)
		_set_slam_arm_pose(raise_t)
		return
	if _state_time < lock_time:
		_body.position.y = 0.16
		_body.rotation.x = deg_to_rad(-14.0)
		_set_slam_arm_pose(1.0)
		return
	var impact_t: float = clampf((_state_time - lock_time) / impact_seconds, 0.0, 1.0)
	_body.position.y = lerpf(0.16, -0.16, impact_t)
	_body.rotation.x = lerpf(deg_to_rad(-14.0), deg_to_rad(18.0), impact_t)
	_set_slam_arm_pose(lerpf(1.0, 0.0, impact_t))


func _set_slam_arm_pose(overhead_weight: float) -> void:
	var weight: float = clampf(overhead_weight, 0.0, 1.0)
	var arm_x: float = lerpf(deg_to_rad(8.0), deg_to_rad(150.0), weight)
	var left_z: float = lerpf(deg_to_rad(-8.0), deg_to_rad(-20.0), weight)
	var right_z: float = lerpf(deg_to_rad(8.0), deg_to_rad(20.0), weight)
	_set_arm_rotations(arm_x, left_z, arm_x, right_z)


func _set_melee_arm_pose(open_weight: float, clap_weight: float) -> void:
	var open_t: float = clampf(open_weight, 0.0, 1.0)
	var clap_t: float = clampf(clap_weight, 0.0, 1.0)
	var left_x: float = lerpf(deg_to_rad(8.0), deg_to_rad(62.0), open_t)
	var right_x: float = lerpf(deg_to_rad(8.0), deg_to_rad(62.0), open_t)
	var left_z: float = lerpf(deg_to_rad(-8.0), deg_to_rad(-78.0), open_t)
	var right_z: float = lerpf(deg_to_rad(8.0), deg_to_rad(78.0), open_t)
	left_x = lerpf(left_x, deg_to_rad(82.0), clap_t)
	right_x = lerpf(right_x, deg_to_rad(82.0), clap_t)
	left_z = lerpf(left_z, deg_to_rad(-6.0), clap_t)
	right_z = lerpf(right_z, deg_to_rad(6.0), clap_t)
	_set_arm_rotations(left_x, left_z, right_x, right_z)


func _set_arm_rotations(
		left_x: float,
		left_z: float,
		right_x: float,
		right_z: float) -> void:
	if _left_arm_pivot != null:
		_left_arm_pivot.rotation = Vector3(left_x, 0.0, left_z)
	if _right_arm_pivot != null:
		_right_arm_pivot.rotation = Vector3(right_x, 0.0, right_z)


func _on_hit_received(_damage: float, knockback: Vector2, _source: Node) -> void:
	if _state == State.DEPLOYING:
		return
	if _receiver.last_hit_kind == HitReceiver.HIT_KIND_PLAYER_SLAM:
		_current_dazed_duration = maxf(dazed_duration * player_slam_daze_multiplier, 0.0)
		_set_state(State.DAZED)
		_external_knockback = _scaled_incoming_knockback(
				knockback * player_slam_knockback_multiplier,
				true)
	else:
		_external_knockback = _scaled_incoming_knockback(knockback, false)
	_hit_particles.restart()
	_flash()


func _scaled_incoming_knockback(knockback: Vector2, is_player_slam: bool) -> Vector2:
	var speed: float = knockback.length()
	if speed <= 0.0001:
		return Vector2.ZERO
	var max_speed: float = normal_hit_knockback_max_speed
	if is_player_slam or speed >= slam_hit_knockback_threshold:
		max_speed = slam_hit_knockback_max_speed
	return knockback.normalized() * minf(speed, max_speed)


func on_attack_blocked(_blocker: Node3D) -> void:
	if _state == State.DEPLOYING:
		return
	_active_hit_delivered = true
	_current_dazed_duration = dazed_duration
	_set_state(State.DAZED)
	_hit_particles.restart()
	_flash_blocked()


func _on_died() -> void:
	queue_free()


func _flash() -> void:
	if _body_material == null:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_body_material.emission_enabled = true
	_body_material.emission = Color.WHITE
	_body_material.emission_energy_multiplier = flash_energy
	_flash_tween = create_tween()
	_flash_tween.tween_property(_body_material, "emission_energy_multiplier", 0.0, flash_seconds)


func _flash_blocked() -> void:
	if _body_material == null:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_body_material.emission_enabled = true
	_body_material.emission = Color(0.35, 0.85, 1.0, 1.0)
	_body_material.emission_energy_multiplier = flash_energy
	_flash_tween = create_tween()
	_flash_tween.tween_property(_body_material, "emission_energy_multiplier", 0.0, flash_seconds)

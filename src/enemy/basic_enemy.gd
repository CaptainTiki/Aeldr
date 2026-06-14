class_name BasicEnemy
extends CharacterBody3D
## Prototype melee threat. It waits for nearby players, chases into range,
## telegraphs a slow lunge swipe, resolves one hit during active frames, then
## recovers long enough to punish.

const EnemyDeployFeedback = preload("res://src/enemy/enemy_deploy_feedback.gd")

enum State {
	DEPLOYING,
	IDLE,
	CHASE,
	ATTACK_WINDUP,
	ATTACK_ACTIVE,
	ATTACK_RECOVERY,
	DAZED,
}

@export_group("Deploy")
@export var deploy_duration: float = 0.65

@export_group("Detection")
@export var wake_range: float = 9.0
@export var leash_range: float = 14.0
@export var attack_range: float = 3.0

@export_group("Movement")
@export var chase_speed: float = 3.1
@export var acceleration: float = 14.0
@export var knockback_friction: float = 16.0

@export_group("Attack")
@export var windup_seconds: float = 0.45
@export var lunge_duration: float = 0.22
@export var recovery_seconds: float = 0.55
@export var damage: float = 10.0
@export var hit_radius: float = 1.9
@export var hit_arc_degrees: float = 95.0
@export var lunge_distance: float = 2.75
@export var knockback_force: float = 5.0

@export_group("Daze")
@export var dazed_duration: float = 0.8

@export_group("Player Slam Response")
@export var player_slam_knockback_multiplier: float = 0.32
@export var player_slam_daze_multiplier: float = 1.0

@export_group("Feedback")
@export var flash_energy: float = 2.5
@export var flash_seconds: float = 0.12

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _state: State = State.IDLE
var _state_time: float = 0.0
var _target: Player = null
var _attack_direction: Vector2 = Vector2.UP
var _active_hit_delivered: bool = false
var _movement_velocity: Vector2 = Vector2.ZERO
var _external_knockback: Vector2 = Vector2.ZERO
var _flash_tween: Tween = null
var _body_material: StandardMaterial3D = null
var _receiver_was_damageable: bool = false
var _current_dazed_duration: float = 0.8

@onready var _body: Node3D = $Body
@onready var _mesh: MeshInstance3D = $Body/Mesh
@onready var _tell: Node3D = $AttackTell
@onready var _receiver: HitReceiver = $HitReceiver
@onready var _hit_particles: GPUParticles3D = $HitParticles
@onready var _daze_feedback: Node = $DazeFeedback
@onready var _deploy_feedback: EnemyDeployFeedback = $DeployFeedback as EnemyDeployFeedback


func _ready() -> void:
	_receiver.hit_received.connect(_on_hit_received)
	_receiver.died.connect(_on_died)
	if _deploy_feedback != null:
		_deploy_feedback.deployed.connect(_on_deploy_finished)
	_set_tell_visible(false)
	var base_material: StandardMaterial3D = _mesh.get_active_material(0) as StandardMaterial3D
	if base_material != null:
		_body_material = base_material.duplicate() as StandardMaterial3D
		_mesh.set_surface_override_material(0, _body_material)
	_set_state(State.DEPLOYING)


func _physics_process(delta: float) -> void:
	_state_time += delta
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
		State.ATTACK_WINDUP:
			_process_windup()
		State.ATTACK_ACTIVE:
			_process_active(delta)
		State.ATTACK_RECOVERY:
			_process_recovery()
		State.DAZED:
			_process_dazed()
	_apply_motion(delta)


func _process_deploying() -> void:
	_target = null
	_stop_horizontal_motion()


func _process_idle() -> void:
	_approach_velocity(Vector2.ZERO, 0.0)
	if _target == null:
		return
	var distance: float = _distance_to_target()
	if distance <= wake_range:
		_set_state(State.CHASE)


func _process_chase(delta: float) -> void:
	if _target == null or _distance_to_target() > leash_range:
		_set_state(State.IDLE)
		return
	var to_target: Vector2 = _to_target_xz()
	var distance: float = to_target.length()
	if distance <= attack_range:
		_set_state(State.ATTACK_WINDUP)
		return
	var direction: Vector2 = to_target / maxf(distance, 0.001)
	_face_direction(direction)
	_approach_velocity(direction, delta)


func _process_windup() -> void:
	_approach_velocity(Vector2.ZERO, 0.0)
	if _target != null:
		var to_target: Vector2 = _to_target_xz()
		if to_target.length_squared() > 0.0001:
			_attack_direction = to_target.normalized()
			_face_direction(_attack_direction)
	if _state_time >= windup_seconds:
		_set_state(State.ATTACK_ACTIVE)


func _process_active(delta: float) -> void:
	if not _active_hit_delivered and _try_deliver_hit():
		_active_hit_delivered = true
	if _state != State.ATTACK_ACTIVE:
		return
	var previous_time: float = maxf(_state_time - delta, 0.0)
	var current_time: float = minf(_state_time, lunge_duration)
	var lunge_step_seconds: float = maxf(current_time - previous_time, 0.0)
	var lunge_step_distance: float = lunge_distance \
			* (lunge_step_seconds / maxf(lunge_duration, 0.001))
	var lunge_speed: float = lunge_step_distance / maxf(delta, 0.001)
	_movement_velocity = _attack_direction * lunge_speed
	if _state_time >= lunge_duration:
		_set_state(State.ATTACK_RECOVERY)


func _process_recovery() -> void:
	_approach_velocity(Vector2.ZERO, 0.0)
	if _state_time < recovery_seconds:
		return
	_return_to_awake_state()


func _process_dazed() -> void:
	_movement_velocity = Vector2.ZERO
	if _daze_feedback != null and _daze_feedback.has_method("apply"):
		_daze_feedback.call("apply", _state_time, _current_dazed_duration)
	if _state_time < _current_dazed_duration:
		return
	_return_to_awake_state()


func _return_to_awake_state() -> void:
	if _target == null or _distance_to_target() > wake_range:
		_set_state(State.IDLE)
	else:
		_set_state(State.CHASE)


func _apply_motion(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	_external_knockback = _external_knockback.move_toward(Vector2.ZERO, knockback_friction * delta)
	var combined_velocity: Vector2 = _movement_velocity + _external_knockback
	velocity.x = combined_velocity.x
	velocity.z = combined_velocity.y
	move_and_slide()


func _approach_velocity(direction: Vector2, delta: float) -> void:
	var target_velocity: Vector2 = direction * chase_speed
	if delta <= 0.0:
		_movement_velocity = Vector2.ZERO
		return
	var current: Vector2 = _movement_velocity
	current = current.move_toward(target_velocity, acceleration * delta)
	_movement_velocity = current


func _stop_horizontal_motion() -> void:
	_external_knockback = Vector2.ZERO
	_movement_velocity = Vector2.ZERO


func _try_deliver_hit() -> bool:
	var origin: Vector2 = Vector2(global_position.x, global_position.z)
	var min_dot: float = cos(deg_to_rad(hit_arc_degrees * 0.5))
	for node: Node in get_tree().get_nodes_in_group("players"):
		var player: Player = node as Player
		if player == null:
			continue
		var receiver: HitReceiver = player.get_node_or_null("HitReceiver") as HitReceiver
		if receiver == null:
			continue
		var to_player: Vector2 = Vector2(player.global_position.x, player.global_position.z) - origin
		var distance: float = to_player.length()
		if distance > hit_radius:
			continue
		var direction: Vector2 = _attack_direction if distance < 0.01 else to_player / distance
		if direction.dot(_attack_direction) < min_dot:
			continue
		receiver.take_hit(damage, direction * knockback_force, self)
		return true
	return false


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


func _distance_to_target() -> float:
	if _target == null:
		return INF
	return _to_target_xz().length()


func _to_target_xz() -> Vector2:
	if _target == null:
		return Vector2.ZERO
	var delta: Vector3 = _target.global_position - global_position
	return Vector2(delta.x, delta.z)


func _face_direction(direction: Vector2) -> void:
	if direction.length_squared() <= 0.0001:
		return
	look_at(global_position + Vector3(direction.x, 0.0, direction.y), Vector3.UP)


func _set_state(next_state: State) -> void:
	if _state == next_state and _state_time > 0.0:
		return
	var previous_state: State = _state
	if previous_state == State.DAZED:
		print("%s DAZED END" % name)
		if _daze_feedback != null and _daze_feedback.has_method("finish"):
			_daze_feedback.call("finish")
	if next_state == State.ATTACK_ACTIVE:
		_commit_attack_direction()
	_state = next_state
	_state_time = 0.0
	_active_hit_delivered = false
	match _state:
		State.DEPLOYING:
			_stop_horizontal_motion()
			_target = null
			_set_tell_visible(false)
			_set_body_color(Color(0.35, 0.70, 0.55, 1.0))
			_set_damageable(false)
			if _deploy_feedback != null:
				_deploy_feedback.start(deploy_duration)
			else:
				_on_deploy_finished()
		State.IDLE:
			_set_tell_visible(false)
			_set_body_color(Color(0.35, 0.70, 0.55, 1.0))
		State.CHASE:
			_set_tell_visible(false)
			_set_body_color(Color(0.58, 0.78, 0.48, 1.0))
		State.ATTACK_WINDUP:
			_set_tell_visible(true)
			_set_body_color(Color(1.0, 0.82, 0.18, 1.0))
		State.ATTACK_ACTIVE:
			_set_tell_visible(true)
			_set_body_color(Color(1.0, 0.22, 0.12, 1.0))
		State.ATTACK_RECOVERY:
			_set_tell_visible(false)
			_set_body_color(Color(0.42, 0.48, 0.42, 1.0))
		State.DAZED:
			_stop_horizontal_motion()
			_set_tell_visible(false)
			_set_body_color(Color(0.35, 0.85, 1.0, 1.0))
			if _daze_feedback != null and _daze_feedback.has_method("start"):
				_daze_feedback.call("start")
			print("%s DAZED START" % name)


func _set_tell_visible(is_visible: bool) -> void:
	_tell.visible = is_visible


func _set_body_color(color: Color) -> void:
	if _body_material == null:
		return
	_body_material.albedo_color = color


func _commit_attack_direction() -> void:
	if _target != null:
		var to_target: Vector2 = _to_target_xz()
		if to_target.length_squared() > 0.0001:
			_attack_direction = to_target.normalized()
	_face_direction(_attack_direction)


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


func _on_hit_received(_damage: float, knockback: Vector2, _source: Node) -> void:
	if _state == State.DEPLOYING:
		return
	if _receiver.last_hit_kind == HitReceiver.HIT_KIND_PLAYER_SLAM:
		_current_dazed_duration = maxf(dazed_duration * player_slam_daze_multiplier, 0.0)
		_set_state(State.DAZED)
		_external_knockback = knockback * player_slam_knockback_multiplier
	else:
		_external_knockback = knockback
	_hit_particles.restart()
	_flash()


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

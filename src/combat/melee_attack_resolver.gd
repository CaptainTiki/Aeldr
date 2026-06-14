class_name MeleeAttackResolver
extends Node
## Resolves blade impacts with XZ-plane math — no physics hitboxes. Two modes,
## both invoked by Call Method keys baked into the AnimationPlayer clips so
## damage lands on the exact frame the blade visually connects, and both
## delivering all impact through take_hit():
## - resolve_swing: radius + arc + facing dot product from the wielder.
## - resolve_slam: full circle around an impact point in front of the wielder,
##   knockback radiating outward from that point, hits rippling outward by
##   distance.

@export var stats: MeleeWeaponStats

var _attack_sequence: int = 0

@onready var _wielder: Node3D = get_parent() as Node3D


func cancel_pending_attacks() -> void:
	_attack_sequence += 1


func resolve_swing(swing_index: int) -> void:
	_attack_sequence += 1
	var knockback_force: float = stats.knockback_force
	if swing_index == 2:
		knockback_force *= stats.swing2_knockback_multiplier
	var forward: Vector2 = _facing_xz()
	var origin: Vector2 = Vector2(_wielder.global_position.x, _wielder.global_position.z)
	var min_dot: float = cos(deg_to_rad(stats.attack_arc_degrees * 0.5))
	var kick_direction: Vector2 = Vector2.ZERO
	var hit_anything: bool = false
	for node: Node in get_tree().get_nodes_in_group("damageable"):
		var receiver: HitReceiver = node as HitReceiver
		if receiver == null:
			continue
		if _receiver_belongs_to_wielder(receiver):
			continue
		var to_target: Vector2 = Vector2(receiver.global_position.x, receiver.global_position.z) - origin
		var distance: float = to_target.length()
		if distance > stats.attack_radius:
			continue
		var direction: Vector2 = forward if distance < 0.01 else to_target / distance
		if direction.dot(forward) < min_dot:
			continue
		receiver.take_hit(stats.damage, direction * knockback_force, self)
		kick_direction += direction
		hit_anything = true
	if not hit_anything:
		return
	var rig: CameraRig = get_tree().get_first_node_in_group("camera_rig") as CameraRig
	if rig != null:
		rig.kick(kick_direction.normalized(), stats.camera_kick_strength)


func resolve_slam() -> void:
	_attack_sequence += 1
	var attack_sequence: int = _attack_sequence
	var swing: SwingStateMachine = _wielder.get_node_or_null("SwingStateMachine") as SwingStateMachine
	if swing != null:
		swing.debug_slam_impact()
	var forward: Vector2 = _facing_xz()
	var impact: Vector2 = Vector2(_wielder.global_position.x, _wielder.global_position.z) \
			+ forward * stats.slam_forward_offset
	var damage: float = stats.damage * stats.slam_damage_multiplier
	var knockback_force: float = stats.knockback_force * stats.slam_knockback_multiplier
	for node: Node in get_tree().get_nodes_in_group("damageable"):
		var receiver: HitReceiver = node as HitReceiver
		if receiver == null:
			continue
		if _receiver_belongs_to_wielder(receiver):
			continue
		var to_target: Vector2 = Vector2(receiver.global_position.x, receiver.global_position.z) - impact
		var distance: float = to_target.length()
		if distance > stats.slam_radius:
			continue
		var direction: Vector2 = forward if distance < 0.01 else to_target / distance
		var delay: float = distance * stats.slam_ripple_seconds_per_meter
		_deliver_hit(receiver, damage, direction * knockback_force, delay, attack_sequence)
	# The ground always takes the hit, so the shake fires even on a whiff.
	var rig: CameraRig = get_tree().get_first_node_in_group("camera_rig") as CameraRig
	if rig != null:
		rig.shake(stats.slam_camera_shake)


## Staggers multi-target impacts so they ripple outward from the impact point.
func _deliver_hit(
		receiver: HitReceiver,
		damage: float,
		knockback: Vector2,
		delay_seconds: float,
		attack_sequence: int) -> void:
	if delay_seconds <= 0.0:
		if attack_sequence != _attack_sequence:
			return
		receiver.take_hit(damage, knockback, self)
		return
	var timer: SceneTreeTimer = get_tree().create_timer(delay_seconds)
	timer.timeout.connect(func() -> void:
		if attack_sequence == _attack_sequence and is_instance_valid(receiver):
			receiver.take_hit(damage, knockback, self))


func _facing_xz() -> Vector2:
	var forward3: Vector3 = -_wielder.global_transform.basis.z
	return Vector2(forward3.x, forward3.z).normalized()


func _receiver_belongs_to_wielder(receiver: HitReceiver) -> bool:
	return _wielder == receiver or _wielder.is_ancestor_of(receiver)

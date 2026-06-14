class_name BruteShockwave
extends Node3D
## Narrow, unblockable ground lane spawned by BruteEnemy. It locks its origin
## and direction at spawn time, then only travels forward on that lane.

@export var travel_speed: float = 14.0
@export var travel_range: float = 16.5
@export var lane_width: float = 1.25
@export var damage: float = 18.0
@export var knockback_force: float = 7.0
@export var linger_seconds: float = 0.25

var _origin: Vector2 = Vector2.ZERO
var _direction: Vector2 = Vector2.UP
var _source: Node = null
var _distance: float = 0.0
var _previous_distance: float = 0.0
var _linger_time: float = 0.0
var _has_stopped: bool = false
var _hit_players: Array[Node] = []

@onready var _crack: MeshInstance3D = $Crack
@onready var _front: Node3D = $WaveFront


func configure(
		spawn_origin: Vector2,
		direction: Vector2,
		next_travel_speed: float,
		next_range: float,
		next_lane_width: float,
		next_damage: float,
		next_knockback_force: float,
		source: Node) -> void:
	_origin = spawn_origin
	_direction = direction.normalized()
	travel_speed = next_travel_speed
	travel_range = next_range
	lane_width = next_lane_width
	damage = next_damage
	knockback_force = next_knockback_force
	_source = source
	global_position = Vector3(_origin.x, global_position.y, _origin.y)
	look_at(global_position + Vector3(_direction.x, 0.0, _direction.y), Vector3.UP)
	_update_visual()


func _physics_process(delta: float) -> void:
	if _has_stopped:
		_linger_time += delta
		if _linger_time >= linger_seconds:
			queue_free()
		return
	_previous_distance = _distance
	_distance = minf(_distance + travel_speed * delta, travel_range)
	_update_visual()
	_try_hit_players()
	if _distance >= travel_range:
		_has_stopped = true


func _update_visual() -> void:
	var visible_distance: float = maxf(_distance, 0.05)
	if _crack != null:
		_crack.position = Vector3(0.0, 0.035, -visible_distance * 0.5)
		_crack.scale = Vector3(lane_width, 1.0, visible_distance)
	if _front != null:
		_front.position = Vector3(0.0, 0.05, -visible_distance)


func _try_hit_players() -> void:
	var half_width: float = lane_width * 0.5
	for node: Node in get_tree().get_nodes_in_group("players"):
		var player: Node3D = node as Node3D
		if player == null or _hit_players.has(player):
			continue
		var to_player: Vector2 = Vector2(
				player.global_position.x - _origin.x,
				player.global_position.z - _origin.y)
		var along: float = to_player.dot(_direction)
		if along < 0.0 or along > travel_range:
			continue
		if along < _previous_distance - half_width or along > _distance + half_width:
			continue
		var lateral: Vector2 = to_player - _direction * along
		if lateral.length() > half_width:
			continue
		var receiver: Node = player.get_node_or_null("HitReceiver")
		if receiver == null or not receiver.has_method("take_hit"):
			continue
		_hit_players.append(player)
		print("brute shockwave player_hit distance=%.2f lane_width=%.2f" % [along, lane_width])
		receiver.call("take_hit", damage, _direction * knockback_force, self, false)

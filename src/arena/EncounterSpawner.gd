class_name EncounterSpawner
extends Node3D
## Reusable encounter loop: spawn each scene in one SpawnEncounter, track only
## those spawned enemies, then repeat after a cooldown once they are all gone.

enum SpawnState {
	IDLE,
	ACTIVE,
	COOLDOWN,
	INACTIVE,
}

const GROUND_RAY_DISTANCE: float = 40.0
const CLEARANCE_GROUND_EPSILON: float = 0.02
const MIN_SEARCH_STEP: float = 0.25
const SpawnEncounter = preload("res://src/arena/SpawnEncounter.gd")

@export_group("Encounter")
@export var encounter: SpawnEncounter
@export var cooldown_seconds: float = 15.0
@export var spawn_on_ready: bool = true
@export var repeat_encounter: bool = true

@export_group("Spawn Placement")
@export var spawn_spacing: float = 1.75
@export var maximum_spawn_radius: float = 8.0
@export var clearance_radius: float = 0.8
@export var clearance_height: float = 2.2
@export_flags_3d_physics var ground_collision_mask: int = 1
@export_flags_3d_physics var obstruction_collision_mask: int = 1

var _state: SpawnState = SpawnState.IDLE
var _cooldown_remaining: float = 0.0
var _active_enemies: Array[Node3D] = []


func _ready() -> void:
	if spawn_on_ready:
		call_deferred("_spawn_encounter")


func _process(delta: float) -> void:
	if _state != SpawnState.COOLDOWN:
		return
	_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)
	if _cooldown_remaining > 0.0:
		return
	_finish_cooldown()


func _spawn_encounter() -> void:
	if not _active_enemies.is_empty():
		return
	if not _validate_encounter():
		_state = SpawnState.INACTIVE
		return

	_state = SpawnState.ACTIVE
	var selected_positions: Array[Vector3] = []
	for index: int in range(encounter.enemies.size()):
		var enemy_scene: PackedScene = encounter.enemies[index]
		if enemy_scene == null:
			push_warning("EncounterSpawner %s: enemy PackedScene at index %d is null." % [name, index])
			continue

		var spawn_position_result: Dictionary = _find_spawn_position(selected_positions)
		if not bool(spawn_position_result.get("found", false)):
			push_warning("EncounterSpawner %s: no valid spawn position found for enemy at index %d." % [name, index])
			continue

		var instance: Node = enemy_scene.instantiate()
		var enemy: Node3D = instance as Node3D
		if enemy == null:
			push_warning("EncounterSpawner %s: enemy scene at index %d does not instantiate a valid Node3D enemy." % [name, index])
			if instance != null:
				instance.queue_free()
			continue

		var spawn_position: Vector3 = spawn_position_result["position"]
		_add_spawned_enemy(enemy, spawn_position)
		selected_positions.append(spawn_position)

	if _active_enemies.is_empty():
		_begin_cooldown()


func _validate_encounter() -> bool:
	if encounter == null:
		push_warning("EncounterSpawner %s: no SpawnEncounter assigned." % name)
		return false
	if encounter.enemies.is_empty():
		push_warning("EncounterSpawner %s: assigned SpawnEncounter contains no enemies." % name)
		return false
	return true


func _add_spawned_enemy(enemy: Node3D, spawn_position: Vector3) -> void:
	var spawn_parent: Node = get_parent()
	if spawn_parent == null:
		spawn_parent = self
	var spawn_parent_3d: Node3D = spawn_parent as Node3D
	if spawn_parent_3d != null:
		enemy.position = spawn_parent_3d.to_local(spawn_position)
	else:
		enemy.global_position = spawn_position
	spawn_parent.add_child(enemy)
	_active_enemies.append(enemy)

	var receiver: HitReceiver = _find_hit_receiver(enemy)
	if receiver != null:
		receiver.died.connect(_on_spawned_enemy_died.bind(enemy))
	enemy.tree_exited.connect(_on_spawned_enemy_tree_exited.bind(enemy))


func _find_spawn_position(selected_positions: Array[Vector3]) -> Dictionary:
	var origin: Vector3 = global_position
	var center_result: Dictionary = _get_valid_grounded_position(origin, selected_positions)
	if bool(center_result.get("found", false)):
		return center_result

	var search_step: float = maxf(spawn_spacing, MIN_SEARCH_STEP)
	var max_radius: float = maxf(maximum_spawn_radius, 0.0)
	var radius: float = search_step
	while radius <= max_radius + 0.001:
		var sample_count: int = maxi(8, int(ceilf(TAU * radius / search_step)))
		for sample_index: int in range(sample_count):
			var angle: float = (TAU * float(sample_index)) / float(sample_count)
			var offset: Vector3 = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			var candidate: Vector3 = origin + offset
			var candidate_result: Dictionary = _get_valid_grounded_position(candidate, selected_positions)
			if bool(candidate_result.get("found", false)):
				return candidate_result
		radius += search_step

	return {"found": false}


func _get_valid_grounded_position(candidate: Vector3, selected_positions: Array[Vector3]) -> Dictionary:
	var ground_result: Dictionary = _find_ground(candidate)
	if not bool(ground_result.get("found", false)):
		return {"found": false}

	var position: Vector3 = ground_result["position"]
	if _is_too_close_to_selected_position(position, selected_positions):
		return {"found": false}
	if not _has_clearance(position):
		return {"found": false}

	return {
		"found": true,
		"position": position,
	}


func _find_ground(candidate: Vector3) -> Dictionary:
	var world: World3D = get_world_3d()
	if world == null:
		return {"found": false}

	var ray_start: Vector3 = candidate + Vector3.UP * GROUND_RAY_DISTANCE
	var ray_end: Vector3 = candidate - Vector3.UP * GROUND_RAY_DISTANCE
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			ray_start,
			ray_end,
			ground_collision_mask)
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {"found": false}

	var collider: Node = hit.get("collider") as Node
	if _is_actor_collider(collider):
		return {"found": false}

	var hit_position: Vector3 = hit["position"]
	return {
		"found": true,
		"position": Vector3(candidate.x, hit_position.y, candidate.z),
	}


func _has_clearance(position: Vector3) -> bool:
	var world: World3D = get_world_3d()
	if world == null:
		return false

	var shape: CapsuleShape3D = CapsuleShape3D.new()
	shape.radius = maxf(clearance_radius, 0.05)
	shape.height = maxf(clearance_height, shape.radius * 2.0)

	var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(
			Basis(),
			position + Vector3.UP * ((shape.height * 0.5) + CLEARANCE_GROUND_EPSILON))
	query.collision_mask = obstruction_collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = true

	var collisions: Array[Dictionary] = world.direct_space_state.intersect_shape(query, 32)
	return collisions.is_empty()


func _is_too_close_to_selected_position(position: Vector3, selected_positions: Array[Vector3]) -> bool:
	var required_spacing: float = maxf(spawn_spacing, clearance_radius * 2.0)
	for selected_position: Vector3 in selected_positions:
		var delta: Vector2 = Vector2(
				position.x - selected_position.x,
				position.z - selected_position.z)
		if delta.length() < required_spacing:
			return true
	return false


func _is_actor_collider(collider: Node) -> bool:
	if collider == null:
		return false
	return collider.is_in_group("players") or collider.is_in_group("enemies")


func _find_hit_receiver(root: Node) -> HitReceiver:
	var receiver: HitReceiver = root.get_node_or_null("HitReceiver") as HitReceiver
	if receiver != null:
		return receiver
	return root.find_child("HitReceiver", true, false) as HitReceiver


func _on_spawned_enemy_died(enemy: Node3D) -> void:
	_remove_active_enemy(enemy)


func _on_spawned_enemy_tree_exited(enemy: Node3D) -> void:
	_remove_active_enemy(enemy)


func _remove_active_enemy(enemy: Node3D) -> void:
	var index: int = _active_enemies.find(enemy)
	if index == -1:
		return
	_active_enemies.remove_at(index)
	if _active_enemies.is_empty():
		_begin_cooldown()


func _begin_cooldown() -> void:
	_state = SpawnState.COOLDOWN
	_cooldown_remaining = maxf(cooldown_seconds, 0.0)
	if _cooldown_remaining <= 0.0:
		call_deferred("_finish_cooldown")


func _finish_cooldown() -> void:
	if _state != SpawnState.COOLDOWN:
		return
	if repeat_encounter:
		_state = SpawnState.IDLE
		call_deferred("_spawn_encounter")
	else:
		_state = SpawnState.INACTIVE

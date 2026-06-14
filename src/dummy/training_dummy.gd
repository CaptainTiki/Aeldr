class_name TrainingDummy
extends CharacterBody3D
## Immortal punching bag. Reacts to hits with knockback, a white flash, and a
## puff of particles. Knockback decays with friction so the slide is readable.

@export var knockback_friction: float = 18.0
@export var flash_energy: float = 3.5
@export var flash_seconds: float = 0.18

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _flash_tween: Tween = null
var _flash_material: StandardMaterial3D = null

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _particles: GPUParticles3D = $HitParticles
@onready var _receiver: HitReceiver = $HitReceiver


func _ready() -> void:
	_receiver.hit_received.connect(_on_hit_received)
	# The mesh resource is shared across instances; flashing its material would
	# flash every dummy. Each instance gets its own override copy instead.
	var base_material: StandardMaterial3D = _mesh.get_active_material(0) as StandardMaterial3D
	if base_material != null:
		_flash_material = base_material.duplicate() as StandardMaterial3D
		_mesh.set_surface_override_material(0, _flash_material)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	velocity.x = move_toward(velocity.x, 0.0, knockback_friction * delta)
	velocity.z = move_toward(velocity.z, 0.0, knockback_friction * delta)
	move_and_slide()


func _on_hit_received(_damage: float, knockback: Vector2, _source: Node) -> void:
	velocity.x = knockback.x
	velocity.z = knockback.y
	_particles.restart()
	_flash()


func _flash() -> void:
	if _flash_material == null:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_material.emission_energy_multiplier = flash_energy
	_flash_tween = create_tween()
	_flash_tween.tween_property(_flash_material, "emission_energy_multiplier", 0.0, flash_seconds)

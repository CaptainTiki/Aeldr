class_name HitReceiver
extends Node3D
## The single chokepoint for incoming hits. All damage and knockback enter
## through take_hit() — nothing else may modify health. Belongs in the
## "damageable" group so weapons can find it.

signal hit_received(damage: float, knockback: Vector2, source: Node)
signal hit_blocked(damage: float, knockback: Vector2, source: Node)
signal health_changed(current_health: float, max_health: float)
signal died

@export var max_health: float = 100.0
## Indestructible receivers (training dummies) refill instead of dying.
@export var destructible: bool = true
@export var block_state: Node

var health: float = 0.0
var is_dead: bool = false


func _ready() -> void:
	reset_health()


func take_hit(damage: float, knockback: Vector2, source: Node, can_block: bool = true) -> void:
	if is_dead:
		return
	if can_block \
			and block_state != null \
			and block_state.has_method("try_block_hit") \
			and bool(block_state.call("try_block_hit", damage, knockback, source)):
		hit_blocked.emit(damage, knockback, source)
		return
	var applied_damage: float = maxf(damage, 0.0)
	var previous_health: float = health
	health = clampf(health - applied_damage, 0.0, max_health)
	if not is_equal_approx(health, previous_health):
		health_changed.emit(health, max_health)
	hit_received.emit(applied_damage, knockback, source)
	if health > 0.0:
		return
	if destructible:
		is_dead = true
		died.emit()
	else:
		reset_health()


func heal(amount: float) -> void:
	if is_dead or amount <= 0.0:
		return
	var previous_health: float = health
	health = minf(health + amount, max_health)
	if is_equal_approx(health, previous_health):
		return
	health_changed.emit(health, max_health)


func reset_health() -> void:
	health = max_health
	is_dead = false
	health_changed.emit(health, max_health)

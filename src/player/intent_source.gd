class_name IntentSource
extends Node
## Base class for anything that produces character intents: local input, AI,
## or (later) a network peer. Characters consume intents and never read Input.
## Also owns the attack input buffer (so the same buffer later serves
## dodge-canceling): a press is remembered until consumed or expired.

var move_input: Vector2 = Vector2.ZERO
var aim_point: Vector3 = Vector3.ZERO
var attack_just_pressed: bool = false
## Time.get_ticks_msec() of the most recent unconsumed attack press, -1 if none.
var attack_press_ticks_ms: int = -1
## True while the attack input is physically down.
var attack_held: bool = false
## True while the block input is physically down.
var block_held: bool = false
var dodge_just_pressed: bool = false
var respawn_held: bool = false
## Time.get_ticks_msec() when the current physical hold began, -1 while up.
## Unlike the press buffer this is never consumed — branch logic reads it live
## to tell a deliberate hold from a quick tap.
var attack_held_since_ms: int = -1


func poll() -> void:
	pass


func clear() -> void:
	move_input = Vector2.ZERO
	attack_just_pressed = false
	attack_press_ticks_ms = -1
	attack_held = false
	block_held = false
	dodge_just_pressed = false
	respawn_held = false
	attack_held_since_ms = -1


## True if an unconsumed attack press is younger than window_seconds and
## happened at or after since_ticks_ms (pass -1 to accept presses of any origin).
func has_buffered_attack(window_seconds: float, since_ticks_ms: int) -> bool:
	if attack_press_ticks_ms < 0:
		return false
	if since_ticks_ms >= 0 and attack_press_ticks_ms < since_ticks_ms:
		return false
	return Time.get_ticks_msec() - attack_press_ticks_ms <= int(window_seconds * 1000.0)


## Consumers call this when they act on a press so it can't trigger twice.
func consume_attack() -> void:
	attack_just_pressed = false
	attack_press_ticks_ms = -1

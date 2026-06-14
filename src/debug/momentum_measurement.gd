class_name MomentumMeasurement
extends SceneTree
## Headless tuning helper for the net-zero rule:
## clean forward sprint should travel at least as far as forward swing-spam.
## Run with:
## godot --headless --path . --script res://src/debug/momentum_measurement.gd

const STATS_PATH: String = "res://src/combat/greatsword_stats.tres"
const SIM_SECONDS: float = 5.0
const FIXED_DELTA: float = 1.0 / 60.0

const MAX_SPEED: float = 6.0
const ACCEL_TIME: float = 0.27
const COAST_TIME: float = 0.40
const OVERSPEED_DECAY_TIME: float = 0.45

var _stats: MeleeWeaponStats = null


func _initialize() -> void:
	_stats = load(STATS_PATH) as MeleeWeaponStats
	if _stats == null:
		push_error("Could not load %s" % STATS_PATH)
		quit(1)
		return

	var clean_distance: float = _simulate_clean_sprint()
	var swing_distance: float = _simulate_forward_swing_spam()
	var margin: float = clean_distance - swing_distance
	print("Momentum measurement over %.2fs" % SIM_SECONDS)
	print("  clean sprint: %.3fm" % clean_distance)
	print("  swing travel: %.3fm" % swing_distance)
	print("  clean - swing: %.3fm" % margin)
	if margin < 0.0:
		push_warning("Net-zero rule failed: swing travel beat clean sprint.")
	_print_representative_cycle()
	quit()


func _simulate_clean_sprint() -> float:
	var velocity: float = 0.0
	var position: float = 0.0
	var elapsed: float = 0.0
	while elapsed < SIM_SECONDS:
		velocity = _step_forward_velocity(velocity, 1.0, FIXED_DELTA)
		position += velocity * FIXED_DELTA
		elapsed += FIXED_DELTA
	return position


func _simulate_forward_swing_spam() -> float:
	var velocity: float = 0.0
	var position: float = 0.0
	var elapsed: float = 0.0
	var release_step_remaining: float = 0.0
	var release_step_seconds_remaining: float = 0.0
	var previous_step_velocity: float = 0.0
	var phases: Array[Dictionary] = _build_swing_phases()
	var phase_index: int = 0
	var phase_remaining: float = float(phases[phase_index]["duration"])
	var release_state: Dictionary = _apply_phase_entry_boost(
			phases[phase_index],
			velocity,
			release_step_remaining,
			release_step_seconds_remaining)
	velocity = float(release_state["velocity"])
	release_step_remaining = float(release_state["step_remaining"])
	release_step_seconds_remaining = float(release_state["step_seconds_remaining"])

	while elapsed < SIM_SECONDS:
		var phase: Dictionary = phases[phase_index]
		velocity -= previous_step_velocity
		velocity = _step_forward_velocity(
				velocity,
				float(phase["input_damp"]),
				FIXED_DELTA)
		var step_velocity: float = _release_step_velocity(
				release_step_remaining,
				release_step_seconds_remaining,
				FIXED_DELTA)
		release_step_remaining = maxf(release_step_remaining - step_velocity * FIXED_DELTA, 0.0)
		release_step_seconds_remaining = maxf(
				release_step_seconds_remaining - FIXED_DELTA,
				0.0)
		velocity += step_velocity
		previous_step_velocity = step_velocity
		position += velocity * FIXED_DELTA
		elapsed += FIXED_DELTA
		phase_remaining -= FIXED_DELTA
		if phase_remaining <= 0.0:
			phase_index = (phase_index + 1) % phases.size()
			phase_remaining += float(phases[phase_index]["duration"])
			velocity -= previous_step_velocity
			previous_step_velocity = 0.0
			release_state = _apply_phase_entry_boost(
					phases[phase_index],
					velocity,
					release_step_remaining,
					release_step_seconds_remaining)
			velocity = float(release_state["velocity"])
			release_step_remaining = float(release_state["step_remaining"])
			release_step_seconds_remaining = float(release_state["step_seconds_remaining"])
	return position


func _build_swing_phases() -> Array[Dictionary]:
	var phases: Array[Dictionary] = []
	phases.append({
		"name": "windup_1",
		"duration": _stats.long_windup_seconds,
		"input_damp": _stats.windup_move_multiplier,
		"boost": false,
	})
	phases.append({
		"name": "snap_1",
		"duration": _stats.snap_seconds,
		"input_damp": _stats.snap_move_multiplier,
		"boost": true,
	})
	phases.append({
		"name": "settle_1",
		"duration": _stats.settle_seconds,
		"input_damp": _stats.settle_move_multiplier,
		"boost": false,
	})
	phases.append({
		"name": "hang_1",
		"duration": _stats.hang_seconds,
		"input_damp": _stats.hang_move_multiplier,
		"boost": false,
	})
	phases.append({
		"name": "windup_2_short",
		"duration": _stats.short_windup_seconds,
		"input_damp": _stats.windup_move_multiplier,
		"boost": false,
	})
	phases.append({
		"name": "snap_2",
		"duration": _stats.snap_seconds * _stats.swing2_snap_multiplier,
		"input_damp": _stats.snap_move_multiplier,
		"boost": true,
	})
	phases.append({
		"name": "settle_2",
		"duration": _stats.settle_seconds,
		"input_damp": _stats.settle_move_multiplier,
		"boost": false,
	})
	phases.append({
		"name": "hang_2",
		"duration": _stats.hang_seconds,
		"input_damp": _stats.hang_move_multiplier,
		"boost": false,
	})
	phases.append({
		"name": "windup_1_short",
		"duration": _stats.short_windup_seconds,
		"input_damp": _stats.windup_move_multiplier,
		"boost": false,
	})
	return phases


func _step_forward_velocity(velocity: float, input_damp: float, delta: float) -> float:
	var acceleration_rate: float = MAX_SPEED / ACCEL_TIME
	var coast_rate: float = MAX_SPEED / COAST_TIME
	var target_speed: float = MAX_SPEED * input_damp
	var next_velocity: float = velocity
	if velocity < target_speed:
		next_velocity = move_toward(velocity, target_speed, acceleration_rate * delta)
	elif input_damp < 0.99 and velocity > target_speed:
		var damp_rate: float = coast_rate * (1.0 - input_damp)
		next_velocity = move_toward(velocity, target_speed, damp_rate * delta)

	if next_velocity > MAX_SPEED:
		var overspeed_rate: float = MAX_SPEED / OVERSPEED_DECAY_TIME
		next_velocity = move_toward(next_velocity, MAX_SPEED, overspeed_rate * delta)
	return next_velocity


func _apply_phase_entry_boost(
		phase: Dictionary,
		velocity: float,
		release_step_remaining: float,
		release_step_seconds_remaining: float) -> Dictionary:
	if not bool(phase["boost"]):
		return {
			"velocity": velocity,
			"step_remaining": release_step_remaining,
			"step_seconds_remaining": release_step_seconds_remaining,
		}
	var redirected: float = lerpf(velocity, absf(velocity), _stats.redirect_strength)
	return {
		"velocity": redirected + _stats.swing_boost_impulse * _stats.whiff_boost_multiplier,
		"step_remaining": release_step_remaining + _stats.release_step_distance,
		"step_seconds_remaining": maxf(
				_stats.release_step_seconds,
				release_step_seconds_remaining),
	}


func _release_step_velocity(
		release_step_remaining: float,
		release_step_seconds_remaining: float,
		delta: float) -> float:
	if release_step_remaining <= 0.0 or release_step_seconds_remaining <= 0.0:
		return 0.0
	var step_time: float = minf(delta, release_step_seconds_remaining)
	var distance: float = minf(
			release_step_remaining,
			release_step_remaining * step_time / release_step_seconds_remaining)
	if delta <= 0.0:
		return 0.0
	return distance / delta


func _print_representative_cycle() -> void:
	print("Representative chained cycle starting at max forward speed:")
	var velocity: float = MAX_SPEED
	var release_step_remaining: float = 0.0
	var release_step_seconds_remaining: float = 0.0
	var previous_step_velocity: float = 0.0
	var total_distance: float = 0.0
	var total_clean_distance: float = 0.0
	for phase: Dictionary in _build_swing_phases():
		velocity -= previous_step_velocity
		previous_step_velocity = 0.0
		var release_state: Dictionary = _apply_phase_entry_boost(
				phase,
				velocity,
				release_step_remaining,
				release_step_seconds_remaining)
		velocity = float(release_state["velocity"])
		release_step_remaining = float(release_state["step_remaining"])
		release_step_seconds_remaining = float(release_state["step_seconds_remaining"])
		var start_velocity: float = velocity
		var phase_distance: float = 0.0
		var remaining: float = float(phase["duration"])
		while remaining > 0.0001:
			var step: float = minf(FIXED_DELTA, remaining)
			velocity -= previous_step_velocity
			velocity = _step_forward_velocity(velocity, float(phase["input_damp"]), step)
			var step_velocity: float = _release_step_velocity(
					release_step_remaining,
					release_step_seconds_remaining,
					step)
			release_step_remaining = maxf(release_step_remaining - step_velocity * step, 0.0)
			release_step_seconds_remaining = maxf(
					release_step_seconds_remaining - step,
					0.0)
			velocity += step_velocity
			previous_step_velocity = step_velocity
			phase_distance += velocity * step
			remaining -= step
		var clean_distance: float = MAX_SPEED * float(phase["duration"])
		total_distance += phase_distance
		total_clean_distance += clean_distance
		print("  %-15s dur=%.3fs start_v=%.2f end_v=%.2f dist=%.3fu clean=%.3fu delta=%+.3fu" % [
				String(phase["name"]),
				float(phase["duration"]),
				start_velocity,
				velocity,
				phase_distance,
				clean_distance,
				phase_distance - clean_distance,
		])
	print("  cycle total: %.3fu clean=%.3fu delta=%+.3fu" % [
			total_distance,
			total_clean_distance,
			total_distance - total_clean_distance,
	])

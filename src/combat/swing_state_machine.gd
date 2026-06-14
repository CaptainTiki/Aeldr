class_name SwingStateMachine
extends Node
## Drives the swing combo and the overhead slam finisher:
## Idle → Windup(long) → ContactSnap → Settle → Hang → Reset → Idle.
## After the snap the blade decelerates into its overshoot (Settle) and HANGS
## there cocked — the hang pose IS the opposite swing's short-windup start
## pose, so chaining never reverses the blade mid-flight. The Hang is the only
## combo window: swing 1's hang chains to swing 2 on a fresh press; swing 2's
## hang runs tap-vs-hold detection on the fresh third press (release before the
## threshold plus grace -> chain swing 1, still held after grace -> overhead
## slam, the hang extending up while a hold resolves). Once the Reset begins it always
## completes; a press in its final recovery buffer window fires a fresh
## long-windup swing 1 the moment it ends, older presses expire silently.
## Consumes attack intents, plays the matching AnimationPlayer clip retimed to
## the stats durations, and exposes per-phase movement/facing rules to the
## character. Transitions ride animation_finished — the only timer is hold
## detection, which has no animation. Damage fires from the Call Method keys
## baked into the snap and slam-hit clips, never from here.

signal lunge_started(speed: float)
signal swing_windup(direction: Vector2)
signal swing_release(direction: Vector2, impulse_strength: float)
signal phase_changed(phase_name: String)

enum Phase {
	IDLE,
	WINDUP,
	CONTACT_SNAP,
	SETTLE,
	HANG,
	RESET,
	SLAM_RISE,
	SLAM_APEX,
	SLAM_HIT,
	SLAM_RECOVERY,
}

enum ComboInputStyle {
	NONE,
	PENDING,
	TAP,
	HOLD,
}

## Blend time when a hang branch jumps into the next windup or the slam rise,
## absorbing the few degrees of hang drift at the branch point.
const BRANCH_BLEND_SECONDS: float = 0.06

@export var stats: MeleeWeaponStats
@export var intents: IntentSource
@export var animation_player: AnimationPlayer
@export var debug_combo_timing: bool = true

const RESET_POSE_ANIMATION: StringName = &"RESET"

var _phase: Phase = Phase.IDLE
var _swing_index: int = 1
## The current swing only accepts combo presses that occur after this timestamp.
var _combo_accept_started_at_ms: int = -1
var _combo_press_ticks_ms: int = -1
var _combo_input_style: ComboInputStyle = ComboInputStyle.NONE
var _hang_clip_finished: bool = false
var _phase_started_at_ms: int = 0
var _phase_planned_duration_ms: int = -1
var _active_phase_animation: StringName = &""
var _action_allowed: bool = true
var _debug_previous_attack_held: bool = false
var _debug_current_press_ms: int = -1


func _ready() -> void:
	animation_player.animation_finished.connect(_on_animation_finished)
	_phase_started_at_ms = Time.get_ticks_msec()
	_log_phase_start(_phase, -1)


func _physics_process(_delta: float) -> void:
	if not _action_allowed:
		if intents != null:
			intents.consume_attack()
		return
	_debug_track_attack_input()
	_process_combo_input()
	match _phase:
		Phase.IDLE:
			if intents.has_buffered_attack(stats.buffer_seconds, -1):
				_start_windup(1, true, "initial_attack")
		Phase.HANG:
			_process_hang_branch()
		_:
			pass


func is_swinging() -> bool:
	return _phase != Phase.IDLE


func current_phase_name() -> String:
	return _phase_name(_phase)


func set_action_allowed(is_allowed: bool) -> void:
	_action_allowed = is_allowed
	if not _action_allowed and intents != null:
		intents.consume_attack()


func cancel_for_dodge() -> void:
	cancel_actions("dodge_cancel")


func cancel_actions(reason: String) -> void:
	_action_allowed = false
	if intents != null:
		intents.consume_attack()
	_cancel_pending_attack_resolver_hits()
	_reset_combo_input(reason)
	_hang_clip_finished = false
	_combo_accept_started_at_ms = -1
	_combo_press_ticks_ms = -1
	_combo_input_style = ComboInputStyle.NONE
	_debug_current_press_ms = -1
	_debug_previous_attack_held = intents != null and intents.attack_held
	_active_phase_animation = &""
	_apply_reset_pose()
	if _phase != Phase.IDLE:
		_set_phase(Phase.IDLE)


## Facing locks while the strike is aimed: ContactSnap keeps the sweep on
## target, apex + hit keep the slam's impact point planted.
func facing_locked() -> bool:
	return _phase == Phase.CONTACT_SNAP \
			or _phase == Phase.SLAM_APEX \
			or _phase == Phase.SLAM_HIT


## Movement speed factor for the current phase. Reset recovers linearly to
## 1.0 as it plays out; slam recovery ramps 0 → the stats multiplier.
func move_multiplier() -> float:
	match _phase:
		Phase.WINDUP, Phase.SLAM_RISE:
			return stats.windup_move_multiplier
		Phase.CONTACT_SNAP:
			return stats.snap_move_multiplier
		Phase.SETTLE:
			return stats.settle_move_multiplier
		Phase.HANG:
			return stats.hang_move_multiplier
		Phase.RESET:
			return lerpf(stats.reset_move_multiplier, 1.0, _clip_fraction())
		Phase.SLAM_APEX, Phase.SLAM_HIT:
			return 0.0
		Phase.SLAM_RECOVERY:
			return lerpf(0.0, stats.slam_recovery_move_multiplier, _clip_fraction())
		_:
			return 1.0


## Combo input is collected during the whole swing and spent at Hang. Swing 1
## only needs a fresh second press; swing 2 uses tap-vs-hold on the third press.
func _process_combo_input() -> void:
	if not _phase_accepts_combo_input():
		return
	if _combo_input_style == ComboInputStyle.NONE:
		if intents.attack_press_ticks_ms < _combo_accept_started_at_ms:
			return
		_combo_press_ticks_ms = intents.attack_press_ticks_ms
		_combo_input_style = ComboInputStyle.PENDING
		if _swing_index == 2:
			_combo_debug("THIRD_PRESS_DETECTED press_ms=%d phase=%s swing=%d %s" % [
					_combo_press_ticks_ms,
					_phase_name(_phase),
					_swing_index,
					_combo_state_text(),
			])
		else:
			_combo_debug("SECOND_PRESS_DETECTED press_ms=%d phase=%s swing=%d %s" % [
					_combo_press_ticks_ms,
					_phase_name(_phase),
					_swing_index,
					_combo_state_text(),
			])
			_consume_attack("second_press_buffered")
			return
	if _combo_input_style != ComboInputStyle.PENDING:
		return
	if _swing_index != 2:
		return
	if not _combo_press_is_still_held():
		_combo_input_style = ComboInputStyle.TAP
		_combo_debug("TAP_DETECTED press_ms=%d released_before_hold_ready=true threshold_ms=%d grace_ms=%d %s" % [
				_combo_press_ticks_ms,
				int(stats.hold_threshold_seconds * 1000.0),
				int(stats.hold_grace_seconds * 1000.0),
				_combo_state_text(),
		])
		_consume_attack("tap_detected")
		return
	var held_ms: int = Time.get_ticks_msec() - _combo_press_ticks_ms
	var hold_ready_ms: int = _hold_ready_ms()
	if _swing_index == 2 and held_ms >= hold_ready_ms:
		_combo_input_style = ComboInputStyle.HOLD
		_combo_debug("HOLD_DETECTED press_ms=%d held_for_ms=%d threshold_ms=%d grace_ms=%d ready_ms=%d %s" % [
				_combo_press_ticks_ms,
				held_ms,
				int(stats.hold_threshold_seconds * 1000.0),
				int(stats.hold_grace_seconds * 1000.0),
				hold_ready_ms,
				_combo_state_text(),
		])
		_consume_attack("hold_detected")


func _phase_accepts_combo_input() -> bool:
	return _phase == Phase.WINDUP \
			or _phase == Phase.CONTACT_SNAP \
			or _phase == Phase.SETTLE \
			or _phase == Phase.HANG


func _combo_press_is_still_held() -> bool:
	if not intents.attack_held:
		return false
	if intents.attack_held_since_ms != _combo_press_ticks_ms:
		_combo_debug(
				"SLAM_REJECTED reason=held_input_does_not_match_tracked_press held_since_ms=%d tracked_press_ms=%d %s" % [
						intents.attack_held_since_ms,
						_combo_press_ticks_ms,
						_combo_state_text(),
				])
		return false
	return intents.attack_held \
			and intents.attack_held_since_ms == _combo_press_ticks_ms


func _hold_ready_ms() -> int:
	return int((stats.hold_threshold_seconds + stats.hold_grace_seconds) * 1000.0)


func _has_recovery_buffered_attack() -> bool:
	if intents.attack_press_ticks_ms < _phase_started_at_ms:
		return false
	return intents.has_buffered_attack(stats.recovery_buffer_seconds, _phase_started_at_ms)


func _log_recovery_ignored_attack() -> void:
	if intents.attack_press_ticks_ms < _phase_started_at_ms:
		return
	_combo_debug("INPUT_IGNORED reason=recovery_too_early press_ms=%d buffer_ms=%d %s" % [
			intents.attack_press_ticks_ms,
			int(stats.recovery_buffer_seconds * 1000.0),
			_combo_state_text(),
	])


func _process_hang_branch() -> void:
	if _swing_index == 1:
		if _combo_input_style == ComboInputStyle.PENDING:
			_combo_debug("SWING_BRANCH reason=buffered_second_press %s" % _combo_state_text())
			_start_windup(2, false, "buffered_second_press", false)
		elif _combo_input_style == ComboInputStyle.NONE and _hang_clip_finished:
			_combo_debug("SWING_BRANCH_REJECTED reason=no_buffered_second_press %s" % _combo_state_text())
			_start_reset()
		return
	if _combo_input_style == ComboInputStyle.TAP:
		_combo_debug("SWING_BRANCH reason=third_press_tapped %s" % _combo_state_text())
		_start_windup(1, false, "third_press_tap_loop", false)
	elif _combo_input_style == ComboInputStyle.HOLD:
		_combo_debug("SLAM_BRANCH reason=third_press_held %s" % _combo_state_text())
		_start_slam()
	elif _combo_input_style == ComboInputStyle.NONE and _hang_clip_finished:
		_combo_debug("SLAM_REJECTED reason=no_fresh_third_press %s" % _combo_state_text())
		_start_reset()


## from_idle picks the long windup clip (idle → cocked); every chained swing
## plays the short clip that starts exactly at the previous swing's hang pose.
func _start_windup(swing_index: int, from_idle: bool, reason: String, consume_attack: bool = true) -> void:
	_swing_index = swing_index
	_hang_clip_finished = false
	if consume_attack:
		_consume_attack(reason)
	_reset_combo_input("start_windup")
	_combo_accept_started_at_ms = Time.get_ticks_msec()
	swing_windup.emit(_facing_xz())
	var clip: String = "windup_%d" if from_idle else "windup_%d_short"
	var duration: float = stats.long_windup_seconds if from_idle else stats.short_windup_seconds
	var blend: float = 0.0 if from_idle else BRANCH_BLEND_SECONDS
	_combo_debug("START_WINDUP swing=%d reason=%s %s" % [
			_swing_index,
			reason,
			_combo_state_text(),
	])
	_set_phase(Phase.WINDUP, duration)
	_play_clip(clip % _swing_index, duration, blend)


func _start_snap() -> void:
	var direction: Vector2 = _facing_xz()
	swing_release.emit(direction, stats.swing_boost_impulse * stats.whiff_boost_multiplier)
	lunge_started.emit(stats.lunge_speed)
	var duration: float = stats.snap_seconds
	if _swing_index == 2:
		duration *= stats.swing2_snap_multiplier
	_set_phase(Phase.CONTACT_SNAP, duration)
	_play_clip("snap_%d" % _swing_index, duration, 0.0)


func _start_settle() -> void:
	_set_phase(Phase.SETTLE, stats.settle_seconds)
	_play_clip("settle_%d" % _swing_index, stats.settle_seconds, 0.0)


func _start_hang() -> void:
	_hang_clip_finished = false
	_set_phase(Phase.HANG, stats.hang_seconds)
	_play_clip("hang_%d" % _swing_index, stats.hang_seconds, 0.0)


func _start_reset() -> void:
	_hang_clip_finished = false
	_reset_combo_input("enter_recovery")
	_set_phase(Phase.RESET, stats.reset_seconds)
	_play_clip("reset_%d" % _swing_index, stats.reset_seconds, 0.0)


func _start_slam() -> void:
	_hang_clip_finished = false
	# The slam honors no buffer: any pending press is discarded outright.
	_consume_attack("start_slam")
	_reset_combo_input("start_slam")
	_combo_debug("START_SLAM reason=third_press_hold %s" % _combo_state_text())
	_set_phase(Phase.SLAM_RISE, stats.slam_rise_seconds)
	_play_clip("slam_rise", stats.slam_rise_seconds, BRANCH_BLEND_SECONDS)


func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name != _active_phase_animation:
		return
	match _phase:
		Phase.WINDUP:
			_start_snap()
		Phase.CONTACT_SNAP:
			_start_settle()
		Phase.SETTLE:
			_start_hang()
		Phase.HANG:
			_hang_clip_finished = true
			_process_hang_branch()
		Phase.RESET:
			# The reset always completes. A recent press fires a fresh
			# from-idle attack right now; earlier recovery presses are ignored.
			if _has_recovery_buffered_attack():
				_combo_debug("RECOVERY_BUFFERED_ATTACK press_ms=%d %s" % [
						intents.attack_press_ticks_ms,
						_combo_state_text(),
				])
				_start_windup(1, true, "recovery_buffered_attack")
			else:
				_log_recovery_ignored_attack()
				_set_phase(Phase.IDLE)
		Phase.SLAM_RISE:
			_set_phase(Phase.SLAM_APEX, stats.slam_apex_seconds)
			_play_clip("slam_apex", stats.slam_apex_seconds, 0.0)
		Phase.SLAM_APEX:
			_set_phase(Phase.SLAM_HIT, stats.slam_hit_seconds)
			_play_clip("slam_hit", stats.slam_hit_seconds, 0.0)
		Phase.SLAM_HIT:
			_set_phase(Phase.SLAM_RECOVERY, stats.slam_recovery_seconds)
			_play_clip("slam_recover", stats.slam_recovery_seconds, 0.0)
		Phase.SLAM_RECOVERY:
			# Presses made during the slam never carry out of it: the chain
			# fully resets and the next attack is a fresh long-windup swing 1.
			_consume_attack("slam_recovery_finished")
			_reset_combo_input("slam_recovery_finished")
			_hang_clip_finished = false
			_set_phase(Phase.IDLE)
		_:
			pass


## Plays a clip scaled so the authored animation lasts exactly `duration`
## seconds.
func _play_clip(animation_name: String, duration: float, blend: float) -> void:
	var animation: Animation = animation_player.get_animation(animation_name)
	_active_phase_animation = StringName(animation_name)
	var speed: float = animation.length / maxf(duration, 0.001)
	animation_player.play(animation_name, blend if blend > 0.0 else -1.0, speed)


func _apply_reset_pose() -> void:
	if animation_player == null:
		return
	animation_player.stop()
	if not animation_player.has_animation(RESET_POSE_ANIMATION):
		return
	animation_player.play(RESET_POSE_ANIMATION)
	animation_player.seek(0.0, true)
	animation_player.stop(true)


func _cancel_pending_attack_resolver_hits() -> void:
	var wielder: Node = get_parent()
	if wielder == null:
		return
	var resolver: Node = wielder.get_node_or_null("MeleeAttackResolver")
	if resolver != null and resolver.has_method("cancel_pending_attacks"):
		resolver.call("cancel_pending_attacks")


func _consume_attack(reason: String) -> void:
	_combo_debug("INPUT_CONSUME attack press_ms=%d reason=%s %s" % [
			intents.attack_press_ticks_ms,
			reason,
			_combo_state_text(),
	])
	intents.consume_attack()


func _reset_combo_input(reason: String) -> void:
	_combo_debug("RESET_COMBO reason=%s tracked_press_ms=%d combo_input=%s %s" % [
			reason,
			_combo_press_ticks_ms,
			_combo_input_style_name(),
			_combo_state_text(),
	])
	_combo_accept_started_at_ms = -1
	_combo_press_ticks_ms = -1
	_combo_input_style = ComboInputStyle.NONE


func _debug_track_attack_input() -> void:
	if intents.attack_held and not _debug_previous_attack_held:
		if intents.attack_held_since_ms < 0:
			return
		_debug_current_press_ms = intents.attack_held_since_ms
		_combo_debug("INPUT_PRESS attack press_ms=%d %s" % [
				_debug_current_press_ms,
				_combo_state_text(),
	])
	elif not intents.attack_held and _debug_previous_attack_held:
		var release_ms: int = Time.get_ticks_msec()
		var held_for_ms: int = 0
		if _debug_current_press_ms >= 0:
			held_for_ms = release_ms - _debug_current_press_ms
		_combo_debug("INPUT_RELEASE attack release_ms=%d held_for_ms=%d %s" % [
				release_ms,
				held_for_ms,
				_combo_state_text(),
		])
		_debug_current_press_ms = -1
	_debug_previous_attack_held = intents.attack_held


func _combo_debug(message: String) -> void:
	if not debug_combo_timing:
		return
	var now_ms: int = Time.get_ticks_msec()
	print("[COMBO %dms] %s" % [now_ms, message])


func debug_slam_impact() -> void:
	_combo_debug("SLAM_IMPACT %s" % _combo_state_text())


func _combo_state_text() -> String:
	var buffered_attack: bool = intents.has_buffered_attack(stats.buffer_seconds, -1)
	var now_ms: int = Time.get_ticks_msec()
	return "state phase=%s swing=%d attack_press_ms=%d attack_held_since_ms=%d attack_held=%s tracked_press_ms=%d combo_input=%s buffered_attack=%s phase_elapsed_ms=%d phase_planned_ms=%d hang_finished=%s" % [
			_phase_name(_phase),
			_swing_index,
			intents.attack_press_ticks_ms,
			intents.attack_held_since_ms,
			str(intents.attack_held),
			_combo_press_ticks_ms,
			_combo_input_style_name(),
			str(buffered_attack),
			now_ms - _phase_started_at_ms,
			_phase_planned_duration_ms,
			str(_hang_clip_finished),
	]


func _combo_input_style_name() -> String:
	match _combo_input_style:
		ComboInputStyle.NONE:
			return "none"
		ComboInputStyle.PENDING:
			return "pending"
		ComboInputStyle.TAP:
			return "tap"
		ComboInputStyle.HOLD:
			return "hold"
		_:
			return "unknown"


func _phase_debug_label(phase: Phase) -> String:
	if phase == Phase.IDLE:
		return "SWING%d_IDLE" % _swing_index
	if phase == Phase.WINDUP:
		return "SWING%d_WINDUP" % _swing_index
	if phase == Phase.CONTACT_SNAP:
		return "SWING%d_SNAP" % _swing_index
	if phase == Phase.SETTLE:
		return "SWING%d_SETTLE" % _swing_index
	if phase == Phase.HANG:
		return "SWING%d_HANG" % _swing_index
	if phase == Phase.RESET:
		return "SWING%d_RECOVERY" % _swing_index
	if phase == Phase.SLAM_RISE:
		return "SLAM_RISE"
	if phase == Phase.SLAM_APEX:
		return "SLAM_APEX"
	if phase == Phase.SLAM_HIT:
		return "SLAM_HIT"
	if phase == Phase.SLAM_RECOVERY:
		return "SLAM_RECOVERY"
	return "UNKNOWN_PHASE"


func _log_phase_start(phase: Phase, planned_duration_seconds: float) -> void:
	var duration_ms: int = -1
	if planned_duration_seconds >= 0.0:
		duration_ms = int(planned_duration_seconds * 1000.0)
	var label: String = _phase_debug_label(phase)
	_phase_started_at_ms = Time.get_ticks_msec()
	_phase_planned_duration_ms = duration_ms
	_combo_debug("%s_START duration_ms=%d phase_started_ms=%d combo_accept_started_ms=%d tracked_press_ms=%d %s" % [
			label,
			duration_ms,
			_phase_started_at_ms,
			_combo_accept_started_at_ms,
			_combo_press_ticks_ms,
			_combo_state_text(),
	])


func _log_phase_end(phase: Phase) -> void:
	var now_ms: int = Time.get_ticks_msec()
	var label: String = _phase_debug_label(phase)
	_combo_debug("%s_END elapsed_ms=%d planned_duration_ms=%d %s" % [
			label,
			now_ms - _phase_started_at_ms,
			_phase_planned_duration_ms,
			_combo_state_text(),
	])


func _clip_fraction() -> float:
	if animation_player.current_animation.is_empty():
		return 1.0
	var length: float = animation_player.current_animation_length
	if length <= 0.0:
		return 1.0
	return clampf(animation_player.current_animation_position / length, 0.0, 1.0)


func _facing_xz() -> Vector2:
	var wielder: Node3D = get_parent() as Node3D
	if wielder == null:
		return Vector2.UP
	var forward: Vector3 = -wielder.global_transform.basis.z
	return Vector2(forward.x, forward.z).normalized()


func _set_phase(next_phase: Phase, planned_duration_seconds: float = -1.0) -> void:
	if _phase == next_phase:
		return
	_log_phase_end(_phase)
	_phase = next_phase
	if _phase == Phase.IDLE:
		_active_phase_animation = &""
	_log_phase_start(_phase, planned_duration_seconds)
	phase_changed.emit(_phase_name(_phase))


func _phase_name(phase: Phase) -> String:
	match phase:
		Phase.IDLE:
			return "idle"
		Phase.WINDUP:
			return "windup_%d" % _swing_index
		Phase.CONTACT_SNAP:
			return "snap_%d" % _swing_index
		Phase.SETTLE:
			return "settle_%d" % _swing_index
		Phase.HANG:
			return "hang_%d" % _swing_index
		Phase.RESET:
			return "reset_%d" % _swing_index
		Phase.SLAM_RISE:
			return "slam_rise"
		Phase.SLAM_APEX:
			return "slam_apex"
		Phase.SLAM_HIT:
			return "slam_hit"
		Phase.SLAM_RECOVERY:
			return "slam_recovery"
		_:
			return "unknown"

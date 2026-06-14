class_name MeleeWeaponStats
extends Resource
## Every tuning number for one melee weapon. One .tres per weapon: the next
## weapon is a new .tres plus animations, zero new code. Phase durations here
## retime the AnimationPlayer clips at runtime, so the damage keys baked into
## the clips can never desync from the visual blade pass.

@export_group("Damage")
@export var damage: float = 25.0
## Max hit distance on the XZ plane.
@export var attack_radius: float = 3.2
## Full width of the hit arc, centered on facing.
@export var attack_arc_degrees: float = 140.0
@export var knockback_force: float = 14.0
@export var camera_kick_strength: float = 0.6

@export_group("Phase Durations")
## Windup when starting a swing from Idle.
@export var long_windup_seconds: float = 0.30
## Windup for every chained swing — it starts from the previous swing's hang
## pose, already cocked, and only finishes the coil.
@export var short_windup_seconds: float = 0.12
@export var snap_seconds: float = 0.08
## Blade decelerates into the overshoot after the snap.
@export var settle_seconds: float = 0.12
## Blade hangs cocked at the overshoot. This is the combo window and the
## primary combo-rhythm tuning knob.
@export var hang_seconds: float = 0.20
## Deliberate, uninterruptible return to idle once the hang expires.
@export var reset_seconds: float = 0.35

@export_group("Movement")
@export_range(0.0, 1.0) var windup_move_multiplier: float = 0.65
@export_range(0.0, 1.0) var snap_move_multiplier: float = 1.00
@export_range(0.0, 1.0) var settle_move_multiplier: float = 0.65
@export_range(0.0, 1.0) var hang_move_multiplier: float = 0.65
## Multiplier at the start of Reset; recovers linearly to 1.0 by reset end.
@export_range(0.0, 1.0) var reset_move_multiplier: float = 0.65
## Forward impulse at the start of ContactSnap so attacking pulses momentum.
@export var lunge_speed: float = 1.5
## Release-phase momentum impulse along the swing direction. This can push the
## player over max speed; Player decays that overspeed instead of clamping it.
@export var swing_boost_impulse: float = 3.0
## Extra release step spent over a short window so each swing visibly moves.
@export var release_step_distance: float = 0.55
@export var release_step_seconds: float = 0.10
@export_range(0.0, 1.0) var release_step_input_cancel_strength: float = 1.0
## Blends current velocity toward the swing direction before the impulse lands.
@export_range(0.0, 1.0) var redirect_strength: float = 0.45
## Default 1.0: whiffs boost just like hits. Kept tunable for future taste tests.
@export var whiff_boost_multiplier: float = 1.0

@export_group("Combo")
## How long a buffered attack press stays valid. Presses during Settle are
## buffered and resolved the moment the Hang begins.
@export var buffer_seconds: float = 0.2
## Tap-vs-hold discriminator in swing 2's hang: released before this age
## plus grace -> chain swing 1; still held after grace -> overhead slam.
@export var hold_threshold_seconds: float = 0.25
## Extra time after the hold threshold before slam can fire, so releases near
## the threshold still resolve as taps.
@export var hold_grace_seconds: float = 0.05
## A press during the final slice of Reset fires a fresh long-windup attack the
## moment Reset completes; earlier recovery presses are logged and ignored.
@export var recovery_buffer_seconds: float = 0.2
## ContactSnap duration scale on every even-position swing (slightly faster).
@export var swing2_snap_multiplier: float = 0.85
## Knockback scale on every even-position swing (slightly harder).
@export var swing2_knockback_multiplier: float = 1.15

@export_group("Slam")
## Hit circle radius around the impact point — full circle, no arc check.
@export var slam_radius: float = 3.0
## Impact point distance in front of the player on the XZ plane.
@export var slam_forward_offset: float = 1.5
@export var slam_damage_multiplier: float = 2.5
@export var slam_knockback_multiplier: float = 2.0
## Blade-rises-overhead charge entered from swing 2's hang.
@export var slam_rise_seconds: float = 0.18
## Pause at the overhead apex before the drop.
@export var slam_apex_seconds: float = 0.1
## The vertical drop into the ground.
@export var slam_hit_seconds: float = 0.07
## Uncancelable recovery after impact; presses during it are discarded and the
## chain fully resets to a long-windup swing 1.
@export var slam_recovery_seconds: float = 0.5
## Movement multiplier reached by the end of slam recovery (ramps from 0).
@export_range(0.0, 1.0) var slam_recovery_move_multiplier: float = 0.4
## Per-meter hit delay so multi-target impacts ripple outward from the
## impact point.
@export var slam_ripple_seconds_per_meter: float = 0.03
## Camera shake strength at impact (bigger than the swing kick).
@export var slam_camera_shake: float = 1.0

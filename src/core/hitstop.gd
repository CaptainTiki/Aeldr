extends Node
## Global hitstop service (autoload "Hitstop"). Freezes gameplay time for a few
## frames on a confirmed hit. Overlapping requests extend to the latest end time.

const FROZEN_TIME_SCALE: float = 0.35

var _end_time_ms: int = 0
var _active: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func request(duration_seconds: float) -> void:
	var end_ms: int = Time.get_ticks_msec() + int(duration_seconds * 1000.0)
	if end_ms > _end_time_ms:
		_end_time_ms = end_ms
	if _active:
		return
	_active = true
	Engine.time_scale = FROZEN_TIME_SCALE
	while Time.get_ticks_msec() < _end_time_ms:
		await get_tree().process_frame
	Engine.time_scale = 1.0
	_active = false

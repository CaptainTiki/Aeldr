class_name PlayerInput
extends IntentSource
## Converts local mouse/keyboard input into intents. The only gameplay script
## allowed to read Input. Aim is the mouse cursor projected onto the XZ plane.


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func poll() -> void:
	move_input = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	attack_just_pressed = Input.is_action_just_pressed("attack")
	attack_held = Input.is_action_pressed("attack")
	block_held = Input.is_action_pressed("block")
	dodge_just_pressed = Input.is_action_just_pressed("dodge")
	respawn_held = Input.is_action_pressed("respawn")
	if attack_just_pressed:
		attack_press_ticks_ms = Time.get_ticks_msec()
		attack_held_since_ms = attack_press_ticks_ms
	elif not attack_held:
		attack_held_since_ms = -1
	_update_aim_point()


func _update_aim_point() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	var body: Node3D = get_parent() as Node3D
	if camera == null or body == null:
		return
	var mouse_position: Vector2 = get_viewport().get_mouse_position()
	var ray_origin: Vector3 = camera.project_ray_origin(mouse_position)
	var ray_direction: Vector3 = camera.project_ray_normal(mouse_position)
	var aim_plane: Plane = Plane(Vector3.UP, body.global_position.y)
	var intersection: Variant = aim_plane.intersects_ray(ray_origin, ray_direction)
	if intersection != null:
		aim_point = intersection

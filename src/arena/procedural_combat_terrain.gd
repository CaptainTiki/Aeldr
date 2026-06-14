class_name ProceduralCombatTerrain
extends Terrain3D
## Deterministic Terrain3D route for combat feel testing.

const GRASS_TEXTURE_ID: int = 0
const DIRT_TEXTURE_ID: int = 1
const CONTROL_BASE_SHIFT: int = 27
const CONTROL_OVERLAY_SHIFT: int = 22
const CONTROL_BLEND_SHIFT: int = 14
const CONTROL_ID_MASK: int = 0x1f
const CONTROL_BLEND_MASK: int = 0xff

@export_group("Terrain Shape")
@export var terrain_size_meters: int = 256
@export var path_height: float = 0.0
@export var surrounding_height_variation: float = 0.75

@export_group("Combat Route")
@export_range(4.0, 16.0, 0.5) var path_width_meters: float = 9.0
@export_range(0.5, 6.0, 0.25) var path_edge_blend_meters: float = 2.0
@export var path_points: Array[Vector2] = [
	Vector2(-38.0, 92.0),
	Vector2(-16.0, 58.0),
	Vector2(10.0, 28.0),
	Vector2(0.0, 0.0),
	Vector2(30.0, -34.0),
	Vector2(6.0, -70.0),
	Vector2(-28.0, -104.0),
]
@export var clearing_centers: Array[Vector2] = [
	Vector2(-16.0, 58.0),
	Vector2(0.0, 0.0),
	Vector2(6.0, -70.0),
]
@export var clearing_radii: PackedFloat32Array = PackedFloat32Array([14.0, 16.0, 13.0])

var _broad_noise: FastNoiseLite = FastNoiseLite.new()
var _detail_noise: FastNoiseLite = FastNoiseLite.new()
var _control_bytes: PackedByteArray = PackedByteArray()


func _ready() -> void:
	_control_bytes.resize(4)
	_configure_noise()
	await regenerate()


func regenerate() -> void:
	var height_image: Image = _create_height_image()
	var control_image: Image = _create_control_image()
	var grass_texture: Terrain3DTextureAsset = await _create_texture_asset(
			"Grass",
			Color.from_hsv(95.0 / 360.0, 0.42, 0.26),
			Color.from_hsv(120.0 / 360.0, 0.48, 0.38),
			512,
			0.10,
			1241)
	var dirt_texture: Terrain3DTextureAsset = await _create_texture_asset(
			"Dirt Path",
			Color.from_hsv(28.0 / 360.0, 0.46, 0.25),
			Color.from_hsv(35.0 / 360.0, 0.50, 0.42),
			512,
			0.045,
			5527)

	_configure_assets(grass_texture, dirt_texture)
	_import_generated_images(height_image, control_image)


func _configure_noise() -> void:
	_broad_noise.seed = 8167
	_broad_noise.frequency = 0.018
	_detail_noise.seed = 2309
	_detail_noise.frequency = 0.055


func _configure_assets(grass_texture: Terrain3DTextureAsset, dirt_texture: Terrain3DTextureAsset) -> void:
	region_size = 128

	var terrain_material: Terrain3DMaterial = material
	if terrain_material == null:
		terrain_material = Terrain3DMaterial.new()
	material = terrain_material
	terrain_material.world_background = Terrain3DMaterial.NONE
	terrain_material.auto_shader = true
	terrain_material.set_shader_param("auto_slope", 0.0)
	terrain_material.set_shader_param("blend_sharpness", 0.55)

	assets = Terrain3DAssets.new()
	assets.set_texture(GRASS_TEXTURE_ID, grass_texture)
	assets.set_texture(DIRT_TEXTURE_ID, dirt_texture)


func _import_generated_images(height_image: Image, control_image: Image) -> void:
	var imported_images: Array[Image] = []
	imported_images.resize(Terrain3DRegion.TYPE_MAX)
	imported_images[Terrain3DRegion.TYPE_HEIGHT] = height_image
	imported_images[Terrain3DRegion.TYPE_CONTROL] = control_image

	var half_size: float = float(_sample_count()) * 0.5
	data.import_images(imported_images, Vector3(-half_size, 0.0, -half_size), 0.0, 1.0)
	data.calc_height_range(true)


func _create_height_image() -> Image:
	var sample_count: int = _sample_count()
	var image: Image = Image.create_empty(sample_count, sample_count, false, Image.FORMAT_RF)
	var half_size: float = float(sample_count) * 0.5
	for x: int in range(sample_count):
		for z: int in range(sample_count):
			var point: Vector2 = Vector2(float(x) + 0.5 - half_size, float(z) + 0.5 - half_size)
			var route_strength: float = _route_strength(point)
			var surrounding_height: float = _surrounding_height(point)
			var height: float = lerpf(surrounding_height, path_height, route_strength)
			image.set_pixel(x, z, Color(height, 0.0, 0.0, 1.0))
	return image


func _create_control_image() -> Image:
	var sample_count: int = _sample_count()
	var image: Image = Image.create_empty(sample_count, sample_count, false, Image.FORMAT_RF)
	var half_size: float = float(sample_count) * 0.5
	for x: int in range(sample_count):
		for z: int in range(sample_count):
			var point: Vector2 = Vector2(float(x) + 0.5 - half_size, float(z) + 0.5 - half_size)
			var dirt_strength: float = _route_strength(point)
			var control_value: float = _packed_control_value(
					GRASS_TEXTURE_ID,
					DIRT_TEXTURE_ID,
					dirt_strength)
			image.set_pixel(x, z, Color(control_value, 0.0, 0.0, 1.0))
	return image


func _sample_count() -> int:
	return maxi(64, terrain_size_meters)


func _surrounding_height(point: Vector2) -> float:
	var broad: float = _broad_noise.get_noise_2d(point.x, point.y)
	var detail: float = _detail_noise.get_noise_2d(point.x, point.y)
	var combined: float = broad * 0.75 + detail * 0.25
	return path_height + combined * surrounding_height_variation


func _route_strength(point: Vector2) -> float:
	var path_radius: float = maxf(path_width_meters * 0.5, 0.1)
	var strength: float = _falloff_strength(_distance_to_path(point), path_radius)
	var clearing_count: int = mini(clearing_centers.size(), clearing_radii.size())
	for index: int in range(clearing_count):
		var distance: float = point.distance_to(clearing_centers[index])
		var clearing_strength: float = _falloff_strength(distance, clearing_radii[index])
		strength = maxf(strength, clearing_strength)
	return strength


func _falloff_strength(distance: float, core_radius: float) -> float:
	if distance <= core_radius:
		return 1.0
	var blend_width: float = maxf(path_edge_blend_meters, 0.001)
	if distance >= core_radius + blend_width:
		return 0.0
	var weight: float = (distance - core_radius) / blend_width
	var smooth_weight: float = weight * weight * (3.0 - 2.0 * weight)
	return 1.0 - smooth_weight


func _distance_to_path(point: Vector2) -> float:
	if path_points.size() < 2:
		return 1000000.0
	var best_distance: float = 1000000.0
	for index: int in range(path_points.size() - 1):
		var segment_distance: float = _distance_to_segment(
				point,
				path_points[index],
				path_points[index + 1])
		best_distance = minf(best_distance, segment_distance)
	return best_distance


func _distance_to_segment(point: Vector2, segment_start: Vector2, segment_end: Vector2) -> float:
	var segment: Vector2 = segment_end - segment_start
	var segment_length_squared: float = segment.length_squared()
	if segment_length_squared <= 0.0001:
		return point.distance_to(segment_start)
	var segment_t: float = clampf((point - segment_start).dot(segment) / segment_length_squared, 0.0, 1.0)
	var closest: Vector2 = segment_start + segment * segment_t
	return point.distance_to(closest)


func _packed_control_value(base_texture_id: int, overlay_texture_id: int, blend: float) -> float:
	var blend_byte: int = clampi(roundi(clampf(blend, 0.0, 1.0) * 255.0), 0, 255)
	var control_bits: int = ((base_texture_id & CONTROL_ID_MASK) << CONTROL_BASE_SHIFT) \
			| ((overlay_texture_id & CONTROL_ID_MASK) << CONTROL_OVERLAY_SHIFT) \
			| ((blend_byte & CONTROL_BLEND_MASK) << CONTROL_BLEND_SHIFT)
	_control_bytes.encode_u32(0, control_bits)
	return _control_bytes.decode_float(0)


func _create_texture_asset(
		asset_name: String,
		low_color: Color,
		high_color: Color,
		texture_size: int,
		uv_scale: float,
		noise_seed: int) -> Terrain3DTextureAsset:
	var gradient: Gradient = Gradient.new()
	gradient.set_color(0, low_color)
	gradient.set_color(1, high_color)

	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = noise_seed
	noise.frequency = 0.006

	var albedo_noise_texture: NoiseTexture2D = NoiseTexture2D.new()
	albedo_noise_texture.width = texture_size
	albedo_noise_texture.height = texture_size
	albedo_noise_texture.seamless = true
	albedo_noise_texture.noise = noise
	albedo_noise_texture.color_ramp = gradient
	await albedo_noise_texture.changed

	var albedo_image: Image = albedo_noise_texture.get_image()
	for x: int in range(albedo_image.get_width()):
		for y: int in range(albedo_image.get_height()):
			var color: Color = albedo_image.get_pixel(x, y)
			color.a = color.v
			albedo_image.set_pixel(x, y, color)
	albedo_image.generate_mipmaps()
	var albedo_texture: ImageTexture = ImageTexture.create_from_image(albedo_image)

	var normal_noise_texture: NoiseTexture2D = NoiseTexture2D.new()
	normal_noise_texture.width = texture_size
	normal_noise_texture.height = texture_size
	normal_noise_texture.as_normal_map = true
	normal_noise_texture.seamless = true
	normal_noise_texture.noise = noise
	await normal_noise_texture.changed

	var normal_image: Image = normal_noise_texture.get_image()
	for x: int in range(normal_image.get_width()):
		for y: int in range(normal_image.get_height()):
			var normal_roughness: Color = normal_image.get_pixel(x, y)
			normal_roughness.a = 0.82
			normal_image.set_pixel(x, y, normal_roughness)
	normal_image.generate_mipmaps()
	var normal_texture: ImageTexture = ImageTexture.create_from_image(normal_image)

	var texture_asset: Terrain3DTextureAsset = Terrain3DTextureAsset.new()
	texture_asset.name = asset_name
	texture_asset.albedo_texture = albedo_texture
	texture_asset.normal_texture = normal_texture
	texture_asset.uv_scale = uv_scale
	texture_asset.detiling_rotation = 0.08
	return texture_asset

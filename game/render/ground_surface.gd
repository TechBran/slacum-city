class_name GroundSurface
extends RefCounted
## Textured ground materials from the procedural page set
## (`tools/gen_textures.py`, pages `ground_*.png`).
##
## Doc 11 §2.1 gives every `ChunkView` a 128 m ground mesh with two surfaces,
## terrain and roads. This builds the materials for them: `game/shaders/
## ground.gdshader` with the page tiled at its authored metre pitch, so a road
## strip and a block face share one scale no matter what mesh they sit on. If
## the pages are missing — a clone that has not run the generator and
## `--import` — every call falls back to the flat tint it was given, and the
## renderer is exactly as it was before textures existed.
##
## The material is a ShaderMaterial rather than a StandardMaterial3D for one
## reason: doc 11 §2.9's wet-ground cheat and §2.5's overlay de-emphasis are
## both driven by project shader globals (`sc_wetness`, `sc_overlay_mode`), and
## a StandardMaterial3D cannot read one. Dry, with no overlay, the shader
## resolves to the same tinted page at the same roughness. Callers are
## unchanged: they assign the result to `mesh.material` or `material_override`.
##
## Kept out of `CityView` on purpose: buildings and ground are different
## meshes owned by different builders, and `main.gd`/`ChunkView` should be able
## to reach this without dragging the building mirror along.

const MANIFEST := "res://game/textures/generated/manifest.json"
const RENDER_DATA := "res://data/render.json"
const SHADER := "res://game/shaders/ground.gdshader"
const WATER_SHADER := "res://game/shaders/water.gdshader"

static var _pages: Dictionary = {}      # "asphalt" -> Texture2D
static var _tile_m: float = 4.0
static var _wet: Dictionary = {}        # doc 11 §2.9 wet-ground constants
static var _shader: Shader = null
static var _water_shader: Shader = null
static var _water: Dictionary = {}      # data/render.json `water_surface`
static var _loaded := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if ResourceLoader.exists(SHADER):
		_shader = load(SHADER)
	if ResourceLoader.exists(WATER_SHADER):
		_water_shader = load(WATER_SHADER)
	# doc 11 §2.9's authored wet-ground numbers, read once. Defaults mirror
	# data/render.json so a stripped clone still looks right.
	_wet = {"roughness_dry": 0.85, "roughness_wet": 0.18, "specular_dry": 0.50,
			"specular_wet": 0.85, "albedo_mult": 0.62}
	if ResourceLoader.exists(RENDER_DATA):
		var render_data: Dictionary = StarterCityLoader.read_json(RENDER_DATA)
		var weather: Dictionary = render_data.get("weather", {})
		_wet["roughness_dry"] = float(weather.get("wet_roughness_dry", _wet["roughness_dry"]))
		_wet["roughness_wet"] = float(weather.get("wet_roughness_wet", _wet["roughness_wet"]))
		_wet["specular_dry"] = float(weather.get("wet_specular_dry", _wet["specular_dry"]))
		_wet["specular_wet"] = float(weather.get("wet_specular_wet", _wet["specular_wet"]))
		_wet["albedo_mult"] = float(weather.get("wet_albedo_mult", _wet["albedo_mult"]))
		_water = render_data.get("water_surface", {})
	if not ResourceLoader.exists(MANIFEST):
		return
	var doc: Dictionary = StarterCityLoader.read_json(MANIFEST)
	_tile_m = float(doc.get("roof_tile_m", 4.0))
	for name in doc.get("grounds", {}):
		var path := String((doc["grounds"][name] as Dictionary).get("path", ""))
		if path != "" and ResourceLoader.exists(path):
			_pages[name] = load(path)


## Metres covered by one repeat of a ground page.
static func tile_m() -> float:
	_ensure_loaded()
	return _tile_m


## The §2.9 wet-ground constants this class pushes into the shader, exposed so
## tests can assert the material matches the authored data.
static func wet_constants() -> Dictionary:
	_ensure_loaded()
	return _wet.duplicate()


## `page_name` is "asphalt" or "pavement"; `world_size` is the metre extent the
## mesh's [0,1] UV spans, which is what sets the repeat count. `roughness` is
## the DRY roughness — §2.9 interpolates it toward `wet_roughness_wet` as
## sc_wetness rises.
static func material(page_name: String, world_size: Vector2, tint := Color.WHITE,
		roughness := 0.92) -> Material:
	_ensure_loaded()
	if _shader == null:
		return _fallback(tint, roughness)
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("dry_roughness", roughness)
	mat.set_shader_parameter("dry_specular", 0.30)
	mat.set_shader_parameter("wet_roughness", float(_wet["roughness_wet"]))
	mat.set_shader_parameter("wet_specular", float(_wet["specular_wet"]))
	mat.set_shader_parameter("wet_albedo_mult", float(_wet["albedo_mult"]))
	var tex: Texture2D = _pages.get(page_name)
	if tex == null:
		mat.set_shader_parameter("has_page", 0.0)
		mat.set_shader_parameter("uv_scale", Vector2.ONE)
		return mat
	mat.set_shader_parameter("has_page", 1.0)
	mat.set_shader_parameter("page", tex)
	mat.set_shader_parameter("uv_scale", Vector2(
			maxf(1.0, world_size.x / _tile_m), maxf(1.0, world_size.y / _tile_m)))
	return mat


## Doc 11 §2.1's third ground surface: animated water for the map's water
## tiles. ONE material for every water quad in the city — the wave field is
## computed in WORLD space, so adjacent 8 m tiles read as one body and the
## caller can share this material across the whole set (it is what makes 15
## planes cost one pipeline state and zero per-frame script work).
##
## Every constant is `water_surface` in data/render.json; the shader's own
## defaults are the same numbers, so a stripped clone still gets water.
## `sc_time`, `sc_night`, `sc_wetness` and `sc_overlay_mode` do the rest — no
## `_process`, no tween, and no reflection probe (§2.11 gates the one probe the
## game may own to High, and a canal is not where to spend it).
static func water() -> Material:
	_ensure_loaded()
	if _water_shader == null:
		# Pre-water clone: the flat slab main.gd used to build inline.
		return _fallback(Color(0.10, 0.20, 0.30), 0.15)
	var mat := ShaderMaterial.new()
	mat.shader = _water_shader
	_set_color(mat, "deep_color", "#12303F")
	_set_color(mat, "shallow_color", "#1E4E5C")
	_set_color(mat, "sky_color", "#6E93B4")
	for key in ["night_mult", "fresnel_power", "fresnel_gain",
			"wave_scale_a_m", "wave_scale_b_m", "wave_speed_a", "wave_speed_b",
			"wave_amp", "sparkle_gain", "sparkle_power", "rain_chop_gain",
			"page_blend"]:
		if _water.has(key):
			mat.set_shader_parameter(key, float(_water[key]))
	if _water.has("roughness"):
		mat.set_shader_parameter("base_roughness", float(_water["roughness"]))
	if _water.has("specular"):
		mat.set_shader_parameter("base_specular", float(_water["specular"]))
	for key in ["wave_dir_a", "wave_dir_b"]:
		var dir: Array = _water.get(key, [])
		if dir.size() == 2:
			mat.set_shader_parameter(key, Vector2(float(dir[0]), float(dir[1])))
	# The optional detail page. The shader is complete without it.
	var page: Texture2D = _pages.get("water")
	mat.set_shader_parameter("has_page", 0.0 if page == null else 1.0)
	if page != null:
		mat.set_shader_parameter("page", page)
		mat.set_shader_parameter("page_tile_m", _tile_m)
	return mat


static func _set_color(mat: ShaderMaterial, key: String, fallback: String) -> void:
	mat.set_shader_parameter(key, Color(String(_water.get(key, fallback))))


## No shader on this clone at all: the pre-texture StandardMaterial3D path.
static func _fallback(tint: Color, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = roughness
	mat.metallic_specular = 0.3
	return mat

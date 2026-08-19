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

static var _pages: Dictionary = {}      # "asphalt" -> Texture2D
static var _tile_m: float = 4.0
static var _wet: Dictionary = {}        # doc 11 §2.9 wet-ground constants
static var _shader: Shader = null
static var _loaded := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if ResourceLoader.exists(SHADER):
		_shader = load(SHADER)
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


## No shader on this clone at all: the pre-texture StandardMaterial3D path.
static func _fallback(tint: Color, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = roughness
	mat.metallic_specular = 0.3
	return mat

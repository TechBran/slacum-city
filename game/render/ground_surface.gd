class_name GroundSurface
extends RefCounted
## Textured ground materials from the procedural page set
## (`tools/gen_textures.py`, pages `ground_*.png`).
##
## Doc 11 §2.1 gives every `ChunkView` a 128 m ground mesh with two surfaces,
## terrain and roads. This builds the materials for them: a `StandardMaterial3D`
## with the page tiled at its authored metre pitch, so a road strip and a block
## face share one scale no matter what mesh they sit on. If the pages are
## missing — a clone that has not run the generator and `--import` — every
## call falls back to the flat tint it was given, and the renderer is exactly
## as it was before textures existed.
##
## Kept out of `CityView` on purpose: buildings and ground are different
## meshes owned by different builders, and `main.gd`/`ChunkView` should be able
## to reach this without dragging the building mirror along.

const MANIFEST := "res://game/textures/generated/manifest.json"

static var _pages: Dictionary = {}      # "asphalt" -> Texture2D
static var _tile_m: float = 4.0
static var _loaded := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
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


## `page_name` is "asphalt" or "pavement"; `world_size` is the metre extent the
## mesh's [0,1] UV spans, which is what sets the repeat count.
static func material(page_name: String, world_size: Vector2, tint := Color.WHITE,
		roughness := 0.92) -> StandardMaterial3D:
	_ensure_loaded()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = roughness
	mat.metallic_specular = 0.3
	var tex: Texture2D = _pages.get(page_name)
	if tex == null:
		return mat
	mat.albedo_texture = tex
	mat.texture_repeat = true
	mat.uv1_scale = Vector3(maxf(1.0, world_size.x / _tile_m),
			maxf(1.0, world_size.y / _tile_m), 1.0)
	return mat

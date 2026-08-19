class_name PropSurface
extends RefCounted
## Materials for the props layer — everything that is neither a building, a
## road, the water nor a vehicle: construction hoarding, crane lattice,
## scaffold tube, stockpiles and streetlight poles.
##
## The pages come from `tools/gen_textures.py` (`prop_*.png`) and are tiled in
## METRES at the manifest's `prop_tile_m`, so a 0.22 m crane leg and an 8 m lamp
## post carry the same grain and the same baked AO band pitch. `hoarding` is the
## exception and is NOT tiled: that page is one hoarding panel drawn end to end,
## and its consumers map u,v across the panel 0..1.
##
## Why a StandardMaterial3D and not a ShaderMaterial like `GroundSurface`: these
## props read no project shader global. They are dry in the rain (a crane is not
## asphalt), they carry no window grid, and doc 12 §2.5's overlay wash is a
## BUILDING and GROUND read — a hoarding that greys out with the power overlay
## would be telling the player something untrue. One less pipeline state.
##
## Every consumer already baked its colour into vertex COLOR, so
## `vertex_color_use_as_albedo` is on and the pages are authored as near-neutral
## VALUE: safety orange stays safety orange, crane yellow stays crane yellow, and
## the page only ever adds surface. A clone without the generated pages gets the
## flat vertex-coloured material that shipped before this pass, unchanged.

const MANIFEST := "res://game/textures/generated/manifest.json"

static var _pages: Dictionary = {}      # "steel" -> Texture2D
static var _tile_m: float = 2.0
static var _loaded := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not ResourceLoader.exists(MANIFEST):
		return
	var doc: Dictionary = StarterCityLoader.read_json(MANIFEST)
	_tile_m = float(doc.get("prop_tile_m", 2.0))
	for name in doc.get("props", {}):
		var path := String((doc["props"][name] as Dictionary).get("path", ""))
		if path != "" and ResourceLoader.exists(path):
			_pages[name] = load(path)


## Metres covered by one repeat of a tiled prop page. Callers bake this into
## their UVs, which is what keeps the grain physical rather than per-mesh.
static func tile_m() -> float:
	_ensure_loaded()
	return _tile_m


static func has_page(page_name: String) -> bool:
	_ensure_loaded()
	return _pages.has(page_name)


## `page_name` is "hoarding", "steel" or "stock". `tint` multiplies on top of the
## vertex colour — leave it white unless a caller wants the whole surface pulled
## one way.
static func material(page_name: String, roughness: float = 0.85,
		metallic: float = 0.0, tint := Color.WHITE) -> StandardMaterial3D:
	_ensure_loaded()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = tint
	mat.roughness = roughness
	mat.metallic = metallic
	mat.metallic_specular = 0.5
	var page: Texture2D = _pages.get(page_name)
	if page != null:
		mat.albedo_texture = page
		# The pages carry no alpha the props want — `prop_*` A is the shine mask
		# the BUILDING shader reads, and StandardMaterial3D would take it as
		# transparency and punch holes in the hoarding.
		mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	return mat

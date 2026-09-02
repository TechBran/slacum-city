class_name CityView
extends Node3D
## Bring-up view over RenderStateModel: one MultiMeshInstance3D per
## (chunk, archetype, level) bucket, meshes from the gray-box manifest,
## per-window shading via the building shader. At starter-city scale the
## whole mirror re-uploads each frame; the model's budgeted flush path is
## exercised by its own tests and takes over with the streaming pass.
##
## Doc 11 §2.5's LOD ladder is applied HERE, on top of that: the model has
## always computed per-chunk tiers (`update_chunk_tiers`, hysteresis and dwell
## included, tested) but nothing on the render side ever consumed them, so
## every chunk drew its full LOD0 bucket set to the cull distance. `refresh`
## now drives the tiers from the camera the caller already passes and swaps a
## FAR chunk's whole bucket set for ONE MultiMesh of the shared 12-triangle
## `far_unit_box` — §2.13's "FAR = 1 building draw call per chunk", finally
## true.
##
## And the MEDIUM tier is merged (doc 91 D-14). One MultiMesh per (chunk,
## ARCHETYPE), over an atlas of the levels that chunk actually holds, replaces
## the per-(chunk, archetype, LEVEL) set the benchmark city measured at 16.4
## nodes per chunk — see the block above `_atlas_for` for how one MultiMesh
## draws several meshes, and why the packed `.b` carries the level at 448.
##
## §2.11's `MM_blob` is the fourth thing this view draws: one dark contact
## decal per building, on NEAR and MEDIUM chunks, on the presets
## `data/render.json`'s `blob_shadow.enabled_presets` names — which is the tier
## whose `shadows` knob is `false` and which therefore had nothing under a
## building at all. See the block above `_read_blob`.

const TEXTURE_MANIFEST := "res://game/textures/generated/manifest.json"
const FAR_MESH_ARCHETYPE := "far_unit_box"
## Doc 11 §2.11's per-building contact shadow. See `_upload_blob`.
const BLOB_SHADER := "res://game/shaders/blob_shadow.gdshader"
## The blob buffer carries NO instance colour and NO custom data — every value
## the decal needs is a uniform or the `sc_night` global — so its stride is the
## bare TRANSFORM_3D twelve and not `INSTANCE_STRIDE`.
const BLOB_STRIDE := 12
## §2.6's five building families, in the order the FAR shader's `window_colors`
## array is indexed. The index is what `_upload_far` writes into the far
## buffer's `.a` channel.
const FAMILY_ORDER := ["residential", "commercial", "industrial", "tech", "civic"]
const CHUNK_M := 128.0
## Godot's MultiMesh buffer stride with `use_custom_data`: 12 transform floats
## then 4 custom-data floats. Mirrored from RenderStateModel.INSTANCE_STRIDE.
const INSTANCE_STRIDE := 16
## The FAR buffer's `.a` packs `family_index + 8 * chunk_overlay_state`.
##
## THE CHANNEL CHOICE, recorded. `.g` was proposed as "the damage slot the far
## tier ignores"; it is not ignored — `building_far.gdshader` reads it for the
## soot multiply AND for the damage dim on EMISSION, so writing the overlay
## there would trade a working damage read for the overlay and lose a burnt
## building's soot the moment the player opened the power overlay. `.r` is the
## emissive ramp the blackout rides across the tier swap and `.b` is the packed
## variant/stage the site shell needs. `.a` is the only channel this tier owns
## outright (§2.6 locks it to `anim_phase` for NEAR/MEDIUM; the far tier has no
## flicker), it already carries a 0..4 integer, and 8 is the smallest power of
## two clear of it — so the state rides ABOVE the family index in the same float
## and nothing else in the buffer had to move.
const FAR_OVERLAY_STRIDE := 8.0
## The two per-building overlay modes (doc 12 §2.5). `OverlayModel` owns the
## names; the model stores whichever one is live and the far shader sees the
## same pair as `sc_overlay_mode` 1 and 2.
const OVERLAY_POWER := &"power"
const OVERLAY_WATER := &"water"
## `building.gdshader`'s `power_dark_hi` / `power_weak_hi`. The far aggregate has
## to grade a chunk the same way the near shader grades a building, or a chunk
## changes verdict as it crosses the LOD boundary.
##
## The near shader ramps these with `smoothstep` and then thresholds the result;
## this takes the upper edge as a hard cut instead, which is the same answer on
## every value the ladder actually produces — `emissive_target_for` emits
## dark 0.05 (OFFLINE both ways), backup 0.22 (WARNING both ways) and
## powered ≥ 0.55 (NORMAL both ways). The two only disagree part-way through a
## blackout stutter, on a chunk that is mid-ramp for a fraction of a second.
const POWER_DARK_HI := 0.17
const POWER_WEAK_HI := 0.42
## The MEDIUM merge's level stride in the packed `.b` channel (doc 91 D-14).
##
## `448 = 16 · 28`, and `28 ≡ 0 (mod 7)`. That is the whole reason this number
## is 448 and not 512 or 1000: `variant = mod(p, 16)` and
## `stage = mod(floor(p / 16), 7)` are the two decoders `RenderStateModel`
## mirrors, and adding `448·level` moves neither of them. `overlay_of` is the
## only decoder that had to change, from a `clamp` to a `mod` — an exact
## identity on every value §2.6's packing can produce (0..447).
##
## Max packed value `447 + 448·6 = 3135`, exact in f32 with 20 bits to spare.
const PACK_LEVEL_STRIDE := 448.0
## The tallest level the gray-box authors (§2.14) — six since doc 02 §2.14's
## tower tier, and five for the archetypes that did not grow one. An atlas
## carries a SUBSET of these — whichever the chunk holds — but the level TAG is
## always the absolute level. `building.gdshader` tags vertices `level/8` in an
## 8-bit channel, so 8 is the hard ceiling; the shader's `level_build_height`
## array is sized `LEVEL_MAX + 1` and the two must move together.
const LEVEL_MAX := 6

var model: RenderStateModel
## Doc 11 §2.5 tier swapping. Off puts every chunk back on its LOD0 buckets,
## which is what the renderer did before the far tier was wired.
var lod_enabled := true
## Doc 91 D-14's bucket merge. Off restores one MultiMesh per
## (chunk, archetype, level) at MEDIUM — the pre-merge renderer, for A/B work.
var medium_merge_enabled := true
## Which LOD the merged MEDIUM atlas is cut from.
##
## **0, and §2.5's table says 1. This is a deliberate, measured departure.**
## The two were A/B-rendered at the Z2 pose on the benchmark city, with the
## merge as the only other variable (`tools/profile_frame.gd --atlas-lod=`):
##
## * LOD0 atlas — **the picture is unchanged**, and that is measured, not
##   asserted: same-config A/B captures at 1920×1080 are BIT-IDENTICAL at Z0
##   and Z1 (0 of 921,600 pixels differ) and at Z2 differ on 0.63% of pixels by
##   at most 18/255 — which is the deliberate `near_flicker = 0` and nothing
##   else. Draw calls at Z2 fall 327 → 194.
## * LOD1 atlas — draw calls fall the same way and the triangle cost is far
##   better (1.27× the un-merged tier against 3.95×), but §2.14's LOD1 rule
##   *drops decor: balcony ledges, sign bands, chamfers*, and on a mid-rise
##   commercial block those pale horizontal bands ARE what the building reads
##   as at 374–412 m. Blocks that show as banded structure at LOD0 come out as
##   flat dark boxes. That is a visible pop at the 150 m NEAR/MEDIUM boundary,
##   and worse, it dims exactly the blocks a player scans for a blackout.
##
## D-14 is a draw-call defect and the merge fixes it at either LOD, so the LOD
## that keeps the picture wins. Set this to 1 once §2.14's LOD1 authoring keeps
## a mid-rise's banding — the renderer side is ready and tested for it.
var atlas_lod := 0

var _manifest_by_key: Dictionary = {}  # "archetype:level:lod" -> manifest entry
var _bucket_nodes: Dictionary = {}  # bucket key -> MultiMeshInstance3D
var _shader: Shader
var _window_colors: Dictionary = {}
## §2.6 window brightness. `emissive.window_nits` is either a plain number (the
## old form, applied to every family) or a {family: nits} object; `_window_nits`
## holds the resolved per-family table and `_window_nits_default` the fallback.
var _window_nits: Dictionary = {}
var _window_nits_default: float = 3.2
var _day_gate: float = 0.06
## Optional `construction` block in data/render.json. Keys map 1:1 onto the
## building shader's construction uniforms and override its art defaults;
## absent keys keep the shader's. Strings are read as colours.
var _construction: Dictionary = {}
# --- procedural surface set (tools/gen_textures.py) ------------------------
var _surface_by_archetype: Dictionary = {}  # archetype -> {facade, roof}
var _surface_by_family: Dictionary = {}     # family    -> {facade, roof}
var _textures: Dictionary = {}              # "facade:brick" -> Texture2D
var _roof_tile_m: float = 4.0
var _bay_m := Vector2(3.2, 3.5)
# --- FAR tier (§2.5 / §2.6 / §2.14 LOD2) -----------------------------------
## §2.6b: the side of the reduction `_page_mean_srgb` takes a page down to.
const FAR_PAGE_PROBE := 8
## §2.6b's measured per-family albedo, in `FAMILY_ORDER`, and the flag that
## says all five resolved. Empty and false on a clone with no texture pages,
## which leaves the far shader's `far_family_mix` at 0 and its neutral pair
## standing — the same "runs untextured" contract `tex_mix` gives the near tier.
## §2.6b's A/B arm, the same shape `blob_override` has: -1 takes the measured
## palette whenever it resolved, 0 FORCES the pre-Wave-17 neutral grey back.
## `tools/profile_frame.gd --far-family=0` is its only caller — the shipped
## game has no way to ask for the old frame, because the old frame was wrong.
var far_family_override: int = -1
## §2.6b's albedo-gain sweep, negative for "leave the shader's identity".
## Set by `tools/profile_frame.gd --far-gain=G` and by nothing the player can
## reach — it is a measuring lever, not a setting.
var far_gain_override: float = -1.0
var _far_wall_albedo := PackedColorArray()
var _far_roof_albedo := PackedColorArray()
var _far_family_albedo_ready := false
var _far_shader: Shader
var _far_mesh: Mesh
var _far_nodes: Dictionary = {}     # Vector2i chunk -> MultiMeshInstance3D
var _far_nits: float = 2.4
var _far_band := Vector2(0.30, 0.78)
var _floor_height_m: float = 3.5
## "archetype:level" -> Vector3(fx·8, height_m, fz·8): the §2.14 scale the far
## box takes. Static per bucket, so it is resolved once at setup.
var _far_scale: Dictionary = {}
## archetype -> index into FAMILY_ORDER, written into the far buffer's `.a`.
var _family_index: Dictionary = {}
var _far_energy_scale: float = 0.62
var _far_cell_m: float = 6.4
var _far_bay_m: float = 3.2
var _far_mullion_duty: float = 0.72
## §2.6b (2)'s day façade relief. 0 is the flat far tier that shipped before
## Wave 17; the modulation is zero-mean at every depth, so this knob changes
## the STRUCTURE the far city shows and never its level.
var _far_relief_depth: float = 0.0
## `--far-relief=D` (tools/profile_frame.gd). Negative = take the authored row.
var far_relief_override: float = -1.0
## Tests only. `MultiMesh.buffer` round-trips through the rendering server,
## which is the dummy one headless, so the far buffer has to be readable from
## the CPU side to be asserted at all. Off in play: keeping it would double the
## far tier's memory for nothing.
var keep_far_buffers := false
var _far_buffers: Dictionary = {}   # Vector2i chunk -> PackedFloat32Array
# --- MEDIUM tier, merged (§2.5 / §2.6 bucket merge, doc 91 D-14) -----------
## "archetype:mask:lod" -> that level set as ONE ArrayMesh. Built once, on
## first use, and shared by every chunk holding the same set of levels.
var _atlas_mesh: Dictionary = {}
## archetype -> the ShaderMaterial the atlas wears. ONE per archetype for the
## whole city, not one per bucket: the merged mesh bakes the per-level window
## grid into UV2 and the per-level height into `level_build_height[]`, so
## nothing is left in the uniform set that varies by chunk or by level.
var _atlas_material: Dictionary = {}
## archetype -> the atlas's per-level `height_m`, kept for the material and for
## the tests that assert the construction clamp still has the right heights.
var _atlas_heights: Dictionary = {}
## Vector2i chunk -> {archetype: MultiMeshInstance3D}.
var _medium_nodes: Dictionary = {}
## Tests only, same reason as `keep_far_buffers`: `MultiMesh.buffer` round-trips
## through the (dummy, headless) rendering server and cannot be read back.
var keep_medium_buffers := false
var _medium_buffers: Dictionary = {}  # "cx_cy_archetype" -> PackedFloat32Array
# --- the contact-shadow decal (§2.11's MM_blob) ----------------------------
## `data/render.json` → `blob_shadow.enabled_presets`. THIS row is the building
## decal's gate and nothing else's: §2.17's street bodies read the same block's
## LOOK keys and take their on/off from the preset's `vehicle_shadows` inverted,
## which is why one block has two consumers (report 98 RR-90, and the
## `_blob_shadow` note in the file itself).
var _blob_presets: Array = []
## The whole `blob_shadow` block, kept because the material is built lazily —
## the first frame a chunk goes NEAR on a preset that wants the decal, which can
## be long after `setup`.
var _blob_cfg: Dictionary = {}
## Whether the ACTIVE preset is in that list. Re-derived from `model.preset` at
## the top of every `_upload_all`, which is what makes a live preset swap and a
## governor latched drop both work with no call from the shell: both paths go
## through `RenderStateModel.set_preset`, and this view reads the model.
var _blob_enabled := false
var _blob_preset := ""
## A/B lever, the same shape as `lod_enabled` and `medium_merge_enabled`:
## −1 obeys `enabled_presets`, 0 forces the decal off and 1 forces it on
## whatever the preset says. `tools/profile_frame.gd --blob=` drives it, so the
## two arms of the draw-call and fill A/B differ in NOTHING but this layer.
var blob_override := -1
var _blob_y_m := 0.04
var _blob_scale := 1.15
var _blob_mesh: Mesh
var _blob_material: ShaderMaterial
## ONE node for the whole city — see the block above `_read_blob` for the
## measurement that chose it over one per chunk.
var _blob_instance: MultiMeshInstance3D
## The buffer as last handed to the server, for the "uploaded only when it
## moved" compare in `_upload_blob`.
var _blob_last := PackedFloat32Array()
var _blob_uploads := 0
## Tests only, and for the same reason `keep_far_buffers` exists: the dummy
## headless server stores no instance data, so a decal's transform can only be
## asserted from the CPU side.
var keep_blob_buffers := false
var _blob_buffers: Dictionary = {}
## The last `set_overlay_palette` argument, replayed onto atlas materials as
## they are built. Empty before the shell ever pushes one.
var _overlay_paint: Array = []
## `set_overlay_palette`'s uniform names, in doc 11's packing order.
const OVERLAY_COLOR_UNIFORMS := ["overlay_normal_color", "overlay_warning_color",
		"overlay_critical_color", "overlay_offline_color"]


func setup(p_model: RenderStateModel, render_data: Dictionary) -> void:
	model = p_model
	_shader = load("res://game/shaders/building.gdshader")
	if ResourceLoader.exists("res://game/shaders/building_far.gdshader"):
		_far_shader = load("res://game/shaders/building_far.gdshader")
	var manifest: Dictionary = StarterCityLoader.read_json("res://game/meshes/generated/manifest.json")
	for entry in manifest.get("meshes", []):
		_manifest_by_key["%s:%d:%d" % [entry["archetype"], int(entry["level"]), int(entry["lod"])]] = entry
		if int(entry["lod"]) == 0:
			var idx := FAMILY_ORDER.find(String(entry.get("family", "residential")))
			_family_index[String(entry["archetype"])] = float(maxi(idx, 0))
			var foot: Array = entry.get("footprint_tiles", [1, 1])
			var aabb: Array = entry.get("aabb", [])
			var h := float(entry.get("height_m", 10.0))
			if aabb.size() >= 2:
				h = maxf(h, float(aabb[1]))
			_far_scale["%s:%d" % [entry["archetype"], int(entry["level"])]] = Vector3(
					float(foot[0]) * 8.0, maxf(h, 0.5), float(foot[1]) * 8.0)
		elif int(entry["lod"]) == 2 and String(entry["archetype"]) == FAR_MESH_ARCHETYPE:
			var path := String(entry.get("path", ""))
			if path != "" and ResourceLoader.exists(path):
				_far_mesh = load(path)
	var world: Dictionary = render_data.get("world", {})
	_floor_height_m = float(world.get("floor_height_m", 3.5))
	var emissive: Dictionary = render_data.get("emissive", {})
	_window_colors = emissive.get("window_color", {})
	_read_window_nits(emissive.get("window_nits", 3.2))
	_far_nits = float(emissive.get("window_nits_far", 2.4))
	_far_energy_scale = float(emissive.get("far_energy_scale", 0.62))
	_far_cell_m = float(emissive.get("far_cell_m", 6.4))
	_far_bay_m = float(emissive.get("far_bay_m",
			world.get("window_spacing_x_m", 3.2)))
	_far_mullion_duty = float(emissive.get("far_mullion_duty", 0.72))
	_far_relief_depth = float(emissive.get("far_relief_depth", 0.0))
	_far_band = Vector2(float(emissive.get("far_band_lo", 0.30)),
			float(emissive.get("far_band_hi", 0.78)))
	_day_gate = float(emissive.get("day_gate", 0.06))
	_construction = render_data.get("construction", {})
	_read_blob(render_data.get("blob_shadow", {}))
	_load_textures()
	_rebuild()


## `emissive.window_nits` accepts BOTH forms. A plain number is the pre-polish
## file and still means "this brightness for every family"; a {family: nits}
## object is the per-family table the commercial-blowout fix needs. Nothing
## downstream changes either way — nits scale EMISSION only, and `day_gate`
## alone decides how many cells light, so `RenderStateModel.lit_window_count`
## keeps mirroring the shader whatever is written here.
func _read_window_nits(value: Variant) -> void:
	_window_nits.clear()
	match typeof(value):
		TYPE_DICTIONARY:
			var table: Dictionary = value
			for family: Variant in table:
				var nits: Variant = table[family]
				if typeof(nits) == TYPE_FLOAT or typeof(nits) == TYPE_INT:
					_window_nits[String(family)] = float(nits)
			# No sensible single fallback in the table form; keep the doc value
			# so an unlisted family is lit rather than black.
			_window_nits_default = float(_window_nits.get("residential", 3.2))
		TYPE_INT, TYPE_FLOAT:
			_window_nits_default = float(value)
		_:
			_window_nits_default = 3.2


## §2.6 window brightness for one building family.
func window_nits_for(family: String) -> float:
	return float(_window_nits.get(family, _window_nits_default))


## Procedural facade/roof pages, doc 11 §2.14's gray-box dressed. Absent pages
## are not an error: the shader's `tex_mix` falls to 0 and the untextured
## gray-box comes back unchanged, so a clone that has not run
## `tools/gen_textures.py` + `--import` still boots.
func _load_textures() -> void:
	if not ResourceLoader.exists(TEXTURE_MANIFEST):
		push_warning("city_view: no texture manifest, running untextured")
		return
	var tex: Dictionary = StarterCityLoader.read_json(TEXTURE_MANIFEST)
	_roof_tile_m = float(tex.get("roof_tile_m", 4.0))
	var bay: Array = tex.get("bay_m", [3.2, 3.5])
	_bay_m = Vector2(float(bay[0]), float(bay[1]))
	_surface_by_archetype = tex.get("archetype_surface", {})
	_surface_by_family = tex.get("family_surface", {})
	for group in ["facades", "roofs"]:
		var pages: Dictionary = tex.get(group, {})
		var kind := "facade" if group == "facades" else "roof"
		for name in pages:
			var path := String((pages[name] as Dictionary).get("path", ""))
			if path == "" or not ResourceLoader.exists(path):
				push_warning("city_view: missing texture page %s" % path)
				continue
			_textures["%s:%s" % [kind, name]] = load(path)
	_measure_far_family_albedo()


## §2.6b — what each family's pages LOOK like once they are a few pixels wide,
## which is the colour the FAR tier has to paint to stop the boundary reading
## as a line (report 98 RR-98, doc 11 §2.6b).
##
## **Measured, not authored, and that is the point.** A hand-written far
## palette is a second copy of the art, and the version this replaced had
## drifted 5.4× on the tech family without anyone writing a wrong number —
## the pages simply moved and the far tier did not. Reading it off the page the
## near tier actually wears means `tools/gen_textures.py` can retint the whole
## city and the far tier follows on the next boot, with nothing to keep in sync.
##
## **Why an 8×8 Lanczos reduction and not the arithmetic mean.** They differ by
## under a per-cent here, but the reduction is the right QUESTION: it is the
## filtered footprint a minified page converges to, in the same sRGB space the
## GPU's own mipmap chain averages in, so what is measured is what a MEDIUM
## chunk shows at the boundary rather than what the page contains. 8×8 rather
## than 1×1 because a single-texel target makes the resampler's window the
## whole image and its edge handling starts to matter; 64 texels averaged in
## GDScript costs 64 `get_pixel` calls per page, once, at load.
func _measure_far_family_albedo() -> void:
	_far_family_albedo_ready = false
	_far_wall_albedo = PackedColorArray()
	_far_roof_albedo = PackedColorArray()
	for family: String in FAMILY_ORDER:
		var surface := _surface_for("", family)
		var facade: Texture2D = _textures.get("facade:%s" % surface.get("facade", ""))
		var roof: Texture2D = _textures.get("roof:%s" % surface.get("roof", ""))
		if facade == null or roof == null:
			return
		_far_wall_albedo.append(_page_mean_srgb(facade))
		_far_roof_albedo.append(_page_mean_srgb(roof))
	_far_family_albedo_ready = _far_wall_albedo.size() == FAMILY_ORDER.size()


## §2.6b's measured per-family WALL albedo, in `FAMILY_ORDER`. Empty on a
## checkout with no texture pages, which is the same state that leaves the far
## shader's `far_family_mix` at 0.
func far_wall_albedo() -> PackedColorArray:
	return _far_wall_albedo.duplicate()


## The same for the ROOF page each family wears. Separate because the far
## shader already splits wall from roof by normal, and because the families do
## not pair up: tech and industrial share `metal` while wearing very different
## walls, and residential and civic share `gravel`.
func far_roof_albedo() -> PackedColorArray:
	return _far_roof_albedo.duplicate()


## The mean of one page, in the space a `source_color` uniform WANTS: sRGB.
##
## **The seam, and it is `A91-D-36`'s rule one layer further on.** A
## `source_color` uniform IS decoded by the engine — measured, not assumed: the
## same 0.5 pushed into a plain `vec3` and into a `source_color` `vec3` renders
## back 0.7373 and 0.4980, and 0.4980 is sRGB(0.214), so the tagged one was
## decoded. That is the OPPOSITE of a MultiMesh instance colour (RR-91) and of
## a vertex colour (RR-95), neither of which is decoded — which is why this
## project keeps getting this seam wrong in both directions, and why every one
## of them is now written down at the write.
##
## So the value handed over here must be sRGB and must NOT be pre-decoded.
## `Image.get_pixel` on an imported page already returns the stored sRGB byte
## as a 0..1 float without decoding it, the average is taken in that space
## (which is what the GPU's own mip chain does), and the engine performs the
## one and only decode when the uniform is set. An `srgb_to_linear()` here
## decodes twice and lands the far city at a third of its brightness — which is
## exactly what this section's first draft did, and what a `far_albedo_gain` of
## 2.0 was silently compensating for until the seam was measured.
func _page_mean_srgb(tex: Texture2D) -> Color:
	var img := tex.get_image()
	if img == null:
		return Color(0.5, 0.5, 0.5)
	if img.is_compressed():
		img.decompress()
	img.resize(FAR_PAGE_PROBE, FAR_PAGE_PROBE, Image.INTERPOLATE_LANCZOS)
	var acc := Vector3.ZERO
	for y in FAR_PAGE_PROBE:
		for x in FAR_PAGE_PROBE:
			var p := img.get_pixel(x, y)
			acc += Vector3(p.r, p.g, p.b)
	acc /= float(FAR_PAGE_PROBE * FAR_PAGE_PROBE)
	return Color(acc.x, acc.y, acc.z)


## Which pages an archetype wears; falls back to its family, then to nothing.
func _surface_for(archetype: String, family: String) -> Dictionary:
	if _surface_by_archetype.has(archetype):
		return _surface_by_archetype[archetype]
	if _surface_by_family.has(family):
		return _surface_by_family[family]
	return {}


func _apply_surface(material: ShaderMaterial, archetype: String, family: String) -> void:
	var surface := _surface_for(archetype, family)
	var facade: Texture2D = _textures.get("facade:%s" % surface.get("facade", ""))
	var roof: Texture2D = _textures.get("roof:%s" % surface.get("roof", ""))
	if facade == null or roof == null:
		material.set_shader_parameter("tex_mix", 0.0)
		return
	material.set_shader_parameter("facade_tex", facade)
	material.set_shader_parameter("roof_tex", roof)
	material.set_shader_parameter("roof_tile_m", _roof_tile_m)
	material.set_shader_parameter("bay_m", _bay_m)
	material.set_shader_parameter("tex_mix", 1.0)


func _rebuild() -> void:
	for node in _bucket_nodes.values():
		(node as Node).queue_free()
	_bucket_nodes.clear()
	for node in _far_nodes.values():
		(node as Node).queue_free()
	_far_nodes.clear()
	for chunk: Vector2i in _medium_nodes:
		for node in (_medium_nodes[chunk] as Dictionary).values():
			(node as Node).queue_free()
	_medium_nodes.clear()
	if _blob_instance != null:
		_blob_instance.queue_free()
		_blob_instance = null
	_blob_last = PackedFloat32Array()
	_blob_buffers.clear()
	# The atlas MESHES and MATERIALS survive: they are keyed by archetype and
	# level set, not by chunk, so a rebuilt city reuses every one of them. The
	# blob mesh and its ONE material survive for the same reason — neither is
	# keyed by anything a rebuild moves.
	_medium_buffers.clear()
	for chunk in model._sorted_chunk_coords():
		for bucket in _sorted_buckets(chunk):
			_ensure_bucket_node(bucket)
	_upload_all()


## `RenderStateModel.buckets_of` hands back the chunk's dictionary order. Every
## far-tier write below folds the buckets into ONE shared buffer, so the order
## they are folded in decides the instance order in it — sort, or the far city
## reshuffles itself between two runs of the same frame.
func _sorted_buckets(chunk: Vector2i) -> Array:
	var out: Array = model.buckets_of(chunk)
	out.sort_custom(func(a: RenderStateModel.Bucket, b: RenderStateModel.Bucket) -> bool:
		return a.key < b.key)
	return out


func _node_key(bucket: RenderStateModel.Bucket) -> String:
	# bucket.key is (archetype, level) only — nodes must be per chunk too.
	return "%d_%d_%d" % [bucket.chunk.x, bucket.chunk.y, bucket.key]


func _ensure_bucket_node(bucket: RenderStateModel.Bucket) -> void:
	if _bucket_nodes.has(_node_key(bucket)):
		return
	var entry: Dictionary = _manifest_by_key.get(
			"%s:%d:0" % [bucket.archetype, bucket.level], {})
	if entry.is_empty():
		push_warning("no mesh for %s L%d" % [bucket.archetype, bucket.level])
		return
	var node := MultiMeshInstance3D.new()
	node.name = "MM_%s_%d_%d_%d" % [bucket.archetype, bucket.level,
			bucket.chunk.x, bucket.chunk.y]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.instance_count = maxi(bucket.capacity, 1)
	var mesh: Mesh = load(String(entry["path"]))
	var material := ShaderMaterial.new()
	material.shader = _shader
	material.set_shader_parameter("window_cols", float(entry.get("window_cols", 4)))
	material.set_shader_parameter("window_rows", float(entry.get("window_rows", 3)))
	var family := String(entry.get("family", "residential"))
	material.set_shader_parameter("window_color",
			Color(String(_window_colors.get(family, "#FFCE8A"))))
	material.set_shader_parameter("window_nits", window_nits_for(family))
	material.set_shader_parameter("day_gate", _day_gate)
	# Construction look (stage 1..6): the shader clamps geometry to
	# `stage/6 * build_height_m`, so it needs this mesh's own height.
	material.set_shader_parameter("build_height_m",
			maxf(float(entry.get("height_m", 10.0)), 0.001))
	for key in _construction:
		var value: Variant = _construction[key]
		match typeof(value):
			TYPE_STRING:
				material.set_shader_parameter(String(key), Color(String(value)))
			TYPE_INT, TYPE_FLOAT:
				material.set_shader_parameter(String(key), float(value))
	_apply_surface(material, bucket.archetype, family)
	mm.mesh = mesh
	node.multimesh = mm
	node.material_override = material
	# Instance transforms are world-space and arrive via direct buffer writes,
	# which do NOT update the auto AABB — set an explicit cull volume covering
	# the chunk (+ tallest-building headroom) or buckets vanish by view angle.
	node.custom_aabb = _chunk_aabb(bucket.chunk)
	add_child(node)
	_bucket_nodes[_node_key(bucket)] = node


func _chunk_aabb(chunk: Vector2i) -> AABB:
	return AABB(
			Vector3(chunk.x * CHUNK_M - 8.0, -2.0, chunk.y * CHUNK_M - 8.0),
			Vector3(CHUNK_M + 16.0, 260.0, CHUNK_M + 16.0))


# ---------------------------------------------- the MEDIUM tier, merged
#
# Doc 91 D-14. §2.13's arithmetic budgets 6 building buckets per MEDIUM chunk;
# `tools/profile_frame.gd` measured 16.4 on the benchmark city, because a real
# block holds five archetypes at four LEVELS and this view allocated a
# MultiMesh per (chunk, archetype, LEVEL). At Z2 that is 259 opaque calls from
# 16 chunks and the Balanced budget breaks: 352 against 320.
#
# The merge is per (chunk, ARCHETYPE) — 6.14 nodes per chunk over the whole
# bench city, and 5.94 over the 16 chunks Z2 actually draws. §2.13's model is 6,
# so this is a number arrived at rather than a target aimed for.
#
# **How one MultiMesh draws several different meshes.** It does not. It draws ONE
# mesh that is the archetype's level meshes concatenated, with each vertex
# carrying the level it came from in `COLOR.a` — the one vertex channel the
# gray-box leaves free (`MeshBuf._push` writes `Color(ao, ao, ao, 1.0)` and the
# shader reads `.rgb`). The instance says which level it is in the packed `.b`
# channel at stride 448, and the vertex stage collapses every vertex of every
# other level onto the instance origin, where its triangles have zero area and
# the rasteriser drops them before a fragment exists.
#
# **What that costs, and why the atlas is built per LEVEL SET.** The vertex
# shader runs over every level in the mesh, not just the instance's, so the
# atlas submits triangles it will never draw. Instance-weighted over the whole
# bench city, against the 100,674 building triangles the un-merged tier submits:
#
#     atlas of all five levels     578,834   5.75x
#     atlas of the levels present  397,700   3.95x   <- shipped
#     (the same, cut from LOD1)    127,856   1.27x   <- see `atlas_lod`
#
# The mask is what buys the middle row, and it comes out of the same histogram
# that motivated the merge: the 591 buckets fall into 221 (chunk, archetype)
# groups, **2.67 levels per group, not five**. The ArrayMesh is therefore keyed
# by (archetype, LEVEL MASK, lod), so a chunk holding L1 and L3 of `house`
# submits two levels' triangles rather than five. The level TAG stays absolute
# (1..5), so `level_build_height[]` and the shader's compare do not know the
# mask exists; only which levels are in the buffer moves. A mask changes when a
# building is built, upgraded or demolished, which is when the node's mesh is
# swapped — never per frame.
#
# **3.95x the triangles for 0.41x the building draw calls.** That is the trade,
# and the measurement says it is the right way round: at the Z2 pose the whole
# frame goes 100,906 -> 209,546 primitives (2.08x, diluted by the roads and the
# unchanged FAR tier) and **the GPU column does not move — 2.44 -> 2.38 ms**
# against a 13 ms Balanced budget. The triangles bought back are degenerate:
# transformed once, dropped at the rasteriser, never shaded. The draw-call
# budget, meanwhile, is the one §2.13 publishes and the one the bench city
# broke. It is still the largest cost this design carries, and the reason
# `atlas_lod = 1` is worth having once §2.14's LOD1 authoring can pay for it.
#
# **What §2.5 says, and where this obeys it.** That table reads "MEDIUM = LOD1,
# ≤ 96 tris, no shadows, per-window hash, NO FLICKER"; the bring-up view drew
# LOD0, with shadows on, at `near_flicker`'s 1.0 NEAR default. The merged node
# is a new node, so it takes `cast_shadow = OFF` and `near_flicker = 0` from the
# start — two of the three closed. The third, LOD1, is measured and deliberately
# NOT taken: see `atlas_lod`. So the merged tier's picture is the un-merged
# tier's picture, with exactly one intended difference — a lit cell 150 m+ away
# no longer takes a 25% dip on the 1.5% of cells the flicker hash picks, which
# is §2.5's own rule and is what MEDIUM was always supposed to look like.

## `mask` bit `level - 1` set for every level this atlas must carry. Cached, so
## the meshes are built once per distinct (archetype, level set, lod) in the
## city. `null` when the archetype has no mesh set at `atlas_lod` at all — then
## that archetype keeps its per-level buckets and the chunk merges the rest,
## which is still a merge.
func _atlas_for(archetype: String, mask: int) -> Mesh:
	var cache_key := "%s:%d:%d" % [archetype, mask, atlas_lod]
	if _atlas_mesh.has(cache_key):
		return _atlas_mesh[cache_key]
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uv1 := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()
	for level in range(1, LEVEL_MAX + 1):
		if (mask & (1 << (level - 1))) == 0:
			continue
		var entry: Dictionary = _manifest_by_key.get("%s:%d:%d" % [archetype, level, atlas_lod], {})
		if entry.is_empty():
			continue
		var path := String(entry.get("path", ""))
		if path == "" or not ResourceLoader.exists(path):
			continue
		var mesh: Mesh = load(path)
		if mesh == null or mesh.get_surface_count() < 1:
			continue
		var arrays: Array = mesh.surface_get_arrays(0)
		var src_v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var src_n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var src_c: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var src_uv1: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var src_uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
		var src_i: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var base := verts.size()
		verts.append_array(src_v)
		norms.append_array(src_n)
		uv1.append_array(src_uv1)
		# The window grid is a per-MESH uniform in the un-merged path
		# (`window_cols` / `window_rows`) and several meshes cannot share one. It is
		# baked into UV2 instead — `uv2 * (cols, rows)` — and the material sets
		# both uniforms to 1.0, so the shader's `floor(v_uv2 * vec2(cols, rows))`
		# lands on exactly the same cell it lands on today and §2.6's
		# `lit = step(1 - e, h)` contract is untouched.
		#
		# The SENTINELS are copied verbatim: (-1,-1) "no window grid" and
		# (-1,-2) "prop side" are read by `step`s against 0.0 and -1.5 and must
		# not be scaled — and a windowless archetype (data_center, cols = 0)
		# would have its sentinel multiplied to (0,0) and light up.
		var cols_n := float(entry.get("window_cols", 0))
		var rows_n := float(entry.get("window_rows", 0))
		for i in src_uv2.size():
			var w: Vector2 = src_uv2[i]
			uv2.append(w if w.x < 0.0 else Vector2(w.x * cols_n, w.y * rows_n))
		# `.a` is the level tag. `level / 8` survives the 8-bit vertex colour
		# channel for 1..6 (1/8 → 32/255 → ×8 = 1.004 → round 1; 6/8 → 191/255 →
		# ×8 = 5.992 → round 6), and the shader rounds, so the format Godot picks
		# for ARRAY_COLOR cannot break it. Eight is where the division stops being
		# safe and that is the ceiling LEVEL_MAX may never cross. `.rgb` is the
		# baked AO, copied untouched.
		var tag := float(level) / 8.0
		for i in src_c.size():
			var c: Color = src_c[i]
			cols.append(Color(c.r, c.g, c.b, tag))
		for i in src_i.size():
			idx.append(src_i[i] + base)
	if verts.is_empty():
		_atlas_mesh[cache_key] = null
		return null
	var arrays_out: Array = []
	arrays_out.resize(Mesh.ARRAY_MAX)
	arrays_out[Mesh.ARRAY_VERTEX] = verts
	arrays_out[Mesh.ARRAY_NORMAL] = norms
	arrays_out[Mesh.ARRAY_COLOR] = cols
	arrays_out[Mesh.ARRAY_TEX_UV] = uv1
	arrays_out[Mesh.ARRAY_TEX_UV2] = uv2
	arrays_out[Mesh.ARRAY_INDEX] = idx
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays_out)
	_atlas_mesh[cache_key] = out
	return out


## An archetype's level heights, indexed by level (0 unused) — the
## `level_build_height[]` uniform. Read from the manifest, not from whichever
## atlas happened to be built first: the material is shared across every level
## mask, so this table must be the whole ladder regardless of mask.
func atlas_heights(archetype: String) -> PackedFloat32Array:
	if _atlas_heights.has(archetype):
		return _atlas_heights[archetype]
	var heights := PackedFloat32Array()
	heights.resize(LEVEL_MAX + 1)
	for level in range(1, LEVEL_MAX + 1):
		# A level this archetype does not author (a level-6 police station) keeps
		# the placeholder height. Nothing indexes it: no bucket at that level
		# survives `_fold`, so no instance ever packs it.
		var entry: Dictionary = _manifest_by_key.get("%s:%d:%d" % [archetype, level, atlas_lod], {})
		heights[level] = maxf(float(entry.get("height_m", 10.0)), 0.001)
	_atlas_heights[archetype] = heights
	return heights


func _atlas_material_for(archetype: String) -> ShaderMaterial:
	var existing: ShaderMaterial = _atlas_material.get(archetype)
	if existing != null:
		return existing
	var entry: Dictionary = {}
	for level in range(1, LEVEL_MAX + 1):
		entry = _manifest_by_key.get("%s:%d:%d" % [archetype, level, atlas_lod], {})
		if not entry.is_empty():
			break
	var family := String(entry.get("family", "residential"))
	var material := ShaderMaterial.new()
	material.shader = _shader
	# The grid is in UV2 now, so the shader's multiply is by one.
	material.set_shader_parameter("window_cols", 1.0)
	material.set_shader_parameter("window_rows", 1.0)
	material.set_shader_parameter("window_color",
			Color(String(_window_colors.get(family, "#FFCE8A"))))
	material.set_shader_parameter("window_nits", window_nits_for(family))
	material.set_shader_parameter("day_gate", _day_gate)
	# §2.5's MEDIUM row: "per-window hash, NO flicker". The un-merged path never
	# set this and inherited the shader's NEAR default of 1.0.
	material.set_shader_parameter("near_flicker", 0.0)
	material.set_shader_parameter("level_atlas", 1.0)
	material.set_shader_parameter("level_stride", PACK_LEVEL_STRIDE)
	material.set_shader_parameter("level_build_height", atlas_heights(archetype))
	# Unused while `level_atlas` is on — the array above replaces it — but set
	# to a sane value so a mis-wired uniform cannot clamp geometry to zero.
	material.set_shader_parameter("build_height_m", 10.0)
	for key in _construction:
		var value: Variant = _construction[key]
		match typeof(value):
			TYPE_STRING:
				material.set_shader_parameter(String(key), Color(String(value)))
			TYPE_INT, TYPE_FLOAT:
				material.set_shader_parameter(String(key), float(value))
	_apply_surface(material, archetype, family)
	_paint_material(material, _overlay_paint, OVERLAY_COLOR_UNIFORMS)
	_atlas_material[archetype] = material
	return material


func _medium_node_for(chunk: Vector2i, archetype: String,
		mask: int) -> MultiMeshInstance3D:
	var mesh := _atlas_for(archetype, mask)
	if mesh == null:
		return null
	var per_chunk: Dictionary = _medium_nodes.get(chunk, {})
	var existing: MultiMeshInstance3D = per_chunk.get(archetype)
	if existing != null:
		# The chunk's level set moved (a building went up, upgraded or came
		# down): swap the atlas. Not a per-frame path — the mask is stable for
		# as long as the chunk's roster is.
		if existing.multimesh.mesh != mesh:
			existing.multimesh.mesh = mesh
		return existing
	var node := MultiMeshInstance3D.new()
	node.name = "MM_med_%s_%d_%d" % [archetype, chunk.x, chunk.y]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = 1
	mm.visible_instance_count = 0
	node.multimesh = mm
	node.material_override = _atlas_material_for(archetype)
	node.custom_aabb = _chunk_aabb(chunk)
	# §2.5: "only NEAR chunks cast shadows (cast_shadow = OFF on all MEDIUM/FAR
	# MultiMeshes)". The un-merged path left MEDIUM casting and got away with it
	# only because a MEDIUM chunk is past `directional_shadow_max_distance`.
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visible = false
	add_child(node)
	per_chunk[archetype] = node
	_medium_nodes[chunk] = per_chunk
	return node


## Fold one chunk's per-level buckets into one MultiMesh per archetype.
## Returns the set of archetypes that merged, so `_upload_all` knows which
## per-level bucket nodes to leave dark.
func _upload_medium(chunk: Vector2i) -> Dictionary:
	var merged: Dictionary = {}
	var by_archetype: Dictionary = {}
	var mask_of: Dictionary = {}
	for bucket: RenderStateModel.Bucket in _sorted_buckets(chunk):
		var arch := String(bucket.archetype)
		# Every archetype the chunk mentions is CLAIMED, even one whose buckets
		# are all empty: claiming it is what keeps its per-level nodes dark. Only
		# the levels that will actually draw go into the fold list and the mask.
		merged[arch] = true
		# An EMPTY bucket contributes no level — one the model has kept alive
		# after its last building came down must not drag that level's triangles
		# back into the atlas. Neither does a bucket outside 1..LEVEL_MAX, or a
		# level the archetype does not author (a level-6 police station): that has no
		# authored mesh at ANY tier (`_ensure_bucket_node` warns and draws
		# nothing), so folding it in would only pad the buffer with instances no
		# vertex tag can match.
		if bucket.visible_count <= 0:
			continue
		if bucket.level < 1 or bucket.level > LEVEL_MAX:
			continue
		var list: Array = by_archetype.get(arch, [])
		list.append(bucket)
		by_archetype[arch] = list
		mask_of[arch] = int(mask_of.get(arch, 0)) | (1 << (bucket.level - 1))
	var names: Array = merged.keys()
	names.sort()
	for arch: String in names:
		var mask := int(mask_of.get(arch, 0))
		var node: MultiMeshInstance3D = null
		if mask != 0:
			node = _medium_node_for(chunk, arch, mask)
		if node == null:
			# Either nothing of this archetype draws this frame, or it has no
			# authored mesh set at all. Stand any node it owns down; the claim
			# above already stopped its per-level buckets from drawing, and a
			# missing mesh set means they had nothing to draw either.
			var idle: MultiMeshInstance3D = (_medium_nodes.get(chunk, {}) as Dictionary).get(arch)
			if idle != null:
				idle.visible = false
			continue
		var buckets: Array = by_archetype[arch]
		var total := 0
		for bucket: RenderStateModel.Bucket in buckets:
			total += bucket.visible_count
		var mm := node.multimesh
		if mm.instance_count < total:
			# The model's own granularity (§2.2): grow in blocks of 32 so a chunk
			# that gains one building does not reallocate every frame.
			mm.instance_count = int(ceil(float(total) / 32.0)) * 32
		var buffer := PackedFloat32Array()
		for bucket: RenderStateModel.Bucket in buckets:
			var n := bucket.visible_count
			if n <= 0:
				continue
			var start := buffer.size()
			# One memcpy per bucket, not one float at a time: the merged buffer
			# IS the mirror, transform and custom data alike, for every channel
			# but the one below. That is what keeps a per-frame fold affordable
			# at 1,500 buildings.
			buffer.append_array(bucket.mirror.slice(0, n * INSTANCE_STRIDE))
			var add := PACK_LEVEL_STRIDE * float(bucket.level)
			for i in n:
				buffer[start + i * INSTANCE_STRIDE + 14] += add
		if keep_medium_buffers:
			_medium_buffers[_medium_key(chunk, arch)] = buffer.duplicate()
		# Sized to the ALLOCATION: `MultiMesh.buffer` must be exactly
		# `instance_count * stride` long and `resize` zero-fills the tail.
		buffer.resize(mm.instance_count * INSTANCE_STRIDE)
		mm.buffer = buffer
		mm.visible_instance_count = total
		node.visible = true
	# An archetype the chunk has stopped holding entirely keeps its node — the
	# streamer will hand it buildings again — but stops drawing.
	var per_chunk: Dictionary = _medium_nodes.get(chunk, {})
	for arch: String in per_chunk:
		if not merged.has(arch):
			(per_chunk[arch] as MultiMeshInstance3D).visible = false
	return merged


func _medium_key(chunk: Vector2i, archetype: String) -> String:
	return "%d_%d_%s" % [chunk.x, chunk.y, archetype]


## The merged instance buffer last written for (chunk, archetype), when
## `keep_medium_buffers` is on. 16 floats per instance: the bucket mirror
## verbatim, except `.b` which carries `packed + 448 · level`.
func medium_buffer(chunk: Vector2i, archetype: String) -> PackedFloat32Array:
	return _medium_buffers.get(_medium_key(chunk, archetype), PackedFloat32Array())


func _hide_medium(chunk: Vector2i) -> void:
	var per_chunk: Dictionary = _medium_nodes.get(chunk, {})
	for arch: String in per_chunk:
		(per_chunk[arch] as MultiMeshInstance3D).visible = false


## Merged MEDIUM MultiMeshes actually submitted this frame.
func medium_draw_calls() -> int:
	var n := 0
	for chunk: Vector2i in _medium_nodes:
		var per_chunk: Dictionary = _medium_nodes[chunk]
		for arch: String in per_chunk:
			if (per_chunk[arch] as MultiMeshInstance3D).visible:
				n += 1
	return n


## Tier for one chunk, resolved for RENDERING, MEDIUM half. An unknown tier
## (-1, before the first `update_chunk_tiers`) is NOT medium: it draws LOD0,
## which is what `lod_enabled = false` restores too.
func _renders_medium(chunk: Vector2i) -> bool:
	if not lod_enabled or not medium_merge_enabled:
		return false
	return model.chunk_tier(chunk) == RenderStateModel.TIER_MEDIUM


# ------------------------------------------------ the contact shadow, MM_blob
#
# Doc 11 §2.11: "one dark radial-gradient quad per building at y = 0.04,
# footprint × 1.15, alpha 0.35·(1 − sc_night·0.6). One extra draw call per
# NEAR/MEDIUM chunk, and the difference between 'buildings sit on the ground'
# and 'buildings float'."
#
# **The layer this file has been owed since the preset table was written.**
# `presets.performance.shadows` is `false` — no sun shadow, no splits — so on
# the tier the cheapest phones run, nothing under a building told the eye it was
# standing on anything. `data/render.json`'s `blob_shadow.enabled_presets` has
# named the answer for as long as the block has existed and no code read that
# row (report 98 RR-90 named it; the street-life layer took the block's LOOK
# keys and deliberately left `enabled_presets` alone, because it belongs here).
#
# **Why a DEDICATED MultiMesh and not a mode on the street fx buffer**, which is
# where the OTHER blob shadow in this renderer lives: the argument is in the
# header of `game/shaders/blob_shadow.gdshader` and it comes down to the fx
# buffer being a per-frame pool for objects that WALK, while a building decal
# moves only when a building does. The full three reasons are there.
#
# **ONE MultiMesh CITY-WIDE, not one per chunk — and §2.11's own arithmetic is
# corrected here rather than obeyed.** The doc prices this at "one extra draw
# call per NEAR/MEDIUM chunk" and its worked example spends 6 of them
# (3 NEAR + 3 MEDIUM). The per-chunk arm was BUILT first and measured, because
# that is what the doc asked for, and on the benchmark city the Performance
# preset's chunk census is not 3 + 3: it is **12 NEAR + 24 MEDIUM at Z0**, so
# the per-chunk layer cost **36 draw calls at Z0, 36 at Z1 and 16 at Z2** —
# against a 180-call budget the bench city is already over. City-wide costs
# **one**, at every pose, for ever.
#
# This is §2.1.2's road-surface ruling applied to a second layer: when a layer
# has no per-chunk state worth culling on, per-chunk buckets buy nothing and
# cost a call each. The blob buffer has even less per-chunk state than the road
# does — no material varies, no uniform varies, and the whole thing is 2
# triangles per building.
#
# **Every building in the city is in the buffer, whatever tier its chunk is**,
# and that is the second half of the decision. It makes the buffer a function of
# the ROSTER and not of the camera, so scrubbing the city across a tier boundary
# rewrites nothing and no chunk drops its shadows as it crosses one. The cost of
# including the far field is 2 triangles and a sub-pixel quad per building; the
# cost of excluding it would be a rewrite on every band crossing plus a visible
# pop at 420 m.
#
# Stride 12: no instance colour, no custom data. Every value the decal needs is
# a material uniform or the `sc_night` global, so the buffer is transforms only
# and one material serves the whole city.

func _read_blob(cfg: Dictionary) -> void:
	_blob_cfg = cfg.duplicate()
	_blob_presets = (cfg.get("enabled_presets", []) as Array).duplicate()
	_blob_y_m = float(cfg.get("y_m", _blob_y_m))
	_blob_scale = maxf(float(cfg.get("footprint_scale", _blob_scale)), 0.01)
	# `alpha` and `night_fade` reach the shader, not this script: nothing on the
	# CPU side has an opinion about them, and a uniform is one place rather than
	# one place per instance. `body_alpha` / `body_m` / `body_lift_m` are the
	# OTHER consumer's and are not read here.
	_blob_material = null
	_blob_preset = ""


## One flat unit quad in the XZ plane, `UV` running 0..1 across it — the whole
## mesh of the layer, shared by every building in the city. Authored here rather
## than in a builder because it is four vertices and because putting it in
## `StreetLifeMesh.billboard_quad`'s file would imply the two shadows share a
## shader, which is the thing the header above spends its argument denying.
func _blob_quad() -> Mesh:
	if _blob_mesh != null:
		return _blob_mesh
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, 0.0, -0.5), Vector3(0.5, 0.0, -0.5),
		Vector3(0.5, 0.0, 0.5), Vector3(-0.5, 0.0, 0.5)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0),
		Vector2(1.0, 1.0), Vector2(0.0, 1.0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_blob_mesh = mesh
	return _blob_mesh


## ONE material for the whole city. `blob_core` is derived rather than authored:
## the quad is scaled up by `footprint_scale`, so `1 / footprint_scale` puts the
## solid part of the mask exactly on the footprint and the penumbra exactly on
## the overhang. Author the scale, get the falloff.
func _blob_material_for() -> ShaderMaterial:
	if _blob_material != null:
		return _blob_material
	if not ResourceLoader.exists(BLOB_SHADER):
		return null
	var material := ShaderMaterial.new()
	material.shader = load(BLOB_SHADER)
	material.set_shader_parameter("blob_alpha", float(_blob_cfg.get("alpha", 0.35)))
	material.set_shader_parameter("night_fade",
			float(_blob_cfg.get("night_fade", 0.6)))
	material.set_shader_parameter("blob_core", 1.0 / _blob_scale)
	_blob_material = material
	return _blob_material


## Flat, and city-wide. The decal lies at `_blob_y_m` and nothing in this buffer
## is ever taller than a building's own ground plane, so the cull volume is a
## SLAB and not `_chunk_aabb`'s 260 m tower box — a world-height AABB on a layer
## that is 4 cm thick is the shape RR-83 measured the cost of. The horizontal
## extent is the model's own chunk set, grown by one chunk so a decal on the
## outermost lot cannot poke out of its own volume.
func _blob_aabb() -> AABB:
	var lo := Vector2i(0, 0)
	var hi := Vector2i(0, 0)
	var first := true
	for chunk: Vector2i in model._sorted_chunk_coords():
		if first:
			lo = chunk
			hi = chunk
			first = false
		else:
			lo = Vector2i(mini(lo.x, chunk.x), mini(lo.y, chunk.y))
			hi = Vector2i(maxi(hi.x, chunk.x), maxi(hi.y, chunk.y))
	return AABB(
			Vector3(float(lo.x - 1) * CHUNK_M, -2.0, float(lo.y - 1) * CHUNK_M),
			Vector3(float(hi.x - lo.x + 3) * CHUNK_M, 8.0,
					float(hi.y - lo.y + 3) * CHUNK_M))


func _blob_node() -> MultiMeshInstance3D:
	if _blob_instance != null:
		return _blob_instance
	var material := _blob_material_for()
	if material == null:
		return null
	var node := MultiMeshInstance3D.new()
	node.name = "MM_blob"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _blob_quad()
	mm.instance_count = 1
	mm.visible_instance_count = 0
	node.multimesh = mm
	node.material_override = material
	node.custom_aabb = _blob_aabb()
	# A shadow does not cast one, and must not be re-drawn into a split if the
	# player switches UP to a preset that has splits before this node is stood
	# down.
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Born hidden, RR-83: an empty MultiMesh under a world AABB still costs a
	# draw call, and a city before its first building is exactly that.
	node.visible = false
	add_child(node)
	_blob_instance = node
	return node


## Fold EVERY visible building in the city into the one decal buffer. Returns
## the instance count written, so the caller can gate the node on it.
##
## Axis-aligned, following `_upload_far`'s precedent and for the same reason:
## every path that feeds this model builds `Transform3D(Basis.IDENTITY, pos)`
## (`game/main.gd`, `tools/profile_frame.gd`, `game/showcase.gd` and the
## fixtures all do), so the source basis carries no rotation to preserve and
## reading it back out of the mirror would only be arithmetic that agrees with
## itself. The footprint comes from `_far_scale`, which is the manifest's own
## `footprint_tiles × 8 m` and is already resolved once at setup.
##
## **Built every frame, uploaded only when it MOVED.** The write loop is
## GDScript and the upload is a server round trip, and only the second one is
## worth avoiding: `PackedFloat32Array ==` is a native compare, so a settled
## city rebuilds 18,000 floats and hands the server nothing. That is the same
## bargain §2.10b's pad buffer strikes for the same reason — a city where
## nothing is being built uploads nothing — reached with a comparison rather
## than with a dirty flag this view has no way to be given.
func _upload_blob() -> int:
	var node := _blob_node()
	if node == null:
		return 0
	var mm := node.multimesh
	var total := 0
	for chunk: Vector2i in model._sorted_chunk_coords():
		for bucket: RenderStateModel.Bucket in _sorted_buckets(chunk):
			total += bucket.visible_count
	if total <= 0:
		mm.visible_instance_count = 0
		return 0
	if mm.instance_count < total:
		# The model's own granularity (§2.2), in blocks of 32, so a city that
		# gains one building does not reallocate.
		mm.instance_count = int(ceil(float(total) / 32.0)) * 32
	var buffer := PackedFloat32Array()
	buffer.resize(mm.instance_count * BLOB_STRIDE)
	var out := 0
	for chunk: Vector2i in model._sorted_chunk_coords():
		for bucket: RenderStateModel.Bucket in _sorted_buckets(chunk):
			var scale: Vector3 = _far_scale.get(
					"%s:%d" % [bucket.archetype, bucket.level], Vector3(8.0, 10.0, 8.0))
			var sx := scale.x * _blob_scale
			var sz := scale.z * _blob_scale
			var mirror := bucket.mirror
			for i in bucket.visible_count:
				var base := i * INSTANCE_STRIDE
				if base + INSTANCE_STRIDE > mirror.size():
					break
				buffer[out + 0] = sx
				buffer[out + 3] = mirror[base + 3]
				buffer[out + 5] = 1.0
				# The building's own ground plane plus §2.11's 4 cm. Read off the
				# instance rather than assumed zero: a lot the map raises takes
				# its buildings up with it, and a shadow buried in the terrain is
				# the defect report NIGHT-1 found under the lamp pools.
				buffer[out + 7] = mirror[base + 7] + _blob_y_m
				buffer[out + 10] = sz
				buffer[out + 11] = mirror[base + 11]
				out += BLOB_STRIDE
	if keep_blob_buffers:
		_blob_buffers["all"] = buffer.slice(0, out)
	if buffer != _blob_last:
		mm.buffer = buffer
		_blob_last = buffer
		_blob_uploads += 1
	mm.visible_instance_count = total
	return total


## The decal buffer last written, when `keep_blob_buffers` is on. 12 floats per
## instance, transforms only.
func blob_buffer() -> PackedFloat32Array:
	return _blob_buffers.get("all", PackedFloat32Array())


## How many times the decal buffer has actually reached the server. A settled
## city must not move this: it is the proof that "built every frame, uploaded
## only when it moved" is a claim and not a hope.
func blob_upload_count() -> int:
	return _blob_uploads


## Whether the ACTIVE preset draws the decal at all — `enabled_presets`.
func blob_enabled() -> bool:
	return _blob_enabled


## Contact-shadow MultiMeshes actually submitted this frame: 0 or 1, because the
## layer is one node city-wide. Kept OUT of `building_draw_calls()`, which is the
## count of building GEOMETRY calls that §2.13's table and four tests are written
## against; this is a separate line in `perf_stats` for the reason RR-83 gave —
## a budget claim that cannot be printed is a budget claim nobody re-checks.
func blob_draw_calls() -> int:
	if _blob_instance != null and _blob_instance.visible:
		return 1
	return 0


## Re-derive the gate from the model. Called at the top of every `_upload_all`,
## which is one string compare per frame and is what lets BOTH preset paths work
## with no call from the shell: the settings row and the governor's latched drop
## both go through `RenderStateModel.set_preset`, and this view reads the model
## rather than being told twice.
func _sync_blob_preset() -> void:
	var name := "%s#%d" % [model.preset if model != null else "", blob_override]
	if name == _blob_preset:
		return
	_blob_preset = name
	if blob_override >= 0:
		_blob_enabled = blob_override == 1
	else:
		_blob_enabled = _blob_presets.has(model.preset if model != null else "")
	if not _blob_enabled and _blob_instance != null:
		# Switched UP: the tier now casts real shadows, so the decal stands down
		# at once rather than on whatever frame it is next uploaded.
		_blob_instance.visible = false


# ------------------------------------------------------------- the FAR tier
#
# §2.14's LOD2: one 12-triangle unit box (x,z ∈ [-0.5,0.5], y ∈ [0,1]) for the
# entire city, scaled per instance to (fx·8, height_m, fz·8). Every building in
# a FAR chunk lands in this one MultiMesh regardless of archetype or level, so
# a chunk that costs 6–8 bucket draw calls at MEDIUM costs exactly one here.
#
# The custom-data channels are copied across UNCHANGED, which is the point: a
# chunk that crosses the boundary mid-blackout carries its exact emissive ramp,
# damage and construction stage over the swap, and the far shader reads the
# same `.r = fraction of windows lit` contract §2.6 locks.

func _far_node_for(chunk: Vector2i) -> MultiMeshInstance3D:
	var existing: MultiMeshInstance3D = _far_nodes.get(chunk)
	if existing != null:
		return existing
	if _far_shader == null or _far_mesh == null:
		return null
	var node := MultiMeshInstance3D.new()
	node.name = "MM_far_%d_%d" % [chunk.x, chunk.y]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _far_mesh
	mm.instance_count = 1
	mm.visible_instance_count = 0
	node.multimesh = mm
	var material := ShaderMaterial.new()
	material.shader = _far_shader
	material.set_shader_parameter("window_nits_far", _far_nits)
	material.set_shader_parameter("far_energy_scale", _far_energy_scale)
	material.set_shader_parameter("far_cell_m", _far_cell_m)
	material.set_shader_parameter("far_bay_m", _far_bay_m)
	material.set_shader_parameter("far_mullion_duty", _far_mullion_duty)
	material.set_shader_parameter("far_relief_depth",
			_far_relief_depth if far_relief_override < 0.0 else far_relief_override)
	material.set_shader_parameter("day_gate", _day_gate)
	material.set_shader_parameter("floor_height_m", _floor_height_m)
	material.set_shader_parameter("band_lo", _far_band.x)
	material.set_shader_parameter("band_hi", _far_band.y)
	material.set_shader_parameter("window_colors", far_window_colors())
	# §2.6b's tier-boundary fix: the far tier paints what the tier in front of
	# it paints. `far_family_mix` stays 0 — the pre-Wave-17 neutral grey —
	# unless all five families resolved to a page that could be measured.
	if _far_family_albedo_ready and far_family_override != 0:
		material.set_shader_parameter("far_wall_albedo", _far_wall_albedo)
		material.set_shader_parameter("far_roof_albedo", _far_roof_albedo)
		if far_gain_override >= 0.0:
			material.set_shader_parameter("far_albedo_gain", far_gain_override)
		material.set_shader_parameter("far_family_mix", 1.0)
	# The `.a` packing constant, pushed rather than left to the shader default,
	# so the buffer writer and its only reader cannot drift apart silently.
	material.set_shader_parameter("far_overlay_stride", FAR_OVERLAY_STRIDE)
	node.material_override = material
	node.custom_aabb = _chunk_aabb(chunk)
	# §2.5: only NEAR casts. A FAR chunk is 420 m+ out, well past
	# directional_shadow_max_distance, and would only cost splits.
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visible = false
	add_child(node)
	_far_nodes[chunk] = node
	return node


## §2.6's five family hues in `FAMILY_ORDER`, ready for the far shader's
## `window_colors[5]` uniform. Every family scaled by its own `window_nits`
## relative to residential, so the far tier inherits the SAME per-family
## brightness ladder the near tier got — the cool commercial bays are dimmer
## than the warm residential ones at 500 m for exactly the reason they are at
## 50 m, and a chunk does not change character when it crosses the boundary.
func far_window_colors() -> PackedColorArray:
	var out := PackedColorArray()
	var reference := maxf(window_nits_for("residential"), 0.001)
	for family: String in FAMILY_ORDER:
		var col := Color(String(_window_colors.get(family, "#FFCE8A")))
		var k := window_nits_for(family) / reference
		out.append(Color(col.r * k, col.g * k, col.b * k))
	return out


## Doc 12 §2.5's per-building overlay, aggregated for the FAR tier.
##
## **Why an aggregate and not the per-building state.** Every far instance
## already carries its own packed 2-bit `overlay_state` in `.b` — it is copied
## across from the near mirror untouched. Decoding it per instance would be free.
## It is not what this draws, because at 420–1200 m a building is a few pixels
## wide and a per-building wash reads as coloured noise over the far city, which
## is the same failure mode §2.6 rejected the per-window hash for. A CHUNK is
## 128 m and stays legible to the far cull distance, and "somewhere in that block
## something is offline" is the honest resolution of the data at that range.
##
## **Worst, not mean.** 0..3 IS the severity order, so `max` is the aggregate
## that cannot hide a dead building behind twenty healthy ones — the overlay
## exists to point at trouble.
##
## POWER additionally reads the emissive ladder, exactly as the near shader
## does: `RenderStateModel.emissive_target_for` writes dark 0.05 / backup 0.22 /
## powered 0.55+, so an unlit building lands OFFLINE and a weak one WARNING even
## when its own packed state is NORMAL. The thresholds are the near shader's
## `power_dark_*` / `power_weak_*` uniforms, mirrored here.
##
## Modes 1 and 2 only. In mode 0 this returns 0 and `.a` is the bare family
## index, byte for byte what it was before this pass.
func _far_overlay_state(buckets: Array) -> float:
	if model == null:
		return 0.0
	var mode := model.overlay_mode()
	if mode != OVERLAY_POWER and mode != OVERLAY_WATER:
		return 0.0
	var worst := 0.0
	for bucket: RenderStateModel.Bucket in buckets:
		var mirror := bucket.mirror
		for i in bucket.visible_count:
			var base := i * INSTANCE_STRIDE
			if base + INSTANCE_STRIDE > mirror.size():
				break
			var packed: float = mirror[base + 14]
			var state := clampf(floor(packed / float(
					RenderStateModel.PACK_OVERLAY_STRIDE)), 0.0, 3.0)
			if mode == OVERLAY_POWER:
				var e: float = mirror[base + 12]
				if e < POWER_DARK_HI:
					state = maxf(state, 3.0)
				elif e < POWER_WEAK_HI:
					state = maxf(state, 1.0)
			worst = maxf(worst, state)
			if worst >= 3.0:
				return worst
	return worst


## Fold every bucket of `chunk` into the chunk's far MultiMesh. Reads the
## bucket mirrors rather than the model's records so the far buffer carries
## exactly what the near buffer would have drawn this frame, ramps included.
## Returns the instance count written, so the caller can gate the NODE on it —
## an empty far buffer still costs a draw call (report 98 RR-83).
func _upload_far(chunk: Vector2i) -> int:
	var node := _far_node_for(chunk)
	if node == null:
		return 0
	var buckets := _sorted_buckets(chunk)
	var total := 0
	for bucket: RenderStateModel.Bucket in buckets:
		total += bucket.visible_count
	var mm := node.multimesh
	if total <= 0:
		mm.visible_instance_count = 0
		return 0
	if mm.instance_count < total:
		# Same granularity the model allocates buckets at: grow in blocks of 32
		# so a city that gains one building does not reallocate every frame.
		mm.instance_count = int(ceil(float(total) / 32.0)) * 32
	# Sized to the ALLOCATION, not to the live count: `MultiMesh.buffer` must be
	# exactly `instance_count * stride` long, and `resize` zero-fills, so the
	# padding beyond `visible_instance_count` costs one allocation and no copy.
	var buffer := PackedFloat32Array()
	buffer.resize(mm.instance_count * INSTANCE_STRIDE)
	var chunk_state := _far_overlay_state(buckets)
	var out := 0
	for bucket: RenderStateModel.Bucket in buckets:
		var scale: Vector3 = _far_scale.get(
				"%s:%d" % [bucket.archetype, bucket.level], Vector3(8.0, 10.0, 8.0))
		var family_index: float = _family_index.get(bucket.archetype, 0.0)
		var mirror := bucket.mirror
		for i in bucket.visible_count:
			var base := i * INSTANCE_STRIDE
			if base + INSTANCE_STRIDE > mirror.size():
				break
			# Axis-aligned box at the source instance's origin (mirror floats
			# 3 / 7 / 11 are the transform's translation column).
			buffer[out + 0] = scale.x
			buffer[out + 3] = mirror[base + 3]
			buffer[out + 5] = scale.y
			buffer[out + 7] = mirror[base + 7]
			buffer[out + 10] = scale.z
			buffer[out + 11] = mirror[base + 11]
			# .r emissive, .g damage, .b packed — copied byte for byte, so the
			# blackout ramp survives the tier swap.
			buffer[out + 12] = mirror[base + 12]
			buffer[out + 13] = mirror[base + 13]
			buffer[out + 14] = mirror[base + 14]
			# .a is `anim_phase` in the model's buffers and, in this one,
			# `family_index + FAR_OVERLAY_STRIDE * chunk_overlay_state` — see
			# `_far_overlay_state` and the far shader's header. Nothing reads
			# the far buffer but that shader, and there is no flicker at 500 m
			# for a phase to drive.
			buffer[out + 15] = family_index + FAR_OVERLAY_STRIDE * chunk_state
			out += INSTANCE_STRIDE
	if keep_far_buffers:
		_far_buffers[chunk] = buffer.slice(0, out)
	mm.buffer = buffer
	mm.visible_instance_count = total
	return total


## Tier for one chunk, resolved for RENDERING: an unknown tier (-1, before the
## first `update_chunk_tiers`) and every tier below FAR draw their buckets.
func _renders_far(chunk: Vector2i) -> bool:
	if not lod_enabled or _far_shader == null or _far_mesh == null:
		return false
	return model.chunk_tier(chunk) == RenderStateModel.TIER_FAR


func _renders_culled(chunk: Vector2i) -> bool:
	if not lod_enabled:
		return false
	return model.chunk_tier(chunk) == RenderStateModel.TIER_CULLED


## The far instance buffer last written for `chunk`, when `keep_far_buffers`
## is on. 16 floats per instance: 12 transform, then (.r emissive, .g damage,
## .b packed, .a FAMILY INDEX).
func far_buffer(chunk: Vector2i) -> PackedFloat32Array:
	return _far_buffers.get(chunk, PackedFloat32Array())


## How many chunks are currently drawing the shared far box. Exposed for tests
## and for the perf log — it is the number §2.13's draw-call arithmetic keys off.
func far_chunk_count() -> int:
	var n := 0
	for chunk: Vector2i in _far_nodes:
		if (_far_nodes[chunk] as MultiMeshInstance3D).visible:
			n += 1
	return n


## Building MultiMeshes actually submitted this frame — the opaque half of
## §2.13's per-chunk draw-call budget. Three kinds now: the per-level LOD0
## buckets a NEAR chunk draws, the merged per-archetype LOD1 nodes a MEDIUM
## chunk draws, and the one shared box a FAR chunk draws.
func building_draw_calls() -> int:
	var n := 0
	for key: String in _bucket_nodes:
		if (_bucket_nodes[key] as MultiMeshInstance3D).visible:
			n += 1
	return n + medium_draw_calls() + far_chunk_count()


## §2.13's adaptive governor, applied to the city layer.
##
## Only one rung of the ladder lands here — `far_cull_m` — and it lands through
## the model, because the model owns tier assignment and the view only mirrors
## it. What this method adds is IMMEDIACY: a re-upload right now, so a step
## taken because the frame is already too long pays back on the next frame
## rather than at the next tier update.
##
## `render_scale` belongs to the 3D SubViewport, `particle_ratio` to
## `WeatherFX`, `street_lights` to `StreetlightView`, and `preset` to whoever
## owns the preset switch; the shell routes each to its owner. This view
## deliberately does not reach across to any of them.
func apply_governor(knobs: Dictionary) -> void:
	if model == null:
		return
	var was := model.far_cull_m
	model.apply_governor(knobs)
	if not is_equal_approx(was, model.far_cull_m):
		_upload_all()


## The counters §7.4's PERF line reports, gathered in the one place that can see
## both the model's tiers and the nodes actually submitted.
func perf_stats() -> Dictionary:
	var census: Dictionary = model.tier_census() if model != null else {}
	var visible_chunks := int(census.get("near", 0)) + int(census.get("medium", 0)) \
			+ int(census.get("far", 0))
	var near_calls := 0
	for key: String in _bucket_nodes:
		if (_bucket_nodes[key] as MultiMeshInstance3D).visible:
			near_calls += 1
	return {
		"chunks": visible_chunks,
		"near_chunks": int(census.get("near", 0)),
		"medium_chunks": int(census.get("medium", 0)),
		"far_chunks": int(census.get("far", 0)),
		"culled_chunks": int(census.get("culled", 0)),
		"instances": model.building_count() if model != null else 0,
		"draw_calls": building_draw_calls(),
		# Split out because D-14 is about WHERE the calls come from: `bucket`
		# is the per-(archetype, level) set, `merged` the per-archetype one.
		"bucket_calls": near_calls,
		"merged_calls": medium_draw_calls(),
		"far_calls": far_chunk_count(),
		# §2.11's contact shadow, counted separately from the geometry above:
		# it is ONE call city-wide on the presets that ask for it and zero on
		# the presets that do not, and both halves of that claim have to be
		# printable (RR-83, RR-96).
		"blob_calls": blob_draw_calls(),
		"blob_enabled": _blob_enabled,
	}


func _upload_all() -> void:
	_sync_blob_preset()
	for chunk in model._sorted_chunk_coords():
		var far := _renders_far(chunk)
		var culled := _renders_culled(chunk)
		# The merge runs FIRST: it reports which archetypes it took, and the
		# per-level loop below leaves exactly those dark and skips their upload.
		var merged: Dictionary = {}
		if not (far or culled) and _renders_medium(chunk):
			merged = _upload_medium(chunk)
		else:
			_hide_medium(chunk)
		for bucket in _sorted_buckets(chunk):
			var node: MultiMeshInstance3D = _bucket_nodes.get(_node_key(bucket))
			if node == null:
				_ensure_bucket_node(bucket)
				node = _bucket_nodes.get(_node_key(bucket))
				if node == null:
					continue
			var taken: bool = merged.has(String(bucket.archetype))
			# `visible_count > 0` is the third gate, and it is report 98 RR-83's
			# corollary: a bucket is allocated when the first building of its
			# (archetype, level) lands in the chunk and is NOT freed when the
			# last one is demolished, so a redeveloped chunk carries empty
			# buckets that still submit. Cheaper than freeing them — the mirror
			# is what makes a rebuild instant — and one boolean makes the cost
			# go away without giving that up.
			node.visible = not (far or culled or taken) and bucket.visible_count > 0
			if far or culled or taken:
				# A hidden bucket is not uploaded: skipping the write is most of
				# what the far tier buys on the CPU side. The mirror is still
				# maintained by the model, so the bucket is correct the instant
				# the chunk comes back.
				continue
			var mm := node.multimesh
			if mm.instance_count * INSTANCE_STRIDE != bucket.mirror.size():
				mm.instance_count = bucket.mirror.size() / INSTANCE_STRIDE
			if bucket.mirror.size() > 0:
				mm.buffer = bucket.mirror
			mm.visible_instance_count = bucket.visible_count
		var far_node: MultiMeshInstance3D = _far_nodes.get(chunk)
		if far:
			var far_total := _upload_far(chunk)
			far_node = _far_nodes.get(chunk)
			if far_node != null:
				# `> 0`, not `true` — RR-83's corollary again. A FAR chunk whose
				# buckets are all empty (every building in it demolished, the
				# chunk not yet retired) was submitting a call for an empty
				# buffer that the culler could not drop.
				far_node.visible = far_total > 0
		elif far_node != null:
			far_node.visible = false
	# §2.11's contact decal, OUTSIDE the chunk loop because it is one node for
	# the whole city — see the block above `_read_blob`.
	if _blob_enabled:
		var blob_total := _upload_blob()
		if _blob_instance != null:
			# RR-83, once more: `> 0`, not `true`. A city whose buildings have
			# all come down leaves an allocated, empty buffer under a world AABB,
			# which is a draw call the culler cannot drop.
			_blob_instance.visible = blob_total > 0


## Doc 12 §2.5's `overlay_changed`, forwarded into the model and flushed at
## once. The flush matters: the rail writes `sc_overlay_mode` the same frame,
## and without it a PAUSED city would grey out with the previous overlay's
## states still in the instance buffer until something else made a record
## dirty. One call, and the buffer the shader reads already carries the mode
## the player just chose.
##
## `camera_pos` only orders the flush (nearest chunks first); passing
## `Vector3.ZERO` is harmless because the budget below is effectively infinite.
func set_overlay_mode(mode: StringName, camera_pos: Vector3 = Vector3.ZERO) -> void:
	if model == null:
		return
	model.set_overlay_mode(mode)
	model.flush_dirty(camera_pos, 1000000)
	_upload_all()


## The four §2.5 state colours the overlay pass tints with, resolved against the
## player's colourblind palette. `paint` is `OverlayModel.
## building_state_paint_ordered(variant)` — doc 11's packing order,
## `[{color, mix, emission}] × 4`.
##
## Until this existed the four hues were baked into `building.gdshader` as
## uniform defaults, so a deuteran player read a deuteran legend beside a city
## still tinted for trichromats. The road bands already followed the palette
## (`RoadOverlayView._build_band_paint`); this is the other half of A6, and it
## reads the same `data/ui.json.palette` table the legend is painted from.
func set_overlay_palette(paint: Array) -> void:
	if paint.size() < 4:
		return
	var names := OVERLAY_COLOR_UNIFORMS
	var materials: Array = []
	var keys: Array = _bucket_nodes.keys()
	keys.sort()
	for key: Variant in keys:
		materials.append((_bucket_nodes[key] as MultiMeshInstance3D).material_override)
	# The merged MEDIUM tier wears one material per ARCHETYPE, shared by every
	# chunk — a dozen more, not several hundred, and they need the palette for
	# the same reason: a deuteran player must not read a deuteran legend beside
	# a mid-distance block still tinted for trichromats.
	var arch_keys: Array = _atlas_material.keys()
	arch_keys.sort()
	for arch: Variant in arch_keys:
		materials.append(_atlas_material[arch])
	# Remembered, because the atlas materials are built lazily — the first time a
	# chunk goes MEDIUM, which can be long after the player picked the palette.
	_overlay_paint = paint
	for material_v: Variant in materials:
		_paint_material(material_v as ShaderMaterial, paint, names)


func _paint_material(material: ShaderMaterial, paint: Array, names: Array) -> void:
	if material == null or paint.size() < 4:
		return
	for i in 4:
		var row: Dictionary = paint[i]
		material.set_shader_parameter(String(names[i]), row.get("color", Color(1, 1, 1)))
	# NORMAL is the calm state and carries its own, lighter blend; the three
	# that mean LOOK HERE share the data blend. Both are §2.5's, restated per
	# state in `data/ui.json.overlay.building_state_paint`.
	material.set_shader_parameter("overlay_normal_blend",
			float((paint[0] as Dictionary).get("mix", 0.50)))
	material.set_shader_parameter("overlay_data_blend",
			float((paint[2] as Dictionary).get("mix", 0.88)))
	material.set_shader_parameter("overlay_state_emission",
			float((paint[2] as Dictionary).get("emission", 0.55)))


## Doc 11 §2.5b — the camera pitch the tier pass is culling against, in degrees
## below horizontal.
##
## **Read off the live `Camera3D` rather than passed in, on purpose.** The
## alternative was a fourth argument to `refresh()`, which would have made this
## feature inert in the shipped game until the shell was edited to supply it —
## and a knob that is authored and not applied is the exact defect this wave
## exists to close (report 98 RR-98). The viewport's current camera is the same
## object `camera_pos` was taken from, so nothing can disagree; the shell keeps
## its one-line call.
##
## `pitch_override` is for the harnesses (`tools/profile_frame.gd`'s
## `--pitch-cull`, the headless tests): `--headless` has no `Camera3D` at all,
## and a test that had to stand a camera up to check a distance would be
## testing Godot. A negative return means "no pitch known", which
## `RenderStateModel.set_camera_pose` reads as "leave `far_cull_m` alone".
var pitch_override: float = -1.0


func camera_pitch_deg() -> float:
	if pitch_override >= 0.0:
		return pitch_override
	if not is_inside_tree():
		return -1.0
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return -1.0
	# -Z is Godot's camera forward. Its Y component is the sine of the angle
	# below horizontal, which is the pitch §2.5 authors and `CameraState`
	# derives — taken off the basis rather than off `rotation`, so a rig that
	# builds its transform any other way still reports the truth.
	var forward := -cam.global_transform.basis.z
	return rad_to_deg(asin(clampf(-forward.y, -1.0, 1.0)))


## The render target's width/height, for §2.5b's corner reach. Negative when
## there is no viewport (headless), which the model reads as "use the authored
## `max_aspect`" and therefore as "cull nothing you are not sure of".
func viewport_aspect() -> float:
	if not is_inside_tree():
		return -1.0
	var size := get_viewport().get_visible_rect().size
	if size.y <= 0.0:
		return -1.0
	return size.x / size.y


func refresh(delta: float, hour: float, camera_pos: Vector3 = Vector3.ZERO) -> void:
	model.set_hour(hour)
	model.advance(delta)
	# advance() ramps the records; flush_dirty() is what writes them into the
	# bucket mirrors. Unbudgeted here — bring-up scale; the streaming pass
	# adopts the per-frame write budget.
	model.flush_dirty(camera_pos, 1000000)
	if lod_enabled:
		# The model owns the hysteresis and the 0.5 s dwell, so the swap below
		# inherits both: a chunk cannot flip tiers more than twice a second and
		# never inside 20 m of a band edge. That is what stops the boundary
		# popping under a normal-speed zoom.
		model.update_chunk_tiers(camera_pos, delta, camera_pitch_deg(),
				viewport_aspect())
	_upload_all()

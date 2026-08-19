class_name RoadOverlayView
extends Node3D
## The TRAFFIC overlay's geometry (doc 12 §2.5 mode 5, doc 10 §2.15).
##
## Every other overlay is a per-BUILDING read and rides the two `overlay_state`
## bits doc 11 already packs into the instance buffer (C-64). Congestion is not:
## it is a property of a road EDGE, and the thing a player needs to see is the
## road. So this is one extra MultiMesh of translucent 8 m quads floating a hand
## above the road slabs, `game/shaders/road_overlay.gdshader` on it, hidden
## unless mode 5 is the active overlay. Nothing about the road material changes,
## and a city with the overlay off costs exactly one invisible node.
##
## Deliberately NOT a second copy of the band table: `OverlayModel` owns which
## congestion index is which band and what that band looks like
## (`data/ui.json.overlay.traffic_bands`), the palette is the same one the
## legend paints with (so the colourblind variants carry), and this file only
## turns those rows into per-instance colour and custom data. The legend and the
## map cannot disagree, because there is one table.
##
## Feed it `RoadNetwork.snapshot.visible_edges` — doc 10 rebuilds that every
## game-minute and each row already carries the band name, so the common path
## does no classification at all. Tiles shared by two edges take the WORSE band:
## an intersection between a clear street and a jammed arterial is not clear.

## Per-instance channels the shader reads. COLOR is (band hue, wash alpha);
## CUSTOM is (stripe duty, pulse Hz, 0, 0).
const CUSTOM_UNUSED := 0.0

var config: UIConfig
var model: OverlayModel

var tile_m: float = 8.0

var _mesh_instance: MultiMeshInstance3D
var _material: ShaderMaterial
var _band_paint: Dictionary = {}      # StringName band -> {color, alpha, duty, hz}
## Band names in `data/ui.json` order, so `index → band` is an array read rather
## than a rebuild of five dictionaries on every game-minute repaint.
var _band_order: Array[StringName] = []
var _slot_of_tile: Dictionary = {}    # Vector2i -> int
var _tile_of_slot: Array = []         # int -> Vector2i
var _band_of_tile: Dictionary = {}    # Vector2i -> StringName
var _tile_y: float = 0.16
var _active := false


## `cfg` is the shared `UIConfig` the shell already parsed; `p_model` lets a
## test inject a fixture. `palette_variant` is the accessibility palette in
## force — the same string `ThemeBuilder` is given, so the overlay recolours
## with the rest of the UI rather than staying green in a deuteran build.
func setup(cfg: UIConfig = null, p_model: OverlayModel = null,
		p_tile_m: float = 8.0, palette_variant: String = "default") -> void:
	config = cfg if cfg != null else UIConfig.load_from_files()
	model = p_model if p_model != null else OverlayModel.new(config)
	tile_m = p_tile_m
	var opts := model.traffic_render_opts()
	_tile_y = float(opts["tile_y_m"])
	_build_band_paint(palette_variant)
	_build_node(opts)
	set_active(false)


## Settings ▸ colourblind palette changed. The band hues are the legend's, so
## the map has to follow the theme — repainting the live tiles in place, because
## the player is probably staring at them when they flip the setting.
func set_palette_variant(palette_variant: String) -> void:
	_build_band_paint(palette_variant)
	var worst: Dictionary = {}
	for i in _tile_of_slot.size():
		var tile: Vector2i = _tile_of_slot[i]
		worst[tile] = maxi(0, _band_order.find(band_of_tile(tile)))
	_paint(worst)


func _build_band_paint(palette_variant: String) -> void:
	_band_paint.clear()
	_band_order.clear()
	var palette := config.palette(palette_variant)
	for row: Dictionary in model.traffic_legend_rows():
		var band: StringName = row["band"]
		_band_order.append(band)
		var paint := model.traffic_band_row(band)
		var hex := str(palette.get(String(paint["state"]), "#FFFFFF"))
		var col := Color(hex)
		var darken := clampf(float(paint["darken"]), 0.0, 1.0)
		_band_paint[band] = {
			"color": Color(col.r * (1.0 - darken), col.g * (1.0 - darken),
					col.b * (1.0 - darken), float(paint["alpha"])),
			"duty": float(paint["stripe_duty"]),
			"hz": float(paint["pulse_hz"]),
			"index": int(paint["index"]),
		}


func _build_node(opts: Dictionary) -> void:
	if _mesh_instance != null:
		return
	var quad := PlaneMesh.new()
	quad.size = Vector2(tile_m, tile_m)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = 0
	_material = ShaderMaterial.new()
	if ResourceLoader.exists("res://game/shaders/road_overlay.gdshader"):
		_material.shader = load("res://game/shaders/road_overlay.gdshader")
	_material.set_shader_parameter("stripe_period_m", float(opts["stripe_period_m"]))
	_material.set_shader_parameter("stripe_scroll_m_s", float(opts["stripe_scroll_m_s"]))
	_material.set_shader_parameter("wash_floor", float(opts["wash_floor"]))
	# Over the opaque ground and under the UI. `depth_draw_never` in the shader
	# means the quads never write depth, so the order between them and the
	# vehicles above them is decided here and not by z-fighting.
	_material.render_priority = 5
	_mesh_instance = MultiMeshInstance3D.new()
	_mesh_instance.name = "TrafficTiles"
	_mesh_instance.multimesh = mm
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_mesh_instance)


# ---------------------------------------------------------------------------
# Visibility — the rail's `overlay_changed` is the only thing that flips this
# ---------------------------------------------------------------------------

func set_active(active: bool) -> void:
	_active = active
	if _mesh_instance != null:
		_mesh_instance.visible = active


func is_active() -> bool:
	return _active


## Convenience for the shell: one call from `overlay_changed`.
func set_overlay_mode(mode: StringName) -> void:
	set_active(mode == OverlayModel.MODE_TRAFFIC)


# ---------------------------------------------------------------------------
# Ingest — `RoadNetwork.snapshot.visible_edges`
# ---------------------------------------------------------------------------

## One rebuild per game-minute. `edges` rows need `tiles` (Array[Vector2i]) and
## either `band` (doc 10 already computed it) or `congestion` (classified here
## through the same table). Returns the number of road tiles painted.
##
## The worst band wins on a shared tile, and the whole pass is deterministic:
## the band ladder is an ordered list, so `max` over it needs no sort.
func apply_edges(edges: Array) -> int:
	var worst: Dictionary = {}      # Vector2i -> int band index
	for raw: Variant in edges:
		if not (raw is Dictionary):
			continue
		var view: Dictionary = raw
		var band := _band_of(view)
		var paint: Dictionary = _band_paint.get(band, {})
		if paint.is_empty():
			continue
		var index := int(paint["index"])
		var tiles: Variant = view.get("tiles", [])
		if not (tiles is Array):
			continue
		for tile: Variant in (tiles as Array):
			var key: Vector2i = tile if tile is Vector2i \
					else Vector2i(int((tile as Array)[0]), int((tile as Array)[1]))
			if index > int(worst.get(key, -1)):
				worst[key] = index
	return _paint(worst)


func _band_of(view: Dictionary) -> StringName:
	var named := str(view.get("band", ""))
	if named != "" and _band_paint.has(StringName(named)):
		return StringName(named)
	return model.traffic_band(float(view.get("congestion", 0.0)))


## Writes the MultiMesh. Slots are stable across calls while the tile SET is
## unchanged — which is every minute the player is not laying road — so the
## common path writes one colour and one custom-data vector per tile and never
## touches a transform.
func _paint(worst: Dictionary) -> int:
	if _mesh_instance == null:
		return 0
	var mm := _mesh_instance.multimesh
	var tiles: Array = worst.keys()
	tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x == b.x:
			return a.y < b.y
		return a.x < b.x)
	var reshaped := tiles.size() != _tile_of_slot.size()
	if not reshaped:
		for i in tiles.size():
			if _tile_of_slot[i] != tiles[i]:
				reshaped = true
				break
	if reshaped:
		_slot_of_tile.clear()
		_tile_of_slot = tiles.duplicate()
		mm.instance_count = tiles.size()
		for i in tiles.size():
			var tile: Vector2i = tiles[i]
			_slot_of_tile[tile] = i
			mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(
					float(tile.x) * tile_m + tile_m * 0.5, _tile_y,
					float(tile.y) * tile_m + tile_m * 0.5)))
		_mesh_instance.custom_aabb = _cover(tiles)
	_band_of_tile.clear()
	for i in _tile_of_slot.size():
		var tile: Vector2i = _tile_of_slot[i]
		var index := clampi(int(worst.get(tile, 0)), 0, maxi(_band_order.size() - 1, 0))
		var band: StringName = _band_order[index]
		var paint: Dictionary = _band_paint[band]
		_band_of_tile[tile] = band
		mm.set_instance_color(i, paint["color"])
		mm.set_instance_custom_data(i, Color(float(paint["duty"]), float(paint["hz"]),
				CUSTOM_UNUSED, CUSTOM_UNUSED))
	mm.visible_instance_count = _tile_of_slot.size()
	return _tile_of_slot.size()


## Instance transforms written through `set_instance_transform` do update the
## auto AABB, but the quads are one unit thin and a grazing camera angle can
## still cull the whole sheet; an explicit cover with a metre of headroom is
## cheaper than finding out on device.
func _cover(tiles: Array) -> AABB:
	if tiles.is_empty():
		return AABB(Vector3.ZERO, Vector3.ONE)
	var lo: Vector2i = tiles[0]
	var hi: Vector2i = tiles[0]
	for raw: Variant in tiles:
		var tile: Vector2i = raw
		lo = Vector2i(mini(lo.x, tile.x), mini(lo.y, tile.y))
		hi = Vector2i(maxi(hi.x, tile.x), maxi(hi.y, tile.y))
	var origin := Vector3(float(lo.x) * tile_m, _tile_y - 1.0, float(lo.y) * tile_m)
	return AABB(origin, Vector3(float(hi.x - lo.x + 1) * tile_m, 2.0,
			float(hi.y - lo.y + 1) * tile_m))


# ---------------------------------------------------------------------------
# Read side (tests, and the perf log's draw-call arithmetic)
# ---------------------------------------------------------------------------

func tile_count() -> int:
	return _tile_of_slot.size()


func band_of_tile(tile: Vector2i) -> StringName:
	return _band_of_tile.get(tile, &"")


func paint_of_band(band: StringName) -> Dictionary:
	var row: Variant = _band_paint.get(band, {})
	return (row as Dictionary).duplicate() if row is Dictionary else {}


func instance_color(tile: Vector2i) -> Color:
	if _mesh_instance == null or not _slot_of_tile.has(tile):
		return Color(0, 0, 0, 0)
	return _mesh_instance.multimesh.get_instance_color(int(_slot_of_tile[tile]))


func mesh_instance() -> MultiMeshInstance3D:
	return _mesh_instance


## One draw call while it is up, zero while it is not — the number §2.13's
## per-chunk budget cares about.
func draw_calls() -> int:
	return 1 if _active and tile_count() > 0 else 0

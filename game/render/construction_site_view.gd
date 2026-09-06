class_name ConstructionSiteView
extends Node3D
## Construction-site props: what turns an active build site from a hole in the
## block into a site — hoarding around the lot with safety-orange accents, a
## material pile or two inside it, scaffolding poles on the small lots and a
## slewing tower crane on anything tall enough to need one. Props appear with
## the placement and are gone the moment the building completes.
##
## Geometry is procedural (no asset files, nothing in the mesh manifest): boxes
## and prisms in the gray-box language of `game/meshes/generated`, with the
## repeated fence pieces on per-site MultiMeshes the way `StreetlightView` does
## its poles. Site counts are tiny (one per building under construction), so the
## moving parts are plain per-frame transform writes rather than a shader.
##
## SURFACE. Three `PropSurface` materials, one per page of
## `tools/gen_textures.py`'s props set, and no new draw calls — the hoarding,
## the posts, the structure and the stockpile were already four separate nodes:
##
##   hoarding panels -> `prop_hoarding`, ONE printed panel mapped 0..1 across
##                      each run, so the hazard band sits at a fixed height
##                      above the pavement whatever the bay length
##   posts, crane, scaffold, cable, hook -> `prop_steel`, tiled in METRES, whose
##                      half-metre baked AO bands are what give a flat-faced
##                      lattice leg depth
##   stockpiles      -> `prop_stock`, tiled in metres
##
## Every page is near-neutral VALUE and the material multiplies the VERTEX
## colour, so the tints below are still the colours: safety orange stays safety
## orange. A clone with no generated pages gets flat vertex-coloured materials
## and the view is exactly what it was before the surface pass.
##
## Integration (`main.gd` owns the wiring):
##   view.setup(render_data)                                # data/render.json
##   view.add_site(id, centre, footprint_tiles, height_m)   # on placement
##   view.set_stage(id, stage)                              # 1..6
##   view.remove_site(id)                                   # on completion
##   view.refresh(delta)                                    # every frame
## `world_pos` is the CENTRE of the lot at ground level — the same vector doc
## 11 §5's BuildingView carries, so the caller passes it straight through.
## `refresh` takes an optional night factor (0 day … 1 night, the
## `daynight.night` key the environment controller already interpolates); pass
## it and the crane beacon only blinks after dark, omit it and it blinks around
## the clock.
##
## Tuning is read from data/render.json under `construction`; every key is
## optional and the constants below are the shipping values, so the view works
## against a render.json that has never heard of it.
##
## SPACE: the gray-box massing fills its lot to within 0.05 tiles a side, and
## the building mesh is already at full size while the site is building — so
## the props own only the strip between the façade and the property line
## (`site_margin_m`, 0.40 m by default = the 0.05 t inset at an 8 m tile). The
## hoarding runs the property line, the stacks lie along the inside of it, the
## scaffold standards rise from its corners, and the crane stands OUTSIDE the
## lot at one corner with its jib reaching over. Nothing is ever placed where
## the building itself is. If a future pass grows the building with the stage,
## raise `site_margin_m` and the yard fills out on its own.

const STAGE_MIN := 1
const STAGE_MAX := 6

const DEF_TILE_M := 8.0
const DEF_FENCE_HEIGHT_M := 2.2
const DEF_FENCE_PANEL_M := 4.0
const DEF_FENCE_THICKNESS_M := 0.10
const DEF_FENCE_INSET_M := 0.0
const DEF_FENCE_POST_M := 0.20
const DEF_FENCE_ACCENT_EVERY := 3
## Free strip inside the lot line: the 0.05-tile inset the gray-box massing
## leaves on every side (8 m tile → 0.40 m).
const DEF_SITE_MARGIN_M := 0.40
const DEF_CRANE_MIN_HEIGHT_M := 10.0
const DEF_CRANE_HEAD_CLEAR_M := 6.0
## How far outside the lot corner the mast stands, on top of its own width.
const DEF_CRANE_STANDOFF_M := 0.35
const DEF_CRANE_MAST_W_M := 1.8
const DEF_CRANE_MAST_SEG_M := 4.0
const DEF_CRANE_LEG_M := 0.22
const DEF_CRANE_JIB_RATIO := 0.80
const DEF_CRANE_JIB_MIN_M := 16.0
const DEF_CRANE_JIB_MAX_M := 34.0
const DEF_CRANE_COUNTER_RATIO := 0.38
const DEF_CRANE_SLEW_DEG_S := 5.0
const DEF_HOIST_PERIOD_S := 11.0
const DEF_BEACON_HZ := 0.55
const DEF_BEACON_ENERGY := 5.0
const DEF_SCAFFOLD_HEIGHT_M := 5.2
const DEF_SCAFFOLD_OVER_M := 1.8
const DEF_SCAFFOLD_POLE_M := 0.16

## Stage 1 already has a crane standing; it climbs to full height by stage 6.
const MAST_STAGE_FLOOR := 0.55

var tile_m := DEF_TILE_M
var fence_height := DEF_FENCE_HEIGHT_M
var fence_panel := DEF_FENCE_PANEL_M
var fence_thickness := DEF_FENCE_THICKNESS_M
var fence_inset := DEF_FENCE_INSET_M
var fence_post := DEF_FENCE_POST_M
var fence_accent_every := DEF_FENCE_ACCENT_EVERY
var site_margin := DEF_SITE_MARGIN_M
var crane_min_height := DEF_CRANE_MIN_HEIGHT_M
var crane_head_clear := DEF_CRANE_HEAD_CLEAR_M
var crane_standoff := DEF_CRANE_STANDOFF_M
var crane_mast_w := DEF_CRANE_MAST_W_M
var crane_mast_seg := DEF_CRANE_MAST_SEG_M
var crane_leg := DEF_CRANE_LEG_M
var crane_jib_ratio := DEF_CRANE_JIB_RATIO
var crane_jib_min := DEF_CRANE_JIB_MIN_M
var crane_jib_max := DEF_CRANE_JIB_MAX_M
var crane_counter_ratio := DEF_CRANE_COUNTER_RATIO
var crane_slew_deg_s := DEF_CRANE_SLEW_DEG_S
var hoist_period_s := DEF_HOIST_PERIOD_S
var beacon_hz := DEF_BEACON_HZ
var beacon_energy := DEF_BEACON_ENERGY
var scaffold_height := DEF_SCAFFOLD_HEIGHT_M
var scaffold_over := DEF_SCAFFOLD_OVER_M
var scaffold_pole := DEF_SCAFFOLD_POLE_M

var fence_color := Color("#7A7F84")
var fence_accent_color := Color("#E8752A")
var post_color := Color("#4C5054")
var crane_color := Color("#D8C24A")
var crane_dark_color := Color("#3E4246")
var crane_accent_color := Color("#E8752A")
var beacon_color := Color("#FF3524")
var concrete_color := Color("#6A6E72")
var timber_color := Color("#9C8158")
var aggregate_color := Color("#6E6455")
var skip_color := Color("#3F6B57")
var scaffold_color := Color("#8C9298")

var _sites: Dictionary = {}  # int -> Site
var _time := 0.0
var _night := 1.0
## The props surface set (`tools/gen_textures.py` + `PropSurface`). Three
## materials, one per page, and every one of them is a vertex-colour material —
## the tints above are still the colour, the page is only surface. A clone with
## no generated pages gets identical flat materials and the view is exactly what
## it was before this pass.
var _material: StandardMaterial3D          # hoarding panels (printed page)
var _steel_material: StandardMaterial3D    # crane, scaffold, posts, cable, hook
var _stock_material: StandardMaterial3D    # timber, aggregate, skips
var _panel_mesh: ArrayMesh
var _post_mesh: ArrayMesh
var _cable_mesh: ArrayMesh
var _hook_mesh: ArrayMesh
var _beacon_mesh: ArrayMesh
var _configured := false


# -------------------------------------------------------------- public API

## `render_data` is data/render.json; `construction` and `world.tile_m` are the
## only sections read, and both may be absent.
func setup(render_data: Dictionary = {}) -> void:
	var cfg: Dictionary = render_data.get("construction", {})
	tile_m = _num(render_data.get("world", {}), "tile_m", DEF_TILE_M)
	fence_height = _num(cfg, "fence_height_m", DEF_FENCE_HEIGHT_M)
	fence_panel = _num(cfg, "fence_panel_m", DEF_FENCE_PANEL_M)
	fence_thickness = _num(cfg, "fence_thickness_m", DEF_FENCE_THICKNESS_M)
	fence_inset = _num(cfg, "fence_inset_m", DEF_FENCE_INSET_M)
	fence_post = _num(cfg, "fence_post_m", DEF_FENCE_POST_M)
	fence_accent_every = maxi(1, int(cfg.get("fence_accent_every", DEF_FENCE_ACCENT_EVERY)))
	site_margin = maxf(0.15, _num(cfg, "site_margin_m", DEF_SITE_MARGIN_M))
	crane_min_height = _num(cfg, "crane_min_height_m", DEF_CRANE_MIN_HEIGHT_M)
	crane_head_clear = _num(cfg, "crane_head_clear_m", DEF_CRANE_HEAD_CLEAR_M)
	crane_standoff = _num(cfg, "crane_standoff_m", DEF_CRANE_STANDOFF_M)
	crane_mast_w = _num(cfg, "crane_mast_w_m", DEF_CRANE_MAST_W_M)
	crane_mast_seg = maxf(1.0, _num(cfg, "crane_mast_seg_m", DEF_CRANE_MAST_SEG_M))
	crane_leg = _num(cfg, "crane_leg_m", DEF_CRANE_LEG_M)
	crane_jib_ratio = _num(cfg, "crane_jib_ratio", DEF_CRANE_JIB_RATIO)
	crane_jib_min = _num(cfg, "crane_jib_min_m", DEF_CRANE_JIB_MIN_M)
	crane_jib_max = _num(cfg, "crane_jib_max_m", DEF_CRANE_JIB_MAX_M)
	crane_counter_ratio = _num(cfg, "crane_counter_ratio", DEF_CRANE_COUNTER_RATIO)
	crane_slew_deg_s = _num(cfg, "crane_slew_deg_s", DEF_CRANE_SLEW_DEG_S)
	hoist_period_s = maxf(0.5, _num(cfg, "hoist_period_s", DEF_HOIST_PERIOD_S))
	beacon_hz = maxf(0.01, _num(cfg, "beacon_hz", DEF_BEACON_HZ))
	beacon_energy = _num(cfg, "beacon_energy", DEF_BEACON_ENERGY)
	scaffold_height = _num(cfg, "scaffold_height_m", DEF_SCAFFOLD_HEIGHT_M)
	scaffold_over = _num(cfg, "scaffold_over_m", DEF_SCAFFOLD_OVER_M)
	scaffold_pole = _num(cfg, "scaffold_pole_m", DEF_SCAFFOLD_POLE_M)
	fence_color = _col(cfg, "fence_color", "#7A7F84")
	fence_accent_color = _col(cfg, "fence_accent_color", "#E8752A")
	post_color = _col(cfg, "post_color", "#4C5054")
	crane_color = _col(cfg, "crane_color", "#D8C24A")
	crane_dark_color = _col(cfg, "crane_dark_color", "#3E4246")
	crane_accent_color = _col(cfg, "crane_accent_color", "#E8752A")
	beacon_color = _col(cfg, "beacon_color", "#FF3524")
	concrete_color = _col(cfg, "concrete_color", "#6A6E72")
	timber_color = _col(cfg, "timber_color", "#9C8158")
	aggregate_color = _col(cfg, "aggregate_color", "#6E6455")
	skip_color = _col(cfg, "skip_color", "#3F6B57")
	scaffold_color = _col(cfg, "scaffold_color", "#8C9298")
	_build_shared()
	_configured = true
	# Re-tune anything already standing (setup after add_site is legal).
	for site: Site in _sites.values():
		site.has_crane = site.height_m >= crane_min_height
		_build_fence(site)
		_build_structure(site)
		_build_clutter(site)
		_animate(site)


## One site's props. `world_pos` is the centre of the ground the building STANDS
## on and `footprint_tiles` is that same BUILT extent in 8 m tiles — not the lot
## (Wave 31, RR-255): a hoarding around the reservation fences ground the
## building is not on, and doc 11 §2.16a's apron already dresses that remainder.
## `height_m` is the finished
## building's height — at or above `crane_min_height_m` the site gets a tower
## crane, below it a ring of scaffolding poles.
## `gate_side` (0 = -Z, 1 = +X, 2 = +Z, 3 = -X) is the lot face that fronts the
## STREET. Optional, and omitting it keeps the hash this view has always used —
## but the two construction layers then disagree about where the site's front
## is, which is the defect §2.16 filed: the vehicle layer derives the frontage
## from the real road (`ConstructionVehicleView.frontage_side`) and stands its
## plant, its barricades and its lorry stop there, while the hoarding opened its
## gate on `hash01(id, 7) % 4` — a one-in-four chance of agreeing. Pass the
## frontage and the gate, the skip standing in it, the coned-off lane and the
## delivery all read as one site.
func add_site(id: int, world_pos: Vector3, footprint_tiles: Vector2i,
		height_m: float, gate_side: int = -1) -> void:
	_ensure_setup()
	if _sites.has(id):
		remove_site(id)
	var site := Site.new()
	site.id = id
	site.gate_side_override = gate_side if gate_side >= 0 and gate_side < 4 else -1
	site.world_pos = world_pos
	site.footprint = Vector2i(maxi(footprint_tiles.x, 1), maxi(footprint_tiles.y, 1))
	site.height_m = maxf(height_m, 0.0)
	site.stage = STAGE_MIN
	site.phase = _hash01(id, 17) * TAU
	# Per-site slew phase AND rate — two cranes in view must never march in step.
	site.slew_rate = deg_to_rad(crane_slew_deg_s) * (0.8 + 0.4 * _hash01(id, 29))
	if _hash01(id, 31) < 0.5:
		site.slew_rate = -site.slew_rate
	site.has_crane = site.height_m >= crane_min_height
	site.root = Node3D.new()
	site.root.name = "Site_%d" % id
	site.root.position = world_pos
	add_child(site.root)
	_sites[id] = site
	_build_fence(site)
	_build_structure(site)
	_build_clutter(site)
	_animate(site)


## Construction stage 1..6 (doc 11 packs the same span). The mast climbs with
## the building and the stockpiles thin out as the site is consumed.
func set_stage(id: int, stage: int) -> void:
	var site: Site = _sites.get(id)
	if site == null:
		return
	var clamped := clampi(stage, STAGE_MIN, STAGE_MAX)
	if clamped == site.stage:
		return
	site.stage = clamped
	_build_structure(site)
	_build_clutter(site)
	_animate(site)


## Turn the gate to face the street after the fact. The vehicle layer resolves a
## site's frontage against doc 10's live network, and that answer can arrive
## AFTER the hoarding went up (the route budget is two sites a frame) or move
## later (a road edit re-routes the site). Idempotent, and a no-op when the gate
## is already on that side, so the shell can call it from the signal without
## thinking about it.
func set_gate_side(id: int, side: int) -> void:
	var site: Site = _sites.get(id)
	if site == null:
		return
	var wanted := side if side >= 0 and side < 4 else -1
	if wanted == site.gate_side_override:
		return
	site.gate_side_override = wanted
	_build_fence(site)
	# The skip straddles the hoarding line IN the gate, so the yard has to move
	# with it or a bin ends up parked against a solid panel.
	_build_clutter(site)


## Which hoarding run carries the gate. The hash is the fallback, not the rule:
## it is what a caller that cannot say where the street is still gets, and it is
## what every pre-frontage call site drew.
func _gate_side(site: Site) -> int:
	if site.gate_side_override >= 0:
		return site.gate_side_override
	return int(_hash01(site.id, 7) * 4.0) % 4


## The hoarding run the gate is standing on, 0..3. Tests and the profiler read
## it; -1 for an unknown site.
func gate_side_of(id: int) -> int:
	var site: Site = _sites.get(id)
	return -1 if site == null else _gate_side(site)


## Completion (or demolition): every prop goes.
func remove_site(id: int) -> void:
	var site: Site = _sites.get(id)
	if site == null:
		return
	_sites.erase(id)
	if site.root != null:
		site.root.queue_free()


func clear() -> void:
	for id: int in _sites.keys():
		remove_site(id)


## Per-frame animation: jib slew, hoist bob, beacon pulse. `night` is doc 11's
## day/night `night` factor; pass -1 (the default) to leave it as it was.
func refresh(delta: float, night: float = -1.0) -> void:
	if night >= 0.0:
		_night = clampf(night, 0.0, 1.0)
	if _sites.is_empty():
		return
	_time += delta
	for site: Site in _sites.values():
		_animate(site)


## Day/night gate for the beacon, for callers that would rather push it than
## pass it to `refresh` every frame.
func set_night(value: float) -> void:
	_night = clampf(value, 0.0, 1.0)


func has_site(id: int) -> bool:
	return _sites.has(id)


func site_count() -> int:
	return _sites.size()


func stage_of(id: int) -> int:
	var site: Site = _sites.get(id)
	return site.stage if site != null else 0


## True when this site is showing a tower crane rather than scaffolding poles.
func has_crane(id: int) -> bool:
	var site: Site = _sites.get(id)
	return site != null and site.has_crane


# ------------------------------------------------------------ shared assets

func _ensure_setup() -> void:
	if not _configured:
		setup()


func _build_shared() -> void:
	# Hoarding is a printed panel and reads matte; galvanised steel is the one
	# thing on a site with any sheen, and it needs a little metallic to pick the
	# sky up along a crane chord; a heap of aggregate is as rough as it gets.
	_material = PropSurface.material("hoarding", 0.88, 0.0)
	_steel_material = PropSurface.material("steel", 0.62, 0.28)
	_stock_material = PropSurface.material("stock", 0.95, 0.0)
	var tile := PropSurface.tile_m()
	# A unit-length panel: instances scale it along local X to the run they
	# cover and carry the gray/orange tint as their instance colour. UV_UNIT,
	# because the hoarding page is ONE panel with its hazard band at a fixed
	# height — a tiled projection would slide the band with the run length, and
	# a 3.6 m bay and a 4.4 m bay would wear different markings.
	var panel := PropMesh.new()
	panel.uv_mode = PropMesh.UV_UNIT
	panel.add_box(Vector3(0.0, fence_height * 0.5, 0.0),
			Vector3(1.0, fence_height, fence_thickness), Color.WHITE)
	_panel_mesh = panel.to_mesh(_material)
	var post := PropMesh.new()
	post.uv_tile_m = tile
	post.add_box(Vector3(0.0, (fence_height + 0.12) * 0.5, 0.0),
			Vector3(fence_post, fence_height + 0.12, fence_post), Color.WHITE)
	_post_mesh = post.to_mesh(_steel_material)
	var cable := PropMesh.new()
	cable.uv_tile_m = tile
	cable.add_box(Vector3(0.0, -0.5, 0.0), Vector3(0.07, 1.0, 0.07), crane_dark_color)
	_cable_mesh = cable.to_mesh(_steel_material)
	var hook := PropMesh.new()
	hook.uv_tile_m = tile
	hook.add_box(Vector3.ZERO, Vector3(0.55, 0.7, 0.55), crane_dark_color)
	hook.add_box(Vector3(0.0, -0.55, 0.0), Vector3(0.22, 0.5, 0.22), crane_accent_color)
	_hook_mesh = hook.to_mesh(_steel_material)
	var beacon := PropMesh.new()
	beacon.add_box(Vector3.ZERO, Vector3(0.55, 0.55, 0.55), Color.WHITE)
	_beacon_mesh = beacon.to_mesh(null)


# ------------------------------------------------------------------- fence

## The colour a hoarding panel is written with — LINEAR, at the write (doc 91
## A91-D-36's instance half, report 98 RR-91 / RR-95). A MultiMesh instance
## colour takes no sRGB decode, and these are the same authored hexes the
## vertex seam in `PropMesh._push` decodes for the posts' and cranes' geometry.
## Decoded here rather than at `_col()` so `fence_color` stays the one authored
## sRGB source of truth for BOTH channels. Once per panel per fence build, not
## per frame. Exposed (rather than inlined) because the headless test server
## stores no instance data, so the only place a test can read the seam is here.
func fence_paint(accent: bool) -> Color:
	return (fence_accent_color if accent else fence_color).srgb_to_linear()


## The same for a post: the gate posts wear the accent orange.
func post_paint(gate: bool) -> Color:
	return (fence_accent_color if gate else post_color).srgb_to_linear()


## Hoarding around the lot: panels on one MultiMesh (tinted per instance so a
## few of them read safety orange), posts on a second, and one panel left out
## as the site gate.
func _build_fence(site: Site) -> void:
	if site.fence != null:
		site.fence.queue_free()
	if site.posts != null:
		site.posts.queue_free()
	var ring := _fence_ring(site)
	# Sides run clockwise from -Z; each is (origin, step, count, yaw).
	var runs: Array = []
	for side in 4:
		var along := ring.x if side % 2 == 0 else ring.y
		var span := along * 2.0
		var count := maxi(1, int(round(span / fence_panel)))
		var length := span / float(count)
		runs.append({"side": side, "count": count, "length": length})
	var panel_total := 0
	var post_total := 0
	for run: Dictionary in runs:
		panel_total += int(run["count"])
		post_total += int(run["count"])
	var gate_side := _gate_side(site)
	var gate_index := int(runs[gate_side]["count"]) / 2

	var panel_mm := MultiMesh.new()
	panel_mm.transform_format = MultiMesh.TRANSFORM_3D
	panel_mm.use_colors = true
	panel_mm.mesh = _panel_mesh
	panel_mm.instance_count = panel_total
	var post_mm := MultiMesh.new()
	post_mm.transform_format = MultiMesh.TRANSFORM_3D
	post_mm.use_colors = true
	post_mm.mesh = _post_mesh
	post_mm.instance_count = post_total

	var panel_i := 0
	var post_i := 0
	var accent_seed := int(_hash01(site.id, 11) * 3.0)
	for run: Dictionary in runs:
		var side := int(run["side"])
		var count := int(run["count"])
		var length := float(run["length"])
		var yaw := side * PI * 0.5
		# Outward normal of this side, and the axis the panels march along.
		var edge := Vector2(0.0, -ring.y)
		var step := Vector2(1.0, 0.0)
		match side:
			0: edge = Vector2(0.0, -ring.y); step = Vector2(1.0, 0.0)
			1: edge = Vector2(ring.x, 0.0); step = Vector2(0.0, 1.0)
			2: edge = Vector2(0.0, ring.y); step = Vector2(-1.0, 0.0)
			3: edge = Vector2(-ring.x, 0.0); step = Vector2(0.0, -1.0)
		var run_half := (ring.x if side % 2 == 0 else ring.y)
		var start := edge - step * run_half
		for i in count:
			var centre_2d := start + step * (length * (float(i) + 0.5))
			var is_gate := side == gate_side and i == gate_index and count > 1
			if is_gate:
				site.gate_pos = Vector3(centre_2d.x, 0.0, centre_2d.y)
				site.gate_yaw = yaw
				site.gate_len = length
				site.gate_out = Vector3(edge.x, 0.0, edge.y).normalized()
			if not is_gate:
				var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)) \
						.scaled_local(Vector3(length, 1.0, 1.0))
				panel_mm.set_instance_transform(panel_i, Transform3D(basis,
						Vector3(centre_2d.x, 0.0, centre_2d.y)))
				var accent := (i + accent_seed + side) % fence_accent_every == 0
				panel_mm.set_instance_color(panel_i, fence_paint(accent))
			else:
				# The gate: no panel, but keep the slot so the buffer stays put.
				panel_mm.set_instance_transform(panel_i,
						Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001),
						Vector3(centre_2d.x, -4.0, centre_2d.y)))
				panel_mm.set_instance_color(panel_i, fence_paint(false))
			panel_i += 1
			var post_2d := start + step * (length * float(i))
			var gate_post := is_gate or (side == gate_side and i == gate_index + 1)
			post_mm.set_instance_transform(post_i, Transform3D(Basis.IDENTITY,
					Vector3(post_2d.x, 0.0, post_2d.y)))
			post_mm.set_instance_color(post_i, post_paint(gate_post))
			post_i += 1

	site.fence = MultiMeshInstance3D.new()
	site.fence.name = "Hoarding"
	site.fence.multimesh = panel_mm
	site.root.add_child(site.fence)
	site.posts = MultiMeshInstance3D.new()
	site.posts.name = "Posts"
	site.posts.multimesh = post_mm
	site.root.add_child(site.posts)


# --------------------------------------------------- crane / scaffold poles

func _build_structure(site: Site) -> void:
	if site.structure != null:
		site.structure.queue_free()
		site.structure = null
	site.slew = null
	site.hoist = null
	site.cable = null
	site.hook = null
	site.beacon = null
	if site.has_crane:
		_build_crane(site)
	else:
		_build_scaffold(site)


func _stage_t(site: Site) -> float:
	return float(site.stage - STAGE_MIN) / float(STAGE_MAX - STAGE_MIN)


func _build_crane(site: Site) -> void:
	var half := _half_extent(site)
	# The head climbs with the stage, but the jib always clears the roof — the
	# building mesh is at full height from placement.
	site.mast_h = site.height_m + crane_head_clear * lerpf(MAST_STAGE_FLOOR, 1.0,
			_stage_t(site))
	site.jib_len = clampf(site.height_m * crane_jib_ratio, crane_jib_min, crane_jib_max)
	var counter_len := site.jib_len * crane_counter_ratio

	# The mast stands OUTSIDE the lot at one corner (the lot itself is the
	# building), in the gap the four tiles leave between them.
	var sx := 1.0 if _hash01(site.id, 3) < 0.5 else -1.0
	var sz := 1.0 if _hash01(site.id, 5) < 0.5 else -1.0
	var standoff := crane_mast_w * 0.5 + crane_standoff
	var base := Vector3(sx * (half.x + standoff), 0.0, sz * (half.y + standoff))

	var crane := Node3D.new()
	crane.name = "Crane"
	crane.position = base
	site.root.add_child(crane)
	site.structure = crane

	var mast := PropMesh.new()
	mast.uv_tile_m = PropSurface.tile_m()
	mast.add_box(Vector3(0.0, 0.20, 0.0),
			Vector3(crane_mast_w * 1.7, 0.40, crane_mast_w * 1.7), concrete_color)
	_lattice_mast(mast, site.mast_h)
	var mast_node := MeshInstance3D.new()
	mast_node.name = "Mast"
	mast_node.mesh = mast.to_mesh(_steel_material)
	crane.add_child(mast_node)

	site.slew = Node3D.new()
	site.slew.name = "Slew"
	site.slew.position = Vector3(0.0, site.mast_h, 0.0)
	crane.add_child(site.slew)

	var head := PropMesh.new()
	head.uv_tile_m = PropSurface.tile_m()
	var apex_y := 7.4
	var jib_y := 2.6
	# Turntable, machinery deck and cab.
	head.add_box(Vector3(0.0, 0.55, 0.0), Vector3(crane_mast_w + 0.5, 1.1,
			crane_mast_w + 0.5), crane_dark_color)
	head.add_box(Vector3(1.5, 1.9, 0.0), Vector3(1.5, 1.7, 1.5), crane_accent_color)
	# A-frame up to the apex the pendants hang from — the tower-crane silhouette.
	var apex := Vector3(0.0, apex_y, 0.0)
	var foot := crane_mast_w * 0.5
	head.add_beam(Vector3(foot, 1.1, foot), apex, 0.20, crane_color)
	head.add_beam(Vector3(-foot, 1.1, foot), apex, 0.20, crane_color)
	head.add_beam(Vector3(foot, 1.1, -foot), apex, 0.20, crane_color)
	head.add_beam(Vector3(-foot, 1.1, -foot), apex, 0.20, crane_color)
	# Jib: two bottom chords, cross ties, pendants from the apex.
	var chord := 0.62
	head.add_beam(Vector3(0.6, jib_y, chord), Vector3(site.jib_len, jib_y, chord),
			0.22, crane_color)
	head.add_beam(Vector3(0.6, jib_y, -chord), Vector3(site.jib_len, jib_y, -chord),
			0.22, crane_color)
	var ties := maxi(3, int(site.jib_len / 3.2))
	for i in ties + 1:
		var x := lerpf(1.4, site.jib_len - 0.4, float(i) / float(ties))
		var accent := i == ties
		head.add_beam(Vector3(x, jib_y, chord), Vector3(x, jib_y, -chord), 0.16,
				crane_accent_color if accent else crane_color)
	head.add_beam(apex, Vector3(site.jib_len * 0.5, jib_y + 0.5, 0.0), 0.13, crane_color)
	head.add_beam(Vector3(site.jib_len * 0.5, jib_y + 0.5, 0.0),
			Vector3(site.jib_len - 0.3, jib_y + 0.3, 0.0), 0.13, crane_color)
	head.add_beam(Vector3(site.jib_len * 0.5, jib_y + 0.5, 0.0),
			Vector3(site.jib_len * 0.5, jib_y, 0.0), 0.13, crane_color)
	# Counter-jib and its slab.
	head.add_beam(Vector3(-0.6, jib_y, chord), Vector3(-counter_len, jib_y, chord),
			0.22, crane_color)
	head.add_beam(Vector3(-0.6, jib_y, -chord), Vector3(-counter_len, jib_y, -chord),
			0.22, crane_color)
	head.add_beam(apex, Vector3(-counter_len + 0.4, jib_y + 0.4, 0.0), 0.13, crane_color)
	head.add_box(Vector3(-counter_len + 1.2, jib_y + 0.9, 0.0),
			Vector3(2.0, 2.4, 2.8), concrete_color)
	head.add_box(Vector3(-2.4, jib_y + 0.9, 0.0), Vector3(2.6, 1.4, 2.0),
			crane_dark_color)
	# Trolley on the jib, where the hoist hangs from.
	var trolley_x := site.jib_len * lerpf(0.45, 0.72, _hash01(site.id, 13))
	head.add_box(Vector3(trolley_x, jib_y - 0.35, 0.0), Vector3(1.0, 0.5, 1.3),
			crane_dark_color)
	var head_node := MeshInstance3D.new()
	head_node.name = "Jib"
	head_node.mesh = head.to_mesh(_steel_material)
	site.slew.add_child(head_node)

	site.hoist = Node3D.new()
	site.hoist.name = "Hoist"
	site.hoist.position = Vector3(trolley_x, jib_y - 0.6, 0.0)
	site.slew.add_child(site.hoist)
	site.cable = MeshInstance3D.new()
	site.cable.name = "Cable"
	site.cable.mesh = _cable_mesh
	site.cable.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	site.hoist.add_child(site.cable)
	site.hook = MeshInstance3D.new()
	site.hook.name = "Hook"
	site.hook.mesh = _hook_mesh
	site.hoist.add_child(site.hook)
	# The trolley swings over the roof, so the hoist may only pay out what is
	# clear above it — no cable through the building.
	site.hook_span = clampf(site.mast_h + jib_y - 0.6 - site.height_m - 1.4, 2.0, 14.0)

	# Aircraft-warning beacon on the apex: on the slew axis, so it stays put
	# while the jib turns under it.
	site.beacon_material = StandardMaterial3D.new()
	site.beacon_material.albedo_color = beacon_color.darkened(0.6)
	site.beacon_material.emission_enabled = true
	site.beacon_material.emission = beacon_color
	site.beacon_material.emission_energy_multiplier = 0.0
	site.beacon = MeshInstance3D.new()
	site.beacon.name = "Beacon"
	site.beacon.mesh = _beacon_mesh
	site.beacon.material_override = site.beacon_material
	site.beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	site.beacon.position = Vector3(0.0, apex_y + 0.5, 0.0)
	site.slew.add_child(site.beacon)


## Four legs, a ring per segment and alternating diagonals — enough lattice to
## read as a mast from the city camera without pretending to be a truss.
func _lattice_mast(buf: PropMesh, height: float) -> void:
	var o := crane_mast_w * 0.5 - crane_leg * 0.5
	var corners := [Vector2(o, o), Vector2(-o, o), Vector2(-o, -o), Vector2(o, -o)]
	for c: Vector2 in corners:
		buf.add_beam(Vector3(c.x, 0.0, c.y), Vector3(c.x, height, c.y), crane_leg,
				crane_color)
	var segments := maxi(1, int(ceil(height / crane_mast_seg)))
	var seg_h := height / float(segments)
	for s in range(1, segments + 1):
		var y := seg_h * float(s)
		var top := s == segments
		var ring_color := crane_accent_color if top else crane_color
		for i in 4:
			var a: Vector2 = corners[i]
			var b: Vector2 = corners[(i + 1) % 4]
			buf.add_beam(Vector3(a.x, y, a.y), Vector3(b.x, y, b.y), crane_leg * 0.7,
					ring_color)
		# Two opposite faces per segment, flipping each level.
		var y0 := y - seg_h
		var f := s % 2
		for k in 2:
			var i0: int = (f + k * 2) % 4
			var a2: Vector2 = corners[i0]
			var b2: Vector2 = corners[(i0 + 1) % 4]
			buf.add_beam(Vector3(a2.x, y0, a2.y), Vector3(b2.x, y, b2.y),
					crane_leg * 0.6, crane_color)


## Below the crane threshold (houses, low shops) the site gets a scaffold ring:
## corner poles, two rails and a plank deck. Same silhouette language, one
## storey tall.
func _build_scaffold(site: Site) -> void:
	var ring := _fence_ring(site)
	# Standards rise from the hoarding corners and the mid-points of the long
	# sides — the only ground the building itself is not standing on.
	var ext := Vector2(maxf(ring.x - 0.14, 0.6), maxf(ring.y - 0.14, 0.6))
	# Standards always project above the working lift — otherwise the building
	# (already at full height) hides the whole ring.
	var over := scaffold_over * lerpf(0.65, 1.0, _stage_t(site))
	var top := maxf(site.height_m + over, scaffold_height)
	var buf := PropMesh.new()
	buf.uv_tile_m = PropSurface.tile_m()
	var corners := [Vector2(ext.x, ext.y), Vector2(-ext.x, ext.y),
			Vector2(-ext.x, -ext.y), Vector2(ext.x, -ext.y)]
	for c: Vector2 in corners:
		buf.add_beam(Vector3(c.x, 0.0, c.y), Vector3(c.x, top, c.y), scaffold_pole,
				scaffold_color)
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		# Mid-span standard on every side long enough to want one.
		var mid := (a + b) * 0.5
		if (b - a).length() > 6.0:
			buf.add_beam(Vector3(mid.x, 0.0, mid.y), Vector3(mid.x, top, mid.y),
					scaffold_pole * 0.9, scaffold_color)
		for level in 2:
			var y := top * (0.52 if level == 0 else 0.98)
			buf.add_beam(Vector3(a.x, y, a.y), Vector3(b.x, y, b.y),
					scaffold_pole * 0.8, scaffold_color)
	# One braced bay in safety orange, and a plank deck at the upper lift.
	buf.add_beam(Vector3(ext.x, fence_height * 0.5, ext.y),
			Vector3(ext.x, top, -ext.y), scaffold_pole * 0.7, crane_accent_color)
	buf.add_box(Vector3(0.0, top - 0.10, ext.y - 0.16),
			Vector3(ext.x * 1.5, 0.09, 0.32), timber_color)
	buf.add_box(Vector3(ext.x - 0.16, top - 0.10, 0.0),
			Vector3(0.32, 0.09, ext.y * 1.5), timber_color)
	var node := MeshInstance3D.new()
	node.name = "Scaffold"
	node.mesh = buf.to_mesh(_steel_material)
	site.root.add_child(node)
	site.structure = node


# ---------------------------------------------------------------- stockpiles

## Material stacked along the inside of the hoarding — timber bundles, an
## aggregate ridge, a skip — three of them while the site is being fed, thinning
## to one as the building tops out. The strip is only `site_margin_m` deep, so
## the stacks run ALONG it (long, low, shallow) rather than sitting in a lot
## the building is already standing on. Sides and offsets are hashed off the id
## so no two sites lay their yard out the same way.
func _build_clutter(site: Site) -> void:
	if site.clutter != null:
		site.clutter.queue_free()
		site.clutter = null
	var count := 3
	if site.stage >= 5:
		count = 1
	elif site.stage >= 3:
		count = 2
	var ring := _fence_ring(site)
	var depth := maxf(site_margin - fence_thickness * 0.5 - 0.06, 0.14)
	var buf := PropMesh.new()
	buf.uv_tile_m = PropSurface.tile_m()
	# The skip stands IN the gate, straddling the hoarding line: the one prop
	# with a clear line of sight from the street, and the only spot with room
	# for it (the neighbouring massing keeps the same 0.05 t inset).
	if site.gate_len > 1.0:
		var skip_len := minf(site.gate_len * 0.62, 2.6)
		# Centred ON the line, so it reaches no further out than the free strip
		# the neighbouring lot leaves either.
		var skip_depth := minf(site_margin * 1.7, site_margin * 2.0 - 0.04)
		var skip_pos := site.gate_pos + Vector3(0.0, 0.46, 0.0)
		buf.add_box_yaw(skip_pos, Vector3(skip_len, 0.92, skip_depth),
				site.gate_yaw, skip_color)
		buf.add_box_yaw(skip_pos + Vector3(0.0, 0.50, 0.0),
				Vector3(skip_len * 0.8, 0.22, skip_depth * 0.75), site.gate_yaw,
				aggregate_color)
		count -= 1
	var first_side := int(_hash01(site.id, 41) * 4.0) % 4
	for i in count:
		var side := (first_side + i) % 4
		var horizontal := side % 2 == 0
		var run := (ring.x if horizontal else ring.y) * 2.0
		var length := clampf(run * 0.38, 1.2, 3.4)
		var t := lerpf(-0.5, 0.5, 0.2 + 0.6 * _hash01(site.id, 53 + i * 3))
		var along := t * (run - length - 0.6)
		# Inner edge of the hoarding, pushed in by half the stack's depth.
		var inner := Vector2(ring.x, ring.y) - Vector2(depth, depth) * 0.5 \
				- Vector2(fence_thickness, fence_thickness) * 0.5
		var p := Vector3.ZERO
		match side:
			0: p = Vector3(along, 0.0, -inner.y)
			1: p = Vector3(inner.x, 0.0, along)
			2: p = Vector3(along, 0.0, inner.y)
			_: p = Vector3(-inner.x, 0.0, along)
		var size := Vector3(length, 0.0, depth) if horizontal \
				else Vector3(depth, 0.0, length)
		match i % 3:
			0:
				# Banded timber / rebar bundles, two courses.
				buf.add_box(p + Vector3(0.0, 0.16, 0.0),
						Vector3(size.x, 0.32, size.z), timber_color)
				buf.add_box(p + Vector3(0.0, 0.42, 0.0),
						Vector3(size.x * 0.7, 0.20, size.z * 0.8),
						timber_color.darkened(0.18))
			1:
				# Aggregate ridge.
				buf.add_pyramid(p, Vector2(size.x, size.z), depth * 1.2,
						aggregate_color)
			_:
				# Skip.
				buf.add_box(p + Vector3(0.0, 0.30, 0.0),
						Vector3(size.x * 0.75, 0.60, size.z), skip_color)
	if buf.is_empty():
		return
	var node := MeshInstance3D.new()
	node.name = "Stockpile"
	node.mesh = buf.to_mesh(_stock_material)
	site.root.add_child(node)
	site.clutter = node


# ---------------------------------------------------------------- animation

func _animate(site: Site) -> void:
	if site.slew == null:
		return
	var angle := site.phase + _time * site.slew_rate
	site.slew.transform = Transform3D(Basis.from_euler(Vector3(0.0, angle, 0.0)),
			site.slew.position)
	if site.hoist != null and site.cable != null and site.hook != null:
		var bob := 0.5 + 0.5 * sin(_time * TAU / hoist_period_s + site.phase * 1.7)
		var drop := site.hook_span * lerpf(0.25, 1.0, bob)
		site.cable.scale = Vector3(1.0, drop, 1.0)
		site.hook.position = Vector3(0.0, -drop - 0.35, 0.0)
	if site.beacon_material != null:
		# Short bright flash, long dark gap — an obstruction light, not a lamp.
		var cycle := fposmod(_time * beacon_hz + site.phase / TAU, 1.0)
		var pulse := 0.0
		if cycle < 0.22:
			pulse = sin(cycle / 0.22 * PI)
		site.beacon_material.emission_energy_multiplier = \
				pulse * beacon_energy * _night
		site.beacon_material.albedo_color = beacon_color.darkened(0.6 - 0.5 * pulse)


# ------------------------------------------------------------------ helpers

func _half_extent(site: Site) -> Vector2:
	return Vector2(float(site.footprint.x) * tile_m * 0.5,
			float(site.footprint.y) * tile_m * 0.5)


## Half-extent of the hoarding line — the property line by default.
func _fence_ring(site: Site) -> Vector2:
	var half := _half_extent(site)
	return Vector2(maxf(half.x - fence_inset, 0.5), maxf(half.y - fence_inset, 0.5))


static func _num(cfg: Dictionary, key: String, fallback: float) -> float:
	return float(cfg.get(key, fallback))


static func _col(cfg: Dictionary, key: String, fallback: String) -> Color:
	var hex := String(cfg.get(key, fallback))
	return Color(hex) if Color.html_is_valid(hex) else Color(fallback)


## Deterministic per-site jitter — same site, same yard, every run.
static func _hash01(id: int, salt: int) -> float:
	var h: int = absi((id * 73856093) ^ (salt * 19349663)) % 100003
	return float(h) / 100003.0


# --------------------------------------------------------------------- Site

class Site extends RefCounted:
	var id := 0
	var world_pos := Vector3.ZERO
	var footprint := Vector2i.ONE
	var height_m := 0.0
	var stage := 1
	var phase := 0.0
	var slew_rate := 0.0
	var has_crane := false
	## Gate opening in the hoarding, in site-local space — the one place a yard
	## prop is visible from outside AND has room to stand.
	var gate_pos := Vector3.ZERO
	var gate_yaw := 0.0
	var gate_len := 2.0
	var gate_out := Vector3.FORWARD
	## Which of the four hoarding runs carries the gate: 0 = -Z, 1 = +X,
	## 2 = +Z, 3 = -X. -1 means "nobody said", and the hash picks (see
	## `_gate_side`).
	var gate_side_override := -1
	var mast_h := 0.0
	var jib_len := 0.0
	var hook_span := 6.0
	var root: Node3D
	var fence: MultiMeshInstance3D
	var posts: MultiMeshInstance3D
	var structure: Node3D
	var clutter: MeshInstance3D
	var slew: Node3D
	var hoist: Node3D
	var cable: MeshInstance3D
	var hook: MeshInstance3D
	var beacon: MeshInstance3D
	var beacon_material: StandardMaterial3D


# ----------------------------------------------------------------- PropMesh

## Tiny procedural mesh builder: boxes, beams between two points and a prism,
## with the colour baked per vertex so a whole prop is one surface and one
## material. Winding matches `tools/gen_graybox.gd` — Godot's front faces are
## CLOCKWISE, so each triangle is emitted with its geometric cross product
## pointing AGAINST the outward normal.
##
## UV. Two modes, because the props want two different things from
## `tools/gen_textures.py`'s prop pages:
##
## * `UV_TILED` (the default) projects the vertex position onto whichever axis
##   pair its face is most perpendicular to and divides by `uv_tile_m` —
##   metres, not mesh fractions. That is what lets one steel page serve a
##   0.22 m crane leg, a 0.16 m scaffold standard and a 4.6 m ladder with the
##   same grain and the same baked AO band pitch, with no per-primitive UV
##   authoring anywhere.
## * `UV_UNIT` maps each face across its own bounding box, v flipped so 0 is the
##   TOP. The hoarding panel needs this: its page is ONE printed panel with the
##   hazard band at a fixed height, and a tiled projection would slide the band
##   up and down with the panel's run length.
class PropMesh extends RefCounted:
	enum { UV_TILED, UV_UNIT }

	var uv_mode := UV_TILED
	var uv_tile_m := 2.0

	var _verts := PackedVector3Array()
	var _norms := PackedVector3Array()
	var _cols := PackedColorArray()
	var _uvs := PackedVector2Array()
	var _idx := PackedInt32Array()

	func is_empty() -> bool:
		return _idx.is_empty()

	func tri_count() -> int:
		return _idx.size() / 3

	## Axis-aligned box, `centre` at its middle.
	func add_box(centre: Vector3, size: Vector3, color: Color) -> void:
		add_box_yaw(centre, size, 0.0, color)

	## Box spun around Y — the same primitive for props that sit at an angle.
	func add_box_yaw(centre: Vector3, size: Vector3, yaw: float, color: Color) -> void:
		var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0))
		var h := size * 0.5
		var x := basis.x * h.x
		var y := basis.y * h.y
		var z := basis.z * h.z
		_quad(centre + x - y - z, centre + x + y - z, centre + x + y + z,
				centre + x - y + z, basis.x, color)
		_quad(centre - x - y + z, centre - x + y + z, centre - x + y - z,
				centre - x - y - z, -basis.x, color)
		_quad(centre - x + y - z, centre - x + y + z, centre + x + y + z,
				centre + x + y - z, basis.y, color)
		_quad(centre - x - y + z, centre - x - y - z, centre + x - y - z,
				centre + x - y + z, -basis.y, color)
		_quad(centre - x - y + z, centre + x - y + z, centre + x + y + z,
				centre - x + y + z, basis.z, color)
		_quad(centre + x - y - z, centre - x - y - z, centre - x + y - z,
				centre + x + y - z, -basis.z, color)

	## Square-section beam from `a` to `b` — legs, chords, braces, pendants.
	func add_beam(a: Vector3, b: Vector3, thickness: float, color: Color) -> void:
		var d := b - a
		var length := d.length()
		if length < 0.0001 or thickness <= 0.0:
			return
		var f := d / length
		var ref := Vector3.UP if absf(f.dot(Vector3.UP)) < 0.985 else Vector3.RIGHT
		var r := f.cross(ref).normalized() * (thickness * 0.5)
		var u := r.normalized().cross(f).normalized() * (thickness * 0.5)
		var a0 := a - r - u
		var a1 := a + r - u
		var a2 := a + r + u
		var a3 := a - r + u
		var b0 := b - r - u
		var b1 := b + r - u
		var b2 := b + r + u
		var b3 := b - r + u
		var nu := u.normalized()
		var nr := r.normalized()
		_quad(a0, a1, b1, b0, -nu, color)
		_quad(a1, a2, b2, b1, nr, color)
		_quad(a2, a3, b3, b2, nu, color)
		_quad(a3, a0, b0, b3, -nr, color)
		_quad(a3, a2, a1, a0, -f, color)
		_quad(b0, b1, b2, b3, f, color)

	## Rectangular pyramid standing on the ground at `base_centre` — heaps.
	func add_pyramid(base_centre: Vector3, base: Vector2, height: float,
			color: Color) -> void:
		var h := Vector2(base.x * 0.5, base.y * 0.5)
		var p0 := base_centre + Vector3(-h.x, 0.0, -h.y)
		var p1 := base_centre + Vector3(h.x, 0.0, -h.y)
		var p2 := base_centre + Vector3(h.x, 0.0, h.y)
		var p3 := base_centre + Vector3(-h.x, 0.0, h.y)
		var apex := base_centre + Vector3(0.0, height, 0.0)
		_tri(p0, p1, apex, ((p1 - p0).cross(apex - p0)).normalized() * -1.0, color)
		_tri(p1, p2, apex, ((p2 - p1).cross(apex - p1)).normalized() * -1.0, color)
		_tri(p2, p3, apex, ((p3 - p2).cross(apex - p2)).normalized() * -1.0, color)
		_tri(p3, p0, apex, ((p0 - p3).cross(apex - p3)).normalized() * -1.0, color)
		_quad(p0, p3, p2, p1, Vector3.DOWN, color)

	func to_mesh(material: Material) -> ArrayMesh:
		var mesh := ArrayMesh.new()
		if _idx.is_empty():
			return mesh
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = _verts
		arrays[Mesh.ARRAY_NORMAL] = _norms
		arrays[Mesh.ARRAY_COLOR] = _cols
		arrays[Mesh.ARRAY_TEX_UV] = _uvs
		arrays[Mesh.ARRAY_INDEX] = _idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if material != null:
			mesh.surface_set_material(0, material)
		return mesh

	## THE COLOUR SEAM for every prop this builder makes (report 98 RR-95,
	## doc 93 §X1). A vertex COLOR is handed to the material exactly as written:
	## `StandardMaterial3D.vertex_color_is_srgb` is off (the project default) and
	## `power_pad.gdshader` reads `COLOR.rgb` raw, so every hex above — the
	## fence, the crane yellow, the skip green, the pad's cabinet — was being used
	## as if it were already linear and rendered about two stops light. Decoded
	## HERE, once per vertex at build time, never at the constant: `crane_dark_color`
	## and friends are also handed to `set_instance_color` in `_build_fence`, and
	## that seam decodes for itself at its own write.
	func _push(p: Vector3, n: Vector3, color: Color, uv: Vector2) -> int:
		_verts.push_back(p)
		_norms.push_back(n)
		_cols.push_back(color.srgb_to_linear())
		_uvs.push_back(uv)
		return _verts.size() - 1

	## Metres-along-the-face, divided by the page pitch. Continuous across a
	## box's four flanks, so a hoarding post or a crane chord never shows a seam
	## where two faces meet.
	func _tiled_uv(p: Vector3, n: Vector3) -> Vector2:
		var t := maxf(uv_tile_m, 0.01)
		if absf(n.y) > 0.5:
			return Vector2(p.x / t, p.z / t)
		if absf(n.x) >= absf(n.z):
			return Vector2(p.z / t, -p.y / t)
		return Vector2(p.x / t, -p.y / t)

	## The face's own [0,1] box, v flipped so the page's top is the prop's top.
	static func _unit_uv(p: Vector3, n: Vector3, lo: Vector3, hi: Vector3) -> Vector2:
		var ext := hi - lo
		if absf(n.y) > 0.5:
			return Vector2((p.x - lo.x) / maxf(ext.x, 0.0001),
					(p.z - lo.z) / maxf(ext.z, 0.0001))
		var u := (p.z - lo.z) / maxf(ext.z, 0.0001) if absf(n.x) >= absf(n.z) \
				else (p.x - lo.x) / maxf(ext.x, 0.0001)
		return Vector2(u, (hi.y - p.y) / maxf(ext.y, 0.0001))

	func _quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3,
			color: Color) -> void:
		var u0 := Vector2.ZERO
		var u1 := Vector2.ZERO
		var u2 := Vector2.ZERO
		var u3 := Vector2.ZERO
		if uv_mode == UV_UNIT:
			var lo := Vector3(minf(minf(p0.x, p1.x), minf(p2.x, p3.x)),
					minf(minf(p0.y, p1.y), minf(p2.y, p3.y)),
					minf(minf(p0.z, p1.z), minf(p2.z, p3.z)))
			var hi := Vector3(maxf(maxf(p0.x, p1.x), maxf(p2.x, p3.x)),
					maxf(maxf(p0.y, p1.y), maxf(p2.y, p3.y)),
					maxf(maxf(p0.z, p1.z), maxf(p2.z, p3.z)))
			u0 = _unit_uv(p0, n, lo, hi)
			u1 = _unit_uv(p1, n, lo, hi)
			u2 = _unit_uv(p2, n, lo, hi)
			u3 = _unit_uv(p3, n, lo, hi)
		else:
			u0 = _tiled_uv(p0, n)
			u1 = _tiled_uv(p1, n)
			u2 = _tiled_uv(p2, n)
			u3 = _tiled_uv(p3, n)
		var i0 := _push(p0, n, color, u0)
		var i1 := _push(p1, n, color, u1)
		var i2 := _push(p2, n, color, u2)
		var i3 := _push(p3, n, color, u3)
		_wind(i0, i1, i2, p0, p1, p2, n)
		_wind(i0, i2, i3, p0, p2, p3, n)

	func _tri(p0: Vector3, p1: Vector3, p2: Vector3, n: Vector3, color: Color) -> void:
		var i0 := _push(p0, n, color, _tiled_uv(p0, n))
		var i1 := _push(p1, n, color, _tiled_uv(p1, n))
		var i2 := _push(p2, n, color, _tiled_uv(p2, n))
		_wind(i0, i1, i2, p0, p1, p2, n)

	func _wind(i0: int, i1: int, i2: int, p0: Vector3, p1: Vector3, p2: Vector3,
			n: Vector3) -> void:
		if (p1 - p0).cross(p2 - p0).dot(n) > 0.0:
			_idx.push_back(i0)
			_idx.push_back(i2)
			_idx.push_back(i1)
		else:
			_idx.push_back(i0)
			_idx.push_back(i1)
			_idx.push_back(i2)

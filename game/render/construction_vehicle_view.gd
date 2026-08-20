class_name ConstructionVehicleView
extends Node3D
## LIVING CONSTRUCTION (doc 11 §2.16) — the layer that turns a site from a box
## that grows into a job that is being DONE.
##
## `ConstructionSiteView` already fences the lot, stands a crane over it and
## stacks a yard inside the hoarding. This view adds the half the player asked
## for: **plant that works and lorries that arrive.** An excavator digs the
## frontage through the early stages; tippers leave a depot on the edge of the
## road network, drive REAL STREETS to the site, pull up in front of the lot and
## stand with the bed up while the load drains onto a heap that visibly grows,
## then drive home. Once the building tops out the flow reverses — the lorry
## comes in empty and is loaded with its bed DOWN, leaves with the spoil, the
## heaps come down and the barricades are lifted a bay at a time.
##
## FIVE DRAW CALLS, whatever the city is doing:
##
##   MM_excavator  articulated plant, `construction_rig.gdshader`
##   MM_tipper     articulated plant, the same shader, `rig_mode = 1`
##   MM_pile_heap  loose material — sand, gravel
##   MM_pile_stack bundled stock — rebar, section steel
##   MM_barrier    one barricade bay + two cones, instanced along the lane line
##
## The two machines are ONE MultiMesh each because the shader walks their
## kinematic chain in the vertex stage off four floats of INSTANCE_CUSTOM (see
## `game/shaders/construction_rig.gdshader`). Boom, arm, bucket, slew and the
## tipping bed cost no extra buffer, no extra node and no extra call.
##
## WHAT IT READS. `RoadNetwork.route_tiles()` for street-true polylines, and
## the site's own stage. Nothing else, and nothing goes back: this view is
## strictly downstream of the sim (constitution §3). Every choice it makes —
## which depot, which cadence, which livery, which part of the dig cycle — is a
## hash of the building id and the game clock, so it is the same on every
## device and after every load, and the sim's state hash cannot move because of
## it. `tests/test_construction_living.gd` pins that by interleaving this
## view's route lookups into a running sim and comparing hashes.
##
## Integration (`main.gd` owns the wiring — see the branch report for the
## patch), and every call mirrors one `ConstructionSiteView` already takes:
##   view.setup(render_data)
##   view.set_road_network(sim.roads)
##   view.add_site(id, centre, footprint_tiles, height_m)   # on placement
##   view.set_stage(id, stage)                              # 1..6
##   view.remove_site(id)                                   # on completion
##   view.refresh(delta, night, gm_per_s, game_minutes)     # every frame

## Emitted when a site's STREET FRONTAGE lands or moves — on the frame its
## route resolves, and again after a road edit re-routes it. `side` is
## 0 = -Z, 1 = +X, 2 = +Z, 3 = -X, or -1 when no street is in reach.
##
## The shell wires this straight into `ConstructionSiteView.set_gate_side` so
## the hoarding's gate turns to the same face this layer stands its plant on.
## Without it the two layers agree one time in four (§2.16's filed open item 4).
signal site_frontage_changed(id: int, side: int)

const SHADER := "res://game/shaders/construction_rig.gdshader"

const DEF_TILE_M := 8.0
const DEF_ROAD_TOP_M := 0.10
const DEF_LANE_OFFSET_M := 1.85
## Sites further than this from the camera focus are not evaluated at all. A
## lorry two districts away is not a story anyone is watching.
const DEF_VISIBLE_RADIUS_M := 520.0
const DEF_MAX_SITES := 28
const DEF_HEADLIGHT_THRESHOLD := 0.15
## Routes resolved per frame. A city that boots with thirty sites under way
## spreads the A* over thirty frames instead of stalling the first one.
const ROUTES_PER_FRAME := 2
## Game-minutes of drift tolerated between this layer's clock and the sim's
## before the layer is snapped onto it. A tick is 0.25 game-minutes, so this is
## eight ticks of slack — far below the 46-minute delivery cadence, and wide
## enough that no ordinary frame-time jitter ever trips it.
const RESYNC_GM := 2.0
## Depot candidates kept off the road network's outer ring, and how many of the
## nearest ones a site chooses between.
const GATEWAY_MAX := 12
const GATEWAY_CHOICES := 4

var tile_m := DEF_TILE_M
var road_top := DEF_ROAD_TOP_M
var lane_offset := DEF_LANE_OFFSET_M
var visible_radius := DEF_VISIBLE_RADIUS_M
var max_sites := DEF_MAX_SITES
var night_threshold := DEF_HEADLIGHT_THRESHOLD
var world_m := 1024.0
var cast_shadows := false
var preset := "balanced"

var activity := ConstructionActivity.new()

var _roads: RoadNetwork = null
var _profile: RouteProfile = null
var _layers: Dictionary = {}       # key -> Layer
var _pending: Array[int] = []      # site ids waiting for a route
var _gateways: Array[Vector2i] = []
var _gateway_version := -1
var _route_version := -1
var _explicit_depots: Array[Vector2i] = []
var _gm := 0.0
var _gm_per_s := 1.0
var _anim_time := 0.0
var _night := 0.0
var _focus := Vector3.ZERO
var _has_focus := false
var _configured := false


class Layer extends RefCounted:
	var key := ""
	var node: MultiMeshInstance3D
	var mm: MultiMesh
	var material: Material


# -------------------------------------------------------------- public API

## `render_data` is data/render.json. Only `construction_vehicles`,
## `vehicles` (for the road surface and lane numbers this layer shares with
## doc 10's traffic) and `world.tile_m` are read, and every key is optional —
## the constants above are the shipping values, so the view works against a
## render.json that has never heard of it.
func setup(render_data: Dictionary = {}) -> void:
	var cfg: Dictionary = render_data.get("construction_vehicles", {})
	var traffic: Dictionary = render_data.get("vehicles", {})
	tile_m = _num(render_data.get("world", {}), "tile_m", DEF_TILE_M)
	world_m = _num(traffic, "world_m", maxf(1024.0, tile_m * 128.0))
	# The road surface and the lane offset belong to doc 10's traffic layer;
	# reading them from there is what keeps a lorry in the same lane as the
	# cars it is holding up.
	road_top = _num(traffic, "road_top_m", DEF_ROAD_TOP_M)
	lane_offset = _num(traffic, "lane_offset_m", DEF_LANE_OFFSET_M)
	night_threshold = _num(traffic, "headlight_night_threshold", DEF_HEADLIGHT_THRESHOLD)
	cast_shadows = bool(traffic.get("cast_shadows", false))
	visible_radius = _num(cfg, "visible_radius_m", DEF_VISIBLE_RADIUS_M)
	max_sites = int(cfg.get("max_sites", DEF_MAX_SITES))
	activity.road_top = road_top
	activity.lane_offset = lane_offset
	activity.configure(cfg, tile_m)
	_read_presets(render_data)
	_build_layers(cfg)
	_configured = true


## Preset swap from the settings sheet (doc 12 §2.13) — one knob, the same one
## the traffic layer moves: whether the plant is re-drawn into the shadow
## splits. Nothing already standing is lost.
func set_preset(name: String, render_data: Dictionary = {}) -> void:
	preset = name
	if not render_data.is_empty():
		_read_presets(render_data)
	var setting := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for key: String in _layers:
		var layer: Layer = _layers[key]
		if layer.node != null:
			layer.node.cast_shadow = setting


## Doc 10's live network. Read-only: this view calls `route_tiles()` and the
## graph's tile accessors and nothing else, and it never writes.
func set_road_network(network: RoadNetwork) -> void:
	_roads = network
	_profile = RouteProfile.construction(activity.truck_speed_mpgm)
	_gateway_version = -1
	_route_version = -1
	_requeue_all()


## Depot override. With no depots pushed, the view uses the outer ring of the
## road network — the tiles where the streets leave the built city, which is
## where material comes from when the player has no industry yet. A caller that
## knows better (an industrial roster, a materials yard) can name the tiles
## here and every lorry will come from one of them instead.
func set_depots(tiles: Array) -> void:
	_explicit_depots.clear()
	for t: Variant in tiles:
		if t is Vector2i:
			_explicit_depots.append(t)
	_gateway_version = -1
	_requeue_all()


## Camera focus for the distance gate. Optional — with no focus pushed nothing
## is culled.
func set_focus(world_pos: Vector3) -> void:
	_focus = world_pos
	_has_focus = true


## One site starts. `world_pos` is the lot CENTRE at ground level and the three
## arguments are the ones `ConstructionSiteView.add_site` already takes.
func add_site(id: int, world_pos: Vector3, footprint_tiles: Vector2i,
		height_m: float) -> void:
	_ensure_setup()
	if activity.sites.has(id):
		remove_site(id)
	activity.add_site(id, world_pos, footprint_tiles, height_m)
	if not _pending.has(id):
		_pending.append(id)


func set_stage(id: int, stage: int) -> void:
	activity.set_stage(id, stage)


func remove_site(id: int) -> void:
	activity.remove_site(id)
	_pending.erase(id)


func clear() -> void:
	activity.clear()
	_pending.clear()
	for key: String in _layers:
		var layer: Layer = _layers[key]
		if layer.mm != null:
			layer.mm.visible_instance_count = 0


## One rendered frame.
##
## * `night` is doc 11's day/night scalar (0 day … 1 night); pass -1 to leave
##   it as it was. It gates the lorries' lamps, nothing else — the amber
##   beacons run around the clock, because a work site announces itself in
##   daylight too.
## * `gm_per_s` is game-minutes per real second (the speed multiplier, 0 while
##   paused). Everything in this layer is scheduled in GAME time, so pausing
##   parks every lorry exactly where it stands.
## * `game_minutes` is the sim's own clock — `clock.game_seconds() / 60.0`.
##   Pass it and the layer is pinned to the save: a load, a catch-up or an
##   `--advance-hours` puts the lorries where the save says they are instead of
##   where the frame counter got to. Omit it and the layer free-runs, which is
##   what a preview harness with no sim wants.
func refresh(delta: float, night: float = -1.0, gm_per_s: float = -1.0,
		game_minutes: float = -1.0) -> void:
	_ensure_setup()
	if night >= 0.0:
		_night = clampf(night, 0.0, 1.0)
	if gm_per_s >= 0.0:
		_gm_per_s = gm_per_s
	_anim_time += delta
	_gm += delta * maxf(_gm_per_s, 0.0)
	if game_minutes >= 0.0 and absf(game_minutes - _gm) > RESYNC_GM:
		_gm = game_minutes
	_service_routes()
	activity.refresh(_gm, _focus, visible_radius if _has_focus else 0.0, max_sites)
	_upload()


func site_count() -> int:
	return activity.site_count()


## Draw calls this layer costs when every kind is on screen at once.
func layer_count() -> int:
	return _layers.size()


## Live instance census, for the tests and the profiler table.
func census() -> Dictionary:
	return {
		"excavator": activity.rig_used,
		"tipper": activity.truck_used,
		"heap": activity.heap_used,
		"stack": activity.stack_used,
		"barrier": activity.barrier_used,
		"sites": activity.site_count(),
		"pending_routes": _pending.size(),
	}


## This layer's clock, in game-minutes. Exposed for the tests, which drive it
## instead of a frame loop.
func game_minutes() -> float:
	return _gm


func set_game_minutes(value: float) -> void:
	_gm = value


# ------------------------------------------------------------------ routes

## Resolve at most `ROUTES_PER_FRAME` pending sites. A road edit bumps
## `graph_version`, which drops every route and re-queues every site — the
## streets a lorry drives are the streets that exist.
func _service_routes() -> void:
	if _roads == null:
		return
	if _roads.graph.graph_version != _route_version:
		_route_version = _roads.graph.graph_version
		_requeue_all()
	var budget := ROUTES_PER_FRAME
	while budget > 0 and not _pending.is_empty():
		var id: int = _pending.pop_front()
		if activity.sites.has(id):
			_resolve(id)
			budget -= 1


func _requeue_all() -> void:
	_pending.clear()
	var ids: Array = activity.sites.keys()
	ids.sort()
	for id: int in ids:
		activity.clear_route(id)
		_pending.append(id)


func _resolve(id: int) -> void:
	var site: ConstructionActivity.Site = activity.sites[id]
	var was := frontage_side(id)
	var road := _frontage_road(site)
	if road.x < 0:
		# No street within the snap radius: the site keeps its hoarding and its
		# crane and gets no traffic. Nothing to draw is the honest answer.
		activity.set_route(id, Vector2i(-1, -1), Vector2i(-1, -1), [], [])
		_announce_frontage(id, was)
		return
	# Try the nearest few gateways in turn: the outermost tile of a road
	# network can be a stub that shares no component with this site.
	for depot: Vector2i in _depot_choices(id, road):
		if depot == road:
			continue
		var out_tiles: Array = _roads.route_tiles(depot, road, _profile)
		if out_tiles.is_empty():
			continue
		var home_tiles: Array = _roads.route_tiles(road, depot, _profile)
		activity.set_route(id, road, depot, out_tiles, home_tiles)
		_announce_frontage(id, was)
		return
	# Reachable street, no reachable depot: frontage and yard, no lorries.
	activity.set_route(id, road, Vector2i(-1, -1), [], [])
	_announce_frontage(id, was)


func _announce_frontage(id: int, was: int) -> void:
	var now := frontage_side(id)
	if now != was:
		site_frontage_changed.emit(id, now)


## The road tile this lot FRONTS ON: the nearest road found by walking straight
## out from each of the four faces, nearest step first and, within a step, the
## probe closest to the middle of its face.
##
## `RoadGraph.nearest_road_tile` is the wrong tool here and it took a
## screenshot to see why: it answers Chebyshev-nearest, so a corner lot with
## roads on two sides gets handed the DIAGONAL tile between them. The frontage
## frame then reads the right side by dominant axis but puts the lorry's stop
## twelve metres along the kerb, past the lot's own corner, with the plant
## strung out after it. A frontage is a FACE, so the search has to be one.
func _frontage_road(site: ConstructionActivity.Site) -> Vector2i:
	return _frontage_road_at(site.world_pos, site.footprint)


## Which side of a lot fronts the street: **0 = -Z, 1 = +X, 2 = +Z, 3 = -X**,
## or -1 when no street is within the snap radius. The same four indices
## `ConstructionSiteView` numbers its hoarding runs with, deliberately.
##
## Two ways in. This one is a pure QUERY on a lot that need not be a site yet,
## so the shell can ask it in the same breath it calls `add_site` on both layers
## — the routes resolve two a frame and the hoarding cannot wait for them. The
## `frontage_side(id)` overload below reads the site's own resolved frontage,
## which is what the `site_frontage_changed` signal carries after a re-route.
func frontage_side(world_pos: Variant, footprint_tiles: Vector2i = Vector2i.ONE) -> int:
	_ensure_setup()
	if world_pos is int:
		var site: Variant = activity.sites.get(int(world_pos))
		if site == null or not (site as ConstructionActivity.Site).frontage_ok:
			return -1
		return side_of_delta((site as ConstructionActivity.Site).out)
	if _roads == null:
		return -1
	var lot: Vector3 = world_pos
	var road := _frontage_road_at(lot, footprint_tiles)
	if road.x < 0:
		return -1
	return side_of_delta(Vector3((float(road.x) + 0.5) * tile_m, 0.0,
			(float(road.y) + 0.5) * tile_m) - lot)


## The frontage frame's dominant-axis test, as a side index. Mirrors
## `ConstructionActivity._frame_frontage` exactly, tie-break included: an
## ambiguous delta resolves to +X, then +Z, which is what makes the two layers
## agree on a lot that is dead square to its street.
static func side_of_delta(d: Vector3) -> int:
	if absf(d.x) >= absf(d.z):
		return 3 if d.x < -0.0001 else 1
	return 0 if d.z < -0.0001 else 2


func _frontage_road_at(world_pos: Vector3, footprint_tiles: Vector2i) -> Vector2i:
	var size := footprint_tiles
	# `world_pos` is the lot centre, so the origin corner is exactly this.
	var origin := Vector2i(
			int(round((world_pos.x - float(size.x) * tile_m * 0.5) / tile_m)),
			int(round((world_pos.z - float(size.y) * tile_m * 0.5) / tile_m)))
	var radius := maxi(1, _roads.tun.snap_radius_tiles)
	for step in range(1, radius + 1):
		var best := Vector2i(-1, -1)
		var best_key := INF
		# Faces in a fixed order — -Z, +X, +Z, -X — so a lot with two equally
		# near frontages always picks the same one, on every device and run.
		for side in 4:
			var probes: Array[Vector2i] = []
			match side:
				0:
					for x in size.x:
						probes.append(Vector2i(origin.x + x, origin.y - step))
				1:
					for y in size.y:
						probes.append(Vector2i(origin.x + size.x - 1 + step, origin.y + y))
				2:
					for x in size.x:
						probes.append(Vector2i(origin.x + x, origin.y + size.y - 1 + step))
				_:
					for y in size.y:
						probes.append(Vector2i(origin.x - step, origin.y + y))
			for i in probes.size():
				var t: Vector2i = probes[i]
				if not _roads.graph.is_road_tile(t):
					continue
				# Distance from the middle of the face, then the face's own
				# order: the lorry should pull up in front of the lot.
				var key := absf(float(i) - (float(probes.size()) - 1.0) * 0.5) \
						+ float(side) * 0.01
				if key < best_key:
					best_key = key
					best = t
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)


## The gateways this site will consider, nearest first, rotated by the id so a
## row of sites is not all fed from the same corner of the map.
func _depot_choices(id: int, road: Vector2i) -> Array[Vector2i]:
	var pool := _gateway_tiles()
	var out: Array[Vector2i] = []
	if pool.is_empty():
		return out
	var ranked: Array[Vector2i] = pool.duplicate()
	ranked.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := maxi(absi(a.x - road.x), absi(a.y - road.y))
		var db := maxi(absi(b.x - road.x), absi(b.y - road.y))
		if da != db:
			return da < db
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y)
	var k := mini(GATEWAY_CHOICES, ranked.size())
	var pick := int(ConstructionActivity.hash01(id, 61) * float(k))
	for i in k:
		out.append(ranked[(pick + i) % k])
	return out


## Where material comes from: the outer ring of the road network — the tiles at
## the extreme of its extent, i.e. where the streets leave the built city. A
## caller that has named real depots with `set_depots` gets those instead.
## Rebuilt only when the graph changes.
func _gateway_tiles() -> Array[Vector2i]:
	if not _explicit_depots.is_empty():
		return _explicit_depots
	if _roads == null:
		return [] as Array[Vector2i]
	if _gateway_version == _roads.graph.graph_version and not _gateways.is_empty():
		return _gateways
	_gateway_version = _roads.graph.graph_version
	_gateways.clear()
	var tiles: Array = _roads.graph.road_tiles_sorted()
	if tiles.is_empty():
		return _gateways
	var lo: Vector2i = tiles[0]
	var hi: Vector2i = tiles[0]
	for t: Vector2i in tiles:
		lo = Vector2i(mini(lo.x, t.x), mini(lo.y, t.y))
		hi = Vector2i(maxi(hi.x, t.x), maxi(hi.y, t.y))
	var ring: Array[Vector2i] = []
	for t: Vector2i in tiles:
		if t.x == lo.x or t.x == hi.x or t.y == lo.y or t.y == hi.y:
			ring.append(t)
	if ring.is_empty():
		ring.append(tiles[0])
	# Even subsample, so the gateways are spread around the ring rather than
	# bunched along whichever edge happens to be listed first.
	var step := maxi(1, ring.size() / GATEWAY_MAX)
	var i := 0
	while i < ring.size() and _gateways.size() < GATEWAY_MAX:
		_gateways.append(ring[i])
		i += step
	return _gateways


# ------------------------------------------------------------------ upload

## Five buffers, rewritten from the activity model's pose arrays.
##
## Still three `set_instance_*` calls an instance and NOT one packed
## `MultiMesh.buffer` write, and that is a measured decision: on this build the
## setters cost 0.031 ms per 200 instances per frame against 0.064 ms to pack
## the same rows in GDScript (0.307 vs 0.662 at 2,000), because each setter is
## one binding call around a C++ memcpy while packing is twenty scripted float
## writes, and the server-side write is ~0.003 ms either way. The A/B harness is
## `tools/profile_mm_upload.gd` and the numbers are in the branch report. See
## `RoadSurfaceView._upload` for the one place in this renderer where the packed
## buffer IS the right tool — a per-EDIT path whose contract needs the bytes.
func _upload() -> void:
	var lamps := 0.0 if night_threshold <= 0.0 \
			else clampf((_night - night_threshold) / 0.30, 0.0, 1.0)
	_write(_layers.get("excavator"), activity.rig_poses, activity.rig_used, -1.0)
	_write(_layers.get("tipper"), activity.truck_poses, activity.truck_used, lamps)
	_write(_layers.get("heap"), activity.heap_poses, activity.heap_used, -1.0)
	_write(_layers.get("stack"), activity.stack_poses, activity.stack_used, -1.0)
	_write(_layers.get("barrier"), activity.barrier_poses, activity.barrier_used, -1.0)
	for key: String in _layers:
		var layer: Layer = _layers[key]
		if layer.material is ShaderMaterial:
			(layer.material as ShaderMaterial).set_shader_parameter("anim_time", _anim_time)
			(layer.material as ShaderMaterial).set_shader_parameter("night_amt", _night)


## `lamp` >= 0 overwrites the pose's third custom channel — the tippers' head
## and tail lamps, which are the view's to gate on the night factor and not the
## activity model's (it knows what time it is, not how dark it looks). The two
## loops are one branch hoisted out of the body: only the tipper layer passes a
## lamp, and testing it per instance was a branch per instance per frame.
func _write(layer_v: Variant, poses: Array, used: int, lamp: float) -> void:
	if layer_v == null:
		return
	var layer: Layer = layer_v
	_ensure_capacity(layer, used)
	var mm := layer.mm
	var n := mini(used, mm.instance_count)
	if lamp >= 0.0:
		for i in n:
			var pose: ConstructionActivity.Pose = poses[i]
			var c: Color = pose.custom
			mm.set_instance_transform(i, Transform3D(pose.basis, pose.origin))
			mm.set_instance_color(i, pose.tint)
			mm.set_instance_custom_data(i, Color(c.r, c.g, lamp, c.a))
	else:
		for i in n:
			var pose: ConstructionActivity.Pose = poses[i]
			mm.set_instance_transform(i, Transform3D(pose.basis, pose.origin))
			mm.set_instance_color(i, pose.tint)
			mm.set_instance_custom_data(i, pose.custom)
	mm.visible_instance_count = n


func _ensure_capacity(layer: Layer, needed: int) -> void:
	if needed <= layer.mm.instance_count:
		return
	# Growing resets the buffer; every visible instance is rewritten each frame
	# anyway, so there is nothing to preserve.
	layer.mm.instance_count = ((needed / 16) + 1) * 16


# ------------------------------------------------------------------- setup

func _ensure_setup() -> void:
	if not _configured:
		setup()


func _read_presets(render_data: Dictionary) -> void:
	var row: Dictionary = (render_data.get("presets", {}) as Dictionary).get(preset, {})
	# The preset has the last word on shadows, exactly as it does for doc 10's
	# traffic: a tier that has already decided how many splits it can afford is
	# the right place to decide whether this layer is re-drawn into all of them.
	# It is the ONLY key this layer reads from a preset row — the distance gate
	# and the site ceiling belong to `construction_vehicles`, because how many
	# sites are worth animating is an art call and not a device tier.
	if row.has("vehicle_shadows"):
		cast_shadows = bool(row["vehicle_shadows"])


func _build_layers(cfg: Dictionary) -> void:
	for key: String in _layers.keys():
		(_layers[key] as Layer).node.queue_free()
	_layers.clear()
	var tile := PropSurface.tile_m()
	# The prop pages, borrowed off the materials `PropSurface` already builds —
	# one place decides what "steel" and "stock" look like in this city.
	var steel_page: Texture2D = PropSurface.material("steel").albedo_texture
	var stock_page: Texture2D = PropSurface.material("stock").albedo_texture
	var shader: Shader = load(SHADER)

	var excavator := ConstructionRigMesh.excavator()
	excavator.uv_tile_m = tile
	var exc_mat := _rig_material(shader, steel_page, stock_page, cfg)
	exc_mat.set_shader_parameter("rig_mode", 0.0)
	exc_mat.set_shader_parameter("joint_axis", _v4(ConstructionRigMesh.EXC_AXES))
	exc_mat.set_shader_parameter("joint_min", Vector4(
			ConstructionRigMesh.EXC_SLEW_RANGE.x, ConstructionRigMesh.EXC_BOOM_RANGE.x,
			ConstructionRigMesh.EXC_ARM_RANGE.x, ConstructionRigMesh.EXC_BUCKET_RANGE.x))
	exc_mat.set_shader_parameter("joint_range", Vector4(
			ConstructionRigMesh.EXC_SLEW_RANGE.y - ConstructionRigMesh.EXC_SLEW_RANGE.x,
			ConstructionRigMesh.EXC_BOOM_RANGE.y - ConstructionRigMesh.EXC_BOOM_RANGE.x,
			ConstructionRigMesh.EXC_ARM_RANGE.y - ConstructionRigMesh.EXC_ARM_RANGE.x,
			ConstructionRigMesh.EXC_BUCKET_RANGE.y - ConstructionRigMesh.EXC_BUCKET_RANGE.x))
	exc_mat.set_shader_parameter("pivot_1",
			Vector3(0.0, ConstructionRigMesh.EXC_SLEW_Y, 0.0))
	exc_mat.set_shader_parameter("pivot_2", ConstructionRigMesh.EXC_BOOM_PIVOT)
	exc_mat.set_shader_parameter("pivot_3", ConstructionRigMesh.EXC_ARM_PIVOT)
	exc_mat.set_shader_parameter("pivot_4", ConstructionRigMesh.EXC_BUCKET_PIVOT)
	exc_mat.set_shader_parameter("load_joint", -1.0)
	_add_layer("excavator", excavator, exc_mat, 16.0)

	var tipper := ConstructionRigMesh.dump_truck()
	tipper.uv_tile_m = tile
	var tip_mat := _rig_material(shader, steel_page, stock_page, cfg)
	tip_mat.set_shader_parameter("rig_mode", 1.0)
	tip_mat.set_shader_parameter("joint_axis", _v4(ConstructionRigMesh.TIP_AXES))
	tip_mat.set_shader_parameter("joint_min",
			Vector4(ConstructionRigMesh.TIP_RANGE.x, 0.0, 0.0, 0.0))
	tip_mat.set_shader_parameter("joint_range", Vector4(
			ConstructionRigMesh.TIP_RANGE.y - ConstructionRigMesh.TIP_RANGE.x,
			0.0, 0.0, 0.0))
	tip_mat.set_shader_parameter("pivot_1", ConstructionRigMesh.TIP_HINGE)
	tip_mat.set_shader_parameter("pivot_2", Vector3.ZERO)
	tip_mat.set_shader_parameter("pivot_3", Vector3.ZERO)
	tip_mat.set_shader_parameter("pivot_4", Vector3.ZERO)
	tip_mat.set_shader_parameter("load_joint", ConstructionRigMesh.JOINT_2)
	tip_mat.set_shader_parameter("load_floor_y", ConstructionRigMesh.TIP_LOAD_FLOOR_Y)
	_add_layer("tipper", tipper, tip_mat, 16.0)

	# The yard props read no joint and need no shader: `PropSurface` is the same
	# material the hoarding and the crane already stand in.
	var heap := ConstructionRigMesh.pile_heap()
	heap.uv_tile_m = tile
	_add_layer("heap", heap, PropSurface.material("stock", 0.96, 0.0), 6.0)
	var stack := ConstructionRigMesh.pile_stack()
	stack.uv_tile_m = tile
	_add_layer("stack", stack, PropSurface.material("stock", 0.92, 0.05), 6.0)
	var barrier := ConstructionRigMesh.barrier_bay()
	barrier.uv_tile_m = tile
	_add_layer("barrier", barrier, PropSurface.material("steel", 0.72, 0.10), 6.0)
	set_preset(preset)


func _rig_material(shader: Shader, steel_page: Texture2D, stock_page: Texture2D,
		cfg: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	if steel_page != null and stock_page != null:
		mat.set_shader_parameter("steel_tex", steel_page)
		mat.set_shader_parameter("stock_tex", stock_page)
		mat.set_shader_parameter("tex_mix", 1.0)
	else:
		# A clone with no generated pages runs the layer flat-shaded, exactly
		# as `VehicleView` and `PropSurface` do.
		mat.set_shader_parameter("tex_mix", 0.0)
	mat.set_shader_parameter("beacon_hz", _num(cfg, "beacon_hz", 1.35))
	mat.set_shader_parameter("beacon_energy", _num(cfg, "beacon_energy", 3.2))
	mat.set_shader_parameter("lamp_energy", _num(cfg, "lamp_energy", 2.2))
	return mat


func _add_layer(key: String, builder: ConstructionRigMesh, material: Material,
		height_m: float) -> void:
	var layer := Layer.new()
	layer.key = key
	layer.material = material
	layer.mm = MultiMesh.new()
	layer.mm.transform_format = MultiMesh.TRANSFORM_3D
	layer.mm.use_colors = true
	layer.mm.use_custom_data = true
	layer.mm.mesh = builder.to_mesh(material)
	layer.mm.instance_count = 16
	layer.mm.visible_instance_count = 0
	layer.node = MultiMeshInstance3D.new()
	layer.node.name = "MM_%s" % key
	layer.node.multimesh = layer.mm
	# Instances are written straight into the buffer and never update the auto
	# AABB, so every MultiMesh in this project carries an explicit one.
	layer.node.custom_aabb = AABB(
			Vector3(-world_m * 0.05, -4.0, -world_m * 0.05),
			Vector3(world_m * 1.1, height_m + 8.0, world_m * 1.1))
	layer.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(layer.node)
	_layers[key] = layer


# ------------------------------------------------------------------ helpers

static func _v4(c: Color) -> Vector4:
	return Vector4(c.r, c.g, c.b, c.a)


static func _num(cfg: Dictionary, key: String, fallback: float) -> float:
	return float(cfg.get(key, fallback))

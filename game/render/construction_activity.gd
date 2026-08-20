class_name ConstructionActivity
extends RefCounted
## The STORY a construction site tells, as a pure function of published sim
## state (doc 11 §2.16).
##
## The sim says four things about a site and nothing else: its building id, its
## lot, its construction STAGE (1…6, `building_construction_stage`) and what
## time it is. Everything the player sees happen on that lot — which machines
## are working it, when the next lorry leaves the depot, which street it takes,
## how high the sand heap is — is DERIVED here from exactly those four, plus a
## hash of the building id for variation. There is no new sim state, no sim RNG
## stream, and nothing in this file is persisted: a save re-derives the same
## site from the same stage at the same game-minute, which is why the state
## hash cannot move.
##
## THE CLOCK IS GAME TIME. Every schedule below is in GAME-MINUTES, so a lorry
## crosses the city three times as fast at 3× and stands still while paused,
## exactly as doc 11 §2.12's traffic does. The view integrates the clock between
## sim ticks and re-syncs it to `GameClock.game_seconds()` whenever the caller
## offers it, so a load, a catch-up or an `advance_hours` puts the whole layer
## where the save says it is rather than where the frame counter got to.
##
## THE TWO LATCHES, and they are the only retained state in the file.
## `Site.delivered` is a high-water mark that keeps the delivery count monotone
## across a re-route: an edit to the street network can shorten a lorry's run,
## and a count that went DOWN would show as a heap shrinking for no reason the
## player can see. `Site.stage_base` is `delivered` at the moment the current
## stage began, and it is what makes the yard READ — see `pile_fill`. Both are
## render-side derivations of published state and neither is persisted.
##
## WHERE THE WORK HAPPENS. The lot itself is not available: doc 11 §5's massing
## is at full FOOTPRINT from placement (the stage clamp is vertical only), so
## the ground inside the property line is under the building from stage 1. The
## work zone is therefore the site's STREET FRONTAGE. The starter city authors
## no separate footway tile, so the property line IS the kerb and the zone is
## the near half of the 8 m road tile: stock against the hoarding, the barricade
## run on the lane line, the plant straddling it with the boom reaching back
## over the fence. That is a coned-off lane, which is what an urban infill site
## takes, and it is where the lorry is arriving anyway.
##
## The frontage is derived from the ROAD, not from the hoarding's gate — the
## road is published sim state, so two machines never disagree about which way
## the street is. `ConstructionVehicleView` finds the tile by walking out from
## each of the lot's four FACES rather than by Chebyshev distance; a corner lot
## would otherwise be handed the diagonal tile between its two streets. Sites
## with no road within the graph's snap radius get no activity at all, and say
## so through `Site.frontage_ok`.

const STAGE_MIN := 1
const STAGE_MAX := 6

## Excavators working a site, indexed by stage 1…6. Digging is an EARLY-stage
## job: two machines opening the ground, one while the frame goes up, none once
## the building is topping out and the site turns into a delivery yard.
const EXCAVATORS_BY_STAGE := [2, 2, 1, 1, 0, 0]
## Material slots a site keeps: sand, gravel, steel. A delivery lands in
## `delivery_index % 3`, so the three fill in rotation and the yard fills out
## rather than growing one mountain.
const PILE_SLOTS := 3
## Pile 2 is bundled stock (rebar, section steel); 0 and 1 are loose heaps.
const PILE_STACK_SLOT := 2

## Stage at which the site stops taking deliveries and starts shipping spoil
## OUT — the lorry arrives empty and leaves loaded, and the heaps come down.
const CLEANUP_STAGE := 5

## A site with a very long haul can have several trips in flight; this is where
## the picture stops improving and the instance count starts mattering.
const MAX_TRUCKS_PER_SITE := 3

## Metres of frontage between the lorry's stop and the nearest machine: half a
## 7.8 m tipper, half a 10.3 m excavator turned 44° to the kerb, and a metre of
## daylight so the two never interpenetrate at Z0.
const RIG_CLEARANCE_M := 6.5

# --------------------------------------------------------------- the tuning

var tile_m := 8.0
var road_top := 0.10
var lane_offset := 1.85
## Metres per GAME-minute. Doc 10's civilian base is 34; plant is slower, and
## the difference is legible when a lorry is overtaken on its own delivery run.
var truck_speed_mpgm := 21.0
## Game-minutes between two departures from the depot. Hashed ±25% per site so
## a street of sites never runs a convoy.
var delivery_period_gm := 46.0
## Game-minutes a lorry stands at the site with its bed up.
var dump_gm := 4.2
## Game-minutes one excavator dig cycle takes. At 1× a game-minute is a real
## second, so this is a ~7 s loop — slow enough to read as machinery.
var dig_cycle_gm := 7.0
## Pile fill one delivery is worth, and what one stage of progress consumes.
## Six stages at 0.30 consume 1.80 against roughly 4 deliveries a stage at
## 0.26, so a site that is being fed keeps a visible yard and a site that has
## topped out empties.
var pile_per_delivery := 0.26
var pile_consume_per_stage := 0.30
var pile_max_m := 1.75
var pile_base_m := 2.60
## Metres of footway one barricade bay covers.
var barrier_bay_m := 2.55
## How far out from the PROPERTY LINE each fitting stands. The starter city
## authors no separate footway tile, so the property line IS the kerb and the
## whole work zone is the near half of the 8 m road tile: stock against the
## hoarding, the barricade run on the lane line, and the plant straddling it
## with the boom reaching back over the fence. That is a coned-off lane, which
## is exactly what an urban infill site takes.
var barrier_out_m := 2.15
var pile_out_m := 0.95
var rig_out_m := 4.40

# ------------------------------------------------------------------- state

var sites: Dictionary = {}   # int building id -> Site
## Filled by `refresh`; the view uploads straight out of these. Pooled, never
## reallocated per frame — this layer is on the 60 Hz path.
var truck_poses: Array[Pose] = []
var rig_poses: Array[Pose] = []
var heap_poses: Array[Pose] = []
var stack_poses: Array[Pose] = []
var barrier_poses: Array[Pose] = []
var truck_used := 0
var rig_used := 0
var heap_used := 0
var stack_used := 0
var barrier_used := 0

## Set by `refresh`; the view's distance gate.
var focus := Vector3.ZERO
var focus_radius := 0.0

var _id_cache: Array = []
var _ids_dirty := true


class Pose extends RefCounted:
	var basis := Basis.IDENTITY
	var origin := Vector3.ZERO
	## The four joint channels for a rig, or (variant, 0, 0, 0) for a prop.
	var custom := Color(0.0, 0.0, 0.0, 0.0)
	## rgb = paint, a = the per-machine hash the shader turns into a beacon
	## phase and a tone skew.
	var tint := Color.WHITE

	func transform() -> Transform3D:
		return Transform3D(basis, origin)


class Site extends RefCounted:
	var id := 0
	var world_pos := Vector3.ZERO
	var footprint := Vector2i.ONE
	var height_m := 10.0
	var stage := STAGE_MIN
	## False when no road was found near the lot: no frontage, no activity.
	var frontage_ok := false
	## The frontage frame. `out` points from the lot towards the street,
	## `along` runs the kerb (out rotated +90° about Y), `edge` is the point on
	## the property line the frame is measured from.
	var out := Vector3.RIGHT
	var along := Vector3.BACK
	var edge := Vector3.ZERO
	var half_frontage := 4.0
	var road_tile := Vector2i(-1, -1)
	var depot_tile := Vector2i(-1, -1)
	## The two street-true polylines, already lane-offset and corner-rounded.
	var to_site := PackedVector3Array()
	var to_site_cum := PackedFloat32Array()
	var to_depot := PackedVector3Array()
	var to_depot_cum := PackedFloat32Array()
	var route_m := 0.0
	## Render-side high-water mark — see the class doc's "the one latch".
	var delivered := 0.0
	## `delivered` at the moment this stage started: the datum the yard is
	## measured from, so a stage consumes what it was given rather than the
	## site's whole history.
	var stage_base := 0.0
	## Per-site schedule, hashed off the id once.
	var period_gm := 46.0
	var offset_gm := 0.0
	var paint := Color.WHITE
	var hash_a := 0.0
	## Everything a frontage fixes rather than the clock: the machines' standing
	## transforms, each pile's position and yaw, and the barricade run for the
	## current stage. Rebuilt when the frontage moves (a re-route) or, for the
	## barricades, when the stage changes — never per frame. This is most of
	## what keeps the layer's per-frame cost in trig-free territory.
	var rig_xform: Array[Transform3D] = []
	var pile_origin: Array[Vector3] = []
	var pile_yaw: Array[Basis] = []
	var barrier_xform: Array[Transform3D] = []
	var barrier_stage := -1
	## Where the lorry comes to rest along the frontage, measured from `edge`
	## along `along` — the datum the plant is stood clear of.
	var stop_u := 0.0

	func has_route() -> bool:
		return to_site.size() >= 2 and route_m > 0.5


# -------------------------------------------------------------- public API

func configure(cfg: Dictionary, world_tile_m: float = 8.0) -> void:
	tile_m = world_tile_m
	truck_speed_mpgm = _num(cfg, "truck_speed_mpgm", truck_speed_mpgm)
	delivery_period_gm = maxf(6.0, _num(cfg, "delivery_period_gm", delivery_period_gm))
	dump_gm = maxf(0.5, _num(cfg, "dump_gm", dump_gm))
	dig_cycle_gm = maxf(0.5, _num(cfg, "dig_cycle_gm", dig_cycle_gm))
	pile_per_delivery = _num(cfg, "pile_per_delivery", pile_per_delivery)
	pile_consume_per_stage = _num(cfg, "pile_consume_per_stage", pile_consume_per_stage)
	pile_max_m = _num(cfg, "pile_max_m", pile_max_m)
	pile_base_m = _num(cfg, "pile_base_m", pile_base_m)
	barrier_bay_m = maxf(1.0, _num(cfg, "barrier_bay_m", barrier_bay_m))
	barrier_out_m = _num(cfg, "barrier_out_m", barrier_out_m)
	pile_out_m = _num(cfg, "pile_out_m", pile_out_m)
	rig_out_m = _num(cfg, "rig_out_m", rig_out_m)
	road_top = _num(cfg, "road_top_m", road_top)
	lane_offset = _num(cfg, "lane_offset_m", lane_offset)


## Register a site. `world_pos` is the lot CENTRE at ground level — the same
## vector doc 11 §5's BuildingView carries and `ConstructionSiteView.add_site`
## takes, so a caller passes the same three arguments to both views.
func add_site(id: int, world_pos: Vector3, footprint: Vector2i,
		height_m: float) -> Site:
	var site := Site.new()
	site.id = id
	site.world_pos = world_pos
	site.footprint = Vector2i(maxi(footprint.x, 1), maxi(footprint.y, 1))
	site.height_m = maxf(height_m, 1.0)
	site.stage = STAGE_MIN
	site.hash_a = hash01(id, 23)
	# ±25% on the cadence, so two sites on one street are never in step.
	site.period_gm = delivery_period_gm * lerpf(0.78, 1.26, hash01(id, 47))
	site.offset_gm = hash01(id, 59) * site.period_gm
	site.paint = _plant_paint(id)
	sites[id] = site
	_ids_dirty = true
	return site


func set_stage(id: int, stage: int) -> void:
	var site: Site = sites.get(id)
	if site == null:
		return
	var clamped := clampi(stage, STAGE_MIN, STAGE_MAX)
	if clamped == site.stage:
		return
	site.stage = clamped
	# The stage that just ended consumed what was delivered into it; the next
	# one starts its yard from here.
	site.stage_base = site.delivered


func remove_site(id: int) -> void:
	sites.erase(id)
	_ids_dirty = true


func clear() -> void:
	sites.clear()
	_ids_dirty = true


func site_count() -> int:
	return sites.size()


## Give a site its frontage frame and its two street-true polylines. The view
## calls this after it has asked doc 10 for the route; keeping the road lookup
## out of here is what leaves this class pure and headless-testable.
func set_route(id: int, road_tile: Vector2i, depot_tile: Vector2i,
		out_tiles: Array, home_tiles: Array) -> void:
	var site: Site = sites.get(id)
	if site == null:
		return
	site.road_tile = road_tile
	site.depot_tile = depot_tile
	_frame_frontage(site)
	site.to_site = polyline_from_tiles(out_tiles, tile_m, road_top, lane_offset)
	site.to_depot = polyline_from_tiles(home_tiles, tile_m, road_top, lane_offset)
	# The last metre is not a lane, it is a STOP. Left on the lane offset the
	# lorry ends its run on whichever side the final approach happened to make
	# "right" — half the time the far side of the street, facing away from the
	# lot it is delivering to. Both runs are pinned to the middle of the
	# frontage tile instead, which is where a tipper on a narrow street stands:
	# clear of the coned-off kerb, square to the site, and the same place every
	# time so the plant can be laid out around it.
	if site.frontage_ok and site.road_tile.x >= 0:
		var stop := Vector3((float(site.road_tile.x) + 0.5) * tile_m, road_top,
				(float(site.road_tile.y) + 0.5) * tile_m)
		if site.to_site.size() >= 2:
			site.to_site[site.to_site.size() - 1] = stop
		if site.to_depot.size() >= 2:
			site.to_depot[0] = stop
	site.to_site_cum = cumulative(site.to_site)
	site.to_depot_cum = cumulative(site.to_depot)
	site.route_m = 0.0 if site.to_site_cum.is_empty() \
			else site.to_site_cum[site.to_site_cum.size() - 1]
	# Where along the frontage the lorry comes to rest, so the plant can be
	# stood clear of it.
	site.stop_u = 0.0
	if site.to_site.size() >= 1 and site.frontage_ok:
		site.stop_u = (site.to_site[site.to_site.size() - 1] - site.edge) \
				.dot(site.along)
	_lay_out_fittings(site)


## Drop a site's routes without dropping the site — what a road edit means.
func clear_route(id: int) -> void:
	var site: Site = sites.get(id)
	if site == null:
		return
	site.to_site = PackedVector3Array()
	site.to_site_cum = PackedFloat32Array()
	site.to_depot = PackedVector3Array()
	site.to_depot_cum = PackedFloat32Array()
	site.route_m = 0.0


## Rebuild every pose array for game-minute `gm`. Sites beyond `radius` of
## `p_focus` are skipped entirely (pass radius <= 0 for no gate); the ids are
## walked in ascending order so the buffers are stable frame to frame and a
## screenshot is reproducible.
func refresh(gm: float, p_focus := Vector3.ZERO, radius := 0.0,
		limit := 0) -> void:
	focus = p_focus
	focus_radius = radius
	truck_used = 0
	rig_used = 0
	heap_used = 0
	stack_used = 0
	barrier_used = 0
	var drawn := 0
	for id: int in _ids():
		if limit > 0 and drawn >= limit:
			break
		var site: Site = sites[id]
		if radius > 0.0:
			var d := Vector2(site.world_pos.x - p_focus.x, site.world_pos.z - p_focus.z)
			if d.length() > radius:
				continue
		if not site.frontage_ok:
			continue
		drawn += 1
		_emit_barriers(site)
		_emit_piles(site, gm)
		_emit_rigs(site, gm)
		_emit_trucks(site, gm)


## Ascending building ids, cached: the buffers stay stable frame to frame (so a
## screenshot is reproducible) without sorting a dictionary's keys sixty times
## a second.
func _ids() -> Array:
	if _ids_dirty:
		_ids_dirty = false
		_id_cache = sites.keys()
		_id_cache.sort()
	return _id_cache


# ------------------------------------------------------------ the schedule

## One full delivery round trip, in game-minutes: out, dump, home.
func trip_gm(site: Site) -> float:
	if not site.has_route():
		return 0.0
	var leg := site.route_m / maxf(truck_speed_mpgm, 0.5)
	return leg * 2.0 + dump_gm


## Game-minutes the outbound leg takes.
func leg_gm(site: Site) -> float:
	return site.route_m / maxf(truck_speed_mpgm, 0.5) if site.has_route() else 0.0


## Deliveries completed by `gm`, as a CONTINUOUS number: the integer count plus
## the fraction of a dump currently draining, so the heap grows while the bed
## is up instead of snapping when it comes down. Non-decreasing in `gm` at a
## fixed route, which is the invariant the pile test pins.
func delivered_at(site: Site, gm: float) -> float:
	if not site.has_route():
		return site.delivered
	var leg := leg_gm(site)
	var newest := _newest_trip(site, gm)
	if newest < 0:
		return 0.0
	# Trips older than this have certainly finished draining; only the window
	# still in flight has to be summed.
	var first := maxi(0, newest - _trip_window(site))
	var total := float(first)
	for k in range(first, newest + 1):
		total += _drain(gm - _depart_gm(site, k) - leg)
	return total


## Index of the most recent departure at `gm`, or -1 before the first one.
func _newest_trip(site: Site, gm: float) -> int:
	return int(floor((gm - site.offset_gm) / maxf(site.period_gm, 0.001)))


func _depart_gm(site: Site, k: int) -> float:
	return site.offset_gm + float(k) * site.period_gm


## How many consecutive trips can be in flight at once — the round trip divided
## by the cadence, plus one for the partial. Capped so a pathological route
## cannot turn a per-frame loop into a per-frame problem.
func _trip_window(site: Site) -> int:
	var span := leg_gm(site) + dump_gm
	return clampi(int(ceil(span / maxf(site.period_gm, 0.001))) + 1, 1, 24)


## Fraction of a load that has left the bed `t` game-minutes into a dump. Zero
## before the bed is up, one once it is empty.
func _drain(t: float) -> float:
	return clampf((t / maxf(dump_gm, 0.001) - 0.26) / 0.46, 0.0, 1.0)


## How many of the first `delivered` loads landed in slot `i`. Delivery `k`
## goes to slot `k % PILE_SLOTS`, so slot `i` has taken `ceil((n − i) / 3)` of
## the first `n`, plus the fraction of the one currently draining if that one is
## its turn. Continuous and non-decreasing in `delivered`, which is what makes
## the growth test exact rather than approximate.
func slot_count(delivered: float, slot: int) -> float:
	var n := int(floor(maxf(delivered, 0.0)))
	var count := 0.0
	if n > slot:
		count = float((n - slot + PILE_SLOTS - 1) / PILE_SLOTS)
	if n % PILE_SLOTS == slot:
		count += maxf(delivered, 0.0) - float(n)
	return count


## Pile fill 0…1 for one slot: what has arrived into it **since the current
## stage began**, less what a stage this far along has already consumed.
##
## Measuring from the stage start rather than from the site's whole history is
## the difference between a yard that reads and a yard that does not. A running
## total minus a fixed per-stage offset saturates: a site fed for a game-day has
## delivered thirty loads, every slot is pinned at 1.0, and the heaps never move
## again for the rest of the build — which is the opposite of the read. Resetting
## the datum on every stage change gives the beat the player is meant to see:
## **the stage consumes the yard, and the next round of deliveries rebuilds it.**
## The `pile_consume_per_stage` term is what makes each rebuild smaller than the
## last, so a topping-out site has a clear kerb.
func pile_fill(site: Site, slot: int, delivered: float) -> float:
	var arrived := slot_count(delivered, slot) - slot_count(site.stage_base, slot)
	var consumed := pile_consume_per_stage * float(site.stage - STAGE_MIN)
	return clampf(arrived * pile_per_delivery - consumed, 0.0, 1.0)


## Excavators a site is running at its current stage.
func excavator_count(site: Site) -> int:
	var index := clampi(site.stage - STAGE_MIN, 0, EXCAVATORS_BY_STAGE.size() - 1)
	return int(EXCAVATORS_BY_STAGE[index])


## Live lorries for this site at `gm` — 0, 1 or 2, and never more, because a
## site whose route is long enough to overlap three trips would be a site whose
## depot is on the far side of the map.
func truck_count(site: Site, gm: float) -> int:
	if not site.has_route():
		return 0
	var total := trip_gm(site)
	var newest := _newest_trip(site, gm)
	if newest < 0:
		return 0
	var n := 0
	for k in range(maxi(0, newest - _trip_window(site)), newest + 1):
		var t := gm - _depart_gm(site, k)
		if t >= 0.0 and t <= total:
			n += 1
	return mini(n, MAX_TRUCKS_PER_SITE)


# --------------------------------------------------------------- emitters

func _emit_trucks(site: Site, gm: float) -> void:
	if not site.has_route():
		return
	var total := trip_gm(site)
	var leg := leg_gm(site)
	var hauling_out := site.stage >= CLEANUP_STAGE
	var newest := _newest_trip(site, gm)
	if newest < 0:
		return
	var live := 0
	for k in range(maxi(0, newest - _trip_window(site)), newest + 1):
		var t := gm - _depart_gm(site, k)
		if t < 0.0 or t > total:
			continue
		live += 1
		if live > MAX_TRUCKS_PER_SITE:
			break
		var pose := _take(truck_poses, truck_used)
		truck_used += 1
		var loaded := 1.0
		var tilt := 0.0
		var dist := 0.0
		var outbound := true
		if t < leg:
			dist = t * truck_speed_mpgm
			loaded = 0.0 if hauling_out else 1.0
		elif t < leg + dump_gm:
			dist = site.route_m
			var w := (t - leg) / maxf(dump_gm, 0.001)
			# Up fast, hold, down: the bed's own gesture, and the load drains
			# inside the hold so the heap and the bed move together. A lorry
			# being LOADED keeps its bed down — the load growing in it is the
			# motion, and a tipper that raises its bed to be filled is a lie
			# anyone who has stood on a site will read straight away.
			var drained := _drain(t - leg)
			if hauling_out:
				loaded = drained
			else:
				tilt = clampf(w / 0.24, 0.0, 1.0) * clampf((1.0 - w) / 0.24, 0.0, 1.0)
				loaded = 1.0 - drained
		else:
			outbound = false
			dist = (t - leg - dump_gm) * truck_speed_mpgm
			loaded = 1.0 if hauling_out else 0.0
		var line := site.to_site if outbound else site.to_depot
		var cum := site.to_site_cum if outbound else site.to_depot_cum
		var sample := sample_polyline(line, cum, dist)
		pose.origin = Vector3(sample.x, road_top, sample.z)
		pose.basis = Basis.from_euler(Vector3(0.0, -sample.w, 0.0))
		# (bed tilt, load fill, lamp, unused). The lamp channel is the view's
		# to set once it knows the night factor.
		pose.custom = Color(tilt, loaded, 0.0, 0.0)
		pose.tint = Color(site.paint.r, site.paint.g, site.paint.b,
				hash01(site.id * 131 + k, 71))


func _emit_rigs(site: Site, gm: float) -> void:
	var count := mini(excavator_count(site), site.rig_xform.size())
	for i in count:
		var pose := _take(rig_poses, rig_used)
		rig_used += 1
		var xform: Transform3D = site.rig_xform[i]
		pose.origin = xform.origin
		pose.basis = xform.basis
		# Two machines on one lot are never in the same part of the cycle.
		var phase := fposmod(gm / dig_cycle_gm + hash01(site.id, 83 + i * 11), 1.0)
		pose.custom = dig_pose(phase)
		pose.tint = Color(site.paint.r, site.paint.g, site.paint.b,
				hash01(site.id + i * 977, 29))


func _emit_piles(site: Site, gm: float) -> void:
	var delivered := delivered_at(site, gm)
	site.delivered = maxf(site.delivered, delivered)
	for slot in PILE_SLOTS:
		var fill := pile_fill(site, slot, site.delivered)
		if fill <= 0.02:
			continue
		var stack := slot == PILE_STACK_SLOT
		var pool := stack_poses if stack else heap_poses
		var used := stack_used if stack else heap_used
		var pose := _take(pool, used)
		if stack:
			stack_used += 1
		else:
			heap_used += 1
		pose.origin = site.pile_origin[slot]
		# A heap spreads as it grows: the base widens with the square root of
		# the fill, the height linearly, which is how a tipped load behaves.
		var height := pile_max_m * fill
		var base := pile_base_m * (0.52 + 0.48 * sqrt(fill))
		pose.basis = (site.pile_yaw[slot] as Basis).scaled_local(
				Vector3(base, maxf(height, 0.05), base))
		var tint := ConstructionRigMesh.SAND if slot == 0 \
				else (ConstructionRigMesh.GRAVEL if slot == 1 else ConstructionRigMesh.REBAR)
		pose.tint = Color(tint.r, tint.g, tint.b, 1.0)
		pose.custom = Color(float(slot), fill, 0.0, 0.0)


func _emit_barriers(site: Site) -> void:
	if site.barrier_stage != site.stage:
		_lay_out_barriers(site)
	for i in site.barrier_xform.size():
		var pose := _take(barrier_poses, barrier_used)
		barrier_used += 1
		var xform: Transform3D = site.barrier_xform[i]
		pose.origin = xform.origin
		pose.basis = xform.basis
		pose.tint = Color.WHITE
		pose.custom = Color(float(i), 0.0, 0.0, 0.0)


## The barricade run for this site's CURRENT stage — rebuilt on a stage change
## and on a re-route, never per frame.
func _lay_out_barriers(site: Site) -> void:
	site.barrier_stage = site.stage
	site.barrier_xform.clear()
	if not site.frontage_ok:
		return
	var span := site.half_frontage * 2.0
	# The full run is what the frontage takes; the pitch that sizes a bay comes
	# from the FULL run and never from the reduced one. Deriving the scale from
	# the reduced count instead is how the first pass ended up stretching a
	# single 2.55 m barricade across 24 m of kerb at stage 6 — one bay lifted
	# has to LOOK like one bay lifted.
	var full := clampi(int(round(span / barrier_bay_m)), 1, 12)
	var pitch := span / float(full)
	var bays := full
	# The work zone comes down as the site finishes: half the run at cleanup,
	# one token bay by the time the last lorry has gone. Bays are lifted from
	# the ENDS inward, so what is left is the middle of the run.
	if site.stage >= STAGE_MAX:
		bays = 1
	elif site.stage >= CLEANUP_STAGE:
		bays = maxi(1, full / 2)
	var first := (full - bays) / 2
	# The bay is authored with +X along its run, so it yaws to `along`. The
	# stretch is clamped: a bay is a barricade, not a fence panel.
	var basis := Basis.from_euler(Vector3(0.0,
			-atan2(site.along.z, site.along.x), 0.0)) \
			.scaled_local(Vector3(clampf(pitch / barrier_bay_m, 0.82, 1.22), 1.0, 1.0))
	for i in range(first, first + bays):
		var u := -site.half_frontage + pitch * (float(i) + 0.5)
		var origin := site.edge + site.along * u + site.out * barrier_out_m
		origin.y = road_top
		site.barrier_xform.append(Transform3D(basis, origin))


# ----------------------------------------------------------- the dig cycle

## Keyframes of one excavator cycle: `[phase, slew, boom, arm, bucket]`, every
## joint NORMALISED 0…1 across its envelope in `ConstructionRigMesh`. Reach
## out low, drag in and curl, lift, slew to the spoil side, open, slew back.
const DIG_KEYS := [
	[0.00, 0.50, 0.26, 0.88, 0.20],
	[0.20, 0.50, 0.09, 0.32, 0.86],
	[0.36, 0.50, 0.80, 0.28, 0.92],
	[0.54, 0.87, 0.74, 0.42, 0.90],
	[0.66, 0.87, 0.70, 0.50, 0.10],
	[0.84, 0.61, 0.50, 0.68, 0.16],
	[1.00, 0.50, 0.26, 0.88, 0.20],
]


## The four normalised joint channels at cycle phase `p` (0…1), smoothstepped
## between keyframes so the machine eases into and out of every move.
static func dig_pose(p: float) -> Color:
	var t := fposmod(p, 1.0)
	for i in range(DIG_KEYS.size() - 1):
		var a: Array = DIG_KEYS[i]
		var b: Array = DIG_KEYS[i + 1]
		var t0 := float(a[0])
		var t1 := float(b[0])
		if t > t1:
			continue
		var w := smoothstep(0.0, 1.0, (t - t0) / maxf(t1 - t0, 0.0001))
		return Color(lerpf(float(a[1]), float(b[1]), w),
				lerpf(float(a[2]), float(b[2]), w),
				lerpf(float(a[3]), float(b[3]), w),
				lerpf(float(a[4]), float(b[4]), w))
	var last: Array = DIG_KEYS[DIG_KEYS.size() - 1]
	return Color(float(last[1]), float(last[2]), float(last[3]), float(last[4]))


# ------------------------------------------------------------- the streets

## Doc 10's tile polyline as a drivable world-space line: tile centres lifted
## to the road surface, pushed `lane_offset` metres to the RIGHT of the
## centreline so a lorry going out and a lorry coming back pass properly, then
## corner-rounded twice so a 90° junction is a turn rather than a pivot.
static func polyline_from_tiles(tiles: Array, tile_m: float, road_y: float,
		lane_offset: float) -> PackedVector3Array:
	var n := tiles.size()
	var out := PackedVector3Array()
	if n == 0:
		return out
	var centres := PackedVector3Array()
	centres.resize(n)
	for i in n:
		var t: Vector2i = tiles[i]
		centres[i] = Vector3((float(t.x) + 0.5) * tile_m, road_y,
				(float(t.y) + 0.5) * tile_m)
	if n == 1:
		out.append(centres[0])
		return out
	var offset := PackedVector3Array()
	offset.resize(n)
	for i in n:
		var back: Vector3 = centres[i] - centres[maxi(i - 1, 0)]
		var fore: Vector3 = centres[mini(i + 1, n - 1)] - centres[i]
		var dir := (back + fore)
		if dir.length() < 0.0001:
			dir = fore if fore.length() > 0.0001 else back
		dir = dir.normalized()
		# `forward × up` in Godot's Y-up basis — the same right-hand side
		# `VehicleMotion.right_xz` uses, so this layer keeps to the same lane
		# as doc 10's traffic.
		var right := Vector3(-dir.z, 0.0, dir.x)
		offset[i] = centres[i] + right * lane_offset
	return chaikin(chaikin(offset))


## One Chaikin corner-cut, endpoints preserved.
static func chaikin(line: PackedVector3Array) -> PackedVector3Array:
	var n := line.size()
	if n < 3:
		return line
	var out := PackedVector3Array()
	out.append(line[0])
	for i in range(n - 1):
		var a: Vector3 = line[i]
		var b: Vector3 = line[i + 1]
		out.append(a * 0.75 + b * 0.25)
		out.append(a * 0.25 + b * 0.75)
	out.append(line[n - 1])
	return out


## Running length along a polyline; `cum[i]` is the distance to `line[i]`.
static func cumulative(line: PackedVector3Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := line.size()
	out.resize(n)
	if n == 0:
		return out
	out[0] = 0.0
	for i in range(1, n):
		out[i] = out[i - 1] + line[i].distance_to(line[i - 1])
	return out


## Position and heading `distance` metres along the line, as
## `(x, y, z, heading)`. Clamped at both ends, so a lorry that has run out of
## route simply stands at the kerb rather than flying off it.
static func sample_polyline(line: PackedVector3Array, cum: PackedFloat32Array,
		distance: float) -> Vector4:
	var n := line.size()
	if n == 0:
		return Vector4(0.0, 0.0, 0.0, 0.0)
	if n == 1:
		return Vector4(line[0].x, line[0].y, line[0].z, 0.0)
	var total: float = cum[n - 1]
	var d := clampf(distance, 0.0, total)
	# Binary search rather than a walk: a 160-point route sampled twice a frame
	# for twenty sites is 5,000 comparisons a frame if walked and 80 if not.
	var lo := 0
	var hi := n - 1
	while lo + 1 < hi:
		var mid := (lo + hi) / 2
		if cum[mid] <= d:
			lo = mid
		else:
			hi = mid
	var span: float = maxf(cum[hi] - cum[lo], 0.0001)
	var w := clampf((d - cum[lo]) / span, 0.0, 1.0)
	var p: Vector3 = line[lo].lerp(line[hi], w)
	var dir: Vector3 = line[hi] - line[lo]
	var heading := atan2(dir.z, dir.x) if dir.length() > 0.0001 else 0.0
	return Vector4(p.x, p.y, p.z, heading)


# ------------------------------------------------------------------ helpers

## The frontage frame: which way the street is, and where the property line
## meets it. Derived from the nearest ROAD TILE, so it is a pure function of
## published sim state.
func _frame_frontage(site: Site) -> void:
	if site.road_tile.x < 0:
		site.frontage_ok = false
		return
	var road := Vector3((float(site.road_tile.x) + 0.5) * tile_m, 0.0,
			(float(site.road_tile.y) + 0.5) * tile_m)
	var d := road - site.world_pos
	var half := Vector2(float(site.footprint.x) * tile_m * 0.5,
			float(site.footprint.y) * tile_m * 0.5)
	if absf(d.x) >= absf(d.z):
		site.out = Vector3(signf(d.x) if absf(d.x) > 0.0001 else 1.0, 0.0, 0.0)
		site.edge = site.world_pos + site.out * half.x
		site.half_frontage = half.y
	else:
		site.out = Vector3(0.0, 0.0, signf(d.z) if absf(d.z) > 0.0001 else 1.0)
		site.edge = site.world_pos + site.out * half.y
		site.half_frontage = half.x
	site.along = Vector3(-site.out.z, 0.0, site.out.x)
	site.edge.y = 0.0
	site.frontage_ok = true


## Everything the frontage fixes: where the two machines stand and where the
## three piles sit. Computed once per route, not sixty times a second — the
## clock moves the bucket and the heap's height, not the ground under them.
func _lay_out_fittings(site: Site) -> void:
	site.rig_xform.clear()
	for i in 2:
		# Machines stand off the kerb at 44° to the property line: square to the
		# street would block both lanes, square to the lot would put the tracks
		# across the footway. 44° reaches over the hoarding and keeps the
		# undercarriage inside the near lane.
		var side := -1.0 if i % 2 == 0 else 1.0
		# Stood off the LORRY'S OWN STOP, not off the middle of the frontage:
		# the stop is wherever the street ends up, and a machine placed by the
		# frontage alone ends up parked inside the lorry about a third of the
		# time. `RIG_CLEARANCE_M` is half a tipper plus half an excavator plus a
		# metre of daylight.
		var reach := maxf(site.half_frontage * 0.55, 2.0) + RIG_CLEARANCE_M
		# Clamped back towards the lot, so a stop that landed well off the
		# frontage cannot walk the plant onto somebody else's street.
		var u := clampf(site.stop_u + side * reach,
				-site.half_frontage - reach, site.half_frontage + reach)
		# Facing the LOT and turned back towards its middle: a machine parked at
		# one end of the frontage looks along it, not out at the neighbour's
		# garden, so the boom reaches the site rather than away from it. Hence
		# `-side` on the along term.
		var forward := (-site.out * 0.72 - site.along * (0.69 * side)).normalized()
		var origin := site.edge + site.along * u + site.out * rig_out_m
		origin.y = road_top
		site.rig_xform.append(Transform3D(Basis.from_euler(Vector3(0.0,
				-atan2(forward.z, forward.x), 0.0)), origin))
	site.pile_origin.clear()
	site.pile_yaw.clear()
	for slot in PILE_SLOTS:
		# Slots sit along the property line, clear of the machines at either
		# end of the frontage.
		var u2 := lerpf(-0.34, 0.34, float(slot) / float(PILE_SLOTS - 1)) \
				* site.half_frontage * 2.0
		var p := site.edge + site.along * u2 + site.out * pile_out_m
		p.y = 0.0
		site.pile_origin.append(p)
		site.pile_yaw.append(Basis.from_euler(Vector3(0.0,
				hash01(site.id, 137 + slot) * TAU, 0.0)))
	# The barricade run depends on the stage too; force a rebuild.
	site.barrier_stage = -1


## Grow a pose pool on demand and hand back slot `index`. Pools never shrink:
## the churn is what this exists to avoid.
static func _take(pool: Array[Pose], index: int) -> Pose:
	while pool.size() <= index:
		pool.append(Pose.new())
	return pool[index]


## Plant paint. Four liveries, picked off the building id — a city's plant
## comes from more than one hire company, and the shader's tone skew makes two
## machines on the same livery still not the same machine.
##
## All four are SATURATED on purpose. Plant hire really does field white and
## grey machines, and a near-neutral livery over a near-neutral steel page is a
## machine the player cannot pick out of a grey street at all: the first pass
## shipped a pale grey in this table and the site read as rubble. "Construction
## is high-visibility" is the language, and it is worth more here than the
## catalogue's full range.
static func _plant_paint(id: int) -> Color:
	const LIVERY := ["#E3A423", "#D2601F", "#2F6E52", "#3D6B92"]
	var index := int(hash01(id, 191) * float(LIVERY.size()))
	return Color(String(LIVERY[clampi(index, 0, LIVERY.size() - 1)]))


static func _num(cfg: Dictionary, key: String, fallback: float) -> float:
	return float(cfg.get(key, fallback))


## Deterministic per-site jitter — the same yard on every run, every device and
## after every load. The same mixer `ConstructionSiteView` and `VehicleMotion`
## use, so a site's crane phase and its lorry cadence come from one family.
static func hash01(id: int, salt: int) -> float:
	var h: int = absi((id * 73856093) ^ (salt * 19349663)) % 100003
	return float(h) / 100003.0

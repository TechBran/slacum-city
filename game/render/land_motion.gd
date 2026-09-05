class_name LandMotion
extends RefCounted
## **THE WORK MOVING** (doc 11 §2.19, ruling doc 93 §BB) — machines that cross a
## developing block, and the crews that walk beside them.
##
## *The player, 2026-09-05, after playing the merged build: "For the land
## excavation … the construction crews, big bulldozers and things like that, need
## to go to clear the land so we can actually see something happening. The
## animation you have — I see it's not bad — but we need to actually show
## MOVEMENT over there. Construction crews, building, clearing land, building
## roads."*
##
## Wave 25 shipped the dressing (doc 11 §2.18) and its own docstring named the
## defect this file exists to close: *"No sim clock: this layer animates nothing
## — it re-reads its own active set at 4 Hz and re-uploads only when something
## moved."* A block being dug out was a still life of stakes, scrub and spoil
## that changed between polls. This is the verb.
##
## ── THE TWO CLOCKS, and which one drives what ────────────────────────────
##
## Everything here is a pure function of published sim state plus a clock, and
## there are exactly two clocks, deliberately:
##
##   **PROGRESS** — `ConstructionQueue.progress(job_id)`, 0…1 through the phase.
##   It drives every POSITION ALONG A PASS: where the dozer is in its sweep,
##   where the paver's screed is, how far the trench has opened. That is what
##   makes a load, a catch-up or an `--advance-hours` put the machine exactly
##   where the save says it is — the save stores the work units, and the work
##   units *are* the position.
##
##   **GAME-MINUTES** — `GameClock.game_seconds() / 60`, the same clock doc 11
##   §2.16's plant runs on. It drives every CYCLE: the excavator's dig, the
##   roller's drum, the haul lorry's shuttle, a crew's walk. Cycles run three
##   times as fast at 3× and stand still while paused, exactly as the plant does.
##
## Nothing is persisted, nothing is integrated across frames that is not also
## re-derivable from those two numbers, and no RNG is drawn. Every choice about
## which machine, which livery, which crew member stands and which walks is a
## hash of the block id and an index (`hash01`, the same mixer
## `ConstructionActivity` and `LandWorksView` use), so a block looks the same on
## every device and after every load and **the sim's state hash cannot move
## because this file exists** (constitution §3).
##
## ── THE PASSES ───────────────────────────────────────────────────────────
##
## | phase | the pass | what it leaves behind |
## |---|---|---|
## | SURVEY | none — two figures on the boundary | nothing; the block is untouched |
## | CLEARING | two dozers, each sweeping its own half of the block in `DOZER_STRIPS` strips, outside in | **the brush in the strip they have covered is gone** — `sweep_of()` is the order, and `LandWorksView` keeps a clump iff its own sweep coordinate is still ahead of the dozers |
## | GRADING | an excavator working the spoil heaps with a dig cycle; a tipper shuttling heap → frontage → back | the heaps grow with the cut |
## | ROAD_INSTALL | a paver crawling the six template runs, a roller two segments behind it | **the base appears BEHIND the screed** — `pave_state()` returns the machine's pose and the number of segments laid from one walk, so the strip cannot disagree with the machine that laid it |
## | UTILITY_CORRIDOR | a trencher cutting down the collector line | the trench opens behind it and **the staged pipe is consumed as it passes** |
## | FINAL_DEVELOPMENT | a slipform kerb machine on the same runs | the kerbs |
##
## And separately from any block: **a player-laid road run gets built.** Doc 10
## does not stamp a road instantly — `CitySim.cmd_place_road` submits an
## ordinary `ConstructionQueue` job with `road_crew` and crew-hours, the tiles
## enter the grid at `under_construction_seed` condition under a
## `construction_new` closure, and `road_built` is emitted when the job
## completes. So the paver-and-roller pass over a fresh run is not a decoration
## over an instant edit: it is the *same* job's progress, drawn.
##
## ── THE ARRIVAL ──────────────────────────────────────────────────────────
##
## A dozer that appears out of nowhere is a pop; one that drives up the road and
## turns onto the lot is a story. The first `ARRIVE_FRAC` of every phase is the
## machine ARRIVING, on the last `ARRIVAL_LEAD_M` of the very polyline doc 11
## §2.16's lorries already drive to this block's frontage — `to_site`, street-true
## and lane-offset, resolved by `ConstructionVehicleView` through
## `RoadNetwork.route_tiles()` — followed by one straight leg from the kerb onto
## the pass start. A block with no street in reach gets no arrival and no haul
## lorry, and its machines simply begin their pass, which is the same honest
## answer `ConstructionActivity.frontage_ok` already gives.
##
## **The arrival is paid for out of the pass, not added to it**: `pass_progress()`
## rescales 0…1 of the phase onto `ARRIVE_FRAC`…1, so the brush does not start
## disappearing before the dozer has reached it and the base does not appear
## before the paver has arrived. That one function is why the machine and the
## ground it changes can never drift apart.

# --------------------------------------------------------------- the geometry

const TILES_PER_BLOCK := 16
## Metres inside the lot line the machines work to. It is the SAME inset
## `LandWorksView._scatter_brush` scatters within, on purpose: the dozers' work
## rectangle IS the brush field, so no clump can ever sit outside the sweep and
## survive a completed clearing.
const WORK_INSET_M := 5.0
## Dozers on a clearing, and strips each one takes across its own half. Two × 3
## is six passes over a 128 m block: wide enough that a strip reads as a strip
## at the city camera, narrow enough that the block visibly empties in bands.
const DOZERS := 2
const DOZER_STRIPS := 3

## Fraction of a phase spent arriving. At 0.10 a machine driving the last 72 m
## of street plus the turn onto the lot takes about a tenth of the phase, which
## at doc 09 §2.3's shortest phase is minutes of game time and at its longest is
## most of an hour — either way it is over before the player looks away.
const ARRIVE_FRAC := 0.10
## Metres of the frontage route the arrival is drawn on. A whole route would put
## the machine on the far side of the city for most of the arrival; 72 m is
## nine tiles, which is a street and a turn.
const ARRIVAL_LEAD_M := 72.0

## Segments each template run is laid in. **Owned here, read by
## `LandWorksView`**, because the number of segments is what turns the paver's
## position into a count of slabs — two constants would be two answers.
const PAVE_SEGMENTS := 6
## Metres the roller trails the paver by. One machine length, which is how close
## a roller actually follows a screed.
const ROLLER_LAG_M := 11.0

## Crew figures per phase, in doc 09 §2.3's phase order. SURVEY is two people
## and a tripod; UTILITY_CORRIDOR is the one phase with men in a hole and men on
## the pipe, which is why it is the only four.
const CREW_BY_PHASE: Array[int] = [2, 3, 3, 3, 4, 3]
## Crew on a player-laid road run: a screed man, a raker and a banksman.
const CREW_PER_ROAD_RUN := 3
## Radius of the little circuit a walking figure keeps. A crew member is not
## commuting; they are working a machine.
const CREW_LOOP_M := 2.4
## Metres a crew figure stands off the machine it is working with.
const CREW_STANDOFF_M := 6.2
## Fraction of crew figures that STAND rather than walk. Hashed per figure, so
## the same block always has the same men standing.
const CREW_STAND_FRAC := 0.38

## Barricade bays at the working end of a player-laid road run.
const RUN_BARRIER_BAYS := 3
const RUN_BARRIER_PITCH_M := 2.55

# ---------------------------------------------------------------- the tuning
#
# Read from `data/render.json.land_motion`; the constants above are structure
# and these are pace. Every one is in GAME-MINUTES, which is what makes the
# whole layer obey the speed multiplier and the pause without a special case.

## Game-minutes one excavator dig cycle takes. Defaulted from doc 11 §2.16's own
## number so a machine on a land block and a machine on a building site are not
## two different excavators.
var dig_cycle_gm := 7.0
## Game-minutes for one heap → frontage → heap haul shuttle.
var haul_cycle_gm := 26.0
## Game-minutes of one crew pace. At 1× a game-minute is a real second, so this
## is a stride a little under a second.
var crew_step_gm := 0.92
## Game-minutes for one lap of a walking figure's circuit.
var crew_loop_gm := 21.0
## Metres per game-minute the roller's drum surface covers. It is not a speed —
## the roller's POSITION comes from the job's progress — it is the gearing
## between distance covered and drum rotation, i.e. the drum's circumference.
var drum_circumference_m := 5.15

var tile_m := 8.0
var road_top := 0.10

# ------------------------------------------------------------------ the state

var sites: Dictionary = {}         # block_id -> Site
var runs: Dictionary = {}          # job_id -> Run

## Pose pools, exactly `ConstructionActivity`'s discipline: pooled, never
## reallocated per frame, and the view uploads straight out of them.
var dozer_poses: Array[ConstructionActivity.Pose] = []
var exc_poses: Array[ConstructionActivity.Pose] = []
var tipper_poses: Array[ConstructionActivity.Pose] = []
var paver_poses: Array[ConstructionActivity.Pose] = []
var roller_poses: Array[ConstructionActivity.Pose] = []
var crew_poses: Array[ConstructionActivity.Pose] = []
var barrier_poses: Array[ConstructionActivity.Pose] = []
var dozer_used := 0
var exc_used := 0
var tipper_used := 0
var paver_used := 0
var roller_used := 0
var crew_used := 0
var barrier_used := 0

## **A SCALE on each phase's own want, not a ceiling.** `CREW_BY_PHASE` says how
## many men a phase takes and the preset says how generous the device is being;
## a flat ceiling would have made `quality` a number with no reader, because no
## phase wants more than four and a ceiling of five could never bind (doc 93
## §AZ2's rule about bounds, applied to a render knob). The governor multiplies
## this further, and a site never falls below one figure — a machine on a block
## with nobody there reads as abandoned plant.
var crew_scale := 1.0
## When false the layer draws only the phase's PRIMARY machine — the dozer, the
## excavator, the paver — and drops the tipper and the roller, which is the order
## doc 11 §2.19 publishes and the governor follows.
var secondary := true
## Spoil heaps the dressing raises on a block — pushed by the view from its own
## `spoil_per_block` budget, because the GRADING excavator works the heap that is
## currently growing and has to agree with the layer that draws them.
var spoil_slots := 6


class Site extends RefCounted:
	var block_id := ""
	var salt := 0
	var centre := Vector3.ZERO
	## Half the block, in metres — 64 on an 8 m tile.
	var half := 64.0
	var phase_index := 0
	var progress := 0.0
	## The frontage frame and the approach route, borrowed READ-ONLY off doc 11
	## §2.16's plant site for this block. Null when the block has no street in
	## reach, or when no plant layer is wired at all (a preview harness, a
	## headless test) — in which case there is no arrival and no haul lorry.
	var plant: ConstructionActivity.Site = null
	## Everything the PHASE fixes rather than the clock: the six template runs
	## and their legs, the trench line, the spoil positions. Rebuilt on a phase
	## change and never per frame — the RR-42 discipline, applied to the one
	## thing on this layer that is expensive to derive.
	var layout_phase := -1
	var run_legs: Array[Dictionary] = []
	var run_total := 0.0
	var trench_a := Vector3.ZERO
	var trench_b := Vector3.ZERO


class Run extends RefCounted:
	var job_id := 0
	var salt := 0
	var progress := 0.0
	## Tile centres, lifted to the road surface, in the order doc 10 sorted them.
	var points := PackedVector3Array()
	var cum := PackedFloat32Array()
	var total := 0.0


# ------------------------------------------------------------------- tuning

func configure(cfg: Dictionary, plant_cfg: Dictionary = {},
		world_tile_m: float = 8.0, road_top_m: float = 0.10) -> void:
	tile_m = world_tile_m
	road_top = road_top_m
	# The dig cycle DEFAULTS to the plant layer's own tuning and may be
	# overridden here. One excavator, one cycle length, unless somebody
	# deliberately says otherwise.
	dig_cycle_gm = maxf(0.5, _num(cfg, "dig_cycle_gm",
			_num(plant_cfg, "dig_cycle_gm", dig_cycle_gm)))
	haul_cycle_gm = maxf(2.0, _num(cfg, "haul_cycle_gm", haul_cycle_gm))
	crew_step_gm = maxf(0.15, _num(cfg, "crew_step_gm", crew_step_gm))
	crew_loop_gm = maxf(2.0, _num(cfg, "crew_loop_gm", crew_loop_gm))
	drum_circumference_m = maxf(0.5,
			_num(cfg, "drum_circumference_m", drum_circumference_m))


# -------------------------------------------------------------- membership

## Add or move a block. `phase_index` is doc 09 §2.3's own order, 0…5.
func set_site(block_id: String, centre: Vector3, phase_index: int,
		progress: float) -> Site:
	var site: Site = sites.get(block_id)
	if site == null:
		site = Site.new()
		site.block_id = block_id
		site.salt = absi(hash(block_id))
		sites[block_id] = site
	site.centre = centre
	site.half = float(TILES_PER_BLOCK) * tile_m * 0.5
	if site.phase_index != phase_index:
		site.phase_index = phase_index
		site.layout_phase = -1
	site.progress = clampf(progress, 0.0, 1.0)
	return site


func drop_site(block_id: String) -> void:
	sites.erase(block_id)


## The plant site whose frontage and route this block's arrivals are drawn on.
## Read-only; pass `null` to say there is no street.
func set_site_plant(block_id: String, plant: ConstructionActivity.Site) -> void:
	var site: Site = sites.get(block_id)
	if site != null:
		site.plant = plant


## A player-laid road run enters the layer. `tiles` is doc 10's own durable
## record (`RoadNetwork.job_record(job_id)["tiles"]`), not the payload copy that
## a save degrades to text.
func set_run(job_id: int, tiles: Array, progress: float) -> Run:
	var run: Run = runs.get(job_id)
	if run == null:
		run = Run.new()
		run.job_id = job_id
		run.salt = absi(job_id * 2654435761)
		runs[job_id] = run
	if run.points.is_empty() and not tiles.is_empty():
		run.points = _tile_line(tiles)
		run.cum = ConstructionActivity.cumulative(run.points)
		run.total = 0.0 if run.cum.is_empty() else run.cum[run.cum.size() - 1]
	run.progress = clampf(progress, 0.0, 1.0)
	return run


func drop_run(job_id: int) -> void:
	runs.erase(job_id)


func clear() -> void:
	sites.clear()
	runs.clear()
	_zero()


func site_count() -> int:
	return sites.size()


func run_count() -> int:
	return runs.size()


# -------------------------------------------------------------- the refresh

## Rebuild every pose array for game-minute `gm`. `radius <= 0` means no gate;
## `limit <= 0` means no ceiling. Ids are walked in sorted order so the buffers
## are stable frame to frame and a screenshot is reproducible.
func refresh(gm: float, focus := Vector3.ZERO, radius := 0.0,
		limit := 0) -> void:
	_zero()
	var ids: Array = sites.keys()
	ids.sort()
	var drawn := 0
	for block_id: String in ids:
		if limit > 0 and drawn >= limit:
			break
		var site: Site = sites[block_id]
		if radius > 0.0 and site.centre.distance_to(focus) > radius:
			continue
		drawn += 1
		_ensure_layout(site)
		_emit_site(site, gm)
	var job_ids: Array = runs.keys()
	job_ids.sort()
	for job_id: int in job_ids:
		var run: Run = runs[job_id]
		if run.total <= 0.01:
			continue
		if radius > 0.0 and _run_head(run).distance_to(focus) > radius:
			continue
		_emit_run(run, gm)


func census() -> Dictionary:
	return {"dozer": dozer_used, "excavator": exc_used, "tipper": tipper_used,
			"paver": paver_used, "roller": roller_used, "crew": crew_used,
			"barrier": barrier_used, "sites": sites.size(), "runs": runs.size()}


# =========================================================================
# THE PASS RULES — every one of these is static and pure, because they are
# read by BOTH this file (to place a machine) and `LandWorksView` (to place
# the ground the machine changed). A rule with two implementations is a
# machine that floats over its own strip.
# =========================================================================

## The phase's progress rescaled onto the pass: 0 while the machine is still
## arriving, then 0…1 across the work itself. Everything a machine LAYS OR
## REMOVES is measured with this, and nothing else is.
static func pass_progress(progress: float) -> float:
	return clampf((clampf(progress, 0.0, 1.0) - ARRIVE_FRAC)
			/ maxf(1.0 - ARRIVE_FRAC, 0.0001), 0.0, 1.0)


## How far into its arrival a machine is, 0…1, or 1 once it is working.
static func arrive_progress(progress: float) -> float:
	return clampf(clampf(progress, 0.0, 1.0) / ARRIVE_FRAC, 0.0, 1.0)


## Where one scrub clump sits, local to the block centre. **The single source**:
## `LandWorksView._scatter_brush` places clumps here and `sweep_of` decides when
## a dozer has been over them, so the two cannot drift.
static func brush_local(salt: int, index: int, half: float) -> Vector2:
	var span := half - WORK_INSET_M
	return Vector2(
			lerpf(-span, span, hash01(salt, 101 + index * 7)),
			lerpf(-span, span, hash01(salt, 211 + index * 13)))


## Where one spoil heap sits, local to the block centre — the same single-source
## rule, and what puts the GRADING excavator beside the heap it is building.
static func spoil_local(salt: int, index: int, half: float) -> Vector2:
	return Vector2(
			lerpf(-half + 12.0, half - 12.0, hash01(salt, 601 + index * 11)),
			lerpf(-half + 12.0, half - 12.0, hash01(salt, 701 + index * 17)))


## **THE CLEARING ORDER**, 0…1: where a point on the block falls in the two
## dozers' sweep. Each dozer owns half the block and works it OUTSIDE IN in
## `DOZER_STRIPS` strips, reversing along Z at the end of each strip — a
## serpentine, which is how a block actually gets cleared and what makes the
## brush go in bands rather than at random.
##
## A clump is still standing exactly while `sweep_of(clump) > pass_progress`.
static func sweep_of(local: Vector2, half: float) -> float:
	var work := maxf(half - WORK_INSET_M, 1.0)
	# 0 at the block's outer edge, 1 at its centre line.
	var u := 1.0 - clampf(absf(local.x) / work, 0.0, 1.0)
	var strip := clampi(int(u * float(DOZER_STRIPS)), 0, DOZER_STRIPS - 1)
	var v := clampf((local.y + work) / (2.0 * work), 0.0, 1.0)
	# Every other strip is run the other way — that is what a serpentine is.
	var along := v if strip % 2 == 0 else 1.0 - v
	return clampf((float(strip) + along) / float(DOZER_STRIPS), 0.0, 1.0)


## Where dozer `index` stands at pass-progress `q`, and which way it faces.
## Returns `{"pos": Vector3, "dir": Vector3}` in world space.
static func dozer_pose(centre: Vector3, half: float, index: int,
		q: float) -> Dictionary:
	var work := maxf(half - WORK_INSET_M, 1.0)
	var f := clampf(q, 0.0, 1.0) * float(DOZER_STRIPS)
	var strip := clampi(int(f), 0, DOZER_STRIPS - 1)
	var along := clampf(f - float(strip), 0.0, 1.0)
	var v := along if strip % 2 == 0 else 1.0 - along
	# Strip `s` is the band |x| ∈ work·[1−(s+1)/S, 1−s/S]; the machine runs its
	# middle. `side` is which half of the block this dozer owns.
	var side := -1.0 if index % 2 == 0 else 1.0
	var x := side * work * (1.0 - (float(strip) + 0.5) / float(DOZER_STRIPS))
	var z := lerpf(-work, work, v)
	var dir := Vector3(0.0, 0.0, 1.0) if strip % 2 == 0 else Vector3(0.0, 0.0, -1.0)
	return {"pos": centre + Vector3(x, 0.0, z), "dir": dir}


## The six runs of doc 10's block template in world space — four boundary
## avenues and the two collector lines. **Moved here from `LandWorksView`**, so
## the paver's pass and the base it lays come out of one function.
static func template_runs(centre: Vector3, half: float,
		tile_m_v: float) -> Array[Dictionary]:
	var edge := half - tile_m_v * 0.5
	var collector := collector_offset(tile_m_v)
	var avenue_w := tile_m_v
	var street_w := tile_m_v * 0.75
	var out: Array[Dictionary] = []
	out.append({"a": centre + Vector3(-edge, 0.0, -edge),
			"b": centre + Vector3(edge, 0.0, -edge), "w": avenue_w})
	out.append({"a": centre + Vector3(edge, 0.0, -edge),
			"b": centre + Vector3(edge, 0.0, edge), "w": avenue_w})
	out.append({"a": centre + Vector3(edge, 0.0, edge),
			"b": centre + Vector3(-edge, 0.0, edge), "w": avenue_w})
	out.append({"a": centre + Vector3(-edge, 0.0, edge),
			"b": centre + Vector3(-edge, 0.0, -edge), "w": avenue_w})
	out.append({"a": centre + Vector3(-edge, 0.0, collector),
			"b": centre + Vector3(edge, 0.0, collector), "w": street_w})
	out.append({"a": centre + Vector3(collector, 0.0, -edge),
			"b": centre + Vector3(collector, 0.0, edge), "w": street_w})
	return out


## Metres from the block centre to the collector line. `TEMPLATE_COLLECTOR_INDEX`
## is a LOCAL tile index (7 of 0…15), so the offset is measured from the block's
## own middle rather than restated as a number.
static func collector_offset(tile_m_v: float) -> float:
	return (float(RoadNetwork.TEMPLATE_COLLECTOR_INDEX) + 0.5
			- float(TILES_PER_BLOCK) * 0.5) * tile_m_v


## The runs turned into a walk: a LAY leg for each run and a TRAVEL leg for each
## reposition between them. The distinction is the whole trick — while the
## machine is repositioning from one run to the next, the strip behind it stops
## growing, which is exactly what happens on a site and is what stops the base
## appearing on a run the paver has not reached.
static func legs_of(template: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r in template.size():
		var a: Vector3 = template[r]["a"]
		var b: Vector3 = template[r]["b"]
		out.append({"a": a, "b": b, "len": a.distance_to(b), "lay": true})
		if r + 1 < template.size():
			var next_a: Vector3 = template[r + 1]["a"]
			var travel := b.distance_to(next_a)
			if travel > 0.01:
				out.append({"a": b, "b": next_a, "len": travel, "lay": false})
	return out


static func legs_total(legs: Array[Dictionary]) -> float:
	var total := 0.0
	for leg: Dictionary in legs:
		total += float(leg["len"])
	return total


## **ONE WALK, TWO ANSWERS**: where the machine is, and how many segments are
## down behind it. Returns
## `{"pos", "dir", "laid" (int), "laying" (bool)}`.
##
## `laid` is what `LandWorksView._lay_pave` writes, and it is FLOORED rather than
## rounded: a segment appears once the screed has passed its far end, never
## before. Rounding would put half a segment in front of the machine, which at
## the city camera is a metre of blacktop with nothing laying it.
static func pave_state(legs: Array[Dictionary], total: float, segments: int,
		fill: float) -> Dictionary:
	var seg := maxi(1, segments)
	var lay_legs := 0
	for leg: Dictionary in legs:
		if bool(leg["lay"]):
			lay_legs += 1
	if legs.is_empty() or total <= 0.01:
		return {"pos": Vector3.ZERO, "dir": Vector3.RIGHT, "laid": 0, "laying": false}
	var d := maxf(total, 0.0001) * clampf(fill, 0.0, 1.0)
	var laid := 0
	for leg: Dictionary in legs:
		var length := float(leg["len"])
		var lay := bool(leg["lay"])
		if d >= length:
			d -= length
			if lay:
				laid += seg
			continue
		var w := d / maxf(length, 0.0001)
		if lay:
			laid += int(floor(w * float(seg)))
		var a: Vector3 = leg["a"]
		var b: Vector3 = leg["b"]
		return {"pos": a.lerp(b, w), "dir": (b - a).normalized(),
				"laid": laid, "laying": lay}
	var last: Dictionary = legs[legs.size() - 1]
	var la: Vector3 = last["a"]
	var lb: Vector3 = last["b"]
	return {"pos": lb, "dir": (lb - la).normalized(),
			"laid": lay_legs * seg, "laying": false}


## The trench line for one block: from the block's own west edge in along the
## collector to the CENTRE, which is where `CitySim._extend_utility_corridor`
## runs the lateral.
static func trench_line(centre: Vector3, half: float,
		tile_m_v: float) -> Array[Vector3]:
	var off := collector_offset(tile_m_v)
	return [centre + Vector3(-half + 1.0, 0.0, off), centre + Vector3(0.0, 0.0, off)]


## Segments of trench open at pass-progress `q`. Floored for the same reason
## `pave_state` floors: the cut stops at the machine cutting it.
static func trench_dug(segments: int, q: float) -> int:
	return clampi(int(floor(float(maxi(1, segments)) * clampf(q, 0.0, 1.0))),
			0, maxi(1, segments))


# =========================================================================
# THE EMITTERS
# =========================================================================

func _emit_site(site: Site, gm: float) -> void:
	var q := pass_progress(site.progress)
	var arriving := site.progress < ARRIVE_FRAC
	match site.phase_index:
		0:
			_crew_at(site, gm, _survey_anchor(site), CREW_BY_PHASE[0])
		1:
			_emit_clearing(site, gm, q, arriving)
		2:
			_emit_grading(site, gm, q, arriving)
		3:
			_emit_road_install(site, gm, q, arriving)
		4:
			_emit_utility(site, gm, q, arriving)
		5:
			_emit_final(site, gm, q, arriving)


func _emit_clearing(site: Site, gm: float, q: float, arriving: bool) -> void:
	var lead := Vector3.ZERO
	for i in DOZERS:
		var pose_at: Dictionary = dozer_pose(site.centre, site.half, i, q)
		var pos: Vector3 = pose_at["pos"]
		var dir: Vector3 = pose_at["dir"]
		if arriving:
			# The second machine is a shade behind the first, so a pair arriving
			# up the same street is a convoy rather than one lorry drawn twice.
			var drive := _arrival(site, pos,
					clampf(arrive_progress(site.progress) - 0.13 * float(i), 0.0, 1.0))
			pos = drive["pos"]
			dir = drive["dir"]
		if i == 0:
			lead = pos
		var pose := _take(dozer_poses, dozer_used)
		dozer_used += 1
		pose.origin = Vector3(pos.x, 0.0, pos.z)
		pose.basis = _yaw_to(dir)
		# The blade rides low through the cut and lifts to carry the spill over
		# the windrow — one cycle a strip, plus a per-machine offset.
		var blade := 0.30 + 0.42 * (0.5 + 0.5 * sin(TAU * (gm / (dig_cycle_gm * 1.6)
				+ hash01(site.salt, 811 + i * 13))))
		pose.custom = Color(clampf(blade, 0.0, 1.0), 0.0, 0.0, 0.0)
		pose.tint = _livery(site.salt, 41 + i * 7)
	_crew_at(site, gm, lead, CREW_BY_PHASE[1])


func _emit_grading(site: Site, gm: float, q: float, arriving: bool) -> void:
	# **Beside the heap that is currently GROWING, and it WALKS to the next one.**
	#
	# `LandWorksView._heap_spoil` raises `round(budget × progress)` heaps in index
	# order off the RAW progress, so the newest is that count minus one — the raw
	# progress here for the same reason: a machine measured on the PASS would
	# stand at a heap the dressing has not raised yet, alone in the middle of a
	# graded plane.
	#
	# The walk is the second half of the rule and it is not cosmetic. Snapping to
	# the newest heap put the machine 119 m away in one step (measured), which at
	# 1× is an excavator vanishing and reappearing across the block every fifty
	# seconds. `round` flips at `built + 1.5`, so the machine spends the first
	# HALF of each heap's span parked beside it and the second half tracking
	# across, ARRIVING exactly as it flips — continuous in progress, with no
	# latch and nothing remembered.
	var heaps := maxi(1, spoil_slots)
	var t := clampf(site.progress, 0.0, 1.0) * float(heaps)
	var built := clampi(int(round(t)) - 1, 0, heaps - 1)
	var next_heap := clampi(built + 1, 0, heaps - 1)
	var travel := clampf((t - (float(built) + 1.0)) / 0.5, 0.0, 1.0)
	var heap_xz := spoil_local(site.salt, built, site.half).lerp(
			spoil_local(site.salt, next_heap, site.half), travel)
	var heap := site.centre + Vector3(heap_xz.x, 0.0, heap_xz.y)
	# Stood off the heap toward the block centre, facing it: the boom reaches the
	# spoil rather than the neighbour's fence.
	var to_centre := (site.centre - heap)
	var facing := to_centre.normalized() if to_centre.length() > 0.5 else Vector3.RIGHT
	var stand := heap - facing * 8.4
	if arriving:
		var drive := _arrival(site, stand, arrive_progress(site.progress))
		stand = drive["pos"]
		facing = drive["dir"]
	var pose := _take(exc_poses, exc_used)
	exc_used += 1
	pose.origin = Vector3(stand.x, 0.0, stand.z)
	pose.basis = _yaw_to(facing)
	pose.custom = ConstructionActivity.dig_pose(
			fposmod(gm / dig_cycle_gm + hash01(site.salt, 83), 1.0))
	pose.tint = _livery(site.salt, 29)
	# The shuttle. No frontage means no street to haul to, and a lorry that
	# drove to nowhere would be worse than no lorry.
	if secondary and site.plant != null and site.plant.frontage_ok:
		_emit_shuttle(site, gm, heap)
	_crew_at(site, gm, stand, CREW_BY_PHASE[2])


## The haul lorry: load at the heap, out to the frontage, tip, come back empty.
## One cycle is `haul_cycle_gm` and the whole of it is derived from the clock, so
## a pause parks it exactly where it stands.
func _emit_shuttle(site: Site, gm: float, heap: Vector3) -> void:
	var stop := site.plant.edge + site.plant.out * 2.0
	stop.y = road_top
	var out_leg := stop - heap
	var w := fposmod(gm / haul_cycle_gm + hash01(site.salt, 157), 1.0)
	var pos := heap
	var dir := out_leg
	var tilt := 0.0
	var load := 0.0
	if w < 0.12:
		# Standing under the excavator, filling. The load rising IS the motion —
		# a tipper that raises its bed to be filled is a lie anyone who has stood
		# on a site reads straight away (doc 11 §2.16's own rule).
		load = w / 0.12
	elif w < 0.46:
		pos = heap.lerp(stop, (w - 0.12) / 0.34)
		load = 1.0
	elif w < 0.62:
		pos = stop
		var t := (w - 0.46) / 0.16
		tilt = clampf(t / 0.26, 0.0, 1.0) * clampf((1.0 - t) / 0.26, 0.0, 1.0)
		load = clampf(1.0 - (t - 0.20) / 0.55, 0.0, 1.0)
	else:
		pos = stop.lerp(heap, clampf((w - 0.62) / 0.38, 0.0, 1.0))
		dir = -out_leg
	var pose := _take(tipper_poses, tipper_used)
	tipper_used += 1
	pose.origin = Vector3(pos.x, road_top, pos.z)
	pose.basis = _yaw_to(dir)
	pose.custom = Color(clampf(tilt, 0.0, 1.0), clampf(load, 0.0, 1.0), 0.0, 0.0)
	pose.tint = _livery(site.salt, 97)


func _emit_road_install(site: Site, gm: float, q: float, arriving: bool) -> void:
	var state := pave_state(site.run_legs, site.run_total, PAVE_SEGMENTS, q)
	var pos: Vector3 = state["pos"]
	var dir: Vector3 = state["dir"]
	if arriving:
		var drive := _arrival(site, pos, arrive_progress(site.progress))
		pos = drive["pos"]
		dir = drive["dir"]
	_push_paver_at(Vector3(pos.x, 0.0, pos.z), dir, 1.0, _livery(site.salt, 53),
			gm, site.salt)
	if secondary:
		# The roller follows the screed by one machine length of run, measured on
		# the same walk so it can never end up on a leg the paver has not reached.
		var q_back := maxf(q - ROLLER_LAG_M / maxf(site.run_total, 1.0), 0.0)
		var behind := pave_state(site.run_legs, site.run_total, PAVE_SEGMENTS, q_back)
		var bp: Vector3 = behind["pos"]
		_push_roller_at(Vector3(bp.x, 0.0, bp.z), behind["dir"],
				site.run_total * q_back, site.salt)
	_crew_at(site, gm, pos, CREW_BY_PHASE[3])


func _emit_utility(site: Site, gm: float, q: float, arriving: bool) -> void:
	# The trencher is an excavator cutting along the line, not standing beside
	# it: its position IS the head of the cut, which is what makes the trench
	# open behind it rather than around it.
	var head := site.trench_a.lerp(site.trench_b, q)
	var dir := site.trench_b - site.trench_a
	if arriving:
		var drive := _arrival(site, head, arrive_progress(site.progress))
		head = drive["pos"]
		dir = drive["dir"]
	var pose := _take(exc_poses, exc_used)
	exc_used += 1
	# Stood a machine's width off the cut so the tracks are not in the hole.
	var side := Vector3(-dir.normalized().z, 0.0, dir.normalized().x)
	pose.origin = Vector3(head.x, 0.0, head.z) + side * 3.6
	pose.basis = _yaw_to(-side)
	pose.custom = ConstructionActivity.dig_pose(
			fposmod(gm / dig_cycle_gm + hash01(site.salt, 61), 1.0))
	pose.tint = _livery(site.salt, 29)
	# Half at the head, the rest strung back along the open cut — the one phase
	# where a crew is spread out rather than gathered round a machine. The men
	# are pushed DIRECTLY rather than through `_crew_at`: the preset scale has
	# already been applied to `want`, and running the halves through it again put
	# six men on a four-man phase at `quality`.
	var want := crew_want(CREW_BY_PHASE[4])
	var at_head := maxi(1, want / 2)
	for h in at_head:
		_push_crew(site.salt, 200 + h * 19, gm, Vector3(head.x, 0.0, head.z), 1.0)
	for i in (want - at_head):
		var back := clampf(q - 0.16 * float(i + 1), 0.02, 1.0)
		var spot := site.trench_a.lerp(site.trench_b, back)
		_push_crew(site.salt, 300 + i * 17, gm, Vector3(spot.x, 0.0, spot.z), 1.2)


func _emit_final(site: Site, gm: float, q: float, arriving: bool) -> void:
	var state := pave_state(site.run_legs, site.run_total, PAVE_SEGMENTS, q)
	var pos: Vector3 = state["pos"]
	var dir: Vector3 = state["dir"]
	if arriving:
		var drive := _arrival(site, pos, arrive_progress(site.progress))
		pos = drive["pos"]
		dir = drive["dir"]
	# The kerb machine is a paver extruding a smaller section — same body at
	# 0.72, in the kerb's own grey rather than a hire livery.
	_push_paver_at(Vector3(pos.x, 0.0, pos.z), dir, 0.72, _kerb_livery(site.salt),
			gm, site.salt)
	_crew_at(site, gm, pos, CREW_BY_PHASE[5])


# --------------------------------------------------------- the player's road

func _emit_run(run: Run, gm: float) -> void:
	var d := run.total * run.progress
	var head := ConstructionActivity.sample_polyline(run.points, run.cum, d)
	var pos := Vector3(head.x, road_top, head.z)
	var dir := Vector3(cos(head.w), 0.0, sin(head.w))
	_push_paver_at(pos, dir, 1.0, _livery(run.salt, 53), gm, run.salt)
	if secondary:
		var lag := maxf(d - ROLLER_LAG_M, 0.0)
		var back := ConstructionActivity.sample_polyline(run.points, run.cum, lag)
		_push_roller_at(Vector3(back.x, road_top, back.z),
				Vector3(cos(back.w), 0.0, sin(back.w)), lag, run.salt)
	# The barricade across the working end: the run is open behind the paver and
	# shut in front of it.
	var ahead := ConstructionActivity.sample_polyline(run.points, run.cum,
			minf(d + 5.0, run.total))
	var forward := Vector3(cos(ahead.w), 0.0, sin(ahead.w))
	var across := Vector3(-forward.z, 0.0, forward.x)
	var basis := _yaw_to(across)
	for i in RUN_BARRIER_BAYS:
		var u := (float(i) - float(RUN_BARRIER_BAYS - 1) * 0.5) * RUN_BARRIER_PITCH_M
		var pose := _take(barrier_poses, barrier_used)
		barrier_used += 1
		pose.origin = Vector3(ahead.x, road_top, ahead.z) + across * u
		pose.basis = basis
		pose.tint = Color.WHITE
		pose.custom = Color(float(i), 0.0, 0.0, 0.0)
	for i in crew_want(CREW_PER_ROAD_RUN):
		_push_crew(run.salt, 700 + i * 23, gm, pos, 1.0)


func _run_head(run: Run) -> Vector3:
	var head := ConstructionActivity.sample_polyline(run.points, run.cum,
			run.total * run.progress)
	return Vector3(head.x, 0.0, head.z)


# ------------------------------------------------------------ pose plumbing

func _push_paver_at(pos: Vector3, dir: Vector3, scale: float, tint: Color,
		gm: float, salt: int) -> void:
	var pose := _take(paver_poses, paver_used)
	paver_used += 1
	pose.origin = pos
	var basis := _yaw_to(dir)
	if not is_equal_approx(scale, 1.0):
		basis = basis.scaled_local(Vector3(scale, scale, scale))
	pose.basis = basis
	# **The screed FLOATS**, and it is the only thing on a paver that moves under
	# its own steam. Everything else about this machine is positional — it is
	# where the job's progress puts it — so a rigid screed would leave the paver
	# a still frame at any moment the player pauses, which is precisely the read
	# this wave exists to remove. A slow half-cycle against the dig, so a paver
	# and an excavator on the same block are never in step.
	pose.custom = Color(clampf(0.5 + 0.42 * sin(TAU * (gm / (dig_cycle_gm * 2.3)
			+ hash01(salt, 271))), 0.0, 1.0), 0.0, 0.0, 0.0)
	pose.tint = tint


func _push_roller_at(pos: Vector3, dir: Vector3, distance: float,
		salt: int) -> void:
	var pose := _take(roller_poses, roller_used)
	roller_used += 1
	pose.origin = pos
	pose.basis = _yaw_to(dir)
	# **The drum turns with the GROUND, not with the clock.** `distance` is how
	# far along its pass the machine has come, so the drum's angle is
	# `fract(distance / circumference)` — a roller standing still has a still
	# drum, which is the whole difference between a machine and a screensaver.
	pose.custom = Color(fposmod(distance / drum_circumference_m, 1.0), 0.0, 0.0, 0.0)
	# Salted off the SITE, never off the position: a livery derived from where
	# the machine happens to be would repaint it every frame it moved.
	pose.tint = _livery(salt, 67)


## `count` figures working around `anchor`. Half of them stand and half walk a
## small circuit; which is which is hashed, so the same block always has the
## same men leaning on the same shovel.
func _crew_at(site: Site, gm: float, anchor: Vector3, count: int) -> void:
	for i in crew_want(count):
		_push_crew(site.salt, 200 + i * 19, gm, anchor, 1.0)


## How many of the `count` men a phase wants actually turn up on this device.
## Never zero and never more than twice the phase's own number, so a knob cannot
## turn a three-man gang into a crowd or into an empty site.
func crew_want(count: int) -> int:
	return clampi(int(round(float(count) * crew_scale)), 1, maxi(count, 1) * 2)


func _push_crew(salt: int, index: int, gm: float, anchor: Vector3,
		spread: float) -> void:
	var stands := hash01(salt, index) < CREW_STAND_FRAC
	var bearing := hash01(salt, index + 3) * TAU
	var radius := CREW_STANDOFF_M * spread * lerpf(0.5, 1.0, hash01(salt, index + 5))
	var base := anchor + Vector3(cos(bearing), 0.0, sin(bearing)) * radius
	var pos := base
	var dir := Vector3(-cos(bearing), 0.0, -sin(bearing))
	var limb := 0.5
	if not stands:
		# A short circuit rather than a walk to anywhere: a crew member working a
		# machine covers a few metres and comes back.
		var lap := fposmod(gm / crew_loop_gm + hash01(salt, index + 7), 1.0) * TAU
		pos = base + Vector3(cos(lap), 0.0, sin(lap)) * CREW_LOOP_M
		dir = Vector3(-sin(lap), 0.0, cos(lap))
		limb = 0.5 + 0.5 * sin(TAU * (gm / crew_step_gm + hash01(salt, index + 11)))
	else:
		# A man standing still still moves: he looks around.
		limb = 0.5 + 0.06 * sin(TAU * (gm / (crew_step_gm * 6.0)
				+ hash01(salt, index + 13)))
	var pose := _take(crew_poses, crew_used)
	crew_used += 1
	pose.origin = Vector3(pos.x, 0.0, pos.z)
	pose.basis = _yaw_to(dir)
	var head := 0.5 + 0.42 * sin(TAU * (gm / (crew_loop_gm * 0.31)
			+ hash01(salt, index + 17)))
	# (legs, head yaw, arms, LEAVING). The fourth channel is `street_life`'s
	# collect/expire animation and a crew member never uses it — a crew does not
	# get collected — so it is nailed to zero and the alpha of the tint, which
	# the same shader reads as the collect FLASH, with it.
	pose.custom = Color(clampf(limb, 0.0, 1.0), clampf(head, 0.0, 1.0),
			clampf(1.0 - limb, 0.0, 1.0), 0.0)
	pose.tint = _hi_vis(salt, index)


# ------------------------------------------------------------- the arrival

## Where a machine is on its way in, and which way it is pointing.
##
## The first `ARRIVAL_LEAD_M` of the answer is doc 11 §2.16's own street-true
## polyline for this block's frontage — the same line the haul lorries drive —
## and the rest is one straight leg from the kerb onto the pass start. With no
## plant site, no route or no frontage there is nothing to drive on, and the
## machine simply stands at its pass start.
func _arrival(site: Site, pass_start: Vector3, t: float) -> Dictionary:
	var plant := site.plant
	if plant == null or not plant.frontage_ok or plant.to_site.size() < 2 \
			or plant.route_m <= 1.0:
		return {"pos": pass_start, "dir": Vector3.RIGHT}
	var lead := minf(ARRIVAL_LEAD_M, plant.route_m)
	var stop := plant.to_site[plant.to_site.size() - 1]
	var lot_leg := maxf(Vector3(stop.x, 0.0, stop.z).distance_to(
			Vector3(pass_start.x, 0.0, pass_start.z)), 0.01)
	var total := lead + lot_leg
	var d := total * clampf(t, 0.0, 1.0)
	if d < lead:
		var sample := ConstructionActivity.sample_polyline(plant.to_site,
				plant.to_site_cum, plant.route_m - lead + d)
		return {"pos": Vector3(sample.x, 0.0, sample.z),
				"dir": Vector3(cos(sample.w), 0.0, sin(sample.w))}
	var w := clampf((d - lead) / lot_leg, 0.0, 1.0)
	var from := Vector3(stop.x, 0.0, stop.z)
	var to := Vector3(pass_start.x, 0.0, pass_start.z)
	var dir := to - from
	return {"pos": from.lerp(to, w),
			"dir": dir.normalized() if dir.length() > 0.01 else Vector3.RIGHT}


## Where a survey party stands: on the block's own frontage boundary if it has
## one, and on its west edge if it has not.
func _survey_anchor(site: Site) -> Vector3:
	if site.plant != null and site.plant.frontage_ok:
		var p := site.plant.edge - site.plant.out * 6.0
		return Vector3(p.x, 0.0, p.z)
	return site.centre + Vector3(-site.half + 10.0, 0.0, 0.0)


# ------------------------------------------------------------------ layout

## Everything the PHASE fixes, built once per phase change. This is the only
## expensive derivation in the file — six run lengths and a trench line — and
## rebuilding it per frame at eight blocks would be 48 square roots a frame for
## numbers that had not moved.
func _ensure_layout(site: Site) -> void:
	if site.layout_phase == site.phase_index:
		return
	site.layout_phase = site.phase_index
	site.run_legs = legs_of(template_runs(site.centre, site.half, tile_m))
	site.run_total = legs_total(site.run_legs)
	var line := trench_line(site.centre, site.half, tile_m)
	site.trench_a = line[0]
	site.trench_b = line[1]


# ----------------------------------------------------------------- plumbing

func _zero() -> void:
	dozer_used = 0
	exc_used = 0
	tipper_used = 0
	paver_used = 0
	roller_used = 0
	crew_used = 0
	barrier_used = 0


## Tile centres as a drivable line at the road surface. No lane offset: a run
## under construction is closed to traffic (doc 10 opens a `construction_new`
## closure over it), so the paver works the centre of it.
func _tile_line(tiles: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for entry: Variant in tiles:
		if not (entry is Vector2i):
			continue
		var t: Vector2i = entry
		out.append(Vector3((float(t.x) + 0.5) * tile_m, road_top,
				(float(t.y) + 0.5) * tile_m))
	return out


static func _yaw_to(dir: Vector3) -> Basis:
	var d := Vector3(dir.x, 0.0, dir.z)
	if d.length() < 0.0001:
		return Basis.IDENTITY
	return Basis.from_euler(Vector3(0.0, -atan2(d.z, d.x), 0.0))


## Grow a pose pool on demand and hand back slot `index`. Pools never shrink;
## the churn is what this exists to avoid. `ConstructionActivity._take` is the
## same function and the same reasoning — this file re-states it rather than
## reaching into another class's private helper.
static func _take(pool: Array[ConstructionActivity.Pose],
		index: int) -> ConstructionActivity.Pose:
	while pool.size() <= index:
		pool.append(ConstructionActivity.Pose.new())
	return pool[index]


## Plant paint, straight off doc 11 §2.16's four-livery fleet, so a dozer and a
## tipper on the same block come from the same hire company as the excavator
## standing between them. Alpha carries the per-machine hash the shader turns
## into a beacon phase and a tone skew.
static func _livery(salt: int, index: int) -> Color:
	const LIVERY := ["#E3A423", "#D2601F", "#3E8C69", "#4C82AE"]
	var pick := int(hash01(salt + index * 977, 191) * float(LIVERY.size()))
	var c := Color(String(LIVERY[clampi(pick, 0, LIVERY.size() - 1)])).srgb_to_linear()
	return Color(c.r, c.g, c.b, hash01(salt, index))


## The kerb machine's grey. It is not hire plant — a slipform machine wears the
## concrete it extrudes.
static func _kerb_livery(salt: int) -> Color:
	var c := Color("#9AA0A6").srgb_to_linear()
	return Color(c.r, c.g, c.b, hash01(salt, 199))


## Hi-vis. Two gangs, yellow and orange, so a block with four men on it does not
## read as four copies of one man. **Alpha is ZERO on purpose**:
## `street_life.gdshader` reads COLOR.a as the collect FLASH, and a crew member
## that flashed white would be a man being arrested.
static func _hi_vis(salt: int, index: int) -> Color:
	const VESTS := ["#F2C21B", "#F2701B"]
	var pick := int(hash01(salt + index, 233) * float(VESTS.size()))
	var c := Color(String(VESTS[clampi(pick, 0, VESTS.size() - 1)])).srgb_to_linear()
	return Color(c.r, c.g, c.b, 0.0)


static func _num(cfg: Dictionary, key: String, fallback: float) -> float:
	return float(cfg.get(key, fallback))


## The same integer mixer `ConstructionActivity` and `LandWorksView` use, so a
## block's machines, its scatter and its plant all come from one family and a
## save cannot change any of them.
static func hash01(value: int, salt: int) -> float:
	var h: int = absi((value * 73856093) ^ (salt * 19349663)) % 100003
	return float(h) / 100003.0

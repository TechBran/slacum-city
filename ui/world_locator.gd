class_name WorldLocator
extends RefCounted
## **Sim id → a point in metres.** The one place that knows how to turn any id
## the sim publishes into somewhere the camera can look.
##
## Headless and static: `sim` is injected, nothing here touches the scene tree,
## `Engine`, `Input` or a node, and every method is a READ. That is the whole
## point of the file — at the Wave-17 fork this reasoning lived twice inside
## `game/main.gd` (`_alert_world_pos` and `_on_fix_requested`), which the suite
## never loads, and both copies were wrong in different ways (PA-38, PA-76):
##
##  * `_on_fix_requested` looked a **transformer** id (`T-01`) up in
##    `sim.buildings` and returned when it missed — the dead half of `Fix this →`
##    on the game's most common blocker (PA-05). **The namespace mismatch dies
##    here**: `locate_any` tries every namespace the sim publishes, in a fixed
##    order, and a grid component id resolves to its tile.
##  * both anchored a building on its origin TILE — `b.origin * tile_m`, the NW
##    corner — so a jump to a 4×4 civic building landed sixteen metres north-west
##    of it, off the lot. Every answer here is a footprint CENTRE.
##  * `_alert_world_pos` declared `tile_m := 8.0` and then used the bare literal
##    on its own `&"tile"` branch, spelled `16` three times where
##    `TileGrid.TILES_PER_BLOCK` existed, and scanned `sim.buildings.keys()`
##    linearly for a key it was already holding.
##
## Every answer is on **grade** (`y == 0`). Elevation is a per-block integer the
## render layer applies to meshes; a locator that guessed at it would put the
## camera under the two raised blocks.
##
## Doc 12 §2.7 (`Fix this →`), doc 12 §4.5 (the alerts centre's jump affordance).

# --------------------------------------------------------------------- kinds
#
# The alert kinds (`tile`, `block_id`, `building`, `cell`) are doc 12 §4.5's own
# spellings and are load-bearing: `AlertsModel` publishes them. The rest are the
# `RequirementFormatter.FIX_*` targets, spelled the same way so one table serves
# both callers.

const KIND_TILE := &"tile"
const KIND_BLOCK := &"block"
const KIND_BLOCK_ID := &"block_id"      ## doc 12 §4.5's spelling of KIND_BLOCK
const KIND_BUILDING := &"building"
const KIND_CELL := &"cell"              ## doc 07 §2.4's flood-cell key
const KIND_COMPONENT := &"component"    ## a PowerGrid component: T-nn, F-nn, …
const KIND_DISTRICT := &"district"
const KIND_ROAD_SEGMENT := &"road_segment"

## How far `nearest_road_tile` will search for an avenue before giving up, in
## tiles. **A reference, not a copy — and it was a copy.**
##
## This shipped as a hand-written `:= 12` under a docstring that said it mirrored
## `BuildController.AVENUE_SEARCH_TILES`, which is **16**. That is RR-139's own
## defect — a number written twice under a promise that it agrees — committed in
## this lane's own new file in the same wave that ruled against it, and the
## tile-metre census could not see it because it is a tile COUNT, not a metre.
##
## It was not cosmetic. `BuildController.nearest_avenue_tiles` searches to 16
## before reporting "none in range", so `E_AVENUE` is raised for a building whose
## nearest avenue is up to 16 tiles off. Once lane L's params half lands
## (`fix_target_id`, §50.2 item 1) a building at 13–16 tiles would hand this
## locator a row the checklist had just measured, and get `unresolved` — a
## `Fix this →` that refuses a fix that exists, which is the exact shape of the
## PA-05 defect the lane was chartered to kill, one namespace over.
##
## **Latent, not live, and said so rather than dressed up**: in the starter city
## the farthest building from an avenue is 7 tiles (`APT-003`), so nothing sits
## in the 13–16 band today and no shipped sweep could have caught it. It is a
## player-placement defect — `E_AVENUE` is a level-4 check (C-62) on a building
## the player chose to put far from an avenue, which is precisely the case the
## starter fixture does not contain.
##
## A reference cannot drift. A Chebyshev ring walk of radius 16 is 33² = 1,089
## tiles worst case, run once on a button press.
const ROAD_SEARCH_TILES := BuildController.AVENUE_SEARCH_TILES


## The one entry point. Returns a `Vector3` in metres, or `null` when the id does
## not resolve — and `null` is a STATEMENT ("there is nowhere to jump"), never a
## silently swallowed miss: `FixRouter` turns it into a refusal with a reason.
static func locate(sim: CitySim, kind: StringName, id: Variant) -> Variant:
	if sim == null:
		return null
	match kind:
		KIND_TILE:
			return locate_tile(id)
		KIND_BLOCK, KIND_BLOCK_ID:
			return locate_block(sim, str(id))
		KIND_BUILDING:
			# A building id that is NOT a building is the PA-05 bug. Rather than
			# returning null and letting the shell drop the tap on the floor,
			# fall through to every other namespace: the id the panel handed us
			# came from the sim and the sim knows what it is.
			var here: Variant = locate_building(sim, str(id))
			return here if here != null else locate_any(sim, id)
		KIND_CELL:
			return locate_cell(id)
		KIND_COMPONENT:
			return locate_component(sim, str(id))
		KIND_DISTRICT:
			# Same fallthrough the building arm takes, for the same reason and
			# found the same way. Doc 05 keys a PRESSURE ZONE by its source node
			# (`WTR-1-PMP`), and `E_WATER_HEADROOM` calls that key `district_id`
			# because it is the area the remedy applies to — so a row whose fix
			# kind is honestly "a district" can carry an id doc 09's district
			# table has never heard of. Rather than let the button resolve to
			# nowhere, ask the other namespaces: the id came from the sim, and
			# the sim knows what it is. (Wave 18 merge; Lane D's own
			# `test_no_real_checklist_row_falls_through_silently` caught it on
			# every building in the starter city.)
			var district: Variant = locate_district(sim, str(id))
			return district if district != null else locate_any(sim, id)
		KIND_ROAD_SEGMENT:
			return locate_road_segment(sim, id)
	return null


## Try every namespace in a fixed order and answer with the first that knows the
## id. The order is by cost and by specificity: the two dictionary lookups first,
## then the block table, then the district table, and the linear road search
## never — an unqualified id is not a licence to walk the map.
##
## Determinism note: the order is fixed and the namespaces are disjoint in
## practice — buildings are archetype-tagged (`APT-001`, `H-001`, `FIRE-1`),
## components are `T-nn` / `F-nn` / `SUB-n`, blocks are `B_<bx>_<bz>` and
## districts are `D_<NAME>` — so "first that knows it" is a stable answer, and
## the four tables are asserted to disagree about nothing in
## `test_world_locator.gd::test_locate_any_walks_the_namespaces_in_order`.
static func locate_any(sim: CitySim, id: Variant) -> Variant:
	if sim == null:
		return null
	if id is Vector2i:
		return locate_tile(id)
	var key := str(id)
	if key == "":
		return null
	var found: Variant = locate_building(sim, key)
	if found != null:
		return found
	found = locate_component(sim, key)
	if found != null:
		return found
	found = locate_block(sim, key)
	if found != null:
		return found
	return locate_district(sim, key)


# ----------------------------------------------------------- one kind at a time

## A tile, given as a `Vector2i` or as doc 07's `"<tx>,<tz>"` text.
static func locate_tile(id: Variant) -> Variant:
	if id is Vector2i:
		return TileGrid.centre_of(id)
	if id is Vector2:
		return TileGrid.centre_of(Vector2i(id))
	var parts := str(id).split(",")
	if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		return TileGrid.centre_of(Vector2i(int(parts[0]), int(parts[1])))
	return null


## Doc 07 §2.4 keys a flood cell either `"B<bx>,<bz>"` (a land block) or
## `"<tx>,<tz>"` (a tile). The `B` prefix is the discriminator and the two answer
## at different scales, which is why this is its own kind and not `KIND_TILE`.
static func locate_cell(id: Variant) -> Variant:
	var key := str(id)
	if not key.begins_with("B"):
		return locate_tile(id)
	var parts := key.substr(1).split(",")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return null
	return TileGrid.centre_of_block(Vector2i(int(parts[0]), int(parts[1])))


## A land block, by its authored id. The centre of the 16×16, not its corner.
static func locate_block(sim: CitySim, block_id: String) -> Variant:
	if sim.world == null or block_id == "":
		return null
	var block: LandBlock = sim.world.block(block_id)
	if block == null:
		return null
	return TileGrid.centre_of_block(block.grid)


## A building, by SIM id (`"B-014"`) or by the integer grid id the render layer
## carries. The centre of its FOOTPRINT — a 4×4 civic building answered at its
## origin tile is sixteen metres off its own lot.
static func locate_building(sim: CitySim, sim_id: String) -> Variant:
	if sim_id == "":
		return null
	var b: Building = sim.buildings.get(sim_id)
	if b == null:
		# The integer form the alerts centre and the render model both speak.
		if sim_id.is_valid_int():
			var wanted := int(sim_id)
			for key: String in sim.buildings:
				var candidate: Building = sim.buildings[key]
				if candidate.id == wanted:
					return locate_building(sim, key)
		return null
	var size: Vector2i = sim.building_record(sim_id).get("footprint", Vector2i.ONE)
	return TileGrid.centre_of_footprint(b.origin, size)


## A `PowerGrid` component — a transformer, a feeder node, the substation. **This
## is the branch PA-05 needed**: `ui/build_controller.gd` fills `fix_target_id`
## from `sim.grid.attachment_of(sim_id)`, which returns a TRANSFORMER id, and the
## shell looked it up among buildings.
static func locate_component(sim: CitySim, component_id: String) -> Variant:
	if component_id == "":
		return null
	# A "component" is not one namespace. Doc 04's grid components (`T-nn`,
	# `F-nn`, `SUB-n`) and doc 05's water nodes (`WTR-1-PMP`, tanks, treatment)
	# are both addressed this way by the checklist, and Wave 18 proved it the
	# expensive way: Lane L's E_WATER_HEADROOM row hands the router a water node
	# id, Lane D's locator asked only the power grid, and every checklist row on
	# every building in the starter city resolved to nothing. Neither lane could
	# see it — the merge did, through Lane D's own completeness gate
	# (`test_no_real_checklist_row_falls_through_silently`). Water is asked
	# SECOND because the power table is the larger and the ids are disjoint.
	if sim.water != null:
		var node: WaterNode = sim.water.node(component_id)
		if node != null:
			return TileGrid.centre_of(node.tile)
	if sim.grid == null:
		return null
	var row: Dictionary = sim.grid.component(component_id)
	# `PowerGrid.component_tile` answers `Vector2i.ZERO` for BOTH an unknown id
	# and a component that carries no tile, and tile (0,0) is a real place on
	# this map — so the two cases are separated HERE rather than by comparing
	# against a sentinel that is also a valid answer.
	if row.is_empty() or not (row.get("tile", null) is Vector2i):
		return null
	return TileGrid.centre_of(sim.grid.component_tile(component_id))


## A district — the mean of its member blocks' centres. A district is up to six
## blocks and need not be convex, so the centroid can fall outside it; that is
## still the right camera answer, because the affordance is "show me this
## district", not "stand on this block".
static func locate_district(sim: CitySim, district_id: String) -> Variant:
	if sim.districts == null or district_id == "":
		return null
	var row: Dictionary = sim.districts.district(district_id)
	if row.is_empty():
		return null
	var blocks: Array = row.get("blocks", [])
	var sum := Vector3.ZERO
	var n := 0
	for block_id: Variant in blocks:
		var point: Variant = locate_block(sim, str(block_id))
		if point != null:
			sum += point as Vector3
			n += 1
	if n == 0:
		return null
	return sum / float(n)


## `E_AVENUE`'s target (C-62): the nearest AVENUE tile to the thing that is short
## of one. The id may be a tile, or — the form `ui/build_controller.gd` can hand
## over with a one-line change — the BUILDING that needs the avenue, in which
## case the search starts at its origin.
##
## Answers the avenue when there is one in range and `null` when there is not,
## which is the honest answer: "there is no avenue to show you" is exactly the
## state `E_AVENUE` is reporting, and jumping the camera to an arbitrary street
## would teach the player the wrong lesson.
static func locate_road_segment(sim: CitySim, id: Variant) -> Variant:
	if sim.world == null:
		return null
	var from := Vector2i(-1, -1)
	if id is Vector2i:
		from = id
	else:
		var key := str(id)
		var parts := key.split(",")
		if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
			from = Vector2i(int(parts[0]), int(parts[1]))
		else:
			var b: Building = sim.buildings.get(key)
			if b != null:
				from = b.origin
	if from == Vector2i(-1, -1):
		return null
	var tile := nearest_road_tile(sim, from, TileGrid.ROAD_AVENUE)
	return null if tile == Vector2i(-1, -1) else TileGrid.centre_of(tile)


## Chebyshev ring walk outward from `from` for the nearest tile of `road_class`.
## Returns `Vector2i(-1, -1)` when none is within `ROAD_SEARCH_TILES` — which is
## `BuildController.AVENUE_SEARCH_TILES` by reference, so this walk reaches
## exactly as far as the check that raises the row (see the constant). Same walk
## `BuildController.nearest_avenue_tiles` does for the DISTANCE; this wants the
## tile, and the ring order (rows then columns, ascending) makes the answer
## deterministic when two are equidistant.
static func nearest_road_tile(sim: CitySim, from: Vector2i,
		road_class: int) -> Vector2i:
	var grid: TileGrid = sim.world.grid
	for radius in range(0, ROAD_SEARCH_TILES + 1):
		for z in range(from.y - radius, from.y + radius + 1):
			for x in range(from.x - radius, from.x + radius + 1):
				if maxi(absi(x - from.x), absi(z - from.y)) != radius:
					continue
				if TileGrid.in_bounds(x, z) and grid.road_class_at(x, z) == road_class:
					return Vector2i(x, z)
	return Vector2i(-1, -1)

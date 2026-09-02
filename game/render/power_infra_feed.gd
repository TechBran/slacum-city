class_name PowerInfraFeed
extends RefCounted
## The sim → distribution-layer adapter: `CitySim` on one side, the plain
## dictionaries `PowerInfraModel` eats on the other.
##
## It exists so that exactly ONE file in the renderer knows what a `CitySim`
## is. `PowerInfraModel` is pure arithmetic and `PowerInfraView` is a MultiMesh
## uploader; both are testable against hand-built fixtures because neither of
## them ever sees the sim. Everything here is a READ — no command, no mutation,
## no RNG draw — which is what keeps the visible power layer hash-neutral by
## construction rather than by inspection.
##
## Two calls, deliberately split by how often they are wanted:
##   * `topology()` — pads and wires. Expensive (one pass over every attached
##     building) and only correct to call when the roster or the attachment map
##     has actually moved.
##   * `state()` — the per-transformer condition/load/temperature rows. Cheap,
##     wanted several times a second, and the ONLY thing a smoking transformer
##     needs to start smoking.

## What a building whose shell is still going up is worth as a service height:
## a temporary pole, not the finished eave forty metres up. `PowerInfraModel`
## clamps to `service_height_min_m` from here, so the drop lands on the site
## hoarding instead of hanging in the air where the roof will be.
const CONSTRUCTION_SERVICE_HEIGHT_M := 4.10

## Fallback when the shell hands in no height lookup — one storey over the
## service-height ceiling, so the clamp decides and the wire is never inside a
## wall it cannot see.
const DEFAULT_HEIGHT_M := 9.00


## `{transformers, buildings, attachments}` — everything `build_topology` wants.
##
## `height_of` is `func(archetype: StringName, level: int) -> float`; the shell
## has the mesh manifest and this does not. An invalid Callable is fine and
## gives every building `DEFAULT_HEIGHT_M`.
static func topology(sim: CitySim, height_of := Callable(),
		tile_m: float = 8.0) -> Dictionary:
	var transformers: Array = []
	for id: String in sim.grid.component_ids_of_kind(&"transformer"):
		var component: Dictionary = sim.grid.component(id)
		transformers.append({
			"id": id,
			"tile": sim.grid.component_tile(id),
			"level": int(component.get("level", 1)),
		})
	var buildings: Dictionary = {}
	var ids: Array = sim.buildings.keys()
	ids.sort()
	for sim_id: String in ids:
		buildings[sim_id] = building_view(sim, sim_id, height_of, tile_m)
	return {
		"transformers": transformers,
		"buildings": buildings,
		"attachments": sim.grid.attachment_map(),
	}


## One building's geometry, as the wire layer needs it: where it is, how big its
## footprint is in METRES (doc 02 stores tiles), and how high a service drop may
## land on it.
static func building_view(sim: CitySim, sim_id: String,
		height_of := Callable(), tile_m: float = 8.0) -> Dictionary:
	var b: Building = sim.buildings.get(sim_id)
	if b == null:
		return {}
	var record: Dictionary = sim._building_records[sim_id]
	var size: Vector2i = record["footprint"]
	var center := Vector3(b.origin.x * tile_m + size.x * tile_m * 0.5, 0.0,
			b.origin.y * tile_m + size.y * tile_m * 0.5)
	var height := DEFAULT_HEIGHT_M
	if b.state == &"under_construction":
		height = CONSTRUCTION_SERVICE_HEIGHT_M
	elif height_of.is_valid():
		height = float(height_of.call(b.archetype, maxi(b.level, 1)))
	return {
		"world_pos": center,
		"footprint_m": Vector2(size.x * tile_m, size.y * tile_m),
		"height_m": height,
	}


## `PowerGrid.transformer_rows()` at the ambient doc 04's own protection pass
## derates on — the same expression `main.gd._feed_dashboard_tabs()` uses, so
## the pad that smokes is the pad the Infrastructure tab lists as hottest.
static func state(sim: CitySim) -> Array:
	return sim.grid.transformer_rows(ambient_c(sim))


static func ambient_c(sim: CitySim) -> float:
	if sim.weather == null:
		return PowerInfraModel.REFERENCE_AMBIENT_C
	return float(sim.weather.env_for_grid().get("t_ambient_c",
			PowerInfraModel.REFERENCE_AMBIENT_C))


## `func(tile) -> bool` over doc 10's road flags, for `set_road_probe`. Bound to
## the world map rather than to the sim so a test can hand in any grid.
static func road_probe(world: WorldMap) -> Callable:
	return func(tile: Vector2i) -> bool:
		if tile.x < 0 or tile.y < 0 or tile.x >= TileGrid.SIZE or tile.y >= TileGrid.SIZE:
			return false
		return world.grid.has_flag(tile.x, tile.y, TileGrid.FLAG_ROAD)


## A cheap signature of the things `topology()` depends on. The view polls this
## instead of rebuilding, because a full topology pass over 1,500 buildings is
## not something to do four times a second for a city where nothing has changed.
##
## It counts rather than hashes, and that is a stated trade: a re-ATTACHMENT
## that moves a building from one transformer to another (doc 04 §2.9's
## adoption) changes no count, so the counts alone would miss it. The view
## therefore also runs a slow unconditional rebuild — see
## `PowerInfraView.topology_poll_s` — and the shell can force one immediately
## with `note_topology_changed()` on the events that are worth a frame.
## **Wave 17 folds in `grid.mutation_epoch`**, which the grid bumps on every call
## that re-shapes it — a component added, removed, re-rated or re-conductored, a
## building attached or detached. That closes the re-attachment hole the
## paragraph above states, and it closes a real one the transformer demolition
## verb opened: a demolish plus a placement inside one poll interval moves the
## transformer count by −1 and +1 and the building count not at all, so the
## counts alone read as "nothing happened" and the pad of a transformer that is
## no longer there stays on the map. A ghost transformer after a demolish is
## precisely this lane's failure mode.
static func signature(sim: CitySim) -> int:
	return sim.grid.mutation_epoch * 1000003 \
			+ sim.grid.component_ids_of_kind(&"transformer").size() * 1009 \
			+ sim.buildings.size()

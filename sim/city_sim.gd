class_name CitySim
extends RefCounted
## The integration root: wires every sim system into the TickScheduler's
## 18-phase order and runs the starter city (Milestone 1). Constitution §3:
## RefCounted only, engine-agnostic, headless.
##
## Weather is a fixed clear-sky stub until doc 07's system lands (Phase 1);
## economy joins at P14 when sim/economy/ lands.

## Doc 05 §8's per-variant L1 base_kw anchors (source 0.30 × 107 → 32,
## treatment 0.50 × 80 → 40, pump 60 reference, tank 5 telemetry-only).
const STREETLIGHT_KW := 0.35
const SIGNAL_KW := 0.6
const DEMAND_CLASS_CHANNEL := {
	&"house": "power_demand_residential", &"apartment": "power_demand_residential",
	&"high_rise": "power_demand_residential",
	&"store": "power_demand_commercial", &"office": "power_demand_commercial",
	&"construction_yard": "power_demand_industrial",
	&"police_station": "power_demand_civic", &"fire_station": "power_demand_civic",
	&"water_facility": "power_demand_civic", &"power_facility": "power_demand_civic",
	&"data_center": "power_demand_datacenter",
}

var clock: GameClock
var curves: DayCurveSet
var modifiers: ModifierStack
var scheduler: TickScheduler
var rng: RngStreams
var bus: SimEventBus
var commands: CommandQueue
var timers: TimerService
var work: WorkService
var events: ScheduledEventService
var loader: StarterCityLoader
var world: WorldMap
var districts: DistrictRegistry
var population: PopulationSystem
var happiness: HappinessModel
var progression: ProgressionSystem
var stats: StatsRecorder
var grid: PowerGrid
var catalog: BuildingCatalog
var construction: ConstructionQueue
var development: DevelopmentController
var econ_curves: CostCurves
var treasury: Treasury
var economy: EconomySystem
var water: WaterSystem
var incident_catalog: IncidentCatalog
var incident_world: CityIncidentWorld
var incidents: IncidentSystem
var roads: RoadNetwork
var weather: WeatherSystem
var director: DisasterDirector
var incident_sink: IncidentRequestSink

## Held metering pair + starter roster (doc 03 §9 item 6b): constants until
## doc 04 meters delivered energy and the doc-06 fleet-billing ruling lands.
## (HELD_WATER retired — doc 05's live inventory() feeds the settlement now.)
const HELD_DELIVERED_MWH := 1.5
const HELD_FINE_RATE := 3.0 / 350.0
const STARTER_VEHICLES := [
	{"type": "patrol_car", "km_this_hour": 1.0},
	{"type": "patrol_car", "km_this_hour": 1.0},
	{"type": "fire_engine", "km_this_hour": 1.5 / 1.9},
	{"type": "utility_service_truck", "km_this_hour": 1.0},
	{"type": "water_repair_truck", "km_this_hour": 1.0},
	{"type": "construction_crew", "km_this_hour": 1.0},
]

## data/grid_components.json — doc 04 §2.1's placement rules for player-placed
## grid components (no prices, no capacities; see the file's own meta notes).
var grid_rules: Dictionary = {}
## doc 03 §2.2's tax rate r. `cmd_set_tax_level` is the only writer; the hour it
## last moved gates the §8 `TAX_RATE_COOLDOWN_HOURS` re-adjustment window.
var tax_rate: float = 0.09
var tax_rate_changed_hour: int = -1

var buildings: Dictionary = {}  # building id string -> Building
var _building_records: Dictionary = {}  # id -> starter record (block, tags…)
## AUTHORED buildings removed by cmd_demolish_building, keyed by sim_id, so a
## reload does not resurrect the tile reservation the loader re-stamps on every
## boot. Bounded by the authored roster; a demolished PLAYER building needs no
## row here, because it simply stops appearing in `placed_records`.
var _removed_records: Dictionary = {}
## Highest building grid id ever issued. Persisted, because ids must never be
## recycled (see `_next_building_grid_id`) and the live roster alone forgets the
## ones that were demolished.
var _grid_id_high_water: int = 0
var _block_to_district: Dictionary = {}
var _last_demands: Dictionary = {}
var _water_kw_by_building: Dictionary = {}  # water_facility id -> Σ hosted variant kW
var _block_dark_weights: Dictionary = {}  # building id -> pop+jobs weight
var _prev_block_dark: Dictionary = {}  # block id -> bool
## Last building_construction_stage emitted per building — DERIVED state, so it
## never enters capture_state(): a reloaded game simply re-announces the stage
## its jobs are actually at on the next tick, which is what the renderer wants.
var _last_construction_stage: Dictionary = {}  # sim_id -> stage 1..6
var _last_expense_hour: float = 1.0            # DirectorInputs.daily_opex source
var _strike_roster: Array = []
var _strike_roster_min: int = -1
var boot_errors: PackedStringArray = []


static func boot_from_files(seed_value: int = 1337) -> CitySim:
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json("res://data/starter_city.json"),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	return sim


func boot(seed_value: int, time_data: Dictionary, starter_data: Dictionary,
		buildings_data: Dictionary, rules_data: Dictionary,
		grid_rules_data: Dictionary = {}) -> bool:
	boot_errors.clear()
	grid_rules = grid_rules_data
	rng = RngStreams.new(seed_value)
	bus = SimEventBus.new()
	commands = CommandQueue.new()
	clock = GameClock.new()
	curves = DayCurveSet.new()
	if not curves.load_from(time_data):
		boot_errors.append_array(curves.errors)
	modifiers = ModifierStack.new()
	scheduler = TickScheduler.new(clock, curves, modifiers)
	timers = TimerService.new()
	work = WorkService.new()
	events = ScheduledEventService.new(time_data.get("event_templates", {}), timers, modifiers)
	catalog = BuildingCatalog.new(buildings_data, rules_data)
	if not catalog.is_valid():
		boot_errors.append("building catalog invalid")
	loader = StarterCityLoader.new()
	if not loader.load_from(starter_data):
		boot_errors.append_array(loader.errors)
	world = loader.world
	districts = DistrictRegistry.new(world, rng)
	construction = ConstructionQueue.new()
	development = DevelopmentController.new(world, construction)
	population = PopulationSystem.new()
	population.attractiveness = float(loader.population.get("attractiveness", 1.0))
	happiness = HappinessModel.new()
	happiness.happiness = float(loader.population.get("happiness", 82.0))
	progression = ProgressionSystem.new()
	stats = StatsRecorder.new()
	econ_curves = CostCurves.new(
			StarterCityLoader.read_json("res://data/building_economy.json"),
			StarterCityLoader.read_json("res://data/economy.json"))
	if not econ_curves.errors.is_empty():
		boot_errors.append_array(econ_curves.errors)
	treasury = Treasury.new(econ_curves.economy_data())
	economy = EconomySystem.new(econ_curves, treasury)
	tax_rate = float((econ_curves.economy_data().get("tax", {}) as Dictionary)
			.get("TAX_RATE_BASE", 0.09))
	tax_rate_changed_hour = -1
	_boot_buildings()
	_boot_power()
	_boot_water()
	_boot_districts()
	_boot_incidents()
	_boot_roads()
	_boot_weather()
	_check_grid_rules()
	_register_systems()
	return boot_errors.is_empty()


func _boot_water() -> void:
	var water_data := WaterData.from_dict(
			StarterCityLoader.read_json("res://data/water.json"))
	if not water_data.is_valid():
		boot_errors.append_array(water_data.errors)
	water = WaterBoot.build(water_data, loader, world.grid)
	# Doc 05 §2.6: water reads power ONLY through doc 04's published function.
	water.powered_provider = func(power_ref: String) -> bool:
		return grid.is_powered(power_ref)
	WaterBoot.attach_buildings(water, loader)
	water.rebuild_zones()
	# Doc 05 owns the per-variant kW at every level, so the site loads
	# doc 02 meters come from the live nodes, not the boot-time L1 table.
	# (Sorted iteration — float addition order is persisted state.)
	_water_kw_by_building.clear()
	var node_ids := water.nodes.keys()
	node_ids.sort()
	for node_id in node_ids:
		var n: WaterNode = water.nodes[node_id]
		if n.variant == &"junction" or n.power_ref == "":
			continue
		_water_kw_by_building[n.power_ref] = \
				float(_water_kw_by_building.get(n.power_ref, 0.0)) \
				+ water.data.kw_required(n.variant, n.level, n.subtype)


func _boot_incidents() -> void:
	incident_catalog = IncidentCatalog.load_from_files()
	if not incident_catalog.is_valid():
		boot_errors.append_array(incident_catalog.errors)
	incident_world = CityIncidentWorld.new(self, incident_catalog)
	incidents = IncidentSystem.new(incident_catalog, incident_world, rng)
	incidents.founding_offset_h = float(GameClock.FOUNDING_OFFSET_MINUTES) / 60.0
	incidents.fleet.populate_from_stations(incident_world.station_rows())


func _boot_roads() -> void:
	var tun := RoadTunables.from_file("res://data/roads.json")
	if not tun.is_valid():
		boot_errors.append_array(tun.errors)
	roads = RoadNetwork.new(world.grid, tun, rng)
	roads.bootstrap()
	roads.power_is_tile_powered = _is_tile_powered      # doc 04 (G-6)
	roads.district_of_tile = _district_of_tile          # doc 09
	roads.land_is_buildable = func(t: Vector2i) -> bool:
		var b := world.block_of_tile(t.x, t.y)
		return b != null and b.is_ready()
	roads.repair_quote = func(road_class: String, damage_fraction: float) -> int:
		return econ_curves.repair_cost_road(road_class, damage_fraction)
	roads.submit_job = func(kind: StringName, target: String, crew_hours: float,
			crew: StringName, payload: Dictionary) -> int:
		var job_id := construction.submit(kind, target, crew_hours, crew, payload)
		construction.assign_crew(job_id, "YARD-CREW-1")   # MVP binding, as buildings do
		return job_id
	_refresh_road_density()
	RoadsPhaseSystems.register_all(scheduler, roads, bus.emit)


func _boot_weather() -> void:
	weather = WeatherSystem.new(
			WeatherTables.load_from_file("res://data/weather.json"), rng)
	if not weather.tables.is_valid():
		boot_errors.append_array(weather.tables.errors)
	weather.set_city_bounds(Vector2(56, 56), 56.0)      # doc 09 map bounds
	weather.attach_modifiers(modifiers)
	for block_id in world.block_ids_sorted():
		var block: LandBlock = world.block(String(block_id))
		weather.flood.register_block(block.grid.x, block.grid.y,
				String(block.elevation_band()))
	director = DisasterDirector.new(
			DirectorTables.load_from_file("res://data/director.json"), rng)
	if not director.tables.is_valid():
		boot_errors.append_array(director.tables.errors)
	# Doc 06's live sink is a Phase-2 seam: director requests are recorded, not
	# executed, so pacing/fairness run without inventing an unmapped incident.
	incident_sink = IncidentRequestSink.Recording.new()
	director.attach(weather, incident_sink, modifiers)
	weather.bootstrap(_boot_context())


func _boot_context() -> TimeContext:
	var ctx := TimeContext.new()
	ctx.tick_index = clock.tick_index
	ctx.minute_of_day = clock.minute_of_day()
	ctx.day_index = clock.day_index()
	ctx.season_index = clock.season_index()
	return ctx


func _refresh_road_density() -> void:
	var sources: Array = []
	for id in _sorted(buildings):
		var b: Building = buildings[id]
		sources.append({"tile": b.origin,
				"pj": float(int(b.stats.get("population", 0)) + int(b.stats.get("jobs", 0)))})
	roads.set_density_sources(sources)


## Doc 04 publishes power state only; doc 10 turns it into delay + congestion
## (G-6). Implemented here because CitySim owns the cross-doc seams.
func _is_tile_powered(tile: Vector2i) -> bool:
	var best := ""
	var best_key := [999999.0, ""]
	for node in loader.power.get("nodes", []):
		if String(node["kind"]) != "transformer":
			continue
		var t := StarterCityLoader.core_to_global(int(node["tile"][0]), int(node["tile"][1]))
		var dist := maxf(absf(tile.x - t.x), absf(tile.y - t.y))
		if dist > float(PowerGrid.TRANSFORMER_SERVICE_RADIUS[int(node.get("level", 1)) - 1]):
			continue
		var key := [dist, String(node["id"])]
		if key < best_key:
			best_key = key
			best = String(node["id"])
	return true if best == "" else grid.is_energized(best)   # uncovered ⇒ lit


func _district_of_tile(tile: Vector2i) -> String:
	var b := world.block_of_tile(tile.x, tile.y)
	return String(_block_to_district.get(b.id, "")) if b != null else ""


## Strikes are generated at WEATHER and resolved before POWER, so the grid sees
## the damage in the same tick it was struck.
func _route_lightning(ctx: TimeContext) -> void:
	if not director.storm.active:
		return
	var now_min: int = ctx.tick_index / GameClock.TICKS_PER_MINUTE
	if now_min != _strike_roster_min:
		_strike_roster = GridStrikeAdapter.roster(grid)
		_strike_roster_min = now_min
	for strike in director.storm.tick(now_min, float(ctx.dt_game_seconds) / 60.0,
			rng, _strike_roster, weather.get_storm_cell(),
			director.target_hard_exclude, director.target_immunity):
		if String(strike["domain"]) == "grid":
			GridStrikeAdapter.resolve(grid, strike, rng)


func build_director_inputs() -> DirectorInputs:
	var dark := 0
	var total := 0
	for id in _sorted(buildings):
		total += 1
		if not grid.is_powered(String(id)):
			dark += 1
	return DirectorInputs.make({
		"city_age_days": clock.day_index(),
		"season_index": clock.season_index(),
		"population": population.city_population,
		"treasury": treasury.balance,
		"daily_opex": maxi(1, int(_last_expense_hour * 24.0)),
		"grid_redundancy": 0.0,      # doc 04 seam — publish and read here
		"water_redundancy": 0.0,     # doc 05 seam
		"road_redundancy": 0.0,      # doc 10 seam
		"units_owned": {},           # doc 06 seam
		"total_response_units": 0,   # doc 06 seam
		"city_stability": districts.city_stability,
		"active_incidents": incidents.active_count(),
		"unresolved_major_incidents": 0,     # doc 06 seam
		"customers_out_pct": float(dark) / float(maxi(1, total)),
		"roads_impassable_pct": 0.0,         # doc 10 seam
		"difficulty": "standard",
	})


## The P0-01 pattern: `data/grid_components.json` republishes doc 04 §2.2's
## service-radius column for the placement layer, so boot asserts it still
## equals the ladder `PowerGrid` mirrors from `data/power.json` §8.
func _check_grid_rules() -> void:
	if grid_rules.is_empty():
		return  # fixture boots may omit the file; placement then refuses every kind
	var row: Dictionary = _placeable_rules("transformer")
	var radii: Array = row.get("service_radius_tiles", [])
	if radii.size() != PowerGrid.TRANSFORMER_SERVICE_RADIUS.size():
		boot_errors.append("grid_components.json: transformer service radius arity")
		return
	for i in radii.size():
		if int(radii[i]) != int(PowerGrid.TRANSFORMER_SERVICE_RADIUS[i]):
			boot_errors.append("grid_components.json: transformer service radius L%d %d != %d"
					% [i + 1, int(radii[i]), int(PowerGrid.TRANSFORMER_SERVICE_RADIUS[i])])


func _placeable_rules(kind: String) -> Dictionary:
	return (grid_rules.get("placeable", {}) as Dictionary).get(kind, {})


func _boot_buildings() -> void:
	for record in loader.buildings:
		var id := String(record["id"])
		var archetype := StringName(String(record["type"]))
		var b := Building.new(int(record["grid_id"]), archetype,
				record["origin_global"], StringName(String(record.get("variant", ""))))
		b.level = int(record.get("level", 1))
		b.state = &"active"
		b.condition = 1.0
		b.stats = catalog.stats(String(archetype), b.level)
		buildings[id] = b
		_building_records[id] = record
	# Water-site kW loads are derived from the LIVE water nodes in _boot_water,
	# which runs right after _boot_power — doc 05 owns per-variant kW now.


func _boot_power() -> void:
	grid = PowerGrid.new()
	for node in loader.power.get("nodes", []):
		var kind := String(node["kind"])
		var opts := {"level": int(node.get("level", 1))}
		match kind:
			"plant_gas":
				grid.add_component(String(node["id"]), &"plant_gas", opts)
			"substation":
				grid.add_component(String(node["id"]), &"substation", opts)
			"transformer":
				var tile: Vector2i = StarterCityLoader.core_to_global(
						int(node["tile"][0]), int(node["tile"][1]))
				opts["parent"] = String(node["feeder"])
				opts["tile"] = tile
				grid.add_component(String(node["id"]), &"transformer", opts)
	for line in loader.power.get("lines", []):
		var kind := String(line["kind"])
		var route: Array = []
		for tile in StarterCityLoader.polyline_tiles(line.get("path", [])):
			route.append([tile.x + StarterCityLoader.CORE_TILE_OFFSET,
					tile.y + StarterCityLoader.CORE_TILE_OFFSET])
		if kind == "transmission":
			# Transmission links hang off their substation (the "to" end).
			grid.add_component(String(line["id"]), &"transmission",
					{"conductor_class": int(line.get("class", 1)), "parent": String(line["to"]),
					"route": route})
		else:
			for lateral in line.get("laterals", []):
				for tile in StarterCityLoader.polyline_tiles(lateral):
					route.append([tile.x + StarterCityLoader.CORE_TILE_OFFSET,
							tile.y + StarterCityLoader.CORE_TILE_OFFSET])
			grid.add_component(String(line["id"]), &"feeder",
					{"conductor_class": int(line.get("class", 1)), "parent": String(line["from"]),
					"route": route, "underground": not bool(line.get("overhead", true))})
	for id in _sorted(buildings):
		var b: Building = buildings[id]
		if b.archetype == &"substation":
			continue  # no service draw (doc 04 §2.3)
		var priority: StringName = &"CRITICAL" if b.archetype == &"water_facility" else &"STANDARD"
		var attached := grid.attach_building(id, b.origin, priority,
				String(_building_records[id].get("block", "")))
		if attached == "":
			boot_errors.append("building %s has no transformer in range" % id)


func _boot_districts() -> void:
	for d in loader.districts:
		var district_id: String = districts.create_district(
				d.get("blocks", []), String(d.get("name", "")), String(d["id"]))
		# Doc 09 t0 placeholders pending doc 06's live values.
		districts.set_indices(district_id, 0.10, 0.12, 0.0)
	for d in loader.districts:
		for block_id in d.get("blocks", []):
			_block_to_district[String(block_id)] = String(d["id"])
	for id in _sorted(buildings):
		var b: Building = buildings[id]
		_block_dark_weights[id] = int(b.stats.get("population", 0)) + int(b.stats.get("jobs", 0))
	# The city is born already inhabited: aggregates are live from tick 0, so
	# the first settled hour sees real employment, not a zero warm-up.
	_rollup_district_population()
	for district_id in districts.district_ids_sorted():
		districts.recompute_fast(district_id)
	districts.recompute_slow(0.0)


## Composed per-building electrical demand (doc 04 §2.3, doc 02 §2.5):
## base_kw × state × channel. Occupancy folds in at the hourly rollup;
## weather multiplier is 1.0 in the clear-sky stub.
func compose_demands(ctx: TimeContext) -> Dictionary:
	var demands := {}
	for id in _sorted(buildings):
		var b: Building = buildings[id]
		if b.archetype == &"substation":
			continue
		var base := float(b.stats.get("power_demand_kw", 0.0))
		if b.archetype == &"water_facility":
			base = float(_water_kw_by_building.get(id, base))
		var channel := String(DEMAND_CLASS_CHANNEL.get(b.archetype, "power_demand_civic"))
		var occ := population.occ_of(id)
		demands[id] = base * b.power_demand_mult() * float(ctx.channels[channel]) * occ
	return demands


func distributed_sinks(ctx: TimeContext) -> Dictionary:
	var streetlight_factor := float(ctx.channels["streetlight_load"])
	var out := {}
	for node in loader.power.get("nodes", []):
		if String(node["kind"]) != "transformer":
			continue
		var kw := float(node.get("streetlights", 0)) * STREETLIGHT_KW * streetlight_factor \
				+ float(node.get("signals", 0)) * SIGNAL_KW
		if kw > 0.0:
			out[String(node["id"])] = kw
	return out


func advance_hours(hours: float) -> void:
	scheduler.advance_fine_n(roundi(hours * GameClock.TICKS_PER_HOUR))


func advance_coarse_hours(hours: int, is_catchup: bool = true) -> void:
	if is_catchup and director != null:
		director.catchup_begin()   # doc 07 C-55: once per catch-up session
	scheduler.advance_coarse_n(hours, is_catchup, 0, hours)


## Capture for SAVING. Godot's full-precision JSON printer is not
## shortest-round-trip for every double (≤1 ULP loss, and not even
## idempotent), so decimal text can never carry sim floats. Floats are
## encoded as exact 64-bit hex strings ("~f~<16 hex>") — lossless through
## any number of JSON round-trips, so the instance that saved and the
## instance that loads proceed bit-identically (constitution §5, M1
## criterion 8). restore_state() decodes transparently.
func canonical_capture() -> Dictionary:
	return _encode_floats(capture_state())


static func _encode_floats(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			# Integral values canonicalize as ints (exactly representable either
			# way; consumers cast on read) so int/float typing between a live
			# and a loaded state can never alias. Only true fractions need bits.
			if absf(value) < 4.6e18 and value == float(int(value)):
				return int(value)
			var bytes := PackedByteArray()
			bytes.resize(8)
			bytes.encode_double(0, value)
			# Two u32 halves, high first — the same 16 hex chars "%016x" printed,
			# but sign-bit-set doubles survive: a whole-u64 "%016x" prints a
			# NEGATIVE int with a minus sign, and hex_to_int refuses any pattern
			# above int64 max, so both full-width paths break on negative doubles.
			return "~f~%08x%08x" % [bytes.decode_u32(4), bytes.decode_u32(0)]
		TYPE_DICTIONARY:
			var out_dict := {}
			for key in value:
				out_dict[key] = _encode_floats(value[key])
			return out_dict
		TYPE_ARRAY:
			var out_array := []
			for entry in value:
				out_array.append(_encode_floats(entry))
			return out_array
		_:
			return value


static func _decode_floats(value: Variant) -> Variant:
	match typeof(value):
		TYPE_STRING:
			if (value as String).begins_with("~f~"):
				var hex := (value as String).substr(3)
				var bytes := PackedByteArray()
				bytes.resize(8)
				bytes.encode_u32(4, ("0x" + hex.substr(0, 8)).hex_to_int())
				bytes.encode_u32(0, ("0x" + hex.substr(8, 8)).hex_to_int())
				return bytes.decode_double(0)
			return value
		TYPE_DICTIONARY:
			var out_dict := {}
			for key in value:
				out_dict[key] = _decode_floats(value[key])
			return out_dict
		TYPE_ARRAY:
			var out_array := []
			for entry in value:
				out_array.append(_decode_floats(entry))
			return out_array
		_:
			return value


## Full state capture/restore. NOTE (tech debt vs report 98 §11): Milestone 1
## ships ONE "city" save section; the per-system section split with individual
## migration ladders lands with the doc 08 integration pass.
func capture_state() -> Dictionary:
	return {
		"clock": clock.serialize(),
		"rng": rng.serialize(),
		"grid": grid.serialize(),
		"districts": districts.serialize(),
		"population": population.serialize(),
		"happiness": happiness.serialize(),
		"progression": progression.serialize(),
		"world_blocks": world.serialize_blocks(),
		"timers": timers.serialize(),
		"work": work.serialize(),
		"events": events.serialize(),
		"construction": construction.serialize(),
		"development": development.serialize(),
		"buildings": _serialize_buildings(),
		"treasury": treasury.serialize(),
		"stats": stats.serialize(),
		"placed_records": _serialize_placed_records(),
		"removed_records": _serialize_removed_records(),
		"policy": {"tax_rate": tax_rate, "tax_rate_changed_hour": tax_rate_changed_hour,
				"grid_id_high_water": _grid_id_high_water},
		"water": water.serialize(),
		"incidents": incidents.serialize_incidents(),
		"fleet": incidents.fleet.serialize(),
		"dispatch": incidents.dispatch.serialize(),
		"roads": roads.save_section(),
		"weather": weather.serialize(),
		"director": director.serialize(),
	}


## Demolished AUTHORED buildings (doc 02 §2.12): the loader re-creates and
## re-stamps them on every boot, so the save has to say which ones are gone.
## Player buildings need no row — they simply stop appearing in
## `placed_records` — which keeps this list bounded by the authored roster
## however long the city runs; `policy.grid_id_high_water` retires their ids.
func _serialize_removed_records() -> Array:
	var out: Array = []
	for sim_id in _sorted(_removed_records):
		var record: Dictionary = _removed_records[sim_id]
		out.append({"id": sim_id, "grid_id": int(record["grid_id"]),
				"type": String(record["type"]),
				"footprint": [record["footprint"].x, record["footprint"].y],
				"origin": [record["origin"].x, record["origin"].y]})
	return out


## Player-placed buildings have no authored loader record — persist theirs.
func _serialize_placed_records() -> Array:
	var out: Array = []
	for sim_id in _sorted(_building_records):
		var record: Dictionary = _building_records[sim_id]
		if String(sim_id).begins_with("P-"):
			out.append({"id": sim_id, "grid_id": int(record["grid_id"]),
					"type": String(record["type"]), "block": String(record["block"]),
					"footprint": [record["footprint"].x, record["footprint"].y],
					"origin": [record["origin_global"].x, record["origin_global"].y]})
	return out


func restore_state(raw_body: Dictionary) -> void:
	var body: Dictionary = _decode_floats(raw_body)
	clock.deserialize(body.get("clock", {}))
	rng.deserialize(body.get("rng", {}))
	grid.deserialize(body.get("grid", {}))
	districts.deserialize(body.get("districts", {}))
	population.deserialize(body.get("population", {}))
	happiness.deserialize(body.get("happiness", {}))
	progression.deserialize(body.get("progression", {}))
	timers.deserialize(body.get("timers", {}))
	work.deserialize(body.get("work", {}))
	events.deserialize(body.get("events", {}))
	construction.deserialize(body.get("construction", {}))
	development.deserialize(body.get("development", {}))
	treasury.deserialize(body.get("treasury", {}))
	stats.deserialize(body.get("stats", {}))
	for saved in body.get("world_blocks", []):
		var block := world.block(String(saved.get("id", "")))
		if block != null:
			block.apply_save(saved)
	# Tile flags are derived from block state, not persisted, so any block that
	# reached READY while the game was running has to be re-opened here — the
	# loader only did it for the blocks that shipped READY.
	for block_id in world.block_ids_sorted():
		if (world.block(block_id) as LandBlock).is_ready():
			_open_block_for_building(block_id)
	# Demolitions are replayed FIRST, against the loader's authored stamps, so a
	# tile a demolition freed is genuinely free before anything re-stamps it.
	_removed_records.clear()
	for record in body.get("removed_records", []):
		var gone_id := String(record["id"])
		var gone_footprint := Vector2i(int(record["footprint"][0]), int(record["footprint"][1]))
		var gone_origin := Vector2i(int(record["origin"][0]), int(record["origin"][1]))
		_removed_records[gone_id] = {"grid_id": int(record["grid_id"]),
				"type": String(record["type"]), "footprint": gone_footprint,
				"origin": gone_origin}
		world.grid.remove_building(int(record["grid_id"]), gone_origin, gone_footprint)
		_building_records.erase(gone_id)
	for record in body.get("placed_records", []):
		var sim_id := String(record["id"])
		var footprint := Vector2i(int(record["footprint"][0]), int(record["footprint"][1]))
		var origin := Vector2i(int(record["origin"][0]), int(record["origin"][1]))
		_building_records[sim_id] = {"id": sim_id, "grid_id": int(record["grid_id"]),
				"type": String(record["type"]), "block": String(record["block"]),
				"footprint": footprint, "origin_global": origin}
		world.grid.stamp_building(int(record["grid_id"]), origin, footprint)
	# Player-placed grid components carry a one-tile reservation the loader knows
	# nothing about; the power section is already restored, so re-stamp from it.
	for component_id in grid.component_ids():
		var component: Dictionary = grid.component(component_id)
		if bool(component.get("player_placed", false)):
			var tile: Vector2i = component["tile"]
			if TileGrid.in_bounds(tile.x, tile.y):
				world.grid.set_flag(tile.x, tile.y, TileGrid.FLAG_OCCUPIED)
	var policy: Dictionary = body.get("policy", {})
	tax_rate = float(policy.get("tax_rate", tax_rate))
	tax_rate_changed_hour = int(policy.get("tax_rate_changed_hour", -1))
	_grid_id_high_water = int(policy.get("grid_id_high_water", 0))
	for sim_id in _removed_records:
		_grid_id_high_water = maxi(_grid_id_high_water,
				int(_removed_records[sim_id]["grid_id"]))
	buildings.clear()
	for record in body.get("buildings", []):
		var b := Building.deserialize(record)
		var id := ""
		for candidate_id in _building_records:
			if int(_building_records[candidate_id]["grid_id"]) == b.id:
				id = candidate_id
				break
		if id == "":
			continue
		b.stats = catalog.stats(String(b.archetype), maxi(b.level, 1))
		buildings[id] = b
	# Block-dark weights are derived from the live roster, so rebuild rather than
	# carry: a demolished building must not keep voting on its block's darkness.
	_block_dark_weights.clear()
	for id in _sorted(buildings):
		var live: Building = buildings[id]
		_block_dark_weights[id] = int(live.stats.get("population", 0)) \
				+ int(live.stats.get("jobs", 0))
	water.deserialize(body.get("water", {}))
	incidents.deserialize_incidents(body.get("incidents", {}))
	incidents.fleet.deserialize(body.get("fleet", {}))
	incidents.dispatch.deserialize(body.get("dispatch", {}))
	roads.load_section(body.get("roads", {}))
	weather.deserialize(body.get("weather", {}))
	director.deserialize(body.get("director", {}))
	_refresh_road_density()


## Deterministic digest of the full sim state (Milestone 1 criterion 4).
## Floats are hex-encoded (bit-exact) before hashing; one JSON round-trip
## then normalizes int/float typing differences between a live state and a
## loaded one so they never alias into a hash mismatch.
func state_hash() -> String:
	var encoded: Variant = canonical_capture()
	var normalized: Variant = JSON.parse_string(JSON.stringify(encoded, "", true, true))
	var text := JSON.stringify(normalized, "", true, true)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode()


func _serialize_buildings() -> Array:
	var out: Array = []
	for id in _sorted(buildings):
		out.append((buildings[id] as Building).serialize())
	return out


func _population_inputs() -> Array:
	var out: Array = []
	for id in _sorted(buildings):
		var b: Building = buildings[id]
		var category := catalog.category(String(b.archetype))
		out.append({
			"id": id,
			"population": int(b.stats.get("population", 0)),
			"jobs": int(b.stats.get("jobs", 0)),
			"residential": category == "residential",
			"civic": category == "service" or category == "utility",
			"state_occupancy": b.state_occupancy(),
			"age_hours": 48.0,  # authored starter age ≥ ramp horizon
		})
	return out


# ------------------------------------------------------- player commands

## Place a new building (doc 02 §2.12 place path). Charges doc 03's cost,
## reserves tiles, submits the construction job. Level-1 only (LOCKED rule).
func cmd_place_building(archetype: String, origin: Vector2i, variant: String = "") -> Dictionary:
	if not catalog.has(archetype):
		return CommandQueue.fail(&"E_UNKNOWN_ARCHETYPE")
	var block := world.block_of_tile(origin.x, origin.y)
	if block == null or not block.is_owned():
		return CommandQueue.fail(&"E_NOT_OWNED")
	if not block.is_ready():
		return CommandQueue.fail(&"E_NOT_DEVELOPED")
	var stats: Dictionary = catalog.stats(archetype, 1)
	var foot: Array = stats.get("footprint", [1, 1])
	var size := Vector2i(int(foot[0]), int(foot[1]))
	if not world.grid.can_place(origin, size):
		return CommandQueue.fail(&"E_FOOTPRINT")
	if not grid.would_serve(origin):
		# Doc 04 §2.1: unservable placements are blocked; the fix is a
		# transformer (grid-component placement is the Phase-1 command).
		return CommandQueue.fail(&"E_UNSERVED")
	var cost := econ_curves.build_cost(archetype)
	if treasury.balance < cost:
		# Construction never auto-borrows; the credit ladder is for crises.
		return CommandQueue.fail(&"E_FUNDS", {"cost": cost, "balance": treasury.balance})
	treasury.spend(cost, &"construction")
	var grid_id := _next_building_grid_id()
	var sim_id := "P-%03d" % grid_id
	var b := Building.new(grid_id, StringName(archetype), origin, StringName(variant))
	b.stats = stats
	b.built_at_minutes = clock.sim_time_minutes()
	world.grid.stamp_building(grid_id, origin, size)
	buildings[sim_id] = b
	_building_records[sim_id] = {"id": sim_id, "grid_id": grid_id, "type": archetype,
			"block": block.id, "footprint": size, "origin_global": origin}
	_block_dark_weights[sim_id] = int(stats.get("population", 0)) + int(stats.get("jobs", 0))
	var job_id := construction.submit(&"build", sim_id,
			float(stats.get("build_time_hours", 4.0)), &"construction_crew",
			{"sim_id": sim_id, "cost": cost})
	# MVP crew binding: doc 06 owns real crews (P1-15); until then every job
	# gets the yard crew so construction progresses.
	construction.assign_crew(job_id, "YARD-CREW-1")
	b.start_construction()
	grid.attach_building(sim_id, origin, &"STANDARD", block.id)
	water.attach_building(sim_id, origin, archetype)
	_refresh_road_density()
	bus.emit(&"building_placed_sim", {"building": grid_id, "sim_id": sim_id,
			"archetype": archetype, "cost": cost})
	stats_add(&"buildings_built")
	return CommandQueue.ok({"sim_id": sim_id, "cost": cost, "job_id": job_id})


## The doc 02 §2.11 upgrade gate. Checks run in the documented order and the
## FIRST blocker returns (the UI shows the full checklist via preview=true).
func cmd_upgrade_building(sim_id: String, preview: bool = false) -> Dictionary:
	var b: Building = buildings.get(sim_id)
	if b == null:
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING")
	var blockers: Array = []
	if b.state != &"active":
		blockers.append(&"E_STATE")
	if b.level >= 5:
		blockers.append(&"E_MAX_LEVEL")
	if b.condition < Building.MIN_CONDITION_TO_UPGRADE:
		blockers.append(&"E_CONDITION")
	var next_level: int = mini(b.level + 1, 5)
	var next_stats: Dictionary = catalog.stats(String(b.archetype), next_level)
	if progression.city_level < int(next_stats.get("min_city_level", 0)):
		blockers.append(&"E_CITY_LEVEL")
	var cost := econ_curves.upgrade_cost(String(b.archetype), b.level)
	if treasury.balance < cost:
		blockers.append(&"E_FUNDS")
	var delta_kw := float(next_stats.get("power_demand_kw", 0.0)) \
			- float(b.stats.get("power_demand_kw", 0.0))
	var headroom := grid.can_upgrade_power(sim_id, delta_kw * 1.15)
	if not bool(headroom["ok"]):
		blockers.append(&"E_POWER_HEADROOM")
	var delta_water := float(next_stats.get("water_demand", 0.0)) \
			- float(b.stats.get("water_demand", 0.0))
	if not bool(water.can_upgrade_water(sim_id, delta_water)["ok"]):
		blockers.append(&"E_WATER_HEADROOM")
	if next_level >= 4 and not _avenue_within(b.origin, 4):
		blockers.append(&"E_AVENUE")
	if preview or not blockers.is_empty():
		var result := CommandQueue.ok({"blockers": blockers, "cost": cost,
				"deficit_kw": headroom.get("deficit_kw", 0.0)}) if blockers.is_empty() \
				else CommandQueue.fail(blockers[0], {"blockers": blockers, "cost": cost,
				"deficit_kw": headroom.get("deficit_kw", 0.0)})
		if preview or not blockers.is_empty():
			return result
	treasury.spend(cost, &"construction")
	b.start_upgrade()
	var job_id := construction.submit(&"upgrade", sim_id,
			float(next_stats.get("upgrade_time_hours", 4.0)), &"construction_crew",
			{"sim_id": sim_id, "cost": cost})
	construction.assign_crew(job_id, "YARD-CREW-1")
	bus.emit(&"upgrade_started_sim", {"sim_id": sim_id, "to_level": next_level, "cost": cost})
	return CommandQueue.ok({"job_id": job_id, "cost": cost, "to_level": next_level})


# ------------------------------------------------- doc 04 §2.1 grid placement

## Place a grid component (doc 04 §2.1). Wave 1.5 ships the transformer — the
## verb that turns `E_UNSERVED` from a wall into a purchase.
##
## Checks run in this documented order; the FIRST blocker is the reason code and
## the full list rides in `payload.blockers` (the UI shows the checklist with
## `preview = true`, which also quotes the price and the feeder it would tap):
##
##   1 E_UNKNOWN_COMPONENT  kind is not in data/grid_components.json `placeable`
##   2 E_LEVEL_UNAVAILABLE  level outside that kind's `placeable_levels`
##   3 E_OUT_OF_BOUNDS      tile off the 112×112 world
##   4 E_NOT_OWNED          the tile's land block is not owned
##   5 E_NOT_DEVELOPED      the block has not reached READY
##   6 E_FOOTPRINT          the tile is roaded / watered / blocked / occupied
##   7 E_NO_FEEDER          no tappable feeder within `feeder_tap_radius_tiles`
##   8 E_FUNDS              treasury below the quoted price
##
## Price = doc 03 §2.13(b) `transformer` build cost at `level`, plus the feeder
## lateral it takes to reach the tap, charged per tile at §2.13(b)'s feeder
## price for that feeder's conductor class (and its underground multiplier).
## Nothing is charged on a preview or on any failure.
func cmd_place_grid_component(kind: String, tile: Vector2i, level: int = 1,
		preview: bool = false) -> Dictionary:
	var rules := _placeable_rules(kind)
	if rules.is_empty():
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT", {"blockers": [&"E_UNKNOWN_COMPONENT"]})
	# JSON numbers arrive as floats; compare on ints so a level never misses its
	# own row by type (the SaveSection cast-on-read contract, applied to data).
	var levels: Array = []
	for entry in (rules.get("placeable_levels", []) as Array):
		levels.append(int(entry))
	if not levels.has(level):
		return CommandQueue.fail(&"E_LEVEL_UNAVAILABLE",
				{"blockers": [&"E_LEVEL_UNAVAILABLE"], "placeable_levels": levels})

	var blockers: Array = []
	if not TileGrid.in_bounds(tile.x, tile.y):
		return CommandQueue.fail(&"E_OUT_OF_BOUNDS", {"blockers": [&"E_OUT_OF_BOUNDS"]})
	var block := world.block_of_tile(tile.x, tile.y)
	if bool(rules.get("requires_block_owned", true)) \
			and (block == null or not block.is_owned()):
		blockers.append(&"E_NOT_OWNED")
	elif bool(rules.get("requires_block_ready", true)) and not block.is_ready():
		blockers.append(&"E_NOT_DEVELOPED")
	var size := Vector2i(int(rules.get("footprint_tiles", 1)),
			int(rules.get("footprint_tiles", 1)))
	if not world.grid.can_place(tile, size):
		blockers.append(&"E_FOOTPRINT")
	var tap := grid.nearest_feeder_tap(tile, int(rules.get("feeder_tap_radius_tiles", 0)))
	var lateral: Array = []
	var cost := econ_curves.grid_build_cost(kind, level,
			float(treasury.difficulty().get("M_build", 1.0)))
	if tap.is_empty():
		blockers.append(&"E_NO_FEEDER")
	else:
		lateral = PowerGrid.lateral_tiles(tap["tap_tile"], tile)
		cost += lateral.size() * econ_curves.grid_line_cost_per_tile(
				"feeder", int(tap["conductor_class"]), bool(tap["underground"]))
	if treasury.balance < cost:
		blockers.append(&"E_FUNDS")

	# `level` already passed the roster check, so its radius row exists.
	var radii: Array = rules.get("service_radius_tiles", [])
	var quote := {"blockers": blockers, "cost": cost,
			"feeder": String(tap.get("feeder", "")),
			"tap_distance": int(tap.get("distance", -1)),
			"lateral_tiles": lateral.size(),
			"service_radius_tiles": int(radii[level - 1])}
	if not blockers.is_empty():
		return CommandQueue.fail(blockers[0], quote)
	if preview:
		return CommandQueue.ok(quote)

	treasury.spend(cost, &"construction")
	var component_id := _next_component_id(kind)
	grid.add_component(component_id, StringName(kind), {
		"level": level, "parent": String(tap["feeder"]), "tile": tile,
		"player_placed": true,
	})
	grid.extend_route(String(tap["feeder"]), lateral)
	# One tile of grid geometry, reserved so nothing is built on top of it
	# (doc 04 §2.1: a transformer is not a building and has no footprint row).
	world.grid.set_flag(tile.x, tile.y, TileGrid.FLAG_OCCUPIED)
	# The new node joins the tree live: `add_component` dirtied the topology, so
	# the next tick's Pass D energizes it. Orphans adopt it now, not next tick,
	# so `would_serve` and `cmd_place_building` agree within the same command.
	var adopted := _reattach_unserved()
	bus.emit(&"grid_component_placed", {"component": component_id, "kind": kind,
			"level": level, "tile": [tile.x, tile.y], "feeder": String(tap["feeder"]),
			"lateral_tiles": lateral.size(), "cost": cost, "adopted": adopted})
	stats_add(&"grid_components_placed")
	quote["component"] = component_id
	quote["adopted"] = adopted
	return CommandQueue.ok(quote)


## Player component ids are `<PREFIX>-NNN`, numbered above every id the grid
## already carries so a reload can never collide with an authored node.
func _next_component_id(kind: String) -> String:
	var prefix := "P" + String(kind).substr(0, 1).to_upper()
	var highest := 0
	for id in grid.component_ids():
		if id.begins_with(prefix + "-"):
			highest = maxi(highest, id.substr(prefix.length() + 1).to_int())
	return "%s-%03d" % [prefix, highest + 1]


## Re-run service attachment for every building the grid lists as unserved.
## Returns the sim_ids that found a transformer, sorted.
func _reattach_unserved() -> Array:
	var adopted: Array = []
	for sim_id in grid.unserved_building_ids():
		var b: Building = buildings.get(sim_id)
		if b == null:
			continue
		var block_id := String(_building_records.get(sim_id, {}).get("block", ""))
		if grid.attach_building(sim_id, b.origin, grid.priority_class_of(sim_id),
				block_id) != "":
			adopted.append(sim_id)
	return adopted


# --------------------------------------------------- doc 02 §2.12 demolition

## Demolish a building (doc 02 §2.12). Order of checks:
##
##   1 E_UNKNOWN_BUILDING  no such sim_id
##   2 E_STATE             `on_fire` (suppress it first) or `destroyed`
##                         (that is `clear_rubble`, a different verb)
##
## Refund (doc 03 §2.3 / §2.10): `DEMOLITION_REFUND_FRACTION 0.25 ×
## capital_value(type, level)` for what is standing, PLUS the construction
## queue's own §2.10 refund fraction on any job still in flight against the
## money that job was charged (1.00 never started, 0.50 upgrade, else
## `0.60 × (1 − progress)`). A level-0 site — placed but never completed — has
## no capital, so its whole refund comes from the queue.
func cmd_demolish_building(sim_id: String, preview: bool = false) -> Dictionary:
	var b: Building = buildings.get(sim_id)
	if b == null:
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING", {"blockers": [&"E_UNKNOWN_BUILDING"]})
	if b.state == &"on_fire" or b.state == &"destroyed":
		return CommandQueue.fail(&"E_STATE", {"blockers": [&"E_STATE"],
				"state": String(b.state)})
	var record: Dictionary = _building_records.get(sim_id, {})
	var type := String(record.get("type", String(b.archetype)))
	var capital_refund := 0
	if b.level >= 1:
		capital_refund = econ_curves.demolition_refund_building(type, b.level)
	var job_refund := 0
	var job_ids: Array = []
	for job in construction.active_jobs():
		if String((job.get("payload", {}) as Dictionary).get("sim_id", "")) != sim_id:
			continue
		job_ids.append(int(job["job_id"]))
		var fraction := _queue_refund_fraction(job)
		job_refund += CostCurves.round_half_up(
				float(int((job["payload"] as Dictionary).get("cost", 0))) * fraction)
	var refund := capital_refund + job_refund
	var quote := {"blockers": [], "refund": refund, "capital_refund": capital_refund,
			"job_refund": job_refund, "cancelled_jobs": job_ids.duplicate(),
			"level": b.level}
	if preview:
		return CommandQueue.ok(quote)

	for job_id in job_ids:
		construction.cancel(job_id)
	var footprint: Vector2i = record.get("footprint", Vector2i.ONE)
	if not record.has("footprint"):
		var stats_row: Dictionary = catalog.stats(type, maxi(b.level, 1))
		var foot: Array = stats_row.get("footprint", [1, 1])
		footprint = Vector2i(int(foot[0]), int(foot[1]))
	world.grid.remove_building(b.id, b.origin, footprint)
	grid.detach_building(sim_id)
	water.detach_building(sim_id)
	buildings.erase(sim_id)
	_building_records.erase(sim_id)
	_block_dark_weights.erase(sim_id)
	_last_construction_stage.erase(sim_id)
	_last_demands.erase(sim_id)
	_refresh_road_density()
	_grid_id_high_water = maxi(_grid_id_high_water, b.id)
	if not sim_id.begins_with("P-"):
		# Only an AUTHORED building needs a replay row: the loader re-creates and
		# re-stamps it on every boot, so the save has to say it is gone.
		_removed_records[sim_id] = {"grid_id": b.id, "type": type,
				"footprint": footprint, "origin": b.origin}
	if refund > 0:
		treasury.credit(refund, &"construction", "demolition " + sim_id)
	# Aggregates must not lag a demolition by an hour: the district rollup is the
	# only place population/jobs live, so refresh it now.
	_rollup_district_population()
	bus.emit(&"building_removed", {"building": b.id, "sim_id": sim_id,
			"archetype": type, "refund": refund, "cause": &"demolished"})
	stats_add(&"buildings_demolished")
	return CommandQueue.ok(quote)


## The §2.10 refund table, read off a live job exactly as `ConstructionQueue`
## applies it on cancel (kept in step by test, not by copy-paste discipline).
func _queue_refund_fraction(job: Dictionary) -> float:
	if int(job["work_units"]) == 0 and (job["assigned_crews"] as Dictionary).is_empty():
		return 1.0
	if job["kind"] == &"upgrade":
		return 0.50
	return 0.60 * (1.0 - construction.progress(int(job["job_id"])))


# ------------------------------------------------------ doc 02 §2.6 repair

## Repair a building back toward condition 1.00 (doc 02 §2.6). Order of checks:
##
##   1 E_UNKNOWN_BUILDING  no such sim_id
##   2 E_STATE             not `active` or `damaged` (a site under construction,
##                         a fire and a ruin all have their own verbs)
##   3 E_NOT_DAMAGED       condition is already 1.00 — nothing to buy
##   4 E_JOB_IN_FLIGHT     a repair job for this building is already queued
##   5 E_FUNDS             treasury below the quoted price
##
## Price is doc 03 §2.5's single repair formula, `capital_value(L) ×
## damage_fraction × REPAIR_COST_PER_CAPITAL × M_repair`; crew-hours are doc 02
## §2.6's `build_time_hours(L) × 0.50 × damage_fraction`. The job goes into the
## same `ConstructionQueue` as everything else, with kind `repair`, and
## `Building.complete_repair` applies §2.12's target — 1.00 from `active`,
## 0.85 from `damaged`, because post-damage repairs never restore to new.
func cmd_repair_building(sim_id: String, preview: bool = false) -> Dictionary:
	var b: Building = buildings.get(sim_id)
	if b == null:
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING", {"blockers": [&"E_UNKNOWN_BUILDING"]})
	var blockers: Array = []
	if b.state != &"active" and b.state != &"damaged":
		blockers.append(&"E_STATE")
	var damage := b.damage_fraction()
	if damage <= 0.0:
		blockers.append(&"E_NOT_DAMAGED")
	for job in construction.active_jobs():
		if job["kind"] == &"repair" \
				and String((job.get("payload", {}) as Dictionary).get("sim_id", "")) == sim_id:
			blockers.append(&"E_JOB_IN_FLIGHT")
			break
	var type := String(_building_records.get(sim_id, {}).get("type", String(b.archetype)))
	var cost := econ_curves.repair_cost_building(type, maxi(b.level, 1), damage,
			float(treasury.difficulty().get("M_repair", 1.0)))
	if treasury.balance < cost:
		blockers.append(&"E_FUNDS")
	var target := 1.0 if b.state == &"active" else Building.REPAIR_TARGET_FROM_DAMAGED
	var quote := {"blockers": blockers, "cost": cost, "damage_fraction": damage,
			"crew_hours": b.repair_crew_hours(), "repair_target": target}
	if not blockers.is_empty():
		return CommandQueue.fail(blockers[0], quote)
	if preview:
		return CommandQueue.ok(quote)

	treasury.spend(cost, &"repair", "repair " + sim_id)
	var started := b.start_repair()
	if not bool(started["ok"]):
		return started  # unreachable: the state gate above already passed
	var crew_hours := float(started["payload"]["crew_hours"])
	var job_id := construction.submit(&"repair", sim_id, crew_hours,
			&"construction_crew",
			{"sim_id": sim_id, "cost": cost,
			"repair_target": float(started["payload"]["repair_target"])})
	construction.assign_crew(job_id, "YARD-CREW-1")
	bus.emit(&"repair_started_sim", {"sim_id": sim_id, "building": b.id, "cost": cost,
			"damage_fraction": damage, "crew_hours": crew_hours})
	quote["job_id"] = job_id
	return CommandQueue.ok(quote)


# ------------------------------------------- doc 04 §2.4 shedding priority

## Set a building's load priority (doc 04 §2.4). The class lives on the grid's
## service record, which is exactly what the shed score reads, so a CRITICAL
## load survives a rolling blackout its STANDARD neighbours do not.
##
##   1 E_UNKNOWN_BUILDING  no such sim_id
##   2 E_UNKNOWN_PRIORITY  not one of data/grid_components.json `priority.classes`
##                         (aliases are resolved first — `PRIORITY` ⇒ ESSENTIAL)
##   3 E_UNSERVED          the building has no grid service record at all
##
## Free: doc 03 prices no policy change.
func cmd_set_priority(sim_id: String, priority_class: String) -> Dictionary:
	if not buildings.has(sim_id):
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING", {"blockers": [&"E_UNKNOWN_BUILDING"]})
	var priority: Dictionary = grid_rules.get("priority", {})
	var resolved := String((priority.get("aliases", {}) as Dictionary).get(
			priority_class, priority_class))
	var classes: Array = priority.get("classes", [])
	if not classes.has(resolved):
		return CommandQueue.fail(&"E_UNKNOWN_PRIORITY",
				{"blockers": [&"E_UNKNOWN_PRIORITY"], "classes": classes.duplicate()})
	var previous := grid.priority_class_of(sim_id)
	if not grid.set_priority_class(sim_id, StringName(resolved)):
		return CommandQueue.fail(&"E_UNSERVED", {"blockers": [&"E_UNSERVED"]})
	bus.emit(&"building_priority_changed", {"sim_id": sim_id,
			"building": (buildings[sim_id] as Building).id,
			"priority_class": resolved, "previous": String(previous)})
	return CommandQueue.ok({"blockers": [], "priority_class": resolved,
			"previous": String(previous)})


# ------------------------------------------------------- doc 03 §2.2 tax rate

## How many detents the tax slider has: `TAX_RATE_MIN … TAX_RATE_MAX` in
## `TAX_RATE_STEP` increments, computed in basis points so no detent can drift.
# --------------------------------------------------- doc 06 player commands

func cmd_dispatch_unit(unit_id: int, incident_id: int) -> Dictionary:
	return incidents.dispatch.cmd_dispatch_unit(unit_id, incident_id, incidents.now_h)


func cmd_recall_unit(unit_id: int) -> Dictionary:
	return incidents.dispatch.cmd_recall_unit(unit_id)


func cmd_pin_incident(incident_id: int, pinned: bool) -> Dictionary:
	return incidents.dispatch.cmd_pin_incident(incident_id, pinned)


func cmd_acknowledge_incident(incident_id: int) -> Dictionary:
	return incidents.dispatch.cmd_acknowledge_incident(incident_id)


func cmd_set_dispatch_policy(key: String, value: Variant) -> Dictionary:
	return incidents.dispatch.cmd_set_policy(key, value)


## The doc 12 P1-38 onboarding hook: the tutorial's transformer cooks on cue.
func trigger_tutorial_transformer_failure() -> Incident:
	return incidents.spawn_scripted_from_tag(loader, "transformer_fail")


func tax_level_count() -> int:
	var t := _tax_ladder()
	return (int(t[1]) - int(t[0])) / int(t[2]) + 1


## The rate at a detent, and its inverse. Level 5 is exactly `TAX_RATE_BASE`.
func tax_rate_for_level(level: int) -> float:
	var t := _tax_ladder()
	return float(int(t[0]) + level * int(t[2])) / 10000.0


func tax_level() -> int:
	var t := _tax_ladder()
	return (CostCurves.round_half_up(tax_rate * 10000.0) - int(t[0])) / int(t[2])


## [min_bp, max_bp, step_bp] — doc 03 §8's tax block, in basis points.
func _tax_ladder() -> Array:
	var tax: Dictionary = econ_curves.economy_data().get("tax", {})
	return [CostCurves.round_half_up(float(tax.get("TAX_RATE_MIN", 0.04)) * 10000.0),
			CostCurves.round_half_up(float(tax.get("TAX_RATE_MAX", 0.16)) * 10000.0),
			maxi(1, CostCurves.round_half_up(float(tax.get("TAX_RATE_STEP", 0.01)) * 10000.0))]


## Move the tax rate (doc 03 §2.2). Order of checks:
##
##   1 E_TAX_LEVEL_RANGE  level outside `[0, tax_level_count() - 1]`
##   2 E_TAX_COOLDOWN     inside doc 03 §8's `TAX_RATE_COOLDOWN_HOURS` window
##                        since the last change (payload carries `hours_remaining`)
##
## Setting the level it is already on is a no-op that returns ok with
## `changed = false` and does NOT start a new cooldown. On success the rate
## feeds three places at the next hourly settlement: `tax_policy_factor` scales
## revenue (§2.2), `happiness_tax_delta = −(r − 0.09) × 220` shifts the
## happiness target (§2.2 / doc 09 §2.10.3), and `growth_rate_multiplier =
## 1 − (r − 0.09) × 3.5` slows or speeds attractiveness (doc 09 §2.10.1).
func cmd_set_tax_level(level: int, preview: bool = false) -> Dictionary:
	var count := tax_level_count()
	if level < 0 or level >= count:
		return CommandQueue.fail(&"E_TAX_LEVEL_RANGE", {"blockers": [&"E_TAX_LEVEL_RANGE"],
				"levels": count})
	var rate := tax_rate_for_level(level)
	var hour := clock.sim_time_minutes() / 60
	var cooldown := int((econ_curves.economy_data().get("tax", {}) as Dictionary)
			.get("TAX_RATE_COOLDOWN_HOURS", 0))
	var quote := {"blockers": [], "level": level, "rate": rate, "previous_rate": tax_rate,
			"happiness_delta": economy.happiness_tax_delta(rate),
			"growth_multiplier": economy.growth_rate_multiplier(rate),
			"changed": rate != tax_rate}
	if rate == tax_rate:
		return CommandQueue.ok(quote)
	if not economy.tax_rate_change_allowed(hour, tax_rate_changed_hour):
		quote["blockers"] = [&"E_TAX_COOLDOWN"]
		quote["hours_remaining"] = cooldown - (hour - tax_rate_changed_hour)
		return CommandQueue.fail(&"E_TAX_COOLDOWN", quote)
	if preview:
		return CommandQueue.ok(quote)
	var previous := tax_rate
	tax_rate = rate
	tax_rate_changed_hour = hour
	bus.emit(&"tax_rate_changed", {"level": level, "rate": rate, "previous": previous,
			"hour": hour})
	return CommandQueue.ok(quote)


# -------------------------------------------------- doc 09 §2.5 land purchase

## Doc 03 §2.7's seven-term `LandPriceInputs` bundle for one block.
func land_price_inputs(block_id: String) -> Dictionary:
	var block := world.block(block_id)
	if block == null:
		return {}
	var prestige := 0.0
	var owned_neighbors := 0
	for neighbor in world.neighbors4(block_id):
		var n: LandBlock = neighbor
		if not n.is_owned():
			continue
		owned_neighbors += 1
		var district_id: String = _block_to_district.get(n.id, "")
		var stability := districts.city_stability
		if district_id != "":
			stability = float(districts.district(district_id).get("stability", stability))
		prestige += n.land_value_index(stability)
	if owned_neighbors > 0:
		prestige /= float(owned_neighbors)
	return {
		"d": world.d_from_center(block_id),
		"dev_terrain": String(block.dev_terrain),
		"risk_index": block.env_risk_index(),
		"waterfront_edges": block.waterfront_edges,
		"arterial_connections": block.arterial_connections,
		"prestige": prestige,
		"elevation_norm": float(block.elevation_class) / 4.0,
		"blocks_owned": world.owned_count(),
		"m_land": float(treasury.difficulty().get("M_land", 1.0)),
		"non_adjacent": false,
	}


## Buy a land block (doc 09 §2.5, priced by doc 03 §2.7). Order of checks —
## the first four are `WorldMap.purchase_allowed`'s, unchanged:
##
##   1 E_UNKNOWN_BLOCK  no such block id
##   2 E_ALREADY_OWNED  already yours
##   3 E_CITY_LEVEL     below the block's `min_city_level`
##   4 E_NOT_ADJACENT   no full edge touches owned land (diagonals do not count)
##   5 E_FUNDS          treasury below the quoted price
##
## `auto_develop` (default true) hands the block straight to
## `DevelopmentController`, which is what makes this one verb "the city grows
## outward". Doc 09's own state machine keeps buying and developing separate, so
## a purchase that cannot also afford the SURVEY phase still succeeds: the
## payload reports `development_started = false` with its own reason, and
## `cmd_start_development` picks it up later.
func cmd_buy_block(block_id: String, preview: bool = false,
		auto_develop: bool = true) -> Dictionary:
	var allowed := world.purchase_allowed(block_id, progression.city_level)
	if not bool(allowed["ok"]):
		var failed: Dictionary = (allowed["payload"] as Dictionary).duplicate()
		failed["blockers"] = [allowed["reason_code"]]
		return CommandQueue.fail(allowed["reason_code"], failed)
	var inputs := land_price_inputs(block_id)
	var price := economy.land_price(inputs)
	var block := world.block(block_id)
	var quote := {"blockers": [], "price": price, "block": block_id,
			"development_estimate": economy.development_total_cost(String(block.dev_terrain),
					float(inputs["d"]), block.arterial_connections,
					float(treasury.difficulty().get("M_dev", 1.0)))}
	if treasury.balance < price:
		quote["blockers"] = [&"E_FUNDS"]
		return CommandQueue.fail(&"E_FUNDS", quote)
	if preview:
		return CommandQueue.ok(quote)

	treasury.spend(price, &"land", "land " + block_id)
	block.ownership_state = &"OWNED"
	block.purchase_price = price
	block.purchased_minute = clock.sim_time_minutes()
	world.refresh_purchasable(progression.city_level)
	bus.emit(&"block_purchased", {"block": block_id, "price": price,
			"blocks_owned": world.owned_count()})
	stats_add(&"blocks_bought")
	quote["development_started"] = false
	if auto_develop:
		var started := cmd_start_development(block_id)
		quote["development_started"] = bool(started["ok"])
		if not bool(started["ok"]):
			quote["development_reason"] = started["reason_code"]
	return CommandQueue.ok(quote)


## Start the six-phase pipeline on an owned block (doc 09 §2.3). Order:
##
##   1 E_UNKNOWN_BLOCK / E_NOT_OWNED / E_ALREADY_DEVELOPING  — the controller's
##   2 E_FUNDS  treasury below the SURVEY phase price (doc 03 §2.8)
##
## Each phase is charged as it is submitted, never up front: the controller
## records what it started, this coordinator prices and pays it.
func cmd_start_development(block_id: String, preview: bool = false) -> Dictionary:
	var block := world.block(block_id)
	if block == null:
		return CommandQueue.fail(&"E_UNKNOWN_BLOCK", {"blockers": [&"E_UNKNOWN_BLOCK"]})
	if not block.is_owned():
		return CommandQueue.fail(&"E_NOT_OWNED", {"blockers": [&"E_NOT_OWNED"]})
	if block.development_state != &"UNDEVELOPED":
		return CommandQueue.fail(&"E_ALREADY_DEVELOPING",
				{"blockers": [&"E_ALREADY_DEVELOPING"], "state": String(block.development_state)})
	var first_cost := _development_phase_cost(block_id, 0)
	var quote := {"blockers": [], "phase_cost": first_cost,
			"total_estimate": economy.development_total_cost(String(block.dev_terrain),
					float(world.d_from_center(block_id)), block.arterial_connections,
					float(treasury.difficulty().get("M_dev", 1.0)))}
	if treasury.balance < first_cost:
		quote["blockers"] = [&"E_FUNDS"]
		return CommandQueue.fail(&"E_FUNDS", quote)
	if preview:
		return CommandQueue.ok(quote)
	var started := development.start_development(block_id)
	if not bool(started["ok"]):
		return started
	_charge_development_phases()
	quote["job_id"] = int(started["payload"]["job_id"])
	quote["phase"] = String(started["payload"]["phase"])
	return CommandQueue.ok(quote)


## Doc 03 §2.8 phase 5, `utility_corridor` — "power + water trunk to block edge",
## $9,000 base. The phase price already bought the copper (doc 03 §2.13(b)'s
## no-double-billing rule), so this books no money: it runs the nearest feeder's
## route to the CENTRE of the developed block, which is what makes the block
## tappable by `cmd_place_grid_component` at all. The centre is the right
## terminus rather than the near edge because a land block is 16×16
## (constitution §6) and the tap radius is 8, so a trunk to the centre puts
## every tile of the block — corners included, Chebyshev 8 — in reach of one
## player transformer. Reaching further is `route_feeder`'s job (doc 04 §4).
##
## The new route tiles raise `line_km`, so doc 03's `E_grid` starts billing the
## extension the very next hour: expansion costs upkeep, exactly as §2.4 intends.
func _extend_utility_corridor(block_id: String) -> void:
	var block := world.block(block_id)
	if block == null:
		return
	var centre: Vector2i = block.grid * TileGrid.TILES_PER_BLOCK \
			+ Vector2i(TileGrid.TILES_PER_BLOCK / 2, TileGrid.TILES_PER_BLOCK / 2)
	var tap := grid.nearest_feeder_tap(centre, TileGrid.SIZE)
	if tap.is_empty() or int(tap["distance"]) <= 0:
		return
	var lateral := PowerGrid.lateral_tiles(tap["tap_tile"], centre)
	grid.extend_route(String(tap["feeder"]), lateral)
	bus.emit(&"utility_corridor_extended", {"block": block_id,
			"feeder": String(tap["feeder"]), "tiles": lateral.size(),
			"centre_tile": [centre.x, centre.y]})


## Doc 03 §2.8 phase 6, `final_development` — "block becomes buildable". Doc 09
## §2.2 gates placement on `count_buildable`, so READY has to open the ground.
## Water, blocked and already-occupied tiles keep their own flags; road tiles
## are doc 10's template stamp and are untouched here.
func _open_block_for_building(block_id: String) -> void:
	var block := world.block(block_id)
	if block == null:
		return
	var origin: Vector2i = block.grid * TileGrid.TILES_PER_BLOCK
	for z in range(origin.y, origin.y + TileGrid.TILES_PER_BLOCK):
		for x in range(origin.x, origin.x + TileGrid.TILES_PER_BLOCK):
			if world.grid.has_flag(x, z, TileGrid.FLAG_WATER) \
					or world.grid.has_flag(x, z, TileGrid.FLAG_BLOCKED):
				continue
			world.grid.set_flag(x, z, TileGrid.FLAG_BUILDABLE)


func _development_phase_cost(block_id: String, phase_index: int) -> int:
	var block := world.block(block_id)
	if block == null:
		return 0
	return economy.development_phase_cost(phase_index, String(block.dev_terrain),
			float(world.d_from_center(block_id)), block.arterial_connections,
			float(treasury.difficulty().get("M_dev", 1.0)))


## Pay doc 03 §2.8 for every development phase the controller started since the
## last drain, and give it the MVP crew. Called from the WORK phase and straight
## after a manual start, so a phase is never more than one tick ahead of its
## invoice. Crew binding matches `cmd_place_building`'s: doc 06 owns real crews
## (P1-15); until then every job gets the yard crew so work actually progresses.
func _charge_development_phases() -> void:
	for charge in development.take_phase_charges():
		var block_id := String(charge["block_id"])
		construction.assign_crew(int(charge["job_id"]), "YARD-CREW-1")
		var cost := _development_phase_cost(block_id, int(charge["phase_index"]))
		if cost <= 0:
			continue
		treasury.spend(cost, &"construction", "development %s %s"
				% [block_id, String(charge["phase"])])
		bus.emit(&"development_phase_charged", {"block": block_id,
				"phase": String(charge["phase"]), "cost": cost})


func _avenue_within(origin: Vector2i, radius: int) -> bool:
	for z in range(origin.y - radius, origin.y + radius + 1):
		for x in range(origin.x - radius, origin.x + radius + 1):
			if TileGrid.in_bounds(x, z) \
					and world.grid.road_class_at(x, z) == TileGrid.ROAD_AVENUE:
				return true
	return false


## Ids come off a HIGH-WATER MARK, not "max live + 1": a demolished id must
## never be handed out again. Recycling one would let a `removed_records` row
## and a live `placed_records` row share a sim_id across a save, and the reload
## would erase the live building while replaying the old demolition.
func _next_building_grid_id() -> int:
	var highest := _grid_id_high_water
	for id in buildings:
		highest = maxi(highest, (buildings[id] as Building).id)
	return highest + 1


func stats_add(counter: StringName) -> void:
	stats.add(String(counter))


## Construction stage pulses for the renderer (doc 11 §5): a site under
## build/upgrade walks six visual stages, and the crane/site loop switches on
## each. One event per CHANGE only — a pulse every tick would be 240 events an
## hour per site. Jobs are read in job_id order so the stream is deterministic.
func _emit_construction_stages() -> void:
	var live := {}
	for job in construction.active_jobs():
		var kind := String(job["kind"])
		if kind != "build" and kind != "upgrade":
			continue
		var sim_id := String((job.get("payload", {}) as Dictionary).get("sim_id", ""))
		if sim_id == "":
			continue
		var b: Building = buildings.get(sim_id)
		if b == null:
			continue
		live[sim_id] = true
		# progress() is the exact integer accumulator, so the stage a given
		# work_units count maps to is identical on every machine and after load.
		var stage := clampi(1 + int(6.0 * construction.progress(int(job["job_id"]))), 1, 6)
		if int(_last_construction_stage.get(sim_id, 0)) == stage:
			continue
		_last_construction_stage[sim_id] = stage
		bus.emit(&"building_construction_stage",
				{"building": b.id, "sim_id": sim_id, "stage": stage})
	# Completed (or cancelled) jobs leave no residue: the next job on the same
	# building starts its stage walk from 1 again.
	for sim_id in _sorted(_last_construction_stage):
		if not live.has(sim_id):
			_last_construction_stage.erase(sim_id)


## Route a completed construction job to its building (build, upgrade, repair).
func on_construction_completed(job: Dictionary) -> void:
	var sim_id := String(job.get("payload", {}).get("sim_id", ""))
	var b: Building = buildings.get(sim_id)
	if b == null:
		return
	if job.get("kind", &"") == &"repair":
		# doc 02 §2.12: `repairing → active` at the target the job was quoted at
		# (1.00 preventive, 0.85 post-damage) — never above the current condition.
		var repaired := b.complete_repair(
				float((job["payload"] as Dictionary).get("repair_target", 1.0)))
		if not bool(repaired["ok"]):
			return
		for event in repaired["payload"]["events"]:
			var out_repair: Dictionary = event.duplicate()
			out_repair["sim_id"] = sim_id
			out_repair["condition"] = b.condition
			bus.emit(StringName(String(out_repair["type"])), out_repair)
		return
	var done := b.complete_construction()
	if not bool(done["ok"]):
		return
	b.stats = catalog.stats(String(b.archetype), b.level)
	_block_dark_weights[sim_id] = int(b.stats.get("population", 0)) + int(b.stats.get("jobs", 0))
	for event in done["payload"]["events"]:
		var out: Dictionary = event.duplicate()
		out["sim_id"] = sim_id
		out["level"] = b.level
		bus.emit(StringName(String(out["type"])), out)


## Assemble the §2.2/§2.4 settlement inputs from live sim state (held
## metering constants documented above).
func build_settlement_inputs(ctx: TimeContext, availability: Dictionary) -> Dictionary:
	var building_inputs: Array = []
	var stations: Array = []
	var has_pump := false
	var water_service := water.service_factors()
	for id in _sorted(buildings):
		var b: Building = buildings[id]
		var district_id: String = _block_to_district.get(
				String(_building_records[id].get("block", "")), "")
		var stability := 1.0
		if district_id != "":
			stability = float(districts.district(district_id).get("stability", 1.0))
		building_inputs.append({
			"type": String(b.archetype), "level": b.level,
			"occ": population.occ_of(id) * b.state_occupancy(),
			"power": float(availability.get(id, 1.0)),
			"water": float(water_service.get(id, 1.0)),
			"road": roads.access_quality(b.origin),
			"stability": stability, "condition": b.condition,
		})
		match b.archetype:
			&"police_station", &"fire_station", &"construction_yard":
				stations.append({"type": String(b.archetype), "level": b.level})
			&"water_facility":
				pass  # water_works staffing added once, below (RR-16)
	var pump_ids := water.nodes.keys()
	pump_ids.sort()
	for node_id in pump_ids:
		if (water.nodes[node_id] as WaterNode).variant == &"pump":
			has_pump = true
	if has_pump:
		stations.append({"type": "water_works", "level": 1})
	return {
		"hour": ctx.tick_index / GameClock.TICKS_PER_HOUR,
		"buildings": building_inputs,
		"happiness": happiness.happiness,
		"tax_rate": tax_rate,
		"stations": stations,
		# Doc 06 owns fleet capacity (C-50) but its authored ladders disagree
		# with doc 03's STARTER_VEHICLES on utility/water counts — a billing
		# change that needs a doc-03 ruling before the swap (report §Wave-1).
		"vehicles": STARTER_VEHICLES,
		"grid_inventory": grid.grid_inventory(),
		"delivered_mwh": HELD_DELIVERED_MWH,
		"generation": [{"plant_type": "gas", "mwh": HELD_DELIVERED_MWH, "level": 1}],
		"water": water.inventory(),
		"roads": roads.settlement_inputs(),
		"police_incidents_resolved": HELD_FINE_RATE,
	}


func _district_service_ratio(district_id: String) -> float:
	var served := 0.0
	var total := 0.0
	for id in _sorted(buildings):
		var block := String(_building_records[id].get("block", ""))
		if _block_to_district.get(block, "") != district_id:
			continue
		var demand := float(_last_demands.get(id, 0.0))
		total += demand
		if grid.is_powered(id):
			served += demand
	return served / total if total > 0.0 else 1.0


func _rollup_district_population() -> void:
	var district_pop := {}
	var district_jobs := {}
	for id in _sorted(buildings):
		var b: Building = buildings[id]
		var block := String(_building_records[id].get("block", ""))
		var district_id: String = _block_to_district.get(block, "")
		if district_id == "":
			continue
		district_pop[district_id] = float(district_pop.get(district_id, 0.0)) \
				+ float(int(b.stats.get("population", 0))) * population.occ_of(id)
		district_jobs[district_id] = int(district_jobs.get(district_id, 0)) + int(b.stats.get("jobs", 0))
	for district_id in districts.district_ids_sorted():
		districts.set_population_jobs(district_id,
				roundi(float(district_pop.get(district_id, 0.0))),
				int(district_jobs.get(district_id, 0)))


func _register_systems() -> void:
	scheduler.register(TimerPhaseSystem.new(self))
	scheduler.register(WeatherPhaseSystem.new(self))
	scheduler.register(PowerPhaseSystem.new(self))
	scheduler.register(WaterPhaseSystem.new(self))
	scheduler.register(WaterHourlySystem.new(self))
	scheduler.register(WorkPhaseSystem.new(self))
	scheduler.register(IncidentPhaseSystem.new(self))
	scheduler.register(DistrictPhaseSystem.new(self))
	scheduler.register(HourlyPhaseSystem.new(self))
	scheduler.register(DirectorPhaseSystem.new(self))
	scheduler.register(WeatherReportPhaseSystem.new(self))
	scheduler.register(ReportPhaseSystem.new(self))


func compose_water_demands() -> Dictionary:
	var out: Dictionary = {}
	for id in _sorted(buildings):
		var b: Building = buildings[id]
		out[id] = float(b.stats.get("water_demand", 0.0)) * b.water_demand_mult()
	return out


# ------------------------------------------------------------ phase adapters

class TimerPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"timers"
	func phase() -> int: return Phase.TIMERS
	func cadence() -> int: return Cadence.EVERY_TICK
	func advance_fine(ctx: TimeContext) -> void:
		sim.events.process_due(sim.timers.collect_due(ctx.tick_index))
	func advance_coarse(ctx: TimeContext) -> void:
		sim.events.process_due(sim.timers.collect_due(ctx.tick_index + GameClock.TICKS_PER_HOUR - 1))


class PowerPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"power"
	func phase() -> int: return Phase.POWER
	func cadence() -> int: return Cadence.EVERY_TICK
	func advance_fine(ctx: TimeContext) -> void:
		var demands := sim.compose_demands(ctx)
		sim._last_demands = demands
		sim.grid.tick(ctx.dt_game_seconds, demands, sim.distributed_sinks(ctx),
				sim.weather.env_for_grid(), sim.rng)
	func advance_coarse(ctx: TimeContext) -> void:
		# Doc 04 §2.12: coarse hour in one step when nothing was overloaded.
		advance_fine(ctx)


class WorkPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"work"
	func phase() -> int: return Phase.WORK
	func cadence() -> int: return Cadence.EVERY_TICK
	func advance_fine(ctx: TimeContext) -> void:
		sim.work.advance(ctx)
		var completed := sim.construction.advance(ctx)
		# Stage pulses read the queue AFTER this tick's work landed and AFTER
		# finished jobs left it, so a completing site never pulses again — its
		# building_completed event is what takes the scaffolding down.
		sim._emit_construction_stages()
		for job in completed:
			if (job.get("payload", {}) as Dictionary).has("roads_kind"):
				sim.roads.on_job_completed(int(job["job_id"]))
			elif not sim.development.on_job_completed(job):
				sim.on_construction_completed(job)
		# A finished phase auto-submits the next one; doc 03 §2.8 bills it here,
		# in the same tick, so the ledger never runs a phase behind the site.
		sim._charge_development_phases()
	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)


class WeatherPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"weather"
	func phase() -> int: return Phase.WEATHER
	func cadence() -> int: return Cadence.EVERY_TICK
	func advance_fine(ctx: TimeContext) -> void:
		sim.weather.tick(ctx)
		sim._route_lightning(ctx)
	func advance_coarse(ctx: TimeContext) -> void:
		sim.weather.advance_coarse(ctx)
		sim._route_lightning(ctx)


class WaterPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"water"
	func phase() -> int: return Phase.WATER
	func cadence() -> int: return Cadence.EVERY_TICK
	func advance_fine(ctx: TimeContext) -> void:
		sim.water.set_demands(sim.compose_water_demands())
		sim.water.advance(float(ctx.dt_game_seconds) / 3600.0, ctx.channels)
	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)


class WaterHourlySystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"water_hourly"
	func phase() -> int: return Phase.WATER          # sorts AFTER &"water"
	func cadence() -> int: return Cadence.EVERY_HOUR
	func advance_fine(_ctx: TimeContext) -> void:
		sim.water.hourly_step(sim.rng, {
			"weather_kind": sim.weather.get_state().to_lower(),
			"air_temp_c": sim.weather.get_ambient_temp_c(),
		})
	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)


class IncidentPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"incidents"
	func phase() -> int: return Phase.INCIDENTS
	func cadence() -> int: return Cadence.EVERY_MINUTE
	func advance_fine(ctx: TimeContext) -> void: _run(ctx, period_ticks())
	func advance_coarse(ctx: TimeContext) -> void: _run(ctx, GameClock.TICKS_PER_HOUR)
	func _run(ctx: TimeContext, step_ticks: int) -> void:
		# The only path by which doc 06 learns it is offline (doc 08 rule 4).
		sim.incident_world.offline = ctx.is_catchup
		# Absolute game-hours off an exact integer tick, never an accumulated
		# delta: this is what makes the fine and coarse paths land together.
		sim.incidents.advance_to(float(ctx.tick_index + step_ticks)
				/ float(GameClock.TICKS_PER_HOUR))


class DirectorPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"director"
	func phase() -> int: return Phase.DIRECTOR
	func cadence() -> int: return Cadence.EVERY_HOUR
	func advance_fine(ctx: TimeContext) -> void:
		sim.director.tick_hour(sim.build_director_inputs(), ctx)
	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)


class WeatherReportPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"weather_report"
	func phase() -> int: return Phase.REPORT
	func cadence() -> int: return Cadence.EVERY_TICK
	func advance_fine(_ctx: TimeContext) -> void:
		for event in sim.weather.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in sim.director.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in sim.director.storm.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)


class DistrictPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"districts"
	func phase() -> int: return Phase.DISTRICTS
	func cadence() -> int: return Cadence.EVERY_MINUTE
	func advance_fine(_ctx: TimeContext) -> void:
		for district_id in sim.districts.district_ids_sorted():
			sim.districts.update_power_reliability(district_id,
					sim._district_service_ratio(district_id), 1.0 / 60.0)
			sim.districts.recompute_fast(district_id)
	func advance_coarse(_ctx: TimeContext) -> void:
		for district_id in sim.districts.district_ids_sorted():
			sim.districts.update_power_reliability(district_id,
					sim._district_service_ratio(district_id), 1.0)
			sim.districts.recompute_fast(district_id)


class HourlyPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"hourly"
	func phase() -> int: return Phase.ECONOMY
	func cadence() -> int: return Cadence.EVERY_HOUR
	func advance_fine(ctx: TimeContext) -> void:
		# P14 order: availability finalized → districts settle → economy bills
		# the completed hour → population/happiness relax (P15 material).
		var availability := sim.grid.settle_hour()
		sim.districts.recompute_slow(1.0)
		var settled := sim.economy.settle_hour(sim.build_settlement_inputs(ctx, availability))
		sim._last_expense_hour = float(
				(settled.get("expenses", {}) as Dictionary).get("total", sim._last_expense_hour))
		# doc 03 §2.2: the tax rate is not only a revenue scalar — it slows
		# growth and shifts the happiness target, which is the whole reason the
		# knob is interesting. Both terms are exactly 0 / 1.0 at TAX_RATE_BASE.
		var result := sim.population.advance(sim._population_inputs(), 1.0,
				sim.districts.city_stability,
				sim.economy.growth_rate_multiplier(sim.tax_rate))
		sim._rollup_district_population()
		sim.happiness.advance(1.0, sim.districts.city_stability, 1.0,
				sim.population.employment_balance(), 1.0,
				sim.economy.happiness_tax_delta(sim.tax_rate))
		for event in sim.progression.update(int(result["city_population"])):
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in sim.economy.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)


class ReportPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"report"
	func phase() -> int: return Phase.REPORT
	func cadence() -> int: return Cadence.EVERY_TICK
	func advance_fine(_ctx: TimeContext) -> void:
		for event in sim.grid.drain_events():
			# Doc 04 fails the component; doc 06 files the repair.
			sim.incidents.on_power_event(event)
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in sim.incidents.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in sim.water.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in sim.development.drain_events():
			# The two phase effects that reach outside the land block itself —
			# the utility trunk and the buildable ground — are the coordinator's,
			# because DevelopmentController may not import the grid or the map's
			# tile flags (doc 09 §2.3 keeps the pipeline world-effect-only).
			match String(event["type"]):
				"development_phase_completed":
					if String(event.get("phase", "")) == "UTILITY_CORRIDOR":
						sim._extend_utility_corridor(String(event["block"]))
				"block_ready":
					sim._open_block_for_building(String(event["block"]))
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in sim.events.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
		# Block-dark transitions (report 98 C-38): the renderer's blackout /
		# relight ceremony is driven by these, never by direct calls.
		var fractions := sim.grid.block_dark_fractions(sim._block_dark_weights)
		for block_id in fractions:
			var dark: bool = fractions[block_id]["dark"]
			if bool(sim._prev_block_dark.get(block_id, false)) != dark:
				sim._prev_block_dark[block_id] = dark
				sim.bus.emit(&"BlockDarkChanged", {
					"block_id": block_id, "block_dark": dark,
					"dark_fraction": fractions[block_id]["fraction"],
					"powered_fraction": 0.0 if dark else 1.0,
				})
	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)


static func _sorted(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys

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
## A water_facility building draws the SUM of its hosted variant nodes —
## replaced by data/water.json when the water system lands.
const WATER_VARIANT_KW_L1 := {
	"source": 32.0, "treatment": 40.0, "pump": 60.0, "tank": 5.0, "booster": 12.0,
}
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

## Held metering pair + starter roster (doc 03 §9 item 6b): constants until
## doc 04 meters delivered energy and doc 06 owns the live fleet.
const HELD_DELIVERED_MWH := 1.5
const HELD_WATER := {"m3_treated": 5.56, "main_km": 1.512, "main_condition": 1.0,
		"pump_capacity_m3h": 40.0, "delivered_m3": 5.56}
const HELD_FINE_RATE := 3.0 / 350.0
const STARTER_VEHICLES := [
	{"type": "patrol_car", "km_this_hour": 1.0},
	{"type": "patrol_car", "km_this_hour": 1.0},
	{"type": "fire_engine", "km_this_hour": 1.5 / 1.9},
	{"type": "utility_service_truck", "km_this_hour": 1.0},
	{"type": "water_repair_truck", "km_this_hour": 1.0},
	{"type": "construction_crew", "km_this_hour": 1.0},
]

var buildings: Dictionary = {}  # building id string -> Building
var _building_records: Dictionary = {}  # id -> starter record (block, tags…)
var _block_to_district: Dictionary = {}
var _last_demands: Dictionary = {}
var _water_kw_by_building: Dictionary = {}  # water_facility id -> Σ hosted variant kW
var _block_dark_weights: Dictionary = {}  # building id -> pop+jobs weight
var _prev_block_dark: Dictionary = {}  # block id -> bool
var boot_errors: PackedStringArray = []


static func boot_from_files(seed_value: int = 1337) -> CitySim:
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json("res://data/starter_city.json"),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"))
	return sim


func boot(seed_value: int, time_data: Dictionary, starter_data: Dictionary,
		buildings_data: Dictionary, rules_data: Dictionary) -> bool:
	boot_errors.clear()
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
	_boot_buildings()
	_boot_power()
	_boot_districts()
	_register_systems()
	return boot_errors.is_empty()


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
	for node in loader.water.get("nodes", []):
		var host := String(node.get("building", ""))
		var variant := String(node.get("variant", ""))
		if host != "" and WATER_VARIANT_KW_L1.has(variant):
			_water_kw_by_building[host] = float(_water_kw_by_building.get(host, 0.0)) \
					+ float(WATER_VARIANT_KW_L1[variant])


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
			return "~f~%016x" % bytes.decode_u64(0)
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
				var bytes := PackedByteArray()
				bytes.resize(8)
				bytes.encode_u64(0, ("0x" + (value as String).substr(3)).hex_to_int())
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
	}


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
	for record in body.get("placed_records", []):
		var sim_id := String(record["id"])
		var footprint := Vector2i(int(record["footprint"][0]), int(record["footprint"][1]))
		var origin := Vector2i(int(record["origin"][0]), int(record["origin"][1]))
		_building_records[sim_id] = {"id": sim_id, "grid_id": int(record["grid_id"]),
				"type": String(record["type"]), "block": String(record["block"]),
				"footprint": footprint, "origin_global": origin}
		world.grid.stamp_building(int(record["grid_id"]), origin, footprint)
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
			{"sim_id": sim_id})
	# MVP crew binding: doc 06 owns real crews (P1-15); until then every job
	# gets the yard crew so construction progresses.
	construction.assign_crew(job_id, "YARD-CREW-1")
	b.start_construction()
	grid.attach_building(sim_id, origin, &"STANDARD", block.id)
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
	# E_WATER_HEADROOM / coverage checks join when docs 05 / 02-coverage land.
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
			{"sim_id": sim_id})
	construction.assign_crew(job_id, "YARD-CREW-1")
	bus.emit(&"upgrade_started_sim", {"sim_id": sim_id, "to_level": next_level, "cost": cost})
	return CommandQueue.ok({"job_id": job_id, "cost": cost, "to_level": next_level})


func _avenue_within(origin: Vector2i, radius: int) -> bool:
	for z in range(origin.y - radius, origin.y + radius + 1):
		for x in range(origin.x - radius, origin.x + radius + 1):
			if TileGrid.in_bounds(x, z) \
					and world.grid.road_class_at(x, z) == TileGrid.ROAD_AVENUE:
				return true
	return false


func _next_building_grid_id() -> int:
	var highest := 0
	for id in buildings:
		highest = maxi(highest, (buildings[id] as Building).id)
	return highest + 1


func stats_add(counter: StringName) -> void:
	stats.add(String(counter))


## Route a completed construction job to its building (build or upgrade).
func on_construction_completed(job: Dictionary) -> void:
	var sim_id := String(job.get("payload", {}).get("sim_id", ""))
	var b: Building = buildings.get(sim_id)
	if b == null:
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
			"water": 1.0, "road": 1.0,  # stubs until docs 05/10 land
			"stability": stability, "condition": b.condition,
		})
		match b.archetype:
			&"police_station", &"fire_station", &"construction_yard":
				stations.append({"type": String(b.archetype), "level": b.level})
			&"water_facility":
				pass  # water_works staffing added once, below (RR-16)
	for node in loader.water.get("nodes", []):
		if String(node.get("variant", "")) == "pump":
			has_pump = true
	if has_pump:
		stations.append({"type": "water_works", "level": 1})
	return {
		"hour": ctx.tick_index / GameClock.TICKS_PER_HOUR,
		"buildings": building_inputs,
		"happiness": happiness.happiness,
		"tax_rate": 0.09,
		"stations": stations,
		"vehicles": STARTER_VEHICLES,
		"grid_inventory": grid.grid_inventory(),
		"delivered_mwh": HELD_DELIVERED_MWH,
		"generation": [{"plant_type": "gas", "mwh": HELD_DELIVERED_MWH, "level": 1}],
		"water": HELD_WATER,
		"roads": {"tiles": {"AVENUE": 540, "STREET": 243}, "c_day": 0.35, "wx_wear_day": 0.0},
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
	scheduler.register(PowerPhaseSystem.new(self))
	scheduler.register(WorkPhaseSystem.new(self))
	scheduler.register(DistrictPhaseSystem.new(self))
	scheduler.register(HourlyPhaseSystem.new(self))
	scheduler.register(ReportPhaseSystem.new(self))


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
				{"t_ambient_c": 22.0, "heat_wave": false}, sim.rng)
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
		for job in sim.construction.advance(ctx):
			if not sim.development.on_job_completed(job):
				sim.on_construction_completed(job)
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
		sim.economy.settle_hour(sim.build_settlement_inputs(ctx, availability))
		var result := sim.population.advance(sim._population_inputs(), 1.0,
				sim.districts.city_stability)
		sim._rollup_district_population()
		sim.happiness.advance(1.0, sim.districts.city_stability, 1.0,
				sim.population.employment_balance(), 1.0, 0.0)
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
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in sim.development.drain_events():
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

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
## Doc 09 §2.14's teaching curriculum. Subscribes to `bus` rather than scanning,
## and earns city levels through `progression.grant_level` — see `GoalSystem`.
var goals: GoalSystem
var stats: StatsRecorder
var grid: PowerGrid
var catalog: BuildingCatalog
var construction: ConstructionQueue
var development: DevelopmentController
var econ_curves: CostCurves
## Doc 03 §2.9's one difficulty file, resolved at boot and pinned for the life of
## the city (doc 93 §K1). Every difficulty scalar in the project is read through
## it; nothing else opens `data/difficulty.json`.
var difficulty: Difficulty
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
## Doc 06 §2.16's opportunity layer — the play-NOW street events the player taps
## for money. A FINE-PATH system: it spawns nothing offline and draws nothing on
## the coarse step, which is doc 08 §2.3 rule 9 made structural. See
## `_boot_street` and `cmd_collect_opportunity`.
var street: OpportunitySystem

## The last held metering constant (doc 03 §9 item 6b): a constant until doc 04
## meters delivered energy. (HELD_WATER retired — doc 05's live inventory()
## feeds the settlement now; STARTER_VEHICLES retired — doc 06's live roster
## does, per the fleet-billing ruling on doc 92 F-3; **HELD_FINE_RATE retired —
## report 98 RR-78**: it metered a `fines` line that was doc 06's `reward_base`
## under a second name, so it printed a flat $3.00/gh on every preset at every
## horizon while the real money went straight to the treasury unnamed. Doc 93
## §N1 point 4's re-open condition — *"when doc 06 publishes real resolutions"* —
## is met, and the live `city_services` line replaces the pair.)
const HELD_DELIVERED_MWH := 1.5

## Station shells whose roster doc 06 houses (doc 06 §2.11 / C-50). A completed
## build or upgrade of one of these re-runs that station's housing, which is what
## makes `fire_station` response capacity instead of an upkeep line (doc 92 F-3).
const FLEET_STATION_ARCHETYPES: Array[StringName] = [
	&"police_station", &"fire_station", &"construction_yard",
	&"water_facility", &"power_facility", &"substation",
]

## The doc 03 §2.10 recovery-ladder events the coordinator republishes on the
## shared bus. `treasury_credited` stays private (it fires on every incident
## reward), and `economy_hour_settled` is EconomySystem's to publish — the
## treasury's copy of it would shadow the settlement snapshot the UI reads.
const TREASURY_BUS_EVENTS: Array[StringName] = [
	&"austerity_entered", &"austerity_exited", &"credit_line_engaged",
	&"credit_limit_reached", &"deferred_liability_accrued",
	&"deferred_liability_cleared", &"relief_grant_awarded",
]

## data/grid_components.json — doc 04 §2.1's placement rules for player-placed
## grid components (no prices, no capacities; see the file's own meta notes).
var grid_rules: Dictionary = {}
## doc 03 §2.2's tax rate r. `cmd_set_tax_level` is the only writer; the hour it
## last moved gates the §8 `TAX_RATE_COOLDOWN_HOURS` re-adjustment window.
var tax_rate: float = 0.09
var tax_rate_changed_hour: int = -1

var buildings: Dictionary = {}  # building id string -> Building
## The ascending building-id order EVERY roster walk iterates in, cached.
##
## Ascending id order is load-bearing — most of these walks are float sums, and
## summing the same values in a different order is not guaranteed to be the same
## number — but re-deriving it is `keys() + sort()` over the whole roster, and at
## 1,500 buildings the districts phase alone paid for twelve of them per step.
## Purely DERIVED: never captured, never restored, rebuilt on demand, and
## invalidated by the four places the roster can change (`_invalidate_roster`).
## Callers iterate it read-only; nothing here hands out a mutable roster.
var _roster_ids: Array = []
var _roster_dirty: bool = true
## Bumped by `_invalidate_roster()`. Sibling systems that keep a per-building
## derived table (doc 06's fire-candidate rows) key it on this rather than
## rebuilding per sub-step. Derived: never captured, never restored.
var roster_revision: int = 0
## Derived, revision-keyed building id -> district id (see `district_of_building`).
var _district_of_building: Dictionary = {}
var _district_of_building_key := Vector2i(-1, -1)
## The revision pair `districts._profile_weights` was last rebuilt for — same
## key, same reason, see `_district_profile_weights`.
var _district_profile_key := Vector2i(-1, -1)
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
var _director_links: Dictionary = {}           # incident id -> director event_uid
## The last settled hour, verbatim (doc 12's budget breakdown reads it).
## Derived: not captured, refilled on the first settled hour after a load.
var last_settlement: Dictionary = {}
var _strike_roster: Array = []
var _strike_roster_min: int = -1
var boot_errors: PackedStringArray = []


static func boot_from_files(seed_value: int = 1337,
		difficulty_preset: String = Difficulty.DEFAULT_PRESET) -> CitySim:
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json("res://data/starter_city.json"),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"),
			difficulty_preset)
	return sim


func boot(seed_value: int, time_data: Dictionary, starter_data: Dictionary,
		buildings_data: Dictionary, rules_data: Dictionary,
		grid_rules_data: Dictionary = {},
		difficulty_preset: String = Difficulty.DEFAULT_PRESET) -> bool:
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
	goals = GoalSystem.new()
	# Doc 09 §2.14's one subscription. Installed here rather than in a phase
	# system because a player command lands BETWEEN ticks — `cmd_place_building`
	# emits `building_placed_sim` from the command thread of control, and a
	# counter that only looked at events during a tick would miss the tap that
	# caused it until the next one.
	bus.observer = goals.observe
	stats = StatsRecorder.new()
	econ_curves = CostCurves.new(
			StarterCityLoader.read_json("res://data/building_economy.json"),
			StarterCityLoader.read_json("res://data/economy.json"))
	if not econ_curves.errors.is_empty():
		boot_errors.append_array(econ_curves.errors)
	# Doc 03 §2.9: the preset resolves BEFORE the treasury, because the founding
	# balance is one of its twelve knobs. A bad file is a boot error and not a
	# fallback — a city that quietly played `standard` because a row was missing
	# is the defect A91-D-19 named.
	difficulty = Difficulty.load_from_file()
	if not difficulty.is_valid():
		boot_errors.append_array(difficulty.errors)
	if not difficulty.select(difficulty_preset):
		boot_errors.append("unknown difficulty preset " + difficulty_preset)
	treasury = Treasury.new(econ_curves.economy_data(), difficulty.row("economic"))
	economy = EconomySystem.new(econ_curves, treasury)
	tax_rate = float((econ_curves.economy_data().get("tax", {}) as Dictionary)
			.get("TAX_RATE_BASE", 0.09))
	tax_rate_changed_hour = -1
	_boot_buildings()
	_boot_power()
	_boot_water()
	_boot_districts()
	# ROADS BEFORE INCIDENTS (Wave 8). Doc 06 §2.10 makes doc 10 authoritative
	# for every dispatch ETA, so `_boot_incidents` has to be able to hand the
	# incident system a road router — which means the router must already exist.
	# The dependency is one-way: `_boot_roads` reads the grid, the districts, the
	# building roster and the cost curves, and nothing at all from incidents, so
	# the swap costs nothing. RNG is unperturbed by the reorder because the two
	# subsystems draw from DIFFERENT named streams (`traffic` and `incidents`,
	# constitution §5) and neither draws during boot.
	_boot_roads()
	_boot_incidents()
	# STREET AFTER INCIDENTS. Doc 06 §2.16's spawner reads `coverage_police`
	# through `CityIncidentWorld`, so the world has to exist first. It draws
	# nothing at boot, so the reorder costs no stream position.
	_boot_street()
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
	_refresh_water_kw()


## Doc 05 owns the per-variant kW at every level, so the site loads doc 02
## meters come from the LIVE nodes, not a boot-time L1 table. Rebuilt whenever
## the node roster changes — at boot, after a load, and after every placement or
## upgrade — because a player-placed pump's draw exists nowhere else.
## (Sorted iteration — float addition order is persisted state.)
func _refresh_water_kw() -> void:
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
	# ---------------------------------------------------------------------
	# **THE LINE WAVE 8 HELD, AND WHAT WAS ACTUALLY WRONG WITH IT** (report 98
	# RR-22 → RR-26/RR-27, Wave 9, 2026-08-20).
	#
	# Doc 06 §2.10 makes doc 10 authoritative for every dispatch ETA. Wave 8
	# finished the seam and then took the argument back out, because on doc 92's
	# `greedy_growth` agent at seed 4242 the 21-game-day run went from ~10 s with
	# 0–4 open incidents to over twenty minutes with the open roster still
	# climbing on game-day 18.
	#
	# **A four-arm ablation found the actual cause, and it was a defect right
	# here at the seam.** `RoadTravelTimeProvider` ignored the `RouteProfile`
	# doc 06 hands it and priced every trip on one fixed `emergency(32.0)` — no
	# per-type speed and no siren multiplier. Doc 06 §2.11 gives a responding
	# patrol car 32 × 1.25 = 40 m/gm; the seam quoted 32, i.e. 20 % slow, and
	# police answer `crime` and `traffic_accident`, which are most of the ambient
	# load. That alone pushed `eta + penalties` past `MAX_ACCEPTABLE_COST` for a
	# whole channel on a degrading network. Honouring the profile takes the same
	# run to 11.2 s with nothing else changed; report 98 RR-26 carries the arms.
	#
	# The two rulings Wave 8 asked for shipped anyway, because they close a real
	# gap and because a terminal rule a played city never reaches is exactly what
	# a terminal rule should be:
	#
	#   * **RR-26** — §2.10's terminal rule. ONE GAME-DAY with nothing
	#     committed ends an incident as ABANDONED, which bounds the open roster
	#     at the arrival rate times a game-day instead of at infinity. Three rows
	#     of `data/incidents.json` author no ending at all, so before this the
	#     bound really was infinity; the rule fires zero times across doc 92's
	#     18-run matrix. `max_acceptable_cost_min` is re-fitted 90 → 115 against
	#     the street-true ETA distribution doc 06 §1.1 publishes.
	#   * **RR-27** — doc 10's hierarchical routing was built, measured and NOT
	#     shipped: with §2.14's rank-then-quote the seam call measures 0.709 ms
	#     on the benchmark city, and a landmark overlay made it 9 % slower.
	#
	# `_boot_roads()` runs ahead of this function so the router exists when the
	# incident system is built; `tests/test_incidents_routes.gd` pins that this
	# is the ROUTER and fails loudly if anything ever puts the stand-in back.
	incidents = IncidentSystem.new(incident_catalog, incident_world, rng,
			roads.travel_time_provider())
	incidents.founding_offset_h = float(GameClock.FOUNDING_OFFSET_MINUTES) / 60.0
	incidents.fleet.populate_from_stations(incident_world.station_rows())


## Doc 06 §2.16's opportunity layer. Four seams, and every one of them is a
## Callable rather than a back-reference: `OpportunitySystem` needs a coverage
## scalar, a residential-frontage set, a revision to memo on and a city level,
## and none of those is a reason for `sim/street/` to know what a `CitySim` is.
##
## `eval_period_h` comes from the phase adapter's OWN cadence and is not
## authored anywhere — see `StreetPhaseSystem`. `data/street.json` expresses the
## rate as a mean interval in game-hours, and a hand-written period that drifted
## from the cadence would silently re-rate the whole layer.
##
## **The fifth seam is not a Callable and is not a view of the city**: since
## RR-85 every bounty the layer pays is priced out of `data/economy.json`, so
## `econ_curves` is handed over whole. It is bound AFTER `configure()` has parsed
## the kind roster, because the check it performs is *"every kind this city can
## spawn has a price"* — see `OpportunitySystem.bind_payouts`.
func _boot_street() -> void:
	street = OpportunitySystem.new(
			StarterCityLoader.read_json("res://data/street.json"))
	street.bind_payouts(econ_curves)
	if not street.errors.is_empty():
		boot_errors.append_array(street.errors)
	street.bind_stream(rng)
	street.grid = world.grid
	street.graph = roads.graph
	street.eval_period_h = float(SimSystem.CADENCE_PERIOD_TICKS[
			SimSystem.Cadence.EVERY_MINUTE]) / float(GameClock.TICKS_PER_HOUR)
	street.coverage_police = func(tile: Vector2i) -> float:
		return incident_world.coverage_police(tile)
	street.residential_ids = _residential_grid_ids
	street.roster_revision = func() -> int: return roster_revision
	street.city_level = func() -> int: return progression.city_level


## Grid building id -> true, for every RESIDENTIAL building in the roster. Doc
## 06 §2.16's loose animal is weighted toward frontage, and frontage is a
## question about the tile ACROSS the kerb — which the tile grid answers with a
## grid id and nothing else, so the categories have to be resolved here.
##
## Asked once per candidate-index rebuild (`graph_version` or `roster_revision`
## moved), never per spawn. The archetype → category lookup is memoised inside
## the walk for the same reason `_population_inputs` memoises it: a handful of
## archetypes against 1,500 buildings.
func _residential_grid_ids() -> Dictionary:
	var out: Dictionary = {}
	var category_by_archetype: Dictionary = {}
	for id in roster_ids():
		var b: Building = buildings[id]
		var found: Variant = category_by_archetype.get(b.archetype)
		if found == null:
			found = catalog.category(String(b.archetype))
			category_by_archetype[b.archetype] = found
		if String(found) == "residential":
			out[b.id] = true
	return out


func _boot_roads() -> void:
	var tun := RoadTunables.from_file("res://data/roads.json")
	if not tun.is_valid():
		boot_errors.append_array(tun.errors)
	roads = RoadNetwork.new(world.grid, tun, rng)
	# **Every sibling is injected BEFORE `bootstrap()`, and that ordering is now
	# load-bearing.** `bootstrap()` rebuilds the graph, stamps every edge's state
	# and takes a cold congestion pass at hour 12; with the assignments on the
	# lines AFTER it, `_assign_districts()` saw an invalid `Callable` and wrote no
	# `district_id` at all — which report 98 RR-61 filed as inert *"only because
	# `profile_weights_of` is injected by nothing"*. This wave injects it, so the
	# inertness is gone and the ordering is the fix. `district_of_tile` keeps its
	# re-stamping setter as the belt to this braces.
	#
	# The one sibling that is NOT live at this point is doc 07's: `_boot_roads`
	# runs before `_boot_weather` so `_boot_incidents` can be handed a router, so
	# `_road_weather_state` answers `clear` for the length of this function and
	# tick 0's `step()` is the first call that sees the real sky.
	roads.power_is_tile_powered = _is_tile_powered      # doc 04 (G-6)
	roads.district_of_tile = _district_of_tile          # doc 09
	roads.profile_weights_of = _district_profile_weights  # doc 09 (§5.1)
	roads.weather_state_of = _road_weather_state          # doc 07 (§5.1)
	roads.land_is_buildable = func(t: Vector2i) -> bool:
		var b := world.block_of_tile(t.x, t.y)
		return b != null and b.is_ready()
	# **The auto-repair quote is priced at the city's own `M_repair`** (doc 10
	# §9.4 item 12, doc 92 §34's top open number, ruled 2026-08-21 as RR-87).
	#
	# `RoadNetwork.auto_repair_daily_cap` is doc 10 §2.12's *player budget
	# setting* — dollars the city may commit to road repair in a game-day — and
	# the quote's only job is deciding how many contiguous runs fit inside it.
	# Quoting at nominal made the cap mean a different number of repairs on every
	# difficulty preset: a `crisis` city (`M_repair` 1.60) admitted 1.60× more
	# tile-fractions than repairing them actually costs and a `casual` one
	# (0.70×) admitted fewer, so the settings row said "$25,000/day" and bought
	# whatever the preset felt like. C-16's multiplier is part of the price, and
	# a budget compared against a price that is not the price is not a budget.
	#
	# **Hash-neutral on `standard`**, where `M_repair` is exactly 1.00 — the
	# multiplication is the identity and every determinism baseline is
	# bit-identical across this change. It is the non-default presets that move,
	# which is the whole point of fixing it. `cmd_repair_building` has always
	# passed the multiplier (see §2.6 below); this is the same seam on doc 10's
	# side, and doc 03 §2.4's `E_roads_repair` accrual already carried it.
	roads.repair_quote = func(road_class: String, damage_fraction: float) -> int:
		return econ_curves.repair_cost_road(road_class, damage_fraction,
				float(treasury.difficulty().get("M_repair", 1.0)))
	roads.submit_job = func(kind: StringName, target: String, crew_hours: float,
			crew: StringName, payload: Dictionary) -> int:
		var job_id := construction.submit(kind, target, crew_hours, crew, payload)
		construction.assign_crew(job_id, "YARD-CREW-1")   # MVP binding, as buildings do
		return job_id
	roads.bootstrap()
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
	incident_sink = DirectorIncidentSink.new(self)
	director.attach(weather, incident_sink, modifiers)
	# Doc 03 §2.9 rule 2 / C-17: the Director stores no difficulty knob. This is
	# the one write path for its `pressure` row, and it runs on every boot, so
	# `DirectorTables` no longer needs the read-only mirror it used to carry.
	_push_difficulty_to_systems()
	weather.bootstrap(_boot_context())


## Pushes the live preset into the three systems that hold difficulty-scaled
## state. `Difficulty` is the authority; these are its readers, and they get the
## row rather than the file.
##
## `EconomySystem` is absent on purpose: it reads `Treasury.difficulty()` every
## settlement, so setting the treasury's row IS setting the economy's. So is the
## incident world — `CityIncidentWorld` asks `sim.difficulty` directly.
func _push_difficulty_to_systems() -> void:
	if director == null:
		return
	director.set_difficulty(difficulty.preset)
	director.set_pressure_knobs(difficulty.row("pressure"))


## Doc 03 §2.9's founding moment, and the ONLY way a preset is chosen (doc 93
## §K1 — difficulty is not changeable mid-city, so there is no `cmd_set_difficulty`
## and never will be).
##
## The shell founds a city by *keeping the sim it booted with*: `game/main.gd`
## holds a paused starter city behind the title door and hands it to the player
## when NEW CITY says so. So the preset cannot be a boot argument on that path —
## it arrives after the boot and before the first tick, and this is the window it
## is honoured in. Outside that window it refuses: `tick_index != 0` is a city
## that has already been played, and re-pricing one mid-life is exactly what the
## ruling forbids.
##
## Booting on a preset and founding on it are the same city, bit for bit
## (`tests/test_difficulty.gd`), because nothing between the two draws RNG.
func found_with_difficulty(preset_name: String) -> bool:
	if clock.tick_index != 0:
		return false
	if not Difficulty.is_preset(preset_name) or not difficulty.select(preset_name):
		return false
	treasury.apply_difficulty(difficulty.row("economic"), true)
	_push_difficulty_to_systems()
	return true


## The city's preset, for the settings sheet's read-only row and for a save
## header. Never a setter — see `found_with_difficulty`.
func difficulty_preset() -> String:
	return difficulty.preset if difficulty != null else Difficulty.DEFAULT_PRESET


func _boot_context() -> TimeContext:
	var ctx := TimeContext.new()
	ctx.tick_index = clock.tick_index
	ctx.minute_of_day = clock.minute_of_day()
	ctx.day_index = clock.day_index()
	ctx.season_index = clock.season_index()
	return ctx


func _refresh_road_density() -> void:
	var sources: Array = []
	for id in roster_ids():
		var b: Building = buildings[id]
		sources.append({"tile": b.origin,
				"pj": float(int(b.stats.get("population", 0)) + int(b.stats.get("jobs", 0)))})
	roads.set_density_sources(sources)


## Doc 04 publishes power state only; doc 10 turns it into delay + congestion
## (G-6). Implemented here because CitySim owns the cross-doc seams.
func _is_tile_powered(tile: Vector2i) -> bool:
	var cached: Variant = _transformer_cover.get(tile)
	if cached == null:
		if _transformer_cover_warm:
			# Warm ⇒ every covered tile is already in the memo, so a miss IS the
			# uncovered answer. No scan, no insert, no unbounded growth from the
			# tiles doc 10 asks about that no transformer reaches.
			return true
		cached = _transformer_covering(tile)
		_transformer_cover[tile] = cached
	var best := String(cached)
	return true if best == "" else grid.is_energized(best)   # uncovered ⇒ lit


## tile -> covering authored transformer id ("" = uncovered). Doc 10 asks this
## question once per signalised intersection EVERY tick, and the answer depends
## only on `loader.power`, which is written once at boot and never again — so it
## is memoised. DERIVED state: it is not captured, not saved, and a loaded game
## refills it from the same loader data.
##
## **It is WARM-FILLED at boot rather than cold-filled one intersection at a
## time** (doc 10's Wave-12 open q4). The lazy fill was O(authored power nodes)
## per tile with a `String()` cast, a `core_to_global()` and a radius lookup
## inside the inner loop, and report 98 RR-60b measured what that came to: **96 ms
## on the benchmark city**, paid by `RoadGraph.refresh_signal_power` at the load
## seam in five ~21 ms cursor steps, or by the first live frame on a fresh boot.
## `_warm_transformer_cover()` inverts the loop and pays it once.
var _transformer_cover: Dictionary = {}
## True once [_warm_transformer_cover] has enumerated every covered tile, after
## which a memo MISS is a complete answer rather than a cache fault.
var _transformer_cover_warm: bool = false
# The authored transformers, resolved once into packed columns: global tile,
# service radius, id. Everything the old inner loop re-derived per tile per node.
var _tf_x := PackedInt32Array()
var _tf_y := PackedInt32Array()
var _tf_radius := PackedInt32Array()
var _tf_id := PackedStringArray()


## Resolve `loader.power`'s transformer rows into the packed columns above. Boot
## data, read once; `_boot_power` calls it before anything can ask a tile.
func _index_transformers() -> void:
	_tf_x.clear()
	_tf_y.clear()
	_tf_radius.clear()
	_tf_id.clear()
	for node in loader.power.get("nodes", []):
		if String(node["kind"]) != "transformer":
			continue
		var t := StarterCityLoader.core_to_global(int(node["tile"][0]), int(node["tile"][1]))
		_tf_x.append(t.x)
		_tf_y.append(t.y)
		_tf_radius.append(int(PowerGrid.TRANSFORMER_SERVICE_RADIUS[int(node.get("level", 1)) - 1]))
		_tf_id.append(String(node["id"]))


## One pass over the transformers, stamping every tile each one reaches — the
## SAME argmin the per-tile scan computed, evaluated from the other side.
##
## Identical by construction, and that is the whole hash-neutrality argument:
## `_transformer_covering` is `argmin over transformers of (chebyshev distance,
## id)` restricted to `distance <= radius`, which is order-independent, so
## stamping tile-major or transformer-major lands on the same id for every tile.
## The covered SET is identical too — it is the union of the same square service
## areas — so `_transformer_cover_warm`'s "a miss means uncovered" shortcut
## answers exactly what the scan answered with `""`.
##
## The `best` table is transient: it holds the winning DISTANCE per tile for the
## duration of the fill and is dropped on the way out, because nothing afterwards
## asks how far a tile is from its transformer — only which one it is.
func _warm_transformer_cover() -> void:
	_transformer_cover.clear()
	_transformer_cover_warm = false
	var best: Dictionary = {}
	for i in _tf_id.size():
		var cx := _tf_x[i]
		var cy := _tf_y[i]
		var radius := _tf_radius[i]
		var id := _tf_id[i]
		for dy in range(-radius, radius + 1):
			var ady := absi(dy)
			for dx in range(-radius, radius + 1):
				var dist := maxi(absi(dx), ady)
				var tile := Vector2i(cx + dx, cy + dy)
				var held: Variant = best.get(tile)
				if held != null:
					var seen := int(held)
					if dist > seen or (dist == seen and id >= String(_transformer_cover[tile])):
						continue
				best[tile] = dist
				_transformer_cover[tile] = id
	_transformer_cover_warm = true


## The cold path, kept because a sim whose transformers were never indexed (a
## bare `CitySim.new()` in a unit test that boots no power) still has to answer.
## It reads the packed columns rather than `loader.power`, which is the same scan
## with the per-node `String()`, `core_to_global()` and radius lookup hoisted.
func _transformer_covering(tile: Vector2i) -> String:
	var best := ""
	var best_dist := 0x7fffffff
	for i in _tf_id.size():
		var dist := maxi(absi(tile.x - _tf_x[i]), absi(tile.y - _tf_y[i]))
		if dist > _tf_radius[i]:
			continue
		# The [dist, id] tuple ordering the scan used, unpacked: nearer wins,
		# ties break on the lower id.
		var id := _tf_id[i]
		if dist < best_dist or (dist == best_dist and id < best):
			best_dist = dist
			best = id
	return best


func _district_of_tile(tile: Vector2i) -> String:
	var b := world.block_of_tile(tile.x, tile.y)
	return String(_block_to_district.get(b.id, "")) if b != null else ""


## Doc 10 §5.1's `land.district_profile_weights(id)`: doc 02's building mix, per
## doc 09 district, as doc 10 §2.10's four land-use weights. Implemented here
## because `CitySim` owns the cross-doc seams — doc 09's `DistrictRegistry` owns
## the interface and the normalisation, doc 02's `BuildingCatalog` owns the
## category, and nothing but this class can see both.
##
## **Not a cadence — a revision memo**, exactly as `district_of_building()` is,
## and that is a ruling rather than a convenience (doc 93 §O1). Doc 10 §2.10 says
## the weights are "recomputed once per game-day"; a day timer would be a second
## thing to keep bit-identical between the fine and coarse paths for no gain,
## because the mix is a pure function of the roster and of district membership
## and both carry a revision counter. A memo over those two is exact, is cheaper
## (it recomputes only when the mix actually MOVED, not 45 times over a
## curriculum run), and — decisively — it gives a restored city the same row as
## the live one it was saved from without a restore hook to forget. It also
## matches doc 10's own grain for the sibling term: `L_dens` refreshes on
## `building_changed`, not only on the day boundary.
func _district_profile_weights(district_id: String) -> Dictionary:
	var key := Vector2i(roster_revision, districts.membership_revision)
	if key != _district_profile_key:
		_district_profile_key = key
		_rebuild_district_profile_weights()
	return districts.profile_weights(district_id)


## Σ(population + jobs) per district per doc 10 profile, from the SAME roster and
## the SAME two stats `_refresh_road_density` counts for `L_dens` — so a district
## whose demand index doc 10 raises is the district whose land-use row moved, and
## the two terms of `c_raw` can never disagree about which buildings exist.
##
## Authored CAPACITY, not this hour's occupancy: `population.occ_of` swings with
## the hour of day, and a weight that swung with it would put the time-of-day
## curve inside its own weights. The curves already own the hour.
func _rebuild_district_profile_weights() -> void:
	var mix: Dictionary = {}
	var district_by_id := district_of_building()
	for id in roster_ids():
		var b: Building = buildings[id]
		var district_id: String = district_by_id[id]
		if district_id == "":
			continue
		var profile := String(DistrictRegistry.CATEGORY_PROFILE.get(
				catalog.category(String(b.archetype)), "civ"))
		var row: Dictionary = mix.get(district_id, {})
		row[profile] = int(row.get(profile, 0)) \
				+ int(b.stats.get("population", 0)) + int(b.stats.get("jobs", 0))
		mix[district_id] = row
	districts.set_building_mix(mix)


## Doc 07 → doc 10 §5.1: the CITY-WIDE weather state (report 98 C-59 — roads
## never asks `state_at(tile)`; only the storm cell is spatial and it does not
## touch the global effect channels), lower-cased onto `data/roads.json`'s
## `weather` rows. Doc 05's water system already reads doc 07 exactly this way,
## and the six states doc 07 authors — CLEAR, CLOUDY, RAIN, HEAVY_RAIN,
## THUNDERSTORM, HEAT_WAVE — are six of doc 10's eleven rows under that fold.
##
## `RoadNetwork.step()` calls this ONCE per step and freezes the answer in
## `weather_state` for that whole step's congestion, wear and routing. That is
## the quantised snapshot doc 10 §4 guarantee 2 depends on, and it is why roads
## deliberately does not read doc 07's continuous `precip01` (C-59).
##
## The null guard is the boot window and nothing else: `_boot_roads` runs before
## `_boot_weather` so the router exists when `_boot_incidents` asks for it, and
## `bootstrap()`'s cold congestion pass reads the `clear` default rather than a
## weather system that does not exist yet. Tick 0's `step()` is the first caller.
func _road_weather_state() -> String:
	return weather.get_state().to_lower() if weather != null else "clear"


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
	for id in roster_ids():
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
		"difficulty": difficulty_preset(),
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
	# Same pattern for the two Wave-6 rosters: a conductor class the ladder does
	# not rate, or a shell mapped onto a component kind that does not exist,
	# would be a command that quotes a price for nothing.
	for entry in (_routable_rules("feeder").get("conductor_classes", []) as Array):
		var conductor_class := int(entry)
		if conductor_class < 1 or conductor_class > PowerGrid.FEEDER_CAPACITY.size():
			boot_errors.append("grid_components.json: feeder conductor class %d is unrated"
					% conductor_class)
	for archetype in _sorted(grid_rules.get("node_shells", {})):
		if String(archetype).begins_with("_"):
			continue
		var kind := StringName(String(_node_shell_kind(String(archetype))))
		if not PowerGrid.CAPACITY.has(kind):
			boot_errors.append("grid_components.json: node shell %s -> unknown kind %s"
					% [archetype, kind])


func _placeable_rules(kind: String) -> Dictionary:
	return (grid_rules.get("placeable", {}) as Dictionary).get(kind, {})


## Doc 04 §4 `route_feeder`'s roster — the LINE components, priced per tile.
func _routable_rules(kind: String) -> Dictionary:
	var row: Variant = (grid_rules.get("routable", {}) as Dictionary).get(kind, {})
	return row if row is Dictionary else {}


## The grid component kind a doc-02 shell archetype IS (report 98 C-30), or ""
## for every archetype that is only a building.
func _node_shell_kind(archetype: String) -> String:
	var row: Variant = (grid_rules.get("node_shells", {}) as Dictionary).get(archetype, {})
	if not (row is Dictionary):
		return ""
	return String((row as Dictionary).get("component_kind", ""))


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
		b.max_level = catalog.max_level_of(String(archetype))
		buildings[id] = b
		_building_records[id] = record
	_invalidate_roster()
	# Water-site kW loads are derived from the LIVE water nodes in _boot_water,
	# which runs right after _boot_power — doc 05 owns per-variant kW now.


func _boot_power() -> void:
	grid = PowerGrid.new()
	# Doc 10's per-tile transformer memo, indexed and filled HERE — before the
	# road network exists to ask it, and once for the life of the sim, restores
	# included (`loader.power` is boot data and a load re-derives from it rather
	# than trusting the body; see `_restamp_authored_power_tiles`).
	_index_transformers()
	_warm_transformer_cover()
	for node in loader.power.get("nodes", []):
		var kind := String(node["kind"])
		var opts := {"level": int(node.get("level", 1))}
		# EVERY authored node gets its authored location, terminal kinds
		# included. See `_authored_power_node_tile` — a plant and a substation
		# spell it `terminal`, and reading only `tile` left both of them at the
		# map origin, which doc 06 then used as the incident position.
		var tile := _authored_power_node_tile(node)
		if tile.x >= 0:
			opts["tile"] = tile
		match kind:
			"plant_gas":
				grid.add_component(String(node["id"]), &"plant_gas", opts)
			"substation":
				grid.add_component(String(node["id"]), &"substation", opts)
			"transformer":
				opts["parent"] = String(node["feeder"])
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
	for id in roster_ids():
		var b: Building = buildings[id]
		if b.archetype == &"substation":
			continue  # no service draw (doc 04 §2.3)
		var priority: StringName = &"CRITICAL" if b.archetype == &"water_facility" else &"STANDARD"
		var attached := grid.attach_building(id, b.origin, priority,
				String(_building_records[id].get("block", "")))
		if attached == "":
			boot_errors.append("building %s has no transformer in range" % id)


## An authored power node's GLOBAL tile, or (-1, -1) when the row carries no
## location at all. `data/starter_city.json` spells a transformer's position
## `tile` and a plant's or substation's `terminal` — the same fact under two
## names, because a terminal is the fence-line tile a feeder leaves from (doc 09
## §2.9.5) — and this is the one place that knows both spellings.
static func _authored_power_node_tile(row: Dictionary) -> Vector2i:
	var raw: Variant = row.get("tile", null)
	if raw == null:
		raw = row.get("terminal", null)
	if raw is Array and (raw as Array).size() == 2:
		return StarterCityLoader.core_to_global(int(raw[0]), int(raw[1]))
	return Vector2i(-1, -1)


## Re-stamp every AUTHORED power component's location from the boot file after a
## load. Boot geometry is not player state: a substation's terminal tile comes
## from `data/starter_city.json` and cannot change in play, so it is re-derived
## rather than trusted from the body — the same rule `_transformer_cover`
## follows, and for the same reason.
##
## It also repairs the Wave-8 defect for saves that already exist. Before
## `PowerGrid._initial_tile`, plants and substations were added with no tile and
## defaulted to (0, 0); that value went into every save, and restoring it would
## put doc 06's incident for a substation failure in the map corner where doc
## 10's router can find no street. Player-placed components are not in the
## authored list and are never touched.
func _restamp_authored_power_tiles() -> void:
	for node in loader.power.get("nodes", []):
		var row: Dictionary = node
		var id := String(row.get("id", ""))
		if id == "" or not grid.has_component(id):
			continue
		var tile := _authored_power_node_tile(row)
		if tile.x >= 0:
			grid.set_component_tile(id, tile)


func _boot_districts() -> void:
	for d in loader.districts:
		var district_id: String = districts.create_district(
				d.get("blocks", []), String(d.get("name", "")), String(d["id"]))
		# Doc 09 t0 placeholders pending doc 06's live values.
		districts.set_indices(district_id, 0.10, 0.12, 0.0)
	for d in loader.districts:
		for block_id in d.get("blocks", []):
			_block_to_district[String(block_id)] = String(d["id"])
	for id in roster_ids():
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
	# The channel a building draws on is a function of its ARCHETYPE, and there
	# are a handful of archetypes against 1,500 buildings — so the channel name
	# is resolved (and its curve value read) once per archetype instead of once
	# per building per tick. Same float in the same place in the same product.
	var channel_value_by_archetype: Dictionary = {}
	for id in roster_ids():
		var b: Building = buildings[id]
		if b.archetype == &"substation":
			continue
		var base := float(b.stats.get("power_demand_kw", 0.0))
		if b.archetype == &"water_facility":
			base = float(_water_kw_by_building.get(id, base))
		var channel_value: Variant = channel_value_by_archetype.get(b.archetype)
		if channel_value == null:
			var channel := String(DEMAND_CLASS_CHANNEL.get(b.archetype, "power_demand_civic"))
			channel_value = float(ctx.channels[channel])
			channel_value_by_archetype[b.archetype] = channel_value
		var occ := population.occ_of(id)
		demands[id] = base * b.power_demand_mult() * float(channel_value) * occ
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


## Retire this city: break every reference cycle a `RefCounted`-only sim can
## make, so the instance can actually free (doc 91 D-9).
##
## **One call instead of two, and the second one is new.** Every caller today
## does `sim.scheduler.dispose()` — `game/sim_host.gd`, `tools/profile_save.gd`,
## two tests — which breaks the sim ↔ phase-adapter loop and nothing else. Doc 06
## §2.16's spawner adds a second loop of the same shape: it stores `Callable`s
## that resolve through this class (the coverage index lives behind
## `CityIncidentWorld`, which holds the sim), exactly as
## `WaterSystem.powered_provider` has since doc 05 shipped.
##
## This is the one place that knows about both, so callers should move to it.
## `scheduler.dispose()` on its own is not wrong — it is half — and calling this
## twice is harmless.
func dispose() -> void:
	if scheduler != null:
		scheduler.dispose()
	if street != null:
		street.dispose()


func advance_hours(hours: float) -> void:
	scheduler.advance_fine_n(roundi(hours * GameClock.TICKS_PER_HOUR))


func advance_coarse_hours(hours: int, is_catchup: bool = true) -> void:
	if is_catchup and director != null:
		director.catchup_begin()   # doc 07 C-55: once per catch-up session
	scheduler.advance_coarse_n(hours, is_catchup, 0, hours)


## A whole `CatchUpPlanner` plan, resumable: units the shell may spend across
## frames behind S15's catch-up veil (doc 13 §2.9, A91-D-31). The synchronous
## loop it replaces lives in `game/main.gd::_on_app_resumed`, and the two land on
## the same city bit for bit — `CatchUpCursor` explains which seam guarantees it
## and `tests/test_catchup_cursor.gd` proves it on both cities.
##
## Doc 13 §2.9's pseudocode calls this `advance_coarse_sliced(hours_per_slice)`
## and has it return "done yet?". It is a cursor instead, for two reasons the
## shipped planner makes unavoidable: a returning player's plan is not coarse
## hours alone — it carries a fine head-align segment and a 40-tick fine tail
## (doc 91 D-1), which a coarse-only entry point cannot advance — and the slice
## BUDGET cannot live in here at all, because `sim/` may not read a clock
## (constitution §5). Same design, one layer out: the shell owns the budget, this
## owns the unit.
func begin_catchup(plan: Dictionary) -> CatchUpCursor:
	var on_segment_begin := Callable()
	if director != null:
		on_segment_begin = director.catchup_begin
	return CatchUpCursor.new(scheduler, plan, on_segment_begin)


## Capture for SAVING. Godot's full-precision JSON printer is not
## shortest-round-trip for every double (≤1 ULP loss, and not even
## idempotent), so decimal text can never carry sim floats. Floats are
## encoded as exact 64-bit hex strings ("~f~<16 hex>") — lossless through
## any number of JSON round-trips, so the instance that saved and the
## instance that loads proceed bit-identically (constitution §5, M1
## criterion 8). restore_state() decodes transparently.
##
## **This is [capture_detached] then [encode_captured], in one call.** It is what
## every tool, test and `state_hash()` wants and it stays the API. The split
## below is for the saver that cares which thread each half runs on.
func canonical_capture() -> Dictionary:
	return encode_captured(capture_detached())


## THE HALF THAT MUST RUN ON THE SIM'S THREAD: a read of live simulation state,
## and the whole reason a save is deterministic (doc 08 §2.6).
##
## `capture_state()` builds fresh dictionaries almost everywhere, but "almost" is
## not a contract a worker thread can be handed — `RoadNetwork.save_section()`
## alone puts three live containers into its body by reference. The
## `duplicate(true)` is that contract, made explicit and made NATIVE: 8.1 ms on
## the 1,500-building benchmark city against the 28 ms a GDScript walk needs to
## copy the same tree (doc 98 §24). What comes back aliases nothing in the sim,
## so it may be encoded, stringified and digested anywhere.
##
## Measured in isolation: capture_state 25.5 ms + duplicate 8.1 = **33.6 ms**,
## against the 75 ms `capture_state()` + `_encode_floats()` used to cost on the
## same city. Through the shipped path — `SaveService.save_slot`, sections,
## envelope header and all — that is **85.4 → 39.2 ms** of caller time
## (`tools/profile_save.gd --async --repeats=7`, best of 7).
func capture_detached() -> Dictionary:
	return capture_state().duplicate(true)


## THE HALF THAT NEED NOT: a pure function of the detached body above, which is
## why `SaveManager.commit_save()` runs it on the write thread. It MUTATES its
## argument and returns it — the tree is already a private copy, and a second
## deep copy here is 8 ms nobody is paying for.
##
## Idempotent on purpose: `_encode_float()` leaves ints and `~f~` strings alone,
## so encoding an already-encoded body is a no-op rather than a corruption. That
## is what makes it safe as a `SaveSection` finalizer, where the manager cannot
## know whether a caller encoded first.
static func encode_captured(raw_body: Dictionary) -> Dictionary:
	_encode_in_place(raw_body)
	return raw_body


## Doc 08 §2.8: this body's own ladder position, independent of the envelope's
## `schema_version`. Bumping it IS "the city section changed shape".
##
## **v2 — 2026-08-20, the sub-step rules epoch (Wave 8).** The city body's SHAPE
## is byte-for-byte what v1 wrote; not one key was added, removed or renamed, and
## `_v1_to_v2` is the identity function on purpose. What moved is the RULES that
## body is advanced under: the fire-spread breakpoint became conditional on a
## live `structure_fire`, so a quiet hour is integrated in fewer, larger
## sub-steps and the generators draw a different (statistically identical)
## Poisson sequence.
##
## *(This rung was originally written to claim the street-true dispatch ETAs as
## well. It should not have: Wave 8 measured the wiring and took it back out, and
## the stand-in shipped in v2. The claim is corrected here rather than left
## standing, because a ladder that describes rules the binary did not have is
## worse than no ladder. Street-true ETAs are v4's, below.)*
##
## **Why that is a version bump and not a free change.** Doc 08 §2.8's ladder is
## not only about shape. A v1 save is a promise about what the binary that wrote
## it would have done next; advancing it under v2 rules produces a city that v1
## would not have produced, and a player who saves in v1 and loads in v2 sees a
## different fire, a different truck and a different arrival time. The bump is
## how that is recorded honestly. It does NOT cost the player anything: an
## identity migrator means every v1 save still loads, with every building, dollar
## and RNG stream exactly where it was left (`tests/test_save_migration.gd`).
##
## The alternative — leaving it at 1 — was rejected because it would make the
## ladder's own claim false. `section_version` is the only field a future
## migrator can key on, and a save written under the old dispatch rules is
## exactly the kind of thing a future rule change will need to recognise. A
## version that never moves when the rules move cannot be that key.
##
## **v3 — 2026-08-20, doc 09 §2.14's goal curriculum (Wave 9).** The body gains
## ONE key, `goals`, and gains it additively: every other key is byte-for-byte
## what v2 wrote. What it costs a v2 save is not a field, it is an ANSWER — a
## city that has been played for thirty game-days has no record of which
## objectives it met, because nothing was counting. `_v2_to_v3` therefore does
## the only honest thing a migrator can do here: it stamps the body
## `goals.bootstrap = true` and leaves the answer to `restore_state`, which is
## the first place that can see the whole restored city (doc 08 §2.8 forbids a
## migrator from reading `data/`, and the curriculum lives in `data/goals.json`).
## `GoalSystem.bootstrap` then completes every level at or below the city's own
## level and initialises the active one from what the city already HAS — see its
## own docs for the two rules and why they are the kind ones.
##
## **v4 — 2026-08-20, THE ROUTING / CADENCE EPOCH (Wave 9).** Mostly a rules
## rung, like v2: `_v3_to_v4` is the identity function and every key a v3 body
## carries means what it meant. It is not *purely* a rules rung — the cadence
## change below adds two additive keys, `power.service_pending_gs` and
## `water.service_pending_h`, each the un-banked remainder of the current
## game-minute; a v3 body has neither and restores both at zero, which is exactly
## what a v3 body meant. Four rule changes land together, and every one of them
## moves the numbers a v3 body would have produced next:
##
##   1. **Dispatch ETAs are street-true.** `IncidentSystem` holds doc 10's
##      `RoadTravelTimeProvider` instead of doc 06's Chebyshev stand-in, so every
##      `eta_gs`, every arrival minute, every assignment ranking and every
##      `unreachable` verdict is a different number (report 98 RR-26).
##   2. **Doc 06 §2.10 has a terminal rule.** An incident with nothing committed
##      to it for `unanswered_abandon_h` (24 game-hours, one game-day) becomes ABANDONED, and
##      `max_acceptable_cost_min` is re-fitted 90 → 115 against the street-true
##      distribution. Incidents that used to stand at tier 5 for ever now end.
##   3. **The minute's roads work is spread across the four ticks of the minute**
##      (doc 91 D-15 proposal 2), which reorders draws inside the `traffic` RNG
##      stream.
##   4. **The power and water service ledgers accumulate per game-minute**
##      (D-15 proposal 3): the settled hour is the same in value, not in float
##      association, and the LIT/DARK hysteresis samples on a coarser grid.
##
## An identity migrator again: a v3 save opens with every building, dollar and
## RNG stream exactly where it was left. What it does not get is the city v3
## would have produced next — which is the whole reason the rung exists.
##
## **v5 — 2026-08-20, THE UPGRADE-TIMING EPOCH.** The smallest rules rung this
## ladder has: `cmd_upgrade_building` read `upgrade_time_hours` from the row
## being upgraded TO, and doc 02 §2.2 stores the price of the step `L → L+1` on
## the row upgraded FROM (report 98 RR-29(h), ruled in RR-38). Every upgrade in
## the game except the last step of a ladder therefore ran one rung's duration
## too slow — a `house` L4→L5 was billed 7.0 crew-hours for a step doc 02 prices
## at 5.0, a `high_rise` L4→L5 was billed 148 for 87. `_v4_to_v5` is the identity
## function: no key means anything different and no default is invented,
## including for the jobs already on the construction queue. **An upgrade in
## flight keeps the duration it was quoted** — `ConstructionQueue` stores
## `required_crew_hours` per job, so a v4 body's in-flight jobs finish on the
## old bill and only the NEXT upgrade the player buys is priced correctly. That
## is the kind reading: re-pricing a job the player already paid for, downward,
## mid-flight would be a gift; re-pricing it upward would be a theft; leaving it
## alone is the only one of the three that is a *record*.
##
## The rung exists for the epoch rule and nothing else: the binary now does
## something different with the same body, so the version that names the rules
## has to move.
##
## **v6 — 2026-08-20, THE DIFFICULTY EPOCH (doc 91 A91-D-19).** Doc 03 §2.9's
## preset stops being a thing only the Disaster Director knows and becomes the
## city's: it now prices every build, upgrade, land purchase, development phase
## and repair through `M_build` / `M_land` / `M_dev` / `M_repair`, scales revenue
## and recurring expense through `M_rev` / `M_exp`, sets the revenue floor, the
## credit APR, the relief-grant allowance and the offline taper, and drives doc
## 06's escalation and generation multipliers as well as doc 07's four pressure
## knobs. Under v5 exactly one of those was reachable — the Director's — and the
## other eleven were `Treasury.DIFFICULTY_STANDARD` on every boot forever.
##
## **The body's SHAPE does not move, and that is deliberate.** The preset is
## already in a v5 body: `DisasterDirector.serialize()` has written
## `"difficulty"` since doc 07 shipped, and `deserialize` has keyed
## `_difficulty_locked` on it. Adding a second copy at city level would be two
## records of one fact — the scattering C-17 exists to stop — and would move
## `state_hash()` on the DEFAULT preset, which this change may not do. So
## `_restore_difficulty` reads the preset back out of the section that already
## carries it and makes it the whole city's again. `_v5_to_v6` is therefore the
## identity function on every save the game has ever written, and stamps the
## default only into a body that somehow carries no `director.difficulty` at all
## (a hand-edited one; there is no such save in the wild).
##
## What a v5 save loses by opening under v6: **nothing**. Every v5 save was
## written by a binary on which only `standard` was reachable, so the default the
## migrator names is not a guess — it is the preset that city was actually played
## on, and the rung is a rules rung exactly like v2 and v4.
##
## **v7 — 2026-08-21, THE OPPORTUNITY LAYER (doc 06 §2.16).** A SHAPE rung, and
## the first one since v3. The body gains one top-level key, `street` —
## `{next_id, live: [...]}`, the roster of tappable bounties standing on the
## city's kerbs — and one entry inside an existing one: `rng.street`, the new
## named stream the spawner draws from (constitution §5).
##
## `_v6_to_v7` is the identity function, and unusually it is the identity
## function *and* the whole truth. Both additions restore correctly from a v6
## body with no migration at all:
##
##   * `OpportunitySystem.deserialize({})` yields an EMPTY roster with
##     `next_id = 1`, which is exactly what a v6 city had — under v6 nothing
##     could spawn, so "no live opportunities" is not a default invented for the
##     save, it is the fact.
##   * `RngStreams.deserialize` walks the streams it HAS and takes each one's
##     entry if the body carries it, so a v6 body re-seats its six known streams
##     and leaves `street` on the seed `hash(master_seed + ":street")` gave it at
##     boot — the same position a fresh city of that seed starts from.
##
## What the player loses by opening a v6 save under v7: nothing, and they gain
## the layer on the next game-minute they spend looking at the city.
##
## The rung exists because the *shape* moved and §2.8's ladder is the only
## record of that. It is also a rules rung, mildly: `state_hash()` moves for
## every city, played or founding, because the `rng` block has a seventh entry
## and the body has a twenty-ninth key. Nothing else in the body changes value —
## the spawner reads the city and writes only its own section, and no other
## stream's sequence is perturbed, which is the property RR-77 turns into a test.
const SAVE_SECTION_VERSION := 7


func save_section_version() -> int:
	return SAVE_SECTION_VERSION


## Doc 08 §2.8's rules: TOTAL (never fails — missing input means a documented
## default), additive-first (a removed field is ignored for one version before
## it is dropped), and it NEVER reads `data/`, because the tables will have
## moved on by the time an old save arrives.
func migrate_save_section(body: Dictionary, from_version: int) -> Dictionary:
	var version := from_version
	while version < SAVE_SECTION_VERSION:
		match version:
			1: body = _v1_to_v2(body)
			2: body = _v2_to_v3(body)
			3: body = _v3_to_v4(body)
			4: body = _v4_to_v5(body)
			5: body = _v5_to_v6(body)
			6: body = _v6_to_v7(body)
		version += 1
	return body


## v1 → v2: **the identity function, and that is the whole migration.** The
## epoch marks a rules change, not a shape change (see `SAVE_SECTION_VERSION`),
## so there is no field to add and no default to invent. Written out as a named
## step rather than an empty `while` body because the ladder is a record: the
## next person to read it needs to see that v1 was considered and deliberately
## left alone, not that a rung was skipped.
static func _v1_to_v2(body: Dictionary) -> Dictionary:
	return body


## v2 → v3: **mark, do not answer.** Doc 08 §2.8's migrator contract is TOTAL and
## may not read `data/`, and the answer this migration needs — which of doc 09
## §2.14's objectives a thirty-game-day city has already met — is a function of
## the whole restored city *and* of `data/goals.json`. Neither is visible from
## here. So the body is stamped with the one bit `restore_state` needs, and a
## save that somehow already carries a real `goals` block (there is no such save
## today, but a hand-edited one is not this function's business to lose) is left
## exactly as it is.
static func _v2_to_v3(body: Dictionary) -> Dictionary:
	var existing: Variant = body.get("goals", null)
	if existing is Dictionary and (existing as Dictionary).has("earned_level"):
		return body
	body["goals"] = {"bootstrap": true}
	return body


## v3 → v4: **the identity function, and that is the whole migration.** The
## routing / cadence epoch changes RULES, not shape (see `SAVE_SECTION_VERSION`),
## so there is no field to add and no default to invent. In particular it does
## NOT invent an `unanswered_h` for the incidents already in the body: doc 06
## §2.10's clock measures *time since anything was last committed*, and a v3 body
## records no such thing, so every restored incident starts its clock at zero and
## gets a full game-day before the new rule can touch it. Inventing a
## number here would abandon a returning player's incidents on the strength of a
## guess, which is the opposite of what a migrator is for.
static func _v3_to_v4(body: Dictionary) -> Dictionary:
	return body


## v4 → v5: **the identity function, and that is the whole migration.** The
## upgrade-timing epoch changes one READ in `cmd_upgrade_building` (see
## `SAVE_SECTION_VERSION`), so there is no field to add and no default to
## invent. In particular it does NOT re-price the construction jobs already in
## the body: `ConstructionQueue` serialises `required_crew_hours` and
## `required_work_units` per job, so an upgrade in flight finishes on the bill it
## was quoted and the correction reaches the player on the next upgrade they
## buy. Re-pricing a paid-for job downward mid-flight would be a gift and upward
## would be a theft; leaving it is the only one of the three that is a record.
static func _v4_to_v5(body: Dictionary) -> Dictionary:
	return body


## v5 → v6: **name the preset, and default it to the only one that was
## reachable.** The difficulty epoch (see `SAVE_SECTION_VERSION`) promotes doc 03
## §2.9's preset from the Director's own knob to the city's, and the body already
## records it — `director.difficulty` has carried it since doc 07 shipped. So on
## every save the game has ever written this is the identity function.
##
## The stamp exists for the one body that is not: a `director` section with no
## `difficulty` string. Under v5 that body restored to the Director's own
## `"standard"` default and played `standard`, so writing `standard` in is not a
## guess about what it meant — it is what it meant, said out loud so that v6's
## reader has one place to look. Doc 08 §2.8: TOTAL, additive-first, and it reads
## no `data/` (the preset NAMES a row; it does not carry one).
##
## It adds **no top-level key**, ever. A body with no `director` section at all
## is a fragment, not a city, and inventing a section for it would make this the
## first rung on the ladder that rewrites a shape rather than recording a rules
## change — `restore_state` defaults such a body to the same preset anyway.
static func _v5_to_v6(body: Dictionary) -> Dictionary:
	var raw: Variant = body.get("director", null)
	if not (raw is Dictionary):
		return body
	var block: Dictionary = raw
	if String(block.get("difficulty", "")) != "":
		return body
	block["difficulty"] = Difficulty.DEFAULT_PRESET
	body["director"] = block
	return body


## v6 → v7: **the identity function, and here it is also the complete answer.**
## The opportunity layer (see `SAVE_SECTION_VERSION`) adds a `street` section and
## a seventh RNG stream, and both restore correctly from a body that has
## neither: an absent `street` block deserialises to an empty roster, which is
## what a v6 city genuinely had, and `RngStreams.deserialize` leaves an unknown
## stream on its boot seed, which is where a fresh city of the same seed starts.
##
## It deliberately does NOT stamp an empty `street` block in. Doc 08 §2.8's rule
## is additive-first and TOTAL, not "write every key the current shape has": a
## migrator that materialises defaults is a migrator that has to be re-read every
## time the default changes, and `restore_state` already answers this one. The
## v5 → v6 rung took the same line for the same reason.
static func _v6_to_v7(body: Dictionary) -> Dictionary:
	return body



## One float, canonicalized. Integral values become ints (exactly representable
## either way; consumers cast on read) so int/float typing between a live and a
## loaded state can never alias. Only true fractions need bits.
##
## Two u32 halves, high first — the same 16 hex chars "%016x" would print, but
## sign-bit-set doubles survive: a whole-u64 "%016x" prints a NEGATIVE int with a
## minus sign, and `hex_to_int` refuses any pattern above int64 max, so both
## full-width paths break on negative doubles.
static func _encode_float(value: float) -> Variant:
	if absf(value) < 4.6e18 and value == float(int(value)):
		return int(value)
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_double(0, value)
	return "~f~%08x%08x" % [bytes.decode_u32(4), bytes.decode_u32(0)]


static func _decode_float(text: String) -> float:
	var hex := text.substr(3)
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_u32(4, ("0x" + hex.substr(0, 8)).hex_to_int())
	bytes.encode_u32(0, ("0x" + hex.substr(8, 8)).hex_to_int())
	return bytes.decode_double(0)


## Encode a body the caller already owns, in place. **The shape of this walk is
## the whole optimization** (doc 98 §24).
##
## The recursive rebuild it replaces cost 62 ms on the benchmark city, and the
## measurements say why: a GDScript walk that does nothing but VISIT the 112,000
## nodes of that body costs 30 ms if it recurses per node and 14 ms if it pops a
## stack and pushes `values()` in one native `append_array`. The per-node call is
## the bill, not the hex — a float encoder that pools its `PackedByteArray` saves
## 0.1 ms and a nibble-table formatter is 6 ms SLOWER than `%08x` (both measured
## and both rejected). So: copy the tree with the engine's own deep copy (8 ms of
## C++), then patch the ~22,000 float leaves with a stack walk that never
## recurses. **36 ms, and byte-identical output.**
##
## A TYPED array is re-seated untyped as it is discovered, which is not a detail:
## the old rebuild produced untyped arrays everywhere, three of the benchmark
## city's arrays arrive typed, and writing a `~f~` string into an `Array[float]`
## is an error while writing an int into one silently converts it back to a float
## and changes the bytes on disk.
static func _encode_in_place(root: Variant) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Variant = stack.pop_back()
		if node is Dictionary:
			var d: Dictionary = node
			for key: Variant in d.keys():
				var v: Variant = d[key]
				var t := typeof(v)
				if t == TYPE_FLOAT:
					d[key] = _encode_float(v)
				elif t == TYPE_DICTIONARY:
					stack.push_back(v)
				elif t == TYPE_ARRAY:
					if (v as Array).is_typed():
						var untyped: Array = []
						untyped.assign(v)
						d[key] = untyped
						v = untyped
					stack.push_back(v)
		else:
			var a: Array = node
			for i in a.size():
				var v: Variant = a[i]
				var t := typeof(v)
				if t == TYPE_FLOAT:
					a[i] = _encode_float(v)
				elif t == TYPE_DICTIONARY:
					stack.push_back(v)
				elif t == TYPE_ARRAY:
					if (v as Array).is_typed():
						var untyped: Array = []
						untyped.assign(v)
						a[i] = untyped
						v = untyped
					stack.push_back(v)


## [_encode_in_place]'s mirror. Same shape, same reasons, 58 ms → 34 ms.
static func _decode_in_place(root: Variant) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Variant = stack.pop_back()
		if node is Dictionary:
			var d: Dictionary = node
			for key: Variant in d.keys():
				var v: Variant = d[key]
				var t := typeof(v)
				if t == TYPE_STRING:
					if (v as String).begins_with("~f~"):
						d[key] = _decode_float(v)
				elif t == TYPE_DICTIONARY:
					stack.push_back(v)
				elif t == TYPE_ARRAY:
					if (v as Array).is_typed():
						var untyped: Array = []
						untyped.assign(v)
						d[key] = untyped
						v = untyped
					stack.push_back(v)
		else:
			var a: Array = node
			for i in a.size():
				var v: Variant = a[i]
				var t := typeof(v)
				if t == TYPE_STRING:
					if (v as String).begins_with("~f~"):
						a[i] = _decode_float(v)
				elif t == TYPE_DICTIONARY:
					stack.push_back(v)
				elif t == TYPE_ARRAY:
					if (v as Array).is_typed():
						var untyped: Array = []
						untyped.assign(v)
						a[i] = untyped
						v = untyped
					stack.push_back(v)


## The pure form: never touches the caller's tree. Kept because `state_hash()`,
## the migration ladder and the tests all hand it bodies they still need.
static func _encode_floats(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			return _encode_float(value)
		TYPE_DICTIONARY:
			var out_dict: Dictionary = (value as Dictionary).duplicate(true)
			_encode_in_place(out_dict)
			return out_dict
		TYPE_ARRAY:
			var out_array: Array = []
			out_array.assign((value as Array).duplicate(true))
			_encode_in_place(out_array)
			return out_array
		_:
			return value


static func _decode_floats(value: Variant) -> Variant:
	match typeof(value):
		TYPE_STRING:
			if (value as String).begins_with("~f~"):
				return _decode_float(value)
			return value
		TYPE_DICTIONARY:
			var out_dict: Dictionary = (value as Dictionary).duplicate(true)
			_decode_in_place(out_dict)
			return out_dict
		TYPE_ARRAY:
			var out_array: Array = []
			out_array.assign((value as Array).duplicate(true))
			_decode_in_place(out_array)
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
		"goals": goals.serialize(),
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
		"director_links": _serialize_director_links(),
		"incidents": incidents.serialize_incidents(),
		"fleet": incidents.fleet.serialize(),
		"dispatch": incidents.dispatch.serialize(),
		"roads": roads.save_section(),
		"weather": weather.serialize(),
		"director": director.serialize(),
		"street": street.serialize(),
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


## Rebuild the live city from a saved body, in ONE call. Tools, tests, the
## legacy loader and every caller that has no frame to protect want this.
##
## It is [begin_restore] drained on the spot, and that is not a convenience
## wrapper around a second implementation — there is one implementation, cut
## into nine steps, and this drains them. See `RestoreCursor` for why the cut
## exists and `tests/test_save_chunked_restore.gd` for the proof that draining
## it in one call and spending it one step per frame land on the same city.
func restore_state(raw_body: Dictionary) -> void:
	begin_restore(raw_body).run()


## The same restore, resumable: steps the shell may spend across frames behind a
## loading veil (doc 13 §2.9). The cut points are where the measured cost is, and
## the sim is INCONSISTENT at every seam, so nothing may tick, render or query it
## between steps.
##
## **The step COUNT is a property of the city, not of this function.** Nine steps
## are named here; the `roads` step splices in `RoadNetwork.load_section_steps()`
## when it runs, and the road graph's own trace phase emits one step per
## `RoadGraph.REBUILD_TRACE_NODE_BUDGET` nodes — so a bigger city is more steps,
## not longer ones, which is the only shape a per-frame budget can be written
## against. Ask `RestoreCursor.step_count()`; do not count the `add` calls below.
##
## `roads` is spliced rather than cut here because the seams inside a road load
## are the road network's to name, and a restore that pretended to know them would
## go stale the first time that loader grew a phase — which it just did, from
## three phases to eight.
##
## Step costs on the 1,500-building benchmark city, workstation (report 98 §26):
## decode 31, core 4, world 23, records 0.1, roster 8, water 18, incidents 0.7,
## roads_tiles 16, then the road graph in four phases and the labelling and state
## behind it. **What the veil budget is written against is the LONGEST step, not
## the total.**
func begin_restore(raw_body: Dictionary) -> RestoreCursor:
	var cursor := RestoreCursor.new()
	# One-slot holder rather than a member: two restores in flight is not a
	# state this class should be able to represent, and a member would let it.
	var held: Dictionary = {}
	cursor.add("decode", func() -> void:
		held["body"] = _decode_floats(raw_body))
	cursor.add("core", func() -> void: _restore_core(held["body"]))
	cursor.add("world", func() -> void: _restore_world(held["body"]))
	cursor.add("records", func() -> void: _restore_records(held["body"]))
	cursor.add("roster", func() -> void: _restore_roster(held["body"]))
	cursor.add("water", func() -> void: _restore_water(held["body"]))
	cursor.add("incidents", func() -> void: _restore_incidents(held["body"]))
	# The road loader's own seams, spliced WHOLE. Resolved at STEP time and not
	# here — the body is still encoded when `begin_restore` returns, and `roads`
	# is not a key until `decode` has run — so the first roads step is the one
	# that asks for the list, runs the list's own first entry, and splices the
	# rest into this cursor.
	#
	# It is spliced rather than named here because the seams inside a road load
	# are the road network's, and there are now eight of them rather than three:
	# `RoadGraph.rebuild_all()` used to be one 73.7 ms step and is four (doc 91
	# A91-D-30, report 98 §26 RR-61). A `begin_restore` that hard-coded three
	# indices would have quietly dropped five of them.
	#
	# `splice_next`, never `add`: the spliced steps have to land BEFORE `finish`
	# below and before the `settle` step `SaveService.begin_load_slot()` appends
	# after this function returns. See `RestoreCursor.splice_next`.
	#
	# The cursor is captured WEAKLY. A lambda stored in `cursor._steps` that also
	# held a strong reference to `cursor` is a reference cycle, and `RefCounted`
	# has no collector to break it — every restore would leak its own cursor and
	# every closure hanging off it. The cursor is alive for as long as anything is
	# calling `step()` on it, which is the only window this runs in.
	var cursor_ref: WeakRef = weakref(cursor)
	cursor.add("roads", func() -> void:
		var road_steps: Array = roads.load_section_steps(held["body"].get("roads", {}))
		if road_steps.is_empty():
			return
		(((road_steps[0] as Array)[1]) as Callable).call()
		var live: RestoreCursor = cursor_ref.get_ref()
		if live == null:
			# No cursor to splice into: drain the rest here so a caller that let go
			# of its cursor mid-restore still gets a whole city rather than half of
			# one. Nothing does this; a half-restored city is worth a defensive line.
			for i in range(1, road_steps.size()):
				(((road_steps[i] as Array)[1]) as Callable).call()
			return
		var labels := PackedStringArray()
		var steps: Array[Callable] = []
		for i in range(1, road_steps.size()):
			labels.append(String((road_steps[i] as Array)[0]))
			steps.append((road_steps[i] as Array)[1])
		live.splice_next(labels, steps))
	cursor.add("finish", func() -> void: _restore_finish(held["body"]))
	return cursor


func _restore_core(body: Dictionary) -> void:
	clock.deserialize(body.get("clock", {}))
	rng.deserialize(body.get("rng", {}))
	grid.deserialize(body.get("grid", {}))
	_restamp_authored_power_tiles()
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


func _restore_world(body: Dictionary) -> void:
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


func _restore_records(body: Dictionary) -> void:
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
	# Player-placed POINT components carry a one-tile reservation the loader knows
	# nothing about; the power section is already restored, so re-stamp from it.
	# Only the `placeable` roster reserves ground: a routed feeder is a polyline
	# that blocks nothing and carries no `tile` (it would re-stamp (0,0)), and a
	# substation or plant is a BUILDING whose footprint `placed_records` above
	# already re-stamped (report 98 C-30).
	for component_id in grid.component_ids():
		var component: Dictionary = grid.component(component_id)
		if not bool(component.get("player_placed", false)):
			continue
		if _placeable_rules(String(component["kind"])).is_empty():
			continue
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


func _restore_roster(body: Dictionary) -> void:
	buildings.clear()
	_invalidate_roster()
	# `grid_id -> sim_id`, built ONCE. The roster rebuild used to answer that
	# question with a linear scan of `_building_records` per saved building, which
	# is O(roster²) — 1,500 buildings against 1,500 records is 1.1 million
	# dictionary reads and it was **216 ms of a 426 ms restore** (measured, doc 98
	# §24). The index is the same answer: `_building_records` iterates in insertion
	# order, the scan took the FIRST record with a matching `grid_id`, and
	# `has()`-guarding the insert keeps the first one here too, so a body with
	# duplicate grid ids (there is no such body, but a hand-edited one is not this
	# loop's business to re-rule) still binds exactly where it did before.
	var record_by_grid_id := {}
	for candidate_id in _building_records:
		var candidate_grid_id := int(_building_records[candidate_id]["grid_id"])
		if not record_by_grid_id.has(candidate_grid_id):
			record_by_grid_id[candidate_grid_id] = candidate_id
	for record in body.get("buildings", []):
		var b := Building.deserialize(record)
		var id := String(record_by_grid_id.get(b.id, ""))
		if id == "":
			continue
		b.stats = catalog.stats(String(b.archetype), maxi(b.level, 1))
		b.max_level = catalog.max_level_of(String(b.archetype))
		buildings[id] = b
	_invalidate_roster()
	# Block-dark weights are derived from the live roster, so rebuild rather than
	# carry: a demolished building must not keep voting on its block's darkness.
	_block_dark_weights.clear()
	for id in roster_ids():
		var live: Building = buildings[id]
		_block_dark_weights[id] = int(live.stats.get("population", 0)) \
				+ int(live.stats.get("jobs", 0))


func _restore_water(body: Dictionary) -> void:
	water.deserialize(body.get("water", {}))
	# The site loads are DERIVED from the node roster, and a player-placed pump
	# exists only in the water section — so they are rebuilt here rather than
	# carried, exactly as `_block_dark_weights` is above.
	_refresh_water_kw()


func _restore_incidents(body: Dictionary) -> void:
	_director_links.clear()
	for key in body.get("director_links", {}):
		_director_links[int(key)] = int(body["director_links"][key])
	incidents.deserialize_incidents(body.get("incidents", {}))
	incidents.fleet.deserialize(body.get("fleet", {}))
	incidents.dispatch.deserialize(body.get("dispatch", {}))
	# Doc 06 §2.16 / doc 08 §2.8 v7: a save taken mid-crook restores the crook.
	# A v6 body has no `street` block and restores to an empty roster, which is
	# exactly what a v6 city had.
	street.deserialize(body.get("street", {}))


func _restore_finish(body: Dictionary) -> void:
	weather.deserialize(body.get("weather", {}))
	director.deserialize(body.get("director", {}))
	_restore_difficulty(body)
	_refresh_road_density()
	_restore_goals(body)


## Doc 03 §2.9 + doc 08 §2.8 city section v6: the preset is part of the city, so
## a restored city gets its multipliers back before it settles an hour.
##
## The body records the preset in exactly ONE place — the `director` section's
## own `difficulty` string, which has carried it since doc 07 shipped — and this
## is where it becomes the whole city's again. `director.deserialize` has just
## re-pinned the Director from the same string; this line re-pins the treasury's
## twelve economic knobs, the four pressure knobs and (through `sim.difficulty`)
## doc 06's escalation pair, so a `hard` city loaded from disk prices its next
## build at `hard` and not at whatever the process booted on.
##
## The balance is NOT reset: `treasury.deserialize` has already restored the
## dollars the save recorded, and `starting_treasury` is a founding number only.
## An unknown preset falls back to the default rather than refusing the load —
## doc 08 §2.8's migrator contract is TOTAL, and a city is worth more than a
## string.
func _restore_difficulty(body: Dictionary) -> void:
	var raw: Variant = body.get("director", null)
	var block: Dictionary = raw if raw is Dictionary else {}
	var name := String(block.get("difficulty", Difficulty.DEFAULT_PRESET))
	if not difficulty.select(name):
		difficulty.select(Difficulty.DEFAULT_PRESET)
	treasury.apply_difficulty(difficulty.row("economic"), false)
	_push_difficulty_to_systems()


## Doc 09 §2.14's half of the load, and it runs LAST on purpose: both branches
## read the city that the lines above have just finished standing up.
##
##   * a v3 body carries the counters verbatim — save → load → advance stays
##     bit-identical, which is what makes the goals section a save section and
##     not a UI preference;
##   * a v2 body carries `_v2_to_v3`'s marker instead, and the curriculum is
##     BOOTSTRAPPED from the city itself.
##
## Either way the queue is emptied afterwards. A restore is not an achievement:
## bootstrapping a level-4 city completes four levels' worth of objectives, and
## publishing those would greet a returning player with four level-up toasts for
## work they did last week.
func _restore_goals(body: Dictionary) -> void:
	var raw: Variant = body.get("goals", {})
	var block: Dictionary = raw if raw is Dictionary else {}
	if block.has("earned_level"):
		goals.deserialize(block)
		goals.reconcile(goal_state_view())
	else:
		goals.bootstrap(progression.city_level, goal_residue_counts(), goal_state_view())
	goals.drain_events()


## Publishes a `ProgressionSystem` event batch and keeps doc 09 §2.3's
## purchasable set in step with the level those events may have moved.
##
## `WorldMap.refresh_purchasable` has always been documented as running "after
## any purchase or city-level change", and only the purchase half was ever
## wired — so a city that levelled up without buying anything went on showing
## LOCKED on the ring-2 blocks it had just earned until the player happened to
## buy something else. It is called HERE, at the moment the level moves, rather
## than from a per-tick "has it changed?" guard, because a guard would refresh
## on the first tick after a load and a live instance would not: that is a
## save → load → advance divergence, and identity is not worth a tidier call
## site.
func publish_progression(events: Array) -> void:
	for event: Variant in events:
		var type := StringName(String((event as Dictionary)["type"]))
		bus.emit(type, event)
		if type == &"city_level_changed":
			world.refresh_purchasable(progression.city_level)
			_pay_level_up_grant(event as Dictionary)


## **The celebration grant** (doc 03 §2.5a, report 98 RR-79).
##
## The goals sheet already celebrates a city level; from this wave it also pays
## for the next chapter. `grant_level` is the one write path onto `city_level`
## and it emits exactly one `city_level_changed` per move, carrying `from` and
## `to` — so a jump that crosses two rungs at once (a population surge past a
## threshold the objectives had not reached) pays BOTH, and neither route to a
## rung is worth more than the other.
##
## It is a one-off receipt, not an hourly ledger line: doc 03 §2.4 keeps one-off
## capital spends out of the recurring rate, and the symmetric treatment for a
## one-off receipt is the same. The player sees it as a treasury event and a
## notification; the budget panel's income statement stays an income statement.
##
## `city_level` is monotone (`data/progression.json`'s `city_level_monotone`),
## so a level can never be re-crossed and a grant can never be paid twice.
func _pay_level_up_grant(event: Dictionary) -> void:
	var from_level := int(event.get("from", 0))
	var to_level := int(event.get("to", 0))
	for level in range(maxi(1, from_level + 1), to_level + 1):
		var amount := econ_curves.level_up_grant(level)
		if amount <= 0:
			continue
		treasury.credit(amount, &"grant", "city_level_%d" % level)
		bus.emit(&"level_up_grant_paid", {"city_level": level, "amount": amount,
				"balance": treasury.balance})


## The O(1) scalars `GoalSystem.STATE_KINDS` reads, once a game-hour.
func goal_state_view() -> Dictionary:
	return {
		"population": float(population.city_population),
		"happiness": happiness.happiness,
		"stability": districts.city_stability,
		"treasury": float(treasury.balance),
	}


## What the city can still SEE of the event kinds — the retroactive-safety input
## to `GoalSystem.bootstrap`, and the one roster walk this system ever does.
##
## It runs once, on the load of a save written before the curriculum existed, and
## it gathers only the keys the curriculum actually asks for
## (`GoalSystem.residue_keys()`), so a curriculum with no `build_archetype` row
## costs no walk at all.
func goal_residue_counts() -> Dictionary:
	var wanted := GoalSystem.residue_keys()
	var out: Dictionary = {}
	for key in wanted:
		out[key] = 0
	if wanted.is_empty():
		return out
	for id in roster_ids():
		var key := "archetype:" + String((buildings[id] as Building).archetype)
		if out.has(key):
			out[key] = int(out[key]) + 1
	for component_id in grid.component_ids():
		var key := "grid:" + String(grid.component(String(component_id)).get("kind", ""))
		if out.has(key):
			out[key] = int(out[key]) + 1
	for node_id in _sorted(water.nodes):
		var key := "water:" + String((water.nodes[node_id] as WaterNode).variant)
		if out.has(key):
			out[key] = int(out[key]) + 1
	if out.has("blocks_owned"):
		out["blocks_owned"] = world.owned_count()
	if out.has("blocks_ready"):
		var ready_count := 0
		for block_id in world.block_ids_sorted():
			if (world.block(block_id) as LandBlock).is_ready():
				ready_count += 1
		out["blocks_ready"] = ready_count
	return out


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


func _serialize_director_links() -> Dictionary:
	var out := {}
	for incident_id in _sorted(_director_links):
		out[str(incident_id)] = int(_director_links[incident_id])
	return out


func _serialize_buildings() -> Array:
	var out: Array = []
	for id in roster_ids():
		out.append((buildings[id] as Building).serialize())
	return out


func _population_inputs() -> Array:
	var out: Array = []
	# Category is a function of archetype, and there are a handful of archetypes
	# against 1,500 buildings — so the catalog is asked (and the archetype
	# converted to a String) once per archetype per settled hour, not once per
	# building.
	var category_by_archetype: Dictionary = {}
	for id in roster_ids():
		var b: Building = buildings[id]
		var found: Variant = category_by_archetype.get(b.archetype)
		if found == null:
			found = catalog.category(String(b.archetype))
			category_by_archetype[b.archetype] = found
		var category: String = found
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
##
## **`min_city_level` is ENFORCED here** (doc 92 pass-1 F-7, ruled Wave 5). It
## was a UI courtesy: `ui/build_controller.gd` drew the lock glyph and refused to
## enter placement mode, but the command underneath said yes, so anything that
## reached `CitySim` directly — a script, a replayed command, a test — could
## found a city on apartments at city level 0. The gate now lives where
## `cmd_upgrade_building`'s has always lived, answers the same `E_CITY_LEVEL`,
## and is checked BEFORE the money so a locked card never quotes a price it
## cannot take. Every scripted strategy in `tools/playtest.gd` already filtered
## on the UI's rule (`Api.buildable`), so the pacing curves do not move — see the
## Wave-5 delivery report for the re-measurement.
func cmd_place_building(archetype: String, origin: Vector2i, variant: String = "") -> Dictionary:
	if not catalog.has(archetype):
		return CommandQueue.fail(&"E_UNKNOWN_ARCHETYPE")
	var block := world.block_of_tile(origin.x, origin.y)
	if block == null or not block.is_owned():
		return CommandQueue.fail(&"E_NOT_OWNED")
	if not block.is_ready():
		return CommandQueue.fail(&"E_NOT_DEVELOPED")
	var required_level := int(catalog.stats(archetype, 1).get("min_city_level", 0))
	if progression.city_level < required_level:
		return CommandQueue.fail(&"E_CITY_LEVEL", {"blockers": [&"E_CITY_LEVEL"],
				"required_level": required_level, "city_level": progression.city_level,
				"archetype": archetype})
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
	var paid := treasury.spend(cost, &"construction")
	if not bool(paid["ok"]):
		# doc 03 §2.10 layer 2 blocks NEW commitments under austerity; a refused
		# spend charges nothing, so the command must refuse too (doc 92 F-7).
		return CommandQueue.fail(_spend_reason(paid),
				{"cost": cost, "balance": treasury.balance})
	var grid_id := _next_building_grid_id()
	var sim_id := "P-%03d" % grid_id
	var b := Building.new(grid_id, StringName(archetype), origin, StringName(variant))
	b.stats = stats
	b.max_level = catalog.max_level_of(archetype)
	b.built_at_minutes = clock.sim_time_minutes()
	world.grid.stamp_building(grid_id, origin, size)
	buildings[sim_id] = b
	_invalidate_roster()
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
	# The top of the ladder is the ARCHETYPE's own top (doc 02 §2.14): five for
	# the civic and utility shells, six for the growth stock. A literal 5 here
	# would refuse the tower tier the whole of doc 92 §24 exists to unlock.
	var top_level: int = catalog.max_level_of(String(b.archetype))
	if b.level >= top_level:
		blockers.append(&"E_MAX_LEVEL")
	if b.condition < Building.MIN_CONDITION_TO_UPGRADE:
		blockers.append(&"E_CONDITION")
	var next_level: int = mini(b.level + 1, top_level)
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
	var paid := treasury.spend(cost, &"construction")
	if not bool(paid["ok"]):
		return CommandQueue.fail(_spend_reason(paid), {"blockers": [_spend_reason(paid)],
				"cost": cost, "balance": treasury.balance})
	b.start_upgrade()
	# **The price of a step is stored on the row it starts FROM.** Doc 02 §2.2:
	# `upgrade_time_hours(L) = 0.65 × build_time(L + 1)`, which is the cost of
	# `L → L+1` — so the row being upgraded FROM is the one to read, and
	# `BuildingCatalog` enforces exactly that shape (every row below the top
	# carries the column; the top row, which prices nothing, must not).
	#
	# This read used to start at `next_stats`, the row upgraded TO, and charged
	# every step in the game the NEXT rung's duration — one rung too slow, all
	# the way up every ladder (report 98 RR-29(h), fixed in RR-38). The one step
	# that was already right is the LAST one: the top row carries no column, so
	# the fallback caught it and it read this same cell. Every other step gets
	# faster, and by its own authored figure: a `house` L1→L2 is 2.5 → 2.0
	# crew-hours, L4→L5 is 7.0 → 5.0, and a `high_rise` L4→L5 is 148 → 87.
	#
	# The fallbacks below are for a hand-edited table only — the catalog rejects
	# a roster that is missing the cell at load — and they keep the read TOTAL
	# rather than crashing a command on a data fault.
	var upgrade_hours := float(b.stats.get("upgrade_time_hours",
			next_stats.get("upgrade_time_hours", 4.0)))
	var job_id := construction.submit(&"upgrade", sim_id,
			upgrade_hours, &"construction_crew",
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
	# A LINE component is a polyline, not a tile, so `kind` routes here into doc
	# 04 §4's own `route_feeder` with the C-41 assist filling the path: `tile` is
	# the far end, `level` is the conductor class, and the source is chosen for
	# the player exactly as the drag tool's snap would. `cmd_route_feeder` is the
	# same command with the path supplied, and every blocker below is its.
	if not _routable_rules(kind).is_empty():
		return _route_line(kind, tile, level, preview)
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
	# Doc 04 §2.9's parallel transformer, quoted: what this placement would take
	# off an overloaded neighbour. Computed against the ladder row rather than
	# against a component, so a preview adds nothing to the graph.
	var relief := grid.building_adoption_plan(tile, int(radii[level - 1]),
			PowerGrid.CAPACITY[StringName(kind)][level - 1], 1.0, 0.0, "",
			_last_demands, _building_origins(), _ambient_c()) if kind == "transformer" \
			else {"adopted": [], "moved_kw": 0.0}
	quote["relieves"] = (relief["adopted"] as Array).size()
	quote["relieved_kw"] = float(relief["moved_kw"])
	if not blockers.is_empty():
		return CommandQueue.fail(blockers[0], quote)
	if preview:
		return CommandQueue.ok(quote)

	var paid := treasury.spend(cost, &"construction")
	if not bool(paid["ok"]):
		quote["blockers"] = [_spend_reason(paid)]
		return CommandQueue.fail(_spend_reason(paid), quote)
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
	# …and the ALREADY-served buildings a cooking neighbour should hand over
	# (doc 04 §2.9's parallel transformer). Without this, §2.1's attachment rule
	# — only ever evaluated for a building with NO transformer — meant a second
	# transformer beside an overloaded one adopted nothing, and the one purchase
	# doc 04 sells as the answer to a hotspot bought the player nothing. Runs
	# AFTER `_reattach_unserved` so an unserved building is attached by the rule
	# that owns it, and a transfer never competes with a first attachment.
	var relieved: Dictionary = grid.adopt_buildings(component_id, _last_demands,
			_building_origins(), _ambient_c())
	bus.emit(&"grid_component_placed", {"component": component_id, "kind": kind,
			"level": level, "tile": [tile.x, tile.y], "feeder": String(tap["feeder"]),
			"lateral_tiles": lateral.size(), "cost": cost, "adopted": adopted,
			"relieved": (relieved["adopted"] as Array).duplicate(),
			"relieved_kw": float(relieved["moved_kw"])})
	stats_add(&"grid_components_placed")
	quote["component"] = component_id
	quote["adopted"] = adopted
	quote["relieves"] = (relieved["adopted"] as Array).size()
	quote["relieved_kw"] = float(relieved["moved_kw"])
	return CommandQueue.ok(quote)


## `{sim_id: origin tile}` for every live building — doc 02's geometry, handed
## to the grid for one adoption decision rather than mirrored inside it.
func _building_origins() -> Dictionary:
	var out := {}
	for sim_id in buildings:
		out[sim_id] = (buildings[sim_id] as Building).origin
	return out


## Player component ids are `<PREFIX>-NNN`, numbered above every id the grid
## already carries so a reload can never collide with an authored node.
func _next_component_id(kind: String) -> String:
	var prefix := "P" + String(kind).substr(0, 1).to_upper()
	var highest := 0
	for id in grid.component_ids():
		if id.begins_with(prefix + "-"):
			highest = maxi(highest, id.substr(prefix.length() + 1).to_int())
	return "%s-%03d" % [prefix, highest + 1]


# --------------------------------------------- doc 04 §4 `route_feeder`

## Route a feeder (doc 04 §4's `route_feeder`, §2.1's tile polyline). The verb
## doc 92 §17.3 named as the late-game's answer: the whole city ran through the
## two class-1 feeders doc 09 §2.9.5 authored — 1,200 kW each, crossed at ~410
## buildings — and no command could add a third.
##
## Checks run in this order; the FIRST blocker is the reason code and the full
## list rides in `payload.blockers` (`preview = true` quotes without charging):
##
##   1 E_UNKNOWN_COMPONENT   kind is not in `routable`
##   2 E_CLASS_UNAVAILABLE   conductor class outside that kind's roster
##   3 E_NO_TILES            fewer than two tiles
##   4 E_OUT_OF_BOUNDS       any tile off the 112×112 world
##   5 E_DISCONTINUOUS       the path is not a walkable Chebyshev polyline
##   6 E_NOT_DEVELOPED       any tile on land that is not owned and READY
##   7 E_NOT_CONNECTED       the run does not START on the network (§2.1)
##   8 E_NO_SLOT             the source substation has no free feeder slot
##                           (§2.2's 2/3/4/6/8 ladder) — buy or upgrade one
##   9 E_FUNDS / E_AUSTERITY
##
## Price is doc 03 §2.13(b)'s `feeder.cost_per_tile_overhead` for that class —
## $110 class 1, $210 class 2 — charged on **every tile of the run**, which is
## exactly the `line_km` doc 03 then bills `E_grid` on (report 98 C-12).
## `M_build` applies (doc 03 §2.13: difficulty at spend time).
##
## On success the new feeder ADOPTS the transformers §2.9's transfer rule says
## it should (see `PowerGrid.adopt_transformers`) — which is what makes this
## relief for the city that already exists rather than headroom for the one that
## does not yet.
func cmd_route_feeder(tiles: Array, conductor_class: int = 2,
		preview: bool = false) -> Dictionary:
	var rules := _routable_rules("feeder")
	if rules.is_empty():
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT", {"blockers": [&"E_UNKNOWN_COMPONENT"]})
	var classes: Array = []
	for entry in (rules.get("conductor_classes", []) as Array):
		classes.append(int(entry))
	if not classes.has(conductor_class):
		return CommandQueue.fail(&"E_CLASS_UNAVAILABLE",
				{"blockers": [&"E_CLASS_UNAVAILABLE"], "conductor_classes": classes})
	var path := _tile_list(tiles)
	if path.size() < 2:
		return CommandQueue.fail(&"E_NO_TILES", {"blockers": [&"E_NO_TILES"]})

	var blockers: Array = []
	for entry in path:
		var t: Vector2i = entry
		if not TileGrid.in_bounds(t.x, t.y):
			blockers.append(&"E_OUT_OF_BOUNDS")
			break
	if blockers.is_empty() and PowerGrid.route_break_index(path) >= 0:
		blockers.append(&"E_DISCONTINUOUS")
	if blockers.is_empty() and bool(rules.get("requires_block_owned", true)):
		for entry in path:
			var t: Vector2i = entry
			var block := world.block_of_tile(t.x, t.y)
			if block == null or not block.is_owned() \
					or (bool(rules.get("requires_block_ready", true)) and not block.is_ready()):
				blockers.append(&"E_NOT_DEVELOPED")
				break
	# §2.1 source connectivity: the run starts on the network — on a trunk, or at
	# a substation's fence line. Branching a trunk roots the new feeder on THAT
	# trunk's substation, because §2.1's tree is two deep and a feeder's parent is
	# always a substation.
	var source := _feeder_source(path[0], int(rules.get("source_tap_radius_tiles", 1)))
	var slots := {"total": 0, "used": 0, "free": 0}
	if source.is_empty():
		blockers.append(&"E_NOT_CONNECTED")
	else:
		slots = grid.feeder_slots(String(source["substation"]))
		if int(slots["free"]) <= 0:
			blockers.append(&"E_NO_SLOT")
	# EVERY tile of the new run is billed, including the one it starts on. Unlike
	# `cmd_place_grid_component`'s lateral — which EXTENDS an existing feeder's
	# route and so only adds the tiles past the tap — this is a new component
	# with a route of its own, and `grid_inventory()` publishes `line_km` for all
	# of it. Billing `size() - 1` would have doc 03 charging `E_grid` forever on a
	# tile of copper the player never bought (report 98 C-12).
	var billed: int = path.size()
	var cost := CostCurves.round_half_up(float(billed)
			* float(econ_curves.grid_line_cost_per_tile("feeder", conductor_class, false))
			* float(treasury.difficulty().get("M_build", 1.0)))
	if treasury.balance < cost:
		blockers.append(&"E_FUNDS")

	var adoption_radius := int(_placeable_rules("transformer").get("feeder_tap_radius_tiles", 0))
	var quote := {"blockers": blockers, "cost": cost, "tiles": path.size(),
			"billed_tiles": billed, "conductor_class": conductor_class,
			"capacity_kw": PowerGrid.FEEDER_CAPACITY[conductor_class - 1],
			"source": String(source.get("kind", "")),
			"substation": String(source.get("substation", "")),
			"feeder_slots_free": int(slots["free"]),
			"line_km": billed * 0.008}
	if not blockers.is_empty():
		return CommandQueue.fail(blockers[0], quote)
	if preview:
		# The quote names what the run would pick up, and computes it against a
		# route rather than against a component, so nothing is added and nothing
		# is dirtied: a preview that could not say "this takes 480 kW off
		# F_SOUTH" would be quoting a price for an effect the player cannot see.
		var dry: Dictionary = grid.adoption_plan(_route_payload(path),
				PowerGrid.FEEDER_CAPACITY[conductor_class - 1], 1.0, 0.0, "",
				adoption_radius, _ambient_c())
		quote["adopts"] = (dry["adopted"] as Array).size()
		quote["adopted_kw"] = float(dry["moved_kw"])
		return CommandQueue.ok(quote)

	var paid := treasury.spend(cost, &"construction", "feeder")
	if not bool(paid["ok"]):
		quote["blockers"] = [_spend_reason(paid)]
		return CommandQueue.fail(_spend_reason(paid), quote)
	var component_id := _next_component_id("feeder")
	grid.add_component(component_id, &"feeder", {
		"conductor_class": conductor_class, "parent": String(source["substation"]),
		"route": _route_payload(path), "player_placed": true,
		# §2.7.4: an overhead run is fully wind-exposed, which is what doc 06's
		# storm generator reads. Undergrounding is deferred (doc 04 §6).
		"weather_exposure": 1.0,
	})
	var adopted: Dictionary = grid.adopt_transformers(component_id, adoption_radius, _ambient_c())
	bus.emit(&"grid_feeder_routed", {"component": component_id,
			"conductor_class": conductor_class, "substation": String(source["substation"]),
			"source": String(source["kind"]), "tiles": path.size(), "billed_tiles": billed,
			"cost": cost, "adopted": (adopted["adopted"] as Array).duplicate(),
			"adopted_kw": float(adopted["moved_kw"])})
	stats_add(&"grid_feeders_routed")
	quote["component"] = component_id
	quote["adopts"] = (adopted["adopted"] as Array).size()
	quote["adopted_kw"] = float(adopted["moved_kw"])
	return CommandQueue.ok(quote)


## `cmd_place_grid_component`'s one-tap path for a line component: pick the
## source the drag tool would have snapped to, fill the polyline with the C-41
## assist, and hand the result to the real verb. The source is the substation
## with a FREE SLOT nearest the far end (id tie-break) — a substation that
## cannot root another feeder is not a source at all, so the one-tap path
## answers `E_NO_SLOT` only when NO substation in the city has room.
func _route_line(kind: String, tile: Vector2i, conductor_class: int,
		preview: bool) -> Dictionary:
	if kind != "feeder":
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT", {"blockers": [&"E_UNKNOWN_COMPONENT"]})
	var start := _best_feeder_source_for(tile)
	if start.x < 0:
		# A city with substations but no room in any of them is the §2.2 slot
		# ladder biting, not a disconnected map — say which, because the two
		# have different prices ($15,000 for a new substation, an upgrade job
		# for a bigger one) and only one of them is a mistake.
		var blocked: StringName = &"E_NOT_CONNECTED"
		for sim_id in roster_ids():
			if grid.has_component(String(sim_id)) \
					and String(grid.component(String(sim_id))["kind"]) == "substation":
				blocked = &"E_NO_SLOT"
				break
		return CommandQueue.fail(blocked, {"blockers": [blocked]})
	return cmd_route_feeder(suggest_feeder_route(start, tile), conductor_class, preview)


## Doc 04 §4's routing assist (report 98 C-41), and the reason the one-tap path
## is usable at all: the shortest run of OWNED, DEVELOPED tiles from `from` to
## `to`, both ends inclusive.
##
## A straight Chebyshev line between two owned blocks routinely crosses a block
## the city does not own — measured, that was the whole of seed 4242's late-game
## failure, where every routing attempt answered `E_NOT_DEVELOPED`, burnt the
## rule's cooldown and never escalated to the substation the city actually
## needed. Breadth-first over the tile grid in a fixed neighbour order, so the
## path is the same on every run and is the CHEAPEST legal one (doc 03 §2.13(b)
## prices a feeder per tile, so shortest is cheapest).
##
## Falls back to the straight line when no legal run exists, so the command
## still returns the honest blocker with a path to show rather than nothing.
## The road-PREFERRING form C-41 names (`suggest_route_along_roads`) is a
## weighting on top of this and is not shipped; nothing here depends on it.
const FEEDER_ROUTE_NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
]


func suggest_feeder_route(from: Vector2i, to: Vector2i) -> Array:
	var straight := PowerGrid.route_between(from, to)
	if not TileGrid.in_bounds(from.x, from.y) or not TileGrid.in_bounds(to.x, to.y):
		return straight
	var size := TileGrid.SIZE
	var previous := PackedInt32Array()
	previous.resize(size * size)
	previous.fill(-1)
	var start := from.y * size + from.x
	var goal := to.y * size + to.x
	previous[start] = start
	var queue := PackedInt32Array([start])
	var head := 0
	while head < queue.size():
		var current := queue[head]
		head += 1
		if current == goal:
			break
		var here := Vector2i(current % size, current / size)
		for step in FEEDER_ROUTE_NEIGHBOURS:
			var next := here + step
			if not TileGrid.in_bounds(next.x, next.y):
				continue
			var index := next.y * size + next.x
			if previous[index] >= 0:
				continue
			if not _feeder_route_tile_legal(next):
				continue
			previous[index] = current
			queue.append(index)
	if previous[goal] < 0:
		return straight
	var reversed_path: Array = []
	var cursor := goal
	while cursor != start:
		reversed_path.append(Vector2i(cursor % size, cursor / size))
		cursor = previous[cursor]
	reversed_path.append(from)
	reversed_path.reverse()
	return reversed_path


## `cmd_route_feeder`'s own §2.1 land rule, so the assist never suggests a run
## the verb will refuse.
func _feeder_route_tile_legal(tile: Vector2i) -> bool:
	var rules := _routable_rules("feeder")
	if not bool(rules.get("requires_block_owned", true)):
		return true
	var block := world.block_of_tile(tile.x, tile.y)
	if block == null or not block.is_owned():
		return false
	return not bool(rules.get("requires_block_ready", true)) or block.is_ready()


## The terminal tile of the substation with a free feeder slot nearest `target`.
## Chebyshev on the shell's own footprint (report 98 C-30: the substation IS the
## building), returning the footprint-adjacent tile on the target's side — which
## is exactly where doc 09 §2.9.5 puts SUB-A's terminal.
func _best_feeder_source_for(target: Vector2i) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_key := [999999, ""]
	for sim_id in roster_ids():
		if not grid.has_component(String(sim_id)):
			continue
		if String(grid.component(String(sim_id))["kind"]) != "substation":
			continue
		if int(grid.feeder_slots(String(sim_id))["free"]) <= 0:
			continue
		var b: Building = buildings[sim_id]
		var size: Vector2i = _building_records.get(sim_id, {}).get("footprint", Vector2i.ONE)
		# The corner of the pad facing the target. Deliberately the pad tile
		# itself and not one step out: a transformer standing right against the
		# fence would otherwise make the suggested run a single tile, which is
		# not a polyline and which `cmd_route_feeder` correctly refuses.
		var terminal := Vector2i(clampi(target.x, b.origin.x, b.origin.x + size.x - 1),
				clampi(target.y, b.origin.y, b.origin.y + size.y - 1))
		var distance: int = maxi(absi(target.x - terminal.x), absi(target.y - terminal.y))
		var key := [distance, String(sim_id)]
		if key < best_key:
			best_key = key
			best = terminal
	return best


## §2.1 source connectivity, resolved: `{kind, substation, feeder}` for a run
## starting at `tile`, or {} when that tile touches no network.
##
## The tile can touch several sources at once — doc 09 §2.9.5's own SUB-A
## terminal is both the substation's fence line AND `F_NORTH`'s first route
## tile — and they do not all have room. So every candidate is collected and the
## **first with a free feeder slot wins**, pad before trunk (the pad is what the
## assist aimed at) and trunks in sorted id order. Picking blind here was worth
## measuring: preferring the trunk unconditionally rooted every attempted run on
## whichever substation happened to own the copper underfoot, and on seed 4242
## that answered `E_NO_SLOT` sixteen times while a player substation two tiles
## away sat with both slots empty.
func _feeder_source(tile: Vector2i, pad_radius: int) -> Dictionary:
	var candidates: Array = []
	for sim_id in roster_ids():
		if not grid.has_component(String(sim_id)):
			continue
		if String(grid.component(String(sim_id))["kind"]) != "substation":
			continue
		var b: Building = buildings[sim_id]
		var size: Vector2i = _building_records.get(sim_id, {}).get("footprint", Vector2i.ONE)
		var dx: int = maxi(b.origin.x - tile.x, tile.x - (b.origin.x + size.x - 1))
		var dy: int = maxi(b.origin.y - tile.y, tile.y - (b.origin.y + size.y - 1))
		if maxi(maxi(dx, 0), maxi(dy, 0)) <= pad_radius:
			candidates.append({"kind": "substation", "feeder": "", "substation": String(sim_id)})
	for feeder_id in grid.feeders_at_tile(tile):
		var parent := String(grid.component(String(feeder_id))["parent"])
		if parent != "":
			candidates.append({"kind": "trunk", "feeder": String(feeder_id),
					"substation": parent})
	for candidate in candidates:
		if int(grid.feeder_slots(String(candidate["substation"]))["free"]) > 0:
			return candidate
	return candidates[0] if not candidates.is_empty() else {}


## Routes persist as [x, z] pairs (the JSON shape `PowerGrid.route_tile` reads).
static func _route_payload(path: Array) -> Array:
	var out: Array = []
	for entry in path:
		var t: Vector2i = entry
		out.append([t.x, t.y])
	return out


## Doc 07's ambient, as the grid tick reads it — `cap_eff` derates with it, so an
## adoption decision taken at 39 °C must use 39 °C.
func _ambient_c() -> float:
	return float(weather.env_for_grid().get("t_ambient_c", 25.0))


# ------------------------------------ doc 04 §2.1 grid nodes that are BUILDINGS

## A `substation` / `power_facility` shell just finished, so the grid node it IS
## joins the graph (report 98 C-30: those two are buildings, and doc 09 §2.9.5
## already authors the shell and the node under ONE id).
##
## Doc 92 §17.3 fix 2, and it is the same class of bug as pass-2 F-3's frozen
## fleet: `cmd_place_building` sold a $15,000 substation and a $60,000 plant that
## added no capacity and no generation at all. The seam is `_commission_water_nodes`'
## — the building takes the construction time, the component is what carries
## power, and a node that carried power while its shell was a hole in the ground
## would be free capacity.
##
## Called for an UPGRADE too, where the component is re-rated rather than added:
## doc 02's L1→L2 job on a substation is what buys 6,000 → 14,000 kW and the
## third feeder slot doc 04 §2.2 gives it.
func _commission_grid_node(sim_id: String, b: Building) -> void:
	var kind := _node_shell_kind(String(b.archetype))
	if kind == "":
		return
	var level := maxi(1, b.level)
	if grid.has_component(sim_id):
		if grid.set_level(sim_id, level):
			bus.emit(&"grid_node_rerated", {"component": sim_id, "kind": kind,
					"level": level,
					"capacity_kw": float(grid.component(sim_id)["capacity_kw"])})
		return
	grid.add_component(sim_id, StringName(kind), {"level": level, "tile": b.origin,
			"player_placed": true})
	bus.emit(&"grid_node_commissioned", {"component": sim_id, "kind": kind,
			"level": level, "tile": [b.origin.x, b.origin.y],
			"capacity_kw": float(grid.component(sim_id)["capacity_kw"])})


## The demolition half. A substation takes the feeders it roots with it (doc 04
## §2.1: a feeder belongs to exactly one substation, and nothing in the MVP
## re-roots one), and their transformers orphan — dark until new copper adopts
## them. Returns the ids removed, sorted.
func _retire_grid_node(sim_id: String) -> Array:
	if not grid.has_component(sim_id):
		return []
	var removed := grid.remove_component(sim_id)
	if removed.is_empty():
		return removed
	bus.emit(&"grid_node_retired", {"component": sim_id, "removed": removed.duplicate()})
	return removed


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


# ------------------------------------------- doc 05 §6 water-component verbs

## Node id suffixes, so a placed site reads like the authored ones
## (`WTR-1-PMP`): doc 09 §2.9.6's convention, applied to player sites.
const WATER_NODE_SUFFIX := {
	"source": "SRC", "treatment": "TRT", "pump": "PMP", "tank": "TNK",
	"booster": "BST",
}


## Place a doc-05 water component (§6's MVP roster: `source` river, `treatment`,
## `pump`, `tank`). One command builds three things that always go together and
## have never been separable in this project:
##
##   1. doc 02's `water_facility` **shell** — the building that decays, is
##      maintained, is billed and is the thing doc 04 energises;
##   2. doc 05's **node** — the intake / skid / pump / tank itself, hosted on
##      that shell's `power_ref`, exactly as `WTR-1` hosts three of them;
##   3. a `service` **lateral main** from the nearest live main to the site,
##      because §2.2's connectivity is physical: a component that shares no tile
##      with the network is its own dead pressure zone.
##
## Checks run in this order; the FIRST blocker is the reason code and the full
## list rides in `payload.blockers` (`preview = true` quotes without charging):
##
##   1 E_UNKNOWN_COMPONENT  kind is not in `data/water.json` `placeable`
##   2 E_VARIANT_LOCKED     the variant is behind a `feature_flags` gate
##   3 E_LEVEL_UNAVAILABLE  level outside that kind's `placeable_levels`
##   4 E_OUT_OF_BOUNDS      tile off the 112×112 world
##   5 E_NOT_OWNED          the tile's land block is not owned
##   6 E_NOT_DEVELOPED      the block has not reached READY
##   7 E_CITY_LEVEL         below the shell's `min_city_level` at this level
##   8 E_FOOTPRINT          the doc-05 footprint does not fit
##   9 E_NO_WATER           a river intake with no water tile touching it
##  10 E_NO_MAIN            no live main within `main_tap_radius_tiles`
##  11 E_UNSERVED           no transformer reaches the site (doc 04 §2.1)
##  12 E_FUNDS / E_AUSTERITY
##
## Price is doc 03 §8 `water`: the component at its level, plus the lateral it
## takes to reach the tap, per tile at the `service` main price. Nothing is
## charged on a preview or on any failure.
##
## The node is born `offline_manual` and goes live when the shell's construction
## job completes — a pump that pumps before it is built would be a supply the
## player never paid the build time for.
func cmd_place_water_component(kind: String, tile: Vector2i, level: int = 1,
		preview: bool = false) -> Dictionary:
	var rules := water.data.placeable_rules(kind)
	if rules.is_empty():
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT",
				{"blockers": [&"E_UNKNOWN_COMPONENT"]})
	var variant := StringName(kind)
	var subtype := String(rules.get("subtype", ""))
	if _water_variant_locked(kind, subtype):
		return CommandQueue.fail(&"E_VARIANT_LOCKED", {"blockers": [&"E_VARIANT_LOCKED"]})
	var levels: Array = []
	for entry in (rules.get("placeable_levels", []) as Array):
		levels.append(int(entry))
	if not levels.has(level):
		return CommandQueue.fail(&"E_LEVEL_UNAVAILABLE",
				{"blockers": [&"E_LEVEL_UNAVAILABLE"], "placeable_levels": levels})
	if not TileGrid.in_bounds(tile.x, tile.y):
		return CommandQueue.fail(&"E_OUT_OF_BOUNDS", {"blockers": [&"E_OUT_OF_BOUNDS"]})

	var blockers: Array = []
	var block := world.block_of_tile(tile.x, tile.y)
	if bool(water.data.placement_value("requires_block_owned", true)) \
			and (block == null or not block.is_owned()):
		blockers.append(&"E_NOT_OWNED")
	elif bool(water.data.placement_value("requires_block_ready", true)) \
			and not block.is_ready():
		blockers.append(&"E_NOT_DEVELOPED")
	var shell_stats: Dictionary = catalog.stats(WATER_SHELL_ARCHETYPE, level)
	if progression.city_level < int(shell_stats.get("min_city_level", 0)):
		blockers.append(&"E_CITY_LEVEL")
	var size := water.data.footprint_of(variant, level, subtype)
	if not world.grid.can_place(tile, size):
		blockers.append(&"E_FOOTPRINT")
	if bool(rules.get("requires_water_adjacent", false)) and not _touches_water(tile, size):
		blockers.append(&"E_NO_WATER")
	var radius := int(water.data.placement_value("main_tap_radius_tiles", 8))
	var tap := water.nearest_main_tile(tile, radius)
	var lateral: Array = []
	var tier := String(water.data.placement_value("lateral_tier", "service"))
	var m_build := float(treasury.difficulty().get("M_build", 1.0))
	var cost := econ_curves.water_component_build_cost(
			water.data.variant_cost_ratio(variant, subtype), level, m_build)
	if tap.is_empty():
		blockers.append(&"E_NO_MAIN")
	else:
		lateral = WaterSystem.lateral_tiles(tap["tap_tile"], tile)
		cost += lateral.size() * econ_curves.water_main_cost_per_tile(tier, m_build)
	if not grid.would_serve(tile):
		blockers.append(&"E_UNSERVED")
	if treasury.balance < cost:
		blockers.append(&"E_FUNDS")

	var quote := {"blockers": blockers, "cost": cost, "level": level,
			"footprint": [size.x, size.y], "lateral_tiles": lateral.size(),
			"main": String(tap.get("edge", "")), "tap_distance": int(tap.get("distance", -1)),
			"kw_required": water.data.kw_required(variant, level, subtype)}
	if not blockers.is_empty():
		return CommandQueue.fail(blockers[0], quote)
	if preview:
		return CommandQueue.ok(quote)

	var paid := treasury.spend(cost, &"construction")
	if not bool(paid["ok"]):
		quote["blockers"] = [_spend_reason(paid)]
		return CommandQueue.fail(_spend_reason(paid), quote)

	# 1. The doc 02 shell.
	var grid_id := _next_building_grid_id()
	var sim_id := "P-%03d" % grid_id
	var b := Building.new(grid_id, StringName(WATER_SHELL_ARCHETYPE), tile, variant)
	b.stats = shell_stats
	b.max_level = catalog.max_level_of(WATER_SHELL_ARCHETYPE)
	b.level = level
	b.built_at_minutes = clock.sim_time_minutes()
	world.grid.stamp_building(grid_id, tile, size)
	buildings[sim_id] = b
	_invalidate_roster()
	_building_records[sim_id] = {"id": sim_id, "grid_id": grid_id,
			"type": WATER_SHELL_ARCHETYPE, "block": block.id, "footprint": size,
			"origin_global": tile}
	_block_dark_weights[sim_id] = int(shell_stats.get("population", 0)) \
			+ int(shell_stats.get("jobs", 0))
	var job_id := construction.submit(&"build", sim_id,
			float(shell_stats.get("build_time_hours", 12.0)), &"construction_crew",
			{"sim_id": sim_id, "cost": cost})
	construction.assign_crew(job_id, "YARD-CREW-1")
	b.start_construction()
	# A water site is doc 04 §2.4 CRITICAL, as the authored ones are.
	grid.attach_building(sim_id, tile, &"CRITICAL", block.id)
	water.attach_building(sim_id, tile, WATER_SHELL_ARCHETYPE)

	# 2. The doc 05 node, held offline until the shell finishes.
	var node_id := "%s-%s" % [sim_id, String(WATER_NODE_SUFFIX.get(kind, "NOD"))]
	water.cmd_place_water_node(node_id, kind, tile, {
		"level": level, "subtype": subtype, "power_ref": sim_id,
		"state": "offline_manual",
	})
	# 3. The lateral that joins it to the network (§2.2: connectivity is tiles).
	# Named off the shell so `_retire_water_nodes` can find it again.
	var main_id := ""
	if not lateral.is_empty():
		main_id = "%s-LAT" % sim_id
		var path: Array = [tap["tap_tile"]]
		path.append_array(lateral)
		water.cmd_place_main(main_id, path, tier)
	water.rebuild_zones()
	_refresh_water_kw()
	_refresh_road_density()
	bus.emit(&"water_component_placed", {"sim_id": sim_id, "building": grid_id,
			"node": node_id, "kind": kind, "level": level, "cost": cost,
			"tile": [tile.x, tile.y], "main": main_id,
			"lateral_tiles": lateral.size()})
	stats_add(&"water_components_placed")
	quote["sim_id"] = sim_id
	quote["node"] = node_id
	quote["job_id"] = job_id
	quote["main"] = main_id
	return CommandQueue.ok(quote)


## Doc 02's shell for every doc-05 variant (`data/buildings.json` names doc 05's
## component table as the source of its per-variant footprint).
const WATER_SHELL_ARCHETYPE := "water_facility"


## Doc 05 §6's deferred roster, read off `feature_flags` rather than re-listed:
## `booster` and the `well` source subtype are Phase-2, data present and gated.
func _water_variant_locked(kind: String, subtype: String) -> bool:
	if kind == "booster":
		return not water.data.flag("boosters_enabled")
	if kind == "source" and subtype == "well":
		return not water.data.flag("source_well_enabled")
	return false


## Doc 05 §2.1: a river intake has to touch the river. Orthogonal adjacency to
## the footprint, against doc 09's `FLAG_WATER`.
func _touches_water(origin: Vector2i, size: Vector2i) -> bool:
	for z in range(origin.y - 1, origin.y + size.y + 1):
		for x in range(origin.x - 1, origin.x + size.x + 1):
			var inside_x := x >= origin.x and x < origin.x + size.x
			var inside_z := z >= origin.y and z < origin.y + size.y
			if inside_x and inside_z:
				continue
			if (inside_x or inside_z) and TileGrid.in_bounds(x, z) \
					and world.grid.has_flag(x, z, TileGrid.FLAG_WATER):
				return true
	return false


## Lay a length of main by hand (doc 05 §6's `service` / `trunk` tiers). Order:
##
##   1 E_UNKNOWN_TIER    not a tier in `data/water.json` `mains`
##   2 E_TIER_LOCKED     `arterial`, which is behind `levels_4_5_enabled`
##   3 E_NO_TILES        fewer than two tiles
##   4 E_OUT_OF_BOUNDS   any tile off the world
##   5 E_NOT_DEVELOPED   any tile on land that is not owned and READY
##   6 E_MAIN_OVERLAP    a tile PAST the first already carries another main
##   7 E_NOT_CONNECTED   the run does not START on a main or a facility node
##   8 E_FUNDS / E_AUSTERITY
##
## Price is doc 03 §8 `water.main_build_cost_per_tile[tier]` × tiles laid.
func cmd_place_water_main(tiles: Array, tier: String = "service",
		preview: bool = false) -> Dictionary:
	if not water.data.mains.has(tier):
		return CommandQueue.fail(&"E_UNKNOWN_TIER", {"blockers": [&"E_UNKNOWN_TIER"]})
	if tier == "arterial" and not water.data.flag("levels_4_5_enabled"):
		return CommandQueue.fail(&"E_TIER_LOCKED", {"blockers": [&"E_TIER_LOCKED"]})
	var path := _tile_list(tiles)
	if path.size() < 2:
		return CommandQueue.fail(&"E_NO_TILES", {"blockers": [&"E_NO_TILES"]})
	var blockers: Array = []
	for entry in path:
		var t: Vector2i = entry
		if not TileGrid.in_bounds(t.x, t.y):
			blockers.append(&"E_OUT_OF_BOUNDS")
			break
		var block := world.block_of_tile(t.x, t.y)
		if block == null or not block.is_owned() or not block.is_ready():
			blockers.append(&"E_NOT_DEVELOPED")
			break
	# The FIRST tile is the tap — it is allowed, and expected, to sit on an
	# existing main. Every tile after it must be clear: two mains sharing a run
	# of tiles is one main with two ids as far as §2.2's union-find is concerned,
	# and doc 03 would have billed the player for both.
	var clash := water.first_occupied_main_tile(path.slice(1))
	if clash.x >= 0:
		blockers.append(&"E_MAIN_OVERLAP")
	# §2.2 connectivity is physical: the run has to START on the network, at a
	# main tile or at a facility's own terminal tile.
	var connected: bool = not water.nearest_main_tile(path[0], 0).is_empty() \
			or water.node_at_tile(path[0]) != ""
	if not connected:
		blockers.append(&"E_NOT_CONNECTED")
	var cost := path.size() * econ_curves.water_main_cost_per_tile(tier,
			float(treasury.difficulty().get("M_build", 1.0)))
	if treasury.balance < cost:
		blockers.append(&"E_FUNDS")
	var quote := {"blockers": blockers, "cost": cost, "tiles": path.size(),
			"tier": tier, "capacity_m3h": water.data.main_capacity(tier)}
	if not blockers.is_empty():
		return CommandQueue.fail(blockers[0], quote)
	if preview:
		return CommandQueue.ok(quote)

	var paid := treasury.spend(cost, &"construction", "water main")
	if not bool(paid["ok"]):
		quote["blockers"] = [_spend_reason(paid)]
		return CommandQueue.fail(_spend_reason(paid), quote)
	var main_id := water.next_main_id("PMN")
	var placed: Dictionary = water.cmd_place_main(main_id, path, tier)
	if not bool(placed["ok"]):
		treasury.credit(cost, &"construction", "water main refused")
		quote["blockers"] = [placed["reason_code"]]
		return CommandQueue.fail(StringName(String(placed["reason_code"])), quote)
	water.rebuild_zones()
	bus.emit(&"water_main_placed", {"main": main_id, "tier": tier,
			"tiles": path.size(), "cost": cost})
	stats_add(&"water_mains_placed")
	quote["main"] = main_id
	return CommandQueue.ok(quote)


## Upgrade a placed or authored water component one level (doc 05 §6). Order:
##
##   1 E_UNKNOWN_NODE     no such node id
##   2 E_NOT_UPGRADEABLE  a junction has no level
##   3 E_MAX_LEVEL        past level 5, or past 3 while `levels_4_5_enabled`
##                        is off (doc 05's own gate)
##   4 E_LEVEL_UNAVAILABLE the roster does not offer the next level
##   5 E_POWER_HEADROOM   doc 04 cannot carry the extra kW (×1.15, as doc 02's
##                        own upgrade check does)
##   6 E_FUNDS / E_AUSTERITY
##
## Price is doc 03 §2.3's `upgrade_cost()` on the `water_plant` anchor, scaled by
## doc 05's variant ratio — the same curve every building upgrade rides.
func cmd_upgrade_water_component(node_id: String, preview: bool = false) -> Dictionary:
	var node: WaterNode = water.nodes.get(node_id)
	if node == null:
		return CommandQueue.fail(&"E_UNKNOWN_NODE", {"blockers": [&"E_UNKNOWN_NODE"]})
	if node.variant == &"junction":
		return CommandQueue.fail(&"E_NOT_UPGRADEABLE", {"blockers": [&"E_NOT_UPGRADEABLE"]})
	var next_level := node.level + 1
	var blockers: Array = []
	if next_level > 5 or (next_level >= 4 and not water.data.flag("levels_4_5_enabled")):
		blockers.append(&"E_MAX_LEVEL")
	var rules := water.data.placeable_rules(String(node.variant))
	var levels: Array = []
	for entry in (rules.get("placeable_levels", []) as Array):
		levels.append(int(entry))
	if not levels.is_empty() and not levels.has(next_level) and blockers.is_empty():
		blockers.append(&"E_LEVEL_UNAVAILABLE")
	var delta_kw := water.data.kw_required(node.variant, next_level, node.subtype) \
			- water.data.kw_required(node.variant, node.level, node.subtype)
	var headroom := grid.can_upgrade_power(node.power_ref, delta_kw * 1.15)
	if not bool(headroom["ok"]):
		blockers.append(&"E_POWER_HEADROOM")
	var cost := econ_curves.water_component_upgrade_cost(
			water.data.variant_cost_ratio(node.variant, node.subtype), node.level,
			float(treasury.difficulty().get("M_build", 1.0)))
	if treasury.balance < cost:
		blockers.append(&"E_FUNDS")
	var quote := {"blockers": blockers, "cost": cost, "node": node_id,
			"to_level": next_level, "delta_kw": delta_kw,
			"deficit_kw": headroom.get("deficit_kw", 0.0)}
	if not blockers.is_empty():
		return CommandQueue.fail(blockers[0], quote)
	if preview:
		return CommandQueue.ok(quote)

	var paid := treasury.spend(cost, &"construction")
	if not bool(paid["ok"]):
		quote["blockers"] = [_spend_reason(paid)]
		return CommandQueue.fail(_spend_reason(paid), quote)
	var upgraded: Dictionary = water.cmd_upgrade_water_node(node_id)
	if not bool(upgraded["ok"]):
		treasury.credit(cost, &"construction", "water upgrade refused")
		quote["blockers"] = [upgraded["reason_code"]]
		return CommandQueue.fail(StringName(String(upgraded["reason_code"])), quote)
	water.rebuild_zones()
	_refresh_water_kw()
	bus.emit(&"water_component_upgraded", {"node": node_id, "level": next_level,
			"cost": cost, "kw_required": upgraded["payload"]["kw_required"]})
	stats_add(&"water_components_upgraded")
	return CommandQueue.ok(quote)


## §2.12's tactical pair, surfaced verbatim: isolating a main trades a
## neighbourhood's taps for the fire's hydrants. Doc 03 prices neither — the
## crew time is doc 05's work content, and no capital changes hands.
func cmd_isolate_water_main(edge_id: String) -> Dictionary:
	var result: Dictionary = water.cmd_isolate_main(edge_id)
	if bool(result["ok"]):
		water.rebuild_zones()
	return result


func cmd_restore_water_main(edge_id: String) -> Dictionary:
	var result: Dictionary = water.cmd_restore_main(edge_id)
	if bool(result["ok"]):
		water.rebuild_zones()
	return result


# ------------------------------------------------ doc 10 §2.13 road placement

## Doc 10 §2.3's class names, as `data/economy.json`'s `roads` block keys them.
const ROAD_CLASS_NAMES := {
	TileGrid.ROAD_STREET: "STREET", TileGrid.ROAD_AVENUE: "AVENUE",
}
## Doc 10 §2.13 rule 5: a road job goes to doc 02's queue, and this is the same
## MVP crew binding every other job in the project gets until doc 06 owns crews.
const ROAD_JOB_CREW := "YARD-CREW-1"


## Build road tiles (doc 10 §2.13). Doc 10 owns the geometry and the reason
## codes; doc 03 owns every dollar; this coordinator joins them and is the only
## place a road command can move money.
##
## Checks run in this order; the FIRST blocker is the reason code and the full
## list rides in `payload.blockers` (`preview = true` quotes without charging):
##
##   1 E_UNKNOWN_ROAD_CLASS  not STREET (1) or AVENUE (2)
##   2 E_NO_TILES            empty tile list
##   3 doc 10 §2.13's own validation, in `query_road_preview`'s order —
##     E_OUT_OF_BOUNDS · E_WATER · E_FOOTPRINT · E_NOT_DEVELOPED ·
##     E_NOT_CONNECTED (the new set touches no existing road tile)
##   4 E_ALREADY_ROAD        every tile already carries the class asked for
##   5 E_FUNDS / E_AUSTERITY treasury below the quote, or doc 03 §2.10 layer 2
##
## Price is doc 03 §2.13(d)'s per-tile build price for the class, times the
## number of tiles that are actually FRESH — a run that overlaps three tiles of
## existing street is billed for what it lays, not for what the player dragged
## over. Nothing is charged on a preview or on any failure.
func cmd_place_road(tiles: Array, road_class: int, preview: bool = false) -> Dictionary:
	if not ROAD_CLASS_NAMES.has(road_class):
		return CommandQueue.fail(&"E_UNKNOWN_ROAD_CLASS",
				{"blockers": [&"E_UNKNOWN_ROAD_CLASS"], "road_class": road_class})
	var wanted := _tile_list(tiles)
	if wanted.is_empty():
		return CommandQueue.fail(&"E_NO_TILES", {"blockers": [&"E_NO_TILES"]})
	var road_preview: Dictionary = roads.query_road_preview(wanted, road_class)
	var fresh: Array = road_preview["tiles"]
	var blockers: Array = (road_preview["reasons"] as Array).duplicate()
	if blockers.is_empty() and fresh.is_empty():
		blockers.append(&"E_ALREADY_ROAD")
	var class_name_of := String(ROAD_CLASS_NAMES[road_class])
	var cost := fresh.size() * econ_curves.road_build_cost(class_name_of,
			float(treasury.difficulty().get("M_build", 1.0)))
	if treasury.balance < cost:
		blockers.append(&"E_FUNDS")
	var quote := {"blockers": blockers, "cost": cost, "tiles": fresh.size(),
			"road_class": road_class, "class_name": class_name_of,
			"skipped": road_preview.get("skipped", []),
			"crew_hours": float(road_preview["crew_hours"]),
			"work_units": int(road_preview["work_units"])}
	if not blockers.is_empty():
		return CommandQueue.fail(blockers[0], quote)
	if preview:
		return CommandQueue.ok(quote)

	var paid := treasury.spend(cost, &"construction", "road build")
	if not bool(paid["ok"]):
		quote["blockers"] = [_spend_reason(paid)]
		return CommandQueue.fail(_spend_reason(paid), quote)
	# Doc 10 stamps the tiles, opens the `construction_new` closure and submits
	# the job; the cost travels in the payload so the queue's own §2.10 refund
	# table has something to refund against.
	var result: Dictionary = roads.cmd_road_build(fresh, road_class, cost)
	if not bool(result["ok"]):
		# Unreachable — doc 10 re-runs the preview it just handed us — but a
		# refused command must never keep the money.
		treasury.credit(cost, &"construction", "road build refused")
		quote["blockers"] = [result["reason_code"]]
		return CommandQueue.fail(StringName(String(result["reason_code"])), quote)
	construction.assign_crew(int(result["payload"]["job_id"]), ROAD_JOB_CREW)
	quote["job_id"] = int(result["payload"]["job_id"])
	bus.emit(&"road_build_started", {"tiles": fresh.size(), "road_class": road_class,
			"class_name": class_name_of, "cost": cost, "job_id": quote["job_id"]})
	stats_add(&"road_tiles_built")
	return CommandQueue.ok(quote)


## Upgrade STREET tiles to AVENUE (doc 10 §2.13). Order of checks:
##
##   1 E_NO_TILES             empty tile list
##   2 E_NO_ELIGIBLE_TILES    no tile in the set is a STREET free of any closure
##                            other than `construction_work` (doc 10's rule)
##   3 E_FUNDS / E_AUSTERITY
##
## Price is doc 03 §2.13(d)'s `STREET → AVENUE` per-tile upgrade, over the
## ELIGIBLE tiles only. Condition is preserved by doc 10 (§2.13), so this buys
## capacity and the `E_AVENUE` gate, never a repair.
func cmd_upgrade_road(tiles: Array, preview: bool = false) -> Dictionary:
	var wanted := _tile_list(tiles)
	if wanted.is_empty():
		return CommandQueue.fail(&"E_NO_TILES", {"blockers": [&"E_NO_TILES"]})
	var road_preview: Dictionary = roads.query_upgrade_preview(wanted)
	var eligible: Array = road_preview["tiles"]
	var blockers: Array = (road_preview["reasons"] as Array).duplicate()
	var cost := eligible.size() * econ_curves.road_upgrade_cost("STREET_TO_AVENUE",
			float(treasury.difficulty().get("M_build", 1.0)))
	if treasury.balance < cost:
		blockers.append(&"E_FUNDS")
	var quote := {"blockers": blockers, "cost": cost, "tiles": eligible.size(),
			"crew_hours": float(road_preview["crew_hours"]),
			"work_units": int(road_preview["work_units"])}
	if not blockers.is_empty():
		return CommandQueue.fail(blockers[0], quote)
	if preview:
		return CommandQueue.ok(quote)

	var paid := treasury.spend(cost, &"construction", "road upgrade")
	if not bool(paid["ok"]):
		quote["blockers"] = [_spend_reason(paid)]
		return CommandQueue.fail(_spend_reason(paid), quote)
	var result: Dictionary = roads.cmd_road_upgrade(eligible, cost)
	if not bool(result["ok"]):
		treasury.credit(cost, &"construction", "road upgrade refused")
		quote["blockers"] = [result["reason_code"]]
		return CommandQueue.fail(StringName(String(result["reason_code"])), quote)
	construction.assign_crew(int(result["payload"]["job_id"]), ROAD_JOB_CREW)
	quote["job_id"] = int(result["payload"]["job_id"])
	bus.emit(&"road_upgrade_started", {"tiles": eligible.size(), "cost": cost,
			"job_id": quote["job_id"]})
	stats_add(&"road_tiles_upgraded")
	return CommandQueue.ok(quote)


## Demolish road tiles (doc 10 §2.13). Order of checks:
##
##   1 E_NO_TILES       empty tile list
##   2 E_NOT_ROAD       no tile in the set is a road tile
##   3 E_WOULD_ORPHAN   a standing building would be left with no road access
##
## Refund is doc 03 §2.13(d)'s `DEMOLITION_REFUND_FRACTION × build price` per
## tile, at the class each tile actually carries (STREET $450 · AVENUE $1,300) —
## so ripping up an avenue you upgraded returns the avenue's refund, not the
## street's. Demolition is instant: doc 10 §2.13 files no job for it.
func cmd_demolish_road(tiles: Array, preview: bool = false) -> Dictionary:
	var wanted := _tile_list(tiles)
	if wanted.is_empty():
		return CommandQueue.fail(&"E_NO_TILES", {"blockers": [&"E_NO_TILES"]})
	var road_preview: Dictionary = roads.query_demolish_preview(wanted)
	var victims: Array = road_preview["tiles"]
	if victims.is_empty():
		return CommandQueue.fail(&"E_NOT_ROAD", {"blockers": [&"E_NOT_ROAD"]})
	var refund := 0
	var by_class := {}
	for entry in victims:
		var t: Vector2i = entry
		var name_of := String(ROAD_CLASS_NAMES.get(world.grid.road_class_at(t.x, t.y), "STREET"))
		refund += econ_curves.road_demolish_refund(name_of)
		by_class[name_of] = int(by_class.get(name_of, 0)) + 1
	var quote := {"blockers": [], "refund": refund, "tiles": victims.size(),
			"by_class": by_class}
	# Doc 02 owns the access list; doc 10 owns the rule and the reason code
	# (§2.13: "rejected if, after removal, any building's access tile would have
	# no adjacent road tile"). This coordinator supplies the list, one tile per
	# building near the removed set, chosen so doc 10's per-tile test reproduces
	# doc 02's per-BUILDING one: a survivor contributes a tile that keeps its
	# road, an orphan contributes the tile that loses it.
	var access_tiles := _road_access_tiles(victims)
	if preview:
		var dry: Dictionary = roads.query_demolish_orphan(victims, access_tiles)
		if not bool(dry["ok"]):
			quote["blockers"] = [&"E_WOULD_ORPHAN"]
			quote["access_tile"] = dry["access_tile"]
			return CommandQueue.fail(&"E_WOULD_ORPHAN", quote)
		return CommandQueue.ok(quote)

	var result: Dictionary = roads.cmd_road_demolish(victims, access_tiles)
	if not bool(result["ok"]):
		quote["blockers"] = [result["reason_code"]]
		quote.merge(result.get("payload", {}), true)
		return CommandQueue.fail(StringName(String(result["reason_code"])), quote)
	# `TileGrid.set_road` clears BUILDABLE when a tile is paved and does not put
	# it back when the pavement goes (doc 09 §2.2 owns the flag, doc 10 owns the
	# class), so the ground a demolition frees is re-opened here — otherwise
	# ripping up a road would sterilise the tile for the life of the city.
	for entry in victims:
		var t: Vector2i = entry
		var block := world.block_of_tile(t.x, t.y)
		if block == null or not block.is_ready():
			continue
		if world.grid.has_flag(t.x, t.y, TileGrid.FLAG_WATER) \
				or world.grid.has_flag(t.x, t.y, TileGrid.FLAG_BLOCKED) \
				or world.grid.has_flag(t.x, t.y, TileGrid.FLAG_OCCUPIED):
			continue
		world.grid.set_flag(t.x, t.y, TileGrid.FLAG_BUILDABLE)
	if refund > 0:
		treasury.credit(refund, &"construction", "road demolition")
	bus.emit(&"road_demolished", {"tiles": victims.size(), "refund": refund,
			"by_class": by_class.duplicate()})
	stats_add(&"road_tiles_demolished")
	return CommandQueue.ok(quote)


## Doc 10 §2.13's automatic-repair policy — the pair, because `RoadNetwork` takes
## the pair. The wrapper exists for the same reason every other one here does:
## a shell binds `CitySim`, never a subsystem, and doc 91 §17's matrix counted
## this verb doorless partly *because* it had no wrapper to bind.
##
## Free: doc 03 prices no policy change. The SPEND it moves is `_queue_auto_repairs`'s,
## a day at a time, against doc 03's own quotes.
func cmd_set_auto_repair_policy(threshold: float, daily_cap: int) -> Dictionary:
	return roads.cmd_set_auto_repair_policy(threshold, daily_cap)


## What the two dials currently hold — what a shell seeds S9's rows from. The
## keys are the settings ROWS' keys (doc 12 §2.13), because that is the only
## thing this dictionary is for.
func auto_repair_policy() -> Dictionary:
	return {"auto_repair_threshold": roads.auto_repair_threshold,
			"auto_repair_daily_cap": roads.auto_repair_daily_cap}


## Accepts `Vector2i`, `[x, z]` pairs and `Vector2`, so a UI drag, a saved
## selection and a test fixture can all speak the same verb. Order is the
## caller's, minus duplicates — a water main is a PATH, so this may not sort.
static func _tile_list(raw: Array) -> Array:
	var out: Array = []
	var seen := {}
	for entry in raw:
		var tile := Vector2i.ZERO
		var parsed := true
		match typeof(entry):
			TYPE_VECTOR2I:
				tile = entry
			TYPE_VECTOR2:
				tile = Vector2i(entry)
			TYPE_ARRAY:
				var pair: Array = entry
				parsed = pair.size() >= 2
				if parsed:
					tile = Vector2i(int(pair[0]), int(pair[1]))
			_:
				parsed = false
		# An OUT-OF-BOUNDS tile is kept, not dropped: the commands raise
		# `E_OUT_OF_BOUNDS` for it, and silently swallowing it here would answer
		# a bad selection with `E_NO_TILES` — a different, misleading refusal.
		if not parsed or seen.has(tile):
			continue
		seen[tile] = true
		out.append(tile)
	return out


## One representative access tile per building whose road access the removal set
## could touch. Doc 09 §2.9.1's placement rule is per BUILDING — "every building
## footprint must be orthogonally adjacent to at least one road tile" — so a
## building survives if ANY footprint tile keeps a neighbour road. The tile
## contributed is therefore the one that answers doc 10's per-tile test with the
## building's own verdict.
func _road_access_tiles(victims: Array) -> Array:
	var removing := {}
	for entry in victims:
		removing[entry] = true
	var out: Array = []
	for sim_id in roster_ids():
		var record: Dictionary = _building_records.get(sim_id, {})
		if record.is_empty():
			continue
		var origin: Vector2i = record.get("origin_global", record.get("origin", Vector2i.ZERO))
		var footprint: Vector2i = record.get("footprint", Vector2i.ONE)
		if not _footprint_near(origin, footprint, removing):
			continue
		var survivor := Vector2i(-1, -1)
		var doomed := Vector2i(-1, -1)
		for z in range(origin.y, origin.y + footprint.y):
			for x in range(origin.x, origin.x + footprint.x):
				var tile := Vector2i(x, z)
				for d in RoadGraph.DIRS:
					var q: Vector2i = tile + d
					if not TileGrid.in_bounds(q.x, q.y):
						continue
					if world.grid.road_class_at(q.x, q.y) == TileGrid.ROAD_NONE:
						continue
					if removing.has(q):
						if doomed.x < 0:
							doomed = tile
					elif survivor.x < 0:
						survivor = tile
		if survivor.x >= 0:
			out.append(survivor)
		elif doomed.x >= 0:
			out.append(doomed)
	return out


## Cheap pre-filter for `_road_access_tiles` (doc 10 §2.13: "evaluate only
## buildings whose access tile is within 2 tiles of the removed set").
static func _footprint_near(origin: Vector2i, footprint: Vector2i,
		removing: Dictionary) -> bool:
	for tile in removing:
		var t: Vector2i = tile
		if t.x >= origin.x - 2 and t.x <= origin.x + footprint.x + 1 \
				and t.y >= origin.y - 2 and t.y <= origin.y + footprint.y + 1:
			return true
	return false


## Doc 09 §2.3 phase 4, `ROAD_INSTALL` — "road template stamped (§2.9.1)". Doc 09
## §2.9.1 owns the template and doc 10 §2.3 owns the class mapping, so the whole
## of this coordinator's job is to hand doc 10 the block that just finished its
## road phase. It is here rather than in `DevelopmentController` for the same
## reason `_extend_utility_corridor` is: the pipeline is world-effect-only and
## may not reach into the tile grid or another doc's system (doc 09 §2.3).
##
## Doc 03 §2.8 has already charged the phase — the stamp books nothing (doc 10
## §2.3's no-double-billing rule).
func _stamp_block_roads(block_id: String) -> void:
	var block := world.block(block_id)
	if block == null:
		return
	var stamped: Dictionary = roads.stamp_block_template(block.grid)
	if (stamped["tiles"] as Array).is_empty():
		return
	bus.emit(&"block_roads_stamped", {"block": block_id,
			"tiles": (stamped["tiles"] as Array).size(),
			"avenue": int(stamped["avenue"]), "street": int(stamped["street"])})


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
	# A demolished water site takes its doc-05 nodes with it, for the same reason
	# a demolished station takes its units: the shell IS the node's power_ref, and
	# an orphaned pump would keep supplying a city from a building that is gone.
	_retire_water_nodes(sim_id)
	# …and a demolished substation or plant takes its grid node, for the same
	# reason: the shell IS the node (doc 04 §2.1 / C-30).
	_retire_grid_node(sim_id)
	# A demolished station takes its units with it (doc 06 §2.11): the roster has
	# to shrink for the same reason it has to grow (doc 92 F-3).
	if FLEET_STATION_ARCHETYPES.has(b.archetype):
		var retired := incidents.fleet.remove_station(sim_id)
		if int(retired.get("removed", 0)) > 0:
			bus.emit(&"fleet_station_retired", {"sim_id": sim_id,
					"archetype": String(b.archetype),
					"removed": int(retired["removed"]),
					"units": (retired["units"] as Array).duplicate(),
					"fleet_size": incidents.fleet.size()})
	buildings.erase(sim_id)
	_invalidate_roster()
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

	# `repair` is NOT an austerity-blocked category (doc 03 §2.10 layer 2 keeps
	# the city repairable), but it can still be refused at the credit floor.
	var paid := treasury.spend(cost, &"repair", "repair " + sim_id)
	if not bool(paid["ok"]):
		quote["blockers"] = [_spend_reason(paid)]
		return CommandQueue.fail(_spend_reason(paid), quote)
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


# ------------------------------------------------ doc 06 §2.16 the street tap

## Collect one street opportunity — the tap the whole opportunity layer exists
## for (doc 06 §2.16). Reporting a crook, catching a dog, pocketing what somebody
## dropped: three fictions, one verb, because what the player does is identical
## and a game that made them three buttons would be teaching filing, not play.
##
##   1 E_UNKNOWN_OPPORTUNITY  no live offer with that id
##   2 E_EXPIRED              the offer's clock ran out between the tap and here
##
## `preview = true` answers the same payload and takes nothing, which is what the
## map marker's label reads. The commit path pays through doc 03 §2.5's `street`
## revenue line — its own ledger row and its own lifetime counter, deliberately
## NOT folded into tax: tax is a rate on the city's value and this is a bounty on
## the player's attention, and mixing them would make the tax slider look like it
## moved when the player simply tapped more.
##
## **The second refusal is not defensive.** The spawner expires on the
## game-minute; a tap lands between ticks, off a marker the renderer drew up to a
## frame ago. `E_EXPIRED` is the honest answer to "I was half a second late", and
## it is answered BEFORE the money so a stale marker can never pay twice.
##
## **The two refusals overlap, and `ui/` should treat them alike.** A marker the
## spawner has already swept answers `E_UNKNOWN_OPPORTUNITY`, not `E_EXPIRED` —
## the row is gone, so there is nothing left to call expired — while one whose
## clock ran out *between* game-minutes is still on the roster and answers
## `E_EXPIRED`. Which of the two a late tap gets depends on where in the minute
## it landed, so the surface should say the same thing for both: *it's gone*.
## They are separate codes because they are separate FACTS, not because the
## player needs to tell them apart.
func cmd_collect_opportunity(opportunity_id: Variant, preview: bool = false) -> Dictionary:
	# The shell's tap funnel carries ids as text (doc 12 §4.4's one-funnel rule);
	# the roster keys on int. Coerce here so both callers speak.
	var opp_id := int(str(opportunity_id))
	var row := street.find(opp_id)
	if row.is_empty():
		return CommandQueue.fail(&"E_UNKNOWN_OPPORTUNITY")
	var quote := {
		"id": int(row["id"]),
		"kind": String(row["kind"]),
		"reward": int(row["reward"]),
		"tile": [int(row["tile_x"]), int(row["tile_y"])],
		"side": int(row["side"]),
		"expires_h": float(row["expires_h"]),
	}
	if float(row["expires_h"]) <= sim_hour():
		return CommandQueue.fail(&"E_EXPIRED", quote)
	if preview:
		return CommandQueue.ok(quote)
	var taken := street.take(opp_id)
	if taken.is_empty():
		return CommandQueue.fail(&"E_UNKNOWN_OPPORTUNITY")
	var reward := int(taken["reward"])
	if reward > 0:
		# Through the SETTLED city-services channel (doc 03 §2.5), source
		# "street" — so the budget row, gate 32's share measurement and the
		# lifetime book all see the same dollar. `lifetime_street` still
		# accrues via the category, so the sim branch's three-key hash
		# enumeration keeps its meaning.
		treasury.credit_city_service(reward, &"street",
				"opportunity " + String(taken["kind"]))
	bus.emit(&"opportunity_collected", OpportunitySystem.event_payload(
			&"opportunity_collected", taken))
	stats_add(&"opportunities_collected")
	return CommandQueue.ok(quote)


## The city's absolute game-hour, off the exact integer tick. The one clock read
## the command layer needs — `expires_h` is stated in these units.
func sim_hour() -> float:
	return float(clock.tick_index) / float(GameClock.TICKS_PER_HOUR)


## The doc 12 P1-38 onboarding hook: the tutorial's transformer cooks on cue.
func trigger_tutorial_transformer_failure() -> Incident:
	return incidents.spawn_scripted_from_tag(loader, "transformer_fail")


## The other half of the same hook (doc 12 §2.17): while the coach marks are up,
## nothing else may go wrong. `seconds_gs` is GAME seconds — the shell converts
## the tutorial's real-time budget with its own `SimHost.GAME_MS_PER_REAL_MS`,
## because the sim owns no wall clock (constitution §4). Calls extend the hold
## rather than replacing it. Doc 07's own F5 suppression is untouched.
func suppress_director(seconds_gs: float) -> void:
	if director != null:
		director.suppress(seconds_gs)


## Tutorial finished or skipped — the Director may schedule again.
func release_director() -> void:
	if director != null:
		director.release()


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

	var paid := treasury.spend(price, &"land", "land " + block_id)
	if not bool(paid["ok"]):
		quote["blockers"] = [_spend_reason(paid)]
		return CommandQueue.fail(_spend_reason(paid), quote)
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
## Water, blocked and already-occupied tiles keep their own flags; ROAD tiles are
## doc 10's template stamp — laid two phases earlier by `_stamp_block_roads` —
## and are skipped, which is what makes `count_buildable` report doc 09 §2.9.1's
## **169 buildable tiles on a clean block** rather than all 256.
func _open_block_for_building(block_id: String) -> void:
	var block := world.block(block_id)
	if block == null:
		return
	var origin: Vector2i = block.grid * TileGrid.TILES_PER_BLOCK
	for z in range(origin.y, origin.y + TileGrid.TILES_PER_BLOCK):
		for x in range(origin.x, origin.x + TileGrid.TILES_PER_BLOCK):
			if world.grid.has_flag(x, z, TileGrid.FLAG_WATER) \
					or world.grid.has_flag(x, z, TileGrid.FLAG_BLOCKED) \
					or world.grid.has_flag(x, z, TileGrid.FLAG_ROAD):
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
		var reason := "development %s %s" % [block_id, String(charge["phase"])]
		var paid := treasury.spend(cost, &"construction", reason)
		var deferred := int(paid.get("deferred", 0))
		if StringName(String(paid.get("reason_code", ""))) == &"AUSTERITY_BLOCKED":
			# The phase is already in flight — doc 03 §2.10 layer 2 never strands
			# half-built work — so the bill becomes a layer-4 liability instead of
			# being silently forgiven, which is what the pre-fix code did. (A
			# credit-floor refusal books its own deferral inside `spend()`.)
			deferred = cost
			treasury.defer(deferred, &"construction", reason)
		bus.emit(&"development_phase_charged", {"block": block_id,
				"phase": String(charge["phase"]), "cost": cost,
				"deferred": deferred})
	_publish_treasury_events()


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
	b.max_level = catalog.max_level_of(String(b.archetype))
	_block_dark_weights[sim_id] = int(b.stats.get("population", 0)) + int(b.stats.get("jobs", 0))
	_sync_station_fleet(sim_id, b)
	_commission_water_nodes(sim_id)
	# doc 04 §2.1 / C-30: a finished substation or plant IS a grid node.
	_commission_grid_node(sim_id, b)
	for event in done["payload"]["events"]:
		var out: Dictionary = event.duplicate()
		out["sim_id"] = sim_id
		out["level"] = b.level
		bus.emit(StringName(String(out["type"])), out)


## The demolition half of `_commission_water_nodes`: every node hosted on this
## shell leaves the graph, and any main whose only reason to exist was reaching
## it goes with it. Zones are rebuilt once, at the end.
func _retire_water_nodes(sim_id: String) -> Array:
	var retired: Array = []
	for node_id in _sorted(water.nodes):
		if (water.nodes[node_id] as WaterNode).power_ref != sim_id:
			continue
		retired.append(String(node_id))
	if retired.is_empty():
		return retired
	for node_id in retired:
		water.remove_node(String(node_id))
	# A main is a pipe, not a promise: one whose endpoint node is gone still
	# carries water for whatever else it touches, so mains are left standing.
	# Only the site's own lateral (`<sim_id>` prefixed) goes.
	for edge_id in _sorted(water.edges):
		if String(edge_id).begins_with(sim_id + "-"):
			water.remove_main(String(edge_id))
	water.rebuild_zones()
	_refresh_water_kw()
	bus.emit(&"water_component_retired", {"sim_id": sim_id, "nodes": retired})
	return retired


## A water shell just finished, so the doc-05 node it hosts comes out of
## `offline_manual` and starts supplying. This is the seam doc 02 §2.12's state
## table and doc 05 §2.5's `is_live()` meet at: the building is what takes the
## construction time, the node is what pumps, and a node that pumped while its
## shell was a hole in the ground would be free supply.
func _commission_water_nodes(sim_id: String) -> void:
	var commissioned: Array = []
	for node_id in _sorted(water.nodes):
		var n: WaterNode = water.nodes[node_id]
		if n.power_ref != sim_id or n.state != &"offline_manual":
			continue
		n.state = &"ok"
		commissioned.append(String(node_id))
	if commissioned.is_empty():
		return
	water.topology_dirty = true
	water.rebuild_zones()
	bus.emit(&"water_component_commissioned", {"sim_id": sim_id,
			"nodes": commissioned})


## A station shell just finished (a new build, or an upgrade to level L+1), so
## doc 06 re-houses it: a new station commissions its whole L1 rung, an upgraded
## one commissions only the difference. Doc 02 owns the shell, doc 06 owns how
## many units live in it (C-50), and this is the seam between them (doc 92 F-3).
func _sync_station_fleet(sim_id: String, b: Building) -> void:
	if not FLEET_STATION_ARCHETYPES.has(b.archetype):
		return
	var result := incidents.fleet.sync_station(sim_id, String(b.archetype),
			maxi(1, b.level), b.origin)
	if int(result.get("added", 0)) <= 0:
		return
	bus.emit(&"fleet_station_synced", {"sim_id": sim_id,
			"archetype": String(b.archetype), "level": maxi(1, b.level),
			"added": int(result["added"]), "units": (result["units"] as Array).duplicate(),
			"fleet_size": incidents.fleet.size()})


## doc 02 §2.6 wear, one settled game-hour of it, for every building that decays
## (§2.12's state table: active, damaged, and an upgrade in flight — never a
## fresh site, never a ruin). Called from `HourlyPhaseSystem` after the grid has
## settled the hour and before doc 03 bills it, because `apply_decay` reads the
## availability that settlement produced and the economy reads the condition this
## produces.
##
##   powered_fraction  doc 04's `power_availability_hour` for the hour just closed
##   overload_excess   `max(0, load/capacity − 1)` of the transformer serving it
##   weather_decay_mult doc 07's `condition_decay_mult`, × doc 03 §2.10 layer 2's
##                     `AUSTERITY_DECAY_MULT` while austerity is engaged
##
## Decay itself draws no RNG — it is a deterministic integration. The one
## stochastic thing on this path is doc 02 §2.6's LAST dead branch, the
## structural-failure roll: a `damaged` building below condition 0.10 fails at
## 0.02/gh on the `failures` stream, in sorted id order, and the draw happens
## only for the handful of buildings that qualify. `destroy_allowed` is doc 08
## C-47: during offline catch-up the roll is not TAKEN (rather than taken and
## refused), so an absence cannot silently consume the stream, and the rot the
## player comes back to is still standing where they can see it.
func apply_hourly_decay(dt_h: float, availability: Dictionary,
		destroy_allowed: bool = true) -> void:
	if dt_h <= 0.0:
		return
	var weather_mult := weather.get_effect("condition_decay_mult")
	if is_nan(weather_mult):
		weather_mult = 1.0
	weather_mult *= treasury.austerity_decay_mult()
	var overload := _overload_excess_by_component()
	var now_minutes := clock.sim_time_minutes()
	for id in roster_ids():
		var b: Building = buildings[id]
		if not b.decays():
			continue
		var excess := float(overload.get(grid.attachment_of(String(id)), 0.0))
		var events: Array = b.apply_decay(dt_h, excess,
				float(availability.get(id, 1.0)), weather_mult)
		if destroy_allowed:
			events.append_array(b.roll_structural_failure(rng, dt_h, now_minutes))
		for event in events:
			var out: Dictionary = event.duplicate()
			out["sim_id"] = id
			out["condition"] = b.condition
			bus.emit(StringName(String(out["type"])), out)


## Per-component `max(0, load/capacity − 1)`, computed once per settled hour and
## shared by every building the component serves. Components are few and
## buildings are many, so this is the cheap half of the join.
func _overload_excess_by_component() -> Dictionary:
	var out: Dictionary = {}
	for component_id in grid.component_ids():
		var c: Dictionary = grid.component(String(component_id))
		var capacity := float(c.get("capacity_kw", 0.0))
		if capacity <= 0.0:
			continue
		var excess := float(c.get("load_kw", 0.0)) / capacity - 1.0
		if excess > 0.0:
			out[String(component_id)] = excess
	return out


## Doc 03 §2.10 layers 2/3/5, run once per settled game-hour off the settlement
## the economy just produced. The ladder needs a *daily* gross revenue and gross
## expense; the last settled hour annualised to a game-day is the same reading
## `DirectorInputs.daily_opex` already takes, and it keeps the ladder stateless —
## no new persisted field, so save→load→advance identity is unchanged.
##
## Order is the doc's: the credit limit is sized first (layer 3), austerity is
## judged against it (layer 2), then relief is offered last (layer 5) so a city
## that austerity alone can save is never handed a grant.
func update_recovery_ladder(settled: Dictionary, hour: int) -> void:
	var gross := float((settled.get("revenue", {}) as Dictionary).get("gross", 0.0))
	var expense := float((settled.get("expenses", {}) as Dictionary).get("total", 0.0))
	var daily_revenue := maxf(0.0, gross) * 24.0
	var daily_expense := maxf(0.0, expense) * 24.0
	treasury.update_credit_limit(daily_revenue)
	treasury.update_austerity(daily_expense, hour)
	treasury.maybe_grant_relief(hour, daily_revenue, (gross - expense) * 24.0)
	_publish_treasury_events()


## Drain the treasury's own event queue every settled hour — the ladder's events
## go to the bus, the bookkeeping ones are consumed here. Draining is not
## optional: an undrained queue grows for the life of the city.
func _publish_treasury_events() -> void:
	for event in treasury.drain_events():
		var type := StringName(String(event["type"]))
		if TREASURY_BUS_EVENTS.has(type):
			bus.emit(type, event)


## One `spend()` refusal, translated into the command layer's reason code.
## Doc 03 §5: nothing outside `Treasury` moves the balance, so a command that
## cannot pay must fail here rather than proceed for free (doc 92 F-7).
static func _spend_reason(result: Dictionary) -> StringName:
	match StringName(String(result.get("reason_code", ""))):
		&"AUSTERITY_BLOCKED":
			return &"E_AUSTERITY"
		_:
			return &"E_FUNDS"


## Assemble the §2.2/§2.4 settlement inputs from live sim state (held
## metering constants documented above).
func build_settlement_inputs(ctx: TimeContext, availability: Dictionary) -> Dictionary:
	var building_inputs: Array = []
	var stations: Array = []
	var has_pump := false
	var water_service := water.service_factors()
	var district_by_id := district_of_building()
	for id in roster_ids():
		var b: Building = buildings[id]
		var district_id: String = district_by_id[id]
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
		# Doc 06 owns fleet capacity (C-50), so doc 03 bills the roster doc 06
		# actually houses — not a held constant. The founding roster is 2 patrol /
		# 1 engine / 2 utility / 2 water / 1 crew off doc 06's per-level ladders,
		# and it GROWS when the player builds a station (doc 92 F-3 ruling).
		# `km_this_hour` is 0 until doc 06 meters road distance, so E_fuel_vehicle
		# bills nothing rather than a fabricated kilometre.
		"vehicles": incidents.fleet.roster_for_economy(),
		"grid_inventory": grid.grid_inventory(),
		"delivered_mwh": HELD_DELIVERED_MWH,
		"generation": [{"plant_type": "gas", "mwh": HELD_DELIVERED_MWH, "level": 1}],
		"water": water.inventory(),
		"roads": roads.settlement_inputs(),
		# RR-77 / RR-78. The receipt book is DRAINED here — once per settled
		# game-hour, in the ECONOMY phase, after INCIDENTS has finished writing
		# to it (doc 01 §2's phase order) — so no payout is reported twice and
		# none is dropped. The founding grant is a published constant on a clock
		# doc 03 owns; this method only tells it which game-day it is.
		"city_services": treasury.take_hour_city_services(),
		"founding_assistance": econ_curves.founding_assistance_per_hour(
				ctx.tick_index / GameClock.TICKS_PER_DAY),
	}


## Every district's served/demanded power ratio in ONE roster pass.
##
## This replaced a per-district `_district_service_ratio(id)` that walked the
## WHOLE roster each time it was asked, and the districts phase asks for all of
## them on every step — twelve full walks of a 1,500-building roster, sixty
## times a game-hour on the fine path. Each district's sum still accumulates
## over the same ascending-id subsequence with the same summands, so every ratio
## is bit-identical to what the per-district walk produced; only the number of
## walks changed.
func _district_service_ratios() -> Dictionary:
	var served: Dictionary = {}
	var total: Dictionary = {}
	var district_by_id := district_of_building()
	for id in roster_ids():
		var district_id: String = district_by_id[id]
		if district_id == "":
			continue
		var demand := float(_last_demands.get(id, 0.0))
		total[district_id] = float(total.get(district_id, 0.0)) + demand
		if grid.is_powered(id):
			served[district_id] = float(served.get(district_id, 0.0)) + demand
	var out: Dictionary = {}
	for district_id in total:
		var denominator: float = total[district_id]
		out[district_id] = float(served.get(district_id, 0.0)) / denominator \
				if denominator > 0.0 else 1.0
	return out


func _rollup_district_population() -> void:
	var district_pop := {}
	var district_jobs := {}
	var district_by_id := district_of_building()
	for id in roster_ids():
		var b: Building = buildings[id]
		var district_id: String = district_by_id[id]
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
	scheduler.register(StreetPhaseSystem.new(self))
	scheduler.register(DistrictPhaseSystem.new(self))
	scheduler.register(HourlyPhaseSystem.new(self))
	scheduler.register(DirectorPhaseSystem.new(self))
	scheduler.register(WeatherReportPhaseSystem.new(self))
	scheduler.register(ReportPhaseSystem.new(self))


func compose_water_demands() -> Dictionary:
	var out: Dictionary = {}
	for id in roster_ids():
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


## Doc 07 → doc 06 live seam: the Director REQUESTS, doc 06 EXECUTES (contract
## in sim/weather/incident_request_sink.gd). The adapter refuses unknown kinds
## and unresolvable targets — the Director never assumes an incident exists
## because it asked for one. The severity_mult travels in `cause` for a later
## doc-06 pressure amendment rather than overriding doc 06's own severity roll.
class DirectorIncidentSink extends IncidentRequestSink:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func request_incident(kind: StringName, target: Dictionary) -> void:
		if not sim.incident_catalog.has_type(String(kind)):
			return
		var ref := String(target.get("ref", ""))
		var tile := Vector2i(-1, -1)
		var target_ref := {}
		if sim.buildings.has(ref):
			tile = (sim.buildings[ref] as Building).origin
			target_ref = {"kind": "building", "id": ref}
		elif ref != "" and sim.grid.has_component(ref):
			tile = sim.grid.component(ref).get("tile", Vector2i(-1, -1))
			target_ref = {"kind": "component", "id": ref}
		elif target.get("pos") is Vector2:
			var pos: Vector2 = target["pos"]
			tile = Vector2i(int(pos.x), int(pos.y))
		if tile.x < 0 or not TileGrid.in_bounds(tile.x, tile.y):
			return  # unresolvable target: refused, per the contract
		var inc := sim.incidents.spawn(String(kind), "", tile, target_ref, -1.0, {
			"reason": "director",
			"event_uid": int(target.get("event_uid", 0)),
			"severity_mult": float(target.get("severity_mult", 1.0)),
			"condition_floor": float(target.get("condition_floor", 0.0)),
		}, String(target.get("district_id", "")))
		if inc != null:
			sim._director_links[inc.id] = int(target.get("event_uid", 0))


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


## Doc 06 §2.16's opportunity layer, in the INCIDENTS phase behind the incident
## system — `&"street"` sorts after `&"incidents"`, which is the same trick
## `WaterHourlySystem` uses to sit behind `&"water"` — so the coverage index it
## reads is the one this minute's dispatch already rebuilt.
##
## **`advance_coarse` expires and returns.** That is doc 08 §2.3 rule 9 made
## structural rather than remembered: opportunities are the play-NOW layer, they
## do not accrue while the player is away, and the coarse path is the away path.
## The doc 01 §2.5 coarse contract is satisfied trivially — zero draws, zero
## spawns, and an expected value that matches the fine path's *for a player who
## was not there to tap anything*, which is the only equivalence that means
## something here. It is also why `tests/balance_matrix.gd`, which runs the
## coarse step, is bit-identical to the day before this system existed.
class StreetPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"street"
	func phase() -> int: return Phase.INCIDENTS   # sorts AFTER &"incidents"
	func cadence() -> int: return Cadence.EVERY_MINUTE
	func advance_fine(ctx: TimeContext) -> void:
		# Absolute game-hours off an exact integer tick, never an accumulated
		# delta — the same rule the incident system advances on.
		sim.street.advance(float(ctx.tick_index + period_ticks())
				/ float(GameClock.TICKS_PER_HOUR), not ctx.is_catchup)
	func advance_coarse(ctx: TimeContext) -> void:
		sim.street.advance(float(ctx.tick_index + GameClock.TICKS_PER_HOUR)
				/ float(GameClock.TICKS_PER_HOUR), false)


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
		_run(1.0 / 60.0)
	func advance_coarse(_ctx: TimeContext) -> void:
		_run(1.0)
	## One roster pass for every district's ratio, then the per-district update
	## in the same sorted order as before. Neither `update_power_reliability` nor
	## `recompute_fast` touches grid power, demands or the roster, so hoisting the
	## measurement out of the loop reads exactly the same city each district did.
	func _run(dt_h: float) -> void:
		var ratios := sim._district_service_ratios()
		for district_id in sim.districts.district_ids_sorted():
			sim.districts.update_power_reliability(district_id,
					float(ratios.get(district_id, 1.0)), dt_h)
			sim.districts.recompute_fast(district_id)


class HourlyPhaseSystem extends SimSystem:
	var sim: CitySim
	func _init(p_sim: CitySim) -> void: sim = p_sim
	func system_id() -> StringName: return &"hourly"
	func phase() -> int: return Phase.ECONOMY
	func cadence() -> int: return Cadence.EVERY_HOUR
	func advance_fine(ctx: TimeContext) -> void:
		# P14 order: availability finalized → doc 02 §2.6 wear → districts settle
		# → economy bills the completed hour → doc 03 §2.10 recovery ladder →
		# population/happiness relax (P15 material).
		var availability := sim.grid.settle_hour()
		# Wear runs BEFORE the settlement, so the hour that was lived at the old
		# condition is billed at the new one — the same ordering doc 03 §2.4's
		# MAINT_CONDITION_PENALTY assumes, and the reason neglect costs money.
		sim.apply_hourly_decay(1.0, availability, not ctx.is_catchup)
		sim.districts.recompute_slow(1.0)
		var settled := sim.economy.settle_hour(sim.build_settlement_inputs(ctx, availability))
		sim.last_settlement = settled
		sim.update_recovery_ladder(settled, ctx.tick_index / GameClock.TICKS_PER_HOUR)
		sim._last_expense_hour = float(
				(settled.get("expenses", {}) as Dictionary).get("total", sim._last_expense_hour))
		# doc 03 §2.2: the tax rate is not only a revenue scalar — it slows
		# growth, shifts the happiness target AND lowers the attractiveness
		# ceiling doc 09 relaxes toward (amendment T-1, the half that lets the
		# slider cost a HEALTHY city people). All three are exactly 0 / 1.0 at
		# TAX_RATE_BASE. Population reads the happiness of the hour just lived
		# and happiness then relaxes on the aggregates population just produced:
		# one hour of lag, deliberately, because happiness consumes
		# `employment_balance` and the cycle has to be cut somewhere.
		var result := sim.population.advance(sim._population_inputs(), 1.0,
				sim.districts.city_stability,
				sim.economy.growth_rate_multiplier(sim.tax_rate),
				sim.happiness.happiness,
				sim.economy.attractiveness_tax_factor(sim.tax_rate))
		sim._rollup_district_population()
		sim.happiness.advance(1.0, sim.districts.city_stability, 1.0,
				sim.population.employment_balance(), 1.0,
				sim.economy.happiness_tax_delta(sim.tax_rate))
		# Doc 09 §2.14's per-hour reconcile, on the population this hour just
		# produced. It reads four scalars and it is the ONLY state reading the
		# curriculum ever takes — the event kinds counted themselves as they
		# happened. The level it may have earned is granted in the REPORT phase
		# of this same tick, which is where every other goal event is published.
		sim.goals.reconcile(sim.goal_state_view())
		sim.publish_progression(sim.progression.update(int(result["city_population"])))
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
			# A director-requested incident closing frees the event's slot (F2).
			match StringName(String(event["type"])):
				&"incident_resolved", &"incident_failed", &"incident_abandoned":
					var incident_id := int(event.get("incident_id", -1))
					if sim._director_links.has(incident_id):
						sim.director.on_incident_resolved(incident_id,
								int(sim._director_links[incident_id]))
						sim._director_links.erase(incident_id)
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in sim.water.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
		# Doc 06 §2.16. `opportunity_collected` is NOT drained here — the verb
		# emits it on the spot, because doc 09 §2.14's counters tick on the TAP
		# and a counter that waited for the next tick would lag the finger.
		for event in sim.street.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in sim.development.drain_events():
			# The two phase effects that reach outside the land block itself —
			# the utility trunk and the buildable ground — are the coordinator's,
			# because DevelopmentController may not import the grid or the map's
			# tile flags (doc 09 §2.3 keeps the pipeline world-effect-only).
			match String(event["type"]):
				"development_phase_completed":
					match String(event.get("phase", "")):
						"ROAD_INSTALL":
							sim._stamp_block_roads(String(event["block"]))
						"UTILITY_CORRIDOR":
							sim._extend_utility_corridor(String(event["block"]))
				"block_ready":
					sim._open_block_for_building(String(event["block"]))
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in sim.events.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
		# Doc 09 §2.14. LAST of the republishers, because every emit above may
		# have moved a counter through `SimEventBus.observer` and this is the
		# publication of what those moves came to. Anything the drain itself
		# provokes lands on the next tick, which is the honest place for it: a
		# goal completed BY a goal event is not a thing the curriculum has.
		for event in sim.goals.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
		# Objectives ADVANCE the level (doc 93 §G1); the population ladder in
		# `progression.update` is the other route, and `grant_level` is monotone,
		# so whichever arrives first wins and neither can take a level back.
		sim.publish_progression(sim.progression.grant_level(sim.goals.earned_level))
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


## Every building id, ascending — the one iteration order the roster walks use.
## Same Array every call until the roster changes, so callers MUST NOT mutate it
## (none do; `_sorted(buildings)` handed out a private copy and this hands out
## the shared one, which is the whole point).
func roster_ids() -> Array:
	if _roster_dirty:
		_roster_ids = _sorted(buildings)
		_roster_dirty = false
	return _roster_ids


## Called by the four places `buildings` gains or loses a key: boot, restore,
## placement (both the ordinary and the water-shell path) and demolition.
func _invalidate_roster() -> void:
	_roster_dirty = true
	roster_revision += 1


## building id -> district id (empty for a building on no district's block).
##
## `_block_to_district[_building_records[id].block]` is a two-hop lookup that
## three per-step roster walks each did per building — the districts phase alone
## sixty times a game-hour. A building's block never moves, so the answer changes
## only when the roster changes or when a block changes district, and both carry
## a revision counter. Derived: never captured, rebuilt on the next ask.
func district_of_building() -> Dictionary:
	var key := Vector2i(roster_revision, districts.membership_revision)
	if key == _district_of_building_key:
		return _district_of_building
	var out: Dictionary = {}
	for id in roster_ids():
		out[id] = String(_block_to_district.get(
				String(_building_records[id].get("block", "")), ""))
	_district_of_building = out
	_district_of_building_key = key
	return out

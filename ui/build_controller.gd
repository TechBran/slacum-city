class_name BuildController
extends RefCounted
## The headless half of doc 12 §2.7 (build sheet + placement mode) and §2.9 (the
## building panel's upgrade block). `ui/build_sheet.gd` and
## `ui/building_panel.gd` only bind what this class computes — they own no
## thresholds, no validity rules and no copy (constitution §3, doc 12 §1).
##
## Three responsibilities, one domain:
##
##   1. **Card list** — the build sheet's rows, straight out of `BuildingCatalog`
##      and `CostCurves`. Cost, footprint and kW are *read*, never authored here
##      (doc 12 §2.7: "read from the archetype table, never authored").
##   2. **Placement state machine** — `enter()` → `move_to_*()` → `confirm()` /
##      `cancel()`, with a validity verdict recomputed on every move. The
##      preflight runs the **same checks in the same order** as
##      `CitySim.cmd_place_building`, reading sim state and charging nothing, so
##      the ghost's verdict and the command's answer can never disagree.
##   3. **Building panel view model** — vitals, service coverage and the full
##      upgrade checklist assembled from `cmd_upgrade_building(preview=true)`.
##
## The sim reference is read-only except through the two `cmd_*` commands, which
## is the doc 12 §4.4 funnel: the UI emits commands and reads snapshots, never
## the reverse.

# --- Placement state machine (doc 12 §2.2 S2 → S3) ---------------------------
const STATE_IDLE := &"idle"
const STATE_PLACING := &"placing"

# --- Verdicts (doc 12 §2.7's validity tint table) ----------------------------
const VERDICT_VALID := &"valid"
const VERDICT_WARN := &"warn"
const VERDICT_BLOCKED := &"blocked"

## Constitution §6: the tile is 8 m. Read from `data/world.json` when present so
## no tunable is owned by this file.
const TILE_M_DEFAULT := 8.0
const WORLD_JSON_PATH := "res://data/world.json"

## Doc 04 §2.1's placement roster (`data/grid_components.json`). The sheet lists
## these beside the buildings because to the player they are one verb — "put a
## thing on a tile" — and because `E_UNSERVED` is unanswerable without them.
const GRID_JSON_PATH := "res://data/grid_components.json"
const CATEGORY_GRID := "grid"
## The tutorial (doc 12 §2.17) and Wave 1.5 both ship exactly L1; the level a
## card offers is data (`placeable_levels`), never a constant here.
const GRID_CARD_LEVEL := 1

## Doc 02's upgrade gate, in the order `CitySim.cmd_upgrade_building` runs it.
## The checklist shows every row, passing ones included (doc 12 §2.9 item 5).
const UPGRADE_CHECKS: Array[StringName] = [
	&"E_STATE", &"E_MAX_LEVEL", &"E_CONDITION", &"E_CITY_LEVEL", &"E_FUNDS",
	&"E_POWER_HEADROOM", &"E_AVENUE",
]

## `E_AVENUE` only exists as a check from Level 4 up (C-62, hard gate L4/L5).
const AVENUE_FROM_LEVEL := 4
const AVENUE_RADIUS_TILES := 4
## How far the panel looks for the nearest avenue before it gives up and reports
## "beyond the search"; purely a display figure for the `{have}` parameter.
const AVENUE_SEARCH_TILES := 16

## Sheet ordering: category first (the doc's tab order), then cost. `grid` is
## last because it is the tab you go to once something else has already said no.
const CATEGORY_ORDER: Array[String] = [
	"residential", "commercial", "industrial", "service", "utility", CATEGORY_GRID,
]

## The four coverage tiles of doc 12 §2.9 item 4.
const COVERAGE_SLOTS: Array[String] = ["power", "water", "police", "fire"]

## Doc 04 publishes availability on [0,1]; the tile bands it with the same
## thresholds the HUD's grid chip uses, expressed as fractions.
const COVERAGE_NORMAL := 0.95
const COVERAGE_WARNING := 0.85

var sim: CitySim
var formatter: RequirementFormatter
var tile_m := TILE_M_DEFAULT

var state: StringName = STATE_IDLE
var archetype := ""
var variant := ""
var origin := Vector2i.ZERO
var size := Vector2i.ONE
var has_origin := false
## Set while the ghost is a grid component rather than a building; it is the
## `kind` of `cmd_place_grid_component` and "" for every building.
var component_kind := ""
var component_level := GRID_CARD_LEVEL

var _verdict: Dictionary = {}
var _grid_placeable: Dictionary = {}


func _init(p_sim: CitySim = null, p_formatter: RequirementFormatter = null,
		p_tile_m: float = -1.0) -> void:
	sim = p_sim
	formatter = p_formatter if p_formatter != null else RequirementFormatter.load_from_files()
	tile_m = p_tile_m if p_tile_m > 0.0 else BuildController.load_tile_m()
	_grid_placeable = BuildController.load_grid_placeable()


## `data/world.json.world.tile_meters`, mirroring `CameraState._apply_world()`.
static func load_tile_m() -> float:
	if not FileAccess.file_exists(WORLD_JSON_PATH):
		return TILE_M_DEFAULT
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(WORLD_JSON_PATH))
	if not (parsed is Dictionary):
		return TILE_M_DEFAULT
	var world: Variant = (parsed as Dictionary).get("world", {})
	if not (world is Dictionary):
		return TILE_M_DEFAULT
	return UIConfig.get_num(world, "tile_meters", TILE_M_DEFAULT)


## `data/grid_components.json.placeable` — doc 04 §2.1's roster, verbatim. The
## file carries no prices and no capacities by design (its own `_price_note`), so
## everything the card quotes past the footprint is read from the economy tables
## and from `cmd_place_grid_component`'s own preview.
static func load_grid_placeable() -> Dictionary:
	if not FileAccess.file_exists(GRID_JSON_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(GRID_JSON_PATH))
	if not (parsed is Dictionary):
		return {}
	var placeable: Variant = (parsed as Dictionary).get("placeable", {})
	return placeable if placeable is Dictionary else {}


# ===========================================================================
# Build sheet cards (doc 12 §2.7)
# ===========================================================================

## One card per placeable archetype. `locked` is `min_city_level > city_level`
## (the doc's lock glyph); an unaffordable card is NOT locked — it stays tappable
## so the requirement message can explain why (§2.7).
func cards() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if sim == null:
		return out
	for id: Variant in sim.catalog.archetypes():
		out.append(card(String(id)))
	for kind: Variant in grid_kinds():
		out.append(grid_card(String(kind)))
	out.sort_custom(BuildController._card_less)
	return out


## The placeable grid kinds, sorted so the sheet is deterministic.
func grid_kinds() -> Array[String]:
	var out: Array[String] = []
	for key: Variant in _grid_placeable:
		out.append(str(key))
	out.sort()
	return out


func is_grid_kind(id: String) -> bool:
	return _grid_placeable.has(id)


func grid_rules(kind: String) -> Dictionary:
	var raw: Variant = _grid_placeable.get(kind, {})
	return raw if raw is Dictionary else {}


## Lowest level the roster offers for a kind — the one the card places.
func grid_level(kind: String) -> int:
	var levels: Array = grid_rules(kind).get("placeable_levels", [])
	var lowest := GRID_CARD_LEVEL
	var found := false
	for entry: Variant in levels:
		var level := int(entry)
		if not found or level < lowest:
			lowest = level
			found = true
	return lowest


## A grid component's card. Same shape as a building's so `ui/build_sheet.gd`
## renders one list — plus `component_kind`, which is how the sheet's tap ends up
## in `cmd_place_grid_component` instead of `cmd_place_building`.
func grid_card(kind: String) -> Dictionary:
	var rules := grid_rules(kind)
	var level := grid_level(kind)
	var foot := int(rules.get("footprint_tiles", 1))
	var cost := 0
	if sim != null:
		cost = sim.econ_curves.grid_build_cost(kind, level,
				float(sim.treasury.difficulty().get("M_build", 1.0)))
	var radii: Array = rules.get("service_radius_tiles", [])
	var radius := 0
	if level - 1 >= 0 and level - 1 < radii.size():
		radius = int(radii[level - 1])
	return {
		"id": kind,
		"archetype": kind,
		"variant": "",
		"component_kind": kind,
		"level": level,
		"category": CATEGORY_GRID,
		"name_key": BuildController.card_name_key(kind),
		"name_fallback": kind.capitalize(),
		"cost": cost,
		"cost_text": RequirementFormatter.money(cost),
		"footprint": Vector2i(foot, foot),
		"power_kw": 0.0,
		# A transformer has no demand — what the micro row must say about it is
		# what it *serves*. The sheet renders `power_text` verbatim, so the
		# sentence is resolved here, from the string table (G-8).
		"power_text": _t("ui_build_card_grid_micro", {"radius": radius},
				RequirementFormatter.tiles(radius)),
		"water_demand": 0.0,
		"min_city_level": 0,
		"locked": false,
		"affordable": sim == null or sim.treasury.balance >= cost,
		"service_radius_tiles": radius,
	}


func card(p_archetype: String, p_variant: String = "") -> Dictionary:
	var stats: Dictionary = sim.catalog.stats(p_archetype, 1)
	var foot: Array = stats.get("footprint", [1, 1])
	var required_level := int(stats.get("min_city_level", 0))
	var cost := sim.econ_curves.build_cost(p_archetype)
	var city_level := sim.progression.city_level
	return {
		"id": p_archetype if p_variant == "" else "%s_%s" % [p_archetype, p_variant],
		"archetype": p_archetype,
		"variant": p_variant,
		# Empty here, the kind on a grid card: one card shape, two commands.
		"component_kind": "",
		"category": sim.catalog.category(p_archetype),
		"name_key": BuildController.card_name_key(p_archetype, p_variant),
		"name_fallback": str(sim.catalog.archetype_info(p_archetype).get("name", p_archetype)),
		"cost": cost,
		"cost_text": RequirementFormatter.money(cost),
		"footprint": Vector2i(int(foot[0]), int(foot[1])),
		"power_kw": float(stats.get("power_demand_kw", 0.0)),
		"power_text": RequirementFormatter.power(stats.get("power_demand_kw", 0.0)),
		"water_demand": float(stats.get("water_demand", 0.0)),
		"min_city_level": required_level,
		"locked": required_level > city_level,
		"affordable": sim.treasury.balance >= cost,
	}


## G-8 key for a card's display name; `water_facility` variants keep the
## `ui_build_card_water_facility_<variant>` keys the string table already owns.
## `data/strings.en.json` through the formatter's config — the controller resolves
## the few sentences that belong to a card's *data* rather than to its layout.
func _t(key: String, args: Dictionary, fallback: String) -> String:
	var cfg: UIConfig = formatter.config if formatter != null else null
	if cfg != null and cfg.has_string(key):
		return cfg.t(key, args)
	return fallback


static func card_name_key(p_archetype: String, p_variant: String = "") -> String:
	if p_variant == "":
		return "ui_build_card_%s" % p_archetype
	return "ui_build_card_%s_%s" % [p_archetype, p_variant]


static func category_tab_key(category: String) -> String:
	return "ui_build_tab_%s" % category


static func _card_less(a: Dictionary, b: Dictionary) -> bool:
	var ia := CATEGORY_ORDER.find(str(a["category"]))
	var ib := CATEGORY_ORDER.find(str(b["category"]))
	if ia != ib:
		return ia < ib
	if int(a["cost"]) != int(b["cost"]):
		return int(a["cost"]) < int(b["cost"])
	return str(a["id"]) < str(b["id"])


# ===========================================================================
# Placement mode (doc 12 §2.7 S3)
# ===========================================================================

func is_placing() -> bool:
	return state == STATE_PLACING


## Enter placement mode for a card. Refuses an unknown archetype and a locked
## one — a locked card is not placeable at all, so the ghost never appears for
## it and the sheet shows the unlock condition instead (§2.7). Returns a
## `CommandQueue`-shaped `{ok, reason_code, payload}`.
func enter(p_archetype: String, p_variant: String = "") -> Dictionary:
	if is_grid_kind(p_archetype):
		return enter_component(p_archetype)
	if sim == null or not sim.catalog.has(p_archetype):
		cancel()
		return CommandQueue.fail(&"E_UNKNOWN_ARCHETYPE", {"archetype": p_archetype})
	var stats: Dictionary = sim.catalog.stats(p_archetype, 1)
	var required_level := int(stats.get("min_city_level", 0))
	if required_level > sim.progression.city_level:
		cancel()
		return CommandQueue.fail(&"E_CITY_LEVEL", {
			"required_level": required_level, "city_level": sim.progression.city_level,
			"archetype": p_archetype,
		})
	var foot: Array = stats.get("footprint", [1, 1])
	state = STATE_PLACING
	archetype = p_archetype
	variant = p_variant
	component_kind = ""
	component_level = GRID_CARD_LEVEL
	size = Vector2i(int(foot[0]), int(foot[1]))
	origin = Vector2i.ZERO
	has_origin = false
	_verdict = {}
	return CommandQueue.ok({"archetype": p_archetype, "variant": p_variant, "size": size})


## Placement mode for a grid component (doc 04 §2.1). Same state machine, same
## bar, same ghost — the only difference is which command the confirm button
## reaches, which is why `is_placing()` never has to be asked what it is placing.
func enter_component(kind: String, level: int = -1) -> Dictionary:
	if sim == null or not is_grid_kind(kind):
		cancel()
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT", {"archetype": kind})
	var rules := grid_rules(kind)
	var wanted := level if level > 0 else grid_level(kind)
	var levels: Array = rules.get("placeable_levels", [])
	var allowed := false
	for entry: Variant in levels:
		if int(entry) == wanted:
			allowed = true
			break
	if not allowed:
		cancel()
		return CommandQueue.fail(&"E_LEVEL_UNAVAILABLE",
				{"archetype": kind, "level": wanted})
	var foot := int(rules.get("footprint_tiles", 1))
	state = STATE_PLACING
	archetype = kind
	variant = ""
	component_kind = kind
	component_level = wanted
	size = Vector2i(foot, foot)
	origin = Vector2i.ZERO
	has_origin = false
	_verdict = {}
	return CommandQueue.ok({"archetype": kind, "component_kind": kind,
			"level": wanted, "size": size})


func is_placing_component() -> bool:
	return is_placing() and component_kind != ""


## Leaves placement mode. Idempotent — the Android back stack calls it blind.
func cancel() -> void:
	state = STATE_IDLE
	archetype = ""
	variant = ""
	component_kind = ""
	component_level = GRID_CARD_LEVEL
	size = Vector2i.ONE
	origin = Vector2i.ZERO
	has_origin = false
	_verdict = {}


## Move the ghost to a footprint origin (the tile `cmd_place_building` stamps
## from). Returns the fresh verdict.
func move_to_tile(tile: Vector2i) -> Dictionary:
	if not is_placing():
		return verdict()
	origin = tile
	has_origin = true
	_verdict = evaluate(origin)
	return _verdict


## Move the ghost to a ground-plane point (`CameraState.screen_to_ground()`).
## The footprint is centred on the pointed tile, so a 3×3 ghost does not hang
## down-right of the finger.
func move_to_ground(point: Vector3) -> Dictionary:
	return move_to_tile(origin_for_ground(point))


func origin_for_ground(point: Vector3) -> Vector2i:
	return BuildController.tile_at(point, tile_m) - centre_offset()


## Footprint centring offset — `(size - 1) / 2`, floored, so odd sizes centre
## exactly and even ones lean up-left.
func centre_offset() -> Vector2i:
	return Vector2i((size.x - 1) / 2, (size.y - 1) / 2)


static func tile_at(point: Vector3, p_tile_m: float = TILE_M_DEFAULT) -> Vector2i:
	var m := p_tile_m if p_tile_m > 0.0 else TILE_M_DEFAULT
	return Vector2i(int(floor(point.x / m)), int(floor(point.z / m)))


## World-space centre of a footprint, for the 3D ghost (`game/ui/ghost_view.gd`).
static func footprint_centre(p_origin: Vector2i, p_size: Vector2i,
		p_tile_m: float = TILE_M_DEFAULT) -> Vector3:
	var m := p_tile_m if p_tile_m > 0.0 else TILE_M_DEFAULT
	return Vector3(float(p_origin.x) * m + float(p_size.x) * m * 0.5, 0.0,
			float(p_origin.y) * m + float(p_size.y) * m * 0.5)


## The placement preflight. Runs `CitySim.cmd_place_building`'s checks in its
## order, reading only — **nothing is charged and nothing is stamped**. Returns
## `{verdict, code, failure, params}`; `failure` is `{}` when VALID.
func evaluate(p_origin: Vector2i) -> Dictionary:
	if sim == null or archetype == "":
		return _blocked(&"E_UNKNOWN_ARCHETYPE", {"archetype": archetype})
	if component_kind != "":
		return evaluate_component(p_origin)
	if not sim.catalog.has(archetype):
		return _blocked(&"E_UNKNOWN_ARCHETYPE", {"archetype": archetype})
	var block: LandBlock = sim.world.block_of_tile(p_origin.x, p_origin.y)
	if block == null or not block.is_owned():
		return _blocked(&"E_NOT_OWNED", {"tile": p_origin,
				"block_id": block.id if block != null else ""})
	if not block.is_ready():
		return _blocked(&"E_NOT_DEVELOPED", {"tile": p_origin, "block_id": block.id})
	if not sim.world.grid.can_place(p_origin, size):
		return _blocked(&"E_FOOTPRINT", {"tile": p_origin, "block_id": block.id})
	if not sim.grid.would_serve(p_origin):
		return _blocked(&"E_UNSERVED", {"tile": p_origin, "block_id": block.id})
	var cost := sim.econ_curves.build_cost(archetype)
	if sim.treasury.balance < cost:
		return _blocked(&"E_FUNDS", {"cost": cost, "balance": sim.treasury.balance,
				"tile": p_origin})
	return {
		"verdict": VERDICT_VALID,
		"code": &"",
		"failure": {},
		"params": {"cost": cost, "balance": sim.treasury.balance, "tile": p_origin},
	}


## The grid component's preflight. It does not re-implement doc 04's eight
## checks: it *asks* — `cmd_place_grid_component(preview = true)` runs the real
## order, charges nothing and returns the quote, so the ghost's verdict and the
## command's answer are the same code path rather than two copies of one rule.
func evaluate_component(p_origin: Vector2i) -> Dictionary:
	var preview := sim.cmd_place_grid_component(component_kind, p_origin,
			component_level, true)
	var payload: Dictionary = preview.get("payload", {})
	var params: Dictionary = {"tile": p_origin, "archetype": component_kind}
	params.merge(payload, true)
	if bool(preview["ok"]):
		params["balance"] = sim.treasury.balance
		return {"verdict": VERDICT_VALID, "code": &"", "failure": {}, "params": params}
	if payload.has("cost"):
		params["balance"] = sim.treasury.balance
	return _blocked(StringName(str(preview["reason_code"])), params)


func _blocked(code: StringName, params: Dictionary) -> Dictionary:
	var failure := formatter.format(code, params)
	return {
		"verdict": VERDICT_WARN if str(failure["severity"]) == String(
				RequirementFormatter.SEVERITY_WARN) else VERDICT_BLOCKED,
		"code": code,
		"failure": failure,
		"params": params,
	}


## Last computed verdict; `{}` before the ghost has been positioned.
func verdict() -> Dictionary:
	return _verdict


func can_confirm() -> bool:
	return is_placing() and has_origin \
			and str(_verdict.get("verdict", VERDICT_BLOCKED)) != String(VERDICT_BLOCKED)


## Doc 12 §2.7: "Placement is never committed on finger-up". This returns the
## `cmd_place_building` arguments; the caller submits them, so the pure logic
## never reaches into the sim's mutating half.
func confirm() -> Dictionary:
	if not is_placing():
		return CommandQueue.fail(&"E_STATE", {"state": String(state)})
	if not has_origin:
		return CommandQueue.fail(&"E_FOOTPRINT", {"archetype": archetype})
	if not can_confirm():
		var code: StringName = StringName(str(_verdict.get("code", &"E_FOOTPRINT")))
		return CommandQueue.fail(code, _verdict.get("params", {}))
	return CommandQueue.ok({
		"archetype": archetype,
		"origin": origin,
		"variant": variant,
		"component_kind": component_kind,
		"level": component_level,
		"cost": placement_cost(),
	})


## What the confirm button is about to spend. A building's cost is the archetype
## table's; a grid component's is the preview's quote, because it includes the
## feeder lateral the placement will have to build (doc 04 §2.1 / doc 03 §2.13b).
func placement_cost() -> int:
	if sim == null or archetype == "":
		return 0
	if component_kind == "":
		return sim.econ_curves.build_cost(archetype)
	var params: Variant = _verdict.get("params", {})
	if params is Dictionary and (params as Dictionary).has("cost"):
		return int((params as Dictionary)["cost"])
	return sim.econ_curves.grid_build_cost(component_kind, component_level,
			float(sim.treasury.difficulty().get("M_build", 1.0)))


## Submit the confirmed placement through `CitySim` and leave placement mode on
## success. The sim re-runs every check, so a stale verdict cannot slip through.
func commit() -> Dictionary:
	var args := confirm()
	if not bool(args["ok"]):
		return args
	var payload: Dictionary = args["payload"]
	var result: Dictionary
	if str(payload.get("component_kind", "")) != "":
		result = sim.cmd_place_grid_component(str(payload["component_kind"]),
				payload["origin"], int(payload["level"]))
	else:
		result = sim.cmd_place_building(str(payload["archetype"]),
				payload["origin"], str(payload["variant"]))
	if bool(result["ok"]):
		cancel()
	return result


## Everything the 3D ghost needs: where, how big, and which of the four data
## states tints it (§2.5 — colour is never the only channel; the bar carries the
## reason in words).
func ghost() -> Dictionary:
	var current := str(_verdict.get("verdict", VERDICT_BLOCKED))
	var state_token: StringName = HudModel.STATE_CRITICAL
	if current == String(VERDICT_VALID):
		state_token = HudModel.STATE_NORMAL
	elif current == String(VERDICT_WARN):
		state_token = HudModel.STATE_WARNING
	return {
		"visible": is_placing() and has_origin,
		"origin": origin,
		"size": size,
		"centre": BuildController.footprint_centre(origin, size, tile_m),
		"tile_m": tile_m,
		"verdict": current,
		"state": state_token,
	}


## What `ui/build_sheet.gd`'s placement bar binds.
func placement_view() -> Dictionary:
	var failure: Dictionary = _verdict.get("failure", {})
	var cost := placement_cost() if is_placing() else 0
	return {
		"active": is_placing(),
		"archetype": archetype,
		"variant": variant,
		"component_kind": component_kind,
		"name_key": BuildController.card_name_key(archetype, variant),
		"cost": cost,
		"cost_text": RequirementFormatter.money(cost),
		"verdict": str(_verdict.get("verdict", VERDICT_BLOCKED)),
		"can_confirm": can_confirm(),
		"issue_count": 0 if failure.is_empty() else 1,
		"failure": failure,
	}


# ===========================================================================
# Picking (doc 12 §2.16 — tap → 3D pick → building panel)
# ===========================================================================

## Reverse lookup: tile → `TileGrid.building_at` render id → sim id. Returns ""
## when the tile carries no building.
func sim_id_at_tile(tile: Vector2i) -> String:
	if sim == null or not TileGrid.in_bounds(tile.x, tile.y):
		return ""
	var grid_id := sim.world.grid.building_at(tile.x, tile.y)
	if grid_id <= 0:
		return ""
	for id: Variant in sim.buildings:
		if (sim.buildings[id] as Building).id == grid_id:
			return String(id)
	return ""


func sim_id_at_ground(point: Vector3) -> String:
	return sim_id_at_tile(BuildController.tile_at(point, tile_m))


# ===========================================================================
# Building panel view model (doc 12 §2.9)
# ===========================================================================

## Header + vitals + risk-free coverage tiles + the whole upgrade block. Plain
## data — `ui/building_panel.gd` binds it and computes nothing.
func building_view(sim_id: String) -> Dictionary:
	if sim == null or not sim.buildings.has(sim_id):
		return {"exists": false, "sim_id": sim_id}
	var b: Building = sim.buildings[sim_id]
	var type_id := String(b.archetype)
	var level := maxi(b.level, 1)
	var tax_per_hour := float(sim.econ_curves.base_tax(type_id, level))
	return {
		"exists": true,
		"sim_id": sim_id,
		"archetype": type_id,
		"variant": String(b.variant),
		"name_key": BuildController.card_name_key(type_id, String(b.variant)),
		"name_fallback": str(sim.catalog.archetype_info(type_id).get("name", type_id)),
		"category": sim.catalog.category(type_id),
		"level": b.level,
		"max_level": sim.catalog.max_level(),
		"state": b.state,
		"state_key": "ui_building_state_%s" % String(b.state),
		"condition": b.condition,
		"condition_text": RequirementFormatter.percent(b.condition),
		"origin": b.origin,
		"footprint": Vector2i(int((b.stats.get("footprint", [1, 1]) as Array)[0]),
				int((b.stats.get("footprint", [1, 1]) as Array)[1])),
		"vitals": [
			_vital("occupants", "ui_building_vital_occupants",
					HudModel.pop(int(b.stats.get("population", 0)))),
			_vital("jobs", "ui_building_vital_jobs",
					HudModel.pop(int(b.stats.get("jobs", 0)))),
			_vital("tax", "ui_building_vital_tax",
					HudModel.rate_per_day(tax_per_hour) if tax_per_hour > 0.0
					else HudModel.NO_DATA),
			_vital("power", "ui_building_vital_power",
					RequirementFormatter.power(b.stats.get("power_demand_kw", 0.0))),
			_vital("water", "ui_building_vital_water",
					RequirementFormatter.water_m3h(b.stats.get("water_demand", 0.0))),
			_vital("condition", "ui_building_vital_condition",
					RequirementFormatter.percent(b.condition)),
		],
		"coverage": _coverage(sim_id),
		"upgrade": upgrade_view(sim_id),
	}


static func _vital(id: String, label_key: String, value: String) -> Dictionary:
	return {"id": id, "label_key": label_key, "value": value}


## Four 40 dp tiles (§2.9 item 4). Only POWER is modelled in this slice; docs 05
## (water) and 06 (police/fire) have no per-building coverage query yet, so their
## tiles read OFFLINE with an em dash rather than an invented number — the same
## honesty rule the HUD's grid/water chips follow.
func _coverage(sim_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for slot: String in COVERAGE_SLOTS:
		var row := {
			"id": slot,
			"label_key": "ui_building_coverage_%s" % slot,
			"state": HudModel.STATE_OFFLINE,
			"value": HudModel.NO_DATA,
		}
		if slot == "power":
			var availability := sim.grid.power_availability_hour(sim_id)
			row["value"] = RequirementFormatter.percent(availability)
			row["state"] = _coverage_state(availability)
			row["attachment"] = sim.grid.attachment_of(sim_id)
		out.append(row)
	return out


static func _coverage_state(availability: float) -> StringName:
	if availability >= COVERAGE_NORMAL:
		return HudModel.STATE_NORMAL
	if availability >= COVERAGE_WARNING:
		return HudModel.STATE_WARNING
	return HudModel.STATE_CRITICAL


## The §2.9 upgrade block: target level, cost, and the **full** checklist —
## `cmd_upgrade_building(preview=true)` returns every blocker, and this fills in
## the passing rows so the player sees the whole gate, not just the first no.
func upgrade_view(sim_id: String) -> Dictionary:
	var preview := sim.cmd_upgrade_building(sim_id, true)
	var payload: Dictionary = preview.get("payload", {})
	var blockers: Array = payload.get("blockers", [])
	if not bool(preview["ok"]) and blockers.is_empty():
		# E_UNKNOWN_BUILDING and friends: no checklist to draw, one reason row.
		var only := formatter.format(preview["reason_code"], {"sim_id": sim_id})
		return {"available": false, "ok": false, "to_level": 0, "cost": 0,
				"cost_text": RequirementFormatter.money(0), "checklist": [only],
				"blocked_by": only, "reason": only}
	var b: Building = sim.buildings[sim_id]
	# Mirrors `CitySim.cmd_upgrade_building` exactly, `level == 0` (a build still
	# in progress) included, so the row numbers describe the gate that actually ran.
	var next_level: int = mini(b.level + 1, sim.catalog.max_level())
	var cost := int(payload.get("cost", 0))
	var checks := _checks_for(b, next_level)
	var rows := formatter.checklist(checks, blockers,
			{"cost": cost, "balance": sim.treasury.balance},
			_check_params(sim_id, b, next_level, payload))
	var blocked_by := RequirementFormatter.first_blocker(rows)
	return {
		"available": b.level < sim.catalog.max_level(),
		"ok": blockers.is_empty(),
		"to_level": next_level,
		"cost": cost,
		"cost_text": RequirementFormatter.money(cost),
		"deficit_kw": float(payload.get("deficit_kw", 0.0)),
		"checklist": rows,
		"blocked_by": blocked_by,
		"blocker_count": blockers.size(),
	}


## `E_AVENUE` is only a check from Level 4 (C-62); listing it below that would
## show the player a gate that cannot fire.
static func _checks_for(b: Building, next_level: int) -> Array[StringName]:
	var out: Array[StringName] = []
	for code: StringName in UPGRADE_CHECKS:
		if code == &"E_AVENUE" and next_level < AVENUE_FROM_LEVEL:
			continue
		out.append(code)
	return out


## Per-code parameters for the checklist. `cmd_upgrade_building` returns codes
## and totals only (the sim never returns display strings), so the numbers each
## row quotes are re-read from sim state here.
func _check_params(sim_id: String, b: Building, next_level: int,
		payload: Dictionary) -> Dictionary:
	var next_stats: Dictionary = sim.catalog.stats(String(b.archetype), next_level)
	var deficit := float(payload.get("deficit_kw", 0.0))
	var delta_kw := float(next_stats.get("power_demand_kw", 0.0)) \
			- float(b.stats.get("power_demand_kw", 0.0))
	var avenue_distance := nearest_avenue_tiles(b.origin)
	return {
		&"E_STATE": {"state": String(b.state), "required_state": "active",
				"fix_target_id": sim_id},
		&"E_MAX_LEVEL": {"level": b.level, "max_level": sim.catalog.max_level()},
		&"E_CONDITION": {"condition": b.condition,
				"min_condition": Building.MIN_CONDITION_TO_UPGRADE,
				"fix_target_id": sim_id},
		&"E_CITY_LEVEL": {"city_level": sim.progression.city_level,
				"required_level": int(next_stats.get("min_city_level", 0))},
		&"E_FUNDS": {"cost": int(payload.get("cost", 0)),
				"balance": sim.treasury.balance},
		&"E_POWER_HEADROOM": {
			"deficit_kw": deficit,
			"required_kw": delta_kw,
			"headroom_kw": maxf(0.0, delta_kw - deficit),
			"at": sim.grid.attachment_of(sim_id),
			"fix_target_id": sim.grid.attachment_of(sim_id),
		},
		&"E_AVENUE": {
			"avenue_distance_tiles": avenue_distance,
			"avenue_radius_tiles": AVENUE_RADIUS_TILES,
			"to_level": next_level,
			"tile": b.origin,
		},
	}


## Chebyshev distance in tiles from `p_origin` to the nearest AVENUE, searched
## outward and capped — the `{have}` figure of the C-62 message. Returns
## `AVENUE_SEARCH_TILES + 1` when none is in range.
func nearest_avenue_tiles(p_origin: Vector2i) -> int:
	for radius in range(0, AVENUE_SEARCH_TILES + 1):
		for z in range(p_origin.y - radius, p_origin.y + radius + 1):
			for x in range(p_origin.x - radius, p_origin.x + radius + 1):
				if maxi(absi(x - p_origin.x), absi(z - p_origin.y)) != radius:
					continue
				if TileGrid.in_bounds(x, z) \
						and sim.world.grid.road_class_at(x, z) == TileGrid.ROAD_AVENUE:
					return radius
	return AVENUE_SEARCH_TILES + 1


## The panel's `UPGRADE` button. Issues the real command (doc 12 §4.4) and hands
## back the sim's verdict so the view can refresh from truth, not from hope.
func upgrade(sim_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING", {"sim_id": sim_id})
	return sim.cmd_upgrade_building(sim_id)

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

## The two placement rosters the sheet lists beside the buildings — doc 04 §2.1's
## grid components (`data/grid_components.json`) and doc 05 §6's water components
## (`data/water.json` `placeable`). They share a tab because to the player they
## are one verb — "put a thing on a tile" — and because the two walls the city
## runs into, `E_UNSERVED` and `E_NO_MAIN`, are unanswerable without them.
const GRID_JSON_PATH := "res://data/grid_components.json"
const WATER_JSON_PATH := "res://data/water.json"
## Wave 5: the `grid` tab becomes `infrastructure` and carries both rosters.
const CATEGORY_INFRASTRUCTURE := "infrastructure"
## Which command a component card reaches. `""` on a building card.
const DOMAIN_GRID := "grid"
const DOMAIN_WATER := "water"
## The doc 02 shell every doc-05 variant is drawn as, so the water cards reuse
## the `ui_build_card_water_facility_<variant>` copy the string table has always
## carried and no new name key is invented here.
const WATER_SHELL_ARCHETYPE := "water_facility"
## The tutorial (doc 12 §2.17) and Wave 1.5 both ship exactly L1; the level a
## card offers is data (`placeable_levels`), never a constant here.
const GRID_CARD_LEVEL := 1

## Doc 02's upgrade gate, in the order `CitySim.cmd_upgrade_building` runs it.
## The checklist shows every row, passing ones included (doc 12 §2.9 item 5).
##
## **`E_WATER_HEADROOM` is the seventh** (Wave 18, PA-24). `cmd_upgrade_building`
## has appended it since doc 05's zones landed and this list never carried it, so
## a building blocked on water alone drew six green ticks, printed "Every
## requirement met." and left `UPGRADE` dead with nothing on screen to act on.
## `tests/test_build_controller.gd` now asserts this list against the codes the
## command can actually append, so the next gate doc 02 grows cannot ship silent.
const UPGRADE_CHECKS: Array[StringName] = [
	&"E_STATE", &"E_MAX_LEVEL", &"E_CONDITION", &"E_CITY_LEVEL", &"E_FUNDS",
	&"E_POWER_HEADROOM", &"E_WATER_HEADROOM", &"E_AVENUE",
]

## Doc 02 §8's `headroom_safety.power`, the factor `CitySim.cmd_upgrade_building`
## multiplies the kW delta by before it asks doc 04. Read from the catalog's own
## rules (PA-12); this is the fallback for a fixture whose rules carry no block.
const HEADROOM_MARGIN_DEFAULT := 1.15

## `E_AVENUE` only exists as a check from Level 4 up (C-62, hard gate L4/L5).
const AVENUE_FROM_LEVEL := 4
const AVENUE_RADIUS_TILES := 4
## How far the panel looks for the nearest avenue before it gives up and reports
## "beyond the search"; purely a display figure for the `{have}` parameter.
const AVENUE_SEARCH_TILES := 16
## The sentinel `nearest_avenue_tile` answers with when the search finds nothing
## — a tile no map has, so it can never be mistaken for a `Fix this →` target.
const NO_TILE := Vector2i(-1, -1)

## Sheet ordering: category first (the doc's tab order), then cost.
## `infrastructure` is last-but-one and `roads` is last for the same reason: they
## are the tabs you go to once something else has already said no —
## `E_UNSERVED` / `E_NO_MAIN` send you to one, `NO_ROAD` / `E_AVENUE` /
## `E_NOT_CONNECTED` send you to the other.
##
## `roads` is `PathTool.CATEGORY_ROADS` and is spelled as a literal here for the
## same reason it is spelled as a literal there: `PathTool` depends on this file
## and this file may not depend back. `tests/test_path_tool.gd` asserts the pair.
const CATEGORY_ORDER: Array[String] = [
	"residential", "commercial", "industrial", "service", "utility",
	CATEGORY_INFRASTRUCTURE, "roads",
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
## Set while the ghost is an infrastructure component rather than a building; it
## is the `kind` of `cmd_place_grid_component` / `cmd_place_water_component`, and
## "" for every building. `component_domain` says which of the two.
var component_kind := ""
var component_domain := ""
var component_level := GRID_CARD_LEVEL

## Doc 05 §6's node verbs (doc 93 §J1). Owned here rather than by the panel for
## the same reason every other view model on this class is: the panel binds, this
## computes, and `BuildingPanel` already holds exactly one controller.
var water: WaterActions

## Doc 04 §4's operating verbs (Wave 17, doc 93 §AD). Same ownership rule as
## `water` above: the panel binds, this computes, and the POWER section, the
## `Fix this →` strip and the dashboard's grid reading all read one model.
var power: PowerActions

## Doc 02 §2.9's coverage band ladder, borrowed from the overlay that already
## owns it (PA-22). Lazily made and kept, because `_coverage()` runs on every
## panel refresh and the bands come out of `data/ui.json`.
var _overlay: OverlayModel = null

## Wave 14's street roster — the thing a tap on a fleeing shoplifter or a loose
## dog has to find before it finds the house behind them.
##
## Deliberately an untyped `Object` and deliberately optional. The roster lives
## in `sim/` and this class must keep working in every build that does not have
## one yet: `street_roster()` takes this when the shell has bound one, otherwise
## asks the sim for `street` by name, and answers `null` rather than failing when
## neither exists. A build with no roster picks buildings and land exactly as it
## did before, which is also what makes the seam testable without a `CitySim`.
var street: Object = null

## The pick radius, in METRES, for the roster query — `tap_dp` converted at the
## camera's current zoom by `set_tap_radius_from()`. Zero disables the
## opportunity arm of the pick entirely, which is the state a shell that has not
## wired the conversion is in: no regression, just no street picks.
var tap_radius_m := 0.0

## `Callable(id: String) -> Dictionary`, overriding `sim.cmd_collect_opportunity`.
## Two reasons it exists, and both are about a seam that crosses two agents: the
## command's final name is the sim's to choose, and a pick that cannot be
## exercised without a whole `CitySim` is a pick with no unit test.
var collect_command := Callable()

var _verdict: Dictionary = {}
var _grid_placeable: Dictionary = {}
var _water_placeable: Dictionary = {}
var _water_components: Dictionary = {}


func _init(p_sim: CitySim = null, p_formatter: RequirementFormatter = null,
		p_tile_m: float = -1.0) -> void:
	sim = p_sim
	formatter = p_formatter if p_formatter != null else RequirementFormatter.load_from_files()
	tile_m = p_tile_m if p_tile_m > 0.0 else BuildController.load_tile_m()
	_grid_placeable = BuildController.load_grid_placeable()
	var water_roster := BuildController.load_water_placeable()
	_water_placeable = water_roster["placeable"]
	_water_components = water_roster["components"]
	water = WaterActions.new(sim, formatter)
	power = PowerActions.new(sim, formatter)


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


## `data/water.json`'s §6 roster plus the component table its footprints and kW
## come from. Doc 05's file carries no price either (its own C-07 guard), so a
## water card quotes doc 03 through `cmd_place_water_component`'s preview exactly
## as a grid card quotes it through doc 04's.
static func load_water_placeable() -> Dictionary:
	var empty := {"placeable": {}, "components": {}}
	if not FileAccess.file_exists(WATER_JSON_PATH):
		return empty
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(WATER_JSON_PATH))
	if not (parsed is Dictionary):
		return empty
	var data: Dictionary = parsed
	var placeable: Variant = data.get("placeable", {})
	var columns: Variant = data.get("_component_columns", {})
	var rows: Variant = data.get("components", {})
	if not (placeable is Dictionary) or not (columns is Dictionary) or not (rows is Dictionary):
		return empty
	# Zip the column names onto the rows, the same shape `WaterData` builds, so
	# the card can read `footprint_w` / `base_kw` by name.
	var components: Dictionary = {}
	for key: Variant in rows:
		var component_key := str(key)
		if not (columns as Dictionary).has(component_key):
			continue
		var names: Array = (columns as Dictionary)[component_key]
		var levels: Dictionary = {}
		for row: Variant in (rows as Dictionary)[component_key]:
			var values: Array = row
			if values.size() != names.size():
				continue
			var record: Dictionary = {}
			for i in names.size():
				record[str(names[i])] = values[i]
			levels[int(record.get("level", 0))] = record
		components[component_key] = levels
	return {"placeable": placeable, "components": components}


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
	for kind: Variant in water_kinds():
		out.append(water_card(String(kind)))
	out.sort_custom(BuildController._card_less)
	return out


## The placeable grid kinds, sorted so the sheet is deterministic.
func grid_kinds() -> Array[String]:
	return BuildController._roster_keys(_grid_placeable)


## The placeable doc-05 water kinds, same contract.
func water_kinds() -> Array[String]:
	return BuildController._roster_keys(_water_placeable)


## Roster keys, sorted, minus the `_note` documentation entries the data files
## carry (both rosters are self-documenting by design).
static func _roster_keys(roster: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for key: Variant in roster:
		var id := str(key)
		if not id.begins_with("_"):
			out.append(id)
	out.sort()
	return out


func is_grid_kind(id: String) -> bool:
	return _grid_placeable.has(id)


func is_water_kind(id: String) -> bool:
	return not id.begins_with("_") and _water_placeable.has(id)


func is_component_kind(id: String) -> bool:
	return is_grid_kind(id) or is_water_kind(id)


func water_rules(kind: String) -> Dictionary:
	var raw: Variant = _water_placeable.get(kind, {})
	return raw if raw is Dictionary else {}


## Doc 05's own key for a variant's component row (`source` splits on subtype).
func water_component_key(kind: String) -> String:
	if kind != "source":
		return kind
	return "source_well" if str(water_rules(kind).get("subtype", "river")) == "well" \
			else "source_river"


func water_row(kind: String, level: int) -> Dictionary:
	var levels: Variant = _water_components.get(water_component_key(kind), {})
	if not (levels is Dictionary):
		return {}
	var row: Variant = (levels as Dictionary).get(level, {})
	return row if row is Dictionary else {}


## Lowest level the water roster offers for a kind — the one the card places.
func water_level(kind: String) -> int:
	return BuildController._lowest_level(water_rules(kind))


func grid_rules(kind: String) -> Dictionary:
	var raw: Variant = _grid_placeable.get(kind, {})
	return raw if raw is Dictionary else {}


## Lowest level the roster offers for a kind — the one the card places.
func grid_level(kind: String) -> int:
	return BuildController._lowest_level(grid_rules(kind))


static func _lowest_level(rules: Dictionary) -> int:
	var levels: Array = rules.get("placeable_levels", [])
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
		"component_domain": DOMAIN_GRID,
		"level": level,
		"category": CATEGORY_INFRASTRUCTURE,
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


## A doc-05 water component's card. Same shape as a grid card, so `build_sheet`
## still renders one list; `component_domain` is what routes the tap into
## `cmd_place_water_component` instead of `cmd_place_grid_component`.
##
## Everything quoted is READ: the footprint and kW are doc 05's component row,
## the price is doc 03's through `CostCurves`, and the display name reuses the
## `ui_build_card_water_facility_<variant>` keys the string table already owns —
## the same names the authored `WTR-1` / `WTR-2` sites carry.
func water_card(kind: String) -> Dictionary:
	var level := water_level(kind)
	var row := water_row(kind, level)
	var size := Vector2i(int(row.get("footprint_w", 1)), int(row.get("footprint_h", 1)))
	var kw := float(row.get("base_kw", 0.0))
	var cost := 0
	var required_level := 0
	if sim != null:
		cost = sim.econ_curves.water_component_build_cost(
				sim.water.data.variant_cost_ratio(StringName(kind),
						str(water_rules(kind).get("subtype", ""))),
				level, float(sim.treasury.difficulty().get("M_build", 1.0)))
		required_level = int(sim.catalog.stats(WATER_SHELL_ARCHETYPE, level)
				.get("min_city_level", 0))
	return {
		"id": "%s_%s" % [WATER_SHELL_ARCHETYPE, kind],
		"archetype": kind,
		"variant": kind,
		"component_kind": kind,
		"component_domain": DOMAIN_WATER,
		"level": level,
		"category": CATEGORY_INFRASTRUCTURE,
		"name_key": BuildController.card_name_key(WATER_SHELL_ARCHETYPE, kind),
		"name_fallback": kind.capitalize(),
		"cost": cost,
		"cost_text": RequirementFormatter.money(cost),
		"footprint": size,
		"power_kw": kw,
		"power_text": RequirementFormatter.power(kw),
		"water_demand": 0.0,
		"min_city_level": required_level,
		"locked": sim != null and required_level > sim.progression.city_level,
		"affordable": sim == null or sim.treasury.balance >= cost,
		"service_radius_tiles": 0,
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
		# Empty here, the kind on a component card: one card shape, three
		# commands (building / grid component / water component).
		"component_kind": "",
		"component_domain": "",
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


## Sheet order: category (the doc's tab order), then **things before runs**, then
## **buys before sells**, then cost, then id.
##
## The two middle clauses are both about a price that is not comparable to the
## price beside it.
##
## **Runs sort after footprints** because a run card's `cost` is a price PER
## TILE and a footprint card's is a total, and §2.7's "then cost" was written
## before either kind of run card existed. Sorted together, `Feeder` at $110 a
## tile leads the INFRASTRUCTURE tab and `Transformer` at $500 falls to fourth —
## on the tab a player is sent to by `E_UNSERVED`, whose answer IS the
## transformer. Ordering by a number that means two different things is not an
## ordering, so the two kinds are ordered separately and each is sorted by its
## own price.
##
## **A card that pays sorts last** — exactly one card, `Remove`, doc 10 §2.13's
## road demolition. Sorted on price alone it leads the ROADS tab, because a card
## that pays $450 is the cheapest thing on it, and a tab whose first card is the
## destructive one teaches the wrong verb first. The rule is one sentence: **the
## sheet is a shop, and a card that pays is not a cheap purchase — it is not a
## purchase.**
static func _card_less(a: Dictionary, b: Dictionary) -> bool:
	var ia := CATEGORY_ORDER.find(str(a["category"]))
	var ib := CATEGORY_ORDER.find(str(b["category"]))
	if ia != ib:
		return ia < ib
	# `path_verb` is what `PathTool` stamps on a run card and what no footprint
	# card carries — the same discriminator `BuildSheet` routes a tap on.
	var pa := str(a.get("path_verb", "")) != ""
	var pb := str(b.get("path_verb", "")) != ""
	if pa != pb:
		return pb
	var ra := bool(a.get("refunds", false))
	var rb := bool(b.get("refunds", false))
	if ra != rb:
		return rb
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
	# A water card's `archetype` IS its doc-05 kind, so `enter("pump")` works;
	# `enter("water_facility", "pump")` — the shape a building card would use —
	# reaches the same place, which is what keeps the sheet's tap handler one line.
	if is_water_kind(p_archetype):
		return enter_water_component(p_archetype)
	# **And the BARE shell card reaches it too** (Wave 26, doc 93 §BA, doc 12
	# §2.7 D-120). `enter("water_facility")` with no variant used to fall through
	# to the plain building path, where the ghost ran doc 02's checks and the
	# confirm ran `cmd_place_building` — which stamped a water works that hosted
	# no doc-05 node and supplied nothing. Doc 02 authors this archetype's whole
	# level table on `reference_variant: "pump"` and doc 03 prices both at the
	# same $45,000 `water_plant` row, so the shell card with no variant IS the
	# pump card, and now says so. The ghost and the command are one code path
	# again: `E_NO_MAIN` is drawn before the player pays for it instead of after.
	if p_archetype == WATER_SHELL_ARCHETYPE:
		var wanted := p_variant if is_water_kind(p_variant) \
				else (sim.catalog.reference_water_variant() if sim != null else "")
		return enter_water_component(wanted)
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
	state = STATE_PLACING
	archetype = p_archetype
	variant = p_variant
	component_kind = ""
	component_domain = ""
	component_level = GRID_CARD_LEVEL
	# **The ghost shows the LOT** (Wave 29, doc 02 §2.3a, doc 12 D-128). §2.7's own
	# rule is that a ghost asks the command rather than re-implementing it, and
	# `cmd_place_building` now reserves `lot_for(archetype)` — so a store's ghost
	# is 2×2 from the first frame, which is both the ground it will take and the
	# ground the player is being asked to find.
	size = sim.lot_for(p_archetype)
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
	component_domain = DOMAIN_GRID
	component_level = wanted
	size = Vector2i(foot, foot)
	origin = Vector2i.ZERO
	has_origin = false
	_verdict = {}
	return CommandQueue.ok({"archetype": kind, "component_kind": kind,
			"domain": DOMAIN_GRID, "level": wanted, "size": size})


## Placement mode for a doc-05 water component (§6). Identical state machine to
## the grid one — the footprint just comes from doc 05's component table instead
## of doc 04's `footprint_tiles`, because a pump house is 3×3 and a tank is 2×2.
func enter_water_component(kind: String, level: int = -1) -> Dictionary:
	if sim == null or not is_water_kind(kind):
		cancel()
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT", {"archetype": kind})
	var rules := water_rules(kind)
	var wanted := level if level > 0 else water_level(kind)
	var allowed := false
	for entry: Variant in (rules.get("placeable_levels", []) as Array):
		if int(entry) == wanted:
			allowed = true
			break
	if not allowed:
		cancel()
		return CommandQueue.fail(&"E_LEVEL_UNAVAILABLE",
				{"archetype": kind, "level": wanted})
	var required_level := int(sim.catalog.stats(WATER_SHELL_ARCHETYPE, wanted)
			.get("min_city_level", 0))
	if required_level > sim.progression.city_level:
		cancel()
		return CommandQueue.fail(&"E_CITY_LEVEL", {
			"required_level": required_level, "city_level": sim.progression.city_level,
			"archetype": kind,
		})
	var row := water_row(kind, wanted)
	state = STATE_PLACING
	archetype = kind
	variant = kind
	component_kind = kind
	component_domain = DOMAIN_WATER
	component_level = wanted
	# The LOT, for `enter`'s reason — and doc 05's, per variant: a `treatment`
	# reserves the 3×3 it reaches at L2, not the 2×2 it opens on.
	size = sim.water_lot_for(kind)
	origin = Vector2i.ZERO
	has_origin = false
	_verdict = {}
	return CommandQueue.ok({"archetype": kind, "component_kind": kind,
			"domain": DOMAIN_WATER, "level": wanted, "size": size})


func is_placing_component() -> bool:
	return is_placing() and component_kind != ""


func is_placing_water() -> bool:
	return is_placing() and component_domain == DOMAIN_WATER


## Leaves placement mode. Idempotent — the Android back stack calls it blind.
func cancel() -> void:
	state = STATE_IDLE
	archetype = ""
	variant = ""
	component_kind = ""
	component_domain = ""
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
	if component_domain == DOMAIN_WATER:
		return evaluate_water_component(p_origin)
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
	var serve := sim.serving_headroom_for_new(archetype, p_origin)
	if String(serve["reason"]) == "UNSERVED":
		return _blocked(&"E_UNSERVED", {"tile": p_origin, "block_id": block.id})
	var cost := sim.econ_curves.build_cost(archetype)
	if sim.treasury.balance < cost:
		return _blocked(&"E_FUNDS", {"cost": cost, "balance": sim.treasury.balance,
				"tile": p_origin})
	var params := {"cost": cost, "balance": sim.treasury.balance, "tile": p_origin}
	if not bool(serve["ok"]):
		# The audit's P0 (doc 93 §AD3): coverage was the only power question
		# placement asked, so a GREEN ghost could put a 98 kW water facility on a
		# 50 kW pole-top that was already full, and the first the player heard of
		# it was the whole street browning out at dinner. Amber, not red: doc 04
		# §2.1 gates placement on coverage and authorises no capacity refusal, so
		# this reports the fact and lets the player place anyway — which is also
		# why it is evaluated LAST, after every real blocker has had its turn.
		params.merge({"component": String(serve["at"]), "transformer":
				String(serve["transformer"]), "need": float(serve["demand_kw"]),
				"deficit_kw": float(serve["deficit_kw"]),
				"ratio": float(serve["r_after"])}, true)
		return {
			"verdict": VERDICT_WARN,
			"code": &"E_TRANSFORMER_FULL",
			"failure": formatter.format(&"E_TRANSFORMER_FULL", params),
			"params": params,
		}
	return {
		"verdict": VERDICT_VALID,
		"code": &"",
		"failure": {},
		"params": params,
	}


## The grid component's preflight. It does not re-implement doc 04's eight
## checks: it *asks* — `cmd_place_grid_component(preview = true)` runs the real
## order, charges nothing and returns the quote, so the ghost's verdict and the
## command's answer are the same code path rather than two copies of one rule.
func evaluate_component(p_origin: Vector2i) -> Dictionary:
	return _component_verdict(p_origin, sim.cmd_place_grid_component(component_kind,
			p_origin, component_level, true))


## The water twin, and for the same reason: `cmd_place_water_component(preview =
## true)` runs doc 05 §6's twelve checks in their order, charges nothing and
## returns the quote — so the ghost's verdict and the command's answer are one
## code path rather than two copies of one rule.
func evaluate_water_component(p_origin: Vector2i) -> Dictionary:
	return _component_verdict(p_origin, sim.cmd_place_water_component(component_kind,
			p_origin, component_level, true))


func _component_verdict(p_origin: Vector2i, preview: Dictionary) -> Dictionary:
	var payload: Dictionary = preview.get("payload", {})
	var params: Dictionary = {"tile": p_origin, "archetype": component_kind}
	params.merge(payload, true)
	if bool(preview["ok"]):
		params["balance"] = sim.treasury.balance
		# **Amber, not green** (Wave 28 fix, doc 91 A91-D-153). Doc 93 §AD3's P0
		# for a water site: the command allows it — doc 04 §2.1 authorises no
		# capacity refusal — and the ghost has to say that the transformer
		# reaching this tile cannot carry it, or the player buys a pump that runs
		# at `power_fraction 0.00`. Same code, same severity and same `Fix this →`
		# the building path has used since Wave 12.
		if payload.has("power_ok") and not bool(payload["power_ok"]):
			params["need"] = float(payload.get("kw_required", 0.0))
			return {
				"verdict": VERDICT_WARN,
				"code": &"E_TRANSFORMER_FULL",
				"failure": formatter.format(&"E_TRANSFORMER_FULL", params),
				"params": params,
			}
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
		"component_domain": component_domain,
		"level": component_level,
		"cost": placement_cost(),
	})


## What the confirm button is about to spend. A building's cost is the archetype
## table's; a component's is the preview's quote, because it includes the run of
## line the placement will have to build — a feeder lateral for a transformer
## (doc 04 §2.1 / doc 03 §2.13b), a service main for a water site (doc 05 §2.2 /
## doc 03 §8 `water`). That run is the interesting half of both decisions.
func placement_cost() -> int:
	if sim == null or archetype == "":
		return 0
	if component_kind == "":
		return sim.econ_curves.build_cost(archetype)
	var params: Variant = _verdict.get("params", {})
	if params is Dictionary and (params as Dictionary).has("cost"):
		return int((params as Dictionary)["cost"])
	var m_build := float(sim.treasury.difficulty().get("M_build", 1.0))
	if component_domain == DOMAIN_WATER:
		return sim.econ_curves.water_component_build_cost(
				sim.water.data.variant_cost_ratio(StringName(component_kind),
						str(water_rules(component_kind).get("subtype", ""))),
				component_level, m_build)
	return sim.econ_curves.grid_build_cost(component_kind, component_level, m_build)


## Submit the confirmed placement through `CitySim` and leave placement mode on
## success. The sim re-runs every check, so a stale verdict cannot slip through.
func commit() -> Dictionary:
	var args := confirm()
	if not bool(args["ok"]):
		return args
	var payload: Dictionary = args["payload"]
	var result: Dictionary
	match str(payload.get("component_domain", "")):
		DOMAIN_WATER:
			result = sim.cmd_place_water_component(str(payload["component_kind"]),
					payload["origin"], int(payload["level"]))
		DOMAIN_GRID:
			result = sim.cmd_place_grid_component(str(payload["component_kind"]),
					payload["origin"], int(payload["level"]))
		_:
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
# ===========================================================================
# STEP ONE — "where CAN this go?" (Wave 28 fix; doc 12 D-127, doc 93 §BD8)
# ===========================================================================
#
# The player, 2026-09-05, first sentence: *"we need to be able to create a water
# source"*. Driven on his own device save, the card enters fine and then there is
# **no legal tile within forty tiles of his plant** — 2,140 refusals for land he
# does not own, 1,092 for a footprint that does not fit, 486 for an intake off
# the shoreline. Every one of those refusals was correct and every one of them
# was *invisible*, because a ghost answers exactly one tile at a time and the
# question "where can this go" is a question about a SET.
#
# This is the missing read. It is the same `evaluate()` the ghost runs, run over
# a window instead of a point, and it answers three things a ghost cannot:
#
#   1. **Which tiles CAN host it** — the set the shell paints under the ghost.
#   2. **What is in the way, over the whole window** — a histogram, which is what
#      turns "nowhere" into "you do not own the land".
#   3. **What to buy first** — the cheapest single purchase that turns some tile
#      in the window legal, as a `fix_target` the existing router already
#      resolves (`FIX_BLOCK` → the land panel, `FIX_TILE` → the camera).
#
# It reads and charges nothing: every verdict is a `preview = true` quote.

## How wide a window `placement_sites()` scans when the caller does not say, and
## how many origins it hands back. Both are LAYOUT/effort numbers rather than
## rules, so they live in `data/ui.json.placement` with these as the fallback.
const SITE_SCAN_RADIUS_DEFAULT := 10
const SITE_ROWS_DEFAULT := 32
## The hard ceiling on one scan, whatever the caller asks for: 41×41. A window
## this size is already 1,681 previews, and the honest answer past it is "look
## somewhere else", not a longer wait on a phone.
const SITE_SCAN_RADIUS_MAX := 20

## The blockers TIME OR MONEY clears. A tile whose refusals are a subset of these
## is not an illegal site — it is a site the player has not bought yet, and that
## distinction is the whole difference between "nowhere" and "buy D3".
##
## `E_AUSTERITY` is in the list and is the one that surprised: on the player's
## own save THREE tiles by the river refuse for nothing else at all. Doc 03
## §2.10 layer 2 freezes every `construction` spend while the balance is under
## water, the save restores the flag verbatim, and the first hourly settlement
## after the load lifts it at his $14.9M — so his step one was one game-hour
## away and no screen said so.
const SITE_BUYABLE_BLOCKERS := [&"E_NOT_OWNED", &"E_NOT_DEVELOPED", &"E_FUNDS",
		&"E_AUSTERITY"]
## Cheapest remedy first, so the advice names the smallest thing that works. A
## tile waiting on the treasury is a better answer than a tile waiting on a land
## purchase, and a purchase is a better answer than six phases of development.
const SITE_REMEDY_RANK := {&"E_AUSTERITY": 0, &"E_FUNDS": 1,
		&"E_NOT_DEVELOPED": 2, &"E_NOT_OWNED": 3}


func site_scan_radius() -> int:
	var cfg: UIConfig = formatter.config if formatter != null else null
	var placement: Dictionary = cfg.section("placement") if cfg != null else {}
	return clampi(int(UIConfig.get_num(placement, "site_scan_radius_tiles",
			SITE_SCAN_RADIUS_DEFAULT)), 1, SITE_SCAN_RADIUS_MAX)


func site_rows() -> int:
	var cfg: UIConfig = formatter.config if formatter != null else null
	var placement: Dictionary = cfg.section("placement") if cfg != null else {}
	return maxi(1, int(UIConfig.get_num(placement, "site_rows", SITE_ROWS_DEFAULT)))


## The set, the histogram and the advice. `centre` defaults to wherever the ghost
## is standing; `radius` and `limit` to `data/ui.json.placement`.
##
## Returns `{ok, kind, centre, radius, scanned, tiles, count, nearest,
## nearest_distance, cost, reasons, advice}`. `advice` is
## `{key, args, fix_target, cost}` — a string KEY and its arguments, never a
## sentence, and a `fix_target` in `RequirementFormatter`'s own shape so the
## placement bar's `FIX THIS →` can carry it without a second router.
func placement_sites(centre: Vector2i = Vector2i(-1, -1), radius: int = -1,
		limit: int = -1) -> Dictionary:
	var out := {"ok": false, "kind": component_kind if component_kind != "" else archetype,
			"centre": centre, "radius": 0, "scanned": 0,
			"tiles": [] as Array[Vector2i], "count": 0, "clean": 0, "warned": false,
			"nearest": Vector2i(-1, -1), "nearest_distance": -1, "cost": 0,
			"reasons": {}, "advice": _site_advice_none()}
	if sim == null or not is_placing():
		return out
	var home := centre
	if not TileGrid.in_bounds(home.x, home.y):
		home = origin if has_origin else _site_home()
	var reach := clampi(radius if radius > 0 else site_scan_radius(),
			1, SITE_SCAN_RADIUS_MAX)
	var rows := limit if limit > 0 else site_rows()
	out["centre"] = home
	out["radius"] = reach

	# The scan. `evaluate()` is the ghost's own preflight, so a tile in `tiles`
	# is a tile the ghost will tint green when the finger reaches it — the two
	# can never disagree, because they are one call.
	var legal: Array = []            # [[distance, y, x, cost], …]
	var buyable: Array = []          # [[distance, y, x, block_id, blockers], …]
	var reasons: Dictionary = {}
	var scanned := 0
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var tile := Vector2i(home.x + dx, home.y + dy)
			if not TileGrid.in_bounds(tile.x, tile.y):
				continue
			scanned += 1
			var verdict := evaluate(tile)
			var distance := maxi(absi(dx), absi(dy))
			if String(verdict["verdict"]) != String(VERDICT_BLOCKED):
				# A WARN site is legal and the command will take it, but it is
				# not the site to recommend: on the player's save the nearest
				# pump site was one whose pole-top could not carry the pump
				# (`E_TRANSFORMER_FULL`), and "nearest" would have sold him a
				# pump at `power_fraction 0.00`. Clean sites sort first; warned
				# ones stay in the set, behind them.
				var params: Dictionary = verdict.get("params", {})
				var warned := 1 if String(verdict["verdict"]) == String(VERDICT_WARN) else 0
				legal.append([warned, distance, tile.y, tile.x,
						int(params.get("cost", 0))])
				continue
			var code := StringName(str(verdict.get("code", &"")))
			reasons[code] = int(reasons.get(code, 0)) + 1
			var blockers := _site_blockers(verdict)
			if _site_is_buyable(blockers):
				var block: LandBlock = sim.world.block_of_tile(tile.x, tile.y)
				# **The refused tile's own price** (Wave 30, `A91-D-163`). The
				# quote that said `E_FUNDS` knows exactly what it would have
				# charged HERE — 38,086 for a source with a one-tile lateral,
				# where the card's headline is 37,800 — and `out["cost"]` is
				# written only when something was legal, so the funds sentence
				# used to read "it costs $0" at the very moment the player was
				# being told they could not afford it. One quote, one price.
				var quoted: Dictionary = verdict.get("params", {}) as Dictionary
				buyable.append([_site_remedy_rank(blockers), distance, tile.y,
						tile.x, block.id if block != null else "", blockers,
						int(quoted.get("cost", 0))])
	# **Nothing above moved the ghost.** `evaluate(tile)` takes the origin as an
	# argument and reads `origin` for nothing, so this whole scan is a read —
	# which is the property that lets the placement bar call it mid-drag.
	legal.sort()
	buyable.sort()
	out["scanned"] = scanned
	out["reasons"] = reasons
	out["count"] = legal.size()
	var tiles: Array[Vector2i] = []
	var clean := 0
	for entry: Variant in legal:
		if int((entry as Array)[0]) == 0:
			clean += 1
		if tiles.size() >= rows:
			continue
		tiles.append(Vector2i(int((entry as Array)[3]), int((entry as Array)[2])))
	out["tiles"] = tiles
	out["clean"] = clean
	if not legal.is_empty():
		var first: Array = legal[0]
		out["ok"] = true
		out["warned"] = int(first[0]) == 1
		out["nearest"] = Vector2i(int(first[3]), int(first[2]))
		out["nearest_distance"] = int(first[1])
		out["cost"] = int(first[4])
	out["advice"] = _site_advice(out, buyable)
	return out


## Everything the window refused this tile for, not just the first. The water and
## grid commands publish the whole list in `payload.blockers`; a plain building's
## `_blocked` publishes one code, so that is the list.
func _site_blockers(verdict: Dictionary) -> Array:
	var params: Dictionary = verdict.get("params", {})
	var listed: Array = params.get("blockers", []) as Array
	if not listed.is_empty():
		var out: Array = []
		for entry: Variant in listed:
			out.append(StringName(str(entry)))
		return out
	return [StringName(str(verdict.get("code", &"")))]


static func _site_is_buyable(blockers: Array) -> bool:
	if blockers.is_empty():
		return false
	for entry: Variant in blockers:
		if not SITE_BUYABLE_BLOCKERS.has(StringName(str(entry))):
			return false
	return true


## The most expensive remedy this tile needs — the one the advice has to name.
static func _site_remedy_rank(blockers: Array) -> int:
	var worst := 0
	for entry: Variant in blockers:
		worst = maxi(worst, int(SITE_REMEDY_RANK.get(StringName(str(entry)), 0)))
	return worst


## Where to look when the player has not put the ghost down yet: the city's own
## water works if it has one (a second source belongs near the first main), else
## the first owned block, else the middle of the map.
func _site_home() -> Vector2i:
	if sim == null:
		return Vector2i(TileGrid.SIZE / 2, TileGrid.SIZE / 2)
	if component_domain == DOMAIN_WATER and sim.water != null:
		var keys := sim.water.nodes.keys()
		keys.sort()
		for key: Variant in keys:
			return (sim.water.nodes[key] as WaterNode).tile
	for raw: Variant in sim.world.block_ids_sorted():
		var block: LandBlock = sim.world.block(String(raw))
		if block != null and block.is_owned():
			# The block's own centre tile: doc 09's blocks are 16×16 and
			# `TileGrid.block_of` is the inverse of this arithmetic.
			return block.grid * TileGrid.TILES_PER_BLOCK \
					+ Vector2i(TileGrid.TILES_PER_BLOCK / 2, TileGrid.TILES_PER_BLOCK / 2)
	return Vector2i(TileGrid.SIZE / 2, TileGrid.SIZE / 2)


static func _site_advice_none() -> Dictionary:
	return {"key": "", "args": {}, "fix_target": {}, "cost": 0}


## **What to buy first.** Five answers, in the order a player can act on them.
func _site_advice(found: Dictionary, buyable: Array) -> Dictionary:
	var kind_key := "ui_build_card_%s_%s" % [WATER_SHELL_ARCHETYPE, String(found["kind"])] \
			if component_domain == DOMAIN_WATER \
			else BuildController.card_name_key(archetype, variant)
	var base := {"kind": kind_key, "radius": int(found["radius"]),
			"count": int(found["count"])}
	# 1. There ARE sites: say how many and how far, so the player stops hunting.
	if bool(found["ok"]):
		var args := base.duplicate()
		args["tiles"] = str(int(found["nearest_distance"]))
		args["cost"] = RequirementFormatter.money(int(found["cost"]))
		return {"key": "ui_site_found", "args": args, "cost": int(found["cost"]),
				"fix_target": {"kind": RequirementFormatter.FIX_TILE,
						"id": "%d,%d" % [int(found["nearest"].x), int(found["nearest"].y)],
						"params": {"tile": found["nearest"]}}}
	# 2. There is a site TIME OR MONEY would open. This is the player's own case
	#    twice over: 2,140 of his 3,721 tiles refuse for `E_NOT_OWNED` alone, and
	#    three tiles by his river refuse for `E_AUSTERITY` and nothing else.
	if not buyable.is_empty():
		var best: Array = buyable[0]
		var distance := int(best[1])
		var tile := Vector2i(int(best[3]), int(best[2]))
		var block_id := String(best[4])
		var blockers: Array = best[5]
		var args := base.duplicate()
		args["at"] = block_id
		args["tiles"] = str(distance)
		var here := {"kind": RequirementFormatter.FIX_TILE,
				"id": "%d,%d" % [tile.x, tile.y], "params": {"tile": tile}}
		# 2a. Nothing but doc 03 §2.10's spending freeze. The site is READY.
		if blockers.has(&"E_AUSTERITY"):
			args["count"] = buyable.size()
			return {"key": "ui_site_austerity", "args": args, "cost": 0,
					"fix_target": here}
		# 2b. Nothing but the price of the thing itself. The price is the one
		#     THAT TILE was quoted (`A91-D-163`); `found["cost"]` is the cheapest
		#     LEGAL site's, and in this branch there are none, so it is zero.
		if blockers.has(&"E_FUNDS"):
			var quoted := int(best[6])
			args["cost"] = RequirementFormatter.money(quoted)
			args["have"] = RequirementFormatter.money(sim.treasury.balance)
			return {"key": "ui_site_funds", "args": args, "cost": quoted,
					"fix_target": here}
		var owned := not blockers.has(&"E_NOT_OWNED")
		var quote := sim.cmd_buy_block(block_id, true) if not owned \
				else sim.cmd_start_development(block_id, true)
		var payload: Dictionary = quote.get("payload", {})
		var price := int(payload.get("price", payload.get("phase_cost", 0)))
		args["cost"] = RequirementFormatter.money(price)
		return {"key": "ui_site_buy_block" if not owned else "ui_site_develop_block",
				"args": args, "cost": price,
				"fix_target": {"kind": RequirementFormatter.FIX_BLOCK, "id": block_id,
						"params": {"block_id": block_id, "tile": tile}}}
	# 3. A river intake with no shoreline in the window. Doc 05 §6's own rule,
	#    and the only refusal in the set that no purchase answers — the answer is
	#    a place, so the advice IS a place.
	var reasons: Dictionary = found["reasons"]
	if int(reasons.get(&"E_NO_WATER", 0)) > 0:
		var shore := _nearest_water_tile(found["centre"])
		var args := base.duplicate()
		args["tiles"] = str(int(shore.get("distance", -1)))
		args["at"] = "%d, %d" % [int(shore.get("tile", Vector2i.ZERO).x),
				int(shore.get("tile", Vector2i.ZERO).y)]
		return {"key": "ui_site_no_shoreline", "args": args, "cost": 0,
				"fix_target": {} if shore.is_empty() \
						else {"kind": RequirementFormatter.FIX_TILE,
								"id": args["at"], "params": {"tile": shore["tile"]}}}
	# 4. Nothing in reach has power. Doc 04 §2.1 gates every placement on a
	#    transformer reaching the site, and the answer is a transformer — the
	#    other card on the same Infrastructure tab, which is why this is worth a
	#    sentence of its own rather than "try somewhere else".
	if int(reasons.get(&"E_UNSERVED", 0)) > 0 \
			and int(reasons.get(&"E_UNSERVED", 0)) >= int(reasons.get(&"E_NO_MAIN", 0)):
		var args := base.duplicate()
		return {"key": "ui_site_unserved", "args": args, "cost": 0, "fix_target": {}}
	# 5. Everything in reach is outside a main's tap radius: the answer is a run
	#    of pipe, which is `PathTool`'s verb and not a tile.
	if int(reasons.get(&"E_NO_MAIN", 0)) > 0:
		var args := base.duplicate()
		args["need"] = str(int(sim.water.data.placement_value(
				"main_tap_radius_tiles", 8))) if sim.water != null else "8"
		return {"key": "ui_site_no_main", "args": args, "cost": 0, "fix_target": {}}
	# 6. Nothing here, and nothing here can be unblocked. Say so rather than
	#    leave the player scrubbing a red ghost across the map.
	return {"key": "ui_site_none", "args": base, "cost": 0, "fix_target": {}}


## The nearest doc-09 water tile to `from`, searched over the whole map — this
## runs only on the refusal path, at most once per placement session.
func _nearest_water_tile(from: Vector2i) -> Dictionary:
	if sim == null:
		return {}
	var best := Vector2i.ZERO
	var best_d := 1 << 30
	for y in range(TileGrid.SIZE):
		for x in range(TileGrid.SIZE):
			if not sim.world.grid.has_flag(x, y, TileGrid.FLAG_WATER):
				continue
			var d: int = maxi(absi(from.x - x), absi(from.y - y))
			if d < best_d:
				best_d = d
				best = Vector2i(x, y)
	if best_d == 1 << 30:
		return {}
	return {"tile": best, "distance": best_d}


func placement_view() -> Dictionary:
	var failure: Dictionary = _verdict.get("failure", {})
	var cost := placement_cost() if is_placing() else 0
	return {
		"active": is_placing(),
		"archetype": archetype,
		"variant": variant,
		"component_kind": component_kind,
		"component_domain": component_domain,
		"name_key": BuildController.card_name_key(WATER_SHELL_ARCHETYPE, component_kind) \
				if component_domain == DOMAIN_WATER \
				else BuildController.card_name_key(archetype, variant),
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


## The land half of the same tap (doc 12 §2.8). A tap that misses every building
## still landed *somewhere*, and doc 09's map can say which 16×16 block that was.
## Returns "" only for a point outside the map.
func block_id_at_tile(tile: Vector2i) -> String:
	if sim == null or not TileGrid.in_bounds(tile.x, tile.y):
		return ""
	var block := sim.world.block_of_tile(tile.x, tile.y)
	return block.id if block != null else ""


func block_id_at_ground(point: Vector3) -> String:
	return block_id_at_tile(BuildController.tile_at(point, tile_m))


## Pick kinds — the answer `pick_at_ground` gives the shell's tap handler.
const PICK_NONE := &"none"
const PICK_BUILDING := &"building"
const PICK_BLOCK := &"block"
## Wave 14. A collectable thing standing on the street, not a thing built on it.
const PICK_OPPORTUNITY := &"opportunity"
## Wave 25 (report 98 §68 RR-207, doc 93 §AY2). A `PowerGrid` component the
## player can tap — a transformer pad today, which is the only grid component
## `PowerInfraView` draws as an object standing on a tile.
const PICK_COMPONENT := &"component"

## The grid kinds a tap may select. A feeder and a transmission line are drawn as
## a ROUTE and have no tile to measure a radius from; a substation and a plant
## are BUILDINGS (report 98 C-30) and are already picked as one, so admitting
## them here would give one object two pick kinds.
const PICKABLE_COMPONENT_KINDS: Array[StringName] = [&"transformer"]

## How far from a pad's tile centre a tap may land and still select it, as a
## fraction of a tile — half, because that is the edge of the tile the pad
## stands on. See `component_near` for why this is a CAP on the finger radius
## rather than a radius of its own.
const COMPONENT_PICK_TILE_FRACTION := 0.5

## `data/ui.json.street.tap_dp`, and the fallback for a malformed file. The path
## is `UIConfig`'s own — a second copy of it here is a second thing to rename.
const TAP_DP_DEFAULT := 48.0
## The verb the roster is asked for, and the command a pick reaches. Named
## constants because both are the seam to a system this file does not import.
const STREET_QUERY := "opportunity_near"
const STREET_COMMAND := "cmd_collect_opportunity"
## What a refusal says when the sim in this build has no collect verb at all —
## distinguishable from "you were too late", which is a real refusal with copy.
const E_NO_COMMAND := &"E_NO_COMMAND"

## Parsed once per process: `pick_at_ground` runs on a finger and every
## `BuildController` in the test suite would otherwise re-read a 1,100-line
## file to learn one number.
static var _street_cfg: Dictionary = {}
static var _street_cfg_read := false


## `data/ui.json.street`, or `{}`. Same degrade-loudly contract as `load_tile_m`.
static func street_config() -> Dictionary:
	if _street_cfg_read:
		return _street_cfg
	_street_cfg_read = true
	if not FileAccess.file_exists(UIConfig.UI_JSON_PATH):
		return _street_cfg
	var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(UIConfig.UI_JSON_PATH))
	if not (parsed is Dictionary):
		return _street_cfg
	var block: Variant = (parsed as Dictionary).get("street", {})
	if block is Dictionary:
		_street_cfg = block
	return _street_cfg


static func tap_dp() -> float:
	return UIConfig.get_num(BuildController.street_config(), "tap_dp", TAP_DP_DEFAULT)


## **48 dp of finger, in metres, at the zoom the player is actually at.** The
## whole reason this conversion exists in the shell rather than as a constant:
## measured on a 412 × 915 dp display (doc 92 §38.3), the same 48 dp is **0.69 m**
## of ground at `zoom_t = 0`, **2.58 m** at the default 0.42 and **16.04 m** at
## full zoom-out — a factor of 23. Any radius authored in metres is wrong at one
## end of that range by more than an order of magnitude.
## `CameraState.m_per_dp(viewport)` is the one number that carries both the
## distance and the FOV, so it is the one number the shell passes.
##
## Returns the radius it set, so a caller can assert on it.
func set_tap_radius_from(m_per_dp: float, dp: float = -1.0) -> float:
	var want := dp if dp > 0.0 else BuildController.tap_dp()
	tap_radius_m = maxf(0.0, m_per_dp) * want
	return tap_radius_m


## The nearest pickable grid component within `radius_m` of `point`, as
## `{id, kind, tile, world_pos, distance_m}`, or `{}` (Wave 25, RR-207).
##
## **A radius from the tapped POINT to the pad's TILE CENTRE**, not a tile test,
## because the pad is a 2.4 × 2.0 m cabinet inside an 8 m tile: a finger 48 dp
## wide over the cabinet must catch the cabinet, and a tile test would answer
## for the whole tile. (Measured at the Wave 25 merge: no pad in the founding
## city or the bench city stands on a tile a building occupies — 0 of 18 and
## 0 of 144 — so the ordering below costs no building a tap; it is there so
## the smaller object wins IF the two ever share a tile.) The radius is
## `tap_radius_m` — the same 48 dp of finger
## `set_tap_radius_from` converts for the street collectable — so a player who
## has zoomed out until the pad is four pixels across gets a proportionally
## wider catch, and one zoomed all the way in has to be on it.
##
## The scan is over `component_ids_of_kind(&"transformer")` and nothing else: a
## line has a route, not a tile, and would answer `Vector2i.ZERO` for every
## query. Ties are broken by distance and then by id, so two pads on adjacent
## tiles resolve the same way on every machine.
func component_near(point: Vector3, radius_m: float = -1.0) -> Dictionary:
	var radius := radius_m if radius_m >= 0.0 else tap_radius_m
	# **Capped at half a tile, and the cap is the whole safety argument.** A
	# transformer stands on ONE tile; a tap more than half a tile from its centre
	# is not on it. Without the cap this pick out-ranks the building at every
	# zoom the street collectable was designed for — 48 dp is 16.04 m of ground
	# at full zoom-out (doc 92 §38.3), two tiles in every direction — so a tap
	# squarely on a house would open the transformer next door. The dog gets to
	# do that because a dog is leaving; a transformer is not.
	#
	# Derived from `tile_m`, not authored: it is "the pad's own tile, with a
	# finger's tolerance inside it". At the default camera height the finger is
	# 2.581 m and the cap never binds (doc 92 §65.3).
	radius = minf(radius, tile_m * COMPONENT_PICK_TILE_FRACTION)
	if radius <= 0.0 or sim == null or sim.grid == null:
		return {}
	var best: Dictionary = {}
	var best_d := radius
	for kind in PICKABLE_COMPONENT_KINDS:
		for id_value in sim.grid.component_ids_of_kind(kind):
			var id := String(id_value)
			var tile := sim.grid.component_tile(id)
			var centre := Vector3((float(tile.x) + 0.5) * tile_m, 0.0,
					(float(tile.y) + 0.5) * tile_m)
			var d := Vector2(centre.x - point.x, centre.z - point.z).length()
			if d > best_d or (d == best_d and not best.is_empty() \
					and id > String(best["id"])):
				continue
			best_d = d
			best = {"id": id, "kind": String(kind), "tile": tile,
					"world_pos": centre, "distance_m": d}
	return best


## The doc-05 water variants a tap may OPEN — the same list
## `PICKABLE_COMPONENT_KINDS` is one document over, and for the same reason: the
## pick and the fix-router ask this array rather than either of them reading an
## id's spelling. A `junction` is absent because §2.1 says it is not a component
## (it is where mains meet), and a `booster` is absent because
## `feature_flags.boosters_enabled` is off — a card that can never be placed
## cannot be tapped either.
const PICKABLE_WATER_VARIANTS: Array[StringName] = [
	&"source", &"treatment", &"pump", &"tank",
]

## When one doc-02 shell hosts several doc-05 nodes — `WTR-1` hosts an intake, a
## treatment train and a pump on one tile — this is which one the tap opens on.
## The **reference variant first** (report 98 RR-8: doc 02 generates this
## archetype's whole level table for `pump`, so the pump is what the shell IS),
## then §2.5's own chain order, then the id. Deterministic on every machine, and
## the panel lists the siblings so the other two are one tap away.
const WATER_PICK_ORDER: Array[StringName] = [
	&"pump", &"source", &"treatment", &"tank",
]


## The doc-05 node under `point`, or `{}`. **Footprint, not centre**, which is
## the one way this differs from `component_near`: a transformer stands on one
## tile and half a tile of tolerance is the whole of it, while a water works is
## 2×2 or 3×3 of doc 02 shell and a tap anywhere on it is a tap on it. The
## building pick this runs ahead of uses exactly the same test
## (`sim_id_at_tile`), so the two can never disagree about where the site is.
func water_node_near(point: Vector3) -> Dictionary:
	if sim == null or sim.water == null:
		return {}
	var tile := BuildController.tile_at(point, tile_m)
	var best: Dictionary = {}
	var best_rank := WATER_PICK_ORDER.size()
	for key: Variant in sim.water.nodes:
		var node: WaterNode = sim.water.nodes[key]
		if not PICKABLE_WATER_VARIANTS.has(node.variant):
			continue
		var size := sim.water.data.footprint_of(node.variant, node.level, node.subtype)
		if tile.x < node.tile.x or tile.y < node.tile.y \
				or tile.x >= node.tile.x + size.x or tile.y >= node.tile.y + size.y:
			continue
		var rank := WATER_PICK_ORDER.find(node.variant)
		if rank < 0:
			rank = WATER_PICK_ORDER.size()
		if not best.is_empty() and (rank > best_rank
				or (rank == best_rank and String(key) > String(best["id"]))):
			continue
		best_rank = rank
		best = {"id": String(key), "kind": String(node.variant), "tile": node.tile,
				"world_pos": Vector3((float(node.tile.x) + float(size.x) * 0.5) * tile_m,
						0.0, (float(node.tile.y) + float(size.y) * 0.5) * tile_m),
				"distance_m": 0.0, "domain": DOMAIN_WATER}
	return best


## The roster, or `null`. The shell's binding wins; otherwise the sim is asked
## for a `street` member **by name**, because a statically-typed `sim.street`
## would not compile in a build whose `CitySim` has no such property.
func street_roster() -> Object:
	if street != null:
		return street
	if sim == null:
		return null
	var found: Variant = sim.get("street")
	return found if found is Object else null


## The nearest collectable within `radius_m` of `point`, as a normalised row, or
## `{}`. `radius_m < 0` uses `tap_radius_m`.
##
## The roster answers in whatever shape doc 06's street system settles on; this
## normalises it to `{id, kind, world_pos, reward, has_pos}` so nothing above
## this line has to know. Two things are checked rather than trusted:
##
##   * a row with no `id` is not a pick — an anonymous collectable cannot be
##     handed to a command, so treating it as one would eat the tap and open
##     nothing, which is the worst outcome a pick has.
##   * a row that *does* carry a position is re-measured against the radius
##     here. The roster is expected to filter; a roster that returns its nearest
##     regardless of distance would otherwise make every tap in the city a
##     collect, and that failure would look like a broken building panel rather
##     than like a broken roster.
func opportunity_near(point: Vector3, radius_m: float = -1.0) -> Dictionary:
	var radius := radius_m if radius_m >= 0.0 else tap_radius_m
	if radius <= 0.0:
		return {}
	var roster := street_roster()
	if roster == null or not roster.has_method(STREET_QUERY):
		return {}
	var answer: Variant = roster.call(STREET_QUERY, point, radius)
	if not (answer is Dictionary):
		return {}
	var row: Dictionary = answer
	var id := str(row.get("id", ""))
	if id == "":
		return {}
	var raw_pos: Variant = row.get("world_pos", row.get("pos", null))
	var has_pos := raw_pos is Vector3
	var world_pos: Vector3 = raw_pos if has_pos else point
	if has_pos and Vector2(world_pos.x - point.x, world_pos.z - point.z).length() > radius:
		return {}
	return {
		"id": id,
		"kind": str(row.get("kind", "")),
		"world_pos": world_pos,
		"has_pos": has_pos,
		"reward": int(row.get("reward", row.get("payout", 0))),
		"row": row,
	}


## The collect itself. Same funnel as every other verb on this class (doc 12
## §4.4): the UI sends a command and reads the answer, and the answer is
## `CommandQueue`'s `{ok, reason_code, payload}` whether the sim has the verb or
## not — a caller never has to special-case a build without a street system.
func collect_opportunity(id: String) -> Dictionary:
	if id == "":
		return {"ok": false, "reason_code": E_NO_COMMAND, "payload": {"id": id}}
	var result: Variant = null
	if collect_command.is_valid():
		result = collect_command.call(id)
	elif sim != null and sim.has_method(STREET_COMMAND):
		result = sim.call(STREET_COMMAND, id)
	if not (result is Dictionary):
		return {"ok": false, "reason_code": E_NO_COMMAND, "payload": {"id": id}}
	return result


## **The whole tap seam, in one call.** Before S4 the shell asked
## `sim_id_at_ground()` and treated `""` as "deselect"; that is why land was
## untouchable — every tap on unowned ground resolved to nothing, and the one
## screen that could have sold it to the player had no way to open.
##
## The order is the order of specificity, and it is decided here rather than in
## the shell so the two panels can never both claim a tap:
##
##   0. a street opportunity within `tap_radius_m` → `{kind: "opportunity", id}`
##      → collect (Wave 14, below)
##   0b. a grid component within `tap_radius_m` → `{kind: "component", id}` → S18
##      (Wave 25, below)
##   1. a building on the tile  → `{kind: "building", id: sim_id}` → S5
##   2. otherwise the block, when S4 has something to offer for it (unowned,
##      owned-undeveloped, or mid-pipeline) → `{kind: "block", id: block_id}`
##   3. otherwise `{kind: "none"}` — finished ground the player already owns, or
##      a point off the map, which deselects exactly as it does today.
##
## **Why an opportunity outranks a building, and by a radius rather than by a
## tile.** Everything else on this list is a thing the player BUILT and can find
## again in a second; a loose dog is a thing that is leaving. The dog is also a
## 32 dp sprite standing in front of a house that occupies a whole tile, so a
## pick decided by tile ownership hands the tap to the house every time — the
## player's finger is on the animal and the game opens a building panel. The
## radius is 48 dp of finger converted at the current zoom
## (`set_tap_radius_from`), and it is a radius from the tapped POINT rather than
## a tile test for the same reason: the thing being picked is not on a grid.
##
## The house behind it is not lost. It has never moved and it will still be
## there on the next tap, which is exactly the asymmetry that makes this order
## the safe one.
##
## **And why a transformer outranks a building** (Wave 25, doc 93 §AY2, as
## corrected at the merge). `PowerInfraView` draws a padmount cabinet
## 2.40 × 2.00 m on the transformer's tile. The lane's first draft said doc 09
## puts most pads on tiles a building already occupies; the lane's own
## instrument and the verifier both measured 0 of 18 (founding) and 0 of 144
## (bench), so tile ownership never handed a pad tap to a house. The order is
## kept for the reason that survives measurement: within one finger's radius
## the smaller, more urgent object wins — the transformer is the thing that is
## on fire, the house is fine and one tap away — and it costs nothing: 0 of 77
## buildings within six tiles of the grid lose their tap to a pad.
##
## `block` is filled in on every in-bounds pick, kind 1 and 3 included, so a
## caller that wants the block a *building* sits in does not need a second query.
func pick_at_ground(point: Vector3) -> Dictionary:
	var tile := BuildController.tile_at(point, tile_m)
	var block_id := block_id_at_tile(tile)
	var out := {"kind": PICK_NONE, "id": "", "tile": tile, "block": block_id}
	var chance := opportunity_near(point)
	if not chance.is_empty():
		out["kind"] = PICK_OPPORTUNITY
		out["id"] = str(chance["id"])
		out["opportunity"] = chance
		return out
	var component := component_near(point)
	if not component.is_empty():
		out["kind"] = PICK_COMPONENT
		out["id"] = String(component["id"])
		out["component"] = component
		return out
	# **Doc 05's nodes are components too** (Wave 28, doc 12 D-124). AHEAD of the
	# building, and that ordering IS doc 93 §BA1's ruling made tappable: *"a
	# `water_facility` IS the doc-05 nodes hosted on it, at their level"*, so the
	# panel a tap on a water works should raise is the one that describes the
	# water — the chain, the zone, the mains — and not the doc-02 shell, whose
	# entire stat block is read out of doc 05's component table anyway. The pump
	# ladder S5 has drawn since Wave 11 stays exactly where it is: it is reached
	# from a goal's `Fix this →` and from the shell's own panel, both of which
	# still resolve.
	var node := water_node_near(point)
	if not node.is_empty():
		out["kind"] = PICK_COMPONENT
		out["id"] = String(node["id"])
		out["component"] = node
		return out
	var sim_id := sim_id_at_tile(tile)
	if sim_id != "":
		out["kind"] = PICK_BUILDING
		out["id"] = sim_id
		return out
	if block_id == "" or sim == null:
		return out
	if LandPanelModel.stage_opens_panel(sim.world.block(block_id)):
		out["kind"] = PICK_BLOCK
		out["id"] = block_id
	return out


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
		# The ARCHETYPE's own ladder height (doc 02 §2.14), not the roster's
		# tallest: a police station's level strip must not draw a sixth pip it
		# can never light.
		"max_level": sim.catalog.max_level_of(type_id),
		"state": b.state,
		"state_key": "ui_building_state_%s" % String(b.state),
		"condition": b.condition,
		"condition_text": RequirementFormatter.percent(b.condition),
		"origin": b.origin,
		# The BUILT extent — what the mesh covers at this level (doc 02 §2.3).
		"footprint": sim.built_of_building(b),
		# The LOT it reserved for life (doc 02 §2.3a) lives on `lot_block` below,
		# where the panel's LOT row reads it — one key per reader, not two.
		"lot_block": _lot_block(sim_id, b),
		"vitals": [
			_vital("occupants", "ui_building_vital_occupants",
					_occupants_text(sim_id, b)),
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
		"actions": actions_view(sim_id),
		# Doc 05 §6's node ladder, for the one archetype that hosts one. A
		# `water_facility` shell is a doc-02 building AND the host of one or
		# more doc-05 nodes, and only the node has a capacity to buy — so the
		# shell's own upgrade block above sells floorspace and this one sells
		# supply. `available` is false everywhere else (doc 93 §J1).
		"water": water.building_block(sim_id),
		# Doc 12 §2.9 D-70's POWER section. Present on every building, because
		# every building is fed by something — or by nothing, which is the one
		# reading the section exists to make impossible to miss.
		"power": power.building_block(sim_id),
	}


# ---------------------------------------------------------------------------
# §2.9 item 6 — the ACTIONS row: `Repair` · `Priority` · `Demolish`
#
# All three verbs shipped in Wave 1.5 / Wave 5 and none of them had a door
# (doc 92 §17.6). Same contract as the upgrade block above: the sim's own
# `preview = true` answers the question and this file only shapes the answer, so
# a button is never enabled on a rule this file believes and the sim does not.
# ---------------------------------------------------------------------------

func actions_view(sim_id: String) -> Dictionary:
	return {
		"restore": restore_view(sim_id),
		"salvage": salvage_view(sim_id),
		"repair": repair_view(sim_id),
		"priority": priority_view(sim_id),
		"demolish": demolish_view(sim_id),
	}


## **The ruin's SECOND row, and the one that runs the other way** (Wave 19;
## doc 12 §2.9 D-89, doc 93 §AQ2, report 98 RR-171).
##
## Drawn on exactly the buildings `restore_view` is drawn on, because it is the
## other half of the same decision: keep the lot and pay, or take the money and
## lose it. A ruin with only one of the two buttons is a ruin with no decision
## on it, which is what the panel had until this wave.
##
## Same contract as every row here — `CitySim.cmd_salvage_building(…, true)`
## answers every value, so the button cannot be enabled on a rule `ui/` believes
## and the sim does not — with one difference worth stating: **there is no
## affordability arm.** Salvage spends nothing, so `ok` is `true` at any balance
## including a negative one, and that is precisely the state the verb exists for.
func salvage_view(sim_id: String) -> Dictionary:
	var blank := {"available": false, "ok": false, "value": 0,
			"value_text": RequirementFormatter.money(0), "reason": {}}
	if sim == null or not sim.buildings.has(sim_id):
		return blank
	var b: Building = sim.buildings[sim_id]
	if b.state != &"destroyed":
		return blank
	var preview := sim.cmd_salvage_building(sim_id, true)
	var payload: Dictionary = preview.get("payload", {})
	var ok := bool(preview["ok"])
	var value := int(payload.get("value", 0))
	var reason: Dictionary = {}
	if not ok:
		reason = formatter.format(preview["reason_code"],
				{"state": String(b.state), "required_state": "destroyed",
				"sim_id": sim_id})
	return {
		"available": true,
		"ok": ok,
		"value": value,
		"value_text": RequirementFormatter.money(value),
		"level": int(payload.get("level", maxi(b.level_at_destruction, 1))),
		"capital": int(payload.get("capital", 0)),
		# The price of the OTHER verb, off the same call, because the row's whole
		# job is to be read against it.
		"restore_cost": int(payload.get("restore_cost", 0)),
		"restore_cost_text": RequirementFormatter.money(
				int(payload.get("restore_cost", 0))),
		"reason": reason,
	}


## **The ruin's own row** (Wave 18; doc 12 §2.9 D-86, doc 93 §AN6). Drawn on a
## `destroyed` building and nowhere else, and it is the ONLY action that building
## has — so `available` is simply "is this a ruin", read off the state rather than
## off a refusal, because every other verb on the panel answers `E_STATE` here and
## `E_STATE` is not a sentence the player can act on.
##
## Same contract as the three rows below it: `CitySim.cmd_restore_building(…,
## true)` answers every value and this file shapes the answer, so the button is
## never enabled on a rule `ui/` believes and the sim does not.
##
## **What the row can honestly say happened.** `Building` does not persist the
## CAUSE of a destruction — `serialize()` is inside doc 08's save body and inside
## `state_hash()`, so adding a field would move every baseline in the project on a
## surface change — so the row states the facts the model actually holds: that it
## is destroyed, how long ago, and the level it will come back at. The fire that
## did it is already published, with its cause, in the event log (doc 12 §2.13).
##
## `batch` is the many-at-once half, quoted from `cmd_restore_all_destroyed(true)`
## on the same read: a player looking at one ruin is exactly the player who has a
## dozen, and this is the moment they learn the city can be brought back in one
## tap. It is absent when this ruin is the only one.
func restore_view(sim_id: String) -> Dictionary:
	var blank := {"available": false, "ok": false, "cost": 0,
			"cost_text": RequirementFormatter.money(0), "reason": {}, "batch": {}}
	if sim == null or not sim.buildings.has(sim_id):
		return blank
	var b: Building = sim.buildings[sim_id]
	if b.state != &"destroyed":
		return blank
	var preview := sim.cmd_restore_building(sim_id, true)
	var payload: Dictionary = preview.get("payload", {})
	var ok := bool(preview["ok"])
	var cost := int(payload.get("cost", 0))
	var reason: Dictionary = {}
	if not ok:
		reason = formatter.format(preview["reason_code"],
				{"cost": cost, "balance": sim.treasury.balance,
				"state": String(b.state), "required_state": "destroyed",
				"sim_id": sim_id})
	return {
		"available": true,
		"ok": ok,
		"cost": cost,
		"cost_text": RequirementFormatter.money(cost),
		"level": int(payload.get("restore_level", maxi(b.level_at_destruction, 1))),
		"capital": int(payload.get("capital", 0)),
		"crew_hours": float(payload.get("crew_hours", 0.0)),
		"hours_destroyed": float(payload.get("hours_destroyed", 0.0)),
		# The queue panel's own clock words, in game-minutes — a player who reads
		# `2h 30m` on one screen and `2.5 hours` on another is reading two things.
		"since_text": UIWidgets.duration_text(
				formatter.config if formatter != null else null,
				float(payload.get("hours_destroyed", 0.0)) * 60.0),
		"reason": reason,
		"batch": _restore_batch_view(sim_id),
	}


## `Restore all destroyed (N) · $Y`, or `{}` when this ruin is the only one.
##
## **Cheapest first is the sim's ruling, not this file's** — a player with $30,000
## and a $28,000 power plant beside eleven $900 houses gets the eleven houses AND
## the plant if the plant is affordable last — so this only reads the count and
## the total the verb published. `ok` is whether the WHOLE set is affordable; the
## button stays live below that because the verb buys what it can and stops at the
## wall, which is the answer a player with a ton of ruins and not enough money
## wants. The note under it says how far the money reaches.
func _restore_batch_view(sim_id: String) -> Dictionary:
	var preview := sim.cmd_restore_all_destroyed(true)
	if not bool(preview["ok"]):
		return {}
	var payload: Dictionary = preview["payload"]
	var rows: Array = payload.get("rows", [])
	if rows.size() <= 1:
		return {}   # this ruin is the whole set; the primary button already is it
	var affordable := 0
	var running := 0
	for row: Variant in rows:
		var next := running + int((row as Dictionary)["cost"])
		if next > sim.treasury.balance:
			break
		running = next
		affordable += 1
	return {
		"available": true,
		"ok": affordable > 0,
		"count": rows.size(),
		"affordable_count": affordable,
		"all_affordable": affordable == rows.size(),
		"cost": int(payload["cost"]),
		"cost_text": RequirementFormatter.money(int(payload["cost"])),
		"others": rows.size() - 1,
		"sim_id": sim_id,
	}


## Doc 02 §2.6's repair, priced by doc 03 §2.5. `available` is what decides
## whether the row is DRAWN at all, and it is the sim's own answer: the command
## refuses `E_NOT_DAMAGED` at condition 1.00, so a building with nothing to buy
## has no button.
##
## Doc 12 §2.9 item 6 writes the threshold as "condition < 90 %". This ships it
## at *any* damage instead, because doc 02's own gate for an upgrade is
## `MIN_CONDITION_TO_UPGRADE` and a player held at 85 % by that gate must be able
## to answer it — a repair affordance that hides above 90 % would hide exactly
## when the checklist starts asking for it. Recorded as a delta in doc 12.
func repair_view(sim_id: String) -> Dictionary:
	if sim == null or not sim.buildings.has(sim_id):
		return {"available": false, "ok": false, "cost": 0,
				"cost_text": RequirementFormatter.money(0), "reason": {}}
	var b: Building = sim.buildings[sim_id]
	var preview := sim.cmd_repair_building(sim_id, true)
	var payload: Dictionary = preview.get("payload", {})
	var code := StringName(str(preview.get("reason_code", &"")))
	var ok := bool(preview["ok"])
	# `E_NOT_DAMAGED` is not a refusal the player has to read — it is the normal
	# state of a healthy building, and the row simply is not there.
	#
	# **`E_OWNER_MAINTAINED` folds in beside it** (Wave 17, doc 93 §Y3a). Private
	# stock keeps itself up, so on a house there is nothing to buy at ANY
	# condition and the row is not drawn at all. Drawing it disabled with an
	# explanation would be *more* interruption than the state this ruling is
	# fixing, not less: the 2026-09-01 playtest counted a REPAIR affordance on
	# 260 private buildings in a 21-game-day `balanced` city (doc 92 §43.1), and
	# a disabled button on 260 buildings is still 260 things asking to be tapped.
	# The code exists so the command layer, the agents and the tests can name the
	# reason exactly; it is not a thing to show a player who never asked.
	var nothing_to_buy := not ok and (code == &"E_NOT_DAMAGED"
			or code == &"E_OWNER_MAINTAINED")
	var cost := int(payload.get("cost", 0))
	var reason: Dictionary = {}
	if not ok and not nothing_to_buy:
		reason = formatter.format(code, {"cost": cost, "balance": sim.treasury.balance,
				"condition": b.condition, "state": String(b.state),
				"required_state": "active", "sim_id": sim_id})
	return {
		"available": not nothing_to_buy,
		"ok": ok,
		"cost": cost,
		"cost_text": RequirementFormatter.money(cost),
		"condition": b.condition,
		"condition_text": RequirementFormatter.percent(b.condition),
		"damage_fraction": float(payload.get("damage_fraction", b.damage_fraction())),
		"target": float(payload.get("repair_target", 1.0)),
		"target_text": RequirementFormatter.percent(payload.get("repair_target", 1.0)),
		"crew_hours": float(payload.get("crew_hours", 0.0)),
		"reason": reason,
	}


## Doc 04 §2.4's shed tier. The classes are doc 04's own roster
## (`data/grid_components.json.priority.classes`), read through the sim so this
## file authors no ladder; `available` is false for a building the grid has no
## service record for, which is the same `E_UNSERVED` the command raises.
func priority_view(sim_id: String) -> Dictionary:
	var out := {"available": false, "classes": [] as Array[String], "current": "",
			"current_key": ""}
	if sim == null or not sim.buildings.has(sim_id):
		return out
	var priority: Dictionary = sim.grid_rules.get("priority", {})
	var classes: Array[String] = []
	for entry: Variant in (priority.get("classes", []) as Array):
		classes.append(str(entry))
	if classes.is_empty():
		return out
	var current := String(sim.grid.priority_class_of(sim_id))
	out["classes"] = classes
	out["current"] = current
	out["current_key"] = BuildController.priority_key(current)
	# A building with no grid service record cannot carry a class: doc 04 keeps
	# the tier ON the service record, which is exactly what the shed score reads.
	out["available"] = sim.grid.attachment_of(sim_id) != ""
	return out


static func priority_key(priority_class: String) -> String:
	return "ui_building_priority_%s" % priority_class.to_lower()


## Doc 02 §2.12's demolition, refunded by doc 03 §2.3 + the construction queue's
## own §2.10 fraction on anything still in flight. Always `available` — the
## refusal (`on_fire`, `destroyed`) is a sentence the player should read rather
## than a button that vanishes, because both states are ones they are looking at.
func demolish_view(sim_id: String) -> Dictionary:
	if sim == null or not sim.buildings.has(sim_id):
		return {"available": false, "ok": false, "refund": 0,
				"refund_text": RequirementFormatter.money(0), "reason": {}}
	var preview := sim.cmd_demolish_building(sim_id, true)
	var payload: Dictionary = preview.get("payload", {})
	var ok := bool(preview["ok"])
	var refund := int(payload.get("refund", 0))
	var reason: Dictionary = {}
	if not ok:
		var b: Building = sim.buildings[sim_id]
		reason = formatter.format(preview["reason_code"],
				{"state": String(b.state), "required_state": "active",
				"sim_id": sim_id})
	return {
		"available": true,
		"ok": ok,
		"refund": refund,
		"refund_text": RequirementFormatter.money(refund),
		"capital_refund": int(payload.get("capital_refund", 0)),
		"job_refund": int(payload.get("job_refund", 0)),
		"cancelled_jobs": (payload.get("cancelled_jobs", []) as Array).size(),
		"reason": reason,
	}


## The three commands, issued for real (doc 12 §4.4). The panel refreshes from
## whatever the sim answers; it never predicts.
func repair(sim_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING", {"sim_id": sim_id})
	return sim.cmd_repair_building(sim_id)


## Doc 02 §2.12's restore, through the same funnel (Wave 18). One tap, the price
## already on the button's face, and the panel re-reads whatever the sim answers.
func restore(sim_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING", {"sim_id": sim_id})
	return sim.cmd_restore_building(sim_id)


## Doc 02 §2.12's OTHER ruin transition, through the same funnel (Wave 19).
## One tap, the money on the button's face, and the panel re-reads the city —
## which it has to, because unlike every other verb on this panel the building
## the panel is about stops existing.
##
## **Hold-to-confirm lives on the BUTTON, not here** (doc 12 §2.9 D-89): this is
## the funnel and it commits what it is asked to commit. The panel is where a
## verb that cannot be undone earns its 800 ms, exactly as `Demolish` does.
func salvage(sim_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING", {"sim_id": sim_id})
	return sim.cmd_salvage_building(sim_id)


## The many-at-once half. Cheapest first and stopping at the funds wall, both of
## which are the sim's rulings — this is a door, not a policy.
func restore_all_destroyed() -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_NO_RUINS", {})
	return sim.cmd_restore_all_destroyed()


func set_priority(sim_id: String, priority_class: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING", {"sim_id": sim_id})
	return sim.cmd_set_priority(sim_id, priority_class)


func demolish(sim_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING", {"sim_id": sim_id})
	return sim.cmd_demolish_building(sim_id)


## Doc 05 §6's node upgrade, from the same panel and through the same funnel.
## The shell's `UPGRADE` button buys doc 02's next level; this buys doc 05's, on
## one of the nodes that shell hosts.
func upgrade_water_node(node_id: String) -> Dictionary:
	if water == null:
		return CommandQueue.fail(&"E_UNKNOWN_NODE", {"node": node_id})
	return water.upgrade_node(node_id)


static func _vital(id: String, label_key: String, value: String) -> Dictionary:
	return {"id": id, "label_key": label_key, "value": value}


## **`3 of 4` — the vital that answers "where are my people?"** (doc 12 D-100,
## report 98 RR-203, the 2026-09-04 player report).
##
## This vital was the AUTHORED capacity and nothing else, so the panel of a
## house the player tapped thirty seconds ago read `Occupants 4` while the
## population chip at the top of the same screen had not moved and would not
## move for another **176 real seconds** (`tools/measure_population_lag.gd`
## measures the whole journey: 120 s of shell, then up to 60 s waiting for doc
## 01's hourly settle). A building claiming four residents beside a counter that
## disagrees is not a slow counter, it is two surfaces telling the player
## different things — and the counter is the one that is right.
##
## So the value is now `settled of authored` whenever the two differ, and the
## plain authored figure when they agree — a full building reads `4`, exactly as
## it always did, and only a building that is genuinely not full spends the
## extra characters. `-1` from the sim means "houses nobody", which is every
## shop, station and pump in the city and must keep reading `0`.
func _occupants_text(sim_id: String, b: Building) -> String:
	var authored := int(b.stats.get("population", 0))
	var settled := sim.settled_residents(sim_id)
	if settled < 0:
		return HudModel.pop(authored)
	return _t("ui_building_occupants_of",
			{"settled": HudModel.pop(settled), "authored": HudModel.pop(authored)},
			"%s of %s" % [HudModel.pop(settled), HudModel.pop(authored)])


## Four 40 dp tiles (§2.9 item 4), all four of them live (Wave 18, PA-22).
##
## Three of these read `✕ —` on every building in the city for eleven waves,
## including on the pump station, whose whole job is the tile that said it had no
## water. The publishers had been there since Wave 5 — `CityIncidentWorld.
## coverage_police/coverage_fire` (doc 02 §2.9, C-51) and `WaterSystem.
## pressure_at` (doc 05) — and the reader was never updated when doc 91 row 2.9
## closed. The L4 curriculum teaches "stations and coverage" against a surface
## that could not turn green.
##
## **The LOT row** (doc 12 §2.9a / D-128, doc 02 §2.3a, Wave 29). Three states,
## and the third is the only one with a button:
##
##   * the archetype does not grow — `available: false`, no row is drawn. A house
##     is 1×1 at every rung and a row saying so is noise.
##   * it grows and it HOLDS its lot — the row says how much ground is reserved
##     and what is standing on it, so a player looking at a one-tile store on a
##     2×2 pad can see the pad is not a mistake.
##   * it is LOT-LOCKED — it was standing when the rule arrived and the tiles it
##     needed were already taken. The row says the level it can still reach and
##     names what is on the missing ground.
##
## **The locked state is four states, and only one of them has a button** (Wave
## 29 fix). The ground grows all at once or not at all, so a door is drawn only
## where pressing it actually frees the lot:
##
##   * a BUILDING is the only thing on the missing ground, and a verb takes it —
##     the row quotes that verb (`cmd_demolish_building` for anything standing,
##     `cmd_salvage_building` for a ruin) and routes `FIX_BUILDING` at it,
##     because *"what freeing it pays"* is the half of the sentence that makes it
##     actionable;
##   * a building is the only blocker but NO verb takes it — it is on fire — the
##     row says so and draws nothing to press;
##   * a building AND ground the player cannot clear (road, water, undeveloped,
##     an occupied tile) — clearing the building would move nothing, so the row
##     says that instead of offering it;
##   * ground only — the original `ui_building_lot_locked_ground`.
##
## Never a fifth state where a lot-locked building is silently short: the whole
## reason this block exists is that a reservation the player cannot see is a
## reservation they will read as a bug.
func _lot_block(sim_id: String, b: Building) -> Dictionary:
	var lot := sim.lot_of_building(b)
	var built := sim.built_of_building(b)
	var first := sim.built_for(String(b.archetype), 1)
	if b.archetype == StringName(CitySim.WATER_SHELL_ARCHETYPE):
		first = sim.water.data.footprint_of(b.variant, 1,
				String(sim.water.data.placeable_rules(String(b.variant)).get("subtype", "")))
	if lot == first:
		# Not a grower: nothing about this building's ground ever changes.
		return {"available": false, "locked": false, "lot": lot, "built": built}
	var lock := sim.lot_lock(sim_id)
	var out := {
		"available": true,
		"locked": not lock.is_empty(),
		"lot": lot,
		"built": built,
		"lot_text": "%d×%d" % [lot.x, lot.y],
		"built_text": "%d×%d" % [built.x, built.y],
		# The verb that would free this ground, for a reader that wants to know
		# WHICH one was quoted: `"demolish"`, `"salvage"`, or empty where no verb
		# is offered. Always present on a drawn row, so no consumer has to guess
		# whether the key exists.
		"free_verb": "",
		"fix_target": {"kind": RequirementFormatter.FIX_NONE, "id": "", "params": {}},
	}
	if lock.is_empty():
		out["text_key"] = "ui_building_lot_reserved"
		out["params"] = {"lot": out["lot_text"], "built": out["built_text"]}
		return out
	var held: Vector2i = lock["held"]
	out["held"] = held
	out["held_text"] = "%d×%d" % [held.x, held.y]
	out["reachable_level"] = int(lock["reachable_level"])
	out["top_level"] = int(lock["top_level"])
	out["blockers"] = (lock["blockers"] as Array).duplicate()
	# The FIRST blocker that is a BUILDING is the one the player can act on; a
	# road or an undeveloped block is a fact about the map, not a door. The
	# blocker list is already in a deterministic order, so this picks the same
	# neighbour on every machine.
	var neighbour := ""
	var neighbours: Array = []
	var ground: Array = []
	for entry in (lock["blockers"] as Array):
		if sim.buildings.has(String(entry)):
			neighbours.append(String(entry))
		else:
			ground.append(String(entry))
	if not neighbours.is_empty():
		neighbour = String(neighbours[0])
	var params := {"held": out["held_text"], "lot": out["lot_text"],
			"level": int(lock["reachable_level"]), "top": int(lock["top_level"])}
	if neighbour == "":
		out["text_key"] = "ui_building_lot_locked_ground"
		out["params"] = params
		return out
	params["neighbour"] = neighbour
	var other: Building = sim.buildings[neighbour]
	out["blocked_by"] = neighbour
	# **WHICH VERB CLEARS IT IS THE NEIGHBOUR'S OWN STATE'S BUSINESS** (Wave 29
	# fix, doc 93 §BE5a, report 98 §74b RR-240). The first cut quoted `cmd_demolish_building`
	# unconditionally and never read the quote's `ok`, and the city that found it
	# was the player's own: 77 of `tests/fixtures/player_save_0903`'s 89
	# buildings are `destroyed`, so all seven lot-locked stores whose blocker is
	# a building named a RUIN. Demolition refuses a ruin (`E_STATE` — that is
	# `cmd_salvage_building`'s job, doc 02 §2.12), so the row read "clearing it
	# refunds $0" and armed a button behind a verb that answers no. Salvage
	# succeeds on every one of them and pays $390 — $27,000 for the destroyed
	# data centre. A wrong number in front of a verb that refuses is the defect
	# this project is named after, one screen further in.
	#
	# So: the ruin's verb for a ruin, the demolition for anything standing, and
	# the QUOTE's own `ok` decides whether there is a door at all. `on_fire` is
	# the one state neither verb takes — the row says so and draws no button
	# rather than inventing a third verb.
	#
	# **And a door only exists where the door OPENS something.** The ground grows
	# all at once or not at all — `migrate_lots` asks `TileGrid.can_expand` for
	# the WHOLE lot rectangle, which refuses if a single tile of it is taken — so
	# clearing one of two blockers moves nothing. Measured on the player's save:
	# every one of those seven stores is blocked by a ruin AND by the kerb
	# (`blockers = [E_ROAD, P-047]`), and salvaging the ruin leaves the shop at
	# 1×1 of its 2×2 with its `reachable_level` still 2. So a lot with ground the
	# player cannot clear says exactly that and draws no button: the row that
	# offers a remedy which cannot work is the same defect as the row that offers
	# a verb which refuses.
	# …and TWO buildings on the missing lot is the same partial case as ground:
	# clearing one of them moves nothing, so no door (the merge verifier found
	# 14 of the bench city's 206 locked lots arming one — the loop used to keep
	# the first building and drop the rest).
	if not ground.is_empty() or neighbours.size() > 1:
		out["text_key"] = "ui_building_lot_locked_partial"
		out["params"] = params
		return out
	var salvaging := other.state == &"destroyed"
	var quote := sim.cmd_salvage_building(neighbour, true) if salvaging \
			else sim.cmd_demolish_building(neighbour, true)
	var payload: Dictionary = quote.get("payload", {})
	if not bool(quote.get("ok", false)):
		# No verb clears it in this state. The lowercase state text is
		# deliberate: it lands mid-sentence ("…while it is on fire"), and the
		# table's own entry is capitalised for a badge.
		params["state"] = _t("ui_building_state_%s" % String(other.state), {},
				String(other.state).replace("_", " ")).to_lower()
		out["text_key"] = "ui_building_lot_locked_stuck"
		out["params"] = params
		return out
	# `cmd_salvage_building` pays `value` and `cmd_demolish_building` pays
	# `refund`; both are "what freeing this ground puts in the treasury", which
	# is the half of the sentence that makes the row actionable.
	var pays := int(payload.get("value", 0)) if salvaging \
			else int(payload.get("refund", 0))
	out["free_verb"] = "salvage" if salvaging else "demolish"
	out["free_refund"] = pays
	out["free_refund_text"] = HudModel.money(pays)
	params["refund"] = out["free_refund_text"]
	out["text_key"] = "ui_building_lot_locked_salvage" if salvaging \
			else "ui_building_lot_locked"
	out["params"] = params
	out["fix_target"] = {"kind": RequirementFormatter.FIX_BUILDING, "id": neighbour,
			"params": {"sim_id": neighbour}}
	return out


## Each tile is banded the way its own doc bands it, and `—` survives in exactly
## one place per slot: the honest one. No station in range at all reads OFFLINE
## with the scalar beside it; a lot no pressure zone reaches reads OFFLINE with
## an em dash, because there is no reading to give rather than a reading of zero.
func _coverage(sim_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for slot: String in COVERAGE_SLOTS:
		var row := {
			"id": slot,
			"label_key": "ui_building_coverage_%s" % slot,
			"state": HudModel.STATE_OFFLINE,
			"value": HudModel.NO_DATA,
			# §2.9's one-line reason on tap: which station, or which zone.
			"reason_key": "",
			"reason_args": {},
		}
		match slot:
			"power":
				var availability := sim.grid.power_availability_hour(sim_id)
				row["value"] = RequirementFormatter.percent(availability)
				row["state"] = _coverage_state(availability)
				row["attachment"] = sim.grid.attachment_of(sim_id)
			"water":
				row.merge(_water_coverage(sim_id), true)
			"police", "fire":
				row.merge(_safety_coverage(sim_id, slot), true)
		out.append(row)
	return out


## Doc 05's per-building service: the pressure at the building's ACCESS tile,
## which is the tile every other doc-05 reading for this building is taken at.
## Banded on doc 05's own thresholds — `nominal_pressure` is the design point and
## `recovery_pressure_threshold` is the line the no-water counter unwinds above,
## so below it the building is on its way to abandoning. Read from
## `data/water.json`; no threshold is authored here.
func _water_coverage(sim_id: String) -> Dictionary:
	if sim == null or sim.water == null:
		return {}
	var tile: Vector2i = sim.water.demand.access_tile(sim_id)
	var zone: PressureZone = sim.water.zone_at(tile)
	if zone == null:
		# The one honest em dash on this row: no zone reaches this lot, so there
		# is no pressure to report — not a pressure of zero.
		return {"state": HudModel.STATE_OFFLINE, "value": HudModel.NO_DATA,
				"reason_key": "ui_building_coverage_reason_no_zone", "reason_args": {}}
	var pressure := sim.water.pressure_at(tile)
	var nominal := sim.water.data.effect("nominal_pressure", 0.60)
	var recover := sim.water.data.effect("recovery_pressure_threshold", 0.35)
	var state := HudModel.STATE_CRITICAL
	if pressure >= nominal:
		state = HudModel.STATE_NORMAL
	elif pressure >= recover:
		state = HudModel.STATE_WARNING
	return {
		"state": state,
		"value": RequirementFormatter.percent(pressure),
		"zone": zone.zone_key,
		"reason_key": "ui_building_coverage_reason_zone",
		"reason_args": {"zone": zone.zone_key},
	}


## Doc 02 §2.9's per-position coverage, banded on the building's own REQUIREMENT
## — "the UI must show the margin, not just pass/fail", verbatim. `OverlayModel.
## coverage_state_name` is that ladder and the overlay already uses it, so the
## tile and the overlay can never disagree about one building.
func _safety_coverage(sim_id: String, slot: String) -> Dictionary:
	if sim == null or sim.incident_world == null or not sim.buildings.has(sim_id):
		return {}
	var b: Building = sim.buildings[sim_id]
	var kind: StringName = CoverageIndex.KIND_POLICE if slot == "police" \
			else CoverageIndex.KIND_FIRE
	var explain: Dictionary = sim.incident_world.coverage_explain(kind, b.origin)
	var value := float(explain.get("coverage", 0.0))
	var requirement := float(b.stats.get(
			"req_police_coverage" if slot == "police" else "req_fire_coverage", 0.0))
	var best_id := str(explain.get("best_id", ""))
	return {
		"state": _overlay_model().coverage_state_name(value, requirement),
		"value": RequirementFormatter.percent(value),
		"requirement": requirement,
		"station": best_id,
		"reason_key": "ui_building_coverage_reason_station" if best_id != "" \
				else "ui_building_coverage_reason_none",
		"reason_args": {"name": best_id},
	}


## The overlay's band ladder, made once and kept — `data/ui.json.overlay` is the
## only place these thresholds are written down and both surfaces read it there.
func _overlay_model() -> OverlayModel:
	if _overlay == null:
		_overlay = OverlayModel.new(formatter.config if formatter != null else null)
	return _overlay


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
	var top_level: int = sim.catalog.max_level_of(String(b.archetype))
	var next_level: int = mini(b.level + 1, top_level)
	var cost := int(payload.get("cost", 0))
	var checks := _checks_for(b, next_level)
	var rows := formatter.checklist(checks, blockers,
			{"cost": cost, "balance": sim.treasury.balance},
			_check_params(sim_id, b, next_level, payload))
	var blocked_by := RequirementFormatter.first_blocker(rows)
	return {
		"available": b.level < top_level,
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
	var avenue_tile := nearest_avenue_tile(b.origin)
	var avenue_distance := BuildController._chebyshev(b.origin, avenue_tile) \
			if avenue_tile != BuildController.NO_TILE else AVENUE_SEARCH_TILES + 1
	# The repair's own quote, so `E_CONDITION`'s `Fix this →` can name the price
	# of the purchase it performs rather than the price of the upgrade it is
	# standing in the way of (PA-05's params contract, `fix_cost`).
	var repair_cost := int((sim.cmd_repair_building(sim_id, true)
			.get("payload", {}) as Dictionary).get("cost", 0))
	return {
		&"E_STATE": {"state": String(b.state), "required_state": "active",
				"fix_target_id": sim_id, "tile": b.origin},
		&"E_MAX_LEVEL": RequirementFormatter.level_params(b.level,
				sim.catalog.max_level_of(String(b.archetype))),
		# `min_condition` is read off the building (PA-13 / doc 93 §Y2), and the
		# fix is a PURCHASE only on a building the city may buy a repair for
		# (doc 02 §2.6a). On private stock the owner is already fixing it and the
		# city's job is to serve it, so the row blocks and offers no button.
		&"E_CONDITION": {"condition": b.condition,
				"min_condition": b.min_condition_to_upgrade(),
				"fix_kind": RequirementFormatter.FIX_NONE if b.owner_maintained
						else RequirementFormatter.FIX_REPAIR,
				"fix_target_id": "" if b.owner_maintained else sim_id,
				"fix_cost": repair_cost, "tile": b.origin},
		&"E_CITY_LEVEL": {"city_level": sim.progression.city_level,
				"required_level": int(next_stats.get("min_city_level", 0))},
		&"E_FUNDS": RequirementFormatter.funds_params(int(payload.get("cost", 0)),
				sim.treasury.balance),
		# PA-12: the margin the GATE applies, not the raw delta. `city_sim.gd`
		# asks doc 04 for `delta × headroom_safety.power`; quoting the delta told
		# the player a number 15 % below the one that would clear the row, so
		# they bought exactly what the panel asked for and were refused again
		# with a smaller deficit. One shape, shared with the water block (PA-75).
		&"E_POWER_HEADROOM": RequirementFormatter.power_headroom_params(
				delta_kw, deficit, headroom_margin(), sim.grid.attachment_of(sim_id),
				sim_id),
		# PA-24: doc 02 §2.11's seventh gate, in doc 05's own unit and against
		# doc 05's own zone. `water.can_upgrade_water` is the gate itself, asked
		# the same question `cmd_upgrade_building` asks it.
		&"E_WATER_HEADROOM": _water_headroom_params(sim_id, b, next_stats),
		&"E_AVENUE": {
			"avenue_distance_tiles": avenue_distance,
			"avenue_radius_tiles": AVENUE_RADIUS_TILES,
			"to_level": next_level,
			"tile": b.origin,
			# PA-05: the row quotes the BUILDING's tile in its sentence ("no
			# avenue within 4 tiles of 12, 30") and routes to the AVENUE's, which
			# is the thing the player has to go and look at. Before this the row
			# carried no `fix_target_id` at all, the formatter emitted `id == ""`
			# and `main.gd`'s router discarded it on its first line — a button
			# that had never once moved the camera.
			"fix_tile": avenue_tile,
			"fix_kind": RequirementFormatter.FIX_ROAD_SEGMENT \
					if avenue_tile != BuildController.NO_TILE \
					else RequirementFormatter.FIX_NONE,
			"fix_target_id": _road_segment_at(avenue_tile),
		},
	}


## Doc 05 §6's headroom gate, as the checklist row's parameters (PA-24). The
## zone's spare capacity and what the next level would draw with doc 05's own
## safety factor on it — both read from `WaterSystem`, which is the gate.
##
## **The row routes to the PURCHASE now, not to the zone** (Wave 28, doc 12
## D-126, A91-D-147). `E_WATER_HEADROOM` has one code and doc 05 §2.11 refuses on
## two different arms behind it, and until this wave the row could not tell them
## apart, so it sent every refusal to the same place — the zone key, as a
## district, which is a camera move to a pump:
##
##   * `capacity` — the zone genuinely has no spare water. The purchase is the
##     rung under the stage that BINDS §2.5's chain, and `WaterSystem.
##     supply_chain` names it. `FIX_COMPONENT` on that node opens S19, where the
##     chain is drawn and the button is quoted. Sending the player to a PUMP
##     when treatment binds is doc 92 §67.4's $5.5M mistake with a fix button
##     on it.
##   * `pressure` — the zone is fine and this BUILDING is too far from a main
##     (doc 92 §67.8: pressure 1.00 in the zone, 0.50 at the tile, 57 m³/h
##     spare). No amount of supply moves a tile factor. The row keeps the
##     camera on the building's own tile and the sentence says the distance,
##     because the answer is a main and the player lays that with the path tool.
func _water_headroom_params(sim_id: String, b: Building,
		next_stats: Dictionary) -> Dictionary:
	var delta_water := float(next_stats.get("water_demand", 0.0)) \
			- float(b.stats.get("water_demand", 0.0))
	var verdict: Dictionary = sim.water.can_upgrade_water(sim_id, delta_water)
	var headroom := sim.water.zone_headroom_m3h(sim_id)
	var tile: Vector2i = sim.water.demand.access_tile(sim_id)
	var zone: PressureZone = sim.water.zone_at(tile)
	var zone_key := zone.zone_key if zone != null else ""
	var limit := String(verdict.get("limit", "capacity"))
	var chain: Dictionary = sim.water.supply_chain_of(zone) if zone != null else {}
	var binding := String(chain.get("binding", "none"))
	var binding_ids: Array = chain.get("binding_ids", [])
	var fix_kind := RequirementFormatter.FIX_NONE
	var fix_id := ""
	if limit == "pressure":
		fix_kind = RequirementFormatter.FIX_BUILDING
		fix_id = sim_id
	elif not binding_ids.is_empty():
		fix_kind = RequirementFormatter.FIX_COMPONENT
		fix_id = String(binding_ids[0])
	elif zone_key != "":
		# A zone that binds on its MAINS has no node to raise — the answer is
		# `cmd_place_water_main`, and the camera goes to the plant so the player
		# can see where the trunk has to start.
		fix_kind = RequirementFormatter.FIX_DISTRICT
		fix_id = zone_key
	return {
		"deficit_m3h": float(verdict.get("deficit_m3h", 0.0)),
		"headroom_m3h": headroom,
		"required_m3h": delta_water * sim.water.data.effect(
				"upgrade_headroom_safety", 1.10),
		"zone": zone_key,
		"district_id": zone_key,
		"at": zone_key,
		"tile": b.origin,
		# Which arm refused, and what it points at — read by the row's copy and
		# by `FixRouter`, and published so a test can assert the two agree.
		"limit": limit,
		"binding": binding,
		"pressure": float(verdict.get("pressure", sim.water.pressure_at(tile))),
		"zone_pressure": zone.pressure if zone != null else 0.0,
		"main_distance_tiles": sim.water.topology.distance_at_tile(tile),
		"fix_target_id": fix_id,
		# No zone and no node at all is not a place the camera can fly to; the
		# row still blocks and still says why, and it offers no button rather
		# than one that resolves to nowhere (the failure shape PA-05 catalogued).
		"fix_kind": fix_kind,
	}


## Doc 02 §8's `headroom_safety.power`, read (PA-12/PA-13). Lane C's accessor
## replaces the two-level `get` at merge; the value is the same either way.
func headroom_margin() -> float:
	if sim == null or sim.catalog == null:
		return HEADROOM_MARGIN_DEFAULT
	var safety: Variant = sim.catalog.rules().get("headroom_safety", {})
	if not (safety is Dictionary):
		return HEADROOM_MARGIN_DEFAULT
	return float((safety as Dictionary).get("power", HEADROOM_MARGIN_DEFAULT))


## Chebyshev distance in tiles from `p_origin` to the nearest AVENUE, searched
## outward and capped — the `{have}` figure of the C-62 message. Returns
## `AVENUE_SEARCH_TILES + 1` when none is in range.
func nearest_avenue_tiles(p_origin: Vector2i) -> int:
	var tile := nearest_avenue_tile(p_origin)
	if tile == BuildController.NO_TILE:
		return AVENUE_SEARCH_TILES + 1
	return BuildController._chebyshev(p_origin, tile)


## The same search, answering with the TILE rather than the distance — the half
## `E_AVENUE`'s `Fix this →` needs and never had (PA-05). Same walk order, so
## the tile returned is always the one the distance was measured to.
func nearest_avenue_tile(p_origin: Vector2i) -> Vector2i:
	for radius in range(0, AVENUE_SEARCH_TILES + 1):
		for z in range(p_origin.y - radius, p_origin.y + radius + 1):
			for x in range(p_origin.x - radius, p_origin.x + radius + 1):
				if maxi(absi(x - p_origin.x), absi(z - p_origin.y)) != radius:
					continue
				if TileGrid.in_bounds(x, z) \
						and sim.world.grid.road_class_at(x, z) == TileGrid.ROAD_AVENUE:
					return Vector2i(x, z)
	return BuildController.NO_TILE


static func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## Doc 10's segment id under a tile, or "" — the `id` half of a
## `FIX_ROAD_SEGMENT` target. The tile in `params` is what the router acts on;
## this is what the row can name.
func _road_segment_at(tile: Vector2i) -> String:
	if sim == null or tile == BuildController.NO_TILE or sim.roads == null:
		return ""
	var edge := sim.roads.edge_at_position(tile)
	return "" if edge < 0 else str(edge)


## The panel's `UPGRADE` button. Issues the real command (doc 12 §4.4) and hands
## back the sim's verdict so the view can refresh from truth, not from hope.
func upgrade(sim_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING", {"sim_id": sim_id})
	return sim.cmd_upgrade_building(sim_id)

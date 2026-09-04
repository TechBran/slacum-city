class_name CostCurves
extends RefCounted
## The project's only cost, tax and repair price functions (doc 03 §2.3 / §2.5,
## report 98 C-07 / C-16). Pure: no state, no tick, no file IO in the
## constructor — the parsed Dictionaries are handed in, so the curves are
## testable from fixtures. `load_from_files()` is the only path that touches
## FileAccess, mirroring `BuildingCatalog`.
##
## The per-archetype columns are GENERATED — `tools/gen_building_economy.py`
## grows `base_tax_by_level`, `upgrade_cost_by_step` and `capital_value_by_level`
## from doc 03 §2.2's money table and diffs them against the doc's published
## cells. Nothing here re-derives a curve at runtime; the ladders are
## table-generation-time only. What this class does is *read* them, re-check the
## generator's invariant at load (doc 03 §7 test 8, ±$1 per cell) and apply the
## §2.5 repair/refund fractions.
##
## Loader invariants are collected in `errors` rather than raised, mirroring
## `BuildingCatalog` and `DayCurveSet`.

## Doc 03 §2.2's ladder floor. Six of the fourteen money rows grew a SIXTH rung
## with doc 02's growth stock (doc 92 §24) and the rest stop here, so this is the
## minimum a row may carry and never the number of cells to read: `_validate_row`
## takes the height off the row itself.
const LEVELS_PER_ARCHETYPE := 5
const TOP_LEVELS_PER_ARCHETYPE := 6
const GENERATED_CELL_TOLERANCE := 1  # doc 03 §7 test 8: ±$1 (RR-5 locks 3 cells)

## doc 03 rounds half-up everywhere (§2.8's own note: 7,187.5 → 7,188). Binary
## floats land a genuine tie a few ulp below it (5000 × 1.25 × 1.15 evaluates to
## 7187.499999999999), so the tie is resolved with an absolute epsilon. Every
## money cell in the project is authored to at most 5 decimal places, so nothing
## legitimate sits within 1e-6 of a half-dollar boundary.
const ROUND_EPSILON := 0.000001

## doc 03 §2.13(f): how far the PUBLISHED rush rate may sit from the §2.5
## contractor row it is derived from. The cell is authored to five decimal
## places like every money cell in the project, so the residual is ~8e-7.
const RUSH_DERIVATION_TOLERANCE := 0.00001

## doc 93 §AN: the damage fraction a MAINTAINING player actually buys a repair
## at. Doc 92 §43.1's `balanced` agent repairs at condition 0.80, so the routine
## repair it buys is priced at `0.20 × REPAIR_COST_PER_CAPITAL = 0.17 × capital`
## — and that is the floor `RESTORE_COST_FRACTION` is checked against at load,
## because a restore cheaper than the repair it replaced would pay for neglect.
## It is not a price and it prices nothing; it is the agent's own threshold,
## named here so the check can quote the number it is enforcing.
const MAINTAINER_DAMAGE_FRACTION := 0.20

## doc 03 §2.13(a) / §2.2 archetype ids. doc 02's roster names four of them
## differently and omits two; the alias map ships in building_economy.json.
const REQUIRED_ARCHETYPE_KEYS := [
	"class", "build_cost_l1", "base_tax_l1", "base_tax_by_level",
	"upgrade_cost_by_step", "capital_value_by_level",
]

const REVENUE_CLASSES := ["residential", "commercial", "industrial", "tech"]

var errors: PackedStringArray = []

var _archetypes: Dictionary = {}  # id -> row Dictionary
var _alias: Dictionary = {}  # doc 02 id -> doc 03 id
var _ids: Array = []
var _economy: Dictionary = {}
var _schema_version: int = 0

# doc 03 §8 constants, resolved once at load.
var _tax_level_growth: float = 0.0
var _upg_coeff: float = 0.0
var _upg_growth: float = 0.0
var _capital_value_v: Array = []
var _repair_cost_per_capital: float = 0.0
## doc 03 §2.5's restore row (Wave 18, doc 93 §AN). The share of a building's
## capital the city pays to bring a RUIN back — the capital end of the same
## repair family `_repair_cost_per_capital` prices the routine end of.
var _restore_cost_fraction: float = 0.0
## Doc 03 §2.5 / Wave 19 (RR-171): what a RUIN is worth stripped, as a fraction
## of the capital it had when it fell down. 0.0 in a table that does not author
## it, which makes the salvage verb quote $0 rather than crash a boot.
var _salvage_fraction: float = 0.0
var _pm_cost_fraction: float = 0.0
var _pm_min_condition: float = 0.0
var _demolition_refund_fraction: float = 0.0
var _vehicle_resale_fraction: float = 0.0
var _land_resale_fraction: float = 0.0
var _contractor_surcharge: float = 0.0
var _contractor_time_fraction: float = 0.0
var _rush_surcharge_per_duration: float = 0.0
var _road_repair_capital_fraction: float = 0.0
var _road_demolish_refund_fraction: float = 0.0
var _road_build_cost: Dictionary = {}
var _road_upgrade_cost: Dictionary = {}
var _grid_components: Dictionary = {}
var _vehicles: Dictionary = {}
var _water_main_cost: Dictionary = {}
var _water_main_repair_capital_fraction: float = 1.0
var _water_demolish_refund_fraction: float = 0.0
## 99-PA PA-26 / C-07: doc 07 §2.7.7's prep-action prices, which used to sit in
## `data/director.json`. `data/economy.json storm_prep` is the only place a storm
## preparation costs a dollar.
var _storm_prep: Dictionary = {}


func _init(building_economy: Dictionary, economy: Dictionary) -> void:
	_load(building_economy, economy)


static func load_from_files(
		building_economy_path: String = "res://data/building_economy.json",
		economy_path: String = "res://data/economy.json") -> CostCurves:
	var building_economy: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(building_economy_path))
	var economy: Variant = JSON.parse_string(FileAccess.get_file_as_string(economy_path))
	var curves := CostCurves.new(
			building_economy if building_economy is Dictionary else {},
			economy if economy is Dictionary else {})
	if not (building_economy is Dictionary):
		curves.errors.append("cannot parse %s" % building_economy_path)
	if not (economy is Dictionary):
		curves.errors.append("cannot parse %s" % economy_path)
	return curves


func is_valid() -> bool:
	return errors.is_empty()


func schema_version() -> int:
	return _schema_version


func economy_data() -> Dictionary:
	return _economy


func ids() -> Array:
	return _ids.duplicate()


## Resolves a doc-02 archetype id onto its doc-03 money row; returns the id
## unchanged when it is already a doc-03 id.
func resolve_type(type: String) -> String:
	if _archetypes.has(type):
		return type
	return String(_alias.get(type, type))


func has_type(type: String) -> bool:
	return _archetypes.has(resolve_type(type))


func class_of(type: String) -> String:
	return String(_row(type).get("class", ""))


func is_revenue_producing(type: String) -> bool:
	return REVENUE_CLASSES.has(class_of(type))


func build_cost_l1(type: String) -> int:
	return int(_row(type).get("build_cost_l1", 0))


## Difficulty is applied at spend time, never baked into the table (doc 03 §2.13).
func build_cost(type: String, m_build: float = 1.0) -> int:
	return round_half_up(float(build_cost_l1(type)) * m_build)


## doc 03 §2.2 — the published, normative rows (report 98 RR-5). `level` is 1-based.
func base_tax(type: String, level: int) -> int:
	var rows: Array = _row(type).get("base_tax_by_level", [])
	if level < 1 or level > rows.size():
		return 0
	return int(rows[level - 1])


## doc 03 §2.3 — the cost of the step `from_level → from_level + 1`.
func upgrade_cost(type: String, from_level: int, m_build: float = 1.0) -> int:
	var steps: Array = _row(type).get("upgrade_cost_by_step", [])
	if from_level < 1 or from_level > steps.size():
		return 0
	return round_half_up(float(steps[from_level - 1]) * m_build)


## doc 03 §2.3 — `build_cost_l1 × V(L)`; drives maintenance, repair, refunds.
func capital_value(type: String, level: int) -> int:
	var rows: Array = _row(type).get("capital_value_by_level", [])
	if level < 1 or level > rows.size():
		return 0
	return int(rows[level - 1])


## doc 03 §2.13(b) — the price of placing one grid component at `level`.
## `level` is 1-based; components priced as a flat scalar (tie switch) ignore it.
func grid_build_cost(component: String, level: int = 1, m_build: float = 1.0) -> int:
	return CostCurves.round_half_up(float(_grid_build_cost_l(component, level)) * m_build)


## doc 03 §2.5 — a grid component's repair capital is its §2.13(b) build cost at
## the current level; grid components are replaced, not upgraded. Same table as
## `grid_build_cost`, read for a different question.
func capital_value_grid(component: String, level: int = 1) -> int:
	return _grid_build_cost_l(component, level)


## doc 03 §2.13(f) (Wave 17) — re-rating a placed node onto a higher rung of
## its §2.13(b) ladder. **Priced as a replacement at the target level's full
## build cost**, which is the rule doc 04 §2.13 WE-1 has always quoted
## ("upgrade T7 to L4 — doc 03 price $6,900") and the reading §2.5 gives grid
## capital ("replaced, not upgraded"). No new magnitude: the same `build_cost`
## column, read at `to_level`. `from_level` is accepted so the accessor can
## refuse a downgrade the way §2.3 refuses one for buildings.
func grid_upgrade_cost(component: String, from_level: int, to_level: int,
		m_build: float = 1.0) -> int:
	if to_level <= from_level:
		return 0
	return grid_build_cost(component, to_level, m_build)


## doc 03 §2.13(f) — the per-tile price of re-conductoring a line onto a heavier
## class: the target class's own §2.13(b) per-tile price, charged on every tile
## of the run (the same tiles `line_km` bills), because the copper is replaced.
func grid_line_upgrade_cost_per_tile(kind: String, to_class: int,
		underground: bool = false) -> int:
	return grid_line_cost_per_tile(kind, to_class, underground)


## doc 03 §2.3's `DEMOLITION_REFUND_FRACTION`, applied to a grid component's
## §2.5 capital — its build cost at the current level. The same 0.25 buildings,
## road tiles and water mains return; grid components had no demolition verb
## until Wave 17 and so no accessor.
func grid_demolition_refund(component: String, level: int = 1) -> int:
	return demolition_refund(capital_value_grid(component, level))


func _grid_build_cost_l(component: String, level: int) -> int:
	var entry: Dictionary = _grid_components.get(component, {})
	var cost: Variant = entry.get("build_cost", null)
	if cost is Array:
		var rows: Array = cost
		if level < 1 or level > rows.size():
			return 0
		return int(rows[level - 1])
	if cost != null and not (cost is Dictionary):
		return int(cost)
	return 0


## doc 03 §2.13(b) — per-tile line costs (feeder is overhead; underground ×2.6).
func grid_line_cost_per_tile(kind: String, conductor_class: int, underground: bool = false) -> int:
	var entry: Dictionary = _grid_components.get(kind, {})
	var key := "cost_per_tile_overhead" if entry.has("cost_per_tile_overhead") else "cost_per_tile"
	var rows: Array = entry.get(key, [])
	if conductor_class < 1 or conductor_class > rows.size():
		return 0
	var cost := float(rows[conductor_class - 1])
	if underground:
		cost *= float(entry.get("underground_cost_mult", 1.0))
	return round_half_up(cost)


## doc 03 §8 `water` — the price of one doc-05 component at `level`.
##
## There is no new ladder and no new table of magnitudes: a water component is
## §2.13(a)'s `water_plant` anchor ($45,000, which IS doc 05's L1 pump reference
## variant) walked up §2.3's own `capital_value()` curve and scaled by doc 05's
## **dimensionless** `variant_cost_ratio_l1`. That ratio is the only thing doc 05
## contributes, exactly as C-16 has it contributing only `damage_fraction` to a
## repair — so it arrives as an ARGUMENT and this class still reads no file and
## knows nothing about `data/water.json`.
##
## L1, at ratio: source_river 0.84 → $37,800 · treatment 2.67 → $120,150 ·
## pump 1.00 → $45,000 · tank 1.33 → $59,850.
func water_component_build_cost(variant_ratio: float, level: int = 1,
		m_build: float = 1.0) -> int:
	return round_half_up(float(capital_value(WATER_ANCHOR_TYPE, level))
			* variant_ratio * m_build)


## The same anchor through §2.3's `upgrade_cost()` — the step `L → L+1`.
func water_component_upgrade_cost(variant_ratio: float, from_level: int,
		m_build: float = 1.0) -> int:
	return round_half_up(float(upgrade_cost(WATER_ANCHOR_TYPE, from_level))
			* variant_ratio * m_build)


## §2.5's repair capital for a component: its build price at the level standing.
func capital_value_water_component(variant_ratio: float, level: int) -> int:
	return water_component_build_cost(variant_ratio, level, 1.0)


## doc 03 §8 `water.main_build_cost_per_tile` — service $286, trunk $804,
## arterial $2,145 (see that block's `_main_derivation`).
func water_main_cost_per_tile(tier: String, m_build: float = 1.0) -> int:
	return round_half_up(float(_water_main_cost.get(tier, 0)) * m_build)


## §2.5's repair capital for a main: a break is dug up and replaced in full, so
## `MAIN_REPAIR_CAPITAL_FRACTION` is 1.00 — unlike a road tile's 0.20.
func capital_value_water_main(tier: String, tiles: int) -> int:
	return round_half_up(float(_water_main_cost.get(tier, 0)) * float(tiles)
			* _water_main_repair_capital_fraction)


## §2.3's demolition refund, at doc 03 §8 `water.demolish_refund_fraction`.
func water_demolition_refund(capital: int) -> int:
	return round_half_up(float(capital) * _water_demolish_refund_fraction)


## The §2.13(a) archetype every water price is anchored on.
const WATER_ANCHOR_TYPE := "water_plant"


## doc 03 §2.5 / §2.13(d) — STREET $360, AVENUE $1,040.
func capital_value_road(road_class: String) -> int:
	return round_half_up(float(_road_build_cost.get(road_class, 0))
			* _road_repair_capital_fraction)


func road_build_cost(road_class: String, m_build: float = 1.0) -> int:
	return round_half_up(float(_road_build_cost.get(road_class, 0)) * m_build)


func road_upgrade_cost(step: String = "STREET_TO_AVENUE", m_build: float = 1.0) -> int:
	return round_half_up(float(_road_upgrade_cost.get(step, 0)) * m_build)


## doc 03 §2.5 — THE repair price of the project (report 98 C-16). Every other
## system supplies only `damage_fraction ∈ [0,1]`.
func repair_cost(capital: int, damage_fraction: float, m_repair: float = 1.0) -> int:
	var fraction := clampf(damage_fraction, 0.0, 1.0)
	return round_half_up(float(capital) * fraction * _repair_cost_per_capital * m_repair)


func repair_cost_building(type: String, level: int, damage_fraction: float,
		m_repair: float = 1.0) -> int:
	return repair_cost(capital_value(type, level), damage_fraction, m_repair)


func repair_cost_road(road_class: String, damage_fraction: float, m_repair: float = 1.0) -> int:
	return repair_cost(capital_value_road(road_class), damage_fraction, m_repair)


## doc 03 §2.5's repair, read against a GRID component's capital (Wave 25,
## RR-206). **No new magnitude and no new ledger line**: §2.5's own bullet has
## published "grid components — their §2.13(b) build cost at the current level"
## since C-16, and `capital_value_grid` above has implemented it since Wave 17.
## What was missing was a COMMAND that spent it — the door
## `CitySim.cmd_repair_grid_component` now is. The charge books under the same
## `&"repair"` category `cmd_repair_building` and the road repair policy use, so
## the Economy ledger's `Repairs` line needs no new row either.
##
## `damage_fraction` is `PowerGrid.damage_fraction(id)`: the wear plus §2.6's
## own `FAILURE_DAMAGE` when the component is FAILED.
func repair_cost_grid(component: String, level: int, damage_fraction: float,
		m_repair: float = 1.0) -> int:
	return repair_cost(capital_value_grid(component, level), damage_fraction, m_repair)


## doc 03 §2.5's RESTORE row — the price of `CitySim.cmd_restore_building`, the
## one tap that brings a ruin back (Wave 18, doc 92 §54, doc 93 §AN).
##
## `capital × RESTORE_COST_FRACTION × M_repair`, and nothing else: no grace
## window, no level demotion, no second magnitude. The building comes back at the
## level it fell down at, so the player is never charged for a ladder they
## already climbed — and because the level survives, the CAPITAL the price is
## read off is the same capital on both sides of the event.
##
## **The fraction has a floor and a ceiling and it is pinned between them**
## (`data/economy.json.expenses._restore_note` carries the derivation, and
## `tests/test_economy.gd` pins the floor as an inequality rather than a
## constant): below 0.17 — the repair a MAINTAINING player buys at condition
## 0.80 — a restore would be cheaper than the maintenance it replaced and the
## game would pay for neglect; above ~0.55 — the repair at doc 02 §2.6's
## auto-damage line — it stops being a decision and becomes a crisis, which is
## the state the 2026-09-02 playtest was in.
func restore_cost(capital: int, m_repair: float = 1.0) -> int:
	return round_half_up(float(capital) * _restore_cost_fraction * m_repair)


func restore_cost_building(type: String, level: int, m_repair: float = 1.0) -> int:
	return restore_cost(capital_value(type, maxi(level, 1)), m_repair)


## The published fraction itself, for the doc and for the balance instruments.
func restore_cost_fraction() -> float:
	return _restore_cost_fraction


## What a RUIN is worth stripped (Wave 19, report 98 RR-171) — the money half of
## doc 02 §2.12's `destroyed → (removed)` row, which has had a table entry, a
## queue kind and a renderer arm since Wave 1 and never had a caller.
##
## `capital_value(level_at_destruction) × SALVAGE_FRACTION`, and the fraction is
## a CLOSED FORM rather than a fit: `DEMOLITION_REFUND_FRACTION − 0.10`, i.e.
## what an intact building is worth knocked down, less doc 02 §2.12's own
## authored rubble-clearance fraction. A ruin is worth its scrap less the mess.
##
## No `M_repair`, deliberately: this is not a repair and the difficulty presets
## scale what the city BUYS, never what it is paid. `capital_value` already
## carries the level, and the level a ruin is valued at is the one it fell down
## at — the same level `restore_cost_building` charges against, so a player can
## read the two numbers on one panel and they are about the same building.
func salvage_value(capital: int) -> int:
	return round_half_up(float(capital) * _salvage_fraction)


func salvage_value_building(type: String, level: int) -> int:
	return salvage_value(capital_value(type, maxi(level, 1)))


func salvage_fraction() -> float:
	return _salvage_fraction


# ============================== §2.5 city services and §2.5a grants (RR-78/78)

## Doc 03 §2.5's payout table for doc 06's dispatch and doc 12's street
## opportunities. The SHAPE of a payout is doc 06's (`data/incidents.json`'s
## `reward` block — tier and speed); every dollar in it is this file's.
func city_services() -> Dictionary:
	return _economy.get("city_services", {})


func dispatch_payout_base(type_id: String) -> float:
	return float((city_services().get("dispatch_payout_base", {}) as Dictionary)
			.get(type_id, 0.0))


## 1.50 — doc 06's own `speed_bonus_max`, paid only when a human made the call
## (`Incident.manual_requested`). Auto-dispatch pays 1.00.
##
## This is the premium at the FOUNDING city and it is the base of the level
## curve below; nothing but `manual_dispatch_mult_at_level` should read it as a
## payout multiplier.
func manual_dispatch_mult() -> float:
	return float(city_services().get("MANUAL_DISPATCH_MULT", 1.0))


## The dispatcher's premium AT A CITY LEVEL (Wave 19, RR-169):
## `MANUAL_DISPATCH_MULT + MANUAL_DISPATCH_LEVEL_K × (level − 1)`, floored at
## level 1 so a city that has not levelled pays exactly the number the founding
## anchor was measured with and every hash across the change is bit-identical.
##
## **The base is flat for the life of the city and that was the defect**
## (`data/economy.json` `_manual_level_k_derivation`): a resolved crime paid the
## same $595 on game-day one and game-day three hundred while the city's income
## per real-minute went 537.7 → 2,755.4, so the reward for answering an incident
## lost four fifths of its real value as the player got better. The curve closes
## most of that gap (4.00× by level 6) and deliberately not all of it (5.12×).
##
## Applied ONLY to a manually dispatched incident on a target doc 03 can price —
## see `CityIncidentWorld.dispatch_payout`, which is where the clamp that bounds
## it lives.
func manual_dispatch_mult_at_level(city_level: int) -> float:
	return manual_dispatch_mult() + manual_dispatch_level_k() * float(maxi(1, city_level) - 1)


## The slope of the curve above. 0.0 in a table that does not author it, which
## restores the pre-Wave-19 flat premium exactly.
func manual_dispatch_level_k() -> float:
	return float(city_services().get("MANUAL_DISPATCH_LEVEL_K", 0.0))


## The moral-hazard ceiling: a payout may never exceed this fraction of the loss
## it prevented. Derived in `data/economy.json`; applied inside
## `CityIncidentWorld.dispatch_payout()`, i.e. on doc 03's side of the seam, so
## `sim/incidents/` authors neither the price nor the ceiling. For the types
## whose targets this file prices no capital for, balance gate 31 holds the
## published table instead.
func moral_hazard_cap_fraction() -> float:
	return float(city_services().get("MORAL_HAZARD_CAP_FRACTION", 1.0))


## Doc 03 §2.5's bounty band for one doc 06 §2.16 opportunity kind, as
## `{base, spread}` — the floor of the band and its width, both dollars.
##
## **This file is where the street layer's money lives** (report 98 RR-85).
## `data/street.json` owns when a crook appears, where he stands and how long he
## waits; it owns no dollar, and `OpportunitySystem.configure()` refuses a table
## that carries one back — the same shape `IncidentCatalog` refuses `reward_base`
## under RR-78. An unpriced kind answers an EMPTY dictionary rather than a zero,
## so `has_street_payout()` can tell "priced at nothing" from "not priced", which
## is the difference between a design choice and a missing row.
func street_payout(kind: String) -> Dictionary:
	var row: Variant = (city_services().get("street_payout", {}) as Dictionary).get(kind, null)
	return (row as Dictionary) if row is Dictionary else {}


func has_street_payout(kind: String) -> bool:
	return not street_payout(kind).is_empty()


## Doc 03 §2.5b's payout band for one commission TIER, as `{base, spread}`
## (Wave 19, report 98 §60 RR-170).
##
## **This file is where the commissions board's money lives.**
## `data/contracts.json` owns which commissions exist, what they ask for and how
## long they run; it owns no dollar, and `ContractBoard.FORBIDDEN_KEYS` refuses
## one that comes back — the same guard RR-85 gave the street table. An unpriced
## tier answers an EMPTY dictionary rather than a zero, so `has_contract_payout`
## can tell "priced at nothing" from "not priced".
func contract_payout(tier: String) -> Dictionary:
	var row: Variant = (city_services().get("contract_payout", {}) as Dictionary).get(tier, null)
	return (row as Dictionary) if row is Dictionary else {}


func has_contract_payout(tier: String) -> bool:
	return not contract_payout(tier).is_empty()


func contract_payout_base(tier: String) -> float:
	return float(contract_payout(tier).get("base", 0.0))


func contract_payout_spread(tier: String) -> float:
	return float(contract_payout(tier).get("spread", 0.0))


## The commissions board's level curve — the same shape the street bounty uses,
## and steeper, because a commission is gated by city level in a way a kerb
## pickup is not. `mult(L) = 1 + k(L − 1)`, fitted to land the `major` band's
## FLOOR on the player's own $15,000 at the top rung.
func contract_reward_city_level_k() -> float:
	return float(city_services().get("CONTRACT_REWARD_CITY_LEVEL_K", 0.0))


## The ruled share of the city's net this layer may pay somebody who completes
## every commission it offers. Published for the balance instruments and for
## gate 32 arm (h); the thing that ENFORCES it is
## `data/contracts.json board.cooldown_h_after_claim`.
func contract_ceiling_share_max() -> float:
	return float(city_services().get("CONTRACT_CEILING_SHARE_MAX", 1.0))


func street_payout_base(kind: String) -> float:
	return float(street_payout(kind).get("base", 0.0))


func street_payout_spread(kind: String) -> float:
	return maxf(0.0, float(street_payout(kind).get("spread", 0.0)))


## The mean bounty of a kind, `base + spread/2`. The figure doc 03 §2.5's
## rulings are stated against: a band's mean is what a player earns and its top
## is what a player remembers.
func street_payout_mean(kind: String) -> float:
	return street_payout_base(kind) + 0.5 * street_payout_spread(kind)


## `k` in `reward × (1 + k·(city_level − 1))`. Moved here from
## `data/street.json`'s spawn block by RR-85 at the same value: it is a term in a
## dollar formula, so it is this file's under C-07.
func street_reward_city_level_k() -> float:
	return float(city_services().get("STREET_REWARD_CITY_LEVEL_K", 0.0))


func street_max_rate_per_game_hour() -> float:
	return float(city_services().get("STREET_MAX_RATE_PER_GAME_HOUR", 0.0))


func grants() -> Dictionary:
	return _economy.get("grants", {})


## The building auto-repair policy's two dials (99-PA PA-33, report 98 RR-150).
## Doc 03 holds them because the cap is dollars (C-07) and because the pass they
## bound spends against `repair_cost_building`; the THRESHOLD half of the block
## authors no number at all — it names doc 02 §2.6's own band keys and `CitySim`
## resolves them off the building's stamped rules.
func building_repair() -> Dictionary:
	return _economy.get("building_repair", {})


## Doc 03 §2.5a — the founding operating subsidy, in $/game-hour, on the settled
## game-day `day`. `share(day) = clamp(1 − day / FOUNDING_ASSISTANCE_DAYS, 0, 1)`,
## so it is the full civic bill on the founding day and exactly zero from
## `FOUNDING_ASSISTANCE_DAYS` onward. A published constant, never a fraction of
## the live bill: a subsidy that grew with the fleet would pay a player to buy
## vehicles.
func founding_assistance_per_hour(game_day: int) -> float:
	var days := float(grants().get("FOUNDING_ASSISTANCE_DAYS", 0.0))
	if days <= 0.0:
		return 0.0
	var share := clampf(1.0 - float(maxi(0, game_day)) / days, 0.0, 1.0)
	return float(grants().get("FOUNDING_ASSISTANCE_PER_HOUR", 0.0)) * share


## Doc 03 §2.5a — how many whole game-days of founding assistance are LEFT after
## the settled game-day `day`, and 0 once the taper has retired (Wave 17, doc 93
## §Y4, doc 92 §43.2, report 98 RR-102).
##
## It is the same two constants read the other way round, and it exists because
## the 2026-09-01 production audit measured the taper as the largest single
## income event of the opening fortnight and found it SILENT: the grant retires
## at `FOUNDING_ASSISTANCE_PER_HOUR / FOUNDING_ASSISTANCE_DAYS` every game-day —
## on the shipped constants **$24.57/gh, $589.71 a game-day** — while the city's
## own income grows an order of magnitude slower, so the opening reads as the
## game getting poorer while you play it and nothing on any surface says why.
## **No dollar moves for this** (doc 93 §Y4): the taper is correct and its
## invisibility was the defect, so doc 03 publishes the window and doc 12's
## budget row spends it on the row's own label.
func founding_assistance_days_left(game_day: int) -> int:
	var days := int(grants().get("FOUNDING_ASSISTANCE_DAYS", 0))
	return maxi(0, days - maxi(0, game_day))


## Doc 03 §2.5a — the celebration grant for reaching `city_level`, paid once per
## level per city. Index 0 is the founding level and pays nothing; a level above
## the published ladder pays nothing rather than extrapolating itself.
func level_up_grant(city_level: int) -> int:
	var ladder: Array = grants().get("LEVEL_UP_GRANT_BY_CITY_LEVEL", [])
	if city_level < 0 or city_level >= ladder.size():
		return 0
	return int(ladder[city_level])


## doc 03 §2.5 — preventive maintenance, allowed on condition ∈ [PM_MIN, 0.99].
func pm_cost(capital: int) -> int:
	return round_half_up(float(capital) * _pm_cost_fraction)


func pm_allowed(condition: float) -> bool:
	return condition >= _pm_min_condition and condition <= 0.99


## doc 07 §2.7.7 preparation, priced by doc 03 (99-PA PA-26 / C-07). `units` is
## the thing being bought more than one of — crews for `pre_stage_crews`, cubic
## metres for `top_off_water` — and is 1 for the flat-rate actions. An unknown
## action costs nothing rather than crashing: the command layer refuses it by
## name before it ever gets here, and a price table is not the place to raise.
func storm_prep_cost(action_id: String, units: float = 1.0) -> int:
	match action_id:
		"pre_stage_crews":
			return round_half_up(float(_storm_prep.get("pre_stage_crews_per_crew", 0))
					* maxf(0.0, units))
		"top_off_water":
			return round_half_up(float(_storm_prep.get("top_off_water_per_m3", 0))
					* maxf(0.0, units))
		_:
			return round_half_up(float(_storm_prep.get(action_id, 0)))


## doc 03 §2.5 — money-for-time valve, deliberately bad value.
func contractor_cost(job_cost: int) -> int:
	return round_half_up(float(job_cost) * _contractor_surcharge)


## doc 03 §2.13(f) — what one crew-hour of a project's REMAINING duration costs
## to buy outright, in dollars, for a project whose cash price is `job_cost` and
## whose full length is `required_crew_hours`.
##
## The rate is per-project, not per-hour-of-the-city, because the roster's
## dollars-per-crew-hour spans **15×** (house $600/ch → data_center $9,000/ch on
## the §2.13(a) build column against doc 02's `build_time_hours`). A flat rate
## would make rushing a tower nearly free and rushing a shack ruinous.
func rush_rate_per_crew_hour(job_cost: int, required_crew_hours: float) -> float:
	if job_cost <= 0 or required_crew_hours <= 0.0:
		return 0.0
	return float(job_cost) * _rush_surcharge_per_duration / required_crew_hours


## doc 03 §2.13(f) — the quoted price of finishing a project NOW.
##
## `remaining / required` is `1 − progress`, taken from `ConstructionQueue`'s own
## exact integer accumulator, so the quote and the work agree by construction.
##
## **Ceiling, not §2.1's half-up, and this is the one price in the ladder that
## rounds that way** — §2.13(f) states the exception and the reason: this is the
## only price computed against a live, continuously moving quantity, and half-up
## would let a project at 99.9 % quote **$0** and hand the player the last of the
## time for none of the money. The valve may be bad value; it may not be free.
func rush_cost(job_cost: int, required_crew_hours: float,
		remaining_crew_hours: float) -> int:
	var rate := rush_rate_per_crew_hour(job_cost, required_crew_hours)
	if rate <= 0.0:
		return 0
	var remaining := clampf(remaining_crew_hours, 0.0, required_crew_hours)
	if remaining <= 0.0:
		return 0
	return ceili(remaining * rate)


# ------------------------------------------------------------- refunds / resale

## doc 03 §2.3 — demolition returns 0.25 × capital_value. Downgrade is not permitted.
func demolition_refund(capital: int) -> int:
	return round_half_up(float(capital) * _demolition_refund_fraction)


func demolition_refund_building(type: String, level: int) -> int:
	return demolition_refund(capital_value(type, level))


## The published fraction itself. `SALVAGE_FRACTION` is derived FROM it (Wave 19,
## RR-171), and the bound "a wreck is never worth more than the same building
## knocked down intact" is checked against it rather than against a literal.
func demolition_refund_fraction() -> float:
	return _demolition_refund_fraction


## doc 03 §2.13(d) — STREET $450, AVENUE $1,300.
func road_demolish_refund(road_class: String) -> int:
	return round_half_up(float(_road_build_cost.get(road_class, 0))
			* _road_demolish_refund_fraction)


## doc 03 §2.4 / §2.13(c) — 0.40 × purchase, every type.
func vehicle_purchase(vehicle_type: String, m_build: float = 1.0) -> int:
	return round_half_up(float(_vehicles.get(vehicle_type, {}).get("purchase", 0)) * m_build)


func vehicle_resale(vehicle_type: String) -> int:
	return round_half_up(float(_vehicles.get(vehicle_type, {}).get("purchase", 0))
			* _vehicle_resale_fraction)


func vehicle_row(vehicle_type: String) -> Dictionary:
	return _vehicles.get(vehicle_type, {})


## doc 03 §2.10 — undeveloped land sells for 0.55 × current price.
func land_resale(current_price: int) -> int:
	return round_half_up(float(current_price) * _land_resale_fraction)


# ------------------------------------------------------------------- plumbing

## doc 03 rounds half-up throughout (§2.8). Symmetric about zero.
static func round_half_up(value: float) -> int:
	if value < 0.0:
		return -int(floor(-value + 0.5 + ROUND_EPSILON))
	return int(floor(value + 0.5 + ROUND_EPSILON))


func _row(type: String) -> Dictionary:
	return _archetypes.get(resolve_type(type), {})


func _load(building_economy: Dictionary, economy: Dictionary) -> void:
	_economy = economy
	_schema_version = int(building_economy.get("schema_version", 0))
	if _schema_version <= 0:
		errors.append("building_economy: missing schema_version")

	var upgrades: Dictionary = economy.get("upgrades", {})
	var tax: Dictionary = economy.get("tax", {})
	var expenses: Dictionary = economy.get("expenses", {})
	var roads: Dictionary = economy.get("roads", {})
	var land: Dictionary = economy.get("land", {})
	for block_name in ["tax", "upgrades", "expenses", "roads", "land"]:
		if not economy.has(block_name):
			errors.append("economy.json: missing block '%s'" % block_name)

	_tax_level_growth = float(tax.get("TAX_LEVEL_GROWTH", 0.0))
	_upg_coeff = float(upgrades.get("UPG_COEFF", 0.0))
	_upg_growth = float(upgrades.get("UPG_GROWTH", 0.0))
	_capital_value_v = upgrades.get("CAPITAL_VALUE_V", [])
	_demolition_refund_fraction = float(upgrades.get("DEMOLITION_REFUND_FRACTION", 0.0))
	_repair_cost_per_capital = float(expenses.get("REPAIR_COST_PER_CAPITAL", 0.0))
	_restore_cost_fraction = float(expenses.get("RESTORE_COST_FRACTION", 0.0))
	_salvage_fraction = float(expenses.get("SALVAGE_FRACTION", 0.0))
	_pm_cost_fraction = float(expenses.get("PM_COST_FRACTION", 0.0))
	_pm_min_condition = float(expenses.get("PM_MIN_CONDITION", 0.0))
	_vehicle_resale_fraction = float(expenses.get("VEHICLE_RESALE_FRACTION", 0.0))
	_contractor_surcharge = float(expenses.get("CONTRACTOR_SURCHARGE", 0.0))
	_contractor_time_fraction = float(expenses.get("CONTRACTOR_TIME_FRACTION", 0.0))
	_rush_surcharge_per_duration = float(
			expenses.get("RUSH_SURCHARGE_PER_DURATION", 0.0))
	_grid_components = expenses.get("grid_components", {})
	_vehicles = expenses.get("vehicles", {})
	_storm_prep = economy.get("storm_prep", {})
	var water: Dictionary = economy.get("water", {})
	_water_main_cost = water.get("main_build_cost_per_tile", {})
	_water_main_repair_capital_fraction = float(
			water.get("MAIN_REPAIR_CAPITAL_FRACTION", 1.0))
	_water_demolish_refund_fraction = float(
			water.get("demolish_refund_fraction", _demolition_refund_fraction))
	_road_repair_capital_fraction = float(roads.get("ROAD_REPAIR_CAPITAL_FRACTION", 0.0))
	_road_demolish_refund_fraction = float(roads.get("demolish_refund_fraction", 0.0))
	_road_build_cost = roads.get("build_cost_per_tile", {})
	_road_upgrade_cost = roads.get("upgrade_cost_per_tile", {})
	_land_resale_fraction = float(land.get("LAND_RESALE_FRACTION", 0.0))

	if _capital_value_v.size() < LEVELS_PER_ARCHETYPE \
			or _capital_value_v.size() > TOP_LEVELS_PER_ARCHETYPE:
		errors.append("economy.json upgrades.CAPITAL_VALUE_V carries %d levels, expected %d–%d"
				% [_capital_value_v.size(), LEVELS_PER_ARCHETYPE, TOP_LEVELS_PER_ARCHETYPE])
	if _repair_cost_per_capital <= 0.0:
		errors.append("economy.json expenses.REPAIR_COST_PER_CAPITAL missing")
	# doc 93 §AN's floor, re-checked at load exactly as the rush rate below is:
	# a restore must never be cheaper than the repair a MAINTAINING player buys
	# (doc 92 §43.1's `balanced` agent repairs at condition 0.80, i.e. a damage
	# fraction of 0.20). A table edit that dropped below it would silently make
	# the game pay for neglect, and the boot has to say so rather than the
	# balance drifting.
	if _restore_cost_fraction <= 0.0:
		errors.append("economy.json expenses.RESTORE_COST_FRACTION missing")
	elif _restore_cost_fraction < MAINTAINER_DAMAGE_FRACTION * _repair_cost_per_capital:
		errors.append(("economy.json expenses.RESTORE_COST_FRACTION %.4f is below the "
				+ "maintainer repair floor %.4f (%.2f × REPAIR_COST_PER_CAPITAL %.2f) — "
				+ "letting a building fall down would be cheaper than keeping it up")
				% [_restore_cost_fraction,
				MAINTAINER_DAMAGE_FRACTION * _repair_cost_per_capital,
				MAINTAINER_DAMAGE_FRACTION, _repair_cost_per_capital])
	# doc 03 §2.13(f): the rush rate is not an independent number. §2.5's
	# emergency-contractor row already publishes the price of time — it buys
	# `1 − CONTRACTOR_TIME_FRACTION` of a project's duration for a surcharge of
	# `CONTRACTOR_SURCHARGE − 1` of its cash price — and the rush is that same
	# rate carried to its limit. The constant is PUBLISHED (C-07: a price lives
	# in this file, not in a runtime expression) and re-checked here, so it can
	# never drift away from the row it came from without the boot saying so.
	if _rush_surcharge_per_duration <= 0.0:
		errors.append("economy.json expenses.RUSH_SURCHARGE_PER_DURATION missing")
	elif _contractor_time_fraction < 1.0:
		var derived := (_contractor_surcharge - 1.0) / (1.0 - _contractor_time_fraction)
		if absf(_rush_surcharge_per_duration - derived) > RUSH_DERIVATION_TOLERANCE:
			errors.append(("economy.json expenses.RUSH_SURCHARGE_PER_DURATION is %.5f;"
					+ " §2.5's contractor row derives %.5f") % [
					_rush_surcharge_per_duration, derived])

	_alias = building_economy.get("doc02_archetype_alias", {})
	var archetypes: Dictionary = building_economy.get("archetypes", {})
	if archetypes.is_empty():
		errors.append("building_economy: no archetypes")
	_ids = archetypes.keys()
	_ids.sort()
	for id in _ids:
		var row: Dictionary = archetypes[id]
		_archetypes[String(id)] = row
		for key in REQUIRED_ARCHETYPE_KEYS:
			if not row.has(key):
				errors.append("%s: missing key '%s'" % [id, key])
		_validate_row(String(id), row)


## Re-checks the generator's own contract at load: every generated cell must sit
## within ±$1 of the curve (doc 03 §7 test 8; RR-5 locks three base_tax cells and
## the CAPITAL_VALUE_V vector produces the published capital cells).
func _validate_row(id: String, row: Dictionary) -> void:
	var cost := float(row.get("build_cost_l1", 0))
	var base_tax_l1 := float(row.get("base_tax_l1", 0))
	var taxes: Array = row.get("base_tax_by_level", [])
	var steps: Array = row.get("upgrade_cost_by_step", [])
	var capitals: Array = row.get("capital_value_by_level", [])
	# How tall this archetype's money ladder is. Six of doc 03's fourteen rows
	# gained a sixth rung with doc 02's growth stock (doc 92 §24); the rest still
	# stop at five, so the height is READ off the row rather than assumed, and it
	# is the same number in all three columns or the row is malformed.
	var levels: int = taxes.size()
	if levels < LEVELS_PER_ARCHETYPE or levels > TOP_LEVELS_PER_ARCHETYPE:
		errors.append("%s: base_tax_by_level carries %d levels, expected %d–%d"
				% [id, levels, LEVELS_PER_ARCHETYPE, TOP_LEVELS_PER_ARCHETYPE])
		return
	if capitals.size() != levels:
		errors.append("%s: capital_value_by_level carries %d levels, base_tax carries %d"
				% [id, capitals.size(), levels])
		return
	if steps.size() != levels - 1:
		errors.append("%s: upgrade_cost_by_step must carry %d steps, carries %d"
				% [id, levels - 1, steps.size()])
		return
	if levels > _capital_value_v.size():
		errors.append("%s: %d levels but economy.json CAPITAL_VALUE_V carries %d"
				% [id, levels, _capital_value_v.size()])
		return
	if not REVENUE_CLASSES.has(String(row.get("class", ""))) and base_tax_l1 != 0.0:
		errors.append("%s: civic/utility archetypes carry base_tax 0 (doc 03 §2.2)" % id)
	for level in range(1, levels + 1):
		var expected_tax := round_half_up(base_tax_l1 * pow(_tax_level_growth, level - 1))
		if absi(int(taxes[level - 1]) - expected_tax) > GENERATED_CELL_TOLERANCE:
			errors.append("%s base_tax L%d: %d vs curve %d (>±$%d)"
					% [id, level, int(taxes[level - 1]), expected_tax, GENERATED_CELL_TOLERANCE])
		var expected_capital := round_half_up(cost * float(_capital_value_v[level - 1]))
		if absi(int(capitals[level - 1]) - expected_capital) > GENERATED_CELL_TOLERANCE:
			errors.append("%s capital_value L%d: %d vs curve %d (>±$%d)"
					% [id, level, int(capitals[level - 1]), expected_capital,
					GENERATED_CELL_TOLERANCE])
	for step in range(1, levels):
		var expected_step := round_half_up(cost * _upg_coeff * pow(_upg_growth, step - 1))
		if absi(int(steps[step - 1]) - expected_step) > GENERATED_CELL_TOLERANCE:
			errors.append("%s upgrade_cost step %d: %d vs curve %d (>±$%d)"
					% [id, step, int(steps[step - 1]), expected_step, GENERATED_CELL_TOLERANCE])

class_name RequirementFormatter
extends RefCounted
## Doc 12 §2.7's single formatter: a **stable sim failure code** in, player
## readable copy out. Used identically by placement (`BuildController`), by the
## building panel's upgrade checklist and — when it lands — by the land panel.
##
## Constitution §3 / doc 12 §1: pure `RefCounted`, no `Node`, no scene tree, so
## every string is reachable from a headless test. Doc 12 §3.1 (G-8): **no
## display copy lives in this file**. Every template resolves from
## `data/strings.en.json` through `UIConfig.t()`:
##
##     ui_requirement_<code_lowercase>            the body template
##     ui_requirement_<code_lowercase>_title      the chip / checklist label
##     ui_requirement_<code_lowercase>_remedy     the "what to do" half
##
## The remedy is resolved first and handed to the body as `{remedy}`, which is
## why the doc's worked examples read as one sentence pair. A missing key falls
## back to a *structural* rendering (`CODE: have / need`) rather than to English
## authored here — a missing template must look wrong, not merely terse.
##
## ## Two code vocabularies, one table
##
## Doc 12 §4.4 names 13 codes (`POWER_CAPACITY` … `E_AVENUE`); `sim/city_sim.gd`
## raises its own 13 (`E_UNKNOWN_ARCHETYPE` … `E_AVENUE`). Six of the sim's codes
## are the doc's code under another spelling, so `ALIASES` folds them onto the
## doc's name and the remaining seven get their own entry. Copy is therefore
## keyed by the doc's vocabulary while the sim keeps its own identifiers — the
## split C-62 asked for, with nothing duplicated.
##
## ## The `fix_target` contract (Wave 18, PA-05 · doc 12 §2.7a · RR-142)
##
## Every row this class formats carries
##
##     fix_target = {"kind": StringName, "id": String, "params": Dictionary}
##
## `kind` is one of the `FIX_*` constants below, `id` is the entity that kind
## names, and **`params` is what the router needs in order to ACT**. Before this
## wave the pair was `{kind, id}` alone, and two of the building panel's seven
## checklist rows were dead because of it: `POWER_CAPACITY` handed a TRANSFORMER
## id to a branch that looked buildings up by it, and `E_AVENUE` handed an empty
## id to a router whose first line discards those. An id with no way to resolve
## it is not a target; it is a button that does nothing.
##
## `ui/fix_router.gd` is the only consumer. The table is normative — a producer
## that cannot fill a row's `params` must route `FIX_NONE` rather than ship a
## button the router will drop on the floor:
##
## | kind               | `id`                    | `params` the router acts on |
## |--------------------|-------------------------|-----------------------------|
## | `FIX_NONE`         | `""`                    | `{}` — no button is drawn |
## | `FIX_BUILDING`     | `sim_id`                | `{tile: Vector2i}` the building's origin |
## | `FIX_BLOCK`        | `block_id`              | `{tile: Vector2i, block_id: String}` — the tile is the block's, when the producer knows it |
## | `FIX_TILE`         | `""`                    | `{tile: Vector2i}` — **required**; the tile IS the target |
## | `FIX_DISTRICT`     | district / zone key     | `{district_id: String, tile: Vector2i}` |
## | `FIX_ROAD_SEGMENT` | segment id, or `""`     | `{tile: Vector2i}` the nearest tile of the road the row is short of |
## | `FIX_COMPONENT`    | grid / water component  | `{component: String}` — resolve with `PowerGrid.component_tile()` |
## | `FIX_REPAIR`       | `sim_id`                | `{verb: "cmd_repair_building", cost: int, cost_text: String}` |
## | `FIX_POWER`        | `sim_id`                | `{verb: "cmd_fix_power_capacity", cost: int, cost_text: String}` |
##
## **The invariant the router may rely on** (`_is_routable`, checked by `format()`
## on every row it emits): if `kind != FIX_NONE` then the `params` that kind's row
## requires are present. A row whose producer could not fill them is folded to
## `FIX_NONE` here, with an empty `id` and empty `params`, so a consumer never has
## to defend against a half-filled target — and a surface that draws its button on
## `kind != FIX_NONE` alone (which the building panel does, and did before this
## was true) is drawing it exactly when there is somewhere to go.
##
## The two verb kinds are performed **in place** by `ui/building_panel.gd` and
## never reach the router (A91-D-54); their `params` exist so a second surface
## can offer the same purchase without re-deriving the quote.
##
## `params` is assembled by `_fix_params_for()` from the same raw dictionary the
## row's `{named}` arguments come from, so a producer that already passes `tile`,
## `block_id` or `at` gets a routable target for free. A producer that knows
## better may pass `fix_target_params` and it is merged over the derived table.

# --- Severity (doc 12 §2.7's VALID / WARN / BLOCKED verdict ladder) -----------
const SEVERITY_BLOCKED := &"blocked"  ## hard gate: the command will be refused
const SEVERITY_WARN := &"warn"        ## placeable, a soft requirement unmet
const SEVERITY_INFO := &"info"        ## nothing to fix (already at max level)

# --- `Fix this →` routing (doc 12 §2.7) --------------------------------------
const FIX_NONE := &"none"
const FIX_BUILDING := &"building"
const FIX_BLOCK := &"block"
const FIX_TILE := &"tile"
const FIX_DISTRICT := &"district"
## C-62: `E_AVENUE` is the one requirement whose fix target is a ROAD SEGMENT.
const FIX_ROAD_SEGMENT := &"road_segment"
## `E_CONDITION`'s fix is not a place, it is a PURCHASE. Every other kind here
## answers "where do I go?"; this one answers "what do I buy?", and the building
## panel performs it in place rather than emitting it to the camera router —
## focusing the camera on the building the player already has open moves nothing,
## which is what `Fix this →` did on this row before doc 02 §2.6's repair had a
## door (doc 92 §17.6).
const FIX_REPAIR := &"repair"
## `POWER_CAPACITY`'s fix is a PURCHASE too, and it was the wrong kind for three
## waves. It routed `FIX_BUILDING`, and `game/main.gd`'s router answers that kind
## by focusing the camera on the building — which is the building the player
## already has open, so the row's whole affordance was a no-op (the lead's
## Wave-17 reproduction, A91-D-54). It now routes here, and the building panel
## performs it in place: `CitySim.cmd_fix_power_capacity` quotes the cheapest
## single purchase that clears the serving path, the strip shows the price, and
## the second tap buys it. Same shape as `FIX_REPAIR`, one row down.
const FIX_POWER := &"power"
## A doc 04 grid component or a doc 05 water component — a SUBSTATION, a
## transformer, a pump. Not a `Building`, which is why it needs a kind of its
## own: `FIX_BUILDING` resolves through `CitySim.buildings`, and a transformer id
## (`T-06`, from `PowerGrid.attachment_of()`) is not a key in that dictionary —
## measured on the founding city, where `sim.buildings.has("T-06")` is `false`
## and `component_tile("T-06")` is `(39, 34)`. A doc 04 SUBSTATION is the
## exception that proves it: `SUB-A` is also a doc 02 shell and is in
## `buildings`, which is why `E_NO_SLOT` correctly stays `FIX_BUILDING`.
const FIX_COMPONENT := &"component"

## Every kind this class can emit, for the lint that walks them (doc 12 §2.7a).
const FIX_KINDS: Array[StringName] = [
	FIX_NONE, FIX_BUILDING, FIX_BLOCK, FIX_TILE, FIX_DISTRICT, FIX_ROAD_SEGMENT,
	FIX_REPAIR, FIX_POWER, FIX_COMPONENT,
]

## The two kinds the building panel performs in place rather than emitting to
## the camera router (A91-D-54) — a purchase, not a place.
const FIX_VERB_KINDS: Array[StringName] = [FIX_REPAIR, FIX_POWER]

## `params["verb"]` for the two purchase kinds: the `CitySim` command the strip
## spends through. Named here rather than in the panel so a second surface
## offering the same purchase cannot drift onto a different command.
const FIX_VERBS := {
	FIX_REPAIR: "cmd_repair_building",
	FIX_POWER: "cmd_fix_power_capacity",
}

const KEY_PREFIX := "ui_requirement_"
const TITLE_SUFFIX := "_title"
const REMEDY_SUFFIX := "_remedy"
const UNKNOWN_CODE := &"UNKNOWN"

## Sim spelling → doc 12 §4.4 spelling. Everything not listed here is already
## canonical (the doc's own name, or a sim code the doc's 13 do not cover).
const ALIASES := {
	&"E_POWER_HEADROOM": &"POWER_CAPACITY",
	&"E_CITY_LEVEL": &"CITY_LEVEL",
	&"E_FUNDS": &"FUNDS",
	&"E_FOOTPRINT": &"OCCUPIED",
	&"E_NOT_OWNED": &"NOT_OWNED",
	&"E_NOT_DEVELOPED": &"UNDEVELOPED",
}

## Canonical code → {severity, fix}. The 13 of doc 12 §4.4 first, then the seven
## `sim/city_sim.gd` codes the doc's list does not name.
const CODE_TABLE := {
	&"POWER_CAPACITY": {"severity": SEVERITY_BLOCKED, "fix": FIX_POWER},
	&"WATER_PRESSURE": {"severity": SEVERITY_BLOCKED, "fix": FIX_DISTRICT},
	&"NO_ROAD": {"severity": SEVERITY_BLOCKED, "fix": FIX_ROAD_SEGMENT},
	&"NO_CREW": {"severity": SEVERITY_WARN, "fix": FIX_BUILDING},
	&"FIRE_COVERAGE": {"severity": SEVERITY_BLOCKED, "fix": FIX_DISTRICT},
	&"CITY_LEVEL": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"FUNDS": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"OCCUPIED": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"NOT_OWNED": {"severity": SEVERITY_BLOCKED, "fix": FIX_BLOCK},
	&"UNDEVELOPED": {"severity": SEVERITY_BLOCKED, "fix": FIX_BLOCK},
	&"TERRAIN": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"TECH_LOCK": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_AVENUE": {"severity": SEVERITY_BLOCKED, "fix": FIX_ROAD_SEGMENT},
	&"E_UNSERVED": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_STATE": {"severity": SEVERITY_BLOCKED, "fix": FIX_BUILDING},
	&"E_CONDITION": {"severity": SEVERITY_BLOCKED, "fix": FIX_REPAIR},
	&"E_MAX_LEVEL": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	&"E_UNKNOWN_ARCHETYPE": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_UNKNOWN_BUILDING": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_NO_FEEDER": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_AUSTERITY": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	# --- Wave 19: doc 03 §2.5b's commissions board (report 98 §60 RR-170). All
	# five route `FIX_NONE`, and that is the right answer rather than a stub:
	# every one of them is answered on the band the player is already looking at
	# — the commission in hand, the clock on it, or the offers under it — so a
	# `Fix this →` could only focus the camera on a screen that is already open.
	&"E_CONTRACT_ACTIVE": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_CONTRACT_COOLDOWN": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	&"E_UNKNOWN_CONTRACT": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_CONTRACT_UNMET": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	&"E_NO_CONTRACT": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	# --- Wave 5: the infrastructure verbs (doc 05 §6 water, doc 10 §2.13 roads).
	# Placement's `E_UNSERVED` twin for water, and the roster/level rows the
	# INFRASTRUCTURE tab can now show on a card it refuses to place.
	&"E_UNKNOWN_COMPONENT": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_LEVEL_UNAVAILABLE": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_VARIANT_LOCKED": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_OUT_OF_BOUNDS": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_NO_MAIN": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_NO_WATER": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_MAIN_OVERLAP": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_UNKNOWN_TIER": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_TIER_LOCKED": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	# Doc 10 §2.13's own vocabulary. `E_WATER` is a road on a water tile, which
	# is a different refusal from water's `E_NO_WATER` (an intake off the river).
	&"E_UNKNOWN_ROAD_CLASS": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_NO_TILES": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_ALREADY_ROAD": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	&"E_NOT_CONNECTED": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_WATER": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_NOT_ROAD": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_NO_ELIGIBLE_TILES": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_WOULD_ORPHAN": {"severity": SEVERITY_BLOCKED, "fix": FIX_ROAD_SEGMENT},
	# --- Wave 10: the building panel's ACTIONS row (doc 12 §2.9 item 6). Doc
	# 02 §2.6's repair, doc 04 §2.4's shed tier and doc 02 §2.12's demolition
	# all shipped without a surface; these are the three refusals the row can
	# now put in front of a player. Two of them are INFO rather than BLOCKED,
	# because "it is already being repaired" is news, not a fault.
	&"E_NOT_DAMAGED": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	# Doc 02 §2.6a (doc 93 §Y1/§Y3a). `repair_view` folds this into "nothing
	# to buy" and never draws a row for it, so this entry exists only so the
	# code can never fall through to UNKNOWN and print itself at a player —
	# the failure shape PA-24 found on `E_WATER_HEADROOM`.
	&"E_OWNER_MAINTAINED": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	&"E_JOB_IN_FLIGHT": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	# Wave 25, doc 04 §2.15.2's `cmd_repair_grid_component` (report 98 §68 RR-206).
	# `E_JOB_IN_FLIGHT`'s twin for a grid component, and a SEPARATE code rather
	# than a re-use, because the two carry different copy: one says a crew is on
	# this BUILDING, the other says a crew is on the transformer that feeds a
	# street of them. INFO for the same reason its twin is — "it is already being
	# repaired" is news, not a fault.
	&"E_ALREADY_REPAIRING": {"severity": SEVERITY_INFO, "fix": FIX_COMPONENT},
	# Wave 18, doc 02 §2.12's restore. `cmd_restore_all_destroyed` answers this
	# on a healthy city and `BuildController` draws no batch row for it — the
	# entry exists for the same reason `E_OWNER_MAINTAINED`'s does, so the code
	# can never fall through to UNKNOWN and print itself at a player.
	&"E_NO_RUINS": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	&"E_UNKNOWN_PRIORITY": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	# --- Wave 6: doc 09 §2.5's land verbs, surfaced by S4 (doc 12 §2.8).
	# `WorldMap.purchase_allowed` raises the first three and
	# `CitySim.cmd_start_development` the fourth; two of them are INFO rather
	# than BLOCKED, because "you already own this" is an answer, not a fault.
	&"E_NOT_ADJACENT": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_ALREADY_OWNED": {"severity": SEVERITY_INFO, "fix": FIX_BLOCK},
	&"E_UNKNOWN_BLOCK": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_ALREADY_DEVELOPING": {"severity": SEVERITY_INFO, "fix": FIX_BLOCK},
	# --- Wave 11: doc 04 §4's `route_feeder` on the drag-path tool, and doc 05
	# §6's node verbs on S5 / S6. Every one of these is a refusal the two new
	# surfaces can now put in front of a player and none had copy. `E_NO_SLOT`
	# is the interesting one: its fix is a BUILDING (doc 04 §2.2's ladder — buy
	# or upgrade the substation), so it routes the camera like `POWER_CAPACITY`.
	&"E_CLASS_UNAVAILABLE": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_DISCONTINUOUS": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	# **Stays `FIX_BUILDING`, and that is measured** (Wave 18, PA-05). A doc 04
	# substation is also a doc 02 SHELL — `sim.buildings.has("SUB-A")` is `true`
	# on the founding city and `substation` is an archetype the build sheet sells
	# — so this id resolves and the camera move is the whole useful answer, which
	# is what doc 12 D-71 ruled deliberate. The component namespace below is a
	# different thing: `attachment_of("H-001")` answers `T-06`, which is NOT a
	# building.
	&"E_NO_SLOT": {"severity": SEVERITY_BLOCKED, "fix": FIX_BUILDING},
	&"E_UNKNOWN_NODE": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_NOT_UPGRADEABLE": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	&"E_UNKNOWN_MAIN": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_NOT_ISOLATED": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	# --- Wave 12: doc 06 §2.11's recall (A91-D-24) and doc 10 §2.13's
	# auto-repair dials. `E_UNIT_NOT_DEPLOYED` is INFO for the same reason
	# `E_NOT_ISOLATED` is: "that unit is already home" is news about the world,
	# not a fault in what the player asked for.
	&"E_UNIT_NOT_DEPLOYED": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	&"E_UNKNOWN_UNIT": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_BAD_THRESHOLD": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	# --- Wave 17: doc 04 §4's operating verbs (doc 93 §AD). `E_TRANSFORMER_FULL`
	# is the one WARN in the placement ladder — doc 04 §2.1 gates a placement on
	# coverage and authorises no capacity refusal, so a full transformer under
	# the ghost is a fact the player is told, not a tile they are refused (§AD3).
	# `E_NEEDS_TRANSFORMER` is the top of the ladder: nothing the fix strip can
	# buy in one tap clears it, and the answer is a tile the player has to pick.
	# Wave 18 (PA-05): both of these name a TRANSFORMER, and a transformer is a
	# doc 04 component (`T-06`), not a `Building` — `CitySim.buildings` has no
	# such key. They routed `FIX_TILE` with the GHOST's tile, which is the tile
	# the player's finger is already on, so the button answered "go to where you
	# are" (doc 12 D-35's lesson). `FIX_COMPONENT` is the namespace they are in
	# and `PowerGrid.component_tile()` is what resolves it — measured on the
	# founding city: `component_tile("T-06")` = `(39, 34)`.
	&"E_TRANSFORMER_FULL": {"severity": SEVERITY_WARN, "fix": FIX_COMPONENT},
	&"E_NEEDS_TRANSFORMER": {"severity": SEVERITY_BLOCKED, "fix": FIX_COMPONENT},
	&"E_NOT_BLOCKED": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	# --- Wave 18: doc 02 §2.11's SEVENTH upgrade gate (PA-24). `city_sim.gd`
	# has appended `E_WATER_HEADROOM` since the water system landed and no
	# surface has ever named it: the panel drew six green ticks, printed "Every
	# requirement met." and left UPGRADE dead. Its fix is doc 05's DISTRICT —
	# the pressure zone that is short, not the building that is thirsty.
	&"E_WATER_HEADROOM": {"severity": SEVERITY_BLOCKED, "fix": FIX_DISTRICT},
	# --- Wave 18: doc 06 §2.6's three dispatch refusals (PA-52). `cmd_dispatch_
	# unit` has raised all three since Wave 4 and the picker collapsed every one
	# of them to "That unit could not be sent." `E_UNKNOWN_INCIDENT` is INFO for
	# the same reason `E_NOT_ISOLATED` is: the call cleared while the sheet was
	# open, which is news about the world and not a fault in the ask.
	&"E_UNIT_UNAVAILABLE": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_UNREACHABLE": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_UNKNOWN_INCIDENT": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	UNKNOWN_CODE: {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
}

## Severity → the doc §2.5 state token the view tints with. Four data states, so
## a requirement row is readable without colour (A5, A14).
const SEVERITY_STATE := {
	SEVERITY_BLOCKED: HudModel.STATE_CRITICAL,
	SEVERITY_WARN: HudModel.STATE_WARNING,
	SEVERITY_INFO: HudModel.STATE_OFFLINE,
}

## Checklist glyphs (doc 12 §2.9 item 5: "each line `✓`/`✗`"). Glyphs, not copy —
## same contract as `HudModel.STATE_GLYPH_CHARS`.
const GLYPH_PASS := "✓"
const GLYPH_FAIL := "✗"

const KW_PER_MW := 1000.0

var config: UIConfig


func _init(cfg: UIConfig = null) -> void:
	config = cfg


static func load_from_files() -> RequirementFormatter:
	return RequirementFormatter.new(UIConfig.load_from_files())


# ---------------------------------------------------------------------------
# Code identity
# ---------------------------------------------------------------------------

## Sim spelling → doc 12 §4.4 spelling; unknown codes fold onto `UNKNOWN` so the
## formatter degrades to a generic row instead of crashing (doc 12 test 13).
static func canonical(code: Variant) -> StringName:
	var name := StringName(str(code).strip_edges().to_upper())
	if ALIASES.has(name):
		return ALIASES[name]
	if CODE_TABLE.has(name):
		return name
	return UNKNOWN_CODE


## False for a code this build has no copy for — the row still renders, but the
## generic template is a copy hole worth failing a lint on.
static func is_known(code: Variant) -> bool:
	return RequirementFormatter.canonical(code) != UNKNOWN_CODE


## `ui_requirement_<code_lowercase>` (doc 12 §3.1) — the only key shape.
static func string_key(code: Variant, suffix: String = "") -> String:
	return KEY_PREFIX + String(RequirementFormatter.canonical(code)).to_lower() + suffix


static func severity_of(code: Variant) -> StringName:
	var row: Dictionary = CODE_TABLE[RequirementFormatter.canonical(code)]
	return row["severity"]


static func is_blocking(code: Variant) -> bool:
	return RequirementFormatter.severity_of(code) == SEVERITY_BLOCKED


static func fix_kind(code: Variant) -> StringName:
	var row: Dictionary = CODE_TABLE[RequirementFormatter.canonical(code)]
	return row["fix"]


## Every canonical code, doc order — what doc 12 test 13 enumerates.
static func codes() -> Array[StringName]:
	var out: Array[StringName] = []
	for code: Variant in CODE_TABLE:
		if StringName(code) != UNKNOWN_CODE:
			out.append(StringName(code))
	return out


# ---------------------------------------------------------------------------
# Value formatting (money mirrors `HudModel`'s NumberFormat — one convention)
# ---------------------------------------------------------------------------

static func money(amount: Variant) -> String:
	return HudModel.money(int(round(float(amount))))


## kW below 1 MW, MW above — the unit doc 12 §2.7's worked example uses
## (`1.8 MW available / 2.4 MW required`).
static func power(kw: Variant) -> String:
	var value := float(kw)
	if absf(value) >= KW_PER_MW:
		return "%s MW" % _trim(String.num(value / KW_PER_MW, 2))
	if absf(value) >= 100.0:
		return "%d kW" % int(round(value))
	return "%s kW" % _trim(String.num(value, 1))


## Doc 05's unit for a building's draw, rendered the way the panel shows it.
static func water_m3h(m3h: Variant) -> String:
	return "%s m³/h" % _trim(String.num(float(m3h), 2))


## Same convention as every other percentage in the deck (`HudModel`'s
## NumberFormat): one place decides how a percent looks.
static func percent(fraction: Variant) -> String:
	return HudModel.percent_text(clampf(float(fraction), 0.0, 1.0) * 100.0)


static func tiles(count: Variant) -> String:
	return str(int(round(float(count))))


static func _trim(text: String) -> String:
	if not text.contains("."):
		return text
	var out := text
	while out.ends_with("0"):
		out = out.substr(0, out.length() - 1)
	return out.trim_suffix(".")


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

## The one entry point. `params` carries raw sim values — `cost`, `balance`,
## `deficit_kw`, `have`, `need`, `at`, `level`, `fix_target_id` — and this class
## turns them into the `{named}` arguments the templates expect. Returns
##
##     {code, canonical, key, title, body, remedy, severity, state, blocking,
##      glyph, fix_target: {kind, id}, args}
##
## and never fails: an unknown code renders the generic row.
func format(code: Variant, params: Dictionary = {}) -> Dictionary:
	var name := RequirementFormatter.canonical(code)
	var args := _args_for(name, params)
	# The raw sim spelling, so the generic row can name what it could not explain.
	args["code"] = str(code).to_upper()
	var remedy := _resolve(RequirementFormatter.string_key(name, REMEDY_SUFFIX), args, "")
	args["remedy"] = remedy
	var body := _resolve(RequirementFormatter.string_key(name), args,
			_structural_body(code, args))
	var title := _resolve(RequirementFormatter.string_key(name, TITLE_SUFFIX), args,
			String(name).capitalize())
	var severity: StringName = RequirementFormatter.severity_of(name)
	# `CODE_TABLE` gives the fix a code has in GENERAL; a caller that knows this
	# particular building can say otherwise by passing `fix_kind` (Wave 17, doc
	# 93 §Y3a). Resolved before the return so the params table below can be built
	# for the kind that will actually be emitted.
	var fix_kind_out := StringName(str(params.get("fix_kind",
			RequirementFormatter.fix_kind(name))))
	var fix_id := str(params.get("fix_target_id", ""))
	var fix_params := RequirementFormatter._fix_params_for(fix_kind_out, params)
	# **The contract enforces itself** (PA-05). A kind that answers "where do I
	# go?" with neither a tile nor an id it can resolve is not a target, and the
	# honest render of that is NO BUTTON — not a button the router drops on its
	# first line, which is what `E_AVENUE` shipped for three waves. This is the
	# one place the decision can be made, because it is the one place that knows
	# both what the kind needs and what the producer actually supplied.
	if not RequirementFormatter._is_routable(fix_kind_out, fix_id, fix_params):
		fix_kind_out = FIX_NONE
		fix_id = ""
		fix_params = {}
	return {
		"code": StringName(str(code).to_upper()),
		"canonical": name,
		"key": RequirementFormatter.string_key(name),
		"title": title,
		"body": body,
		"remedy": remedy,
		"severity": severity,
		"state": SEVERITY_STATE.get(severity, HudModel.STATE_CRITICAL),
		"blocking": severity == SEVERITY_BLOCKED,
		"glyph": GLYPH_FAIL,
		# The one case `fix_kind` needs overriding today is `E_CONDITION` on
		# private stock: the remedy in general is a repair, and on a building
		# whose owner maintains it there is no repair to sell, so the row states
		# the blocker and offers no button rather than offering one that refuses.
		"fix_target": {
			"kind": fix_kind_out,
			"id": fix_id,
			# The building the row belongs to, when the params say (FIX_POWER does;
			# Wave 28 merge). `""` otherwise — the router treats that as "no subject".
			"sim_id": str(params.get("sim_id", "")),
			# PA-05: what the router needs in order to ACT. See the contract
			# table in this class's doc — it is normative for both halves.
			"params": fix_params,
		},
		"args": args,
	}


## Several codes at once, doc order preserved. `params_by_code` may carry a
## per-code override dictionary; `shared` applies to every row.
func format_all(codes_in: Array, shared: Dictionary = {},
		params_by_code: Dictionary = {}) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for code: Variant in codes_in:
		out.append(format(code, RequirementFormatter._merged(shared, params_by_code, code)))
	return out


## A `CommandQueue` result (`{ok, reason_code, payload}`) straight from the sim.
## Returns `{}` when the command succeeded — there is nothing to explain.
func from_result(result: Dictionary, params: Dictionary = {}) -> Dictionary:
	if bool(result.get("ok", false)):
		return {}
	var merged: Dictionary = params.duplicate()
	var payload: Variant = result.get("payload", {})
	if payload is Dictionary:
		for key: Variant in (payload as Dictionary):
			if not merged.has(key):
				merged[key] = (payload as Dictionary)[key]
	return format(result.get("reason_code", UNKNOWN_CODE), merged)


## The doc 12 §2.9 upgrade checklist: every check the gate runs, passing rows
## included, in the order `sim/city_sim.gd` evaluates them. `blockers` is the
## preview payload's array; `checks` is the full ordered code list.
func checklist(checks: Array, blockers: Array, shared: Dictionary = {},
		params_by_code: Dictionary = {}) -> Array[Dictionary]:
	var failed: Dictionary = {}
	for code: Variant in blockers:
		failed[RequirementFormatter.canonical(code)] = true
	var out: Array[Dictionary] = []
	for code: Variant in checks:
		var row := format(code, _merged(shared, params_by_code, code))
		var ok := not failed.has(RequirementFormatter.canonical(code))
		row["ok"] = ok
		row["glyph"] = GLYPH_PASS if ok else GLYPH_FAIL
		# A satisfied requirement is named, not explained: the body sentence is
		# written in the failure voice ("Condition too low: …"), which would read
		# as a contradiction next to a `✓`. The failing row keeps the full
		# sentence, because that is the row the player has to act on.
		row["text"] = str(row["title"]) if ok else str(row["body"])
		if ok:
			row["state"] = HudModel.STATE_NORMAL
		out.append(row)
	return out


## `shared` under a per-code override, keyed either by `StringName` or `String`.
static func _merged(shared: Dictionary, params_by_code: Dictionary,
		code: Variant) -> Dictionary:
	var merged: Dictionary = shared.duplicate()
	var extra: Variant = params_by_code.get(StringName(str(code).to_upper()), null)
	if extra == null:
		extra = params_by_code.get(str(code).to_upper(), null)
	if extra is Dictionary:
		for key: Variant in (extra as Dictionary):
			merged[key] = (extra as Dictionary)[key]
	return merged


## First blocking row of a checklist, or `{}` — the panel's `UPGRADE` subtitle
## ("its subtitle names the first blocker", §2.9).
static func first_blocker(rows: Array) -> Dictionary:
	for entry: Variant in rows:
		var row: Dictionary = entry
		if not bool(row.get("ok", true)) and bool(row.get("blocking", true)):
			return row
	return {}


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

## Raw sim values → the `{named}` arguments each template declares. This is the
## only place a code's parameter shape is written down.
func _args_for(name: StringName, p: Dictionary) -> Dictionary:
	var args: Dictionary = {}
	for key: Variant in p:
		args[str(key)] = p[key]
	match name:
		&"POWER_CAPACITY":
			var deficit := float(p.get("deficit_kw", 0.0))
			var headroom := float(p.get("headroom_kw", 0.0))
			var required := float(p.get("required_kw", headroom + deficit))
			args["have"] = str(p.get("have", RequirementFormatter.power(headroom)))
			args["need"] = str(p.get("need", RequirementFormatter.power(required)))
			args["deficit"] = RequirementFormatter.power(deficit)
			args["at"] = str(p.get("at", p.get("feeder_id", "")))
		&"WATER_PRESSURE":
			args["have"] = str(p.get("have", ""))
			args["need"] = str(p.get("need", ""))
		&"NO_ROAD":
			args["have"] = str(p.get("have", RequirementFormatter.tiles(p.get("distance_tiles", 0))))
			args["need"] = str(p.get("need", "1"))
		&"NO_CREW":
			args["have"] = str(p.get("have", int(p.get("busy_crews", 0))))
			args["need"] = str(p.get("need", int(p.get("total_crews", 0))))
		&"FIRE_COVERAGE":
			args["have"] = str(p.get("have", ""))
			args["need"] = str(p.get("need", ""))
		&"CITY_LEVEL":
			args["have"] = str(p.get("have", int(p.get("city_level", 0))))
			args["need"] = str(p.get("need", int(p.get("required_level", 0))))
		&"FUNDS":
			args["have"] = str(p.get("have", RequirementFormatter.money(p.get("balance", 0))))
			args["need"] = str(p.get("need", RequirementFormatter.money(p.get("cost", 0))))
		&"OCCUPIED":
			args["have"] = str(p.get("have", _tile_text(p)))
			args["need"] = str(p.get("need", ""))
		&"E_ALREADY_REPAIRING":
			# Wave 25, doc 04 §2.15.2. `at` is the COMPONENT a crew is already on —
			# the same `{at}` name `POWER_CAPACITY` above uses for the thing that
			# runs out first, because a player reading two power rows should not
			# have to learn two words for "which piece of equipment".
			args["at"] = str(p.get("at", p.get("component", "")))
		&"NOT_OWNED", &"UNDEVELOPED":
			args["at"] = str(p.get("at", p.get("block_id", _tile_text(p))))
			args["have"] = str(p.get("have", args["at"]))
			args["need"] = str(p.get("need", ""))
		&"TERRAIN":
			args["have"] = str(p.get("have", ""))
			args["need"] = str(p.get("need", ""))
		&"TECH_LOCK":
			args["have"] = str(p.get("have", ""))
			args["need"] = str(p.get("need", ""))
		&"E_AVENUE":
			# C-62 payload: {have: tiles to nearest avenue, need: 4, unit: tiles,
			# at: access tile, fix_target_id: road segment id}.
			args["have"] = str(p.get("have", RequirementFormatter.tiles(
					p.get("avenue_distance_tiles", 0))))
			args["need"] = str(p.get("need", int(p.get("avenue_radius_tiles", 4))))
			args["level"] = str(p.get("level", int(p.get("to_level", 4))))
			args["at"] = str(p.get("at", _tile_text(p)))
			args["unit"] = str(p.get("unit", "tiles"))
		&"E_UNSERVED":
			args["have"] = str(p.get("have", _tile_text(p)))
			args["need"] = str(p.get("need", ""))
		&"E_NO_MAIN":
			# **Wave 28 (doc 12 D-126).** `ui_requirement_e_no_main` has asked for
			# `{need}` and `{have}` since Wave 10 and nothing ever supplied
			# either, so doc 05's site refusal rendered as *"the nearest main is
			# more than  tiles from tile "* — the sentence shape doc 12 §2.7
			# calls the most important teaching device in the game, teaching
			# nothing. `cmd_place_water_component` publishes both now:
			# `tap_radius_tiles` is the reach the rule uses and
			# `nearest_main_tiles` is how far the nearest live main actually is,
			# searched over the whole map on the refusal path only.
			args["need"] = str(p.get("need", int(p.get("tap_radius_tiles", 8))))
			args["have"] = str(p.get("have", _tile_text(p)))
			var main_far := int(p.get("nearest_main_tiles", -1))
			args["distance"] = "—" if main_far < 0 else str(main_far)
			args["at"] = str(p.get("at", _tile_text(p)))
		&"E_NO_WATER":
			# The other half of the same refusal: an intake off the shoreline.
			# The tile is the answer here — there is nothing to measure, only a
			# place to move to.
			args["have"] = str(p.get("have", _tile_text(p)))
			args["at"] = str(p.get("at", _tile_text(p)))
		&"E_WATER_HEADROOM":
			# Doc 05's own unit, and doc 05's own answer to "how short?".
			# `can_upgrade_water` returns `deficit_m3h` and `zone_headroom_m3h`
			# is the standing figure, so `{have}` is what the zone has spare and
			# `{need}` is what the next level would draw with §6's safety margin
			# on it — the same shape `POWER_CAPACITY` uses one row up.
			var water_deficit := float(p.get("deficit_m3h", 0.0))
			var water_headroom := float(p.get("headroom_m3h", 0.0))
			args["have"] = str(p.get("have",
					RequirementFormatter.water_m3h(water_headroom)))
			args["need"] = str(p.get("need", RequirementFormatter.water_m3h(
					p.get("required_m3h", water_headroom + water_deficit))))
			args["deficit"] = RequirementFormatter.water_m3h(water_deficit)
			args["at"] = str(p.get("at", p.get("zone", "")))
			# **Wave 28 (A91-D-147): one code, two refusals, two remedies.** Doc
			# 05 §2.11 refuses this upgrade on capacity OR on the per-tile
			# pressure §2.3 derives from distance to a main, and the old remedy —
			# *"add a pumping station or a storage tank in this district"* — was
			# the wrong sentence for both of them at once: a tank stores water
			# the zone never had, and a pump when TREATMENT binds raises supply
			# by exactly zero (doc 92 §67.4 measured 118 of them and $5.5M).
			# `WaterSystem.can_upgrade_water` now says which arm said no and
			# `WaterSystem.supply_chain` says which stage binds, so the row can
			# name the purchase. A caller that supplies neither still renders —
			# the default is the capacity arm, which is what the row has always
			# assumed.
			var water_limit := str(p.get("limit", "capacity"))
			var water_stage := str(p.get("binding", "none"))
			args["stage"] = _resolve("ui_water_stage_%s" % water_stage, {}, water_stage)
			args["tiles"] = str(p.get("main_distance_tiles", -1))
			args["pressure"] = RequirementFormatter.percent(p.get("pressure", 0.0))
			var advice_key := "ui_requirement_e_water_headroom_capacity"
			if water_limit == "pressure":
				advice_key = "ui_requirement_e_water_headroom_pressure"
			elif water_limit == "no_zone":
				advice_key = "ui_requirement_e_water_headroom_no_zone"
			elif water_stage == "mains":
				advice_key = "ui_requirement_e_water_headroom_mains"
			args["advice"] = _resolve(advice_key, args, "")
		&"E_UNIT_UNAVAILABLE", &"E_UNREACHABLE", &"E_UNKNOWN_INCIDENT":
			# Doc 06's dispatch refusals (PA-52). `unit` is the vehicle's display
			# name and `have` its `Vehicle` status string verbatim — the same
			# vocabulary the picker sorts its rows on, so a rename on either side
			# is a copy hole rather than a silent mis-sentence.
			args["unit"] = str(p.get("unit", p.get("unit_name", p.get("unit_id", ""))))
			args["have"] = str(p.get("have", p.get("status", "")))
			args["need"] = str(p.get("need", ""))
			args["at"] = str(p.get("at", p.get("station", "")))
		&"E_STATE":
			args["have"] = str(p.get("have", p.get("state", "")))
			args["need"] = str(p.get("need", p.get("required_state", "")))
		&"E_CONDITION":
			args["have"] = str(p.get("have",
					RequirementFormatter.percent(p.get("condition", 0.0))))
			args["need"] = str(p.get("need",
					RequirementFormatter.percent(p.get("min_condition", 0.0))))
		&"E_NOT_DAMAGED":
			# The building's own condition, in the same percent every other
			# condition reading in the deck uses.
			args["have"] = str(p.get("have",
					RequirementFormatter.percent(p.get("condition", 1.0))))
			args["need"] = str(p.get("need", ""))
		&"E_UNKNOWN_PRIORITY":
			args["have"] = str(p.get("have", p.get("priority_class", "")))
			args["need"] = str(p.get("need", ""))
		&"E_MAX_LEVEL":
			args["have"] = str(p.get("have", int(p.get("level", 0))))
			args["need"] = str(p.get("need", int(p.get("max_level", 0))))
		&"E_UNKNOWN_ARCHETYPE":
			args["have"] = str(p.get("have", p.get("archetype", "")))
			args["need"] = str(p.get("need", ""))
		&"E_CLASS_UNAVAILABLE":
			args["have"] = str(p.get("have", int(p.get("conductor_class", 0))))
			args["need"] = str(p.get("need", ", ".join(
					RequirementFormatter._as_strings(p.get("conductor_classes", [])))))
		&"E_DISCONTINUOUS":
			args["have"] = str(p.get("have", _tile_text(p)))
			args["need"] = str(p.get("need", ""))
		&"E_TRANSFORMER_FULL":
			# Wave 17's placement WARNING (doc 93 §AD3). `component` is the
			# transformer that would take the new load, `have` its spare
			# capacity at the peak and `need` what the building would add there.
			args["component"] = str(p.get("component", p.get("transformer", "")))
			args["at"] = str(p.get("at", args["component"]))
			args["have"] = str(p.get("have",
					RequirementFormatter.power(p.get("headroom_kw", 0.0))))
			args["need"] = str(p.get("need",
					RequirementFormatter.power(p.get("demand_kw", 0.0))))
		&"E_NEEDS_TRANSFORMER":
			# The top of the ladder: nothing the one-tap fix can buy clears it,
			# and the answer is a second transformer on a tile the player picks.
			args["component"] = str(p.get("component", p.get("at", "")))
			args["at"] = str(p.get("at", args["component"]))
			args["have"] = str(p.get("have", int(p.get("level", 0))))
			args["need"] = str(p.get("need", int(p.get("max_level", 0))))
		&"E_NO_SLOT":
			# Doc 04 §2.2's 2/3/4/6/8 slot ladder, at the substation the run
			# would have rooted on. `at` is that substation, which is also the
			# `Fix this →` target.
			args["at"] = str(p.get("at", p.get("substation", "")))
			args["have"] = str(p.get("have", int(p.get("feeder_slots_free", 0))))
			args["need"] = str(p.get("need", 1))
		&"E_UNKNOWN_NODE", &"E_UNKNOWN_MAIN", &"E_NOT_ISOLATED", &"E_NOT_UPGRADEABLE":
			args["have"] = str(p.get("have", p.get("node", p.get("edge", ""))))
			args["need"] = str(p.get("need", ""))
		&"E_UNKNOWN_BUILDING":
			args["have"] = str(p.get("have", p.get("sim_id", "")))
			args["need"] = str(p.get("need", ""))
		&"E_UNIT_NOT_DEPLOYED", &"E_UNKNOWN_UNIT":
			# Doc 06's `Vehicle` status string verbatim — the same vocabulary the
			# unit picker sorts on, so a rename on either side is a copy hole
			# rather than a silent mis-sentence.
			args["have"] = str(p.get("have", p.get("status", "")))
			args["need"] = str(p.get("need", ""))
			args["unit"] = str(p.get("unit", p.get("unit_id", "")))
		&"E_BAD_THRESHOLD":
			# Doc 10's own ladder, as percentages, because that is what the row
			# offers: `0 %, 25 %, 40 %, 55 %`.
			args["have"] = str(p.get("have",
					RequirementFormatter.percent(p.get("threshold", 0.0))))
			args["need"] = str(p.get("need", ", ".join(
					RequirementFormatter._as_percents(p.get("allowed", [])))))
		&"E_NOT_ADJACENT", &"E_ALREADY_OWNED", &"E_UNKNOWN_BLOCK", &"E_ALREADY_DEVELOPING":
			# The land family names a BLOCK, and a block's player-facing name is
			# its label (`B4`), not its id (`B_1_3`) — `at` carries whichever the
			# caller supplied, preferring the label.
			args["at"] = str(p.get("at", p.get("block_label", p.get("block", ""))))
			args["have"] = str(p.get("have", args["at"]))
			args["need"] = str(p.get("need", ""))
			args["phase"] = str(p.get("phase", p.get("state", "")))
		_:
			args["have"] = str(p.get("have", ""))
			args["need"] = str(p.get("need", ""))
	if not args.has("at"):
		args["at"] = str(p.get("at", ""))
	if p.has("cost"):
		args["cost"] = RequirementFormatter.money(p["cost"])
	if p.has("balance"):
		args["balance"] = RequirementFormatter.money(p["balance"])
	return args


## The `fix_target.params` of one row — the contract table in this class's doc,
## in code (PA-05). Built from the SAME raw dictionary the `{named}` arguments
## come from, so a producer that already passes `tile`, `block_id` or `at` gets a
## routable target without a second table to keep in step.
##
## Two escape hatches, in this order: `fix_tile` names a tile that is NOT the
## row's own `tile` (`E_AVENUE` quotes the building's tile in its sentence and
## routes to the avenue's), and `fix_target_params` is merged last for a producer
## that knows something this table cannot derive.
static func _fix_params_for(kind: StringName, p: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var tile: Variant = RequirementFormatter._fix_tile(p)
	match kind:
		FIX_NONE:
			pass
		FIX_REPAIR, FIX_POWER:
			out["verb"] = str(FIX_VERBS.get(kind, ""))
			# `fix_cost`, deliberately not `cost`: the checklist's shared `cost`
			# is the UPGRADE's price, and quoting it as the price of the repair
			# or the transformer would be a wrong number wearing a right one's
			# name. A producer that knows the purchase quote passes `fix_cost`;
			# one that does not ships the verb alone and the surface quotes it.
			if p.has("fix_cost"):
				out["cost"] = int(round(float(p["fix_cost"])))
				out["cost_text"] = RequirementFormatter.money(p["fix_cost"])
		FIX_DISTRICT:
			out["district_id"] = str(p.get("district_id",
					p.get("zone", p.get("zone_key", p.get("at", "")))))
			if tile != null:
				out["tile"] = tile
		FIX_COMPONENT:
			out["component"] = str(p.get("component",
					p.get("fix_target_id", p.get("at", ""))))
			# **Only an explicit `fix_tile`.** The row's own `tile` is where the
			# GHOST is, and a router that preferred it would fly the camera to
			# the finger instead of to the full transformer. The component id is
			# the target; `PowerGrid.component_tile()` turns it into a place.
			if p.get("fix_tile", null) is Vector2i:
				out["tile"] = p["fix_tile"]
		_:
			# `FIX_TILE`, `FIX_BUILDING`, `FIX_BLOCK`, `FIX_ROAD_SEGMENT`: every
			# one of them answers "where do I go?", and a tile is the answer the
			# router can always act on — an id it cannot resolve is a dead button.
			if tile != null:
				out["tile"] = tile
			if kind == FIX_BLOCK and p.has("block_id"):
				out["block_id"] = str(p["block_id"])
	var extra: Variant = p.get("fix_target_params", null)
	if extra is Dictionary:
		for key: Variant in (extra as Dictionary):
			out[str(key)] = (extra as Dictionary)[key]
	return out


## Can `ui/fix_router.gd` do anything with this target? The contract table in
## this class's doc, read as a predicate.
##
##   * the two purchase kinds are ALWAYS routable: they are performed in place by
##     the surface that already has the building open, so they need no locator at
##     all — a producer that wants one of them silent says so with an explicit
##     `fix_kind: FIX_NONE` (which is how a privately maintained building draws
##     no repair button);
##   * `FIX_TILE` needs its tile — for that kind the tile IS the target;
##   * every other placing kind needs a tile, or an id of its own namespace.
static func _is_routable(kind: StringName, id: String, params: Dictionary) -> bool:
	if kind == FIX_NONE:
		return false
	if FIX_VERB_KINDS.has(kind):
		return true
	if kind == FIX_TILE:
		return params.has("tile")
	# The component id IS the target for this kind, so a tile does not stand in
	# for a missing one — see `_fix_params_for`.
	if kind == FIX_COMPONENT:
		return str(params.get("component", "")) != ""
	if params.has("tile"):
		return true
	if kind == FIX_DISTRICT:
		return str(params.get("district_id", "")) != ""
	return id != ""


## `fix_tile` over `tile`, and only a real `Vector2i` — a tile the producer
## rendered into a string is copy, not a coordinate, and handing the router a
## string it would have to parse is how `E_AVENUE` shipped an empty id.
static func _fix_tile(p: Dictionary) -> Variant:
	for key: String in ["fix_tile", "tile"]:
		var raw: Variant = p.get(key, null)
		if raw is Vector2i:
			return raw
	return null


# ---------------------------------------------------------------------------
# Shared parameter shapes (PA-75)
#
# Three rows are asked for by two panels at once — the building panel's doc 02
# ladder (`BuildController._check_params`) and the water block's doc 05 ladder
# (`WaterActions._check_params`) — and they were written out twice. They had
# already drifted: the building panel quoted `required_kw` with no headroom
# margin at all while the water panel applied ×1.15, so the panel told the
# player a number 15 % below the one its own gate demands (PA-12). One shape,
# one place, and a test that asserts the two callers produce identical params.
# ---------------------------------------------------------------------------

## Doc 02 §2.11 / doc 05 §6's `E_POWER_HEADROOM` row. `margin` is doc 02's
## `headroom_safety.power` — the SAME factor `CitySim` multiplies the delta by
## before it asks doc 04, so `{need}` is the number the gate actually demanded
## and buying exactly it clears the row.
static func power_headroom_params(delta_kw: float, deficit_kw: float,
		margin: float, at_id: String, sim_id: String = "") -> Dictionary:
	var required := delta_kw * margin
	return {
		# The BUILDING the row is about (Wave 28 merge). `FixRouter` reads it to
		# put `needs` — which transformer rung this building's next level wants —
		# on the answer, and S18 draws that sentence for the building the player
		# came from. Two verifier passes found the router's `needs` reaching no
		# surface because no production fix target ever carried the building id:
		# the only creator is `_row` below, and it only knows what `params` tell it.
		"sim_id": sim_id,
		"deficit_kw": deficit_kw,
		"required_kw": required,
		"headroom_kw": maxf(0.0, required - deficit_kw),
		# The TRANSFORMER the site hangs off, not the site: `Fix this →` that
		# flies the camera to the thing already under the player's thumb moves
		# nothing (doc 12 D-35). "" when the grid has no record, and the row then
		# has no camera target rather than a target that resolves to nowhere.
		# NOT a `fix_kind` override: `POWER_CAPACITY` routes `FIX_POWER` and the
		# building panel performs that purchase in place (Wave 17, A91-D-54).
		# The id rides along so the row's sentence can name the blocker.
		"at": at_id,
		"fix_target_id": at_id,
	}


static func funds_params(cost: int, balance: int) -> Dictionary:
	return {"cost": cost, "balance": balance}


static func level_params(level: int, max_level: int) -> Dictionary:
	return {"level": level, "max_level": max_level}


## An `Array` of anything → the strings a `{need}` list is joined from. Used by
## `E_CLASS_UNAVAILABLE`, whose payload names the roster it refused against.
static func _as_strings(raw: Variant) -> PackedStringArray:
	var out: PackedStringArray = []
	if raw is Array:
		for entry: Variant in (raw as Array):
			out.append(str(entry))
	return out


## The same, for a list of `[0, 1]` fractions a refusal names — doc 10's
## `auto_repair_thresholds` is the one, and a player reads `40 %`, never `0.4`.
static func _as_percents(raw: Variant) -> PackedStringArray:
	var out: PackedStringArray = []
	if raw is Array:
		for entry: Variant in (raw as Array):
			out.append(RequirementFormatter.percent(entry))
	return out


static func _tile_text(p: Dictionary) -> String:
	var raw: Variant = p.get("tile", null)
	if raw is Vector2i:
		return "%d, %d" % [(raw as Vector2i).x, (raw as Vector2i).y]
	return str(p.get("tile", ""))


## `data/strings.en.json` first (G-8). The fallback is deliberately *structural*
## — a missing template must read as broken, never as authored copy in code.
func _resolve(key: String, args: Dictionary, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key, args)
	return fallback


static func _structural_body(code: Variant, args: Dictionary) -> String:
	var have := str(args.get("have", ""))
	var need := str(args.get("need", ""))
	return "%s: %s / %s" % [str(code).to_upper(), have, need]

class_name PathTool
extends RefCounted
## Doc 12 §2.7's **drag-path placement**, headless. Roads and water mains are not
## footprints: the player picks a start tile, sweeps to an end tile, and one
## command lays the whole run. `BuildController` owns the footprint half of §2.7;
## this class owns the run half, and `ui/build_sheet.gd` routes a card tap to
## whichever of the two the card belongs to — so the sheet, the placement bar and
## the Android back stack stay one code path for both.
##
## Three responsibilities, and no fourth:
##
##   1. **The roster** — which cards draw runs, which `CitySim` verb each one
##      reaches, and which category tab it sits on. Structural, like
##      `BuildController.CATEGORY_ORDER`; every *number* on a card is read from
##      `CostCurves` or from the owning command's own preview, never authored
##      here (doc 12 §3.1 G-8).
##   2. **The geometry** — `l_path()`, doc 12 §2.7's "L-shaped (Manhattan,
##      longest-leg-first)" run: pure, static, and the reason a test can name
##      tiles without a sim.
##   3. **The state machine** — `enter() → aim → begin_run() → draw → commit()`,
##      with the verdict recomputed on every move by *asking the sim*
##      (`preview = true`), exactly as `BuildController.evaluate_component` does.
##      A run's verdict and the command's answer are one code path, not two
##      copies of one rule.
##
## ## Why the anchor is an explicit step
##
## The shell moves the ghost from two places — a tap (`Main._handle_tap`) and a
## desktop hover (`Main._unhandled_input`) — and nothing down here can tell them
## apart. If the first move pinned the anchor, a desktop hover would anchor the
## run wherever the pointer happened to cross the world. So the bar's primary
## button does two jobs: `START` while aiming (which pins the anchor under the
## ghost) and `PLACE` once a run exists. It costs one tap, and it is the same
## rule §2.7 already makes about buildings — *placement is never committed on
## finger-up*. `game/touch_input.gd`'s drag router is the accelerator on top: a
## press-and-sweep anchors and draws in one stroke, and `PLACE` still commits.

# --- States -----------------------------------------------------------------
const STATE_IDLE := &"idle"
## A card is held and the ghost is hunting for a start tile.
const STATE_AIMING := &"aiming"
## The anchor is pinned; the free end follows the ghost and the run is priced.
const STATE_DRAWING := &"drawing"

# --- Which command a card reaches -------------------------------------------
const VERB_ROAD_BUILD := &"road_build"
const VERB_ROAD_UPGRADE := &"road_upgrade"
const VERB_ROAD_DEMOLISH := &"road_demolish"
const VERB_WATER_MAIN := &"water_main"

## Doc 12 §2.7's own tab name for the run verbs ("Residential · Commercial ·
## Industrial · Civic · Utility · **Roads** · Land"). Water mains do NOT come
## here: the doc files them under Utility beside the pumps they feed, which is
## `BuildController.CATEGORY_INFRASTRUCTURE` in this build. Kept as a literal
## rather than imported so `BuildController` may depend on this file and this
## file may not depend on it — `tests/test_path_tool.gd` asserts the pair.
const CATEGORY_ROADS := "roads"
const CATEGORY_INFRASTRUCTURE := "infrastructure"

## Doc 10 §2.13's classes, by the integers `cmd_place_road` takes
## (`RoadTunables.CLASS_NONE / CLASS_STREET / CLASS_AVENUE`). Named here so the
## roster reads; asserted against doc 10's own constants in the test.
const ROAD_CLASS_NONE := 0
const ROAD_CLASS_STREET := 1
const ROAD_CLASS_AVENUE := 2

## The roster. **Structure only** — no price, no capacity, no copy. `min_tiles`
## is the shortest run the owning command accepts, and it is what decides whether
## a card can price its aim tile before a run exists: doc 10 quotes a single road
## tile happily, doc 05 §6 refuses a main shorter than two.
const CARDS: Array[Dictionary] = [
	{"id": "road_street", "verb": VERB_ROAD_BUILD, "category": CATEGORY_ROADS,
			"road_class": ROAD_CLASS_STREET, "tier": "", "min_tiles": 1,
			"refunds": false},
	{"id": "road_avenue", "verb": VERB_ROAD_BUILD, "category": CATEGORY_ROADS,
			"road_class": ROAD_CLASS_AVENUE, "tier": "", "min_tiles": 1,
			"refunds": false},
	{"id": "road_widen", "verb": VERB_ROAD_UPGRADE, "category": CATEGORY_ROADS,
			"road_class": ROAD_CLASS_AVENUE, "tier": "", "min_tiles": 1,
			"refunds": false},
	{"id": "road_remove", "verb": VERB_ROAD_DEMOLISH, "category": CATEGORY_ROADS,
			"road_class": ROAD_CLASS_NONE, "tier": "", "min_tiles": 1,
			"refunds": true},
	{"id": "water_main_service", "verb": VERB_WATER_MAIN,
			"category": CATEGORY_INFRASTRUCTURE, "road_class": ROAD_CLASS_NONE,
			"tier": "service", "min_tiles": 2, "refunds": false},
	{"id": "water_main_trunk", "verb": VERB_WATER_MAIN,
			"category": CATEGORY_INFRASTRUCTURE, "road_class": ROAD_CLASS_NONE,
			"tier": "trunk", "min_tiles": 2, "refunds": false},
]

## Doc 05's arterial tier sits behind `levels_4_5_enabled` and is therefore not
## in the roster above: a card that can never be placed in this build is noise,
## not progression (§2.13's lock glyph is for a level the player can still
## reach). `available()` re-checks the flag anyway, so turning it on is a data
## change and not a code change.
const FLAG_LOCKED_TIERS: Array[String] = ["arterial"]

## The verdict vocabulary is doc 12 §2.7's tint table, spelled exactly as
## `BuildController` spells it — one ladder, two tools.
const VERDICT_VALID := &"valid"
const VERDICT_WARN := &"warn"
const VERDICT_BLOCKED := &"blocked"

## `data/ui.json.placement.max_run_tiles`, with this as the floor if the key is
## missing. A run is one command and one bill, and a thumb that slips across the
## map must not quote a $250,000 avenue; the player commits and sweeps again.
const MAX_RUN_TILES_DEFAULT := 48

var sim: CitySim
var formatter: RequirementFormatter
var tile_m := BuildController.TILE_M_DEFAULT
var max_run_tiles := MAX_RUN_TILES_DEFAULT

var state: StringName = STATE_IDLE
## The card id currently held, "" when idle.
var card_id := ""
var anchor := Vector2i.ZERO
var head := Vector2i.ZERO
var has_head := false

var _tiles: Array[Vector2i] = []
var _verdict: Dictionary = {}
var _quote: Dictionary = {}


func _init(p_sim: CitySim = null, p_formatter: RequirementFormatter = null,
		p_tile_m: float = -1.0) -> void:
	sim = p_sim
	formatter = p_formatter if p_formatter != null else RequirementFormatter.load_from_files()
	tile_m = p_tile_m if p_tile_m > 0.0 else BuildController.load_tile_m()
	var cfg: UIConfig = formatter.config if formatter != null else null
	if cfg != null:
		max_run_tiles = maxi(1, int(UIConfig.get_num(cfg.section("placement"),
				"max_run_tiles", float(MAX_RUN_TILES_DEFAULT))))


# ===========================================================================
# The roster
# ===========================================================================

static func row(id: String) -> Dictionary:
	for entry: Dictionary in CARDS:
		if str(entry["id"]) == id:
			return entry
	return {}


static func is_path_id(id: String) -> bool:
	return not PathTool.row(id).is_empty()


static func ids() -> Array[String]:
	var out: Array[String] = []
	for entry: Dictionary in CARDS:
		out.append(str(entry["id"]))
	return out


## G-8 key for a card's name — the same shape `BuildController.card_name_key`
## builds, so one convention covers every card on the sheet.
static func card_name_key(id: String) -> String:
	return "ui_build_card_%s" % id


## Doc 12 §2.7's card list, for the run verbs. `cost` is the **per-tile** price,
## read from `CostCurves`, because a run has no total until the player has drawn
## one and a card that quoted a total would have to invent a length. A refund
## card quotes what one tile gives back.
func cards() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if sim == null:
		return out
	for entry: Dictionary in CARDS:
		var id := str(entry["id"])
		if available(id):
			out.append(card(id))
	return out


## False when this build cannot offer the card at all — a tier behind doc 05's
## `levels_4_5_enabled`, or one `data/water.json` no longer carries.
func available(id: String) -> bool:
	var entry := PathTool.row(id)
	if entry.is_empty() or sim == null:
		return false
	if StringName(str(entry["verb"])) != VERB_WATER_MAIN:
		return true
	var tier := str(entry["tier"])
	if not sim.water.data.mains.has(tier):
		return false
	return not FLAG_LOCKED_TIERS.has(tier) or sim.water.data.flag("levels_4_5_enabled")


func card(id: String) -> Dictionary:
	var entry := PathTool.row(id)
	if entry.is_empty():
		return {}
	var per_tile := per_tile_price(id)
	var refunds := bool(entry["refunds"])
	return {
		"id": id,
		"archetype": id,
		"variant": "",
		"component_kind": "",
		"component_domain": "",
		"path_verb": String(entry["verb"]),
		"level": 1,
		"category": str(entry["category"]),
		"name_key": PathTool.card_name_key(id),
		"name_fallback": id.capitalize(),
		"cost": 0 if refunds else per_tile,
		# `BuildController._card_less` sorts a card that PAYS after every card
		# that charges — see its own note. Building and component cards do not
		# carry the key at all and default to `false`.
		"refunds": refunds,
		"cost_text": per_tile_text(id),
		"footprint": Vector2i.ONE,
		"power_kw": 0.0,
		"power_text": micro_text(id),
		"water_demand": 0.0,
		"min_city_level": 0,
		"locked": false,
		# A refund card is always affordable: it pays.
		"affordable": refunds or sim == null or sim.treasury.balance >= per_tile,
		"service_radius_tiles": 0,
	}


## The per-tile figure the card face quotes — doc 03 §2.13(d) for the three road
## rows, doc 03 §8 `water` for the mains, both through `CostCurves`.
func per_tile_price(id: String) -> int:
	var entry := PathTool.row(id)
	if entry.is_empty() or sim == null:
		return 0
	var m_build := float(sim.treasury.difficulty().get("M_build", 1.0))
	match StringName(str(entry["verb"])):
		VERB_ROAD_BUILD:
			return sim.econ_curves.road_build_cost(
					PathTool.road_class_name(int(entry["road_class"])), m_build)
		VERB_ROAD_UPGRADE:
			return sim.econ_curves.road_upgrade_cost("STREET_TO_AVENUE", m_build)
		VERB_ROAD_DEMOLISH:
			# The STREET refund is the honest headline — what ripping up the
			# ordinary tile returns. `cmd_demolish_road` quotes the real mixture
			# once the player has actually drawn over an avenue.
			return sim.econ_curves.road_demolish_refund(
					PathTool.road_class_name(ROAD_CLASS_STREET))
		VERB_WATER_MAIN:
			return sim.econ_curves.water_main_cost_per_tile(str(entry["tier"]), m_build)
	return 0


## `$1,800/tile`, or `+$450/tile` on a refund card. One key each, so the slash
## and the plus sign are copy and not code (G-8).
func per_tile_text(id: String) -> String:
	var entry := PathTool.row(id)
	if entry.is_empty():
		return ""
	var money := RequirementFormatter.money(per_tile_price(id))
	var key := "ui_build_card_path_refund" if bool(entry["refunds"]) \
			else "ui_build_card_path_cost"
	return _t(key, {"cost": money}, money)


## The §2.7 micro-row. A run card has no kW and no footprint to show, so the line
## carries what the decision actually turns on: the capacity a main tier buys
## (doc 05 §2.2), or what the road verb does to a tile (doc 10 §2.13).
func micro_text(id: String) -> String:
	var entry := PathTool.row(id)
	if entry.is_empty():
		return ""
	if StringName(str(entry["verb"])) == VERB_WATER_MAIN:
		var capacity := 0.0
		if sim != null:
			capacity = sim.water.data.main_capacity(str(entry["tier"]))
		return _t("ui_build_card_path_micro_main",
				{"capacity": RequirementFormatter.water_m3h(capacity)},
				RequirementFormatter.water_m3h(capacity))
	return _t("ui_build_card_path_micro_%s" % id, {}, "")


static func road_class_name(road_class: int) -> String:
	return "AVENUE" if road_class == ROAD_CLASS_AVENUE else "STREET"


# ===========================================================================
# Geometry
# ===========================================================================

## Doc 12 §2.7's run: an **L, Manhattan, longest leg first**. Deterministic and
## pure — the same two tiles always give the same ordered list, which is what
## lets doc 05 §2.2 read `path[0]` as "the tap onto the existing network".
##
## The longer axis is walked first, so a sweep that is mostly horizontal reads as
## a horizontal street with a short jog at the end — which is what the thumb
## drew. A tie goes to X, because a rule that flips on `|dx| == |dz|` makes the
## ghost snap sideways at 45°.
static func l_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var corner := Vector2i(to.x, from.y) if absi(to.x - from.x) >= absi(to.y - from.y) \
			else Vector2i(from.x, to.y)
	PathTool._append_leg(out, from, corner)
	PathTool._append_leg(out, corner, to)
	return out


## Appends every tile from `from` to `to` inclusive, skipping one the list
## already ends with — which is how the corner is emitted exactly once.
static func _append_leg(out: Array[Vector2i], from: Vector2i, to: Vector2i) -> void:
	var step := Vector2i(signi(to.x - from.x), signi(to.y - from.y))
	var at := from
	while true:
		if out.is_empty() or out[out.size() - 1] != at:
			out.append(at)
		if at == to:
			return
		at += step


# ===========================================================================
# The state machine
# ===========================================================================

func is_active() -> bool:
	return state != STATE_IDLE


func is_aiming() -> bool:
	return state == STATE_AIMING


func is_drawing() -> bool:
	return state == STATE_DRAWING


## Pick up a run card. Refuses an id this build does not offer, exactly as
## `BuildController.enter()` refuses a locked archetype.
func enter(id: String) -> Dictionary:
	if sim == null or not available(id):
		cancel()
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT", {"archetype": id})
	var entry := PathTool.row(id)
	state = STATE_AIMING
	card_id = id
	anchor = Vector2i.ZERO
	head = Vector2i.ZERO
	has_head = false
	_tiles = [] as Array[Vector2i]
	_verdict = {}
	_quote = {}
	return CommandQueue.ok({"archetype": id, "path_verb": String(entry["verb"]),
			"category": str(entry["category"])})


func cancel() -> void:
	state = STATE_IDLE
	card_id = ""
	anchor = Vector2i.ZERO
	head = Vector2i.ZERO
	has_head = false
	_tiles = [] as Array[Vector2i]
	_verdict = {}
	_quote = {}


## Move the free end — or, while aiming, the prospective anchor.
func move_to_tile(tile: Vector2i) -> Dictionary:
	if not is_active():
		return verdict()
	head = tile
	has_head = true
	if state == STATE_AIMING:
		anchor = tile
	_recompute()
	return _verdict


func move_to_ground(point: Vector3) -> Dictionary:
	return move_to_tile(BuildController.tile_at(point, tile_m))


## Pin the anchor and start drawing — the placement bar's `START`, and the press
## half of a drag stroke. `tile` is optional: a drag supplies the tile it went
## down on, the button supplies nothing and the ghost's tile is used.
func begin_run(tile: Variant = null) -> Dictionary:
	if not is_active():
		return CommandQueue.fail(&"E_STATE", {"state": String(state)})
	if tile is Vector2i:
		anchor = tile
		head = tile
		has_head = true
	elif not has_head:
		return CommandQueue.fail(&"E_NO_TILES", {"blockers": [&"E_NO_TILES"]})
	else:
		anchor = head
	state = STATE_DRAWING
	_recompute()
	return CommandQueue.ok({"anchor": anchor})


## Back to hunting for a start tile without dropping the card — the bar's `↺`.
## Doc 12 §2.7 reserves that slot for the footprint tools' rotation; a run has no
## rotation and every run has a start, so that is what the slot means here.
func reset_run() -> void:
	if not is_active():
		return
	state = STATE_AIMING
	if has_head:
		anchor = head
	_recompute()


## The tiles the command would be handed, in order.
func tiles() -> Array[Vector2i]:
	return _tiles


func verdict() -> Dictionary:
	return _verdict


## The owning command's own preview payload — `{blockers, cost|refund, tiles, …}`
## — or `{}` before a run exists. The bar reads its money out of this, and
## nothing in `ui/` computes a run price.
func quote() -> Dictionary:
	return _quote


func can_confirm() -> bool:
	return is_drawing() and not _tiles.is_empty() \
			and str(_verdict.get("verdict", VERDICT_BLOCKED)) != String(VERDICT_BLOCKED)


## What confirming would move — negative on a refund card, so one field carries
## both directions and no view has to know which kind of card it is showing.
func run_cost() -> int:
	if _quote.has("cost"):
		return int(_quote["cost"])
	if _quote.has("refund"):
		return -int(_quote["refund"])
	return 0


## Issue the real command (doc 12 §4.4). On success the tool returns to AIMING
## rather than idle: a player laying a grid lays several runs, and dropping them
## back out to the sheet between each one is the wrong shape.
func commit() -> Dictionary:
	if not is_drawing():
		return CommandQueue.fail(&"E_STATE", {"state": String(state)})
	if _tiles.is_empty():
		return CommandQueue.fail(&"E_NO_TILES", {"blockers": [&"E_NO_TILES"]})
	if not can_confirm():
		return CommandQueue.fail(StringName(str(_verdict.get("code", &"E_NO_TILES"))),
				_verdict.get("params", {}))
	var result := _issue(_tiles, false)
	if bool(result["ok"]):
		state = STATE_AIMING
		anchor = head
		_recompute()
	return result


# ===========================================================================
# Evaluation — the sim answers; this class never re-implements a rule
# ===========================================================================

func _recompute() -> void:
	_tiles = _run_tiles()
	_verdict = {}
	_quote = {}
	if _tiles.is_empty() or _tiles.size() < int(PathTool.row(card_id)["min_tiles"]):
		# Aiming at a card that cannot price one tile. Not an error — there is
		# nothing to quote yet, and the bar says exactly that, in words.
		return
	var preview := _issue(_tiles, true)
	_quote = preview.get("payload", {})
	var params: Dictionary = {"tile": head, "archetype": card_id}
	params.merge(_quote, true)
	if sim != null:
		params["balance"] = sim.treasury.balance
	if bool(preview["ok"]):
		_verdict = {"verdict": VERDICT_VALID, "code": &"", "failure": {}, "params": params}
		return
	var code := StringName(str(preview["reason_code"]))
	var failure := formatter.format(code, params)
	_verdict = {
		"verdict": VERDICT_WARN if str(failure["severity"]) == String(
				RequirementFormatter.SEVERITY_WARN) else VERDICT_BLOCKED,
		"code": code,
		"failure": failure,
		"params": params,
	}


## The run under the ghost, capped at [max_run_tiles] by truncating the far end —
## so the preview the player sees is exactly the run the commit will lay.
func _run_tiles() -> Array[Vector2i]:
	if not is_active() or not has_head:
		return [] as Array[Vector2i]
	if state == STATE_AIMING:
		return [head] as Array[Vector2i]
	var full := PathTool.l_path(anchor, head)
	if full.size() <= max_run_tiles:
		return full
	var clipped: Array[Vector2i] = []
	for i in max_run_tiles:
		clipped.append(full[i])
	return clipped


func _issue(run: Array[Vector2i], preview: bool) -> Dictionary:
	var entry := PathTool.row(card_id)
	if entry.is_empty() or sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT", {"archetype": card_id})
	var raw: Array = []
	for tile: Vector2i in run:
		raw.append(tile)
	match StringName(str(entry["verb"])):
		VERB_ROAD_BUILD:
			return sim.cmd_place_road(raw, int(entry["road_class"]), preview)
		VERB_ROAD_UPGRADE:
			return sim.cmd_upgrade_road(raw, preview)
		VERB_ROAD_DEMOLISH:
			return sim.cmd_demolish_road(raw, preview)
		VERB_WATER_MAIN:
			return sim.cmd_place_water_main(raw, str(entry["tier"]), preview)
	return CommandQueue.fail(&"E_UNKNOWN_COMPONENT", {"archetype": card_id})


# ===========================================================================
# Views
# ===========================================================================

## What `game/ui/path_ghost_view.gd` draws: the run, tile by tile, plus the
## verdict the whole run carries. Per-tile centres rather than one box, because a
## run's refusal is usually about ONE tile in it and the player has to see which.
func ghost() -> Dictionary:
	var current := str(_verdict.get("verdict",
			VERDICT_VALID if state == STATE_AIMING else VERDICT_BLOCKED))
	var state_token: StringName = HudModel.STATE_CRITICAL
	if current == String(VERDICT_VALID):
		state_token = HudModel.STATE_NORMAL
	elif current == String(VERDICT_WARN):
		state_token = HudModel.STATE_WARNING
	var centres: Array[Vector3] = []
	for tile: Vector2i in _tiles:
		centres.append(BuildController.footprint_centre(tile, Vector2i.ONE, tile_m))
	return {
		"visible": is_active() and has_head and not centres.is_empty(),
		"aiming": state == STATE_AIMING,
		"tiles": _tiles.duplicate(),
		"centres": centres,
		"billable": billable_flags(),
		"anchor": anchor,
		"head": head,
		"tile_m": tile_m,
		"verdict": current,
		"state": state_token,
	}


## Per tile of the run: will the owning command actually *touch* this one?
##
## Doc 10 §2.13 keeps build, upgrade and demolish as three verbs and each passes
## silently over the tiles the other two own — a build sweep over three tiles of
## existing street is billed for what it lays, not for what the thumb crossed.
## The player has to be able to see that before they commit, so the ghost dims
## the untouched tiles. One `road_class_at` per tile, which is O(1) and is why
## this can ride the 10 Hz revalidation instead of a second preview per tile.
func billable_flags() -> Array[bool]:
	var out: Array[bool] = []
	if sim == null or card_id == "":
		for _tile: Vector2i in _tiles:
			out.append(true)
		return out
	var verb := StringName(str(PathTool.row(card_id)["verb"]))
	for tile: Vector2i in _tiles:
		if not TileGrid.in_bounds(tile.x, tile.y):
			out.append(false)
			continue
		var road_class := sim.world.grid.road_class_at(tile.x, tile.y)
		match verb:
			VERB_ROAD_BUILD:
				out.append(road_class == TileGrid.ROAD_NONE)
			VERB_ROAD_UPGRADE:
				out.append(road_class == TileGrid.ROAD_STREET)
			VERB_ROAD_DEMOLISH:
				out.append(road_class != TileGrid.ROAD_NONE)
			_:
				# Doc 05 §6 bills every tile of a main, the tap included.
				out.append(true)
	return out


## The 56 dp placement bar (doc 12 §2.7). `mode` is what the primary button is
## for right now, which is the only thing about a run tool the view has to know.
func placement_view() -> Dictionary:
	var failure: Dictionary = _verdict.get("failure", {})
	var entry := PathTool.row(card_id)
	var refunds := bool(entry["refunds"]) if not entry.is_empty() else false
	var amount := run_cost()
	return {
		"active": is_active(),
		"is_path": true,
		"mode": String(state),
		"archetype": card_id,
		"variant": "",
		"component_kind": "",
		"component_domain": "",
		"path_verb": str(entry.get("verb", "")),
		"name_key": PathTool.card_name_key(card_id),
		"tile_count": _tiles.size() if state == STATE_DRAWING else 0,
		"refunds": refunds,
		"cost": amount,
		"cost_text": RequirementFormatter.money(absi(amount)),
		"per_tile": per_tile_price(card_id),
		"per_tile_text": per_tile_text(card_id),
		"verdict": str(_verdict.get("verdict",
				VERDICT_VALID if state == STATE_AIMING else VERDICT_BLOCKED)),
		"can_confirm": can_confirm(),
		"can_start": is_active() and has_head,
		"issue_count": 0 if failure.is_empty() else 1,
		"failure": failure,
	}


func _t(key: String, args: Dictionary, fallback: String) -> String:
	var cfg: UIConfig = formatter.config if formatter != null else null
	if cfg != null and cfg.has_string(key):
		return cfg.t(key, args)
	return fallback

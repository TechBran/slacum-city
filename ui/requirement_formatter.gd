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
	&"POWER_CAPACITY": {"severity": SEVERITY_BLOCKED, "fix": FIX_BUILDING},
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
	&"E_CONDITION": {"severity": SEVERITY_BLOCKED, "fix": FIX_BUILDING},
	&"E_MAX_LEVEL": {"severity": SEVERITY_INFO, "fix": FIX_NONE},
	&"E_UNKNOWN_ARCHETYPE": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_UNKNOWN_BUILDING": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
	&"E_NO_FEEDER": {"severity": SEVERITY_BLOCKED, "fix": FIX_TILE},
	&"E_AUSTERITY": {"severity": SEVERITY_BLOCKED, "fix": FIX_NONE},
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
		"fix_target": {
			"kind": RequirementFormatter.fix_kind(name),
			"id": str(params.get("fix_target_id", "")),
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
		&"E_STATE":
			args["have"] = str(p.get("have", p.get("state", "")))
			args["need"] = str(p.get("need", p.get("required_state", "")))
		&"E_CONDITION":
			args["have"] = str(p.get("have",
					RequirementFormatter.percent(p.get("condition", 0.0))))
			args["need"] = str(p.get("need",
					RequirementFormatter.percent(p.get("min_condition", 0.0))))
		&"E_MAX_LEVEL":
			args["have"] = str(p.get("have", int(p.get("level", 0))))
			args["need"] = str(p.get("need", int(p.get("max_level", 0))))
		&"E_UNKNOWN_ARCHETYPE":
			args["have"] = str(p.get("have", p.get("archetype", "")))
			args["need"] = str(p.get("need", ""))
		&"E_UNKNOWN_BUILDING":
			args["have"] = str(p.get("have", p.get("sim_id", "")))
			args["need"] = str(p.get("need", ""))
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

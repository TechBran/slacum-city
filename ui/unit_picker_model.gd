class_name UnitPickerModel
extends RefCounted
## The unit picker's list (doc 12 §2.6, S7): every unit that could answer one
## incident, ranked by how soon it can be there.
##
## The seam is one injected `Callable` and nothing else:
##
##     set_provider(Callable(incident_id: int) -> Array[Dictionary])
##
## returning one row per unit the shell is willing to offer:
##
##     {id: int, dept: String, kind: String, eta_gs: float, state: String}
##
## plus four optional fields the sim can answer cheaply and the picker uses when
## they are there: `eligible: bool` (false ⇒ WRONG TYPE, sorted last and dimmed),
## `required: bool` (false ⇒ OPTIONAL rather than REQUIRED), `incident_id: int`
## (what it is on right now) and `frees_in_gs: float` (how soon it is free).
##
## `eta_gs` is **game-seconds**, negative when the sim cannot route to the
## incident; `state` is doc 06's `Vehicle` status string verbatim (`IDLE`,
## `RESPONDING`, `ON_SCENE`, `RETURNING`, `REFIT`, `OFFLINE`) so a rename on
## either side is a test failure rather than a silent mis-sort. Everything else
## — ranking, tags, copy, the AUTO pick and the empty-state card — is computed
## here, headless, from `data/ui.json` and `data/strings.en.json`.
##
## Why a provider rather than a snapshot the shell pushes: the list is only ever
## needed for the one incident whose ASSIGN the player just tapped, and doc 06
## states `eta_seconds()` "must be cheap (cached, ≤ 2 ms for 40 units)". Pulling
## on open costs one query per *tap*; pushing would cost one per *tick*.

## §2.6's rank key is `(not eligible, status_rank, eta_seconds, id)` with
## `status_rank = 0 Available, 1 Returning, 2 Reassignable-busy`.
const RANK_AVAILABLE := 0
const RANK_RETURNING := 1
const RANK_BUSY := 2
const RANK_INELIGIBLE := 3

const TAG_REQUIRED := &"required"
const TAG_OPTIONAL := &"optional"
const TAG_INELIGIBLE := &"ineligible"

## Doc 06 `Vehicle` status → rank. REFIT and OFFLINE are not dispatchable at all
## (`Vehicle.is_dispatchable_now()`), so they can only appear as WRONG TYPE rows.
const STATE_RANKS := {
	"IDLE": RANK_AVAILABLE,
	"RETURNING": RANK_RETURNING,
	"RESPONDING": RANK_BUSY,
	"ON_SCENE": RANK_BUSY,
	"REFIT": RANK_INELIGIBLE,
	"OFFLINE": RANK_INELIGIBLE,
}

const DISPATCHABLE_STATES := ["IDLE", "RETURNING", "RESPONDING", "ON_SCENE"]

var _cfg: UIConfig
var _picker: Dictionary = {}
var _provider := Callable()
var _incident: Dictionary = {}
var _rows: Array[Dictionary] = []


func _init(cfg: UIConfig = null) -> void:
	if cfg == null:
		return
	_cfg = cfg
	_picker = cfg.section("unit_picker")


static func load_from_files() -> UnitPickerModel:
	return UnitPickerModel.new(UIConfig.load_from_files())


## `Callable(incident_id: int) -> Array[Dictionary]`. Until it is set the picker
## renders its empty-state card rather than a blank sheet (A14: a surface with
## nothing on it still says why).
func set_provider(provider: Callable) -> void:
	_provider = provider


func has_provider() -> bool:
	return _provider.is_valid()


# ---------------------------------------------------------------------------
# Query
# ---------------------------------------------------------------------------

## Pull the roster for one incident (an `IncidentModel` row) and rank it.
## Returns the ranked rows; `rows()` returns the same list afterwards.
func open_for(incident_row: Dictionary) -> Array[Dictionary]:
	_incident = incident_row.duplicate(true)
	_rows = []
	var incident_id := int(incident_row.get("id", 0))
	if incident_id <= 0 or not _provider.is_valid():
		return _rows
	var raw: Variant = _provider.call(incident_id)
	if not (raw is Array):
		return _rows
	_rows = rank(raw as Array)
	return _rows


## Pure: the ranking of §2.6 step 3 over a roster the caller already has. Exposed
## separately so the comparator is testable without a provider.
func rank(roster: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw: Variant in roster:
		if not (raw is Dictionary):
			continue
		out.append(_decorate(raw as Dictionary))
	out.sort_custom(UnitPickerModel._compare)
	return out


static func _compare(a: Dictionary, b: Dictionary) -> bool:
	if int(a["status_rank"]) != int(b["status_rank"]):
		return int(a["status_rank"]) < int(b["status_rank"])
	# A unit the sim cannot route to sorts behind every unit it can, rather than
	# jumping to the top on a negative ETA.
	var a_eta := float(a["eta_gs"])
	var b_eta := float(b["eta_gs"])
	var a_known := a_eta >= 0.0
	var b_known := b_eta >= 0.0
	if a_known != b_known:
		return a_known
	if a_known and not is_equal_approx(a_eta, b_eta):
		return a_eta < b_eta
	return int(a["id"]) < int(b["id"])


func _decorate(record: Dictionary) -> Dictionary:
	var state := str(record.get("state", "IDLE")).to_upper()
	var dispatchable := DISPATCHABLE_STATES.has(state)
	var eligible := bool(record.get("eligible", true)) and dispatchable
	var required := bool(record.get("required", true))
	var eta_gs := float(record.get("eta_gs", -1.0))
	var rank_value := int(STATE_RANKS.get(state, RANK_BUSY))
	if not eligible:
		rank_value = RANK_INELIGIBLE
	var tag: StringName = TAG_INELIGIBLE
	if eligible:
		tag = TAG_REQUIRED if required else TAG_OPTIONAL
	var unit_id := int(record.get("id", 0))
	var kind := str(record.get("kind", record.get("type", "")))
	var row := {
		"id": unit_id,
		"dept": str(record.get("dept", record.get("department", ""))),
		"kind": kind,
		"state": state,
		"eta_gs": eta_gs,
		"eligible": eligible,
		"required": required,
		"tag": tag,
		"status_rank": rank_value,
		"incident_id": int(record.get("incident_id", 0)),
		"frees_in_gs": float(record.get("frees_in_gs", -1.0)),
		"name": _unit_name(unit_id, kind),
		"eta_text": _eta_text(eta_gs),
		"state_text": _state_text(state),
		"tag_text": _tag_text(tag),
		"dept_glyph": dept_glyph(str(record.get("dept", record.get("department", "")))),
	}
	row["state_token"] = UnitPickerModel.state_token(state, eligible)
	return row


## §2.5's four data states, applied to a unit row: an available unit reads
## NORMAL, one that is busy but reassignable WARNING, an ineligible one OFFLINE.
static func state_token(state: String, eligible: bool) -> StringName:
	if not eligible:
		return HudModel.STATE_OFFLINE
	match int(STATE_RANKS.get(state, RANK_BUSY)):
		RANK_AVAILABLE: return HudModel.STATE_NORMAL
		RANK_RETURNING: return HudModel.STATE_NORMAL
		_: return HudModel.STATE_WARNING


func dept_glyph(dept: String) -> String:
	var raw: Variant = _picker.get("dept_glyphs", {})
	var glyphs: Dictionary = raw if raw is Dictionary else {}
	return str(glyphs.get(dept.to_lower(), str(glyphs.get("unknown", ""))))


func _unit_name(unit_id: int, kind: String) -> String:
	var key := "ui_unit_kind_%s" % kind
	var label := _cfg.t(key) if _cfg != null and _cfg.has_string(key) \
			else UIWidgets.t(_cfg, "ui_unit_kind_unknown")
	return UIWidgets.t_args(_cfg, "ui_picker_unit", {"kind": label, "id": unit_id})


func _eta_text(eta_gs: float) -> String:
	if eta_gs < 0.0:
		return UIWidgets.t(_cfg, "ui_picker_eta_unknown")
	return UIWidgets.t_args(_cfg, "ui_picker_eta",
			{"eta": HudModel.eta(int(round(eta_gs)))})


func _state_text(state: String) -> String:
	var key := "ui_picker_state_%s" % state.to_lower()
	if _cfg != null and _cfg.has_string(key):
		return _cfg.t(key)
	return state.capitalize()


func _tag_text(tag: StringName) -> String:
	return UIWidgets.t(_cfg, "ui_picker_tag_%s" % String(tag))


# ---------------------------------------------------------------------------
# Read side
# ---------------------------------------------------------------------------

func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row: Dictionary in _rows:
		out.append(row.duplicate(true))
	return out


func incident() -> Dictionary:
	return _incident.duplicate(true)


func incident_id() -> int:
	return int(_incident.get("id", 0))


func size() -> int:
	return _rows.size()


func eligible_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row: Dictionary in _rows:
		if bool(row["eligible"]):
			out.append(row.duplicate(true))
	return out


## §2.6 step 2's primary button: the top-ranked eligible unit, which is exactly
## the first eligible row after the sort. `{}` when nothing can be sent.
func auto_pick() -> Dictionary:
	for row: Dictionary in _rows:
		if bool(row["eligible"]):
			return row.duplicate(true)
	return {}


func row(unit_id: int) -> Dictionary:
	for record: Dictionary in _rows:
		if int(record["id"]) == unit_id:
			return record.duplicate(true)
	return {}


## The header line: what the player is dispatching to.
func header_text() -> String:
	if _incident.is_empty():
		return UIWidgets.t(_cfg, "ui_picker_title")
	return UIWidgets.t_args(_cfg, "ui_picker_header", {
		"incident": str(_incident.get("title", "")),
		"tier": int(_incident.get("tier", 1)),
	})


## §2.6 step 5's state card. `{}` while at least one unit can be sent; otherwise
## the reason in words (A14) plus the soonest a unit frees, when the shell knows.
func empty_card() -> Dictionary:
	if not auto_pick().is_empty():
		return {}
	if not _provider.is_valid():
		return {"text": UIWidgets.t(_cfg, "ui_picker_unavailable"), "soonest_gs": -1.0}
	var soonest := -1.0
	for record: Dictionary in _rows:
		var frees := float(record["frees_in_gs"])
		if frees < 0.0:
			continue
		soonest = frees if soonest < 0.0 else minf(soonest, frees)
	if soonest < 0.0:
		return {"text": UIWidgets.t(_cfg, "ui_picker_empty"), "soonest_gs": -1.0}
	return {
		"text": UIWidgets.t_args(_cfg, "ui_picker_empty_soonest",
				{"eta": HudModel.eta(int(round(soonest)))}),
		"soonest_gs": soonest,
	}


## The toast copy after a successful dispatch (§2.6 step 4).
func dispatched_text(unit_id: int) -> String:
	var record := row(unit_id)
	if record.is_empty():
		return UIWidgets.t(_cfg, "ui_picker_failed")
	return UIWidgets.t_args(_cfg, "ui_picker_dispatched", {
		"unit": str(record["name"]),
		"eta": HudModel.eta(int(round(maxf(0.0, float(record["eta_gs"]))))),
	})


func clear() -> void:
	_incident = {}
	_rows = []

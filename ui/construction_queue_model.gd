class_name ConstructionQueueModel
extends RefCounted
## **S16 — the construction queue, headless** (doc 12 §2.22). What the city is
## building right now, how far along each project is, when it lands, and what it
## costs to make it land sooner.
##
## Node-free and sim-free like every other model in `ui/` (constitution §3). It
## does not import `CitySim`, it does not know what a `Building` is, and it holds
## no price: it is handed **two Callables and a reading**, and everything it
## publishes is a rearrangement of what they answer.
##
##   * `set_provider(c)` — `c.call()` answers `CitySim.construction_overview()`:
##     an Array of contract rows, one per IN-FLIGHT project. The seam is
##     published verbatim in `ROW_KEYS` below and this file reads nothing else.
##   * `set_rush(c)` — `c.call(job_id)` answers `CitySim.cmd_rush_construction()`
##     with `{ok, err, cost}`.
##   * `set_treasury(c)` — `c.call()` answers the balance, in whole dollars.
##     Affordability is a UI reading and never a UI *decision*: the door still
##     refuses a rush this model thought was affordable, and the refusal wins.
##
## Every one of the three defaults to unbound, and unbound degrades rather than
## fails — an empty queue, a refusal with `E_NO_COMMAND`, and a treasury of zero
## that renders the price on a disabled face. A shell that never wires the seam
## therefore shows exactly what a city with nothing under way shows, which is
## nothing at all.
##
## **Why a provider and not a sim.** `tools/ui_preview.gd` has to reach a queue
## with three mixed rows and a queue with an uncrewed one on demand, and a live
## sim reaches neither: a crewed job and a starved one are hours apart in a real
## city. The provider is also what let this half of the wave be built and swept
## before the sim half existed.

## The seam, verbatim (the Wave-14 lesson: siblings who guess each other's seams
## mismatch on every one). A row that is missing one of these is read with the
## fallback beside it rather than crashing the screen, and a row that carries
## something this list does not name is ignored — a field one side ships and the
## other does not is a deferral, never a guess.
const ROW_KEYS := {
	"job_id": TYPE_INT, "source": TYPE_STRING_NAME, "title_key": TYPE_STRING,
	"ref": TYPE_STRING, "tile": TYPE_VECTOR2I, "level_from": TYPE_INT,
	"level_to": TYPE_INT, "progress01": TYPE_FLOAT, "eta_gm": TYPE_FLOAT,
	"crews": TYPE_INT, "rushable": TYPE_BOOL, "rush_cost": TYPE_INT,
}

## Every `source` this screen has a word for — **enumerated, never invented.**
## `ConstructionQueue.KINDS` verbatim (`build`, `upgrade`, `repair`, `rebuild`,
## `clear_rubble`, `road`, `development`) plus `block`, which is the seam
## contract's own name for a land development. Both spellings of that last one
## are kept on purpose: the contract names one and the sim's queue names the
## other, whichever the sim half ships resolves here, and the one it does not
## ship is a deferral row (doc 12 §2.22), not a guess. Anything outside this
## list renders as `ui_queue_source_other` and is reported by
## `unknown_sources()`; `tests/test_ui_construction_queue.gd` holds the list
## equal to the sim's `KINDS` so a new kind fails a test rather than going grey.
const KNOWN_SOURCES: Array[StringName] = [&"block", &"build", &"upgrade", &"repair",
		&"rebuild", &"clear_rubble", &"road", &"development"]

## The event the door raises through the normal batch. Named as a constant
## because it is the seam to a system this file does not import — a build whose
## sim never emits it simply never sounds a coin.
const EVENT_RUSHED := &"construction_rushed"

## `eta_gm < 0` is the contract's "nothing is working this". It is a STATE and
## not a small number, which is the whole reason it is not rendered as a clock:
## `0:00` reads as *finishing now* and this is its opposite.
const ETA_NONE := -1.0

## The chip the spend pulses — `HudModel`'s own spelling, never a second copy.
const CHIP_TREASURY := HudModel.CHIP_TREASURY

## Fallbacks for a malformed `data/ui.json` (constitution §3: degrade, never
## crash). Every one of them is also authored in the file.
const DEFAULT_ROW_H_DP := 96.0
const DEFAULT_CHIP_W_DP := 72.0
const DEFAULT_PANEL_W_DP := 320.0
const DEFAULT_BAR_H_DP := 6.0
const DEFAULT_CHIP_FLASH_S := 0.9

var config: UIConfig

var _provider := Callable()
var _rush := Callable()
var _treasury := Callable()

var _rows: Array[Dictionary] = []
var _raw_count := 0
## Sources the seam shipped that this table has no word for. Reported rather
## than swallowed: a source nobody named renders as a neutral "Project", and
## `tests/test_ui_construction_queue.gd` reads this list so a new sim-side kind
## shows up as a missing string instead of as silent grey copy.
var _unknown_sources: Dictionary = {}


func _init(cfg: UIConfig = null) -> void:
	config = cfg


static func load_from_files() -> ConstructionQueueModel:
	return ConstructionQueueModel.new(UIConfig.load_from_files())


# ---------------------------------------------------------------------------
# The three wires
# ---------------------------------------------------------------------------

func set_provider(provider: Callable) -> void:
	_provider = provider


func set_rush(command: Callable) -> void:
	_rush = command


func set_treasury(reading: Callable) -> void:
	_treasury = reading


func has_provider() -> bool:
	return _provider.is_valid()


# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

func section() -> Dictionary:
	return config.section("construction") if config != null else {}


func row_h_dp() -> float:
	return UIConfig.get_num(section(), "row_h_dp", DEFAULT_ROW_H_DP)


func chip_w_dp() -> float:
	return UIConfig.get_num(section(), "chip_w_dp", DEFAULT_CHIP_W_DP)


func panel_w_dp() -> float:
	return UIConfig.get_num(section(), "panel_w_dp", DEFAULT_PANEL_W_DP)


func bar_h_dp() -> float:
	return UIConfig.get_num(section(), "bar_h_dp", DEFAULT_BAR_H_DP)


func chip_flash_s() -> float:
	return UIConfig.get_num(section(), "chip_flash_s", DEFAULT_CHIP_FLASH_S)


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

## Pulls the provider once and rebuilds the view. Cheap enough for the shell's
## 1 Hz HUD cadence — it walks the in-flight list, which is bounded by the
## city's crew count plus whatever is waiting for one.
func refresh() -> void:
	_rows.clear()
	_unknown_sources.clear()
	_raw_count = 0
	if not _provider.is_valid():
		return
	var answer: Variant = _provider.call()
	if not (answer is Array):
		return
	for entry: Variant in (answer as Array):
		if not (entry is Dictionary):
			continue
		_raw_count += 1
		_rows.append(_view_row(entry as Dictionary))
	_rows.sort_custom(ConstructionQueueModel._sooner_first)


## The rows, worst-known-first: everything with a crew on it in ETA order, then
## everything nobody is working, oldest job first.
##
## **The sim already sorts this way and this model sorts it again**, which is
## deliberate rather than redundant: the provider is a Callable, `ui/` has no way
## to hold a seam to its promise, and a fixture or a future second source that
## arrives unsorted would otherwise put the thing that lands next halfway down a
## scrolling list. Sorting an already-sorted list costs nothing.
func rows() -> Array[Dictionary]:
	return _rows


func count() -> int:
	return _rows.size()


func is_empty() -> bool:
	return _rows.is_empty()


## How many rows the provider handed over, including any this model could not
## read. Equal to `count()` in every healthy build; a gap is a seam mismatch and
## the tests say so by name.
func raw_count() -> int:
	return _raw_count


func unknown_sources() -> PackedStringArray:
	var out: PackedStringArray = []
	for key: Variant in _unknown_sources:
		out.append(str(key))
	out.sort()
	return out


## One row by job id, or `{}`.
func row(job_id: int) -> Dictionary:
	for entry: Dictionary in _rows:
		if int(entry["job_id"]) == job_id:
			return entry
	return {}


## One row by the thing it is being done TO — the contract's `ref`, which is the
## queue's own `target_ref`. This is how S5 finds the project for the building
## the player has open (§2.22 item 3) without inventing a second index.
##
## Returns the SOONEST of them when a ref carries more than one, because that is
## the one whose bar is moving and whose ETA the panel is about to print.
func row_for_ref(ref: String) -> Dictionary:
	if ref == "":
		return {}
	for entry: Dictionary in _rows:
		if str(entry["ref"]) == ref:
			return entry
	return {}


## The count on the chip's face. Empty when nothing is building — the chip hides
## then, and a badge reading `0` on a hidden control is a badge that will read
## `0` the day the hiding breaks.
func badge_text() -> String:
	return "" if _rows.is_empty() else str(_rows.size())


## The chip's accessibility name (A15) and its tooltip: `3 building`.
func chip_tooltip() -> String:
	if _rows.is_empty():
		return _t("ui_queue_chip_idle", "Nothing under construction")
	return _t_args("ui_queue_chip", {"n": _rows.size()},
			"%d building" % _rows.size())


## The one line under the panel's title: `3 under way · 1 waiting for a crew`.
## The second half only exists when something is actually waiting, because a
## queue where every project has a crew has nothing to apologise for.
func summary_text() -> String:
	if _rows.is_empty():
		return ""
	var idle := 0
	for entry: Dictionary in _rows:
		if not bool(entry["working"]):
			idle += 1
	if idle <= 0:
		return _t_args("ui_queue_summary", {"n": _rows.size()},
				"%d under way" % _rows.size())
	return "%s %s %s" % [
		_t_args("ui_queue_summary", {"n": _rows.size()}, "%d under way" % _rows.size()),
		_t("ui_queue_separator", "·"),
		_t_args("ui_queue_summary_idle", {"n": idle}, "%d waiting for a crew" % idle),
	]


## Counts by `source`, in a stable alphabetical order — the grouping half of
## this model's job, published as a summary rather than as section headers.
##
## **Why the list itself is not grouped.** The seam sorts by ETA and so does
## this; a 320 dp column broken into per-source sections would put the thing
## that lands in four minutes below a heading and under two projects that land
## tomorrow, which is the one reading this screen exists to give. The kind is
## carried on the row instead, where it costs no ordering.
func groups() -> Array[Dictionary]:
	var counts: Dictionary = {}
	for entry: Dictionary in _rows:
		var key := String(entry["source"])
		counts[key] = int(counts.get(key, 0)) + 1
	var keys: Array = counts.keys()
	keys.sort()
	var out: Array[Dictionary] = []
	for key: Variant in keys:
		out.append({"source": StringName(str(key)), "count": int(counts[key]),
				"label": _source_label(StringName(str(key)))})
	return out


# ---------------------------------------------------------------------------
# One row, from the seam's shape into words
# ---------------------------------------------------------------------------

func _view_row(raw: Dictionary) -> Dictionary:
	var source := StringName(str(raw.get("source", "")))
	var eta := float(raw.get("eta_gm", ETA_NONE))
	var crews := int(raw.get("crews", 0))
	# The contract's two ways of saying the same thing have to agree before a
	# sentence is written about it: `eta_gm < 0` is "nothing is working it", and
	# a job with no crew cannot have an ETA whatever number came with it.
	var working := eta >= 0.0 and crews > 0
	var progress := clampf(float(raw.get("progress01", 0.0)), 0.0, 1.0)
	var rush_cost := maxi(0, int(raw.get("rush_cost", 0)))
	var rushable := bool(raw.get("rushable", false))
	var affordable := rushable and rush_cost <= balance()
	var level_from := int(raw.get("level_from", 0))
	var level_to := int(raw.get("level_to", 0))
	return {
		"job_id": int(raw.get("job_id", 0)),
		"source": source,
		"source_label": _source_label(source),
		"title": _title(raw),
		"ref": str(raw.get("ref", "")),
		"tile": _tile(raw.get("tile", Vector2i.ZERO)),
		"level_text": _level_text(level_from, level_to),
		"level_from": level_from,
		"level_to": level_to,
		"progress01": progress,
		"percent_text": HudModel.percent_text(progress * 100.0),
		"working": working,
		"crews": crews,
		"crew_text": _crew_text(crews),
		"eta_gm": eta,
		"eta_text": _eta_text(working, eta),
		"state": HudModel.STATE_NORMAL if working else HudModel.STATE_WARNING,
		"rushable": rushable,
		"rush_cost": rush_cost,
		"rush_text": _rush_text(rushable, rush_cost),
		"rush_tooltip": _rush_tooltip(rushable, rush_cost, affordable),
		"affordable": affordable,
	}


## The title the seam named. `title_key` is a `data/strings.en.json` key and a
## key that is not in the table would render as itself — which `UIAudit`'s
## `raw_string_key` check calls a defect, correctly — so an unresolved one falls
## back to a real English word instead.
func _title(raw: Dictionary) -> String:
	var key := str(raw.get("title_key", ""))
	if key != "" and config != null and config.has_string(key):
		return config.t(key)
	return _t("ui_queue_untitled", "Project")


func _source_label(source: StringName) -> String:
	if source == &"":
		return _t("ui_queue_source_other", "Project")
	var key := "ui_queue_source_%s" % String(source)
	if config != null and config.has_string(key):
		return config.t(key)
	_unknown_sources[String(source)] = true
	return _t("ui_queue_source_other", "Project")


## `Level 2 → 3`, and nothing at all when the contract says `0/0`. A project that
## is not a level change must not print one: doc 12 §2.9's pips are the reading
## for "what level is this", and a queue row inventing `Level 0 → 0` would be a
## second, wrong answer to the same question.
func _level_text(from_level: int, to_level: int) -> String:
	if from_level <= 0 and to_level <= 0:
		return ""
	if to_level <= 0 or to_level == from_level:
		return _t_args("ui_queue_level_flat", {"level": from_level},
				"Level %d" % from_level)
	return _t_args("ui_queue_level", {"from": from_level, "to": to_level},
			"Level %d → %d" % [from_level, to_level])


## The ETA line, and the one rule doc 12 §2.8 wrote for it: **an unworked project
## says so in words.** `0:00` is what a clock reads a second before it lands and
## this is the opposite state; a bar frozen at 12 % with a countdown under it is
## a lie the player will act on.
func _eta_text(working: bool, eta_gm: float) -> String:
	if not working:
		return _t("ui_queue_eta_none", "Nothing is working on this")
	return _t_args("ui_queue_eta",
			{"eta": UIWidgets.duration_text(config, eta_gm)},
			"about %s left" % UIWidgets.duration_text(config, eta_gm))


func _crew_text(crews: int) -> String:
	if crews <= 0:
		return _t("ui_queue_crew_none", "No crew")
	return _t_args("ui_queue_crew", {"n": crews}, "%d crews" % crews)


## The price goes on the button's FACE, never only in a confirmation — the
## build-card pattern (§2.7), for the same reason: a button that names what it
## will take is a button nobody has to be asked twice about (§2.22's ruling).
func _rush_text(rushable: bool, cost: int) -> String:
	if not rushable:
		return _t("ui_queue_rush", "RUSH")
	return _t_args("ui_queue_rush_price", {"cost": HudModel.money(cost)},
			"RUSH %s" % HudModel.money(cost))


func _rush_tooltip(rushable: bool, cost: int, affordable: bool) -> String:
	if not rushable:
		return _t("ui_queue_rush_unavailable", "This cannot be rushed")
	if not affordable:
		return _t_args("ui_queue_rush_short",
				{"cost": HudModel.money(cost), "have": HudModel.money(balance())},
				"%s needed, %s available" % [HudModel.money(cost),
						HudModel.money(balance())])
	return _t_args("ui_queue_rush_hint", {"cost": HudModel.money(cost)},
			"Finish this now for %s" % HudModel.money(cost))


static func _tile(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value as Vector2i
	if value is Vector2:
		var point: Vector2 = value
		return Vector2i(int(point.x), int(point.y))
	if value is Array and (value as Array).size() >= 2:
		var pair: Array = value
		return Vector2i(int(pair[0]), int(pair[1]))
	return Vector2i.ZERO


## Working projects in ETA order, then everything nobody is on, oldest first.
## Ties break on `job_id` so the list never reorders under a finger for two rows
## that land in the same minute.
static func _sooner_first(a: Dictionary, b: Dictionary) -> bool:
	var a_working := bool(a["working"])
	var b_working := bool(b["working"])
	if a_working != b_working:
		return a_working
	if a_working and not is_equal_approx(float(a["eta_gm"]), float(b["eta_gm"])):
		return float(a["eta_gm"]) < float(b["eta_gm"])
	return int(a["job_id"]) < int(b["job_id"])


# ---------------------------------------------------------------------------
# The verb
# ---------------------------------------------------------------------------

func balance() -> int:
	if not _treasury.is_valid():
		return 0
	var answer: Variant = _treasury.call()
	return int(answer) if typeof(answer) != TYPE_NIL else 0


## The door, with the door's own coercion at it (the Wave-14 String-id lesson —
## a row id that arrived as a String must not become job 0). Returns
## `CitySim.cmd_rush_construction`'s answer verbatim, plus nothing: this model
## does not re-read the queue, because the shell's own refresh is what publishes
## the city that command just changed.
func rush(job_id: Variant) -> Dictionary:
	if not _rush.is_valid():
		return {"ok": false, "err": String(BuildController.E_NO_COMMAND), "cost": 0}
	var answer: Variant = _rush.call(int(str(job_id)))
	if not (answer is Dictionary):
		return {"ok": false, "err": String(BuildController.E_NO_COMMAND), "cost": 0}
	var out: Dictionary = answer
	return {
		"ok": bool(out.get("ok", false)),
		"err": str(out.get("err", out.get("reason_code", ""))),
		"cost": int(out.get("cost", 0)),
	}


# ---------------------------------------------------------------------------
# The cue (doc 12 §2.22, the D-62 shape with the money going the other way)
# ---------------------------------------------------------------------------

## What a `construction_rushed` should be worth to the senses:
## `{ok, amount, toast, cue, flash_chip, haptic}` — the same record
## `StreetModel` publishes for a payday, spent by `UIRoot._spend_feedback()` on
## the same three surfaces.
##
## **One cue, one chip flash, one sentence, and the money goes OUT.** A payday
## and a purchase are the same beat backwards, so this takes the deck's spend
## cue (`purchase`, `data/audio.json`'s own rule on `construction_rushed`) rather
## than the coin — a player who hears a till when their balance drops learns the
## wrong thing about their own treasury. The completion the rush causes is NOT
## sounded here: it arrives a moment later on `building_completed` and sounds
## `construct_complete`, exactly as an unrushed one does.
##
## Returns `{}` for an event that cost nothing, which is a rush that did not
## happen and has nothing to say.
func rush_feedback(event: Dictionary) -> Dictionary:
	var cost := int(event.get("cost", 0))
	if cost <= 0:
		return {}
	var source := StringName(str(event.get("source", "")))
	return {
		"ok": true,
		"amount": cost,
		"amount_text": HudModel.money_exact(-cost),
		"job": int(event.get("job", 0)),
		"source": source,
		"toast": _t_args("ui_queue_rushed_toast",
				{"what": _source_label(source),
						"cost": HudModel.money_exact(-cost)},
				"%s rushed — %s" % [_source_label(source),
						HudModel.money_exact(-cost)]),
		# The cue is a `data/audio.json` rule on the event itself, so the shell
		# needs no branch: `AudioService.feed_batch()` already gets this batch.
		"cue": false,
		"flash_chip": CHIP_TREASURY,
		"flash_s": chip_flash_s(),
		# §2.14: this one DOES buzz, unlike a bounty. The player's own thumb is
		# on the button — a confirmation in the hand is what a spend with no
		# confirm dialog owes them.
		"haptic": Haptics.CUE_DISPATCH,
	}


# ---------------------------------------------------------------------------
# Copy
# ---------------------------------------------------------------------------

func _t(key: String, fallback: String = "") -> String:
	return UIWidgets.t(config, key, fallback)


func _t_args(key: String, args: Dictionary, fallback: String = "") -> String:
	return UIWidgets.t_args(config, key, args, fallback)

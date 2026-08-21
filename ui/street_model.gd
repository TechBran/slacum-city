class_name StreetModel
extends RefCounted
## **The payday, headless.** Wave 14's answer to the one thing the playtest said
## was missing — "there's not a lot of downtime of absolutely nothing to do" —
## from the UI side of the seam. The sim spawns the collectables and pays for
## them; the renderer draws them; this class owns everything that happens
## between a collect landing and the player believing it happened.
##
## Node-free and sim-free, like every other model in `ui/` (constitution §3):
## it takes plain data in — a command result, a bus event — and hands back a
## Dictionary of *what should be felt*, which `ui/ui_root.gd` spends on the
## surfaces it owns. It plays no sound, shows no toast and holds no clock.
##
## Four jobs, and they are deliberately in one class because they are one beat:
##
##   1. **The payday.** `collect_feedback()` and `bounty_feedback()` turn a
##      collect and an `incident_resolved` into `{cue, toast, flash_chip,
##      haptic}`. Both resolve to the same cue and the same chip, because to a
##      player they are the same event: money arrived.
##   2. **Discovery.** `note_spawn()` fires exactly once, ever, for the first
##      opportunity a save has ever seen, and never again — the flag rides in
##      the `ui` save section, so a reload does not re-teach a lesson.
##   3. **The ledger.** Bounties are `Treasury.credit(…, &"incident", …)` and
##      street pickups arrive the same way: neither passes through
##      `EconomySystem.settle_hour`, so **no row of the Economy tab has ever
##      contained either of them** and its NET has been wrong by exactly that
##      much every hour a crew answered a call. Until doc 03 settles them, this
##      class tallies them per game-hour off the bus and `BudgetModel` renders
##      the two lines from the tally. See `side_revenue()`.
##   4. **A8.** Under `reduce_motion` the collect's floating `+$` is suppressed
##      — it is motion, and doc 11 owns it — so this class raises a toast
##      instead. The payday is never silent for an accessibility setting.
##
## No reward, spawn rate or lifetime is authored here or anywhere else in `ui/`.
## The only numbers this file owns are in `data/ui.json.street`, and every one of
## them is about the finger or the screen.

# --- Bus events this class reads -------------------------------------------
## Doc 06's resolve. It has carried `reward` since the incident system shipped
## and nothing has ever sounded it, toasted it or counted it.
const EVENT_INCIDENT_RESOLVED := &"incident_resolved"
## The street system's spawn and its collect. Named as constants because they
## are the seam to a system this file does not import; a build whose sim emits
## neither simply never raises a coach mark and never tallies a pickup.
const EVENT_SPAWNED := &"opportunity_spawned"
const EVENT_COLLECTED := &"opportunity_collected"
## Doc 03's hourly close — the tally's window boundary, and nothing else.
const EVENT_HOUR_SETTLED := &"economy_hour_settled"

# --- Ledger keys. `data/ui.json.budget.revenue_keys` carries the same two. ---
const REVENUE_BOUNTIES := "bounties"
const REVENUE_STREET := "street"

## The chip a deposit pulses — `HudModel`'s own spelling, never a second copy.
const CHIP_TREASURY := HudModel.CHIP_TREASURY

## Fallbacks for a malformed `data/ui.json` (constitution §3: degrade, never
## crash). Every one of them is also authored in the file.
const DEFAULT_COACH_TTL_S := 14.0
const DEFAULT_CHIP_FLASH_S := 0.9
const DEFAULT_TOAST_MIN := 25

var config: UIConfig

## Set once, from the first spawn this save ever sees, and persisted. It is NOT
## a tutorial step: gate 21 counts those, this gates nothing, and a player who
## skipped the tutorial still gets it.
var coached := false

## `true` while a first opportunity was seen but the tutorial still had the
## screen. The mark is owed, not lost.
var coach_pending := false

var _block: Dictionary = {}
var _reduce_motion := false
## The spawn a deferred mark will point at. Memory only — see `note_spawn`.
var _pending_event: Dictionary = {}

## The running game-hour, and the hour that closed. Two pairs rather than one:
## the ledger's window is "the last SETTLED hour", so a bounty paid four minutes
## ago belongs to the hour still running and must not appear in a column headed
## by the one before it.
var _live: Dictionary = {REVENUE_BOUNTIES: 0.0, REVENUE_STREET: 0.0}
var _settled: Dictionary = {REVENUE_BOUNTIES: 0.0, REVENUE_STREET: 0.0}


func _init(cfg: UIConfig = null) -> void:
	config = cfg
	if cfg == null:
		return
	_block = cfg.section("street")
	_reduce_motion = bool(cfg.section("defaults").get("reduce_motion", false))


static func load_from_files() -> StreetModel:
	return StreetModel.new(UIConfig.load_from_files())


# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

func coach_ttl_s() -> float:
	return UIConfig.get_num(_block, "coach_ttl_s", DEFAULT_COACH_TTL_S)


func chip_flash_s() -> float:
	return UIConfig.get_num(_block, "chip_flash_s", DEFAULT_CHIP_FLASH_S)


func toast_min() -> int:
	return UIConfig.get_int(_block, "toast_min", DEFAULT_TOAST_MIN)


## A8's own switch, read the same way `ui/hud.gd` reads it. Exposed so the shell
## can push a live settings change in without rebuilding the model.
func set_reduce_motion(value: bool) -> void:
	_reduce_motion = value


func reduce_motion() -> bool:
	return _reduce_motion


# ---------------------------------------------------------------------------
# The payday
# ---------------------------------------------------------------------------

## What a collect should be worth to the senses. `result` is
## `BuildController.collect_opportunity()`'s record — `CommandQueue`'s
## `{ok, reason_code, payload}` — and `pick` is the row the pick resolved, which
## is where the amount comes from when the command's payload does not carry one.
##
## The shape is a list of things to DO, never a thing done: `ui/ui_root.gd`
## spends it and `game/main.gd` plays the cue. That is what keeps this testable
## without a scene, a mixer or a sim.
func collect_feedback(result: Dictionary, pick: Dictionary = {}) -> Dictionary:
	var ok := bool(result.get("ok", false))
	var payload: Variant = result.get("payload", {})
	var block: Dictionary = payload if payload is Dictionary else {}
	var amount := int(block.get("reward", block.get("amount", pick.get("reward", 0))))
	var reason := StringName(str(result.get("reason_code", "")))
	if not ok:
		return {
			"ok": false,
			"amount": 0,
			"reason": reason,
			# A build whose sim has no collect verb yet must say nothing at all:
			# there is no story to tell the player about a feature that is not
			# there. Every other refusal is "you were too late", which is a real
			# thing that happened and gets a sentence.
			"toast": "" if reason == BuildController.E_NO_COMMAND else _t("ui_street_gone"),
			"cue": false,
			"flash_chip": "",
			"haptic": StringName("") if reason == BuildController.E_NO_COMMAND
					else Haptics.CUE_BLOCKED,
		}
	_live[REVENUE_STREET] = float(_live[REVENUE_STREET]) + float(amount)
	return {
		"ok": true,
		"amount": amount,
		"amount_text": HudModel.money_signed(amount),
		"reason": reason,
		# The floating `+$` is doc 11's and it is motion. Under A8 there is no
		# float, so the toast is the only thing left that says a number — which
		# makes it required, not redundant.
		"toast": _t_args("ui_street_collected",
				{"amount": HudModel.money_signed(amount)}) if _reduce_motion else "",
		"cue": true,
		"flash_chip": CHIP_TREASURY,
		"haptic": Haptics.CUE_DISPATCH,
	}


## The other half of the same beat: a crew the player never watched leave came
## back with money. `event` is `incident_resolved` verbatim.
##
## Returns `{}` when the resolve paid nothing — a self-resolving tier-1 nuisance
## is not a payday and must not interrupt anything to say so.
func bounty_feedback(event: Dictionary) -> Dictionary:
	var amount := int(event.get("reward", 0))
	if amount <= 0:
		return {}
	_live[REVENUE_BOUNTIES] = float(_live[REVENUE_BOUNTIES]) + float(amount)
	var kind := str(event.get("incident_type", event.get("kind", "")))
	return {
		"ok": true,
		"amount": amount,
		"amount_text": HudModel.money_signed(amount),
		"kind": kind,
		# Below the floor the money still lands, the chip still pulses and the
		# coin still sounds; only the sentence is withheld. A $12 fender-bender
		# clearing itself is not worth a line of the player's attention, and a
		# toast that fires for one teaches the player to ignore the next.
		"toast": _bounty_toast(kind, amount) if amount >= toast_min() else "",
		"cue": true,
		"flash_chip": CHIP_TREASURY,
		# **No haptic, deliberately.** §2.14's cues answer something the player
		# did; this is something that happened while they were doing something
		# else, possibly mid-drag on a road. A buzz in the hand for an event the
		# hand had no part in reads as an error, not as a reward.
		"haptic": StringName(""),
	}


## The player asked for this sentence by name — "Crime stopped — +$120 bounty" —
## so crime gets it verbatim and everything else gets the general form with its
## own name in front. `ui_incident_kind_<type>` is the drawer's own table, so a
## fire and a water main are named here exactly as they are named there.
func _bounty_toast(kind: String, amount: int) -> String:
	var money := HudModel.money_signed(amount)
	if kind == "crime":
		return _t_args("ui_bounty_toast_crime", {"amount": money})
	var key := "ui_incident_kind_%s" % kind
	var name_text := _t(key)
	if name_text == key or kind == "":
		name_text = _t("ui_incident_kind_unknown")
	return _t_args("ui_bounty_toast", {"kind": name_text, "amount": money})


# ---------------------------------------------------------------------------
# Discovery — one mark, once, ever
# ---------------------------------------------------------------------------

## The first opportunity this save has ever seen. Returns the coach request —
## `{text, world_pos, has_pos}` — or `{}` on every later spawn.
##
## `tutorial_active` is the shell's answer, not this class's business: while the
## scripted first fifteen minutes owns the screen, a second mark over the top of
## the first would be two teachers talking at once. The mark is then *owed*
## rather than dropped, and `take_pending()` hands it over the moment the
## tutorial is done — the lesson is worth more late than never.
func note_spawn(event: Dictionary, tutorial_active: bool = false) -> Dictionary:
	if coached:
		return {}
	if tutorial_active:
		coach_pending = true
		# Kept in memory only, and deliberately not saved: a mark owed across a
		# reload would point at a spot on a street where nothing has stood for
		# hours. The flag survives, the coordinates do not, and a positionless
		# mark centres its bubble rather than lying about where to look.
		_pending_event = event.duplicate()
		return {}
	coached = true
	coach_pending = false
	return _coach_request(event)


## The mark the tutorial was holding up. `{}` when none is owed. `event` wins
## over the remembered spawn, so a caller with a fresher opportunity can point
## at that one instead.
func take_pending(event: Dictionary = {}) -> Dictionary:
	if not coach_pending or coached:
		return {}
	coached = true
	coach_pending = false
	var source := event if not event.is_empty() else _pending_event
	_pending_event = {}
	return _coach_request(source)


func _coach_request(event: Dictionary) -> Dictionary:
	var raw: Variant = event.get("world_pos", event.get("pos", null))
	var has_pos := raw is Vector3
	return {
		"text": _t("ui_street_coach_first"),
		"world_pos": raw if has_pos else Vector3.ZERO,
		"has_pos": has_pos,
		"ttl_s": coach_ttl_s(),
	}


# ---------------------------------------------------------------------------
# The ledger (item 3 in the class doc)
# ---------------------------------------------------------------------------

## Doc 03's hour closed: what accrued becomes what is shown, and the running
## tally starts again at zero. Called from the same batch every other reading of
## the bus is taken from, so the two windows can never drift apart.
func close_hour() -> void:
	_settled = _live.duplicate()
	_live = {REVENUE_BOUNTIES: 0.0, REVENUE_STREET: 0.0}


## `{bounties, street}` for the hour the ledger is showing. Handed to
## `BudgetModel.feed_side_revenue()`, which drops any key doc 03 has started
## settling for itself.
func side_revenue() -> Dictionary:
	return _settled.duplicate()


## The hour still running — not a ledger line, but the honest answer to "did
## anything land since the last close", which the tests assert on.
func live_revenue() -> Dictionary:
	return _live.duplicate()


# ---------------------------------------------------------------------------
# Persistence — the `ui.street` block of doc 12 §3.2
# ---------------------------------------------------------------------------

## The one-shot flag and the two tallies. The tallies ride along because a save
## taken mid-hour and restored would otherwise show a ledger line for money the
## restored city no longer remembers earning.
func capture_state() -> Dictionary:
	return {
		"coached": coached,
		"coach_pending": coach_pending,
		"live": _live.duplicate(),
		"settled": _settled.duplicate(),
	}


func restore_state(state: Dictionary) -> void:
	coached = bool(state.get("coached", false))
	coach_pending = bool(state.get("coach_pending", false))
	_live = StreetModel._tally(state.get("live", null))
	_settled = StreetModel._tally(state.get("settled", null))


static func _tally(raw: Variant) -> Dictionary:
	var out := {REVENUE_BOUNTIES: 0.0, REVENUE_STREET: 0.0}
	if raw is Dictionary:
		var block: Dictionary = raw
		out[REVENUE_BOUNTIES] = float(block.get(REVENUE_BOUNTIES, 0.0))
		out[REVENUE_STREET] = float(block.get(REVENUE_STREET, 0.0))
	return out


# ---------------------------------------------------------------------------
# Copy
# ---------------------------------------------------------------------------

func _t(key: String) -> String:
	return UIWidgets.t(config, key)


func _t_args(key: String, args: Dictionary) -> String:
	return UIWidgets.t_args(config, key, args)

class_name VeilModel
extends RefCounted
## S15's headless half — the loading veil of doc 13 §2.9 / §2.9.1 and doc 91
## §20.2 item 19.
##
## **Both slicers existed and neither had a surface.** `CitySim.begin_restore()`
## cuts a restore into eleven resumable steps (`RestoreCursor`) and
## `CatchUpPlanner.plan()` cuts an absence into boundary-aligned segments, and
## doc 13 has written `veil.show()` in its pseudocode since the section was
## drafted. What was missing was the screen the two slicers hand their progress
## to; `game/main.gd` stood the title door in front of the restore instead, which
## covers CONTINUE and covers nothing else — not a resume, not a slot load from
## S8, not the catch-up that follows any of them.
##
## Two phases, one model:
##
##   * **LOADING** — `Opening {city}…`, fed by the restore cursor's step index.
##     Doc 13 §2.9.1 rules the fraction "honest about how many steps have run and
##     dishonest about how much time is left" (`roads_graph` alone is 37 % of the
##     work and one step of eleven) and asks for a spinner. This ships the bar
##     **with its unit named** — `Step 4 of 11` under it — which is the same
##     honesty by a different route, and it costs A8 nothing: a stepped bar has no
##     animation for `reduce_motion` to suppress and a spinner does.
##   * **CATCHUP** — `Your city ran {hours} hours`, fed by the planner's tick
##     count. Here the fraction *is* proportional to time (§2.9's own argument),
##     so the bar means what a bar usually means.
##
## Pure `RefCounted` with no node in it, for the reason every other `ui/` model is:
## the phase machine, the copy and the fraction are then testable without a
## viewport, and `tests/test_veil_model.gd` asks it the questions a screenshot
## cannot — that a zero-step load never divides, that a two-step catch-up is
## beneath the veil's own floor, and that `finish()` is idempotent.

## No veil. Nothing is drawn and `build_view().visible` is false.
const PHASE_NONE := &"none"
## A restore is stepping (`RestoreCursor`).
const PHASE_LOADING := &"loading"
## An offline catch-up is running (`CatchUpPlanner`).
const PHASE_CATCHUP := &"catchup"

## Doc 13 §2.9: `catchup_veil_min_steps = 5` — an absence worth four steps or
## fewer is sub-frame work, and a veil that flashes for one frame is a defect,
## not a courtesy. Overridable from `data/ui.json.veil.min_steps`.
const DEFAULT_MIN_STEPS := 5

var config: UIConfig

var phase: StringName = PHASE_NONE
## What the load is opening, in the player's words. The shell supplies it —
## `ui/` has no slot list and `sim/` has no name.
var city := ""
var steps_done := 0
var steps_total := 0
## Game hours the catch-up is about to run. 0 while loading.
var catchup_hours := 0
## Doc 01's cap bit: the absence was longer than the sim will credit.
var capped := false
## REAL hours the cap allows, for the capped line's `{hours}`. It is doc 01
## C-19's 12 again and it is a parameter rather than a constant on purpose: it
## stopped being one in Wave 17, when doc 08 §2.12's `max_coarse_hours` could
## pull the effective cap down to six and copy that said "12" was a lie with a
## footnote (RR-133). RR-160 deleted that clamp — the plan's own `cap_real_hours`
## is the only source now — but the parameter stays, because a surface that
## quotes a cap must quote the cap that was applied and never a constant of its
## own.
var cap_real_hours := 12

var _min_steps := DEFAULT_MIN_STEPS


func _init(cfg: UIConfig = null) -> void:
	config = cfg
	if config != null:
		_min_steps = maxi(1, UIConfig.get_int(config.section("veil"), "min_steps",
				DEFAULT_MIN_STEPS))


## The floor an offline catch-up has to clear before it is worth a veil at all.
func min_steps() -> int:
	return _min_steps


## Raise the veil over a restore. `total_steps` is `RestoreCursor.step_count()`.
##
## A load ALWAYS raises it, however few steps it has — unlike a catch-up. A
## restore's steps are not uniform (doc 13 §2.9.1: 0.2 ms to 76.5 ms), so "few
## steps" does not mean "fast", and a one-step cursor is the whole-file fallback
## `SaveService.begin_load_slot()` returns for a legacy save — the slowest load
## in the project, not the quickest.
func begin_load(p_city: String, total_steps: int) -> void:
	phase = PHASE_LOADING
	city = p_city
	steps_done = 0
	steps_total = maxi(0, total_steps)
	catchup_hours = 0
	capped = false
	cap_real_hours = 12


## Where the restore cursor has got to. Clamped rather than trusted: a shell that
## reports a step count past the total has a bug, and a bar past its own end is
## not the place to find out.
func advance_load(completed: int) -> void:
	if phase != PHASE_LOADING:
		return
	steps_done = clampi(completed, 0, maxi(steps_total, completed))


## Switch to (or raise) the catch-up phase. `hours` is the game time about to be
## run, `total_steps` the planner's tick count. Answers whether the veil is up
## afterwards: an absence under `min_steps()` is refused and, if a load was
## showing, the veil comes down with it.
func begin_catchup(hours: int, total_steps: int, was_capped: bool = false,
		p_cap_real_hours: int = 12) -> bool:
	if total_steps < _min_steps:
		finish()
		return false
	phase = PHASE_CATCHUP
	catchup_hours = maxi(0, hours)
	capped = was_capped
	cap_real_hours = maxi(1, p_cap_real_hours)
	steps_done = 0
	steps_total = maxi(0, total_steps)
	return true


func advance_catchup(completed: int) -> void:
	if phase != PHASE_CATCHUP:
		return
	steps_done = clampi(completed, 0, maxi(steps_total, completed))


## Down. Idempotent — the shell calls it on the happy path, on a refused load and
## on a corrupt save, and two of those can happen in the same frame.
func finish() -> void:
	phase = PHASE_NONE
	steps_done = 0
	steps_total = 0
	catchup_hours = 0
	capped = false
	cap_real_hours = 12


func is_open() -> bool:
	return phase != PHASE_NONE


## `steps_done / steps_total` on [0, 1]. A cursor with no steps reads 0 rather
## than dividing by one — an empty cursor is what a quarantined save comes back
## as, and a full bar over a load that never happened is a lie.
func progress01() -> float:
	if steps_total <= 0:
		return 0.0
	return clampf(float(steps_done) / float(steps_total), 0.0, 1.0)


## Everything the view draws, and nothing it has to work out. Same contract as
## `HudModel.build_view()`: the screen is a renderer of this dictionary.
func build_view() -> Dictionary:
	return {
		"visible": is_open(),
		"phase": phase,
		"title": _title(),
		"detail": _detail(),
		"progress01": progress01(),
		"steps_done": steps_done,
		"steps_total": steps_total,
	}


func _title() -> String:
	match phase:
		PHASE_LOADING:
			return _t("ui_veil_opening", {"city": city}) if city != "" \
					else _t("ui_veil_opening_unnamed", {})
		PHASE_CATCHUP:
			return _t("ui_veil_catchup", {"hours": catchup_hours})
		_:
			return ""


func _detail() -> String:
	match phase:
		PHASE_LOADING:
			# The unit, named. See the class doc: this is what makes a stepped bar
			# an honest one rather than doc 13's spinner.
			if steps_total <= 0:
				return ""
			return _t("ui_veil_step", {"n": steps_done, "total": steps_total})
		PHASE_CATCHUP:
			return _t("ui_veil_catchup_capped",
					{"hours": cap_real_hours}) if capped else ""
		_:
			return ""


func _t(key: String, args: Dictionary) -> String:
	if config == null or not config.has_string(key):
		return ""
	return config.t(key, args)

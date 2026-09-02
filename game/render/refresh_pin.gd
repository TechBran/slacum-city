class_name RefreshPin
extends RefCounted
## Doc 13 §2.8's missing half: DECLARE the frame rate the game caps itself at
## (report 98 RR-126, doc 11 §2.13's note).
##
## **The fault.** `PerfGovernor.target_fps()` answers 60, 45 or 30 and
## `game/main.gd` writes it into `Engine.max_fps`. Nothing has ever told the
## DISPLAY. On a fixed 60 Hz panel that costs nothing, because there is one mode
## and the panel is already in it. On the reference device — a Galaxy Z Fold 6
## whose inner panel is a 1–120 Hz LTPO — the platform has to infer a mode from
## the cadence it observes, so the panel hunts whenever the cadence changes, and
## an adaptive mode change part-way down a scan is a horizontal band. The player's
## verdict after days on the Aug-21 build is the shape that predicts: *"tearing
## only happens in the sub menus"* — world play is clean, and a sheet opening over
## a still world is exactly a cadence change with no camera motion to hide it.
##
## **What this object is.** The policy half, and nothing else: it decides WHICH
## rate to declare and WHEN, keeps the answer so an unchanged rate is never
## re-declared, and hands the number to `AndroidNative.set_frame_rate()`. The
## platform half — `Surface.setFrameRate`, `preferredRefreshRate`,
## `preferredDisplayModeId` — is `SlacumNative.kt`, per that file's own rule that
## Kotlin knows *how* and GDScript decides *what*.
##
##     pin = RefreshPin.new(render_cfg, AndroidNative.detect())
##     pin.apply_lever(DevArgs.user_args())      # --refresh=auto|60|90|120|off
##     pin.pin(perf_governor.target_fps())       # every time max_fps is written
##
## `pin()` is idempotent by construction: the same number twice casts one vote.
## That matters more than it looks — a vote is a request the compositor acts on,
## and re-casting it every frame is how a fix for mode hunting becomes a cause of
## it.
##
## **The modes.**
##
## * `auto` — declare whatever the cap is. The default, and the shipped behaviour.
## * `60` / `90` / `120` — declare that number whatever the cap says. An A/B lever
##   and a player escape hatch, not a promise that the game will RUN at it: the
##   cap is still the governor's, and declaring 120 on a 60 fps cap only tells the
##   panel to sit in its fastest mode.
## * `off` — never declare anything. **Today's behaviour exactly**, kept so the
##   A/B has a control arm that is the shipped build rather than a rebuild of it.
##
## Headless-safe: `AndroidNative` answers "unavailable" off-device and every
## method here still returns a defined answer, so the whole rule is testable with
## no plugin, no device and no engine singleton.

const MODE_AUTO := "auto"
const MODE_OFF := "off"
## `--refresh=<mode>`, doc 13 D-20's argument path (`DevArgs.user_args()`).
const LEVER_PREFIX := "--refresh="

## Fallbacks used only when `data/render.json` carries no `refresh` block. They
## are what that block ships with, not invented alternatives.
const DEF_MODE := MODE_AUTO
const DEF_LEVER_MODES := ["auto", "60", "90", "120", "off"]
const DEF_SETTINGS_MODES := ["auto", "60", "120", "off"]

## "The rate has never been declared." Distinct from 0, which is a real request
## meaning *clear the vote and hand the panel back to the platform*.
const UNPINNED := -1

var native: AndroidNative = null
var mode := DEF_MODE
## Set when a `--refresh=` argument was supplied. A dev lever outranks the
## settings row for the same reason `main.gd`'s `_apply_render_ab_args()` is
## applied after the boot preset seeding: an A/B arm the player's saved settings
## could silently overturn is not an arm.
var lever_locked := false

var _lever_modes: Array = DEF_LEVER_MODES.duplicate()
var _settings_modes: Array = DEF_SETTINGS_MODES.duplicate()
var _pinned := UNPINNED
var _pins := 0


func _init(render_cfg: Dictionary = {}, bridge: AndroidNative = null) -> void:
	native = bridge
	configure(render_cfg)


func configure(render_cfg: Dictionary) -> void:
	var block: Dictionary = render_cfg.get("refresh", {})
	mode = String(block.get("default_mode", DEF_MODE))
	var lever: Variant = block.get("lever_modes", null)
	_lever_modes = (lever as Array).duplicate() if lever is Array else DEF_LEVER_MODES.duplicate()
	var rows: Variant = block.get("settings_modes", null)
	_settings_modes = (rows as Array).duplicate() if rows is Array \
			else DEF_SETTINGS_MODES.duplicate()
	_pinned = UNPINNED


# ------------------------------------------------------------- the mode rule

## **The rule, and the one place it is written down.** `SlacumNative.modeFor()`
## mirrors it in Kotlin because it has to run against a `Display.Mode` that only
## exists on a device; this is the copy the suite tests, and
## `tests/test_release_plumbing.gd` pins the two together.
##
## Three clauses over the panel's supported rates, in order:
##
## 1. **the SMALLEST rate that is an integer multiple of `fps`** — 60 for a 60 fps
##    cap on {60, 120}; 90 for a 45 fps cap on {60, 90, 120}; 60 for a 30 fps cap
##    on {60, 120}. A multiple is what makes the cadence exact: every app frame is
##    held for the same whole number of scanouts, and a capped game then has no
##    beat against the panel at all. **Smallest** rather than largest because
##    every extra scanout is battery spent on a picture that did not change — doc
##    13 §2.8 calls capping at 60 on a 120 Hz panel "the single biggest battery
##    lever available", and pinning the panel to 120 anyway would hand it back.
## 2. **no multiple: the FASTEST rate at or above `fps`** — 120 for a 45 fps cap
##    on {60, 120}. Neither 60 nor 120 divides 45, so some frames are held one
##    scanout longer than others whichever is chosen; the error is one scanout, so
##    the faster mode halves it (±4.2 ms at 120 Hz against ±8.3 ms at 60).
## 3. **nothing reaches `fps`: the fastest rate there is** — the panel cannot do
##    what the preset asked, and saying so beats asking for a mode that does not
##    exist.
##
## Answers 0 when there is nothing to choose from — an empty list is "no display
## to ask", and the honest response is to declare the rate and leave the window
## alone.
static func choose_refresh_hz(fps: int, supported: PackedInt32Array) -> int:
	if fps <= 0 or supported.is_empty():
		return 0
	var best := 0
	for hz: int in supported:
		if hz < fps or hz % fps != 0:
			continue
		if best == 0 or hz < best:
			best = hz
	if best > 0:
		return best
	for hz: int in supported:
		if hz < fps:
			continue
		if hz > best:
			best = hz
	if best > 0:
		return best
	for hz: int in supported:
		if hz > best:
			best = hz
	return best


## What the panel says it can do, ascending and de-duplicated, or empty off-device.
func supported_hz() -> PackedInt32Array:
	if native == null:
		return PackedInt32Array()
	return native.supported_refresh_rates()


## The mode this pin would put the panel in for a given cap — the number the
## settings row shows the player, and the one a device session can compare
## against `dumpsys display`. 0 means "no mode is requested".
func target_hz(cap_fps: int) -> int:
	var fps := requested_fps(cap_fps)
	if fps <= 0:
		return 0
	return choose_refresh_hz(fps, supported_hz())


# ---------------------------------------------------------------- the modes

func lever_modes() -> Array:
	return _lever_modes.duplicate()


func settings_modes() -> Array:
	return _settings_modes.duplicate()


static func is_numeric_mode(candidate: String) -> bool:
	return candidate.is_valid_int() and candidate.to_int() > 0


## The rate this pin will declare for a given governor cap, or 0 for "declare
## nothing". `auto` follows the cap; a numeric mode overrides it; `off` is 0.
func requested_fps(cap_fps: int) -> int:
	if mode == MODE_OFF:
		return 0
	if is_numeric_mode(mode):
		return mode.to_int()
	return maxi(0, cap_fps)


# ---------------------------------------------------------------- the lever

## `--refresh=auto|60|90|120|off` out of `DevArgs.user_args()`. Last one wins, as
## every other repeated flag in this shell does. An unrecognised value is refused
## and logged rather than guessed at: a lever that silently means something else
## is worse than no lever, because the A/B it drives would report the wrong arm.
## Returns true when an argument was actually honoured.
func apply_lever(args: PackedStringArray) -> bool:
	var found := ""
	for arg: String in args:
		if not arg.begins_with(LEVER_PREFIX):
			continue
		var value := arg.substr(LEVER_PREFIX.length()).strip_edges().to_lower()
		if _lever_modes.has(value):
			found = value
		else:
			push_warning("RefreshPin: --refresh=%s is not one of %s; ignored"
					% [value, str(_lever_modes)])
	if found == "":
		return false
	set_mode(found)
	lever_locked = true
	return true


# ------------------------------------------------------------------ the pin

## The player's settings row, or the lever. Refused while a lever is locked.
## Returns true when the mode actually changed — which is also when the next
## `pin()` is guaranteed to re-declare, because the mode is what decides the
## number.
func set_mode(new_mode: String, from_player: bool = false) -> bool:
	if from_player and lever_locked:
		return false
	if new_mode == mode:
		return false
	mode = new_mode
	_pinned = UNPINNED
	return true


## Declare `cap_fps` to the platform, unless it is already declared. Called
## wherever `game/main.gd` writes `Engine.max_fps`, with the same number.
##
## Returns true when a vote was cast, false when there was nothing to do — the
## rate is unchanged, the mode is `off`, or there is no plugin to tell.
func pin(cap_fps: int) -> bool:
	var fps := requested_fps(cap_fps)
	if mode == MODE_OFF:
		# `off` is "never declare", not "declare 0": clearing a vote is itself a
		# request, and the control arm of the A/B must make no request at all.
		return false
	if fps == _pinned:
		return false
	_pinned = fps
	_pins += 1
	if native == null:
		return false
	return native.set_frame_rate(float(fps), true)


## The rate currently declared, or `UNPINNED`.
func pinned_fps() -> int:
	return _pinned


## How many votes this object has cast. The idempotence test's instrument, and
## the number a device session compares against the sheet-open count.
func pin_count() -> int:
	return _pins


## One line for the PERF log and for `adb logcat`, so a device session can read
## the arm it is actually running rather than the arm it meant to launch.
func state_line(cap_fps: int) -> String:
	return "REFRESH mode=%s cap=%d declared=%d panel=%d pins=%d lever=%d" % [
		mode, cap_fps, requested_fps(cap_fps), target_hz(cap_fps), _pins,
		1 if lever_locked else 0,
	]

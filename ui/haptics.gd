class_name Haptics
extends RefCounted
## Doc 12 §2.14, and the **only** place in the project that may call a vibrator.
##
## Seven cues, three levels, one table — `data/ui.json.haptics_ms`, which carries
## the doc's `light / full` millisecond pairs verbatim. Nothing here authors a
## duration and nothing here decides which cue a screen should fire; a screen
## names an *event* (`blocked`, `escalate`) and this class answers with the
## milliseconds the player's settings allow, which is what keeps a "buzz" from
## quietly becoming a per-screen opinion.
##
## **Why one class rather than seven call sites.** `Input.vibrate_handheld()` is
## unconditional: it has no settings, no accessibility gate and no way to ask
## whether the player wanted it. Every gate the deck needs — the `haptics` row,
## the `reduce_motion` row, the level table — therefore has to live in front of
## it, and a gate that is only in front of *some* of the call sites is not a
## gate. `fire()` is the one door.
##
## **`reduce_motion` silences haptics** (A8, doc 12 §2.18). The checklist's rule
## is that a pulse is motion, and a vibration is the most literal motion the
## device can produce: a player who has asked the interface to stop moving has
## asked this to stop too. It is a *suppression*, not a level change — the
## `haptics` row keeps whatever it said, so switching `reduce_motion` back off
## restores the player's own choice rather than a default.
##
## Pure `RefCounted` with an injectable vibrator, so the whole table is reachable
## from a headless test (`tests/test_ui_haptics.gd`) with no device and no tree.

## Doc 12 §2.14's setting, in the order the settings row cycles them.
const LEVEL_OFF := &"off"
const LEVEL_LIGHT := &"light"
const LEVEL_FULL := &"full"
const LEVELS: Array[StringName] = [LEVEL_OFF, LEVEL_LIGHT, LEVEL_FULL]

## The seven cues §2.14 names, spelled as `data/ui.json.haptics_ms` spells them.
const CUE_BUTTON := &"button"                    ## a confirm tap — placement commit
const CUE_SNAP_TILE := &"snap_tile"              ## the ghost moved to a new tile
const CUE_BLOCKED := &"blocked"                  ## a refusal: BLOCKED verdict, refused command
const CUE_DISPATCH := &"dispatch"                ## a dispatch was accepted
const CUE_ESCALATE := &"escalate"                ## incident escalated, or a new P1
const CUE_POWER_RESTORED := &"power_restored"    ## the lights came back on
const CUE_ROTATION_SNAP := &"rotation_snap"      ## camera rotation snapped

const CUES: Array[StringName] = [
	CUE_BUTTON, CUE_SNAP_TILE, CUE_BLOCKED, CUE_DISPATCH,
	CUE_ESCALATE, CUE_POWER_RESTORED, CUE_ROTATION_SNAP,
]

## The two settings rows that reach this class.
const SETTING_LEVEL := &"haptics"
const SETTING_REDUCE_MOTION := &"reduce_motion"

const SECTION := "haptics_ms"

var config: UIConfig
## The player's `haptics` row. Defaults to `data/ui.json.defaults.haptics`.
var level: StringName = LEVEL_LIGHT
## The player's `reduce_motion` row — see the class note: on means silence.
var reduce_motion := false
## `Callable(ms: int) -> void`. Swappable so a test can record instead of buzz;
## the default is Godot's own, which is a documented no-op off a handheld.
var vibrator: Callable = Callable(Input, "vibrate_handheld")

## What `fire()` last did, for the harnesses and for `tests/test_ui_haptics.gd`.
var last_cue: StringName = &""
var last_ms: int = 0
var fired_count: int = 0


func _init(cfg: UIConfig = null) -> void:
	setup(cfg)


static func load_from_files() -> Haptics:
	return Haptics.new(UIConfig.load_from_files())


## Idempotent, like every other `setup()` in the deck: re-running it with a new
## config re-reads the table and keeps whatever the player has since chosen.
func setup(cfg: UIConfig = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		return
	var defaults := config.section("defaults")
	level = Haptics.normalize_level(defaults.get("haptics", String(LEVEL_LIGHT)))
	reduce_motion = bool(defaults.get("reduce_motion", false))


## An unknown level is `off` rather than a guess: a settings block from a build
## that spelled it differently must not silently become `full` on a phone.
static func normalize_level(value: Variant) -> StringName:
	var name := StringName(str(value).strip_edges().to_lower())
	return name if LEVELS.has(name) else LEVEL_OFF


## Routes one settings row here. Returns true when the row was one of ours, so
## `UIRoot` can hand it every change without a second table of key names.
func apply_setting(key: StringName, value: Variant) -> bool:
	match key:
		SETTING_LEVEL:
			level = Haptics.normalize_level(value)
			return true
		SETTING_REDUCE_MOTION:
			reduce_motion = bool(value)
			return true
	return false


## Milliseconds this cue is worth right now. Pure — no device, no side effect —
## so every row of §2.14's table is assertable.
##
## Zero is a legitimate answer at `light` for four of the seven cues: the doc's
## light column is `0` for button, tile snap and rotation snap on purpose, so the
## default level buzzes only for the four events that carry information.
func duration_ms(cue: StringName) -> int:
	if level == LEVEL_OFF or reduce_motion or config == null:
		return 0
	var table: Variant = config.section(SECTION).get(String(level), {})
	if not (table is Dictionary):
		return 0
	return maxi(0, UIConfig.get_int(table, String(cue), 0))


## Fire a cue. Returns the milliseconds actually sent to the device (`0` = the
## settings silenced it), which is what the tests and the audio pass assert on.
##
## §2.14 asks for a 20‑60‑20 *pattern* on `escalate`; `Input.vibrate_handheld`
## takes one duration and no pattern, so this sends the single pulse the table
## carries. A pattern would need a timer, and a timer belongs to a Node.
func fire(cue: StringName) -> int:
	var ms := duration_ms(cue)
	last_cue = cue
	last_ms = ms
	if ms <= 0:
		return 0
	fired_count += 1
	if vibrator.is_valid():
		vibrator.call(ms)
	return ms

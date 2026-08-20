class_name DevArgs
extends RefCounted
## The one list of dev/QA arguments, merged across the two places Android can
## put them (doc 13 D-20).
##
## **The fault this closes.** `OS.get_cmdline_user_args()` is the only argument
## source every tool in this repo reads, and on the shipped Android export
## template it answers `[]` no matter what the launch carried. Two device
## sessions proved it: `--zoom=0.0` and `--zoom=0.5` produced byte-identical
## draw-call sequences, and `--rain=1.0,--overlay=2` came up in clear weather
## with no overlay. The city still loaded on every launch, which is what
## disguised the fault — through `CrashSentinel`'s recovery branch, because
## `am force-stop` registers as an unclean exit, not through `--resume`. With no
## argument reaching the game, doc 13's whole D-17/D-18 pose matrix, the hour
## control and `--save-now` were undrivable on the only device that matters.
##
## **The fix.** `SlacumNative.launch_args()` reads the launching Intent's extras
## in Kotlin, where they demonstrably survive, and this class merges that answer
## with the engine's own list. Consumers read `DevArgs.user_args()` and stop
## caring which of the two delivered.
##
## **Merge rule.** The engine's list wins its own entries and the plugin's list
## is appended, skipping any argument the engine already reported. That
## de-duplication is load-bearing, not tidiness: if a future engine build starts
## forwarding the extra, both sources carry the same strings, and
## `--advance-hours=4` counted twice would silently advance the city eight hours
## before the first frame. Two DIFFERENT values of the same flag are both kept —
## a repeated flag is last-wins in every consumer's loop, exactly as it is on a
## desktop command line.
##
## **Separator rule.** `OS.get_cmdline_user_args()` returns only what follows a
## literal `--`, so the documented `adb` form carries the separator inside the
## extra (`--esa command_line_params "--,--resume,--zoom=1.0"`). This class
## applies the same convention to the plugin's list: everything after the first
## bare `--`, or the whole list when there is none — because forgetting the
## separator is the single most common way a session loses its arguments, and a
## list of things that all begin with `--` has no other plausible reading.
##
## Pure `RefCounted` in `game/`: it touches `OS` and the Android bridge, so it
## cannot live in `sim/`, and it holds no policy about what an argument MEANS.

## Godot's own "user arguments start here" marker.
const SEPARATOR := "--"

## Answered once per process. `OS.get_cmdline_user_args()` is cheap; the plugin
## call is a JNI hop, and `game/main.gd` asks three times during bring-up.
static var _cached: PackedStringArray = PackedStringArray()
static var _has_cache := false


## The merged list every dev-arg consumer should read instead of
## `OS.get_cmdline_user_args()`. Identical to it on desktop, in the headless test
## runner, and on any build without the plugin.
static func user_args(native: AndroidNative = null) -> PackedStringArray:
	if _has_cache and native == null:
		return _cached
	var merged := merge(OS.get_cmdline_user_args(),
			(native if native != null else AndroidNative.detect()).launch_args())
	if native == null:
		_cached = merged
		_has_cache = true
	return merged


## The pure half, so the merge rule is testable without a device, a plugin or an
## `OS`: `engine` verbatim, then everything in `native` that is not already in it.
static func merge(engine: PackedStringArray,
		native: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray(engine)
	for arg in after_separator(native):
		if not out.has(arg):
			out.append(arg)
	return out


## Everything after the first bare `--`, or the whole list when it carries none.
static func after_separator(args: PackedStringArray) -> PackedStringArray:
	var at := -1
	for i in args.size():
		if args[i] == SEPARATOR:
			at = i
			break
	if at < 0:
		return args
	return args.slice(at + 1)


## Drops the memoised answer. Only a test needs this — a process's launch
## arguments do not change under it.
static func reset_cache() -> void:
	_cached = PackedStringArray()
	_has_cache = false

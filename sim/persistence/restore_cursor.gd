class_name RestoreCursor
extends RefCounted
## A restore, cut into resumable steps (doc 08 §2.14, doc 13 §2.9).
##
## `CitySim.restore_state()` rebuilds a 1,500-building city in one call and that
## call is **202 ms on a workstation** after the roster fix below it — three to
## five times that on a Fold, and doc 13 §2.9's ANR arithmetic budgets the
## offline catch-up that FOLLOWS it without counting it at all. A restore cannot
## be moved off the main thread (it writes the live sim), it cannot be made to
## disappear, and the player is looking at a loading veil while it happens. So
## the only honest lever left is to let the veil KEEP DRAWING: hand the shell a
## cursor and let it spend one step per frame.
##
## This is deliberately not a coroutine, not a thread and not a timer. It is a
## list of Callables and an index, because:
##
##   * the shell decides the budget — one step per frame under a veil, or the
##     whole thing in a `while` loop when there is no frame to protect;
##   * `sim/` may not read a clock (constitution §5), so a cursor cannot decide
##     for itself that it has spent long enough;
##   * a step boundary is a place the sim is INCONSISTENT — half-restored — and
##     naming the seams in one list is what makes that reviewable. Nothing may
##     tick, render or query the sim between [step] calls; the veil is what
##     guarantees it.
##
## The end state is bit-identical to the single call: same steps, same order,
## same code. `tests/test_save_chunked_restore.gd` proves it on both cities and
## on a mid-flood, mid-incident body.

var _labels: PackedStringArray = []
var _steps: Array[Callable] = []
var _index: int = 0


## Append a step. `label` is a stable KEY, not a sentence — `sim/` does not
## write player-facing text (doc 12 §3.1). A veil that wants to name the step
## maps it to a `data/strings.en.json` key of its own; nothing does yet, because
## the veil is not built (doc 91 §20.2 item 19), and a string with no surface is
## a string `tests/test_ui_strings.gd` correctly refuses.
func add(label: String, step: Callable) -> void:
	_labels.append(label)
	_steps.append(step)


func step_count() -> int:
	return _steps.size()


## How many steps have run. `completed() / step_count()` is the progress bar.
func completed() -> int:
	return _index


func is_done() -> bool:
	return _index >= _steps.size()


## The label of the step [step] would run next, or "" when there is none.
func next_label() -> String:
	return "" if is_done() else _labels[_index]


## Run exactly ONE step. Returns [is_done] afterwards, so a caller can write
## `if cursor.step(): _finish()` and never ask twice. Calling it on a finished
## cursor is a no-op, not an error: a veil that runs one frame long must not
## crash the load it was hiding.
func step() -> bool:
	if is_done():
		return true
	var work := _steps[_index]
	_index += 1
	work.call()
	return is_done()


## Drain every remaining step now. This is what `restore_state()` is.
func run() -> void:
	while not is_done():
		step()

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
##
## **The step COUNT is a property of the city being restored, not of the code**
## (Wave 13): a step may [splice_next] more steps, and the road graph's rebuild
## emits one trace step per batch of nodes. Read [step_count] for a progress bar;
## never assume a number.

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


## Insert steps to run **next** — immediately after the step that is calling
## this, and before everything that was already queued behind it.
##
## This exists because a restore's step list is not fully known when the cursor
## is built. `CitySim.begin_restore()` cannot ask `RoadNetwork` for the road
## loader's seams until the body has been decoded, which is itself a step; so the
## `roads` step asks, runs the first seam, and splices the rest in here.
##
## **It must be an insert and not an append**, and that is the whole reason this
## method has a body worth reading. `SaveService.begin_load_slot()` adds a
## `settle` step of its own AFTER `begin_restore()` has handed the cursor back —
## the step that publishes the loaded UI state and fires the `loaded` signal — and
## an append would have put ten road-graph steps *behind* it. The city would have
## been announced as loaded with no road graph in it.
func splice_next(labels: PackedStringArray, steps: Array[Callable]) -> void:
	if labels.size() != steps.size():
		return
	for i in range(steps.size() - 1, -1, -1):
		_labels.insert(_index, labels[i])
		_steps.insert(_index, steps[i])


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

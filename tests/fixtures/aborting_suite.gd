extends SimTest
## **A deliberately broken suite.** It is the fixture `tests/test_runner_guard.gd`
## drives to prove that `tests/run_tests.gd` cannot print ALL TESTS PASSED over a
## test method that never ran.
##
## It lives under `tests/fixtures/` and is not named `test_*.gd`, so the runner's
## own discovery walk never picks it up — the guard test instantiates it by path
## and drives it with the same three calls the runner makes
## (`begin_test` → `call` → `end_test`).
##
## The three methods are the three shapes a method can have:
##   * one that asserts (the control — it must NOT be reported);
##   * one that ABORTS on a GDScript runtime error, which is the shape that
##     produced the false green on 2026-08-20: an aborted method unwinds one
##     function, contributes no assert and no failure, and used to be
##     indistinguishable from a pass;
##   * one that returns early without asserting, which is the same signal from a
##     different cause and is worth catching for the same reason.


func test_asserts_normally() -> void:
	assert_true(true, "the control: this one really does assert")


## The measured failure mode, reproduced. `test_save_service.gd` aborted here on
## a manifest key a concurrent sibling run had swept out from under it.
##
## The engine prints one `SCRIPT ERROR: Invalid access to key…` when this runs.
## **That line is deliberate** — it is the evidence, not a symptom — and the
## guard test announces it before calling this method so a reader of the log
## never has to wonder.
func test_aborts_on_a_missing_key() -> void:
	var manifest: Dictionary = {"present": 1}
	var slot: int = manifest["absent"]  # unwinds HERE; nothing below runs
	assert_eq(slot, 0, "unreachable — the line above ends this method")


func test_returns_before_asserting() -> void:
	if _bail():
		return
	assert_true(false, "unreachable — _bail() always returns true")


## Behind a call so the analyser cannot fold the branch and warn about the
## assertion below it. The point is the missing assert, not the dead code.
func _bail() -> bool:
	return true

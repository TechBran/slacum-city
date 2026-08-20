class_name SimTest
extends RefCounted
## Base class for headless sim tests. Subclasses define methods named test_*.
## Assertion failures are collected (not fatal) so one bad assert doesn't hide the rest.
##
## **A method that makes no assertion is a FAILURE, not a pass.** A GDScript
## runtime error — an index out of range, a missing dictionary key — does not
## throw: it prints, unwinds the one function it happened in, and hands control
## straight back to the caller. Before Wave 12 the runner's only evidence was
## `failures()`, so an aborted method contributed nothing to either column and
## the suite still printed ALL TESTS PASSED with a test that never ran. That is
## not hypothetical — `tests/test_save_service.gd` did exactly this under a
## concurrent sibling run on 2026-08-20 (see `tests/run_tests.gd`'s header).
##
## `begin_test` / `end_test` bracket each method and record the ones that
## finished with the assert counter exactly where they found it. The runner
## turns that list into failures. `tests/test_runner_guard.gd` drives a fixture
## that aborts on purpose and asserts the guard catches it.

var _failures: Array[String] = []
var _assert_count: int = 0
var _current: String = ""
var _current_asserts_at_start: int = 0
var _silent: Array[String] = []


func begin_test(method_name: String) -> void:
	_current = method_name
	_current_asserts_at_start = _assert_count


## Closes the method `begin_test` opened. Optional for a caller that only wants
## failures; REQUIRED for one that wants the silent-method guard, because this
## is where a method that asserted nothing gets recorded.
func end_test() -> void:
	if _current == "":
		return
	if _assert_count == _current_asserts_at_start:
		_silent.append(_current)
	_current = ""


func failures() -> Array[String]:
	return _failures


## Methods that ran without making a single assertion — aborted on a runtime
## error, or returned before asserting. Empty on a healthy suite.
func silent() -> Array[String]:
	return _silent


func assert_count() -> int:
	return _assert_count


func _fail(message: String) -> void:
	_failures.append("%s: %s" % [_current, message])


func assert_true(condition: bool, message: String = "") -> void:
	_assert_count += 1
	if not condition:
		_fail("expected true. %s" % message)


func assert_false(condition: bool, message: String = "") -> void:
	_assert_count += 1
	if condition:
		_fail("expected false. %s" % message)


func assert_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	_assert_count += 1
	if actual != expected:
		_fail("expected %s, got %s. %s" % [str(expected), str(actual), message])


func assert_ne(actual: Variant, unexpected: Variant, message: String = "") -> void:
	_assert_count += 1
	if actual == unexpected:
		_fail("expected value different from %s. %s" % [str(unexpected), message])


func assert_almost_eq(actual: float, expected: float, tolerance: float = 0.0001, message: String = "") -> void:
	_assert_count += 1
	if absf(actual - expected) > tolerance:
		_fail("expected %f ± %f, got %f. %s" % [expected, tolerance, actual, message])

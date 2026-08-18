class_name SimTest
extends RefCounted
## Base class for headless sim tests. Subclasses define methods named test_*.
## Assertion failures are collected (not fatal) so one bad assert doesn't hide the rest.

var _failures: Array[String] = []
var _assert_count: int = 0
var _current: String = ""


func begin_test(method_name: String) -> void:
	_current = method_name


func failures() -> Array[String]:
	return _failures


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

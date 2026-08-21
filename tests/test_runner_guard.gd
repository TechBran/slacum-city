extends SimTest
## The runner's own guard, under test — doc 91's suite-hygiene debt, filed twice
## by two agents in two waves.
##
## The fault: `tests/run_tests.gd` decided a run was green from `failures()`
## alone. A GDScript runtime error does not throw — it prints, unwinds the one
## function it happened in, and returns to the caller — so a method that ABORTED
## contributed no assert and no failure and looked exactly like a method that
## passed. On 2026-08-20 an agent watched a green run in which
## `test_save_service.gd::test_a_pinned_checkpoint_is_never_swept` never ran at
## all, killed mid-method by a manifest key a concurrent sibling suite had swept.
##
## The fix is `SimTest.begin_test` / `end_test`: the assert counter is read on
## both sides of every method, and one that did not move it is recorded by name
## in `silent()`. `run_tests.gd` fails the run on a non-empty `silent()`.
##
## This test drives `tests/fixtures/aborting_suite.gd` — a fixture whose methods
## abort and return on purpose — with the SAME three calls the runner makes, and
## asserts the guard sees all three shapes correctly. It is deliberately a test
## OF THE HARNESS: if it ever goes quiet the suite loses the only thing that can
## tell "passed" from "never ran".

const FIXTURE := "res://tests/fixtures/aborting_suite.gd"


## `run_tests.gd`'s inner loop, verbatim, so this test cannot drift from it.
func _drive(suite: SimTest) -> void:
	var names: Array[String] = []
	for m in suite.get_method_list():
		if m.name.begins_with("test_"):
			names.append(m.name)
	names.sort()
	for method_name in names:
		suite.begin_test(method_name)
		suite.call(method_name)
		suite.end_test()


func test_the_guard_names_every_method_that_ran_without_asserting() -> void:
	var script: GDScript = load(FIXTURE)
	assert_true(script != null and script.can_instantiate(),
			"the fixture must load: " + FIXTURE)
	if script == null:
		return
	var fixture: SimTest = script.new()
	print("[runner-guard] the SCRIPT ERROR below is DELIBERATE — "
			+ "tests/fixtures/aborting_suite.gd aborts on purpose.")
	_drive(fixture)

	var silent := fixture.silent()
	assert_true(silent.has("test_aborts_on_a_missing_key"),
			"an ABORTED method must be reported; silent() = %s" % str(silent))
	assert_true(silent.has("test_returns_before_asserting"),
			"a method that returns before asserting must be reported; silent() = %s"
			% str(silent))
	assert_false(silent.has("test_asserts_normally"),
			"a method that DID assert must not be reported; silent() = %s" % str(silent))
	assert_eq(silent.size(), 2, "exactly the two silent methods, no more")

	# The other half of the old fault: the aborted method also produced no
	# failure. That is still true — which is precisely why `silent()` has to
	# exist, and why asserting it here is the point rather than a detail.
	assert_eq(fixture.failures().size(), 0,
			"an aborted method still contributes NO failure — silent() is the "
			+ "only evidence there is")
	assert_eq(fixture.assert_count(), 1,
			"only the control method asserted")


func test_a_healthy_suite_reports_nothing_silent() -> void:
	var suite := SimTest.new()
	suite.begin_test("synthetic::asserts")
	suite.assert_true(true, "")
	suite.end_test()
	assert_eq(suite.silent().size(), 0, "an asserting method is never silent")


## `end_test` has to be safe to call without a matching `begin_test`, because a
## caller that only wants failures (`tools/run_one.gd`) does not bracket at all.
func test_end_test_without_begin_test_is_a_no_op() -> void:
	var suite := SimTest.new()
	suite.end_test()
	suite.end_test()
	assert_eq(suite.silent().size(), 0, "no method was open, so none is silent")

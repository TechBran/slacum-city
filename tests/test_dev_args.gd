extends SimTest
## D-20's merge rule (doc 13): the dev-argument list a consumer reads is the
## engine's `OS.get_cmdline_user_args()` plus whatever the launching Intent
## carried, de-duplicated, with Godot's `--` convention applied to the Intent's
## half.
##
## The Kotlin side cannot run here — it reads an Android `Intent` — so the tests
## drive `DevArgs.merge()` and `DevArgs.after_separator()`, which are pure by
## design for exactly this reason, and substitute an `AndroidNative` for the one
## call that is not.


## A plugin that is present and answers with a scripted launch line.
class FakeNative extends AndroidNative:
	var args := PackedStringArray()

	func is_available() -> bool:
		return true

	func launch_args() -> PackedStringArray:
		return args


func _native(args: Array) -> FakeNative:
	var fake := FakeNative.new()
	fake.args = PackedStringArray(args)
	return fake


# ------------------------------------------------------------ the separator

func test_the_intent_list_honours_the_engines_double_dash_convention() -> void:
	# The documented adb form carries the separator INSIDE the extra, because
	# `OS.get_cmdline_user_args()` returns only what follows a literal `--`.
	assert_eq(Array(DevArgs.after_separator(
			PackedStringArray(["--", "--resume", "--zoom=1.0"]))),
			["--resume", "--zoom=1.0"])


func test_a_launch_line_without_a_separator_is_taken_whole() -> void:
	# Forgetting the `--` is the single most common way a device session loses
	# its arguments, and a list whose every entry begins with `--` has no other
	# plausible reading.
	assert_eq(Array(DevArgs.after_separator(
			PackedStringArray(["--resume", "--zoom=1.0"]))),
			["--resume", "--zoom=1.0"])


func test_only_the_first_separator_is_the_separator() -> void:
	assert_eq(Array(DevArgs.after_separator(
			PackedStringArray(["--", "--place=house", "--", "--resume"]))),
			["--place=house", "--", "--resume"])


func test_an_empty_launch_line_merges_to_the_engines_own_list() -> void:
	assert_eq(Array(DevArgs.merge(PackedStringArray(["--resume"]),
			PackedStringArray())), ["--resume"])


# ----------------------------------------------------------------- the merge

func test_the_intent_list_is_appended_to_the_engines() -> void:
	assert_eq(Array(DevArgs.merge(PackedStringArray(["--verbose-ish"]),
			PackedStringArray(["--", "--resume", "--zoom=0.5"]))),
			["--verbose-ish", "--resume", "--zoom=0.5"])


func test_an_argument_both_sources_report_is_counted_once() -> void:
	# The load-bearing half of the rule. If a future engine build starts
	# forwarding `command_line_params` after all, both halves carry the same
	# strings — and `--advance-hours=4` applied twice would silently run the city
	# eight hours forward before the first frame.
	assert_eq(Array(DevArgs.merge(
			PackedStringArray(["--resume", "--advance-hours=4"]),
			PackedStringArray(["--", "--resume", "--advance-hours=4"]))),
			["--resume", "--advance-hours=4"])


func test_two_different_values_of_one_flag_both_survive() -> void:
	# A repeated flag is last-wins in every consumer's loop, exactly as it is on
	# a desktop command line — de-duplication may not turn that into first-wins.
	assert_eq(Array(DevArgs.merge(PackedStringArray(["--zoom=0.0"]),
			PackedStringArray(["--", "--zoom=0.5"]))),
			["--zoom=0.0", "--zoom=0.5"])


# ------------------------------------------------------------- the live path

func test_a_build_without_the_plugin_answers_exactly_the_engines_list() -> void:
	# Desktop, the headless runner, and any APK exported without the Gradle
	# template. `AndroidNative` with no singleton attached is the real object on
	# all three, so this is the path the whole test suite runs on.
	var bare := AndroidNative.new()
	assert_false(bare.is_available())
	assert_eq(bare.launch_args().size(), 0)
	assert_eq(Array(DevArgs.user_args(bare)),
			Array(OS.get_cmdline_user_args()))


func test_the_plugins_answer_reaches_a_consumer() -> void:
	var merged := DevArgs.user_args(_native(["--", "--resume", "--overlay=2"]))
	assert_true(merged.has("--resume"),
			"the intent's --resume reaches the consumer's list")
	assert_true(merged.has("--overlay=2"))
	assert_false(merged.has("--"), "the separator is not itself an argument")


func test_asking_with_an_explicit_bridge_never_poisons_the_process_cache() -> void:
	# `user_args()` memoises the process's own answer; a test (or a diagnostics
	# screen) passing its own bridge must not overwrite it.
	DevArgs.reset_cache()
	var real := Array(DevArgs.user_args())
	assert_eq(Array(DevArgs.user_args(_native(["--", "--resume"]))).size(),
			real.size() + 1)
	assert_eq(Array(DevArgs.user_args()), real)

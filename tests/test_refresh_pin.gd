extends SimTest
## Doc 13 §2.8's refresh pin (report 98 RR-126), `game/render/refresh_pin.gd`.
##
## The whole rule is headless: which rate to declare, which panel mode that rate
## should land in, when a vote is re-cast and when it is not. Only the two
## platform calls behind it need a device, and they are `AndroidNative` methods,
## so a subclass stands in for the plugin exactly as `tests/test_dev_args.gd`
## does — no JNI, no `Display`, no window.
##
## The mode table below is the specification. `SlacumNative.modeFor()` mirrors it
## in Kotlin because it has to run against a `Display.Mode`;
## `tests/test_release_plumbing.gd` is what keeps the two from drifting.


## A plugin that is present, records every vote, and answers with a scripted
## panel. `set_frame_rate` returns true the way the real one does when the
## surface vote lands.
class FakeNative extends AndroidNative:
	var panel := PackedInt32Array()
	var votes: Array[float] = []
	var fixed_flags: Array[bool] = []
	var answer := true

	func is_available() -> bool:
		return true

	func set_frame_rate(fps: float, fixed: bool = true) -> bool:
		votes.append(fps)
		fixed_flags.append(fixed)
		return answer

	func supported_refresh_rates() -> PackedInt32Array:
		return panel


func _fake(panel: Array = [60, 120]) -> FakeNative:
	var native := FakeNative.new()
	native.panel = PackedInt32Array(panel)
	return native


func _cfg() -> Dictionary:
	return RenderStateModel.load_config("res://data/render.json")


func _pin(panel: Array = [60, 120]) -> RefreshPin:
	return RefreshPin.new(_cfg(), _fake(panel))


# ===========================================================================
# The mode chooser — the table
# ===========================================================================

func test_the_mode_table_is_what_the_brief_asked_for() -> void:
	# Rows are `[cap fps, panel, chosen mode]`. The first three are the reference
	# device's own panel; the rest are the ladders the rule has to survive.
	var fold := [60, 120]
	for row: Array in [
			# clause 1 — the smallest INTEGER MULTIPLE at or above the cap
			[60, fold, 60],
			[30, fold, 60],
			[120, fold, 120],
			[45, [60, 90, 120], 90],
			[30, [24, 30, 60, 120], 30],
			[60, [60], 60],
			# clause 2 — no multiple exists: the FASTEST mode at or above the cap
			[45, fold, 120],
			[90, fold, 120],
			[45, [60], 60],
			# clause 3 — nothing reaches the cap: the fastest mode there is
			[60, [24, 30, 48], 48],
			[120, [60], 60],
	]:
		var fps: int = row[0]
		var panel := PackedInt32Array(row[1] as Array)
		assert_eq(RefreshPin.choose_refresh_hz(fps, panel), int(row[2]),
				"a %d fps cap on a %s panel lands on %d Hz"
						% [fps, str(row[1]), int(row[2])])


func test_the_smallest_multiple_wins_because_the_extra_scanouts_are_battery() -> void:
	# The discriminating case: 120 is also a legal multiple of 60, and picking it
	# would hand back doc 13 §2.8's "single biggest battery lever available".
	assert_eq(RefreshPin.choose_refresh_hz(60, PackedInt32Array([60, 120])), 60)
	assert_eq(RefreshPin.choose_refresh_hz(60, PackedInt32Array([120, 60])), 60,
			"the answer does not depend on the order the panel reports its modes")


func test_no_panel_means_no_mode_is_requested() -> void:
	assert_eq(RefreshPin.choose_refresh_hz(60, PackedInt32Array()), 0,
			"an empty list is 'no display to ask', not 'one mode'")
	assert_eq(RefreshPin.choose_refresh_hz(0, PackedInt32Array([60, 120])), 0)
	assert_eq(RefreshPin.choose_refresh_hz(-1, PackedInt32Array([60, 120])), 0)


# ===========================================================================
# The modes
# ===========================================================================

func test_auto_declares_whatever_the_governor_capped_at() -> void:
	var pin := _pin()
	assert_eq(pin.mode, RefreshPin.MODE_AUTO, "data/render.json ships auto")
	assert_eq(pin.requested_fps(60), 60)
	assert_eq(pin.requested_fps(45), 45, "the thermal MODERATE cap")
	assert_eq(pin.requested_fps(30), 30, "the thermal SEVERE cap")
	assert_eq(pin.target_hz(45), 120,
			"45 has no multiple on a 60/120 panel, so the faster mode wins")


func test_a_numeric_mode_outranks_the_cap_and_off_declares_nothing() -> void:
	var pin := _pin()
	pin.set_mode("120")
	assert_eq(pin.requested_fps(30), 120,
			"the row pins the PANEL; the governor still owns the frame cap")
	pin.set_mode(RefreshPin.MODE_OFF)
	assert_eq(pin.requested_fps(60), 0)


func test_off_casts_no_vote_at_all_rather_than_a_vote_of_zero() -> void:
	# The A/B's control arm has to be the shipped build, not a rebuild of it:
	# clearing a vote is itself a request to the compositor.
	var native := _fake()
	var pin := RefreshPin.new(_cfg(), native)
	pin.set_mode(RefreshPin.MODE_OFF)
	assert_false(pin.pin(60))
	assert_false(pin.pin(30))
	assert_eq(native.votes.size(), 0, "off never reaches the platform")
	assert_eq(pin.pin_count(), 0)


# ===========================================================================
# Idempotence
# ===========================================================================

func test_the_same_rate_twice_casts_one_vote() -> void:
	var native := _fake()
	var pin := RefreshPin.new(_cfg(), native)
	assert_true(pin.pin(60), "the first declaration reaches the plugin")
	assert_false(pin.pin(60))
	assert_false(pin.pin(60))
	assert_eq(native.votes.size(), 1)
	assert_eq(pin.pinned_fps(), 60)
	# …and a real change still gets through. The governor's thermal ladder is
	# 60 → 45 → 30, so this is the sequence a warming phone actually produces.
	assert_true(pin.pin(45))
	assert_true(pin.pin(30))
	assert_false(pin.pin(30))
	assert_eq(Array(native.votes), [60.0, 45.0, 30.0])
	assert_eq(pin.pin_count(), 3)


func test_every_vote_is_cast_as_a_fixed_source() -> void:
	var native := _fake()
	var pin := RefreshPin.new(_cfg(), native)
	pin.pin(60)
	assert_eq(Array(native.fixed_flags), [true],
			"FIXED_SOURCE is the honest compatibility for content that has "
			+ "already capped itself")


func test_changing_the_mode_re_declares_even_at_the_same_cap() -> void:
	var native := _fake()
	var pin := RefreshPin.new(_cfg(), native)
	pin.pin(60)
	assert_true(pin.set_mode("120"))
	assert_true(pin.pin(60), "the mode decides the number, so it invalidates it")
	assert_eq(Array(native.votes), [60.0, 120.0])
	assert_false(pin.set_mode("120"), "setting the mode it already has is not a change")


func test_a_pin_with_no_plugin_still_answers_and_still_remembers() -> void:
	var pin := RefreshPin.new(_cfg(), null)
	assert_false(pin.pin(60), "there is nothing to tell")
	assert_eq(pin.pinned_fps(), 60, "…but the shell's belief is still recorded")
	assert_eq(pin.pin_count(), 1)
	assert_eq(pin.target_hz(60), 0, "and no panel was reported")


# ===========================================================================
# The lever
# ===========================================================================

func test_the_lever_parses_every_mode_data_declares() -> void:
	for mode: String in ["auto", "60", "90", "120", "off"]:
		var pin := _pin()
		assert_true(pin.apply_lever(PackedStringArray(["--refresh=%s" % mode])))
		assert_eq(pin.mode, mode)
		assert_true(pin.lever_locked)


func test_an_unknown_lever_value_is_refused_not_guessed() -> void:
	var pin := _pin()
	assert_false(pin.apply_lever(PackedStringArray(["--refresh=fastest"])))
	assert_eq(pin.mode, RefreshPin.MODE_AUTO)
	assert_false(pin.lever_locked)
	assert_false(pin.apply_lever(PackedStringArray(["--refresh="])))
	assert_false(pin.apply_lever(PackedStringArray(["--zoom=1.0", "--perf"])),
			"an argument list with no --refresh leaves the default alone")


func test_a_repeated_lever_is_last_wins_like_every_other_flag() -> void:
	var pin := _pin()
	assert_true(pin.apply_lever(PackedStringArray(["--refresh=off", "--refresh=120"])))
	assert_eq(pin.mode, "120")


func test_the_lever_survives_the_dev_args_merge_it_arrives_through() -> void:
	# On device the argument comes off the Intent, so it reaches the pin through
	# `DevArgs.merge()` with the separator convention applied.
	var merged := DevArgs.merge(PackedStringArray(),
			PackedStringArray(["--", "--refresh=off", "--perf"]))
	var pin := _pin()
	assert_true(pin.apply_lever(merged))
	assert_eq(pin.mode, RefreshPin.MODE_OFF)


func test_the_lever_outranks_the_settings_row() -> void:
	# An A/B arm the player's saved settings could silently overturn is not an
	# arm — the same rule `main.gd` applies to `_apply_render_ab_args()`.
	var pin := _pin()
	pin.apply_lever(PackedStringArray(["--refresh=off"]))
	assert_false(pin.set_mode("120", true), "the player's row is refused")
	assert_eq(pin.mode, RefreshPin.MODE_OFF)
	# …and the shell itself is not locked out, only the player's row.
	assert_true(pin.set_mode("60"))


# ===========================================================================
# The data
# ===========================================================================

func test_the_ladders_come_from_doc_11s_file_and_the_row_is_the_shorter_one() -> void:
	var pin := _pin()
	assert_eq(pin.lever_modes(), ["auto", "60", "90", "120", "off"])
	assert_eq(pin.settings_modes(), ["auto", "60", "120", "off"])
	assert_true(pin.lever_modes().has("90"))
	assert_false(pin.settings_modes().has("90"),
			"90 is a dev arm: the reference panel has no 90 Hz mode to land on")
	for mode: Variant in pin.settings_modes():
		assert_true(pin.lever_modes().has(mode),
				"every player mode is also drivable from the command line")


func test_a_missing_refresh_block_falls_back_to_the_shipped_ladder() -> void:
	var pin := RefreshPin.new({}, null)
	assert_eq(pin.mode, RefreshPin.MODE_AUTO)
	assert_eq(pin.lever_modes(), RefreshPin.DEF_LEVER_MODES)
	assert_eq(pin.settings_modes(), RefreshPin.DEF_SETTINGS_MODES)


func test_the_state_line_names_the_arm_a_device_session_is_running() -> void:
	var pin := _pin()
	pin.apply_lever(PackedStringArray(["--refresh=off"]))
	assert_eq(pin.state_line(60), "REFRESH mode=off cap=60 declared=0 panel=0 pins=0 lever=1")
	var auto := _pin()
	auto.pin(60)
	assert_eq(auto.state_line(60),
			"REFRESH mode=auto cap=60 declared=60 panel=60 pins=1 lever=0")

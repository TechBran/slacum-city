extends SimTest
## S15's headless half (`ui/veil_model.gd`), doc 13 §2.9 / §2.9.1 and doc 91
## §20.2 item 19.
##
## The veil exists to be up while the sim is INCONSISTENT — between two steps of
## a `RestoreCursor`, and between two segments of a `CatchUpPlanner` plan — so
## the questions worth asking it are the arithmetic ones a screenshot cannot
## answer: that a cursor with no steps never divides by zero, that doc 13's
## `catchup_veil_min_steps` floor is honoured for the catch-up and deliberately
## *not* for the restore, and that `finish()` may be called twice in a frame,
## which the corrupt-save fallback in `game/main.gd` does.


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _model() -> VeilModel:
	return VeilModel.new(_cfg())


# ===========================================================================
# Phases
# ===========================================================================

func test_a_fresh_veil_is_down_and_draws_nothing() -> void:
	var model := _model()
	assert_eq(model.phase, VeilModel.PHASE_NONE)
	assert_false(model.is_open())
	var view := model.build_view()
	assert_false(bool(view["visible"]))
	assert_eq(str(view["title"]), "", "a veil that is down has no copy")
	assert_almost_eq(float(view["progress01"]), 0.0, 0.0001)


func test_a_load_names_the_city_and_counts_its_steps() -> void:
	var model := _model()
	model.begin_load("Autosave", 11)
	model.advance_load(7)
	var view := model.build_view()
	assert_true(bool(view["visible"]))
	assert_eq(model.phase, VeilModel.PHASE_LOADING)
	assert_true(str(view["title"]).contains("Autosave"),
			"the veil says what it is opening: %s" % str(view["title"]))
	# Doc 13 §2.9.1: the fraction is honest about STEPS and dishonest about time,
	# so the unit is named under the bar rather than hidden behind a spinner.
	assert_true(str(view["detail"]).contains("7"), str(view["detail"]))
	assert_true(str(view["detail"]).contains("11"), str(view["detail"]))
	assert_almost_eq(float(view["progress01"]), 7.0 / 11.0, 0.0001)


func test_a_load_with_no_name_still_has_a_sentence() -> void:
	# `SaveService.begin_load_slot()` is reachable from a resume as well as from
	# CONTINUE, and a resume has no slot label to hand over.
	var model := _model()
	model.begin_load("", 11)
	var title := str(model.build_view()["title"])
	assert_ne(title, "", "an unnamed load is still a load")
	assert_false(title.contains("{"), "and no placeholder survives into it")


func test_an_empty_cursor_never_divides_by_zero() -> void:
	# What a quarantined save comes back as: the read failed its seven-check gate,
	# the refusal has already happened, and the cursor has no steps at all.
	var model := _model()
	model.begin_load("Slot 2", 0)
	assert_true(model.is_open(), "the veil is still up — the shell decides when")
	assert_almost_eq(float(model.build_view()["progress01"]), 0.0, 0.0001,
			"an empty cursor reads 0, not a full bar over a load that never ran")
	assert_eq(str(model.build_view()["detail"]), "",
			"and it does not claim to be on step 0 of 0")


func test_a_step_count_past_the_total_cannot_overfill_the_bar() -> void:
	var model := _model()
	model.begin_load("Autosave", 11)
	model.advance_load(94)
	assert_almost_eq(float(model.build_view()["progress01"]), 1.0, 0.0001)


func test_advancing_the_wrong_phase_is_ignored() -> void:
	# The two slicers run one after the other and both report progress; a
	# late `advance_load` from the frame the catch-up started must not rewind the
	# bar the catch-up is now driving.
	var model := _model()
	model.begin_catchup(12, 720)
	model.advance_catchup(360)
	model.advance_load(1)
	assert_almost_eq(float(model.build_view()["progress01"]), 0.5, 0.0001)


# ===========================================================================
# The catch-up, and doc 13's floor under it
# ===========================================================================

func test_the_catchup_says_how_long_the_city_ran() -> void:
	var model := _model()
	assert_true(model.begin_catchup(6, 1440))
	var view := model.build_view()
	assert_eq(model.phase, VeilModel.PHASE_CATCHUP)
	assert_true(str(view["title"]).contains("6"), str(view["title"]))
	assert_false(str(view["title"]).contains("{"), "every argument was supplied")


func test_one_hour_takes_the_singular() -> void:
	# doc 12 §3.1's plural rule, which is why `ui_veil_catchup_one` exists.
	var cfg := _cfg()
	var model := VeilModel.new(cfg)
	model.begin_catchup(1, 1440)
	var one := str(model.build_view()["title"])
	model.begin_catchup(2, 1440)
	var many := str(model.build_view()["title"])
	assert_ne(one, many, "`ran 1 hours` is the defect the rule exists for")


func test_a_short_absence_is_beneath_the_veils_own_floor() -> void:
	# doc 13 §2.9: `catchup_veil_min_steps = 5`. Sub-frame work gets no veil,
	# because a veil that flashes for one frame is a defect, not a courtesy.
	var model := _model()
	assert_true(model.min_steps() >= 2, "the floor is read from data/ui.json")
	assert_false(model.begin_catchup(0, model.min_steps() - 1))
	assert_false(model.is_open())
	assert_true(model.begin_catchup(1, model.min_steps()))
	assert_true(model.is_open())


func test_a_short_absence_takes_a_showing_veil_down_with_it() -> void:
	# The sequence a returning player actually produces: the restore raises the
	# veil, the catch-up is two ticks long, and the veil must not be left up over
	# a city that is finished loading.
	var model := _model()
	model.begin_load("Autosave", 11)
	model.advance_load(11)
	assert_false(model.begin_catchup(0, 1))
	assert_false(model.is_open())
	assert_eq(model.phase, VeilModel.PHASE_NONE)


func test_a_capped_absence_says_so() -> void:
	# Doc 01's 12-real-hour cap (C-19). The player was away longer than the sim
	# will credit, and A14's rule is that the refusal is stated in words.
	var model := _model()
	model.begin_catchup(720, 720, true)
	assert_ne(str(model.build_view()["detail"]), "",
			"the cap is named rather than silently applied")
	model.begin_catchup(720, 720, false)
	assert_eq(str(model.build_view()["detail"]), "",
			"and an uncapped catch-up says nothing extra")


# ===========================================================================
# Coming down
# ===========================================================================

func test_finish_is_idempotent() -> void:
	# `game/main.gd` calls it on the happy path and on the corrupt-save fallback,
	# and both can happen in the same frame.
	var model := _model()
	model.begin_load("Autosave", 11)
	model.finish()
	model.finish()
	assert_false(model.is_open())
	assert_eq(model.phase, VeilModel.PHASE_NONE)
	assert_almost_eq(float(model.build_view()["progress01"]), 0.0, 0.0001)


func test_a_second_load_starts_from_zero() -> void:
	# The fallback path: the named slot failed its gate and the newest OTHER one
	# is tried behind the same veil.
	var model := _model()
	model.begin_load("Slot 2", 11)
	model.advance_load(9)
	model.begin_load("Autosave", 11)
	assert_almost_eq(float(model.build_view()["progress01"]), 0.0, 0.0001)
	assert_true(str(model.build_view()["title"]).contains("Autosave"))

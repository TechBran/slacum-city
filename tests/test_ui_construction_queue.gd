extends SimTest
## Wave 17 — **S16, the construction queue** (doc 12 §2.22): the UI half of the
## seam, proved against the CONTRACT rather than against a build.
##
## The sim half — `CitySim.construction_overview()` and
## `CitySim.cmd_rush_construction()` — lands with a sibling branch. Every test
## here reaches the model through the two `Callable`s and the treasury reading
## `ConstructionQueueModel` takes for exactly that reason, and the fixture rows
## are the contract's twelve fields verbatim. What is under test:
##
##   1. **The seam is published once and read once.** `ROW_KEYS` is the
##      contract's field list, `KNOWN_SOURCES` is the sim's `KINDS` plus the
##      contract's own `block`, and a field or a kind on one side that the other
##      does not ship fails HERE rather than rendering grey.
##   2. **An unworked project says so in words.** `eta_gm = -1` — or a job with
##      no crew whatever number came with it — never renders as a clock, because
##      `0:00` reads as *finishing now* and this is its opposite.
##   3. **The price is on the face, and unaffordable is disabled-with-price.**
##      Never hidden, never blank — the number is the reading (§2.7's rule).
##   4. **The spend is one beat.** `rush_feedback()` is one sentence, one chip
##      flash, money OUT; the door's own answer buzzes only on a refusal, and
##      the accepted case is felt from the bus and nowhere else.
##   5. **Nothing is building → no chip.** The empty-state rule, on the mounted
##      scene; and the chip is the corner rail's third rung, which wraps rather
##      than leaving a 340 dp display.


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

## The contract's twelve fields, in the contract's order.
const CONTRACT_FIELDS: Array[String] = ["job_id", "source", "title_key", "ref",
		"tile", "level_from", "level_to", "progress01", "eta_gm", "crews",
		"rushable", "rush_cost"]


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## One contract row. Defaults are a crewed, rushable build a quarter done.
static func _row(job_id: int, source: StringName, eta_gm: float, crews: int,
		rushable: bool = true, rush_cost: int = 1000, level_from: int = 0,
		level_to: int = 0, ref: String = "b_1", progress01: float = 0.25,
		title_key: String = "ui_build_card_house") -> Dictionary:
	return {"job_id": job_id, "source": source, "title_key": title_key, "ref": ref,
			"tile": Vector2i(40 + job_id, 40), "level_from": level_from,
			"level_to": level_to, "progress01": progress01, "eta_gm": eta_gm,
			"crews": crews, "rushable": rushable, "rush_cost": rush_cost}


## The mixed queue S16 is written for: an upgrade fourteen minutes out with two
## crews, a new building an hour and a half out, a land development a day out
## that cannot be rushed, and a job nobody is working.
static func _mixed() -> Array:
	return [
		_row(44, &"build", 96.0, 1, true, 18_400, 0, 0, "b_new"),
		_row(41, &"upgrade", 14.0, 2, true, 1_240, 2, 3, "b_1"),
		_row(47, &"development", 1_910.0, 1, false, 0, 0, 0, "E4"),
		_row(39, &"repair", -1.0, 0, true, 600, 0, 0, "b_9"),
	]


func _model(rows: Array, balance: int = 1_000_000) -> ConstructionQueueModel:
	var model := ConstructionQueueModel.new(_cfg())
	model.set_provider(func() -> Array: return rows)
	model.set_treasury(func() -> int: return balance)
	model.refresh()
	return model


func _mount() -> UIRoot:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false  # never touch the test runner's window
	_tree().root.add_child(root)
	root.initialize()
	return root


func _unmount(root: UIRoot) -> void:
	_tree().root.remove_child(root)
	root.free()


static func _ids(rows: Array[Dictionary]) -> Array:
	var out: Array = []
	for row: Dictionary in rows:
		out.append(int(row["job_id"]))
	return out


# ===========================================================================
# 1. The seam, verbatim
# ===========================================================================

func test_the_contract_row_is_published_once_and_read_once() -> void:
	# The model reads nothing the contract does not name, and names nothing the
	# contract does not carry: the two lists are the same twelve fields.
	var published: Array = ConstructionQueueModel.ROW_KEYS.keys()
	published.sort()
	var contract: Array = CONTRACT_FIELDS.duplicate()
	contract.sort()
	assert_eq(published, contract, "ROW_KEYS is the seam contract, field for field")
	# And a row that carries every field is read with nothing lost.
	var model := _model([_row(41, &"upgrade", 14.0, 2, true, 1_240, 2, 3)])
	var row := model.row(41)
	assert_eq(int(row["job_id"]), 41)
	assert_eq(row["source"], &"upgrade")
	assert_eq(str(row["ref"]), "b_1")
	assert_eq(row["tile"], Vector2i(81, 40))
	assert_eq(int(row["level_from"]), 2)
	assert_eq(int(row["level_to"]), 3)
	assert_almost_eq(float(row["progress01"]), 0.25)
	assert_almost_eq(float(row["eta_gm"]), 14.0)
	assert_eq(int(row["crews"]), 2)
	assert_true(bool(row["rushable"]))
	assert_eq(int(row["rush_cost"]), 1_240)


func test_every_sim_kind_and_the_contracts_block_have_copy() -> void:
	# Enumerated, never invented: the sources this screen names are the sim
	# queue's own KINDS plus the contract's `block`, and every one has a string.
	var cfg := _cfg()
	var expected: Array = []
	for kind: StringName in ConstructionQueue.KINDS:
		expected.append(kind)
	expected.append(&"block")
	expected.sort()
	var known: Array = []
	for source: StringName in ConstructionQueueModel.KNOWN_SOURCES:
		known.append(source)
	known.sort()
	assert_eq(known, expected, "KNOWN_SOURCES == ConstructionQueue.KINDS + block")
	for source: StringName in ConstructionQueueModel.KNOWN_SOURCES:
		assert_true(cfg.has_string("ui_queue_source_%s" % String(source)),
				"ui_queue_source_%s exists" % String(source))
	assert_true(cfg.has_string("ui_queue_source_other"), "and the fallback exists")


func test_a_source_nobody_named_renders_as_project_and_is_reported() -> void:
	var model := _model([_row(9, &"teleport", 5.0, 1)])
	var row := model.row(9)
	assert_eq(str(row["source_label"]), _cfg().t("ui_queue_source_other"))
	assert_eq(model.unknown_sources(), PackedStringArray(["teleport"]),
			"a kind this table has no word for is REPORTED, not swallowed")
	var healthy := _model(_mixed())
	assert_eq(healthy.unknown_sources().size(), 0)


func test_an_unbound_provider_is_an_empty_queue_and_no_chip() -> void:
	# A shell that never wires the seam shows exactly what a city with nothing
	# under way shows: nothing.
	var model := ConstructionQueueModel.new(_cfg())
	model.refresh()
	assert_false(model.has_provider())
	assert_true(model.is_empty())
	assert_eq(model.count(), 0)
	assert_eq(model.badge_text(), "", "a hidden chip carries no `0`")
	assert_eq(model.chip_tooltip(), _cfg().t("ui_queue_chip_idle"))
	assert_eq(model.summary_text(), "")
	var refused := model.rush(41)
	assert_false(bool(refused["ok"]))
	assert_eq(str(refused["err"]), String(BuildController.E_NO_COMMAND),
			"no rush verb bound refuses with E_NO_COMMAND, which the shell reads as silence")
	assert_eq(int(refused["cost"]), 0)


func test_a_malformed_row_degrades_rather_than_crashing_the_screen() -> void:
	var model := _model([{}, "junk", 7, {"job_id": "7"}])
	assert_eq(model.raw_count(), 2, "two dictionaries arrived, whatever they held")
	assert_eq(model.count(), 2)
	var bare := model.row(7)
	assert_false(bare.is_empty(), "a String job id is read as a number, not as job 0")
	assert_false(bool(bare["working"]), "no eta and no crew is an unworked project")
	assert_eq(str(bare["eta_text"]), _cfg().t("ui_queue_eta_none"))
	assert_eq(str(bare["title"]), _cfg().t("ui_queue_untitled"))
	assert_false(bool(bare["rushable"]))
	assert_eq(str(bare["level_text"]), "")


# ===========================================================================
# 2. Order, words and time
# ===========================================================================

func test_rows_sort_sooner_first_and_uncrewed_last() -> void:
	var model := _model(_mixed())
	assert_eq(_ids(model.rows()), [41, 44, 47, 39],
			"ETA ascending with the unworked job last, whatever order the seam sent")
	# Ties among the unworked break on job id, so two starved rows never swap
	# under a finger.
	var starved := _model([_row(52, &"build", -1.0, 0), _row(51, &"build", -1.0, 0),
			_row(50, &"build", 30.0, 1)])
	assert_eq(_ids(starved.rows()), [50, 51, 52])


func test_an_unworked_project_says_so_in_words_and_never_as_a_clock() -> void:
	var cfg := _cfg()
	var model := _model(_mixed())
	var row := model.row(39)
	assert_false(bool(row["working"]))
	assert_eq(str(row["eta_text"]), cfg.t("ui_queue_eta_none"))
	assert_false(str(row["eta_text"]).contains("0m"), "never `0m`")
	assert_false(str(row["eta_text"]).contains(":"), "never `0:00`")
	assert_eq(str(row["crew_text"]), cfg.t("ui_queue_crew_none"))
	assert_eq(row["state"], HudModel.STATE_WARNING, "amber, and the bar is hatched")
	# The contract's two ways of saying it have to AGREE before a sentence is
	# written: a job with crews but a -1 ETA, and a job with an ETA but no crew,
	# are both unworked.
	var disagreeing := _model([_row(1, &"build", -1.0, 2), _row(2, &"build", 40.0, 0)])
	assert_false(bool(disagreeing.row(1)["working"]))
	assert_false(bool(disagreeing.row(2)["working"]))
	assert_eq(str(disagreeing.row(2)["eta_text"]), cfg.t("ui_queue_eta_none"),
			"an ETA with nobody on it is not a countdown")
	# And the summary counts the waiting ones out loud.
	assert_eq(model.summary_text(), "%s %s %s" % [
			cfg.t("ui_queue_summary", {"n": 4}), cfg.t("ui_queue_separator"),
			cfg.t("ui_queue_summary_idle", {"n": 1})])
	var all_working := _model([_row(1, &"build", 10.0, 1)])
	assert_eq(all_working.summary_text(), cfg.t("ui_queue_summary", {"n": 1}),
			"a queue where every project has a crew has nothing to apologise for")


func test_the_eta_reads_in_game_time_through_the_shared_span_words() -> void:
	var cfg := _cfg()
	var model := _model(_mixed())
	assert_eq(str(model.row(41)["eta_text"]),
			cfg.t("ui_queue_eta", {"eta": "14m"}))
	assert_eq(str(model.row(44)["eta_text"]),
			cfg.t("ui_queue_eta", {"eta": "1h 36m"}))
	assert_eq(str(model.row(47)["eta_text"]),
			cfg.t("ui_queue_eta", {"eta": "1d 7h"}))
	# The span is ONE function for S4 and S16 — a second `{h}h {m}m` in the table
	# would be a second place for the copy to drift.
	assert_eq(UIWidgets.duration_text(cfg, 96.0), "1h 36m")
	assert_eq(UIWidgets.duration_text(cfg, 1_910.0), "1d 7h")
	assert_eq(UIWidgets.duration_text(cfg, 14.4), "14m")
	assert_eq(UIWidgets.duration_text(cfg, -5.0), "0m",
			"a negative is the CALLER's sentence; the span itself floors at zero")
	for key: String in ["ui_time_dh", "ui_time_hm", "ui_time_m"]:
		assert_true(cfg.has_string(key), "%s is the neutral key" % key)
	for old: String in ["ui_land_time_dh", "ui_land_time_hm", "ui_land_time_m"]:
		assert_false(cfg.has_string(old), "%s left with the arithmetic" % old)


func test_level_text_only_when_it_is_a_level_change() -> void:
	var cfg := _cfg()
	var model := _model(_mixed())
	assert_eq(str(model.row(41)["level_text"]),
			cfg.t("ui_queue_level", {"from": 2, "to": 3}))
	assert_eq(str(model.row(44)["level_text"]), "",
			"0/0 is `not a level change`, and prints nothing")
	var flat := _model([_row(5, &"repair", 8.0, 1, true, 100, 3, 3)])
	assert_eq(str(flat.row(5)["level_text"]), cfg.t("ui_queue_level_flat", {"level": 3}))


func test_progress_text_and_groups() -> void:
	var model := _model(_mixed())
	assert_eq(str(model.row(41)["percent_text"]), "25%")
	var clamped := _model([_row(1, &"build", 10.0, 1, true, 1, 0, 0, "x", 1.7)])
	assert_almost_eq(float(clamped.row(1)["progress01"]), 1.0)
	assert_eq(str(clamped.row(1)["percent_text"]), "100%")
	var groups := model.groups()
	var seen: Dictionary = {}
	for group: Dictionary in groups:
		seen[group["source"]] = int(group["count"])
	assert_eq(seen, {&"build": 1, &"upgrade": 1, &"development": 1, &"repair": 1})
	assert_eq(groups[0]["source"], &"build", "groups come in a stable alphabetical order")
	assert_eq(str(groups[0]["label"]), _cfg().t("ui_queue_source_build"))


func test_row_for_ref_finds_the_project_for_the_building_on_screen() -> void:
	# S5 looks a project up by `ref` — the contract's own field. Two projects on
	# one ref answer the soonest, because that is the bar that is moving.
	var model := _model([_row(2, &"repair", 50.0, 1, true, 10, 0, 0, "b_7"),
			_row(1, &"upgrade", 20.0, 1, true, 10, 1, 2, "b_7")])
	assert_eq(int(model.row_for_ref("b_7")["job_id"]), 1)
	assert_true(model.row_for_ref("nobody").is_empty())
	assert_true(model.row_for_ref("").is_empty())


# ===========================================================================
# 3. The price on the face
# ===========================================================================

func test_the_rush_price_is_on_the_face_and_unaffordable_is_disabled_with_price() -> void:
	var cfg := _cfg()
	var rich := _model(_mixed(), 500_000)
	var row := rich.row(44)
	assert_eq(str(row["rush_text"]),
			cfg.t("ui_queue_rush_price", {"cost": HudModel.money(18_400)}))
	assert_true(bool(row["affordable"]))
	assert_eq(str(row["rush_tooltip"]),
			cfg.t("ui_queue_rush_hint", {"cost": HudModel.money(18_400)}))
	var poor := _model(_mixed(), 500)
	var short := poor.row(44)
	assert_false(bool(short["affordable"]), "disabled…")
	assert_eq(str(short["rush_text"]), str(row["rush_text"]), "…with the price still on it")
	assert_eq(str(short["rush_tooltip"]), cfg.t("ui_queue_rush_short",
			{"cost": HudModel.money(18_400), "have": HudModel.money(500)}),
			"the tooltip names both numbers")
	var fixed := poor.row(47)
	assert_false(bool(fixed["rushable"]))
	assert_eq(str(fixed["rush_text"]), cfg.t("ui_queue_rush"))
	assert_eq(str(fixed["rush_tooltip"]), cfg.t("ui_queue_rush_unavailable"))
	assert_eq(int(fixed["rush_cost"]), 0)
	# A treasury reading exactly equal to the price is affordable — the door is
	# what decides, and a model that refused at equality would be a second door.
	var exact := _model(_mixed(), 18_400)
	assert_true(bool(exact.row(44)["affordable"]))
	assert_eq(exact.balance(), 18_400)


func test_the_rush_door_coerces_a_string_id_and_answers_verbatim() -> void:
	var model := _model(_mixed())
	var seen: Array = []
	model.set_rush(func(job_id: Variant) -> Dictionary:
		seen.append(job_id)
		return {"ok": true, "err": "", "cost": 1_240})
	var answer := model.rush("41")
	assert_eq(seen, [41], "`\"41\"` reaches the door as int 41, never as job 0")
	assert_eq(seen[0] is int, true)
	assert_true(bool(answer["ok"]))
	assert_eq(int(answer["cost"]), 1_240)
	# A door that answers in the shell's older spelling is read too.
	model.set_rush(func(_job_id: Variant) -> Dictionary:
		return {"ok": false, "reason_code": &"E_FUNDS"})
	var refused := model.rush(41)
	assert_false(bool(refused["ok"]))
	assert_eq(str(refused["err"]), "E_FUNDS")
	assert_eq(int(refused["cost"]), 0)
	# A door that answers nonsense is a refusal, not a crash.
	model.set_rush(func(_job_id: Variant) -> Variant: return null)
	assert_eq(str(model.rush(41)["err"]), String(BuildController.E_NO_COMMAND))


# ===========================================================================
# 4. The spend is one beat
# ===========================================================================

func test_rush_feedback_is_one_sentence_one_chip_and_money_out() -> void:
	var cfg := _cfg()
	var model := _model(_mixed())
	var feedback := model.rush_feedback({"type": "construction_rushed", "job": 41,
			"cost": 1_240, "source": &"upgrade"})
	assert_true(bool(feedback["ok"]))
	assert_eq(int(feedback["amount"]), 1_240)
	assert_eq(str(feedback["amount_text"]), HudModel.money_exact(-1_240),
			"money leaving is printed as leaving")
	assert_eq(str(feedback["toast"]), cfg.t("ui_queue_rushed_toast",
			{"what": cfg.t("ui_queue_source_upgrade"), "cost": HudModel.money_exact(-1_240)}))
	assert_eq(str(feedback["flash_chip"]), HudModel.CHIP_TREASURY)
	assert_almost_eq(float(feedback["flash_s"]), model.chip_flash_s())
	assert_almost_eq(model.chip_flash_s(),
			UIConfig.get_num(cfg.section("construction"), "chip_flash_s", -1.0),
			0.0001, "the flash length is authored, not a literal")
	assert_eq(feedback["haptic"], Haptics.CUE_DISPATCH, "the player's own thumb is on it")
	assert_false(bool(feedback["cue"]), "the coin is a data/audio.json rule, not a branch")
	assert_true(model.rush_feedback({"job": 1, "cost": 0}).is_empty(),
			"a rush that cost nothing did not happen and has nothing to say")


func test_the_audio_rule_sounds_a_rush_as_a_spend_and_not_as_a_payday() -> void:
	# The cue is a `data/audio.json` rule on the event itself, so the shell needs
	# no branch — and it is `purchase`, the deck's spend cue, because a player who
	# hears a till when their balance DROPS learns the wrong thing.
	var audio: Dictionary = StarterCityLoader.read_json("res://data/audio.json")
	var found := false
	for entry: Variant in audio.get("events", []):
		if not (entry is Dictionary):
			continue
		var rule: Dictionary = entry
		if str(rule.get("type", "")) != String(ConstructionQueueModel.EVENT_RUSHED):
			continue
		found = true
		assert_eq(str(rule.get("cue", "")), "purchase")
		assert_ne(str(rule.get("cue", "")), "cash")
	assert_true(found, "data/audio.json has a rule on construction_rushed")


func test_a_rush_on_the_bus_is_felt_once_and_a_refusal_is_a_sentence() -> void:
	var root := _mount()
	var rows: Array = _mixed()
	root.bind_construction(func() -> Array: return rows,
			func(_job_id: Variant) -> Dictionary: return {"ok": true, "err": "", "cost": 1_240},
			func() -> int: return 500_000)
	# The spend arrives on the bus, like every other rush from any door.
	root.feed_events([{"type": "construction_rushed", "job": 41, "cost": 1_240,
			"source": &"upgrade"}])
	assert_true(root.hud.model.chip_flashing(HudModel.CHIP_TREASURY),
			"the treasury chip pulses — money moved")
	assert_true(root.toast_view.is_open())
	assert_true(root.toast_view.text().contains(HudModel.money_exact(-1_240)),
			"one sentence, and the money in it is leaving")
	root.toast_view.hide_toast()
	# The door's own accepted answer adds NOTHING — no second toast.
	root.report_rush(41, {"ok": true, "err": "", "cost": 1_240})
	assert_false(root.toast_view.is_open(), "an accepted rush is felt from the bus only")
	# A refusal is a sentence from §2.7's formatter, never silence…
	root.report_rush(41, {"ok": false, "err": "E_FUNDS", "cost": 0})
	assert_true(root.toast_view.is_open())
	assert_ne(root.toast_view.text(), "")
	root.toast_view.hide_toast()
	# …except for a build whose sim has no rush verb at all.
	root.report_rush(41, {"ok": false, "err": String(BuildController.E_NO_COMMAND),
			"cost": 0})
	assert_false(root.toast_view.is_open(),
			"there is no story to tell about a feature that is not there")
	_unmount(root)


# ===========================================================================
# 5. The mounted screen: the chip, the rail, the rows, the back stack
# ===========================================================================

func test_the_chip_hides_when_nothing_is_building_and_badges_the_count() -> void:
	var root := _mount()
	var queue := root.construction_queue
	assert_ne(queue, null, "S16 is in the scene")
	assert_false(queue.chip_button().visible, "unbound: no chip at all")
	var rows: Array = _mixed()
	root.bind_construction(func() -> Array: return rows)
	assert_true(queue.chip_button().visible, "four projects: the chip is up")
	assert_true(queue.chip_button().text.contains("4"), "…with the count on its face")
	assert_true(queue.chip_button().text.begins_with(ConstructionQueueSheet.CHIP_GLYPH),
			"A5: the glyph names the kind, the number is the value")
	assert_eq(queue.chip_button().tooltip_text, _cfg().t("ui_queue_chip", {"n": 4}))
	assert_eq(_cfg().t("ui_queue_chip", {"n": 1}), _cfg().t("ui_queue_chip_one", {"n": 1}),
			"one project takes the singular")
	assert_true(queue.chip_button().custom_minimum_size.x >= 48.0)
	assert_true(queue.chip_button().custom_minimum_size.y >= 48.0)
	rows.clear()
	root.refresh_construction()
	assert_false(queue.chip_button().visible, "the last project finished: the chip leaves")
	assert_eq(queue.chip_button().text, ConstructionQueueSheet.CHIP_GLYPH,
			"a hidden chip never carries a `0`")
	_unmount(root)


func test_opening_the_queue_puts_the_sibling_panel_away_and_back_closes_it() -> void:
	var root := _mount()
	var rows: Array = _mixed()
	root.bind_construction(func() -> Array: return rows)
	root.alerts_center.open()
	assert_true(root.alerts_center.is_open())
	root.open_construction_queue()
	assert_true(root.construction_queue_open())
	assert_false(root.alerts_center.is_open(), "one open surface on PanelLayer at a time")
	assert_false(root.construction_queue.chip_button().visible,
			"the chip and the panel share the right edge; the panel wins")
	assert_eq(root.handle_back(1000.0), UIRoot.BACK_CLOSE_PANEL)
	assert_false(root.construction_queue_open(), "Android BACK closes the panel")
	assert_true(root.construction_queue.chip_button().visible, "…and the chip comes back")
	root.open_construction_queue()
	root.alerts_center.open()
	assert_false(root.construction_queue_open(), "and the other way round")
	_unmount(root)


func test_the_panel_lists_every_row_with_its_verbs_and_a_tap_focuses_the_site() -> void:
	var root := _mount()
	var rows: Array = _mixed()
	var rushed_ids: Array = []
	root.bind_construction(func() -> Array: return rows,
			func(job_id: Variant) -> Dictionary:
				var wanted := int(str(job_id))
				rushed_ids.append(wanted)
				for i in rows.size():
					if int((rows[i] as Dictionary)["job_id"]) == wanted:
						var cost := int((rows[i] as Dictionary)["rush_cost"])
						rows.remove_at(i)
						return {"ok": true, "err": "", "cost": cost}
				return {"ok": false, "err": "E_UNKNOWN_JOB", "cost": 0},
			func() -> int: return 10_000)
	root.set_incident_locator(func(kind: StringName, id: Variant) -> Variant:
		assert_eq(kind, &"tile")
		var tile: Vector2i = id
		return Vector3(float(tile.x) * 8.0, 0.0, float(tile.y) * 8.0))
	var focused: Array = []
	root.focus_requested.connect(func(pos: Vector3) -> void: focused.append(pos))
	root.open_construction_queue()
	var queue := root.construction_queue
	assert_eq(queue.count(), 4)
	for job_id: int in [41, 44, 47, 39]:
		var row_button := queue.row_button(job_id)
		assert_ne(row_button, null, "job %d has a row" % job_id)
		assert_ne(row_button.tooltip_text.strip_edges(), "", "and the row names itself (A15)")
		assert_true(row_button.custom_minimum_size.y >= 48.0)
	# Tap the row: the site, through the locator, to the camera.
	queue.row_button(41).pressed.emit()
	assert_eq(focused, [Vector3(81.0 * 8.0, 0.0, 40.0 * 8.0)])
	# The verbs: a price on every rushable face, disabled where the treasury is
	# short, absent where the seam says it cannot be rushed.
	var cheap := queue.rush_button(41)
	assert_ne(cheap, null)
	assert_false(cheap.disabled, "$1,240 against $10,000")
	assert_true(cheap.text.contains(HudModel.money(1_240)))
	assert_true(cheap.custom_minimum_size.y >= 48.0)
	assert_ne(cheap.tooltip_text.strip_edges(), "")
	var dear := queue.rush_button(44)
	assert_true(dear.disabled, "$18.4K against $10,000: disabled…")
	assert_true(dear.text.contains(HudModel.money(18_400)), "…with the price still on it")
	assert_eq(queue.rush_button(47), null, "not rushable: no button, not a blank one")
	# One tap, and the list is re-read from the provider rather than predicted.
	var answers: Array = []
	queue.rushed.connect(func(job_id: int, result: Dictionary) -> void:
		answers.append([job_id, result]))
	cheap.pressed.emit()
	assert_eq(rushed_ids, [41])
	assert_eq(answers.size(), 1)
	assert_true(bool((answers[0][1] as Dictionary)["ok"]))
	assert_eq(queue.count(), 3, "the door took the row and the panel re-read it")
	assert_eq(queue.row_button(41), null)
	_unmount(root)


func test_the_building_panel_shows_the_same_row_inline_and_only_while_it_exists() -> void:
	# §2.22 item 3: a picked building mid-project shows the queue's own row in a
	# bounded block directly under the level pips, from the SAME model, and a
	# building the seam does not name simply has no block.
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	var root := _mount()
	var panel := root.safe_area.get_node_or_null("PanelLayer/BuildingPanel") as BuildingPanel
	assert_ne(panel, null)
	panel.setup(root.config, controller)
	var keys := sim.buildings.keys()
	keys.sort()
	var picked := str(keys[0])
	var rows: Array = [_row(41, &"upgrade", 14.0, 2, true, 1_240, 2, 3, picked)]
	root.bind_construction(func() -> Array: return rows, Callable(),
			func() -> int: return 500)
	panel.bind_construction(root.construction_queue.model)
	panel.show_building(picked)
	var block := panel.get_node_or_null("Panel/Scroll/Body/Progress") as Control
	assert_ne(block, null, "the UPGRADE-PROGRESS block is built in code")
	assert_true(block.visible, "a building with a project shows it")
	var level := panel.get_node_or_null("Panel/Scroll/Body/Level") as Control
	assert_eq(block.get_index(), level.get_index() + 1,
			"directly under the level pips, above the upgrade block")
	var eta := block.get_node("Eta") as Label
	assert_eq(eta.text, _cfg().t("ui_queue_eta", {"eta": "14m"}))
	var rush := block.get_node("Rush") as Button
	assert_true(rush.visible)
	assert_true(rush.text.contains(HudModel.money(1_240)), "the price on the face…")
	assert_true(rush.disabled, "…disabled against a $500 treasury")
	assert_ne(rush.tooltip_text.strip_edges(), "")
	assert_true(rush.custom_minimum_size.y >= 48.0)
	assert_true((block.get_node("Clock/Bar") as MeterBar) != null, "the six-step bar widget")
	# The project lands: the block goes with it, and nothing else on the panel moves.
	rows.clear()
	root.refresh_construction()
	panel.refresh()
	assert_false(block.visible, "no project, no block — no `0:00`, no empty bar")
	assert_true(panel.is_open())
	_unmount(root)


func test_the_building_panels_rush_carries_the_doors_answer() -> void:
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	var root := _mount()
	var panel := root.safe_area.get_node_or_null("PanelLayer/BuildingPanel") as BuildingPanel
	panel.setup(root.config, controller)
	var keys := sim.buildings.keys()
	keys.sort()
	var picked := str(keys[0])
	var rows: Array = [_row(41, &"upgrade", 14.0, 2, true, 1_240, 2, 3, picked)]
	root.bind_construction(func() -> Array: return rows,
			func(job_id: Variant) -> Dictionary:
				rows.clear()
				return {"ok": true, "err": "", "cost": 1_240, "seen": int(str(job_id))},
			func() -> int: return 500_000)
	panel.bind_construction(root.construction_queue.model)
	panel.show_building(picked)
	var answers: Array = []
	panel.rushed.connect(func(sim_id: String, job_id: int, result: Dictionary) -> void:
		answers.append([sim_id, job_id, result]))
	var block := panel.get_node("Panel/Scroll/Body/Progress") as Control
	(block.get_node("Rush") as Button).pressed.emit()
	assert_eq(answers.size(), 1)
	assert_eq(str(answers[0][0]), picked)
	assert_eq(int(answers[0][1]), 41)
	assert_true(bool((answers[0][2] as Dictionary)["ok"]))
	assert_false(block.visible, "the door took the project; the panel re-read the city")
	_unmount(root)


func test_the_presentation_block_holds_no_price_and_every_tunable_is_authored() -> void:
	# Doc 03 owns every dollar (C-07): `data/ui.json.construction` may hold a
	# width, a height and a flash length, and not one number that is a price, a
	# duration or a rate.
	var section := _cfg().section("construction")
	assert_false(section.is_empty(), "data/ui.json has a `construction` block")
	for key: String in ["row_h_dp", "panel_w_dp", "chip_w_dp", "bar_h_dp", "chip_flash_s"]:
		assert_true(section.has(key), "construction.%s is authored" % key)
	for key: Variant in section:
		var name := str(key)
		assert_false(name.contains("cost") or name.contains("price")
				or name.contains("rate") or name.contains("_gm") or name.contains("mult"),
				"construction.%s is presentation, not a price" % name)
	var model := ConstructionQueueModel.new(_cfg())
	assert_almost_eq(model.row_h_dp(), UIConfig.get_num(section, "row_h_dp", -1.0))
	assert_almost_eq(model.panel_w_dp(), UIConfig.get_num(section, "panel_w_dp", -1.0))
	assert_almost_eq(model.chip_w_dp(), UIConfig.get_num(section, "chip_w_dp", -1.0))
	assert_almost_eq(model.bar_h_dp(), UIConfig.get_num(section, "bar_h_dp", -1.0))
	# Fallbacks exist for a malformed file and match what is authored.
	var bare := ConstructionQueueModel.new(null)
	assert_almost_eq(bare.row_h_dp(), ConstructionQueueModel.DEFAULT_ROW_H_DP)
	assert_almost_eq(bare.chip_flash_s(), ConstructionQueueModel.DEFAULT_CHIP_FLASH_S)

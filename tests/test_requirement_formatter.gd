extends SimTest
## Doc 12 §7 test 13 (`test_requirement_formatter`), P1-33's half: every stable
## failure code — the doc's 13 of §4.4 **and** the 13 `sim/city_sim.gd` actually
## raises — renders non-empty copy with its parameters substituted, routes a
## `fix_target`, resolves from `data/strings.en.json` rather than from code, and
## degrades (never crashes) on an unknown code or a missing template.

## Doc 12 §4.4's stable enum, verbatim.
const DOC_CODES: Array[String] = [
	"POWER_CAPACITY", "WATER_PRESSURE", "NO_ROAD", "NO_CREW", "FIRE_COVERAGE",
	"CITY_LEVEL", "FUNDS", "OCCUPIED", "NOT_OWNED", "UNDEVELOPED", "TERRAIN",
	"TECH_LOCK", "E_AVENUE",
]

## What `CitySim.cmd_place_building` / `cmd_upgrade_building` return.
const SIM_CODES: Array[String] = [
	"E_UNKNOWN_ARCHETYPE", "E_NOT_OWNED", "E_NOT_DEVELOPED", "E_FOOTPRINT",
	"E_UNSERVED", "E_FUNDS", "E_STATE", "E_MAX_LEVEL", "E_CONDITION",
	"E_CITY_LEVEL", "E_POWER_HEADROOM", "E_AVENUE", "E_UNKNOWN_BUILDING",
]


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _fmt() -> RequirementFormatter:
	return RequirementFormatter.load_from_files()


## A representative parameter bag: every code takes what it needs and ignores
## the rest, which is exactly the contract the placement bar relies on.
func _params() -> Dictionary:
	return {
		"cost": 12400, "balance": 8400, "deficit_kw": 87.4, "required_kw": 87.4,
		"headroom_kw": 0.0, "at": "SUB-A", "fix_target_id": "SUB-A",
		"tile": Vector2i(40, 40), "block_id": "B_3_3", "city_level": 2,
		"required_level": 3, "condition": 0.40, "min_condition": 0.55,
		"level": 4, "max_level": 5, "state": "damaged", "archetype": "house",
		"sim_id": "H-001", "avenue_distance_tiles": 7, "distance_tiles": 3,
		"busy_crews": 2, "total_crews": 2,
	}


# ---------------------------------------------------------------------------
# Coverage: both vocabularies, every code, no missing template
# ---------------------------------------------------------------------------

func test_all_thirteen_doc_codes_render() -> void:
	var cfg := _cfg()
	var formatter := RequirementFormatter.new(cfg)
	assert_eq(DOC_CODES.size(), 13, "report 98 C-62 raised the enum from 12 to 13")
	for code: String in DOC_CODES:
		var row := formatter.format(code, _params())
		assert_eq(str(row["canonical"]), code, "%s is canonical" % code)
		assert_true(str(row["body"]).length() > 0, "%s renders a body" % code)
		assert_false(str(row["body"]).contains("{"),
				"%s leaves no placeholder unresolved: %s" % [code, row["body"]])
		assert_ne(str(row["body"]), str(row["key"]),
				"%s resolves a template, not the key itself" % code)
		assert_true(str(row["title"]).length() > 0, "%s has a chip title" % code)
		assert_true(RequirementFormatter.CODE_TABLE.has(StringName(code)))


func test_all_thirteen_sim_codes_map_onto_the_table() -> void:
	# The sim keeps its own spelling; the formatter folds six of them onto the
	# doc's name and gives the other seven their own row. Nothing lands on
	# UNKNOWN — an unmapped sim code would be a silent copy hole.
	var formatter := _fmt()
	assert_eq(SIM_CODES.size(), 13)
	for code: String in SIM_CODES:
		var canonical := RequirementFormatter.canonical(code)
		assert_ne(canonical, RequirementFormatter.UNKNOWN_CODE,
				"%s is a known requirement" % code)
		var row := formatter.format(code, _params())
		assert_eq(str(row["code"]), code, "the raw sim code is preserved")
		assert_true(str(row["body"]).length() > 0)
		assert_false(str(row["body"]).contains("{"), "%s: %s" % [code, row["body"]])


func test_every_template_lives_in_the_string_table() -> void:
	# G-8: no display copy in `ui/`. Body, title and remedy all resolve from
	# data/strings.en.json for every canonical code.
	var cfg := _cfg()
	for code: StringName in RequirementFormatter.codes():
		for suffix: String in ["", "_title", "_remedy"]:
			var key := RequirementFormatter.string_key(code, suffix)
			assert_true(cfg.has_string(key), "data/strings.en.json carries %s" % key)


func test_aliases_fold_sim_spellings_onto_doc_names() -> void:
	assert_eq(RequirementFormatter.canonical("E_POWER_HEADROOM"), &"POWER_CAPACITY")
	assert_eq(RequirementFormatter.canonical("E_FUNDS"), &"FUNDS")
	assert_eq(RequirementFormatter.canonical("E_FOOTPRINT"), &"OCCUPIED")
	assert_eq(RequirementFormatter.canonical("E_NOT_OWNED"), &"NOT_OWNED")
	assert_eq(RequirementFormatter.canonical("E_NOT_DEVELOPED"), &"UNDEVELOPED")
	assert_eq(RequirementFormatter.canonical("E_CITY_LEVEL"), &"CITY_LEVEL")
	# Case and whitespace are not a vocabulary.
	assert_eq(RequirementFormatter.canonical(" e_funds "), &"FUNDS")


# ---------------------------------------------------------------------------
# Parameter interpolation
# ---------------------------------------------------------------------------

func test_funds_interpolates_money_through_the_hud_conventions() -> void:
	var row := _fmt().format(&"E_FUNDS", {"cost": 12400, "balance": 8400})
	assert_eq(str(row["args"]["have"]), HudModel.money(8400))
	assert_eq(str(row["args"]["need"]), HudModel.money(12400))
	assert_true(str(row["body"]).contains("$12.4K"), row["body"])
	assert_true(str(row["body"]).contains(HudModel.money(8400)), row["body"])
	assert_true(bool(row["blocking"]))
	assert_eq(str(row["state"]), String(HudModel.STATE_CRITICAL))


func test_power_capacity_renders_kw_and_names_the_feeder() -> void:
	var row := _fmt().format(&"E_POWER_HEADROOM",
			{"deficit_kw": 87.4, "required_kw": 87.4, "headroom_kw": 0.0, "at": "SUB-A"})
	assert_true(str(row["body"]).contains("87.4 kW"), row["body"])
	assert_true(str(row["body"]).contains("SUB-A"), "the remedy names the blocker")
	# Wave 17 (A91-D-54): this row's fix is a PURCHASE the panel performs in
	# place, not a camera jump to the building the player already has open.
	assert_eq(str(row["fix_target"]["kind"]), String(RequirementFormatter.FIX_POWER))
	# The MW ladder of the doc's worked example.
	assert_eq(RequirementFormatter.power(1800.0), "1.8 MW")
	assert_eq(RequirementFormatter.power(2400.0), "2.4 MW")
	assert_eq(RequirementFormatter.power(87.4), "87.4 kW")
	assert_eq(RequirementFormatter.power(210.0), "210 kW")


func test_avenue_row_is_the_thirteenth_code_and_routes_to_a_road() -> void:
	# C-62: `have` in tiles, `need == 4`, the target level named, and the fix
	# target a ROAD SEGMENT rather than a building.
	var row := _fmt().format(&"E_AVENUE", {"avenue_distance_tiles": 7,
			"avenue_radius_tiles": 4, "to_level": 4, "fix_target_id": "R-014"})
	assert_eq(str(row["args"]["have"]), "7")
	assert_eq(str(row["args"]["need"]), "4")
	assert_eq(str(row["args"]["level"]), "4")
	assert_true(str(row["body"]).contains("AVENUE"), row["body"])
	assert_eq(str(row["fix_target"]["kind"]), String(RequirementFormatter.FIX_ROAD_SEGMENT))
	assert_eq(str(row["fix_target"]["id"]), "R-014")


func test_condition_and_max_level_render_their_own_units() -> void:
	var formatter := _fmt()
	var condition := formatter.format(&"E_CONDITION",
			{"condition": 0.40, "min_condition": Building.MIN_CONDITION_TO_UPGRADE})
	assert_true(str(condition["body"]).contains("40%"), condition["body"])
	assert_true(str(condition["body"]).contains("55%"), condition["body"])
	var maxed := formatter.format(&"E_MAX_LEVEL", {"level": 5, "max_level": 5})
	assert_eq(str(maxed["severity"]), String(RequirementFormatter.SEVERITY_INFO),
			"being finished is not a blocker to fix")
	assert_false(bool(maxed["blocking"]))


func test_severity_classes_follow_the_doc() -> void:
	assert_true(RequirementFormatter.is_blocking(&"E_FUNDS"))
	assert_true(RequirementFormatter.is_blocking(&"E_AVENUE"), "C-62: a hard gate")
	assert_false(RequirementFormatter.is_blocking(&"NO_CREW"), "§4.4 classes it soft")
	assert_eq(RequirementFormatter.severity_of(&"NO_CREW"),
			RequirementFormatter.SEVERITY_WARN)
	assert_eq(str(_fmt().format(&"NO_CREW", _params())["state"]),
			String(HudModel.STATE_WARNING))


# ---------------------------------------------------------------------------
# Degradation — never a crash, never a blank
# ---------------------------------------------------------------------------

func test_unknown_code_degrades_to_a_generic_row() -> void:
	var row := _fmt().format(&"E_SOMETHING_THE_SIM_INVENTED_LATER", _params())
	assert_eq(row["canonical"], RequirementFormatter.UNKNOWN_CODE)
	assert_true(str(row["body"]).length() > 0, "a generic row, never a blank")
	assert_true(str(row["body"]).contains("E_SOMETHING_THE_SIM_INVENTED_LATER"),
			"the generic row names the code so a copy hole is findable")
	assert_false(str(row["body"]).contains("{"))


func test_missing_string_table_degrades_structurally() -> void:
	# An empty config stands in for a broken/absent data file: every code still
	# renders something readable and nothing throws.
	var formatter := RequirementFormatter.new(UIConfig.new())
	for code: String in (DOC_CODES + SIM_CODES):
		var row := formatter.format(code, _params())
		assert_true(str(row["body"]).length() > 0, "%s degrades to a structural body" % code)
		assert_true(str(row["title"]).length() > 0)
	assert_eq(formatter.format(&"E_FUNDS", {"cost": 100, "balance": 10})["body"],
			"E_FUNDS: $10 / $100")


func test_formatter_survives_empty_params() -> void:
	var formatter := _fmt()
	for code: String in (DOC_CODES + SIM_CODES):
		var row := formatter.format(code)
		assert_true(str(row["body"]).length() > 0, "%s renders with no params" % code)
		assert_false(str(row["body"]).contains("{"), "%s: %s" % [code, row["body"]])


# ---------------------------------------------------------------------------
# Checklist assembly (doc 12 §2.9 item 5)
# ---------------------------------------------------------------------------

func test_checklist_marks_every_row_and_names_the_first_blocker() -> void:
	var formatter := _fmt()
	var checks: Array = [&"E_STATE", &"E_MAX_LEVEL", &"E_CONDITION", &"E_CITY_LEVEL",
			&"E_FUNDS", &"E_POWER_HEADROOM"]
	var rows := formatter.checklist(checks, [&"E_CONDITION", &"E_FUNDS"], _params())
	assert_eq(rows.size(), 6, "the whole gate, passing rows included")
	assert_true(bool(rows[0]["ok"]))
	assert_eq(str(rows[0]["glyph"]), RequirementFormatter.GLYPH_PASS)
	assert_eq(str(rows[0]["state"]), String(HudModel.STATE_NORMAL))
	assert_false(bool(rows[2]["ok"]), "E_CONDITION failed")
	assert_eq(str(rows[2]["glyph"]), RequirementFormatter.GLYPH_FAIL)
	var first := RequirementFormatter.first_blocker(rows)
	assert_eq(str(first["canonical"]), "E_CONDITION", "the UPGRADE subtitle names it")
	assert_true(RequirementFormatter.first_blocker(
			formatter.checklist(checks, [], _params())).is_empty(),
			"no blockers, no subtitle")


func test_from_result_reads_a_real_command_refusal() -> void:
	var sim := CitySim.boot_from_files()
	var formatter := _fmt()
	# An unowned ring block (doc 09) — the sim's own E_NOT_OWNED.
	var refused := sim.cmd_place_building("house", Vector2i(8, 8))
	assert_false(bool(refused["ok"]))
	var row := formatter.from_result(refused, {"tile": Vector2i(8, 8)})
	assert_eq(str(row["canonical"]), "NOT_OWNED")
	assert_true(str(row["body"]).length() > 0)
	assert_false(str(row["body"]).contains("{"))
	# A successful command has nothing to explain.
	assert_true(formatter.from_result(CommandQueue.ok({})).is_empty())


func test_from_result_folds_the_payload_into_the_parameters() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.spend(sim.treasury.balance - 100, &"test_drain")
	var origin := Vector2i(-1, -1)
	for z in range(32, 80):
		for x in range(32, 80):
			if sim.world.grid.can_place(Vector2i(x, z), Vector2i.ONE) \
					and sim.grid.would_serve(Vector2i(x, z)):
				origin = Vector2i(x, z)
				break
		if origin.x >= 0:
			break
	var refused := sim.cmd_place_building("house", origin)
	assert_eq(refused["reason_code"], &"E_FUNDS")
	var row := _fmt().from_result(refused)
	# `{cost, balance}` came straight off the command payload.
	assert_eq(str(row["args"]["need"]), HudModel.money(int(refused["payload"]["cost"])))
	assert_eq(str(row["args"]["have"]), HudModel.money(int(refused["payload"]["balance"])))


func test_checklist_text_is_the_name_when_passing_and_the_reason_when_not() -> void:
	var formatter := _fmt()
	var rows := formatter.checklist([&"E_CONDITION", &"E_FUNDS"], [&"E_FUNDS"], _params())
	assert_eq(str(rows[0]["text"]), str(rows[0]["title"]),
			"a satisfied requirement is named, never explained in the failure voice")
	assert_eq(str(rows[1]["text"]), str(rows[1]["body"]),
			"the row the player must act on carries the whole sentence")
	assert_true(str(rows[1]["text"]).contains("$"), rows[1]["text"])


# ===========================================================================
# Wave 18 — the fix-target contract (PA-05) and the shared shapes (PA-75)
# ===========================================================================

## PA-05. `{kind, id}` was not a target: `POWER_CAPACITY` handed a TRANSFORMER id
## to a branch that resolved buildings by it, and `E_AVENUE` handed an empty id
## to a router that discards those on its first line. Two of the building panel's
## seven checklist rows drew a `Fix this →` that had never once moved anything.
## Every row now carries `params`, and this asserts the contract table in
## `RequirementFormatter`'s own class doc, row by row.
func test_every_fix_target_carries_the_params_its_kind_needs() -> void:
	var formatter := _fmt()
	var missing: Array[String] = []
	for code: StringName in RequirementFormatter.codes():
		var row := formatter.format(code, _params())
		var fix: Dictionary = row["fix_target"]
		assert_true(fix.has("params"), "%s has no params at all" % code)
		var kind := StringName(str(fix["kind"]))
		assert_true(RequirementFormatter.FIX_KINDS.has(kind),
				"%s routes an unknown kind %s" % [code, kind])
		var params: Dictionary = fix["params"]
		match kind:
			RequirementFormatter.FIX_NONE:
				assert_true(params.is_empty(), "%s: FIX_NONE draws no button" % code)
			RequirementFormatter.FIX_REPAIR, RequirementFormatter.FIX_POWER:
				assert_eq(str(params["verb"]),
						str(RequirementFormatter.FIX_VERBS[kind]),
						"%s: a purchase kind names the command it spends through" % code)
			RequirementFormatter.FIX_DISTRICT:
				assert_true(params.has("district_id"), "%s: no district" % code)
			RequirementFormatter.FIX_COMPONENT:
				assert_true(params.has("component"), "%s: no component" % code)
			_:
				# `FIX_TILE` is the strict one: the tile IS the target, so a row
				# that cannot supply one has nothing for the router to act on.
				if kind == RequirementFormatter.FIX_TILE and not params.has("tile"):
					missing.append(String(code))
	assert_true(missing.is_empty(),
			"FIX_TILE rows with no tile in params: %s" % ", ".join(missing))


## A tile the producer rendered into a string is copy, not a coordinate — and
## handing the router something it would have to parse is exactly how `E_AVENUE`
## shipped an empty id for three waves.
func test_fix_params_take_only_a_real_vector_tile() -> void:
	var formatter := _fmt()
	var typed := formatter.format(&"E_UNSERVED", {"tile": Vector2i(11, 7)})
	assert_eq((typed["fix_target"]["params"] as Dictionary)["tile"], Vector2i(11, 7))
	var stringy := formatter.format(&"E_UNSERVED", {"tile": "11, 7"})
	assert_false((stringy["fix_target"]["params"] as Dictionary).has("tile"),
			"a string is not a coordinate")
	# `fix_tile` wins over `tile`: `E_AVENUE` quotes the BUILDING's tile in its
	# sentence and routes to the AVENUE's.
	var split := formatter.format(&"E_AVENUE",
			{"tile": Vector2i(3, 3), "fix_tile": Vector2i(9, 9)})
	assert_eq(str(split["args"]["at"]), "3, 3", "the sentence names the building")
	assert_eq((split["fix_target"]["params"] as Dictionary)["tile"], Vector2i(9, 9),
			"and the button goes to the avenue")


## PA-75. The building panel's doc-02 ladder and the water block's doc-05 ladder
## ask for the same three rows, and they were written out twice. They had already
## drifted — `required_kw` carried the ×1.15 margin in one copy and not the other
## (PA-12) — so this asserts the two callers hand the formatter dictionaries that
## are equal key for key, which is the only thing that keeps them from drifting
## again.
func test_the_two_panels_build_identical_shared_params() -> void:
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	var controller := BuildController.new(sim, _fmt())
	var water := WaterActions.new(sim, _fmt())
	assert_eq(controller.headroom_margin(), water.headroom_margin(),
			"one margin, read from doc 02 §8 by both")
	var margin := controller.headroom_margin()
	var from_building := RequirementFormatter.power_headroom_params(
			120.0, 45.0, margin, "T-18")
	var from_water := RequirementFormatter.power_headroom_params(
			120.0, 45.0, margin, "T-18")
	assert_eq(from_building, from_water, "one shape, one place")
	assert_eq(float(from_building["required_kw"]), 120.0 * margin)
	assert_eq(float(from_building["headroom_kw"]), 120.0 * margin - 45.0)
	assert_eq(RequirementFormatter.funds_params(4200, 900),
			{"cost": 4200, "balance": 900})
	assert_eq(RequirementFormatter.level_params(3, 6), {"level": 3, "max_level": 6})


## PA-24 / PA-52: the four codes this wave gave doors to render sentences rather
## than their own identifiers. `E_WATER_HEADROOM` used to fold to UNKNOWN and
## print "Blocked by requirement E_WATER_HEADROOM…" at a player.
func test_the_wave_18_codes_render_english() -> void:
	var formatter := _fmt()
	for code: StringName in [&"E_WATER_HEADROOM", &"E_UNIT_UNAVAILABLE",
			&"E_UNREACHABLE", &"E_UNKNOWN_INCIDENT"]:
		assert_true(RequirementFormatter.is_known(code), String(code))
		var row := formatter.format(code, {"deficit_m3h": 4.0, "headroom_m3h": 1.0,
				"zone": "WTR-1-PMP", "unit": "Engine 3", "status": "on a call"})
		assert_false(str(row["body"]).contains(String(code)),
				"%s prints its own identifier at the player: %s" % [code, row["body"]])
		assert_true(str(row["title"]).length() > 0, String(code))
		assert_true(str(row["body"]).length() > 0, String(code))
	var water := formatter.format(&"E_WATER_HEADROOM", {"deficit_m3h": 4.0,
			"headroom_m3h": 1.0, "required_m3h": 5.0, "zone": "WTR-1-PMP",
			"fix_target_id": "WTR-1-PMP"})
	assert_true(str(water["body"]).contains("m³/h"), water["body"])
	assert_eq(str(water["fix_target"]["kind"]), String(RequirementFormatter.FIX_DISTRICT))
	assert_eq(str((water["fix_target"]["params"] as Dictionary)["district_id"]),
			"WTR-1-PMP")


## The `params` table is written **twice** — in this class's own doc and in doc
## 12 §2.7a — and both copies say they are normative. Two copies of a contract is
## the shape PA-75 filed on `_check_params`, where they had already drifted, and
## this lane drifted these two inside one wave: `FIX_BLOCK` gained `block_id` in
## the code and in doc 12 and not in the class doc.
##
## So the two are diffed here, kind by kind and key by key. Lane D's router reads
## the class doc; a reviewer reads doc 12; a disagreement between them is a
## contract with a hole in it whichever half is right.
func test_the_two_copies_of_the_params_contract_agree() -> void:
	var code_table := _contract_rows(
			FileAccess.get_file_as_string("res://ui/requirement_formatter.gd"), "## |")
	var doc_table := _contract_rows(
			FileAccess.get_file_as_string("res://docs/design/12-ui-ux.md"), "|")
	assert_eq(code_table.size(), RequirementFormatter.FIX_KINDS.size(),
			"the class doc lists every kind: %s" % [code_table.keys()])
	assert_eq(doc_table.size(), RequirementFormatter.FIX_KINDS.size(),
			"doc 12 s2.7a lists every kind: %s" % [doc_table.keys()])
	for kind: StringName in RequirementFormatter.FIX_KINDS:
		var row := "FIX_%s" % String(kind).to_upper()
		assert_true(code_table.has(row), "%s has no row in the class doc" % row)
		assert_true(doc_table.has(row), "%s has no row in doc 12 s2.7a" % row)
		assert_eq(code_table[row], doc_table[row],
				"%s: the class doc says %s and doc 12 s2.7a says %s"
				% [row, code_table[row], doc_table[row]])


## One markdown table row → the param KEYS its third cell names, sorted. The
## class doc's rows are the same markdown behind a `##`, which is why the prefix
## is a parameter and nothing else is.
func _contract_rows(source: String, prefix: String) -> Dictionary:
	var out: Dictionary = {}
	for raw: String in source.split("\n"):
		var line := raw.strip_edges()
		if not line.begins_with("%s `FIX_" % prefix):
			continue
		var cells := line.split("|")
		if cells.size() < 4:
			continue
		var kind := cells[1].strip_edges().replace("`", "")
		var params: Array[String] = []
		var body := cells[3]
		var open := body.find("{")
		var close := body.find("}", open + 1)
		if open >= 0 and close > open:
			for part: String in body.substr(open + 1, close - open - 1).split(","):
				var key := part.strip_edges()
				if key.contains(":"):
					key = key.substr(0, key.find(":"))
				key = key.strip_edges()
				if key != "":
					params.append(key)
		params.sort()
		out[kind] = params
	return out

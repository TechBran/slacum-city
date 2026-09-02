extends SimTest
## The copy audit (G-8, doc 12 §3.1). Three questions, asked of the whole project
## rather than of one screen:
##
##   1. **Does every key the code asks for exist?** A missing key renders as the
##      key — `ui_sheet_close` was shipping as the literal text `ui_sheet_close`
##      on the build sheet's ✕ until this scan found it.
##   2. **Is every key in the table asked for?** Dead copy is copy nobody
##      maintains, and it hides the live entry next to it in a diff.
##   3. **Does every `{placeholder}` have somebody to fill it?** The alerts feed's
##      `{units} crews are responding.` had no supplier anywhere, so the hole rule
##      deleted that sentence on every render — a whole clause of authored copy
##      that no player has ever seen and no test noticed.
##
## Plus the plural rule the formatter implements, because "1 blocks are dark" is
## the defect doc 12 §3.1 names by hand and a rule with no test is a rule that
## drifts.
##
## The scan is deliberately **source-driven**, not a hand-maintained list: it
## reads `ui/`, `game/` and `data/ui.json`, so a new screen with a new key is
## covered by being written, and a deleted screen's orphans surface on the next
## run.

## `res://sim` joined the scan with the construction roster (doc 02 §2.13,
## report 98 RR-109): `CitySim.construction_overview()` publishes a `title_key`
## per row — the seam contract makes the SIM the author of the noun, and `ui/`
## resolves it dynamically (`_t(row.title_key)`), so the five `ui_queue_title_*`
## keys are named by no line under `ui/` or `game/` and would read as orphans.
## `sim/` held exactly one `"ui_*"` literal before this (`ui_bands`, a forecast
## table field, not a key), so the widening changes no other verdict.
const SOURCE_DIRS: Array[String] = ["res://ui", "res://game", "res://sim"]
const STRINGS_PATH := "res://data/strings.en.json"
## Data files besides `data/ui.json` that NAME copy through `*_key` fields.
## `data/goals.json` (doc 09 §8.3) is the first: the curriculum's level titles
## and objective sentences live there, and nothing in `ui/` spells one out.
const DATA_KEY_FILES: Array[String] = ["res://data/goals.json"]

## Lookup idioms. A `ui_*` literal on a line that carries one of these is a
## string-table key; one anywhere else is an audio cue id, an observation kind or
## a node path, and none of those live in this file.
const LOOKUP_MARKERS: Array[String] = [
	".t(", "t_args(", "has_string(", "_text(", "_text_args(", "_resolve(",
	"_key", "template(",
]


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


# ===========================================================================
# The plural rule (doc 12 §3.1's `1 blocks are dark`)
# ===========================================================================

func test_a_count_of_one_takes_the_one_variant() -> void:
	var cfg := UIConfig.new({}, {
		"n_outage_major_title": "{count} blocks are dark",
		"n_outage_major_title_one": "{count} block is dark",
	})
	assert_eq(cfg.t("n_outage_major_title", {"count": 1}), "1 block is dark")
	assert_eq(cfg.t("n_outage_major_title", {"count": 2}), "2 blocks are dark")
	assert_eq(cfg.t("n_outage_major_title", {"count": 0}), "0 blocks are dark",
			"English pluralises zero")


func test_a_stringified_count_still_counts() -> void:
	# `RequirementFormatter` turns every argument into a String before it reaches
	# the table, so the rule has to read "1" as one.
	var cfg := UIConfig.new({}, {
		"ui_requirement_no_road": "nearest road is {have} tiles away.",
		"ui_requirement_no_road_one": "nearest road is {have} tile away.",
	})
	assert_eq(cfg.t("ui_requirement_no_road", {"have": "1"}),
			"nearest road is 1 tile away.")
	assert_eq(cfg.t("ui_requirement_no_road", {"have": "4"}),
			"nearest road is 4 tiles away.")


func test_a_template_with_two_numbers_names_its_selector() -> void:
	var strings := {
		"k": "Day {day} · {n} days passed",
		"k_one": "Day {day} · {n} day passed",
	}
	var ambiguous := UIConfig.new({}, strings)
	assert_eq(ambiguous.t("k", {"day": 3, "n": 1}), "Day 3 · 1 days passed",
			"two numbers and no declaration: the rule refuses to guess")
	strings["k_plural"] = "n"
	var declared := UIConfig.new({}, strings)
	assert_eq(declared.t("k", {"day": 3, "n": 1}), "Day 3 · 1 day passed")
	assert_eq(declared.t("k", {"day": 1, "n": 5}), "Day 1 · 5 days passed",
			"the other number does not govern the noun")


func test_non_numeric_arguments_never_trigger_a_plural() -> void:
	var cfg := UIConfig.new({}, {
		"k": "{district} lost {n} feeders",
		"k_one": "{district} lost {n} feeder",
	})
	assert_eq(cfg.t("k", {"district": "Harbour", "n": 1}), "Harbour lost 1 feeder")
	assert_eq(cfg.t("k", {"district": "1", "n": 3}), "1 lost 3 feeders",
			"a district that happens to be named '1' is not a count")


func test_a_key_with_no_one_variant_is_untouched() -> void:
	var cfg := UIConfig.new({}, {"k": "{n} unread"})
	assert_eq(cfg.t("k", {"n": 1}), "1 unread")


func test_a_missing_key_still_returns_the_key() -> void:
	assert_eq(UIConfig.new({}, {}).t("ui_nope"), "ui_nope",
			"doc 12 test 21: a copy hole is loud, not blank")


func test_placeholders_are_listed_in_order_without_repeats() -> void:
	assert_eq(UIConfig.placeholders("{a} and {b} and {a}"),
			PackedStringArray(["a", "b"]))


# ===========================================================================
# The table itself
# ===========================================================================

func test_every_plural_variant_is_well_formed() -> void:
	var cfg := _cfg()
	var strings := cfg.strings_data()
	for key: String in strings:
		if not key.ends_with(UIConfig.PLURAL_ONE_SUFFIX):
			continue
		var base := key.trim_suffix(UIConfig.PLURAL_ONE_SUFFIX)
		assert_true(strings.has(base), "%s has a base key" % key)
		if not strings.has(base):
			continue
		var base_names := UIConfig.placeholders(str(strings[base]))
		var one_names := UIConfig.placeholders(str(strings[key]))
		assert_eq(one_names, base_names,
				"%s carries the same arguments as its plural form" % key)
		# The selector has to be *decidable*: one number in the template, or a
		# declaration. Anything else is a rule that silently never fires.
		var declared: Variant = strings.get(base + UIConfig.PLURAL_ARG_SUFFIX, null)
		if declared is String:
			assert_true(base_names.has(declared),
					"%s%s names an argument the template carries"
					% [base, UIConfig.PLURAL_ARG_SUFFIX])
		else:
			assert_eq(base_names.size(), 1,
					"%s has one placeholder, or %s%s must say which one governs"
					% [base, base, UIConfig.PLURAL_ARG_SUFFIX])


func test_every_plural_declaration_belongs_to_a_variant() -> void:
	var strings := _cfg().strings_data()
	for key: String in strings:
		if not key.ends_with(UIConfig.PLURAL_ARG_SUFFIX):
			continue
		var base := key.trim_suffix(UIConfig.PLURAL_ARG_SUFFIX)
		assert_true(strings.has(base + UIConfig.PLURAL_ONE_SUFFIX),
				"%s declares a selector for a variant that exists" % key)


func test_every_key_the_code_asks_for_exists() -> void:
	var cfg := _cfg()
	var missing: PackedStringArray = []
	for key: String in _referenced_keys():
		if not cfg.has_string(key):
			missing.append(key)
	assert_eq(str(missing), "[]",
			"data/strings.en.json carries every key the code looks up")


func test_every_key_in_the_table_is_reachable() -> void:
	# Reachable means: named outright, built by a `"prefix_%s" % x` family, or a
	# plural satellite of something that is. An orphan is copy the game cannot
	# show, and the next person to edit the file cannot tell it apart from copy
	# that merely has no test.
	var cfg := _cfg()
	var literal := _mentioned_keys()
	var families := _referenced_families()
	var orphans: PackedStringArray = []
	for key: String in cfg.strings_data():
		if key.begins_with("_") or key == "schema_version":
			continue
		if _is_reachable(key, literal, families, cfg.strings_data()):
			continue
		orphans.append(key)
	assert_eq(str(orphans), "[]", "no orphaned copy in data/strings.en.json")


# ===========================================================================
# Placeholders and their suppliers
# ===========================================================================

func test_every_notification_placeholder_has_a_supplier() -> void:
	# The `n_*` family is the one whose arguments are fully declared in data:
	# `data/ui.json.event_log.events[].args` maps each `{name}` to where it comes
	# from. Anything a template asks for and no rule supplies is a sentence the
	# hole rule will delete for ever.
	#
	# **This test read `alerts.events` until Wave 12 and was therefore VACUOUS.**
	# `data/ui.json.alerts` holds the panel's geometry — `max_entries`,
	# `row_h_dp`, `coalesce_window_s` — and has never had an `events` array; the
	# rows live under `event_log`. `raw` came back `[]`, `supplied` stayed empty,
	# every `n_*` key hit the `continue` below, and the method made **zero
	# assertions** while counting as a passing test. It was found the day
	# `tests/run_tests.gd` learned to fail a method that never asserts, which is
	# the entire argument for that guard: nothing else in the suite can see the
	# difference between a test that holds and a test that is not there.
	var cfg := _cfg()
	var strings := cfg.strings_data()
	var supplied: Dictionary = {}
	var raw: Variant = cfg.section("event_log").get("events", [])
	assert_false((raw as Array if raw is Array else []).is_empty(),
			"data/ui.json.event_log.events must exist — an empty supplier table "
			+ "makes every assertion below unreachable, which is exactly how "
			+ "this test spent its first waves")
	for entry: Variant in (raw as Array if raw is Array else []):
		var rule: Dictionary = entry
		var notify_id := str(rule.get("notify_id", ""))
		var args: Variant = rule.get("args", {})
		var names: Dictionary = supplied.get(notify_id, {})
		for name: String in (args as Dictionary if args is Dictionary else {}):
			names[name] = true
		supplied[notify_id] = names
	for key: String in strings:
		if not key.begins_with("n_"):
			continue
		var body := key.trim_suffix("_title").trim_suffix("_body").trim_suffix(
				UIConfig.PLURAL_ONE_SUFFIX)
		if not supplied.has(body):
			continue
		for name: String in UIConfig.placeholders(str(strings[key])):
			assert_true((supplied[body] as Dictionary).has(name),
					"%s asks for {%s}; data/ui.json.event_log.events supplies it"
					% [key, name])


func test_every_requirement_placeholder_has_a_supplier() -> void:
	# `RequirementFormatter._args_for` is the only supplier for this family, and it
	# will happily produce a row for a code whose template asks for something it
	# never builds — which renders as a literal `{at}` in the checklist.
	var cfg := _cfg()
	var formatter := RequirementFormatter.new(cfg)
	var strings := cfg.strings_data()
	for code: StringName in RequirementFormatter.codes():
		var args: Dictionary = formatter.format(code, {})["args"]
		for suffix: String in ["", RequirementFormatter.TITLE_SUFFIX,
				RequirementFormatter.REMEDY_SUFFIX]:
			var key := RequirementFormatter.string_key(code, suffix)
			for variant: String in [key, key + UIConfig.PLURAL_ONE_SUFFIX]:
				if not strings.has(variant):
					continue
				for name: String in UIConfig.placeholders(str(strings[variant])):
					assert_true(args.has(name),
							"%s asks for {%s}; RequirementFormatter supplies it"
							% [variant, name])


# ===========================================================================
# Source scanning
# ===========================================================================

## Keys the code **looks up**: a literal on a GDScript line that performs a
## lookup, plus every `*_key` field in `data/ui.json`, where the onboarding steps
## and the overlay strip name their copy as data. Narrow on purpose — a `ui_*`
## literal elsewhere is an audio cue id (`ui_tap`) or an observation kind
## (`ui_opened`), and neither belongs in the string table.
func _referenced_keys() -> PackedStringArray:
	var out: PackedStringArray = []
	var regex := RegEx.new()
	regex.compile("\"((?:ui|n)_[a-z0-9_]+)\"")
	for path: String in _source_files():
		for line: String in FileAccess.get_file_as_string(path).split("\n"):
			if not _is_lookup(line):
				continue
			for match in regex.search_all(line):
				var key := match.get_string(1)
				if not out.has(key):
					out.append(key)
	_collect_data_keys(UIConfig.load_from_files().ui_data(), out)
	# `data/goals.json` names copy the same way (doc 09 §8.3): every curriculum
	# level and every objective carries `*_key` fields and no GDScript source
	# ever spells one out. Without this the whole `ui_goal_*` / `ui_level_*`
	# family reads as orphaned and the orphan check would delete live copy.
	for path: String in DATA_KEY_FILES:
		_collect_data_keys(StarterCityLoader.read_json(path), out)
	return out


## Keys the code **mentions**, anywhere: the same literals without the lookup
## filter. A key passed through a helper (`_action_button(…, "ui_saves_save", …)`)
## or stored in a table is used, even though its own line performs no lookup —
## the orphan check has to see those or it deletes live copy.
func _mentioned_keys() -> PackedStringArray:
	var out := _referenced_keys()
	var regex := RegEx.new()
	regex.compile("\"((?:ui|n)_[a-z0-9_]+)\"")
	for path: String in _source_files():
		for match in regex.search_all(FileAccess.get_file_as_string(path)):
			var key := match.get_string(1)
			if not out.has(key):
				out.append(key)
	return out


static func _is_lookup(line: String) -> bool:
	for marker: String in LOOKUP_MARKERS:
		if line.contains(marker):
			return true
	return false


## `data/ui.json` names copy through fields called `*_key` and nothing else, so
## the walk keys off the field name rather than off the value's shape — an
## `advance.kind` of `ui_opened` is a step condition, not a string.
static func _collect_data_keys(value: Variant, out: PackedStringArray,
		field: String = "") -> void:
	if value is Dictionary:
		for key: Variant in (value as Dictionary):
			_collect_data_keys((value as Dictionary)[key], out, str(key))
	elif value is Array:
		for entry: Variant in (value as Array):
			_collect_data_keys(entry, out, field)
	elif value is String and field.ends_with("_key") and not out.has(value):
		out.append(value)


## The families a literal scan cannot see:
##   * `"ui_settings_row_%s" % key` and `"n_%s_title" % notify_id` — an id spliced
##     into a template;
##   * `"ui_requirement_" + code.to_lower()` — a prefix constant concatenated,
##     recognised by the trailing underscore that makes it a prefix.
## Each entry is `[prefix, suffix]`.
func _referenced_families() -> Array:
	var out: Array = []
	var spliced := RegEx.new()
	spliced.compile("\"((?:ui|n)_[a-z0-9_]*)%s([a-z0-9_]*)\"")
	# `"ui_budget_%s_%s"` splices twice; only its prefix is knowable statically.
	var loose := RegEx.new()
	loose.compile("\"((?:ui|n)_[a-z0-9_]*)%s")
	var prefix := RegEx.new()
	prefix.compile("\"((?:ui|n)_[a-z0-9_]*_)\"")
	for path: String in _source_files():
		var src := FileAccess.get_file_as_string(path)
		for match in spliced.search_all(src):
			_add_family(out, [match.get_string(1), match.get_string(2)])
		for match in loose.search_all(src):
			_add_family(out, [match.get_string(1), ""])
		for match in prefix.search_all(src):
			_add_family(out, [match.get_string(1), ""])
	# `data/ui.json` builds keys too: the event log's `@lookup:<prefix>:<field>`
	# argument form (see EventLogModel.ARG_LOOKUP_PREFIX) makes every key under
	# <prefix> reachable, and no GDScript source ever names them.
	var lookup := RegEx.new()
	lookup.compile("@lookup:((?:ui|n)_[a-z0-9_]*):")
	var ui_json := FileAccess.get_file_as_string("res://data/ui.json")
	for match in lookup.search_all(ui_json):
		_add_family(out, [match.get_string(1), ""])
	return out


static func _add_family(out: Array, pair: Array) -> void:
	if not out.has(pair):
		out.append(pair)


static func _is_reachable(key: String, literal: PackedStringArray, families: Array,
		strings: Dictionary) -> bool:
	if literal.has(key):
		return true
	for pair: Array in families:
		var prefix: String = pair[0]
		var suffix: String = pair[1]
		if key.begins_with(prefix) and key.ends_with(suffix) \
				and key.length() > prefix.length() + suffix.length():
			return true
	for satellite: String in [UIConfig.PLURAL_ONE_SUFFIX, UIConfig.PLURAL_ARG_SUFFIX]:
		if key.ends_with(satellite) and strings.has(key.trim_suffix(satellite)):
			return _is_reachable(key.trim_suffix(satellite), literal, families, strings)
	return false


func _source_files() -> PackedStringArray:
	var out: PackedStringArray = []
	for dir_path: String in SOURCE_DIRS:
		_walk_dir(dir_path, out)
	return out


static func _walk_dir(dir_path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := "%s/%s" % [dir_path, entry]
		if dir.current_is_dir():
			_walk_dir(full, out)
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()

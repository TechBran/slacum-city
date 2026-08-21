extends SceneTree
## **The instrument for a save→load determinism defect** (report 98 §26 RR-60,
## doc 91 A91-D-30). It reflection-walks every member of every live object under
## a named `CitySim` field, on a LIVE city and on its RESTORED twin, and prints
## what differs — **before either city advances a tick**, which is the whole
## point.
##
## §26's ruling, mechanised: *the first field to MOVE is not the field that is
## wrong.* Diff two cities after advancing and what you see is whichever
## coordinate amplifies fastest — for three waves that was the cosmetic traffic
## feed, and it sent a defect report to the wrong subsystem. Diff them at rest
## and you see the seed. All three defects §26 closes were invisible in the save
## BODY (which was byte-identical every time) and obvious in the live objects.
##
## What it compares, and why each choice matters:
##   * **dictionary KEY ORDER as well as values** — `state_hash` stringifies to
##     JSON, so insertion order is part of the answer;
##   * **floats with `is_same`, never a tolerance** — the defect it was written
##     for was one ULP, and every tolerance in the project would have passed it;
##   * **int-vs-float typing only when the numbers are EQUAL** — that much is
##     genuinely normalised by the hash's JSON round trip, and reporting the
##     type without checking the value hid a real divergence once;
##   * a per-field CENSUS rather than a list, because a real difference is
##     usually 600 rows of one field.
##
## Not a test — a microscope. `tests/test_save_determinism_days.gd` is the gate.
##
##   godot --headless --script tools/diff_restore.gd -- \
##       [--seed=8191] [--hours=24] [--advance=2] [--root=roads|water|incidents|…]
##       [--city=res://tests/fixtures/bench_city.json] [--coarse] [--storm]
##
## `--coarse` ages the city on the offline catch-up path instead of the fine one;
## `--storm` reproduces the mid-incident, mid-flood fixture (a storm injected
## across the save point and doc 04's tutorial transformer failed under it),
## which is the shape that exposed the signal-power defect and nothing else did.

const SKIP_KEYS: Array[String] = ["_events"]
## Lazily-settled bookkeeping that is not state: it is recomputed on demand and
## cannot differ once anything asks. Suppressed so the real signal is visible.
const NOISE: Array[String] = ["component_id", "_components", "_components_dirty",
	"_order_dirty", "_tiles_sorted", "_tiles_sorted_version", "graph_version",
	"last_retraced_tiles", "dark_signals"]


func _init() -> void:
	var seed_value := 8191
	var hours := 24.0
	var advance := 1.0
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg.begins_with("--hours="):
			hours = float(arg.substr(8))
		elif arg.begins_with("--advance="):
			advance = float(arg.substr(10))
		elif arg.begins_with("--root="):
			root_name = arg.substr(7)
		elif arg.begins_with("--city="):
			city_path = arg.substr(7)
	print("seed=%d hours=%s advance=%s" % [seed_value, hours, advance])

	var live := _boot(seed_value)
	if OS.get_cmdline_user_args().has("--storm"):
		# `tests/test_save_chunked_restore.gd`'s mid-incident, mid-flood fixture:
		# a storm across the save point and a transformer down under it.
		live.advance_hours(3.0)
		live.weather.inject_storm(live.clock.abs_minutes() + 40, 180, 0.77, 4242)
		live.trigger_tutorial_transformer_failure()
		live.advance_hours(maxf(0.0, hours - 3.0))
	elif OS.get_cmdline_user_args().has("--coarse"):
		live.advance_coarse_hours(int(hours))
	else:
		live.advance_hours(hours)
	var body := live.capture_state()
	var encoded: Variant = CitySim._encode_floats(body)

	var restored := _boot(seed_value)
	restored.restore_state(encoded)

	if OS.get_cmdline_user_args().has("--patch-water"):
		# **The A/B that turned a hypothesis into a root cause** (report 98 §26
		# RR-60), kept because a claim about a cause is worth exactly the
		# experiment that isolates it. Hand the restored city the LIVE water zone
		# sums and change nothing else: if the divergence goes away, those sums
		# were the seed and everything downstream of them was a symptom.
		restored.water.demand.zone_res = live.water.demand.zone_res.duplicate()
		restored.water.demand.zone_com = live.water.demand.zone_com.duplicate()
		restored.water.demand.zone_proc = live.water.demand.zone_proc.duplicate()
		restored.water.demand.zone_count = live.water.demand.zone_count.duplicate()
		restored.water.demand.publish(restored.water.topology)
		print("patched water zone sums")
	print("state_hash live=%s restored=%s  match=%s" % [
			live.state_hash().substr(0, 16), restored.state_hash().substr(0, 16),
			live.state_hash() == restored.state_hash()])

	var diffs := _compare_roads(live, restored)
	print("--- AT REST: %d differing paths ---" % diffs.size())
	_report(diffs)

	live.advance_hours(advance)
	restored.advance_hours(advance)
	print("state_hash after +%s h  live=%s restored=%s  match=%s" % [advance,
			live.state_hash().substr(0, 16), restored.state_hash().substr(0, 16),
			live.state_hash() == restored.state_hash()])
	var after := _compare_roads(live, restored)
	print("--- AFTER: %d differing paths ---" % after.size())
	_report(after)

	var body_diff: Array = []
	_compare_value("body", live.capture_state(), restored.capture_state(), body_diff, -9)
	print("--- AFTER, capture_state(): %d differing paths ---" % body_diff.size())
	var real: Array = []
	for entry in body_diff:
		if not String(entry).contains(": TYPE "):
			real.append(entry)
	print("    (%d of them are real; int/float typing is normalised by state_hash)" % real.size())
	for i in mini(40, real.size()):
		print("   * ", real[i])
	quit()


## Collapse indices so one differing FIELD prints as one line with a census.
func _report(diffs: Array) -> void:
	var buckets: Dictionary = {}
	var regex := RegEx.new()
	regex.compile("\\[[^\\]]*\\]")
	for entry in diffs:
		var text := String(entry)
		var head := text.split(": ")[0]
		var shape := regex.sub(head, "[*]", true)
		var row: Dictionary = buckets.get(shape, {"n": 0, "eg": text})
		row["n"] = int(row["n"]) + 1
		buckets[shape] = row
	for shape in buckets:
		print("  %5d × %s" % [int(buckets[shape]["n"]), shape])
		print("          e.g. ", buckets[shape]["eg"])


var root_name: String = "roads"
var city_path: String = ""


func _boot(seed_value: int) -> CitySim:
	if city_path == "":
		return CitySim.boot_from_files(seed_value)
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city_path),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	return sim


func _compare_roads(a: CitySim, b: CitySim) -> Array:
	var out: Array = []
	_compare_object(root_name, a.get(root_name), b.get(root_name), out, 0)
	return out


func _compare_object(path: String, a: Object, b: Object, out: Array, depth: int) -> void:
	if depth > 3:
		return
	for entry in a.get_property_list():
		var record: Dictionary = entry
		if int(record["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var key := String(record["name"])
		if SKIP_KEYS.has(key):
			continue
		_compare_value("%s.%s" % [path, key], a.get(key), b.get(key), out, depth)


func _compare_value(path: String, a: Variant, b: Variant, out: Array, depth: int) -> void:
	if out.size() > 40000:
		return
	# Only while walking LIVE OBJECTS (depth >= 0). The saved body is compared
	# whole — a key called `component_id` in the power section is not the road
	# graph's lazily-settled one, and suppressing it there would hide a real diff.
	if depth >= 0:
		for noise in NOISE:
			if path.ends_with("." + noise) or path.ends_with("[%s]" % noise):
				return
	var ta := typeof(a)
	var tb := typeof(b)
	if ta != tb:
		# int-vs-float typing is what `state_hash`'s JSON round-trip normalises, so
		# it is noise — but ONLY when the two numbers are equal. Reporting the type
		# and returning without looking at the value hid a real divergence once.
		if (ta == TYPE_INT or ta == TYPE_FLOAT) and (tb == TYPE_INT or tb == TYPE_FLOAT):
			if not is_same(float(a), float(b)):
				out.append(path + ": NUMERIC " + String.num(a, 17) + " vs "
						+ String.num(b, 17))
			else:
				out.append("%s: TYPE %d vs %d" % [path, ta, tb])
			return
		out.append("%s: TYPE %d vs %d" % [path, ta, tb])
		return
	match ta:
		TYPE_OBJECT:
			if a == null or b == null:
				if a != b:
					out.append("%s: null mismatch" % path)
				return
			if a is Callable or a is RandomNumberGenerator:
				return
			_compare_object(path, a, b, out, depth + 1)
		TYPE_DICTIONARY:
			var da: Dictionary = a
			var db: Dictionary = b
			var ka := da.keys()
			var kb := db.keys()
			if ka.size() != kb.size():
				out.append("%s: dict size %d vs %d" % [path, ka.size(), kb.size()])
			for i in mini(ka.size(), kb.size()):
				if str(ka[i]) != str(kb[i]):
					out.append("%s: key order @%d %s vs %s" % [path, i, ka[i], kb[i]])
					break
			for key in ka:
				if not db.has(key):
					out.append("%s[%s]: missing on B" % [path, key])
					continue
				_compare_value("%s[%s]" % [path, key], da[key], db[key], out, depth)
		TYPE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, \
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_FLOAT32_ARRAY:
			var aa: Array = []
			var ab: Array = []
			aa.assign(a)
			ab.assign(b)
			if aa.size() != ab.size():
				out.append("%s: array size %d vs %d" % [path, aa.size(), ab.size()])
			for i in mini(aa.size(), ab.size()):
				_compare_value("%s[%d]" % [path, i], aa[i], ab[i], out, depth)
		TYPE_FLOAT:
			if not is_same(float(a), float(b)):
				out.append(path + ": " + String.num(a, 17) + " vs " + String.num(b, 17)
						+ "  (rel " + String.num(absf(float(a) - float(b))
						/ maxf(1e-300, absf(float(a))), 4) + ")")
		_:
			if a != b:
				out.append("%s: %s vs %s" % [path, a, b])

extends SceneTree
## **The A/B that isolates Wave 25's hash delta to its own four key groups.**
##
## `tools/profile_sim.gd --hash-only` says the four determinism baselines MOVED.
## This says WHY, and it says it as an identity rather than as a story: it
## reproduces `profile_sim`'s exact two advances on both cities, then digests the
## canonical body **with doc 03 §2.8b's four additions stripped out, one group at
## a time**. The fully stripped digest must equal the FORK's published baseline,
## which is the strongest statement available — not "we think only these moved"
## but "with these removed the city is byte-identical to the one before them".
##
## The four groups, in strip order (report 98 §69.3, doc 92 §66.6):
##
##   1  `rng.land_works`                             — the tenth named stream
##   2  `treasury.ledger_totals.lifetime_excavation`
##      + `treasury.hour_city_services.excavation`   — doc 03 §2.5's sub-grain
##   3  `works_stockpile`                            — the materials yard
##   4  `works_yield_total` on every `world_blocks` row
##
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/ab_land_works.gd -- [--seed=1337] [--fork=A,B,C,D]
##
## `--fork` takes the four fork digests in the order
## `starter coarse, starter fine, bench coarse, bench fine`; with it the tool
## exits non-zero unless every stripped digest matches. Without it, it prints.
##
## Like every `tools/*` instrument it boots the real `CitySim`, drives the real
## scheduler, owns no constant, and nothing in `sim/`, `game/` or `ui/` imports it.

const STARTER := "res://data/starter_city.json"
const BENCH := "res://tests/fixtures/bench_city.json"
const COARSE_HOURS := 24
const FINE_HOURS := 2.0

const GROUPS: Array[String] = ["rng.land_works", "treasury.excavation",
		"works_stockpile", "world_blocks.works_yield_total"]


func _initialize() -> void:
	var seed_value := 1337
	var fork: Array[String] = []
	for raw: Variant in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg.begins_with("--fork="):
			for part in arg.substr(7).split(",", false):
				fork.append(String(part).strip_edges())

	var ok := true
	var index := 0
	for city: String in [STARTER, BENCH]:
		for coarse: bool in [true, false]:
			var label := "%s %s" % ["starter" if city == STARTER else "bench",
					"coarse 24h" if coarse else "fine 2.0h"]
			var body := _body(city, seed_value, coarse)
			print("\n== %s ==" % label)
			print("  full                          %s" % _digest(body))
			for group: String in GROUPS:
				_strip(body, group)
				print("  less %-25s %s" % [group, _digest(body)])
			var stripped := _digest(body)
			if index < fork.size():
				var want := String(fork[index])
				var hit := stripped.begins_with(want) or want.begins_with(stripped)
				print("  fork baseline                 %s  -> %s"
						% [want, "MATCH" if hit else "MISMATCH"])
				ok = ok and hit
			index += 1
	if not fork.is_empty() and not ok:
		printerr("ab_land_works: a stripped body does NOT match its fork baseline —"
				+ " this lane moved something outside its own four key groups")
		quit(1)
		return
	quit(0)


func _body(city: String, seed_value: int, coarse: bool) -> Dictionary:
	var sim := _boot(city, seed_value)
	if coarse:
		sim.advance_coarse_hours(COARSE_HOURS)
	else:
		sim.advance_hours(FINE_HOURS)
	var body := sim.canonical_capture()
	sim.dispose()
	return body


## `profile_sim._boot`, verbatim in effect: the starter city takes the short
## path, anything else takes the same five data files with the city swapped.
func _boot(city: String, seed_value: int) -> CitySim:
	if city == STARTER:
		return CitySim.boot_from_files(seed_value)
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	if not sim.boot_errors.is_empty():
		printerr("ab_land_works: %d boot error(s) from %s" % [sim.boot_errors.size(), city])
	return sim


static func _strip(body: Dictionary, group: String) -> void:
	match group:
		"rng.land_works":
			(body.get("rng", {}) as Dictionary).erase("land_works")
		"treasury.excavation":
			var treasury: Dictionary = body.get("treasury", {})
			(treasury.get("ledger_totals", {}) as Dictionary).erase("lifetime_excavation")
			(treasury.get("hour_city_services", {}) as Dictionary).erase("excavation")
		"works_stockpile":
			body.erase("works_stockpile")
		"world_blocks.works_yield_total":
			for entry: Variant in (body.get("world_blocks", []) as Array):
				(entry as Dictionary).erase("works_yield_total")


## `CitySim.state_hash()`'s own digest, over a body this tool has edited.
static func _digest(body: Dictionary) -> String:
	var normalized: Variant = JSON.parse_string(JSON.stringify(body, "", true, true))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(JSON.stringify(normalized, "", true, true).to_utf8_buffer())
	return ctx.finish().hex_encode()

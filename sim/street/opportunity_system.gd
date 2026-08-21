class_name OpportunitySystem
extends RefCounted
## Doc 06 §2.16 — THE OPPORTUNITY LAYER: tappable street events that pay.
##
## **Why it exists,** in the player's own words after the Wave-13 playtest: *"on
## the street, we should have an animation of humans that are committing crimes
## that aren't being picked up by the police station, and animals that maybe
## have gotten on the loose — need to collect them. And these should definitely
## pay you money. So there's not a lot of downtime of absolutely nothing to do."*
##
## Everything above that sentence in this project is a system the player SETS UP
## and then watches settle: a fire answers itself, a tax rate pays out on the
## hour, a block develops over game-days. None of it rewards LOOKING at the city.
## This does. Three kinds of thing appear on the kerb, live for two to four real
## minutes, and pay a bounty to whoever taps them:
##
##   * **petty_crime** — a crook, weighted toward tiles where doc 02 §2.9's
##     `coverage_police` is weak. It is the gameplay hook the player named: the
##     crime the station did not answer is the one you can answer yourself.
##   * **loose_animal** — a dog or a goat, weighted toward residential frontage.
##   * **lost_valuables** — rare, flat-weighted, short-lived, pure cash.
##
## ── the three rules that keep it honest ───────────────────────────────────
##
## **1. It is a FINE-PATH system.** `advance_coarse` expires and never spawns,
## and draws NOTHING from the `street` stream. That is doc 08's offline fairness
## rule expressed where it is enforceable rather than as a policy somebody has to
## remember: opportunities are the play-NOW layer, so a player who was away finds
## the street exactly as empty as they left it and is owed nothing. It also means
## the balance matrix — which runs the coarse step (`tests/balance_matrix.gd`) —
## is bit-identical to the day before this file existed, which is the property
## `do_nothing` is measured on.
##
## **2. Nothing spawns VALUE.** A live opportunity is not money; a TAP is money.
## Until `CitySim.cmd_collect_opportunity` runs, this system has changed no
## treasury, no district, no building and no other stream — it is a roster of
## offers with an expiry, and an agent that never taps (every strategy in
## `tools/playtest.gd`) reaches the same city it always did.
##
## **3. The whole roster persists.** A save taken mid-crook restores the crook —
## same id, same tile, same kerb, same dollars, same expiry — because a bounty
## the player was walking toward and lost to a phone call is exactly the kind of
## small theft that makes a save feel unsafe. City section rung v7 (doc 08 §2.8).
##
## Deterministic by construction: one named stream (`street`, constitution §5),
## no clock, no wall time, sorted iteration everywhere, and every float that
## reaches a save is written through `CitySim`'s `~f~` encoder.

## The three kinds v1 ships. Order is the DRAW order — `_pick_kind` walks it —
## so it is a contract, not a list: reordering it would re-associate the stream.
const KIND_PETTY_CRIME := &"petty_crime"
const KIND_LOOSE_ANIMAL := &"loose_animal"
const KIND_LOST_VALUABLES := &"lost_valuables"
const KINDS: Array[StringName] = [
	KIND_PETTY_CRIME, KIND_LOOSE_ANIMAL, KIND_LOST_VALUABLES,
]

## Constitution §5's named stream for this system, and the only one it touches.
const STREAM_NAME := "street"

## C-07 / RR-85: `data/street.json` may carry no dollar, at any depth.
##
## The layer shipped with its reward columns in its own file and doc 03
## publishing a second, dead set beside them — one feature, two price tables,
## and the live one was not the one the balance gates read. The columns moved to
## `data/economy.json`'s `city_services.street_payout` at the same values, and
## these two keys are refused on the way back in so the second source of truth
## cannot quietly reappear. It is the same guard `IncidentCatalog.FORBIDDEN_KEYS`
## puts on `reward_base`, and it fails the BOOT rather than a report six weeks
## later.
const FORBIDDEN_KEYS: Array[String] = ["reward", "reward_city_level_k"]

## N, E, S, W — the same order and the same meaning as
## `StreetlightPlacer.DIRS` / `RoadSurfaceView.DIRS`, declared locally because
## `sim/` may not read `game/` (constitution §3). A row's `side` indexes this,
## so a renderer that stands an actor on `side` stands it on the footway the
## kerb classification found and not in a traffic lane.
const DIRS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
]

## `data/street.json`, whole. Never authored here (constitution: no magic
## numbers in code); the fallbacks below exist only so a fixture-built system
## behaves before `configure()`.
var target_interval_h: float = 1.5
var max_live: int = 4
var min_separation_tiles: float = 5.0
## Set by `CitySim` from the phase adapter's OWN cadence, never authored: the
## per-evaluation probability is `eval_period_h / target_interval_h`, and a
## hand-written period that drifted from the cadence would silently re-rate the
## whole layer. See `CitySim._boot_street`.
var eval_period_h: float = 1.0 / 60.0
var _kinds: Dictionary = {}  # StringName -> normalised row

## Doc 03 §2.5's price table, the ONLY place this system's dollars come from
## (RR-85). Held rather than resolved through a `Callable` because unlike the
## four seams below it is not a view of the live city — it is a parsed data
## file that outlives every tick and holds no reference back to `CitySim`, so
## there is no cycle for `dispose()` to break. Null in a fixture that never
## bound one, which is why `_reward_for` still draws its `u`.
var payouts: CostCurves = null

## Boot errors, drained into `CitySim.boot_errors` (`_boot_street`). A file that
## carries a price back, or a kind that no price table names, is a boot error and
## not a fallback: a city that quietly paid $0 for every crook because a row was
## missing would look like a balance finding for a wave before anyone found it.
var errors: PackedStringArray = []

# ------------------------------------------------------------------ the world
# Set once at boot. `sim/street/` knows the tile grid and the road graph (both
# doc 09 / doc 10, both `sim/`) directly, and asks for everything else through a
# Callable so this class needs no reference to `CitySim` — the same shape
# `WaterSystem.powered_provider` uses.

var grid: TileGrid = null
var graph: RoadGraph = null
## `func(tile: Vector2i) -> float` — doc 02 §2.9's `coverage_police`, published
## by `CityIncidentWorld` (report 98 C-51). Asked ONCE per spawn.
var coverage_police: Callable = Callable()
## `func() -> Dictionary` — grid building id -> true for every RESIDENTIAL
## building in the roster. Asked once per candidate-index rebuild.
var residential_ids: Callable = Callable()
## `func() -> int` — `CitySim.roster_revision`, half of the memo key below.
var roster_revision: Callable = Callable()
## `func() -> int` — doc 09 §2.11's city level, the reward's growth term.
var city_level: Callable = Callable()

# ------------------------------------------------------------------- the state

## Live offers, ASCENDING BY ID and kept that way — ids are issued in order and
## removal preserves order, so every walk (expiry, serialisation, the renderer's
## feed) sees the same sequence.
var _live: Array[Dictionary] = []
var _next_id: int = 1
var _events: Array[Dictionary] = []
## The `street` stream, held from `bind_stream`. Null in a fixture that never
## bound one, which is why every draw site tests it.
var _rng: RandomNumberGenerator = null

## DERIVED: the kerb tiles, memoised on `(graph_version, roster_revision)`.
## Never captured, never restored, rebuilt on demand — a restored city rebuilds
## the identical list from the identical grid, graph and roster, which is what
## makes save → load → advance bit-identical.
var _candidates: Array = []
var _candidate_key := Vector2i(-1, -1)


func _init(table: Dictionary = {}) -> void:
	if not table.is_empty():
		configure(table)


## `data/street.json`, whole. Unknown kinds are DROPPED rather than crashing a
## city (the same rule doc 09 §8.3's curriculum parses under), so a table that
## names a fourth kind before the code knows one still boots.
##
## A dollar anywhere in the table is NOT dropped — it is an error (`FORBIDDEN_KEYS`).
func configure(table: Dictionary) -> void:
	errors = PackedStringArray()
	_assert_no_prices(table)
	var spawn: Dictionary = table.get("spawn", {})
	target_interval_h = maxf(0.000001, float(spawn.get("target_interval_h",
			target_interval_h)))
	max_live = maxi(0, int(spawn.get("max_live", max_live)))
	min_separation_tiles = maxf(0.0, float(spawn.get("min_separation_tiles",
			min_separation_tiles)))
	_kinds = {}
	var rows: Dictionary = table.get("kinds", {})
	for kind: StringName in KINDS:
		var raw: Variant = rows.get(String(kind), null)
		if raw is Dictionary:
			_kinds[kind] = _normalise_kind(raw as Dictionary)


## Doc 03 §2.5's price table, bound after `configure()` so the kind roster it
## checks is the parsed one. Every kind this file names must be PRICED — an
## unpriced one is a boot error, not a free crook.
func bind_payouts(curves: CostCurves) -> void:
	payouts = curves
	if curves == null:
		return
	for kind: StringName in KINDS:
		if not _kinds.has(kind):
			continue
		if not curves.has_street_payout(String(kind)):
			errors.append(("data/street.json names kind `%s` and "
					+ "data/economy.json city_services.street_payout prices no "
					+ "row for it (RR-85)") % String(kind))


## Recursive, because a price that came back would come back somewhere. Mirrors
## `IncidentCatalog._assert_clean`, deliberately down to the shape of the
## message: two files, one rule, one way to read the failure.
func _assert_no_prices(value: Variant) -> void:
	match typeof(value):
		TYPE_DICTIONARY:
			for key: Variant in (value as Dictionary):
				var key_text := String(key)
				if FORBIDDEN_KEYS.has(key_text):
					errors.append(("data/street.json carries price key `%s`; doc 03 "
							+ "owns every dollar (C-07 / RR-85) — it belongs in "
							+ "data/economy.json city_services.street_payout")
							% key_text)
				_assert_no_prices((value as Dictionary)[key])
		TYPE_ARRAY:
			for entry: Variant in (value as Array):
				_assert_no_prices(entry)
		_:
			pass


static func _normalise_kind(row: Dictionary) -> Dictionary:
	var life: Variant = row.get("lifetime_h", [2.0, 3.0])
	var life_lo := 2.0
	var life_hi := 3.0
	if life is Array and (life as Array).size() >= 2:
		life_lo = float((life as Array)[0])
		life_hi = maxf(life_lo, float((life as Array)[1]))
	var coverage: Dictionary = row.get("coverage", {})
	var frontage: Dictionary = row.get("frontage", {})
	return {
		"base_weight": maxf(0.0, float(row.get("base_weight", 1.0))),
		"life_lo": life_lo,
		"life_hi": life_hi,
		"has_coverage": not coverage.is_empty(),
		"weak_below": clampf(float(coverage.get("weak_below", 0.45)), 0.000001, 0.999999),
		"weight_at_zero": maxf(0.0, float(coverage.get("weight_at_zero", 1.0))),
		"weight_at_threshold": maxf(0.0, float(coverage.get("weight_at_threshold", 1.0))),
		"weight_at_full": maxf(0.0, float(coverage.get("weight_at_full", 1.0))),
		"has_frontage": not frontage.is_empty(),
		"frontage_weight": maxf(0.0, float(frontage.get("frontage_weight", 1.0))),
		"elsewhere_weight": maxf(0.0, float(frontage.get("elsewhere_weight", 1.0))),
		# RULED ZERO, v1 (doc 93 §V1, sim q5). Parsed and carried so the ruling
		# is visible in code as well as in `data/street.json`, and SPENT NOWHERE:
		# `_expire_through` is the one function that would spend it and it does
		# not, so an unanswered crook costs the player nothing at all. The steer
		# is the lead's and it is a design rule, not a placeholder — this layer
		# exists because the player asked for something to DO, and a layer that
		# fines you for not looking has turned a bounty into a chore. Re-open
		# only on the named condition: telemetry showing players farm-ignoring
		# crooks at scale.
		"expire_stability_delta": float(row.get("expire_stability_delta", 0.0)),
	}


func drain_events() -> Array[Dictionary]:
	var out := _events
	_events = [] as Array[Dictionary]
	return out


## Break the sim ↔ system reference cycle, the same debt `TickScheduler.dispose`
## pays (doc 91 D-9). Three of the four seams above resolve through `CitySim` —
## the coverage index lives behind `CityIncidentWorld`, which holds the sim; the
## frontage set and the revision are the sim's own — so a stored `Callable` for
## any of them keeps the sim alive, and `RefCounted` has no collector to break
## the loop. `WaterSystem.powered_provider` has the same shape and the same debt.
##
## Called by `CitySim.dispose()`. A system that is disposed answers zero coverage
## and an empty frontage set, which is inert rather than wrong: nothing ticks a
## retired sim.
func dispose() -> void:
	coverage_police = Callable()
	residential_ids = Callable()
	roster_revision = Callable()
	city_level = Callable()
	_candidates = []
	_candidate_key = Vector2i(-1, -1)


# ---------------------------------------------------------------- the tick

## ONE evaluation window, whose length is `eval_period_h`. The phase adapter's
## cadence IS the window (`CitySim.StreetPhaseSystem`, EVERY_MINUTE), so this is
## called exactly once per game-minute online and never draws twice for the same
## minute however the shell slices its frames.
##
## `online` is `not ctx.is_catchup`, and it is the whole of doc 08's fairness
## rule: offline, this expires and returns, having touched no stream.
func advance(now_h: float, online: bool) -> void:
	_expire_through(now_h, online)
	if not online:
		return
	# At the ceiling the Bernoulli is not drawn at all. That is a deliberate
	# choice and not an optimization: a draw whose only outcome is "discard" is
	# a stream position spent on nothing, and the roster size is state either
	# way — the sequence is a pure function of the persisted city, which is what
	# save → load → advance identity actually requires.
	if _live.size() >= max_live:
		return
	_try_spawn(now_h)


## Expire everything whose clock has run out. ONLINE this emits
## `opportunity_expired` per row, in ascending id order; OFFLINE it clears them
## without a word — doc 08 §2.3 rule 9: a returning player is not told about
## bounties they could not possibly have taken.
##
## **AN EXPIRY COSTS NOTHING, and that is a ruling (doc 93 §V1, sim q5).** The
## obvious next step from the kinds table is a stability micro-ding on the
## district that let a crook walk — `expire_stability_delta` is authored, is
## parsed, and would be spent here. It is ruled **zero for v1** and the reason is
## not conservatism: this whole layer exists because a playtester said *"there's
## not a lot of downtime of absolutely nothing to do"*, i.e. they wanted
## something to DO. A penalty for NOT doing it converts a bounty into a chore
## and taxes exactly the player who put the phone down — which is the same
## player doc 08's offline fairness rule already promises not to punish. There
## is no line of code below to disable, because there is no line of code above
## that spends it. Re-open on the named condition and no other: telemetry
## showing players farm-ignoring crooks at scale.
func _expire_through(now_h: float, online: bool) -> void:
	if _live.is_empty():
		return
	var kept: Array[Dictionary] = []
	for row: Dictionary in _live:
		if float(row["expires_h"]) > now_h:
			kept.append(row)
			continue
		if online:
			_emit(&"opportunity_expired", row)
	_live = kept


## One Bernoulli, then — if it clears — one tile, one kind, one reward and one
## lifetime. **At most five draws per game-minute and exactly one on a quiet
## one**, which is the bound doc 01 §2.5's coarse contract would ask for if this
## had a coarse path. Fewer than five when the drawn tile is rejected: a tile
## inside `min_separation_tiles` of a live offer costs two draws and produces
## nothing, which is deliberate — spending the rest of the sequence on an offer
## that will not exist would make the stream depend on a rejection.
func _try_spawn(now_h: float) -> void:
	var rng := _rng
	if rng == null:
		return
	if rng.randf() >= clampf(eval_period_h / target_interval_h, 0.0, 1.0):
		return
	var pool := _candidate_tiles()
	if pool.is_empty():
		return
	var pick: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
	var tile: Vector2i = pick["tile"]
	if _too_close(tile):
		return
	var kind := _pick_kind(rng, tile, bool(pick["residential"]))
	if kind == &"":
		return
	var row: Dictionary = _kinds[kind]
	var reward := _reward_for(rng, kind)
	var lifetime := lerpf(float(row["life_lo"]), float(row["life_hi"]), rng.randf())
	var offer := {
		"id": _next_id,
		"kind": String(kind),
		"tile_x": tile.x,
		"tile_y": tile.y,
		"side": int(pick["side"]),
		"reward": reward,
		"spawned_h": now_h,
		# The spawn GAME-MINUTE, and it is a second field rather than
		# `spawned_h * 60` computed at the reader for one reason: it is the
		# number doc 11 §2.17's renderer anchors a body's wander beat to, and a
		# unit conversion done in a renderer is a unit conversion the save cannot
		# check. Written once, persisted, republished on every event, and read by
		# exactly one consumer.
		"born_gm": now_h * 60.0,
		"expires_h": now_h + lifetime,
	}
	_next_id += 1
	_live.append(offer)
	_emit(&"opportunity_spawned", offer)


## Doc 03 §2.5's bounty, frozen at spawn — **and every dollar in it is read from
## `data/economy.json`, not from this system's own file** (RR-85).
##
## `u` is drawn BEFORE the lifetime and UNCONDITIONALLY: it is a stream position,
## not an optimisation, so a fixture with no price table bound draws it anyway
## and produces the same sequence a priced one does at zero dollars. Skipping the
## draw when `payouts` is null would make the `street` stream depend on whether
## doc 03's file was loaded, which is exactly the class of dependency
## save → load → advance identity forbids.
func _reward_for(rng: RandomNumberGenerator, kind: StringName) -> int:
	var u := rng.randf()
	if payouts == null:
		return 0
	var band := payouts.street_payout_base(String(kind)) \
			+ payouts.street_payout_spread(String(kind)) * u
	var level := maxi(1, _city_level())
	var scaled := band * (1.0 + payouts.street_reward_city_level_k() * float(level - 1))
	return maxi(0, int(floor(scaled + 0.5)))


## The kind, drawn from the three weights AT THIS TILE. That is what makes the
## placement rule a placement rule rather than a preference: a crook's weight is
## `f_weak(coverage_police(tile))`, so at a covered corner it is a TWENTIETH of
## what it is at an unpoliced one (3.00 → 0.15 at the shipped values) and the
## crook lands where the player can see the station is missing. Total spawn RATE does not move — the layer is the
## thing that keeps a session busy, and a well-run city may not be a quiet one.
func _pick_kind(rng: RandomNumberGenerator, tile: Vector2i, residential: bool) -> StringName:
	var weights := PackedFloat64Array()
	var total := 0.0
	for kind: StringName in KINDS:
		var w := 0.0
		if _kinds.has(kind):
			w = _weight_of(_kinds[kind], tile, residential)
		weights.append(w)
		total += w
	if total <= 0.0:
		return &""
	var roll := rng.randf() * total
	var running := 0.0
	for i in KINDS.size():
		running += weights[i]
		if roll < running:
			return KINDS[i]
	return KINDS[KINDS.size() - 1]


func _weight_of(row: Dictionary, tile: Vector2i, residential: bool) -> float:
	var w := float(row["base_weight"])
	if w <= 0.0:
		return 0.0
	if bool(row["has_coverage"]):
		w *= _coverage_weight(row, _coverage_at(tile))
	if bool(row["has_frontage"]):
		w *= float(row["frontage_weight"]) if residential \
				else float(row["elsewhere_weight"])
	return w


## Two straight segments through one authored knee. Below `weak_below` the
## weight falls from `weight_at_zero` to `weight_at_threshold`; above it, on to
## `weight_at_full` at perfect coverage. A knee rather than a curve because the
## number the player is being taught is "there is no station near here", and a
## knee is the shape that says it.
static func _coverage_weight(row: Dictionary, coverage: float) -> float:
	var knee := float(row["weak_below"])
	var c := clampf(coverage, 0.0, 1.0)
	if c <= knee:
		return lerpf(float(row["weight_at_zero"]), float(row["weight_at_threshold"]),
				c / knee)
	return lerpf(float(row["weight_at_threshold"]), float(row["weight_at_full"]),
			(c - knee) / (1.0 - knee))


func _coverage_at(tile: Vector2i) -> float:
	if not coverage_police.is_valid():
		return 0.0
	return clampf(float(coverage_police.call(tile)), 0.0, 1.0)


func _city_level() -> int:
	return int(city_level.call()) if city_level.is_valid() else 1


## Squared-distance test against every live offer. `_live` is capped at
## `max_live`, so this is at most four comparisons.
func _too_close(tile: Vector2i) -> bool:
	var limit := min_separation_tiles * min_separation_tiles
	for row: Dictionary in _live:
		var dx := float(int(row["tile_x"]) - tile.x)
		var dy := float(int(row["tile_y"]) - tile.y)
		if dx * dx + dy * dy < limit:
			return true
	return false


## Constitution §5: the system is handed its ONE stream at boot and never sees
## the others. Held rather than looked up per draw — `RngStreams.stream()`
## asserts on every call, and this is asked once a game-minute forever.
func bind_stream(streams: RngStreams) -> void:
	_rng = streams.stream(STREAM_NAME)


# ------------------------------------------------------------ the kerb index

## Every kerb tile in the city, in the road graph's own (y, x) order.
##
## **This is `RoadSurfaceView.classify()`'s `kerb` mask and nothing else.** That
## function lives in `game/render/`, which `sim/` may not read (constitution §3),
## so the one test it makes that this needs is replicated here: a side is a KERB
## when the neighbour across it is in bounds, is not road and is not water — the
## footway a pedestrian would be standing on. What is deliberately NOT
## replicated is everything the carriageway needs and a bounty does not: the
## per-edge road class, the dual-carriageway pairing, the junction flag.
##
## **One deliberate divergence, in the safe direction.** `RoadSurfaceView` kerbs
## an OFF-MAP neighbour, so a road that runs to the edge of the world still gets
## a face drawn on it; this does not, because a bounty standing on that side
## would be standing off the map. The sim's kerb mask is therefore a strict
## subset of the renderer's, and `tests/test_street_opportunities.gd` asserts
## exactly that — subset, plus set-equality once the renderer's off-map sides
## are removed — rather than trusting this paragraph.
##
## Memoised on `(graph_version, roster_revision)` — the two revisions that can
## change the answer. Not a cadence: a memo over an exact key gives a restored
## city the same list as the live one it was saved from, which a "rebuild every
## game-day" timer would not. **Callers iterate it read-only**; the shared array
## is handed out rather than copied because it is 734 rows on the founding city
## and 3,000-odd on the benchmark, and nothing mutates it.
func _candidate_tiles() -> Array:
	if grid == null or graph == null:
		return []
	var key := Vector2i(graph.graph_version, _roster_revision())
	if key == _candidate_key and not _candidates.is_empty():
		return _candidates
	_candidates = _build_candidates()
	_candidate_key = key
	return _candidates


func _roster_revision() -> int:
	return int(roster_revision.call()) if roster_revision.is_valid() else 0


func _build_candidates() -> Array:
	var residential: Dictionary = {}
	if residential_ids.is_valid():
		var raw: Variant = residential_ids.call()
		if raw is Dictionary:
			residential = raw
	var out: Array = []
	for raw_tile: Variant in graph.road_tiles_sorted():
		var t: Vector2i = raw_tile
		var side := -1
		var has_residential := false
		for i in 4:
			var q: Vector2i = t + DIRS[i]
			if not TileGrid.in_bounds(q.x, q.y):
				continue
			var flags := grid.flags_at(q.x, q.y)
			if (flags & TileGrid.FLAG_ROAD) != 0:
				continue
			if (flags & TileGrid.FLAG_WATER) != 0:
				continue
			if side < 0:
				side = i
			if not has_residential and residential.has(grid.building_at(q.x, q.y)):
				has_residential = true
		if side < 0:
			continue
		out.append({"tile": t, "side": side, "residential": has_residential})
	return out


# ------------------------------------------------------------------- the verb

## The roster, newest last, as private copies. `ui/` and the renderer read this;
## nothing outside this class mutates a row.
func live() -> Array:
	var out: Array = []
	for row: Dictionary in _live:
		out.append(row.duplicate())
	return out


func live_count() -> int:
	return _live.size()


## One offer by id, or an EMPTY dictionary. A private copy — see `live()`.
## The nearest live offer within `radius_m` of a WORLD point (metres), or `{}`.
## The shell's tap funnel (doc 12 §2.21) calls this through `BuildController`;
## a query, so it moves nothing and draws nothing. `world_pos` rides the answer
## because the caller circle-tests against it — tile centre, the same 8 m grid
## every renderer uses.
func opportunity_near(point: Vector3, radius_m: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d := radius_m
	for row: Dictionary in _live:
		var world := Vector3(float(int(row["tile_x"])) * 8.0 + 4.0, 0.0,
				float(int(row["tile_y"])) * 8.0 + 4.0)
		var d := Vector2(world.x - point.x, world.z - point.z).length()
		if d <= best_d:
			best_d = d
			best = row.duplicate()
			best["world_pos"] = world
	return best


func find(opportunity_id: int) -> Dictionary:
	for row: Dictionary in _live:
		if int(row["id"]) == opportunity_id:
			return row.duplicate()
	return {}


## Take the offer off the roster and hand it back, or `{}` if it is not there.
## The MONEY is `CitySim.cmd_collect_opportunity`'s — this class credits no
## treasury and knows no ledger, which is what keeps doc 03 the only place a
## dollar is created.
func take(opportunity_id: int) -> Dictionary:
	for i in _live.size():
		if int(_live[i]["id"]) == opportunity_id:
			var row: Dictionary = _live[i]
			_live.remove_at(i)
			return row
	return {}


func _emit(event_type: StringName, row: Dictionary) -> void:
	_events.append(event_payload(event_type, row))


## The payload shape all three events share, so a consumer that can read one can
## read the others: `{id, kind, tile, side, reward, born_gm, expires_h}`. `tile`
## is a two-int array rather than a `Vector2i` because this crosses the bus into
## `game/` and `ui/`, and doc 91 §18's routers key on plain JSON shapes.
##
## `born_gm` is the spawn GAME-MINUTE and it is here for doc 11 §2.17's benefit
## alone: that layer's whole wander is a closed form in `(id, now − born)`, so
## with the spawn minute on the payload a body re-seeded after a load is
## standing where the save says instead of restarting on its first waypoint.
## **A payload field is not hashed** — `state_hash` reads `capture_state`, and
## the bus is not in it — so publishing this moves nothing. The persisted row
## does move the hash, and that delta is published in doc 98 RR-93.
static func event_payload(event_type: StringName, row: Dictionary) -> Dictionary:
	return {
		"type": event_type,
		"id": int(row["id"]),
		"kind": String(row["kind"]),
		"tile": [int(row["tile_x"]), int(row["tile_y"])],
		"side": int(row["side"]),
		"reward": int(row["reward"]),
		"born_gm": float(row.get("born_gm", float(row.get("spawned_h", 0.0)) * 60.0)),
		"expires_h": float(row["expires_h"]),
	}


# ---------------------------------------------------------------- persistence

## Doc 08 §2.8 city section v7. Floats go through `CitySim`'s `~f~` encoder on
## the way out, so `expires_h` survives a round trip to the bit.
func serialize() -> Dictionary:
	var rows: Array = []
	for row: Dictionary in _live:
		rows.append(row.duplicate())
	return {"next_id": _next_id, "live": rows}


## NOTE: JSON numbers arrive as floats — every read casts (SaveSection contract).
## A body with no `street` block at all is a v6 save and restores to an EMPTY
## roster, which is exactly what a v6 city had.
func deserialize(data: Dictionary) -> void:
	_live = [] as Array[Dictionary]
	_next_id = maxi(1, int(data.get("next_id", 1)))
	for raw: Variant in data.get("live", []):
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		var kind := String(row.get("kind", ""))
		if not _kinds.has(StringName(kind)):
			# A kind the running build no longer knows. Dropping it is the only
			# TOTAL answer: the alternative is a live offer whose weights,
			# lifetime and artwork do not exist.
			continue
		_live.append({
			"id": int(row.get("id", 0)),
			"kind": kind,
			"tile_x": int(row.get("tile_x", 0)),
			"tile_y": int(row.get("tile_y", 0)),
			"side": clampi(int(row.get("side", 0)), 0, 3),
			"reward": int(row.get("reward", 0)),
			"spawned_h": float(row.get("spawned_h", 0.0)),
			# A v7 save written before render q2 carries no `born_gm`; deriving
			# it from `spawned_h` restores exactly the value the spawner would
			# have written, so an old save is not a body with no beat.
			"born_gm": float(row.get("born_gm",
					float(row.get("spawned_h", 0.0)) * 60.0)),
			"expires_h": float(row.get("expires_h", 0.0)),
		})
	_live.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["id"]) < int(b["id"]))
	_candidate_key = Vector2i(-1, -1)
	_candidates = []

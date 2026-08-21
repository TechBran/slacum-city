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
var reward_city_level_k: float = 0.20
## Set by `CitySim` from the phase adapter's OWN cadence, never authored: the
## per-evaluation probability is `eval_period_h / target_interval_h`, and a
## hand-written period that drifted from the cadence would silently re-rate the
## whole layer. See `CitySim._boot_street`.
var eval_period_h: float = 1.0 / 60.0
var _kinds: Dictionary = {}  # StringName -> normalised row

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
func configure(table: Dictionary) -> void:
	var spawn: Dictionary = table.get("spawn", {})
	target_interval_h = maxf(0.000001, float(spawn.get("target_interval_h",
			target_interval_h)))
	max_live = maxi(0, int(spawn.get("max_live", max_live)))
	min_separation_tiles = maxf(0.0, float(spawn.get("min_separation_tiles",
			min_separation_tiles)))
	reward_city_level_k = float(spawn.get("reward_city_level_k", reward_city_level_k))
	_kinds = {}
	var rows: Dictionary = table.get("kinds", {})
	for kind: StringName in KINDS:
		var raw: Variant = rows.get(String(kind), null)
		if raw is Dictionary:
			_kinds[kind] = _normalise_kind(raw as Dictionary)


static func _normalise_kind(row: Dictionary) -> Dictionary:
	var life: Variant = row.get("lifetime_h", [2.0, 3.0])
	var life_lo := 2.0
	var life_hi := 3.0
	if life is Array and (life as Array).size() >= 2:
		life_lo = float((life as Array)[0])
		life_hi = maxf(life_lo, float((life as Array)[1]))
	var reward: Dictionary = row.get("reward", {})
	var coverage: Dictionary = row.get("coverage", {})
	var frontage: Dictionary = row.get("frontage", {})
	return {
		"base_weight": maxf(0.0, float(row.get("base_weight", 1.0))),
		"life_lo": life_lo,
		"life_hi": life_hi,
		"reward_base": float(reward.get("base", 100.0)),
		"reward_spread": maxf(0.0, float(reward.get("spread", 0.0))),
		"has_coverage": not coverage.is_empty(),
		"weak_below": clampf(float(coverage.get("weak_below", 0.45)), 0.000001, 0.999999),
		"weight_at_zero": maxf(0.0, float(coverage.get("weight_at_zero", 1.0))),
		"weight_at_threshold": maxf(0.0, float(coverage.get("weight_at_threshold", 1.0))),
		"weight_at_full": maxf(0.0, float(coverage.get("weight_at_full", 1.0))),
		"has_frontage": not frontage.is_empty(),
		"frontage_weight": maxf(0.0, float(frontage.get("frontage_weight", 1.0))),
		"elsewhere_weight": maxf(0.0, float(frontage.get("elsewhere_weight", 1.0))),
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
	var reward := _reward_for(rng, row)
	var lifetime := lerpf(float(row["life_lo"]), float(row["life_hi"]), rng.randf())
	var offer := {
		"id": _next_id,
		"kind": String(kind),
		"tile_x": tile.x,
		"tile_y": tile.y,
		"side": int(pick["side"]),
		"reward": reward,
		"spawned_h": now_h,
		"expires_h": now_h + lifetime,
	}
	_next_id += 1
	_live.append(offer)
	_emit(&"opportunity_spawned", offer)


## Doc 03 §2.5's bounty, frozen at spawn. `u` is drawn BEFORE the lifetime so
## the two are stably associated whatever a future retune does to either.
func _reward_for(rng: RandomNumberGenerator, row: Dictionary) -> int:
	var base := float(row["reward_base"]) + float(row["reward_spread"]) * rng.randf()
	var level := maxi(1, _city_level())
	var scaled := base * (1.0 + reward_city_level_k * float(level - 1))
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
## read the others: `{id, kind, tile, side, reward, expires_h}`. `tile` is a
## two-int array rather than a `Vector2i` because this crosses the bus into
## `game/` and `ui/`, and doc 91 §18's routers key on plain JSON shapes.
static func event_payload(event_type: StringName, row: Dictionary) -> Dictionary:
	return {
		"type": event_type,
		"id": int(row["id"]),
		"kind": String(row["kind"]),
		"tile": [int(row["tile_x"]), int(row["tile_y"])],
		"side": int(row["side"]),
		"reward": int(row["reward"]),
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
			"expires_h": float(row.get("expires_h", 0.0)),
		})
	_live.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["id"]) < int(b["id"]))
	_candidate_key = Vector2i(-1, -1)
	_candidates = []

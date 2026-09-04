class_name Building
extends RefCounted
## One building instance: the eight-state machine, condition/decay and the
## per-state behaviour modifiers (doc 02 §2.5, §2.6, §2.12). Transitions are
## validated here and returned as events; cross-system side effects (charges,
## crew binding, tile stamping) belong to the owning coordinator.

const STATES := [
	&"planned", &"under_construction", &"active", &"damaged",
	&"on_fire", &"repairing", &"destroyed",
]

## Doc 02 §2.6's condition block, as it stands in `data/building_rules.json`.
## **These are DEFAULTS, not the source** (PA-13, doc 93 §Y2): the authored file
## is the source and `condition_rules` below carries it. They stay named consts
## because they are also the fallback — a `Building` the coordinator never
## stamped behaves exactly as every pre-Wave-17 fixture did — and because three
## tests and one formatter quote them as the shipped values.
const AUTO_DAMAGE_THRESHOLD := 0.35
const STRUCTURAL_FAILURE_THRESHOLD := 0.10
const STRUCTURAL_FAILURE_P_PER_H := 0.02
const MIN_CONDITION_TO_UPGRADE := 0.55
const REPAIR_TIME_FACTOR := 0.50
const REPAIR_TARGET_FROM_DAMAGED := 0.85
## RETIRED Wave 18 (doc 93 §AN) — see `order_rebuild()`. It gated a level
## demotion and a price fraction that no caller ever read, against a window ten
## times shorter than doc 08's own offline cap. Deleted rather than deprecated:
## nothing in the project reads it, and a const that gates nothing is a rule the
## next reader will try to obey.
const OVERLOAD_DECAY_COEFFICIENT := 0.80
const UNPOWERED_DECAY_COEFFICIENT := 0.50
const DAMAGED_DECAY_MULTIPLIER := 1.50

## The same fifteen values keyed as `data/building_rules.json.condition` keys
## them, so a stamped block and this fallback are interchangeable and the
## accessors below need no special case.
const DEFAULT_CONDITION := {
	"start": 1.00,
	"auto_damage_threshold": AUTO_DAMAGE_THRESHOLD,
	"structural_failure_threshold": STRUCTURAL_FAILURE_THRESHOLD,
	"structural_failure_p_per_hour": STRUCTURAL_FAILURE_P_PER_H,
	"min_condition_to_upgrade": MIN_CONDITION_TO_UPGRADE,
	"repair_time_factor": REPAIR_TIME_FACTOR,
	"repair_target_active": 1.00,
	"repair_target_damaged": REPAIR_TARGET_FROM_DAMAGED,
	"overload_decay_coefficient": OVERLOAD_DECAY_COEFFICIENT,
	"unpowered_decay_coefficient": UNPOWERED_DECAY_COEFFICIENT,
	"damaged_decay_multiplier": DAMAGED_DECAY_MULTIPLIER,
	# Doc 02 §2.6's band table. `band_worn` is the ownership floor (§2.6a) and is
	# the one value in this dict a `Building` cannot do without: a fallback that
	# omitted it gave an unstamped private building NO floor, which is a silently
	# different physics from the stamped one. `band_poor` is here for the same
	# reason — the fallback must be the whole block, not the part today happens
	# to read.
	"band_good": 0.85,
	"band_worn": 0.60,
	"band_poor": 0.35,
	# Doc 08 C-47's offline clamp. Here for the same reason `band_worn` is: this
	# fallback must be the WHOLE authored block, not the part that happened to
	# have a reader. `burn_down` and `demolish` both read it through `rule()`,
	# and without a default an unstamped fixture would clamp to 0.0 — i.e. to a
	# ruin — which is the exact outcome the clamp exists to prevent.
	"offline_burn_down_clamp": 0.15,
}

var id: int = 0
var archetype: StringName = &""
var variant: StringName = &""  # water_facility only
var level: int = 0  # 0 while a new build is in progress
var pending_level: int = 0  # target level while under_construction
var origin := Vector2i.ZERO
var state: StringName = &"planned"
var condition: float = 1.0
var built_at_minutes: int = 0
var destroyed_at_minutes: int = 0
var level_at_destruction: int = 0
## Stats row for the CURRENT level, supplied by BuildingCatalog via the
## coordinator on every level change. Keys per data/buildings.json.
var stats: Dictionary = {}
## How many rungs THIS archetype's ladder has (doc 02 §2.14): five for the civic
## and utility shells, six for the growth stock. A `Building` holds no catalog,
## so the coordinator stamps it beside `stats`. The default is the five-rung
## floor every archetype had before doc 92 §24 — a fixture that never sets it
## gets exactly the behaviour it had, and a building that somehow escapes the
## stamp is under-upgradable rather than infinitely upgradable.
var max_level: int = 5
## Doc 02 §2.6's condition block, stamped by the coordinator beside `stats` and
## `max_level` at the four sites that make a `Building` live — boot, restore,
## placement and the doc 05 water shell (PA-13, doc 93 §Y2). It is the SAME
## shared `Dictionary` on every
## instance, so this costs one reference per building and no copy. Never a
## static and never a singleton: `sim/` is RefCounted-only and the rigs boot
## several `CitySim`s in one process, so a process-global would let one city's
## fixture move another city's physics.
var condition_rules: Dictionary = DEFAULT_CONDITION
## Doc 02 §2.6a (doc 93 §Y1): is this PRIVATE STOCK, kept up by its owner rather
## than by the city's crews? A property of the archetype's tax class, so it is
## stamped like the two above and never persisted. The default is `false` — a
## fixture that never sets it wears and damages exactly as it did before the
## ruling, which is what keeps every pre-Wave-17 worked example true.
var owner_maintained: bool = false
## Doc 93 §AP1 (Wave 19) and §AR1 (Wave 20): may ordinary WEAR take this building
## all the way to `destroyed`? Stamped from
## `BuildingCatalog.wear_may_demolish_for`, which folds both rulings —
## `building_rules.owner_maintenance.wear_may_demolish` for private stock and
## `building_rules.utility_spine.wear_may_demolish` for the city's own generation
## and water — beside [owner_maintained], and read only by
## [roll_structural_failure]. The default is `true` — the pre-Wave-19
## behaviour — so a fixture that never stamps it collapses exactly as it always
## did, and the rulings arrive only where the coordinator applied them.
## It is not persisted, for [owner_maintained]'s reason: it is a property of the
## archetype and the file, not of the row, so a save written before the ruling
## loads into a city that applies it.
var wear_may_demolish: bool = true

## **A GUTTED SHELL IS NOT FUEL — doc 93 §AS2 (Wave 21).** Set by
## [condemn_unanswered] and by nothing else: an unanswered fire has already
## taken everything in this building that could burn, and until the shell is
## rebuilt there is nothing left in it to ignite. Read by [state_fire_mult], so
## it takes the building out of doc 06 §2.6's ignition roll AND out of §2.8's
## spread candidates at the same time and by the same number.
##
## **It is the BOUND, and without it §AS1 has no floor.** §AS1 rules that a fire
## the city cannot answer condemns rather than destroys — and destruction was
## the only thing that ever made fire self-limiting. Doc 06's own saturation note
## says so in as many words: *"five of the eight resolve to a BUILDING and take
## it off the board, which makes them self-limiting the way fire spread is"*. A
## condemned building comes to rest in `damaged` at 0.10, where
## `state_fire_mult` is **1.8** and `fire_condition_mult(0.10)` is **2.28** — 4.1
## times a healthy building's ignition rate — so a shell that survives its own
## burn-down is the most flammable object in the city, forever. Doc 92 §60.3
## measured the loop that makes: on the player's slot 0 with the ruling and no
## bound, **7,379 incidents born in 45 game-days on a 76-building city** (doc 06
## §2.10.1's own worst legitimate arrival rate is 26 a game-day), 3,919 of them
## failing, each failure spawning a `blocked_road`, and 72,195
## `dispatch_blocked_unreachable` behind the roads that made.
##
## **It is not a shield and it is not a farm.** The shell earns doc 02 §2.12's
## `output_mult` 0.40 and doc 03's `f_condition` 0.46 while it stands gutted, so
## the player is holding a fifth of a building; the moment they repair it — or
## its owner does, or they restore it — the flag lifts and it burns like anything
## else. Choosing to be un-burnable by staying gutted costs four fifths of the
## asset's income, every game-hour, which is strictly worse than any fire.
##
## **THREE VERBS LIFT IT, AND ALL THREE ARE SOMEBODY PAYING.**
## [complete_repair] (the player bought a repair), [complete_construction] (the
## player restored or rebuilt it) and [_destroy] (there is no shell left to
## board). Routine owner upkeep deliberately does NOT — see [_owner_maintain] for
## the measurement that made that the difference between a bound and a
## two-game-hour delay.
##
## Persisted, but only when TRUE (see [serialize]): a shell that survives a
## reload has to still be a shell, and a city that has never had one writes the
## byte-identical save it wrote before this ruling.
var burnt_out: bool = false


func _init(p_id: int = 0, p_archetype: StringName = &"", p_origin := Vector2i.ZERO,
		p_variant: StringName = &"") -> void:
	id = p_id
	archetype = p_archetype
	origin = p_origin
	variant = p_variant


func is_new_build() -> bool:
	return state == &"under_construction" and level == 0


func is_upgrade_in_progress() -> bool:
	return state == &"under_construction" and level >= 1


## At the top of THIS archetype's ladder (doc 02 §2.14) — five rungs for the
## civic and utility shells, six for the growth stock.
func is_at_top_level() -> bool:
	return level >= maxi(max_level, 1)


# ------------------------------------------------- per-state modifiers (§2.12)

func output_mult() -> float:
	match state:
		&"active": return 1.0
		&"under_construction": return 0.35 if level >= 1 else 0.0
		&"damaged", &"repairing": return 0.40
		_: return 0.0


func power_demand_mult() -> float:
	match state:
		&"active": return 1.0
		&"under_construction": return 1.0 if level >= 1 else 0.15
		&"damaged", &"repairing": return 0.50
		_: return 0.0


func water_demand_mult() -> float:
	match state:
		&"active": return 1.0
		&"under_construction": return 1.0 if level >= 1 else 0.10
		&"damaged", &"repairing": return 0.50
		_: return 0.0


func state_occupancy() -> float:
	match state:
		&"active": return 1.0
		&"under_construction": return 0.50 if level >= 1 else 0.0
		&"damaged", &"repairing": return 0.40
		_: return 0.0


func coverage_mult() -> float:
	match state:
		&"active": return 1.0
		&"under_construction": return 0.50 if level >= 1 else 0.0
		&"damaged", &"repairing": return 0.25
		_: return 0.0


func decays() -> bool:
	match state:
		&"active": return true
		&"under_construction": return level >= 1
		&"damaged": return true
		_: return false


func state_fire_mult() -> float:
	# Doc 93 §AS2: a shell an unanswered fire already gutted has nothing left in
	# it to burn. Checked BEFORE the state table, because the state a gutted
	# building rests in is `damaged`, which is the table's most flammable row.
	if burnt_out:
		return 0.0
	match state:
		&"under_construction": return 1.4
		&"damaged", &"repairing": return 1.8
		&"active": return 1.0
		_: return 0.0  # planned / destroyed / on_fire never (re-)ignite


# ------------------------------------------------------- condition (§2.6)

## The condition block's readers (PA-13, doc 93 §Y2). Every one of them takes the
## authored value when the coordinator stamped a block and the const above when
## it did not, so perturbing a key in `data/building_rules.json` moves the
## BEHAVIOUR and not just the loader's opinion of it.
func rule(key: String) -> float:
	return float(condition_rules.get(key, DEFAULT_CONDITION.get(key, 0.0)))


func auto_damage_threshold() -> float:
	return rule("auto_damage_threshold")


func min_condition_to_upgrade() -> float:
	return rule("min_condition_to_upgrade")


func repair_time_factor() -> float:
	return rule("repair_time_factor")


## §2.12's post-repair target: 1.00 from `active`, `repair_target_damaged` from
## `damaged`, because a post-damage repair never restores to new.
func repair_target() -> float:
	return rule("repair_target_active") if state == &"active" \
			else rule("repair_target_damaged")


## Doc 02 §2.6a: the condition below which an owner's crew starts. It is the
## Good band's own floor — doc 93 §Y1 authors no number for this.
func owner_repair_threshold() -> float:
	return rule("band_good")


func fire_condition_mult() -> float:
	return 1.0 + 1.5 * pow(1.0 - condition, 1.5)


func damage_fraction() -> float:
	return clampf(1.0 - condition, 0.0, 1.0)


## doc 02 §2.6: `build_time_hours(L) × REPAIR_TIME_FACTOR × damage_fraction`.
## `data/buildings.json` names the column `build_time_hours`; `build_hours` is
## accepted as a legacy alias so a fixture written either way still prices.
func repair_crew_hours() -> float:
	var build_hours := float(stats.get("build_time_hours",
			stats.get("build_hours", 0.0)))
	return build_hours * repair_time_factor() * damage_fraction()


## One settled hour (or dt_h of them) of decay. `powered_fraction` is doc 04's
## power_availability_hour; `overload_excess` = max(0, load/capacity − 1) of
## the serving grid node; `weather_decay_mult` from doc 07 get_effect().
## Returns events (auto-damage transition).
func apply_decay(dt_h: float, overload_excess: float = 0.0, powered_fraction: float = 1.0,
		weather_decay_mult: float = 1.0) -> Array:
	if not decays():
		return []
	var rate := float(stats.get("decay_per_hour", 0.0)) \
			* (1.0 + rule("overload_decay_coefficient") * maxf(0.0, overload_excess)) \
			* (1.0 + rule("unpowered_decay_coefficient")
					* (1.0 - clampf(powered_fraction, 0.0, 1.0))) \
			* weather_decay_mult
	if state == &"damaged":
		rate *= rule("damaged_decay_multiplier")  # §2.12 state table
	if owner_maintained and state == &"damaged" \
			and clampf(powered_fraction, 0.0, 1.0) > 0.0:
		# An INCIDENT put it here (doc 06) and the owner is rebuilding it, so
		# this path owns the WHOLE hour: no wear is applied on top of the crew's
		# work, and the floor below does not apply either. A `damaged` building
		# is not a worn one — it is doc 06's damage, restored at §2.6's own
		# crew-hours to §2.12's own post-damage target, and floor-jumping it to
		# `band_worn` in a single hour would erase the incident instead of
		# repairing it.
		return _owner_maintain(dt_h, powered_fraction)
	var events: Array = []
	condition = clampf(condition - rate * dt_h, 0.0, 1.0)
	if owner_maintained and state != &"damaged" \
			and clampf(powered_fraction, 0.0, 1.0) > 0.0:
		# **Doc 02 §2.6a, the ownership FLOOR (doc 93 §Y1).** A private building
		# wears exactly as §2.6 has always said — this ruling moves not one
		# `decay_per_hour` cell — but its owner will not let it fall past the
		# Worn band's floor, because below that it stops being an asset and
		# starts being a liability, and it is *their* asset. So a private
		# building is never `damaged` by wear, is never destroyed by wear, and is
		# always still upgradable (`band_worn` 0.60 sits above
		# `min_condition_to_upgrade` 0.55 — that ordering is what makes the
		# floor a floor rather than a trap).
		#
		# What the city sees is the whole of the drag: `f_condition` runs down to
		# `COND_FLOOR + (1 − COND_FLOOR) × 0.60 = 0.76`, i.e. **a permanent 24 %
		# cut in what a neglected building pays**, and it is the ONLY thing the
		# city sees, because there is no repair to buy at any condition.
		#
		# **The answer to a worn city is to invest in it, not to tap REPAIR on
		# it**: `complete_construction` sets condition back to 1.00, so an
		# UPGRADE is the recovery — the loop doc 09 level 2 already teaches, and
		# 20.7 % cheaper since doc 93 §Y7.
		#
		# **The service clause** (doc 93 §Y1a) is the `powered_fraction > 0`
		# guard: an owner the city has left in the dark cannot hold anything, so
		# the floor lifts, the building falls past the auto-damage line, and
		# `roll_structural_failure` can take it. That is what keeps neglect fatal
		# — and it is why the floor is not simply `clampf`ed into the line above.
		#
		# No new constant: `band_worn` is doc 02 §2.6's own band table.
		condition = maxf(condition, rule("band_worn"))
	if state == &"active" and condition < auto_damage_threshold():
		state = &"damaged"
		events.append({"type": &"building_damaged", "building": id, "cause": &"decay"})
	return events


## Doc 02 §2.6a — the owner's crew REBUILDING after an incident, one settled
## hour (or `dt_h` of them) of it. Ordinary wear is not handled here: it is
## absorbed in `apply_decay` above, by subtracting the base rate from the rate.
##
## While `damaged`, the owner restores condition at exactly the rate a city crew
## would work: §2.6's
## `repair_hours = build_time_hours × repair_time_factor × damage_fraction`
## means the WHOLE of a building's damage is made good in
## `build_time_hours × repair_time_factor` game-hours, so the restore rate is
## `1 / that` per game-hour — a house in under an hour, a level-3 apartment's
## 0.15 in about an hour, a level-4 data centre's in seven. No new number.
##
## **The service clause** (doc 93 §Y1a) gates this the same way it gates the
## wear offset: an owner with no power cannot rebuild either, so a building the
## city has left dark stays damaged, keeps wearing, and stays reachable by
## `roll_structural_failure`. That is what keeps neglect fatal after the
## ownership ruling (gate 29) — a city that stops holding up its end loses its
## tax base because the lights went out, which the player can see and fix,
## rather than because they did not tap REPAIR on two hundred houses.
##
## Nothing is billed to the city and nothing is emitted for routine wear: the
## only event this path can produce is the `damaged → active` return after an
## incident, which carries `cause: owner` so a surface can tell an owner's
## rebuild from a city crew's.
func _owner_maintain(dt_h: float, powered_fraction: float = 1.0) -> Array:
	if state != &"damaged":
		return []
	var service := clampf(powered_fraction, 0.0, 1.0)
	if service <= 0.0:
		return []
	# **AN OWNER BOARDS UP A GUTTED SHELL; THEY DO NOT REBUILD IT OUT OF PETTY
	# CASH — doc 93 §AS2** (Wave 21). §AP1's own sentence for a condemned
	# building is *"an owner boards it up rather than bulldozing it"*, and this is
	# where that sentence ends: the owner HOLDS the shell at doc 02 §2.6's line —
	# so it does not rot away and it goes on paying §2.12's `output_mult` 0.40 and
	# doc 03's `f_condition` 0.46, a fifth of a building — and does no more.
	# Putting a burnt-out structure back is a construction job somebody pays for.
	#
	# **Without this the bound is a two-game-hour delay.** `restore` below is
	# `dt_h / (build_time_hours × repair_time_factor)`, which takes ordinary
	# private stock from 0.10 back over `repair_target_damaged` in about two
	# game-hours — and the flip to `active` lifted [burnt_out], so the building
	# was fuel again before the smoke cleared. Doc 92 §60.7 measured that cycle on
	# the player's own slot 0: **14,071 unanswerable fires in ninety game-days on
	# a 68-building city**, 156 a game-day, one per powered building every 2.4
	# game-hours, with `building_repaired` firing 14,062 times to feed them. With
	# this line it is **65 in ninety game-days**.
	#
	# **The service gate above still applies, and it is not weakened here.** A
	# dark shell falls exactly as any other dark private building falls, because
	# doc 93 §Y1a's service clause is the ruling for a building nobody is serving
	# and §AS2 has no business restating it.
	#
	# **The exit is a BILL the player chooses, not a fee they are handed.**
	# `cmd_repair_building` opens on a gutted shell even for private stock (doc 93
	# §AS2, `CitySim.cmd_repair_building` check 2), at doc 03 §2.5's own repair
	# price, and `complete_repair` lifts the flag. That is §AS1's *"spends instead
	# of being erased"* half, and it is why a mutual-aid FEE was rejected: this
	# never hands an insolvent city a liability it cannot pay.
	if burnt_out:
		condition = maxf(condition, rule("structural_failure_threshold"))
		return []
	var build_hours := float(stats.get("build_time_hours",
			stats.get("build_hours", 0.0)))
	var full_repair_hours := build_hours * repair_time_factor()
	var restore := 1.0 if full_repair_hours <= 0.0 else dt_h / full_repair_hours
	condition = clampf(condition + restore * service, 0.0, 1.0)
	if state == &"damaged" and condition >= rule("repair_target_damaged"):
		state = &"active"
		return [{"type": &"building_repaired", "building": id, "cause": &"owner"}]
	return []


## Structural-failure roll (§2.6): below condition 0.10, 0.02/gh on the
## `failures` stream. Returns events; may transition damaged → destroyed.
##
## **WEAR MAY CONDEMN, IT MAY NOT DEMOLISH — doc 93 §AP1 (Wave 19).** For an
## `owner_maintained` building this roll no longer destroys anything, and that
## is the whole of Wave 19's answer to *"ALL of my buildings are destroyed right
## now"*. The instrument (`tools/measure_catastrophe.gd`, doc 92 §56.1) put a
## number on the door: over 45 game-days × 4 presets × 2 session kinds, **every
## single destruction in the game came through THIS function** — 0 from
## `apply_damage`, 0 from `burn_down`, 42 of 42 on standard from here — and the
## chain behind it has nothing to do with any disaster. A city that outgrows its
## own generation leaves ~30 % of its stock permanently dark; §2.6a's ownership
## floor has a service clause (§Y1a) and lifts when the lights go out; the
## private stock then falls unbounded to 0.10 and this roll deletes it at
## 0.02/gh — nine buildings on a bad game-day, one every 2.7 real minutes.
##
## Deleting the player's capital is not a difficulty setting, it is a genre
## change. §Y1's own sentence is the argument: it is *their* asset, and an owner
## whose building is condemned boards it up — they do not bulldoze it. So a
## private building stops at the threshold, in `damaged`, where doc 02 §2.12
## already charges it dearly and REVERSIBLY: `output_mult` 0.40, `coverage_mult`
## 0.25, and doc 03's `f_condition` at 0.46. A neglected city still collapses to
## roughly a fifth of its income; it simply has something left to save.
##
## What can still take a building down, so that a storm still MATTERS:
## `burn_down` (an unanswered tier-5 fire), doc 06's explicit `destroy_building`
## cascade op, an event landing on a building already at the threshold (§AP2),
## and this roll on the city's own POLICE, FIRE and CONSTRUCTION stock.
##
## **WEAR MAY NOT TAKE THE UTILITY SPINE EITHER — doc 93 §AR1 (Wave 20).** The
## paragraph above used to end "…and this roll on the city's OWN civic and
## utility stock", and that exception is the hole the 2026-09-03 player fell
## through: doc 92 §58 loaded their slot 0 and found both power plants, all three
## water facilities and both substations already gone, so every remaining lot was
## dark forever, §Y1a's service clause had lifted the ownership floor for the
## whole city, and nothing could be rebuilt because the treasury was $22,624
## under water. §AP1's own argument is stronger here, not weaker — the city IS
## the owner of a power plant — so `power_facility`, `substation` and
## `water_facility` are condemned by wear and never demolished by it. A neglected
## city browns out to §2.12's `output_mult` 0.40; it does not go dark for good.
## Police, fire and the construction yard stay losable, because losing coverage
## is a loss a player can see, price and rebuild out of.
func roll_structural_failure(rng: RngStreams, dt_h: float, now_minutes: int) -> Array:
	if state != &"damaged" or condition >= rule("structural_failure_threshold"):
		return []
	# **Wave 20 widened this guard and DELETED a conjunct** (doc 93 §AR1).
	# It read `owner_maintained and not wear_may_demolish`, which is why §AP1's
	# own text had to list "this same roll on the city's OWN civic and utility
	# stock" as an exception. `BuildingCatalog.wear_may_demolish_for` now answers
	# for both rulings at the stamping site, so this line asks the flag and
	# nothing else — and a fixture that stamps neither still reads the `true`
	# default and collapses exactly as it did before Wave 19.
	if not wear_may_demolish:
		return []
	var p := 1.0 - pow(1.0 - rule("structural_failure_p_per_hour"), dt_h)
	if rng.stream("failures").randf() < p:
		return _destroy(now_minutes, &"structural_failure")
	return []


# ---------------------------------------------------- transitions (§2.12)

## planned → under_construction (crew assigned).
func start_construction() -> Dictionary:
	if state != &"planned":
		return CommandQueue.fail(&"E_STATE")
	state = &"under_construction"
	if pending_level == 0:
		pending_level = 1
	return CommandQueue.ok({"events": [{"type": &"job_started", "building": id}]})


## under_construction → active (progress complete).
func complete_construction() -> Dictionary:
	if state != &"under_construction":
		return CommandQueue.fail(&"E_STATE")
	level = pending_level if pending_level > 0 else 1
	pending_level = 0
	state = &"active"
	condition = 1.0
	# Doc 93 §AS2, one of the four "the shell is whole again" transitions that
	# lift the flag. This is the one a RESTORE arrives through (`order_rebuild`
	# → `start_construction` → here), so a rebuilt building is fuel again —
	# which is what keeps §AS2 an inconvenience rather than a strategy.
	burnt_out = false
	return CommandQueue.ok({"events": [
		{"type": &"building_completed", "building": id, "level": level},
	]})


## active → under_construction with pending_level = L+1. The full §2.11 gate
## (funds, headroom, coverage…) runs in UpgradeGate; here only local checks.
func start_upgrade() -> Dictionary:
	if state != &"active":
		return CommandQueue.fail(&"E_STATE")
	if is_at_top_level():
		return CommandQueue.fail(&"E_MAX_LEVEL")
	if condition < min_condition_to_upgrade():
		return CommandQueue.fail(&"E_CONDITION")
	pending_level = level + 1
	state = &"under_construction"
	return CommandQueue.ok({"events": [{"type": &"upgrade_started", "building": id,
			"to_level": pending_level}]})


## Cancel an in-progress upgrade: building returns to level L, active,
## condition unchanged (refund fraction 0.50 per §2.10 — coordinator applies).
func cancel_upgrade() -> Dictionary:
	if not is_upgrade_in_progress():
		return CommandQueue.fail(&"E_STATE")
	pending_level = 0
	state = &"active"
	return CommandQueue.ok({"refund_fraction": 0.50})


## doc 06 FireStarted (ignition roll or spread).
func ignite() -> Dictionary:
	if state != &"active" and state != &"damaged" and state != &"under_construction":
		return CommandQueue.fail(&"E_STATE")
	state = &"on_fire"
	return CommandQueue.ok({"events": [{"type": &"building_ignited", "building": id}]})


## doc 06 FireSuppressed with the residual damage it computed.
func suppress_fire(residual_damage_fraction: float) -> Dictionary:
	if state != &"on_fire":
		return CommandQueue.fail(&"E_STATE")
	state = &"damaged"
	condition = clampf(1.0 - residual_damage_fraction, 0.0, 1.0)
	return CommandQueue.ok({"events": [{"type": &"building_damaged", "building": id,
			"cause": &"fire"}]})


## **AN INCIDENT NOBODY COULD ANSWER CONDEMNS; IT DOES NOT DEMOLISH** — doc 93
## §AR2 (Wave 20). The terminal outcome of an incident in a city that has NO
## standing fire station: the building is put at `structural_failure_threshold`
## in `damaged` — doc 02 §2.12's condemned rung, `output_mult` 0.40,
## `coverage_mult` 0.25, doc 03's `f_condition` 0.46 — instead of being deleted.
##
## It is `burn_down`'s sibling, not its replacement: `CityIncidentWorld` decides
## which of the two an incident gets, and it hands a city that HAS a fire
## department the old verb, so a fire the player could have answered and did not
## still takes the building. Wave 19 §AP1 draws this exact line for wear ("wear
## condemns, it may not demolish"); §AR2 says the same sentence about the one
## door §AP1 explicitly left open, and only for the case where the player could
## not have closed it.
##
## The floor is `structural_failure_threshold` and NOT a new number, for §AP2's
## reason: doc 02 §2.6 already names 0.10 as the line below which a building is
## no longer structurally sound, and a second constant meaning the same thing
## would be a second source of truth.
##
## Offline it behaves exactly as `burn_down` and `demolish` do — doc 08 C-47's
## clamp and a refusal — so an absence still cannot change the roster.
func condemn_unanswered(destroy_allowed: bool, now_minutes: int) -> Array:
	if state == &"destroyed" or state == &"planned":
		return []
	if not destroy_allowed:
		condition = maxf(condition, rule("offline_burn_down_clamp"))
		return []
	# **A NEW BUILD HAS NOTHING TO CONDEMN.** `level == 0` is a site that has
	# never completed (`is_new_build`), so there is no standing structure to
	# board up — and putting one in `damaged` at level 0 would strand it: it is
	# no longer `under_construction`, so `complete_construction` can never run,
	# and `damaged` at level 0 is a state doc 02 §2.12's table does not describe.
	# The city loses the site, exactly as it did before this ruling. An UPGRADE
	# in flight (`level >= 1`) is a real building and IS condemned — it falls
	# back to the level it already had, which is `cancel_upgrade`'s own rule.
	if is_new_build():
		return _destroy(now_minutes, &"unanswered")
	condition = minf(condition, rule("structural_failure_threshold"))
	# **THE BOUND — doc 93 §AS2, and it is set on BOTH exits below.** The fire
	# took the fuel; see [burnt_out] for why the ruling has no floor without it.
	burnt_out = true
	if state == &"damaged":
		return []
	state = &"damaged"
	return [{"type": &"building_damaged", "building": id, "cause": &"unanswered"}]


## doc 06 BurnDown — guarded by world.destroy_allowed() (report 98 C-47):
## refused VISIBLY during offline catch-up, never silently swallowed.
func burn_down(destroy_allowed: bool, now_minutes: int) -> Dictionary:
	if state != &"on_fire":
		return CommandQueue.fail(&"E_STATE")
	if not destroy_allowed:
		# doc 08 C-47's clamp; incident stays open. Read from the authored block
		# rather than spelled 0.15 here (Wave 19) — the number never moved, but
		# `data/building_rules.json` has carried `offline_burn_down_clamp` since
		# doc 02 shipped and this was the one reader that ignored it.
		condition = maxf(condition, rule("offline_burn_down_clamp"))
		return CommandQueue.fail(&"E_DESTROY_SUPPRESSED_OFFLINE")
	return CommandQueue.ok({"events": _destroy(now_minutes, &"fire")})


## Incident/disaster damage arriving as a damage_fraction (one pricing path).
##
## **ONE EVENT MAY NOT DEMOLISH A STANDING BUILDING — doc 93 §AP2 (Wave 19).**
## A building ABOVE `structural_failure_threshold` when the damage lands cannot
## be taken past it by that damage, however large the fraction: the worst a
## single event does is CONDEMN. A building already at or below the threshold is
## finished off exactly as before, so nothing is immortal — it takes a second
## event, or a fire, or the city's own neglect to get it there first.
##
## The floor is `structural_failure_threshold` and NOT a new number, deliberately:
## doc 02 §2.6 already names 0.10 as the line below which a building is no longer
## structurally sound, and a second authored constant meaning the same thing
## would be a second source of truth for one idea (C-07's rule, applied to a
## fraction instead of a dollar).
##
## **This door fires zero times on the shipped tables** — doc 92 §56.1 measured
## 45 game-days × 4 presets × 2 session kinds and saw not one `damage`
## destruction — and that is precisely why the guarantee is worth writing down
## now rather than after it fires. §56.4 is about to move the Director's
## pressure, and the promise *"You built it. Now keep it alive"* should not
## depend on nobody ever authoring a damage fraction of 1.0.
##
## The explicit `destroy_building` cascade op does NOT come through here — see
## `CityIncidentWorld.destroy_building`, which now says what it means.
func apply_damage(fraction: float, now_minutes: int,
		may_destroy: bool = true) -> Array:
	if state == &"destroyed" or state == &"planned":
		return []
	var floor_condition := rule("structural_failure_threshold")
	var hit := clampf(condition - fraction, 0.0, 1.0)
	# **`may_destroy` is doc 93 §AR2's second half, and it closes §AP2's own
	# exception where that exception has no argument left** (Wave 20).
	#
	# §AP2's floor is conditional — `if condition > floor_condition` — so a
	# building ALREADY at the structural-failure line is finished off by the next
	# event. That is deliberate and it is fair when the city could have answered
	# the first event and did not. In a city with NO fire department it is not:
	# §AR2 puts unanswered incidents' targets exactly at that line, so without
	# this parameter the ruling would buy the building one game-hour and hand it
	# to the very next hazard. Doc 92 §58.4 measured that: with §AR2's condemn
	# alone the player's save still lost 12 of 12 through this door, `cause:
	# damage`, in place of the ten it used to lose to `cause: fire`.
	#
	# `CityIncidentWorld` is the only caller that passes it, and it passes false
	# on exactly the predicate §AR2 already turns on. Every other caller keeps
	# §AP2 unchanged, so an ordinary city's physics does not move at all.
	if may_destroy:
		condition = maxf(hit, floor_condition) if condition > floor_condition else hit
	else:
		condition = maxf(hit, floor_condition)
	var events: Array = []
	if condition <= 0.0:
		events.append_array(_destroy(now_minutes, &"damage"))
	elif state == &"active" and condition < auto_damage_threshold():
		state = &"damaged"
		events.append({"type": &"building_damaged", "building": id, "cause": &"incident"})
	return events


## Doc 06's `destroy_building` op and doc 07's terminal outcomes: DEMOLISH this
## building outright, whatever its condition. Split out of [apply_damage] by doc
## 93 §AP2 — until Wave 19 the two shared one line (`apply_damage(1.0)`), which
## is why a floor could not be put on damage without also disarming the op that
## means destruction. They were never the same statement: one is *this building
## took a beating*, the other is *this building is gone*.
##
## `destroy_allowed` is doc 08 C-47, on `burn_down`'s own terms: an absence may
## not silently demolish the city, so offline the call clamps the condition to
## the same `offline_burn_down_clamp` floor and refuses, leaving the wreck
## standing where the player can see it.
func demolish(destroy_allowed: bool, now_minutes: int) -> Array:
	if state == &"destroyed" or state == &"planned":
		return []
	if not destroy_allowed:
		condition = maxf(condition, rule("offline_burn_down_clamp"))
		return []
	return _destroy(now_minutes, &"damage")


## damaged/active → repairing. Target: 1.00 preventive from active,
## 0.85 after damage (post-damage repairs never restore to new).
func start_repair() -> Dictionary:
	if state != &"damaged" and state != &"active":
		return CommandQueue.fail(&"E_STATE")
	var target := repair_target()
	state = &"repairing"
	return CommandQueue.ok({"repair_target": target,
			"crew_hours": repair_crew_hours()})


func complete_repair(repair_target: float) -> Dictionary:
	if state != &"repairing":
		return CommandQueue.fail(&"E_STATE")
	state = &"active"
	condition = maxf(condition, repair_target)
	burnt_out = false  # doc 93 §AS2: repaired is rebuilt, and rebuilt burns.
	return CommandQueue.ok({"events": [{"type": &"building_repaired", "building": id}]})


## Crew withdrawn or new damage mid-repair: partial progress kept upstream.
func interrupt_repair() -> Dictionary:
	if state != &"repairing":
		return CommandQueue.fail(&"E_STATE")
	state = &"damaged"
	return CommandQueue.ok()


## destroyed → planned, at the level it fell down at (doc 02 §2.12, re-ruled
## Wave 18 by doc 93 §AN).
##
## **THE LEVEL SURVIVES, ALWAYS, AND THERE IS NO CLOCK ON IT.** Until Wave 18
## this returned `pending_level = level_at_destruction` inside a 72-game-hour
## grace window and `1` after it, plus a `cost_fraction` of 0.60 / 1.00 — and no
## caller ever read either, because until Wave 18 there was no caller at all
## (doc 91 §14.5, A91-D-99). Both halves are retired rather than wired up:
##
##   * **the demotion** deleted the player's own money for missing a deadline.
##     A `house` at L5 carries $37,955 of capital the player paid for rung by
##     rung; coming back at L1 hands them $1,200 of it and burns the rest, for a
##     fire they did not start. A game whose promise is *"You built it. Now keep
##     it alive"* cannot answer a fire by un-building it.
##   * **the window** was 72 game-hours against doc 08's 720-game-hour offline
##     cap — a player who closes the app overnight, which is the scenario this
##     game is DESIGNED around, returns to a city where every ruin has already
##     aged out. It punished exactly the behaviour the product is shaped for.
##
## No price is returned and none is computed here: `sim/buildings/` carries no
## dollar and no dollar fraction (report 98 C-07). `CostCurves.restore_cost_building`
## is the one place a restore is priced, and `CitySim.cmd_restore_building` is
## the one place it is charged. What comes back instead is a FACT the surface
## wants — how long the ruin has been standing — which is not a price at all.
func order_rebuild(now_minutes: int) -> Dictionary:
	if state != &"destroyed":
		return CommandQueue.fail(&"E_STATE")
	pending_level = maxi(level_at_destruction, 1)
	level = 0
	state = &"planned"
	return CommandQueue.ok({"rebuild_level": pending_level,
			"hours_destroyed": maxf(0.0, float(now_minutes - destroyed_at_minutes) / 60.0)})


func _destroy(now_minutes: int, cause: StringName) -> Array:
	state = &"destroyed"
	level_at_destruction = maxi(level, pending_level)
	destroyed_at_minutes = now_minutes
	condition = 0.0
	# Doc 93 §AS2: rubble is not a gutted shell, it is rubble — `state_fire_mult`
	# already answers 0 for `destroyed`, and carrying the flag on a ruin would
	# put a key in [serialize] that says nothing.
	burnt_out = false
	return [{"type": &"building_destroyed", "building": id, "cause": cause}]


# ------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var out := {
		"id": id, "archetype": String(archetype), "variant": String(variant),
		"level": level, "pending_level": pending_level,
		"origin": [origin.x, origin.y], "state": String(state),
		"condition": condition, "built_at_minutes": built_at_minutes,
		"destroyed_at_minutes": destroyed_at_minutes,
		"level_at_destruction": level_at_destruction,
	}
	# **SPARSE ON PURPOSE — doc 93 §AS2, and it is why Wave 21's four
	# `profile_sim` baselines are still comparable with Wave 20's.**
	# `serialize()` is captured into `CitySim.canonical_capture()` and therefore
	# into `state_hash()`, so an unconditional key would move every hash on every
	# city for a flag no city without a gutted shell has ever set. Written only
	# when true; [deserialize] defaults it to false, which is exactly what every
	# save written before this ruling means.
	if burnt_out:
		out["burnt_out"] = true
	return out


static func deserialize(data: Dictionary) -> Building:
	var b := Building.new(int(data.get("id", 0)),
			StringName(String(data.get("archetype", ""))),
			Vector2i(int(data["origin"][0]), int(data["origin"][1])),
			StringName(String(data.get("variant", ""))))
	b.level = int(data.get("level", 0))
	b.pending_level = int(data.get("pending_level", 0))
	b.state = StringName(String(data.get("state", "planned")))
	b.condition = float(data.get("condition", 1.0))
	b.built_at_minutes = int(data.get("built_at_minutes", 0))
	b.destroyed_at_minutes = int(data.get("destroyed_at_minutes", 0))
	b.level_at_destruction = int(data.get("level_at_destruction", 0))
	b.burnt_out = bool(data.get("burnt_out", false))
	return b

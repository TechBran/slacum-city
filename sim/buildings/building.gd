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
func roll_structural_failure(rng: RngStreams, dt_h: float, now_minutes: int) -> Array:
	if state != &"damaged" or condition >= rule("structural_failure_threshold"):
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


## doc 06 BurnDown — guarded by world.destroy_allowed() (report 98 C-47):
## refused VISIBLY during offline catch-up, never silently swallowed.
func burn_down(destroy_allowed: bool, now_minutes: int) -> Dictionary:
	if state != &"on_fire":
		return CommandQueue.fail(&"E_STATE")
	if not destroy_allowed:
		condition = maxf(condition, 0.15)  # doc 08 clamp; incident stays open
		return CommandQueue.fail(&"E_DESTROY_SUPPRESSED_OFFLINE")
	return CommandQueue.ok({"events": _destroy(now_minutes, &"fire")})


## Incident/disaster damage arriving as a damage_fraction (one pricing path).
func apply_damage(fraction: float, now_minutes: int) -> Array:
	if state == &"destroyed" or state == &"planned":
		return []
	condition = clampf(condition - fraction, 0.0, 1.0)
	var events: Array = []
	if condition <= 0.0:
		events.append_array(_destroy(now_minutes, &"damage"))
	elif state == &"active" and condition < auto_damage_threshold():
		state = &"damaged"
		events.append({"type": &"building_damaged", "building": id, "cause": &"incident"})
	return events


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
	return [{"type": &"building_destroyed", "building": id, "cause": cause}]


# ------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	return {
		"id": id, "archetype": String(archetype), "variant": String(variant),
		"level": level, "pending_level": pending_level,
		"origin": [origin.x, origin.y], "state": String(state),
		"condition": condition, "built_at_minutes": built_at_minutes,
		"destroyed_at_minutes": destroyed_at_minutes,
		"level_at_destruction": level_at_destruction,
	}


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
	return b

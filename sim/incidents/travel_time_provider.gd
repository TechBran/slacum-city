class_name TravelTimeProvider
extends RefCounted
## The doc 10 seam (doc 06 §2.10). Doc 06 never owns a road speed, a road class
## multiplier or a weather speed multiplier (C-49): it asks for a travel time
## and takes the answer.
##
## Until doc 10's router lands this class IS the implementation: a deterministic
## Chebyshev-distance model in whole game-seconds. Doc 10 replaces it by
## subclassing and overriding `travel_gs()`; nothing else in sim/incidents/
## changes, because every caller goes through `eta_gs()`.
##
## Whole game-seconds, not float minutes, because arrival time is persisted
## state and an integer round-trips a save exactly. Constitution §6: 1 tile = 8 m.

const METRES_PER_TILE := 8.0
const GAME_SECONDS_PER_GAME_MINUTE := 60
## Sentinel for "no route exists" (doc 06 §2.10: route_minutes returns INF, the
## unit is skipped and the incident is flagged `unreachable`).
const UNREACHABLE_GS := 1 << 40

## Fallback when a profile carries no speed of its own.
var default_speed_mpgm: float = 24.0
## Tiles the caller may not cross; doc 10 replaces this with its closure table.
var blocked_tiles: Dictionary = {}
## Global "every route to here is cut" set, for the unreachable path in tests
## and for doc 10's closure results.
var unreachable_tiles: Dictionary = {}


## Travel time between two GLOBAL tiles, in whole game-seconds.
## `profile` is doc 06's RouteProfile: exactly {speed_mpgm, siren,
## ignores_closures, capabilities} (C-49 — no weather_mult, no flood_mult).
func travel_gs(from: Vector2i, to: Vector2i, profile: Dictionary = {}) -> int:
	if unreachable_tiles.has(_key(to)) or unreachable_tiles.has(_key(from)):
		return UNREACHABLE_GS
	if blocked_tiles.has(_key(to)) and not bool(profile.get("ignores_closures", false)):
		return UNREACHABLE_GS
	var speed := float(profile.get("speed_mpgm", default_speed_mpgm))
	if bool(profile.get("siren", false)):
		speed *= float(profile.get("siren_mult", 1.0))
	if speed <= 0.0:
		return UNREACHABLE_GS
	var tiles := maxi(absi(to.x - from.x), absi(to.y - from.y))
	var metres := float(tiles) * METRES_PER_TILE
	# metres / (metres per game-minute) = game-minutes; × 60 = game-seconds.
	return int(round(metres / speed * float(GAME_SECONDS_PER_GAME_MINUTE)))


## The STREETS the vehicle drives, as a tile polyline from `from` to `to`
## inclusive (doc 06 §2.11 / doc 10 §2.8). EMPTY means "this provider knows no
## street network" — doc 06 then paces the trip along the straight segment it has
## always used, which is the pre-doc-10 behaviour exactly.
##
## The polyline never carries a DURATION. `travel_gs()` above is still the only
## answer to "when does it arrive"; this is the same trip's shape, and doc 06
## distributes the one over the other (`Vehicle.update_motion`).
func route_tiles(_from: Vector2i, _to: Vector2i, _profile: Dictionary = {}) -> Array:
	return []


## Turnout + travel, the number §2.10's cost function ranks on.
func eta_gs(from: Vector2i, to: Vector2i, profile: Dictionary = {},
		turnout_min: float = 0.0) -> int:
	var travel := travel_gs(from, to, profile)
	if travel >= UNREACHABLE_GS:
		return UNREACHABLE_GS
	return int(round(turnout_min * float(GAME_SECONDS_PER_GAME_MINUTE))) + travel


func is_reachable(from: Vector2i, to: Vector2i, profile: Dictionary = {}) -> bool:
	return travel_gs(from, to, profile) < UNREACHABLE_GS


# ------------------------------------------------ ranking before quoting
#
# Doc 10 §2.14 publishes a two-step contract to doc 06 because a real route is a
# search and an estimate is arithmetic: *"rank every candidate unit with
# `estimate_eta_practical` (O(1) …), then call `route_minutes` for only the top
# `DISPATCH_CANDIDATES = 3`."* §2.10's assignment loop reads exactly these three
# methods to obey it. **On THIS class all three degrade to the exact answer**, so
# a provider with no street network ranks and quotes identically and every doc 06
# test written before doc 10 still measures what it measured.


## How many candidates the assignment loop may pay a REAL quote for after
## ranking. **0 means "quote everyone"** — the honest answer for a provider whose
## quote is arithmetic, and the reason this seam does not change the pre-router
## ranking by so much as a tie-break.
func dispatch_candidates() -> int:
	return 0


## The O(1) ranking estimate: same units as [eta_gs], same turnout, no search.
## Identical to `eta_gs` here, because there is nothing cheaper to be.
func estimate_eta_gs(from: Vector2i, to: Vector2i, profile: Dictionary = {},
		turnout_min: float = 0.0) -> int:
	return eta_gs(from, to, profile, turnout_min)


## The cheap half of reachability, used to drop hopeless candidates BEFORE the
## quote budget is spent. It may answer `true` for a route that a real quote
## later refuses (doc 10 §4: the component test is class-aware only for hard
## blocks) — which is why the assignment loop still decides `unreachable` on a
## real quote and never on this.
func is_reachable_estimate(from: Vector2i, to: Vector2i, profile: Dictionary = {}) -> bool:
	return is_reachable(from, to, profile)


## Doc 10 §2.11's road-access quality at a position, ∈ [0,1]. 1.0 until the
## router lands; §2.4's `access_factor` reads it and nothing else.
func access_quality(_tile: Vector2i) -> float:
	return 1.0


## A counter that changes whenever [access_quality] could answer differently and
## never otherwise, so doc 06 can memoise the answer per tile instead of paying
## doc 10's ring search once per incident per integrator sub-step. **0 forever**
## here, which is correct: this class's `access_quality` is a constant.
func access_epoch() -> int:
	return 0


## Doc 10's per-edge congestion, ∈ [0,2]. Zero until the router lands.
func congestion_index(_tile: Vector2i) -> float:
	return 0.0


## Doc 10 §2.11 `condition_hazard_mult`, on the [0,1] road-condition scale
## (RR-3). 1.00 for a pristine road; doc 06 never rescales the return value.
func condition_hazard_mult(_tile: Vector2i) -> float:
	return 1.0


func set_unreachable(tile: Vector2i, value: bool = true) -> void:
	if value:
		unreachable_tiles[_key(tile)] = true
	else:
		unreachable_tiles.erase(_key(tile))


static func _key(tile: Vector2i) -> String:
	return "%d,%d" % [tile.x, tile.y]

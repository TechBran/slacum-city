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


## Turnout + travel, the number §2.10's cost function ranks on.
func eta_gs(from: Vector2i, to: Vector2i, profile: Dictionary = {},
		turnout_min: float = 0.0) -> int:
	var travel := travel_gs(from, to, profile)
	if travel >= UNREACHABLE_GS:
		return UNREACHABLE_GS
	return int(round(turnout_min * float(GAME_SECONDS_PER_GAME_MINUTE))) + travel


func is_reachable(from: Vector2i, to: Vector2i, profile: Dictionary = {}) -> bool:
	return travel_gs(from, to, profile) < UNREACHABLE_GS


## Doc 10 §2.11's road-access quality at a position, ∈ [0,1]. 1.0 until the
## router lands; §2.4's `access_factor` reads it and nothing else.
func access_quality(_tile: Vector2i) -> float:
	return 1.0


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

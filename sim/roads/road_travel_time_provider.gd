class_name RoadTravelTimeProvider
extends TravelTimeProvider
## The real TravelTimeProvider (doc 10 over doc 06's seam): `travel_gs` is
## `route_minutes × 60`, rounded to whole game-seconds, for one fixed
## RouteProfile.
##
## Doc 06 holds one of these per vehicle type (the profile carries doc 06's own
## `speed_mpgm`, siren multiplier already folded in) and never needs to know
## RoadNetwork exists. The value is authoritative and mode-invariant: identical
## (graph_version, quantised congestion, closure_epoch, profile) ⇒ identical
## answer in fine and coarse steps.
##
## RoadNetwork's own integer API answers -1 for UNREACHABLE; doc 06's ranking
## contract needs a sentinel that can never win a min() — the mapping happens
## here, at the seam, so neither side changes its convention.

var network: RoadNetwork
var profile: RouteProfile


func _init(p_network: RoadNetwork, p_profile: RouteProfile) -> void:
	network = p_network
	profile = p_profile


func travel_gs(from: Vector2i, to: Vector2i, route_profile: Dictionary = {}) -> int:
	if network == null:
		return super.travel_gs(from, to, route_profile)
	var gs := network.travel_gs_for(from, to, profile)
	return UNREACHABLE_GS if gs < 0 else gs


## The street polyline for the SAME route `travel_gs` just priced: both go
## through `planner.quote()`, so they come out of one cache entry and the shape
## and the duration can never describe two different trips.
func route_tiles(from: Vector2i, to: Vector2i, _route_profile: Dictionary = {}) -> Array:
	if network == null:
		return []
	return network.route_tiles(from, to, profile)


## The turnout-free form of `estimate_eta_gs`, kept because doc 12's unit picker
## asks the same question without a turnout to add. One implementation, so the
## picker and the dispatcher can never rank on two different estimates.
func estimate_gs(from: Vector2i, to: Vector2i) -> int:
	return estimate_eta_gs(from, to)


# ------------------------------------------------ ranking before quoting
#
# Doc 10 §2.14's two-step contract, made real. A quote here is an **A\* on the
# contracted graph** — measured at ~5 ms on the benchmark city's 3,132 road
# tiles — and the route cache cannot absorb it, because a responding unit's
# position is the cache key's first half and it changes every tile it drives.
# Quoting every capable unit therefore costs the incident phase **163 ms per
# coarse game-hour** on that city, against a whole-step budget of 166. Ranking
# on the O(1) estimate and quoting three is doc 10's own answer, published as a
# tunable (`data/roads.json` `routing.dispatch_candidates`) since before doc 06
# had a router to spend it on.


func dispatch_candidates() -> int:
	return 0 if network == null else network.dispatch_candidates()


func estimate_eta_gs(from: Vector2i, to: Vector2i, _route_profile: Dictionary = {},
		turnout_min: float = 0.0) -> int:
	if network == null:
		return super.estimate_eta_gs(from, to, _route_profile, turnout_min)
	var minutes := network.estimate_eta_practical(from, to, profile)
	if is_inf(minutes):
		return UNREACHABLE_GS
	return int(round(turnout_min * float(GAME_SECONDS_PER_GAME_MINUTE))) \
			+ roundi(minutes * 60.0)


## Doc 10 §4's component test: a snap at each end and one integer compare, with
## no search anywhere. Conservative by design — it answers `true` while the
## component labelling is incomplete — so it can only ever admit a candidate the
## real quote then rejects, never hide one.
func is_reachable_estimate(from: Vector2i, to: Vector2i,
		route_profile: Dictionary = {}) -> bool:
	if network == null:
		return super.is_reachable_estimate(from, to, route_profile)
	return network.is_reachable(from, to, profile)


# ------------------------------------------- the other three published inputs
#
# Doc 10 §7's published surface to doc 06 is FOUR things, not one: `route_minutes`
# plus `access_quality`, `congestion_index` and `condition_hazard_mult`. Only the
# first was overridden when this class landed, so the other three were still
# answering with `TravelTimeProvider`'s pre-router constants (1.0 / 0.0 / 1.0)
# behind a provider whose whole job is that it knows the streets. A road can now
# be blocked, collapsed or nowhere near the incident and doc 06 will hear about
# it — through doc 10's own formulas, unrescaled (C-48/C-61).


## Doc 10 §2.11's tile-level road access, `∈ [0,1]` (report 98 C-61: the SINGLE
## definition, consumed by docs 02, 03 and 06 alike). Doc 06 §2.4 reads it once,
## through `IncidentSystem.access_factor`'s `< 0.60` knee.
func access_quality(tile: Vector2i) -> float:
	if network == null:
		return super.access_quality(tile)
	return network.access_quality(tile)


func access_epoch() -> int:
	return 0 if network == null else network.access_epoch()


## Doc 10 §2.10's per-edge congestion at the incident's position, `∈ [0,2]`.
## Doc 06 uses it as a FALLBACK only — a generator that already knows which
## intersection it picked pins `context["congestion_index"]` and this is never
## consulted for it. What reaches this path is everything doc 06 did not author:
## a doc 07 Director accident, a cascade child, a manually spawned incident.
func congestion_index(tile: Vector2i) -> float:
	if network == null:
		return super.congestion_index(tile)
	return network.congestion_index_at(tile)


## Doc 10 §2.11's road-condition hazard multiplier at a position. Doc 06 folds it
## into `traffic_accident` weighting per C-48 and never rescales the return value.
func condition_hazard_mult(tile: Vector2i) -> float:
	if network == null:
		return super.condition_hazard_mult(tile)
	return network.condition_hazard_mult_at(tile)

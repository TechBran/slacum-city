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


## Convenience for doc 06's ranking pass: O(1), no search, never over-estimates.
func estimate_gs(from: Vector2i, to: Vector2i) -> int:
	if network == null:
		return super.travel_gs(from, to)
	var minutes := network.estimate_eta_practical(from, to, profile)
	return UNREACHABLE_GS if is_inf(minutes) else roundi(minutes * 60.0)

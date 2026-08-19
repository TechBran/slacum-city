class_name RoadTravelTimeProvider
extends TravelTimeProvider
## The real TravelTimeProvider: `travel_gs` is `route_minutes × 60`, rounded to
## whole game-seconds, for one fixed RouteProfile.
##
## Doc 06 holds one of these per vehicle type (the profile carries doc 06's own
## `speed_mpgm`, siren multiplier already folded in) and never needs to know
## RoadNetwork exists. The value is authoritative and mode-invariant: identical
## (graph_version, quantised congestion, closure_epoch, profile) ⇒ identical
## answer in fine and coarse steps.

var network: RoadNetwork
var profile: RouteProfile


func _init(p_network: RoadNetwork, p_profile: RouteProfile) -> void:
	network = p_network
	profile = p_profile


func travel_gs(from: Vector2i, to: Vector2i) -> int:
	if network == null:
		return flat_gs
	return network.travel_gs_for(from, to, profile)


## Convenience for doc 06's ranking pass: O(1), no search, never over-estimates.
func estimate_gs(from: Vector2i, to: Vector2i) -> int:
	if network == null:
		return flat_gs
	return roundi(network.estimate_eta_practical(from, to, profile) * 60.0)

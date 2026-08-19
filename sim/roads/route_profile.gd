class_name RouteProfile
extends RefCounted
## Doc 10 §4: the routing profile doc 06 builds from its vehicle table.
##
## `speed_mpgm` is DOC 06's (siren_mult already folded in); doc 10 publishes no
## absolute vehicle speed. `route_class` selects the privilege triple
## (cong_relief / node_relief / wx_resist) from `data/roads.json`.
## Report 98 C-49: the profile carries NO weather_mult and NO flood_mult —
## roads applies weather via wx_resist and flood via the closure table, and
## carrying them here would double-count.

enum RouteClass { EMERGENCY = 0, UTILITY = 1, CONSTRUCTION = 2, CIVILIAN = 3 }
enum RouteFail { NONE = 0, NO_ROAD_NEAR_ORIGIN = 1, NO_ROAD_NEAR_DEST = 2,
		UNREACHABLE = 3, BUDGET_EXCEEDED = 4 }
enum InvalidReason { CLOSURE = 0, GRAPH = 1, COLLAPSE = 2 }

## Doc 10 §2.15's only absolute speed, used by the cosmetic layer alone.
const CIVILIAN_BASE_SPEED_MPGM: float = 34.0

var speed_mpgm: float = 32.0
var route_class: int = RouteClass.CIVILIAN
## true ⇒ the second-chance pass may admit SOFT-blocked edges at
## DESPERATE_BLOCK_MULT. Hard blocks (flood_deep, COLLAPSED) are never admitted.
var ignores_closures: bool = false
## 0 = critical … 3 = routine. ≤ critical_priority_max routes with ε = 1.0.
var priority: int = 2


func _init(p_speed_mpgm: float = 32.0, p_route_class: int = RouteClass.CIVILIAN,
		p_ignores_closures: bool = false, p_priority: int = 2) -> void:
	speed_mpgm = p_speed_mpgm
	route_class = p_route_class
	ignores_closures = p_ignores_closures
	priority = p_priority


static func emergency(speed_mpgm: float, priority: int = 0) -> RouteProfile:
	return RouteProfile.new(speed_mpgm, RouteClass.EMERGENCY, false, priority)


static func utility(speed_mpgm: float, priority: int = 2) -> RouteProfile:
	return RouteProfile.new(speed_mpgm, RouteClass.UTILITY, false, priority)


static func construction(speed_mpgm: float, priority: int = 3) -> RouteProfile:
	return RouteProfile.new(speed_mpgm, RouteClass.CONSTRUCTION, false, priority)


static func civilian(speed_mpgm: float = CIVILIAN_BASE_SPEED_MPGM) -> RouteProfile:
	return RouteProfile.new(speed_mpgm, RouteClass.CIVILIAN, false, 3)


func duplicate_profile() -> RouteProfile:
	return RouteProfile.new(speed_mpgm, route_class, ignores_closures, priority)


## Stable cache discriminator. Speed is bucketed to 1e-3 m/gm so float noise in
## doc 06's siren_mult product cannot fragment the LRU.
func cache_key() -> String:
	return "%d|%d|%d" % [route_class, roundi(speed_mpgm * 1000.0), 1 if ignores_closures else 0]

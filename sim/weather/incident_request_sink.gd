class_name IncidentRequestSink
extends RefCounted
## The seam between the Disaster Director (doc 07, this subsystem) and the
## incident/dispatch system (doc 06, built in parallel).
##
## The Director REQUESTS; doc 06 EXECUTES. Doc 06 owns all incident generation
## including storm damage (report 98 C-53), so nothing in `sim/weather/` may
## create an incident object, roll a line failure or dispatch a unit. The whole
## contract is one method:
##
##     func request_incident(kind: StringName, target: Dictionary) -> void
##
## `kind` is a catalog id (`traffic_pileup`, `storm_damage`, `structure_fire`, …).
## `target` carries whatever the requester knows and nothing it doesn't:
##   {event_uid: int, ref: String, domain: String, district_id: String,
##    severity_mult: float, pos: Vector2, reason: String, hazard_tier: int}
##
## Doc 06 is free to refuse, re-target or downgrade a request — the Director
## never assumes an incident exists because it asked for one.

func request_incident(_kind: StringName, _target: Dictionary) -> void:
	pass


## Test/bring-up double: records every request in order.
class Recording extends IncidentRequestSink:
	var requests: Array = []

	func request_incident(kind: StringName, target: Dictionary) -> void:
		requests.append({"kind": kind, "target": target.duplicate()})

	func kinds() -> Array:
		var out: Array = []
		for request in requests:
			out.append(String(request["kind"]))
		return out

	func count_of(kind: String) -> int:
		var count := 0
		for request in requests:
			if String(request["kind"]) == kind:
				count += 1
		return count

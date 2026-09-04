class_name DispatchSystem
extends RefCounted
## Priority scoring (doc 06 §2.9) and the greedy nearest-available assignment
## loop (§2.10). Deterministic by construction: every iteration is over an
## id-sorted array and every tie breaks on ascending unit id.
##
## `system` is the owning IncidentSystem, held UNTYPED on purpose — a typed
## back-reference would make IncidentSystem and DispatchSystem a cyclic
## class_name pair.

var catalog: IncidentCatalog
var fleet: FleetSystem
var policy: DispatchPolicy
var world: IncidentWorld
var travel: TravelTimeProvider
var system  # IncidentSystem

var stats: Dictionary = {
	"resolved_total": 0, "failed_total": 0, "abandoned_total": 0,
	"avg_response_min": 0.0, "rolling_response_score": 1.0,
	"response_samples": 0,
}

var _events: Array = []

## Top-K candidate buffer for §2.10's rank-then-quote pass, GROWN AND NEVER
## SHRUNK and never longer than `_rank_cap`. Three parallel arrays rather than
## an array of dictionaries, for one measured reason: the assignment scan is
## `open_incidents × capable_units` on EVERY integrator sub-step, and a city in
## collapse runs it with forty-odd open incidents at six hundred sub-steps a
## game-day. One Dictionary allocated per candidate there is a quarter of a
## million allocations per game-day, which is the same shape of mistake the
## traffic generator's scratch buffer exists to avoid (`IncidentSystem`).
var _rank_units: Array = []
var _rank_penalty: PackedFloat64Array = PackedFloat64Array()
var _rank_score: PackedFloat64Array = PackedFloat64Array()
var _rank_used: int = 0
var _rank_cap: int = 0

## incident id -> the `travel.access_epoch()` at which every capable unit's route
## to it came back `INF`. **Reachability is a fact about the ROAD NETWORK, not
## about where the trucks happen to be standing**: doc 10 answers it by comparing
## road-graph components, and a unit cannot leave its own component without a
## route out of it. So an incident that nothing could reach stays unreachable
## until a road is built, repaired, collapsed, closed or reopened — every one of
## which moves `access_epoch()`. Until then, re-pricing it is provably wasted
## work, and on a rotting city it is the difference between a bounded assignment
## pass and one that re-runs a full A\* sweep for hundreds of unanswerable
## incidents on every integrator sub-step.
##
## Derived, not saved: a loaded city simply re-discovers it on the first pass.
## The whole set is dropped the moment the epoch moves, which is also what keeps
## it from growing: it can never hold more than the live roster.
var _unreachable_at_epoch: Dictionary = {}
var _unreachable_epoch: int = -1


func _init(p_catalog: IncidentCatalog, p_fleet: FleetSystem, p_policy: DispatchPolicy,
		p_world: IncidentWorld, p_travel: TravelTimeProvider) -> void:
	catalog = p_catalog
	fleet = p_fleet
	policy = p_policy
	world = p_world
	travel = p_travel


# ------------------------------------------------------------------ scoring

func priority(inc: Incident, cluster_size: int, now_h: float) -> float:
	var row := catalog.type_row(inc.type, inc.subtype)
	var w_type := float(catalog.scoring.get("w_type", 60.0))
	var w_sev := float(catalog.scoring.get("w_sev", 45.0))
	var w_wait := float(catalog.scoring.get("w_wait", 30.0))
	var wait_cap := float(catalog.scoring.get("wait_cap_h", 3.0))
	var w_exposure := float(catalog.scoring.get("w_exposure", 70.0))
	var w_life := float(catalog.scoring.get("w_life", 120.0))
	var w_coverage := float(catalog.scoring.get("w_coverage", 90.0))
	var pin_bonus := float(catalog.scoring.get("pin_bonus", 500.0))
	var cluster_bonus := float(catalog.scoring.get("cluster_bonus", 25.0))

	var score := w_type * float(row.get("type_priority", 1))
	score += w_sev * (inc.severity - 1.0)
	score += w_wait * minf(inc.wait_hours(now_h), wait_cap)
	score += w_exposure * exposure(inc)
	score += w_life * (1.0 if life_safety(inc) else 0.0)
	score -= w_coverage * coverage(inc)
	if inc.pinned:
		score += pin_bonus
	score += cluster_bonus * float(maxi(0, cluster_size - 1))
	return score


## §2.9 `exposure(inc) ∈ [0,1]`. `inc.context` overrides let a generator (or a
## test) pin the inputs it already knows; everything else is queried live.
func exposure(inc: Incident) -> float:
	var ex: Dictionary = catalog.exposure
	match inc.type:
		"structure_fire":
			var occupants := float(inc.context.get("occupants", _occupants_of_target(inc)))
			var neighbours := float(inc.context.get("neighbour_occupants",
					_neighbour_occupants(inc, float(ex.get("fire_neighbour_radius_m", 24.0)))))
			var reference := maxf(1.0, float(ex.get("fire_pop_ref", 400.0)))
			return clampf((occupants + float(ex.get("fire_neighbour_k", 0.4)) * neighbours)
					/ reference, 0.0, 1.0)
		"transformer_failure":
			var customers := float(inc.context.get("customers_downstream",
					world.power_customers_downstream(inc.target_component_id())))
			var base := clampf(customers / maxf(1.0, float(ex.get("customers_ref", 800.0))), 0.0, 1.0)
			if bool(inc.context.get("critical_downstream", false)):
				base += float(ex.get("critical_facility_bonus", 0.35))
			return clampf(base, 0.0, 1.0)
		"water_main_break":
			var customers2 := float(inc.context.get("customers_downstream", 0.0))
			var base2 := clampf(customers2 / maxf(1.0, float(ex.get("customers_ref", 800.0))), 0.0, 1.0)
			if bool(inc.context.get("fire_in_zone", false)):
				base2 += float(ex.get("fire_in_zone_bonus", 0.30))
			return clampf(base2, 0.0, 1.0)
		"traffic_accident":
			var congestion := float(inc.context.get("congestion_index",
					travel.congestion_index(inc.tile)))
			return clampf(congestion / maxf(0.001, float(ex.get("congestion_ref", 1.5))), 0.0, 1.0)
		"crime":
			var d := world.district(inc.district_id)
			var pop := float(inc.context.get("district_pop", d.get("population", 0)))
			var stability := float(inc.context.get("stability", d.get("stability", 1.0)))
			return clampf(float(ex.get("crime_pop_w", 0.6))
					* clampf(pop / maxf(1.0, float(ex.get("crime_pop_ref", 6000.0))), 0.0, 1.0)
					+ float(ex.get("crime_stability_w", 0.4)) * (1.0 - stability), 0.0, 1.0)
		"storm_damage":
			return clampf(float(inc.context.get("asset_exposure", 0.4)), 0.0, 1.0)
	return 0.0


func life_safety(inc: Incident) -> bool:
	if inc.type == "structure_fire" and inc.tier() >= 2:
		return float(inc.context.get("occupants", _occupants_of_target(inc))) > 0.0
	if inc.type == "traffic_accident":
		return bool(inc.context.get("injury", false))
	return false


## §2.9's `coverage` is the ASSIGNED rate, so a unit already en route counts —
## an incident with a truck two minutes out is not an uncovered incident.
func coverage(inc: Incident) -> float:
	var required: float = system.required_rate(inc)
	if required <= 0.0:
		return 1.0
	var committed: float = system.committed_effective_rate(inc)
	return clampf(committed / required, 0.0, 1.0)


func _occupants_of_target(inc: Incident) -> float:
	var building_id := inc.target_building_id()
	if building_id == "":
		return 0.0
	return float(world.building(building_id).get("occupants", 0))


func _neighbour_occupants(inc: Incident, radius_m: float) -> float:
	var total := 0.0
	for other_id in world.buildings_within_m(inc.tile, radius_m, inc.target_building_id()):
		total += float(world.building(String(other_id)).get("occupants", 0))
	return total


# ------------------------------------------------------------- assignment

## One assignment pass. `incidents` is the live id-sorted array of non-terminal
## incidents; the caller has already refreshed `priority_cache`.
func assign_tick(incidents: Array, now_h: float) -> void:
	var max_assignments := int(catalog.assignment.get("max_assignments_per_tick", 16))
	var reassign_threshold := float(catalog.assignment.get("reassign_threshold", 120))
	var reassign_penalty := float(catalog.assignment.get("reassign_penalty_min", 12))
	var reserve_penalty := float(catalog.assignment.get("reserve_penalty_min", 45))
	var role_fit_penalty := float(catalog.assignment.get("role_fit_penalty_min", 30))
	var max_cost := float(catalog.assignment.get("max_acceptable_cost_min", 90))
	var preempt_priority := float(catalog.assignment.get("construction_preempt_priority", 400))

	var queue: Array = []
	for inc in incidents:
		var incident: Incident = inc
		if incident.is_terminal():
			continue
		if coverage(incident) >= 1.0 and _primary_count_met(incident):
			continue
		queue.append(incident)
	queue.sort_custom(func(a: Incident, b: Incident) -> bool:
		if absf(a.priority_cache - b.priority_cache) > 1e-9:
			return a.priority_cache > b.priority_cache
		if absf(a.created_h - b.created_h) > 1e-12:
			return a.created_h < b.created_h
		return a.id < b.id)

	var assignments_made := 0
	# **THE ROUTE-QUOTE ALLOWANCE FOR THIS PASS.** §2.10 has always capped
	# ASSIGNMENTS per tick at 16; it never needed to cap the work of *looking*,
	# because a Chebyshev ETA is arithmetic. Under doc 10's router a quote is an
	# A\* (~5 ms), and the loop below walks the WHOLE queue — an incident that
	# finds no unit inside `MAX_ACCEPTABLE_COST` does not increment
	# `assignments_made`, so it never reaches the `break` above, and it pays for
	# another three quotes on the next sub-step, and the next.
	#
	# The allowance is `max_assignments × dispatch_candidates`: exactly enough
	# quotes to make every assignment this tick is permitted to make, and not one
	# more. The queue is priority-sorted, so the budget is spent on the most
	# urgent incidents, and one it could not afford this sub-step keeps its place
	# and gains priority from `w_wait` while it waits. **Zero means unlimited**,
	# which is what doc 06's own stand-in provider answers, so a city with no
	# street network behaves exactly as it always did — every tie-break included.
	#
	# **It is necessary and it is not sufficient, and that is measured.** With
	# the router wired, doc 92's `greedy_growth` agent at seed 4242 goes from
	# 12.6 s for a 21-game-day run to over twenty minutes, and this allowance
	# does not move it — because the cost is not the quoting. Real ETAs across a
	# collapsed, flood-closed network push `eta + penalties` past
	# `MAX_ACCEPTABLE_COST`, incidents stop being answered at all, and §2.10 has
	# no terminal rule for one nobody can answer, so the open roster grows without
	# bound and everything that is O(open) grows with it. That is the reason
	# `CitySim` still constructs doc 06's stand-in; see its comment at the seam.
	var quote_budget_per_need := travel.dispatch_candidates()
	var quote_allowance := max_assignments * quote_budget_per_need
	var access_epoch := travel.access_epoch()
	if access_epoch != _unreachable_epoch:
		_unreachable_epoch = access_epoch
		_unreachable_at_epoch.clear()
	for incident in queue:
		if assignments_made >= max_assignments:
			break
		if quote_budget_per_need > 0 and quote_allowance <= 0:
			break
		# Nothing can have reached it since the roads last moved — see
		# `_unreachable_at_epoch`. Skipping BEFORE `unmet_needs` is the point:
		# that call walks the fleet too.
		if incident.unreachable \
				and int(_unreachable_at_epoch.get(incident.id, -1)) == access_epoch:
			continue
		var damage_estimate: float = system.expected_damage_fraction(incident)
		for need in unmet_needs(incident):
			if assignments_made >= max_assignments:
				break
			var role := String(need)
			var best: Vehicle = null
			var best_cost := INF
			var any_candidate := false
			var any_allowed := false
			var any_reachable := false
			# **RANK, THEN QUOTE** (doc 10 §2.14, adopted here because doc 10's
			# router is now what answers `eta_h`). A real quote is an A\* — ~5 ms
			# on the benchmark city — and the route cache cannot amortise it,
			# because half the key is a responding unit's tile and that changes
			# every tile it drives. `dispatch_candidates()` is 0 for a provider
			# whose quote is arithmetic, and the loop below then behaves exactly
			# as it did before doc 10 was wired in, tie-breaks included.
			#
			# **Nothing in the ranking walk may touch the road graph.** The walk
			# is `open_incidents × capable_units` per sub-step and a collapsing
			# city runs it hundreds of times a game-day; `estimate_eta_practical`
			# is arithmetic, and the reachability screen — which is two ring
			# searches — is deferred to the quote pass, where it runs at most
			# `_rank_cap` times instead of once per candidate.
			var quote_budget := quote_budget_per_need
			if quote_budget > 0:
				quote_budget = mini(quote_budget, quote_allowance)
				if quote_budget <= 0:
					break
			_rank_reset(quote_budget)
			# Read-only walk of the fleet's own ascending order — see
			# `FleetSystem.unit_ids_ref`. Nothing in this loop adds or removes a
			# unit; `_assign` runs after it, on the winner.
			for unit_id in fleet.unit_ids_ref():
				var u: Vehicle = fleet.unit(unit_id)
				if not u.has_capability_for(role):
					continue
				if not u.is_dispatchable_now():
					continue
				if u.manual_lock:
					continue
				if u.status == Vehicle.ON_SCENE:
					continue  # never strip an on-scene unit automatically
				if incident.assigned.has(u.id):
					continue
				if u.status == Vehicle.RESPONDING:
					var other: Incident = system.incident(u.incident_id)
					if other != null and incident.priority_cache - other.priority_cache \
							< reassign_threshold:
						continue
				if u.construction_job_id != 0 and incident.priority_cache < preempt_priority:
					continue
				any_candidate = true
				if not policy.allows(u, incident, incident.priority_cache, fleet, world,
						damage_estimate):
					continue
				any_allowed = true
				# The three penalties are part of the ORDERING, so the ranking
				# pass has to carry them or it would rank on a different number
				# from the one the winner is chosen on.
				var penalty := 0.0
				if u.status == Vehicle.RESPONDING:
					penalty += reassign_penalty
				if policy.breaks_reserve(u, fleet):
					penalty += reserve_penalty
				penalty += role_fit_penalty * (1.0 - u.role_fit(role))
				if quote_budget <= 0:
					var eta := fleet.eta_h(u, incident.tile)
					if is_inf(eta):
						continue
					any_reachable = true
					var cost := eta * 60.0 + penalty
					if cost < best_cost - 1e-9 or (absf(cost - best_cost) <= 1e-9 and best != null and u.id < best.id):
						best_cost = cost
						best = u
					continue
				var estimate := fleet.estimate_h(u, incident.tile)
				if is_inf(estimate):
					continue
				_rank_offer(u, penalty, estimate * 60.0 + penalty)
			if quote_budget > 0 and _rank_used > 0:
				var quoted := 0
				for i in _rank_used:
					var u2: Vehicle = _rank_units[i]
					# Cheap screen first: a unit in another road component can
					# never win, and finding that out must not cost a search.
					if not fleet.maybe_reachable(u2, incident.tile):
						continue
					var eta2 := fleet.eta_h(u2, incident.tile)
					if is_inf(eta2):
						# The screen was conservative and this route really is
						# cut. It cost a quote and bought no candidate, so it
						# does not spend the budget — otherwise a city with one
						# severed block would report "unreachable" for incidents
						# that three other trucks can reach. `_rank_cap` is what
						# stops that generosity from becoming a full fleet sweep.
						continue
					any_reachable = true
					var cost2 := eta2 * 60.0 + _rank_penalty[i]
					if cost2 < best_cost - 1e-9 or (absf(cost2 - best_cost) <= 1e-9 and best != null and u2.id < best.id):
						best_cost = cost2
						best = u2
					quoted += 1
					if quoted >= quote_budget:
						break
				quote_allowance -= quoted
			if best != null and best_cost <= max_cost:
				_assign(best, incident, role, now_h, false)
				assignments_made += 1
				incident.context.erase("blocked_reason")
				incident.unreachable = false
				_unreachable_at_epoch.erase(incident.id)
			elif any_candidate and any_allowed and not any_reachable:
				# Doc 10 says there is no route: that is a different problem for
				# the player than "no truck is free", and the UI says so.
				incident.unreachable = true
				_unreachable_at_epoch[incident.id] = access_epoch
				_emit_blocked(incident, "dispatch_blocked_unreachable", role)
			else:
				_emit_blocked(incident, "dispatch_blocked_no_units", role)


# ------------------------------------------------ the top-K candidate buffer
#
# `quote_budget` candidates get a real route quote, but the buffer keeps
# **four times** that many, because a quote can come back `INF` (a hard closure
# the O(1) component screen cannot see) and a candidate that bought nothing must
# not spend the budget. Four is the smallest multiple that makes "all of them
# are cut but a fifth truck could have got there" a case this loop can be wrong
# about — and it can only be wrong in the direction of reporting `unreachable`
# for an incident four separately-ranked units all failed to reach, on a road
# graph where the component test already said they were connected. The cap is
# what keeps a severed city from paying a full-fleet A\* sweep per sub-step.


func _rank_reset(quote_budget: int) -> void:
	_rank_used = 0
	_rank_cap = maxi(1, quote_budget * 4)


## Offer one candidate. Keeps the buffer sorted ascending on `(score, unit id)`
## — the SAME tie-break the winner selection uses, so ranking can never impose
## an ordering the quoted pass would not have chosen itself — and drops the
## worst entry once the cap is reached. No allocation after warm-up.
func _rank_offer(unit: Vehicle, penalty: float, score: float) -> void:
	var slot := _rank_used
	while slot > 0:
		var prev := slot - 1
		var prev_score := _rank_score[prev]
		if prev_score < score - 1e-9:
			break
		if absf(prev_score - score) <= 1e-9 and int((_rank_units[prev] as Vehicle).id) < unit.id:
			break
		slot = prev
	if slot >= _rank_cap:
		return                      # worse than everything already kept
	# Grow to hold one more, up to the cap.
	var target := mini(_rank_cap, _rank_used + 1)
	while _rank_units.size() < target:
		_rank_units.append(null)
		_rank_penalty.append(0.0)
		_rank_score.append(0.0)
	# Shift the tail down one place; the entry falling off the end is dropped.
	var i := target - 1
	while i > slot:
		_rank_units[i] = _rank_units[i - 1]
		_rank_penalty[i] = _rank_penalty[i - 1]
		_rank_score[i] = _rank_score[i - 1]
		i -= 1
	_rank_units[slot] = unit
	_rank_penalty[slot] = penalty
	_rank_score[slot] = score
	_rank_used = target


## Primary role until the requirement is met, then the catalog's support roles,
## then stop. This is what produces multi-unit responses without a separate
## "alarm level" concept: a bigger fire simply keeps asking for engines until
## the requirement is met.
func unmet_needs(inc: Incident) -> Array:
	var row := catalog.type_row(inc.type, inc.subtype)
	var needs: Array = []
	var primary := String(row.get("primary_role", ""))
	if primary != "":
		var have := _count_with_role(inc, primary)
		var want := _primary_count_for(inc)
		var deficit_units := 0
		var required: float = system.required_rate(inc)
		var committed: float = system.committed_effective_rate(inc)
		if required > committed:
			var per_unit := _representative_contribution(inc, primary)
			if per_unit > 0.0:
				deficit_units = int(ceil((required - committed) / per_unit))
		var wanted := maxi(want - have, deficit_units)
		for i in wanted:
			needs.append(primary)
	var tier := inc.tier()
	for support in row.get("support_roles", []):
		var support_row: Dictionary = support
		if tier < int(support_row.get("min_tier", 1)):
			continue
		var role := String(support_row.get("role", ""))
		if role == "" or role == primary:
			continue
		if float(support_row.get("rate_bonus", 0.0)) <= 0.0:
			continue
		if _count_with_role(inc, role) == 0:
			needs.append(role)
	return needs


## Emit a blocked event only when the reason CHANGES. The assignment loop runs
## every sub-step, so an unanswered incident would otherwise fill doc 08's
## history ring with thousands of identical rows.
## **ONE ANNOUNCEMENT PER INCIDENT PER REASON — doc 93 §AS3 (Wave 21). AN EVENT
## STORM IS ITS OWN DEFECT.**
##
## This is a NOTIFICATION: it tells the player *why* an incident is not being
## answered. Saying it again on the next integrator sub-step tells them nothing
## and drowns every other line on the bus.
##
## **The old de-dup was one slot, and one slot cannot hold two roles.** It kept a
## single `"<event>:<role>"` string and suppressed only an exact repeat — so an
## incident whose `fire` need is blocked for one reason and whose `police` need
## is blocked for another overwrites the slot on every need, every sub-step, and
## announces BOTH forever. Doc 92 §60.3 measured it on the player's slot 0:
## **279,071 `dispatch_blocked_unreachable` in 45 game-days** — 258 a game-hour,
## on a city with twelve buildings — and 466,321 over ninety. It is not a
## cosmetic problem: `CitySim` republishes every one of these on the shared bus,
## so every subscriber in the game paid for them.
##
## The slot is now a SET of the reasons this incident has already announced,
## under the same key, and it is cleared where it always was — the moment
## something is actually assigned, because *"a unit is finally coming"* makes the
## next block genuine news. A reason that CHANGES (no engine free → no route in)
## is still announced, because it is a different sentence about a different
## problem, and it is still announced exactly once.
##
## A save written before this ruling carries a String under this key. It is read
## defensively and replaced, rather than migrated: the value is a per-incident
## de-dup hint with no meaning beyond the current block, so the worst a stale one
## can cost is one extra notification on the load.
func _emit_blocked(inc: Incident, event_type: String, role: String) -> void:
	var said: Variant = inc.context.get("blocked_reason", null)
	if not (said is Dictionary):
		said = {}
		inc.context["blocked_reason"] = said
	var key := "%s:%s" % [event_type, role]
	if bool((said as Dictionary).get(key, false)):
		return
	(said as Dictionary)[key] = true
	_emit(event_type, {"incident_id": inc.id, "role": role})


## What one more capable unit would add, used only to size the ask.
func _representative_contribution(inc: Incident, role: String) -> float:
	var best := 0.0
	for unit_id in fleet.unit_ids_ref():
		var u: Vehicle = fleet.unit(unit_id)
		if not u.has_capability_for(role):
			continue
		best = maxf(best, float(system.unit_contribution(u, inc, role)))
	return best


func _primary_count_met(inc: Incident) -> bool:
	var row := catalog.type_row(inc.type, inc.subtype)
	var primary := String(row.get("primary_role", ""))
	if primary == "":
		return true
	return _count_with_role(inc, primary) >= _primary_count_for(inc)


func _primary_count_for(inc: Incident) -> int:
	var row := catalog.type_row(inc.type, inc.subtype)
	var counts: Array = row.get("primary_counts_by_tier", [1, 1, 1, 1, 1])
	if counts.is_empty():
		return 1
	return int(counts[clampi(inc.tier(), 1, counts.size()) - 1])


func _count_with_role(inc: Incident, role: String) -> int:
	var count := 0
	for unit_id in inc.assigned:
		if String((inc.assigned[unit_id] as Dictionary).get("role", "")) == role:
			count += 1
	return count


func _assign(u: Vehicle, inc: Incident, role: String, now_h: float, manual: bool) -> bool:
	var previous: Incident = system.incident(u.incident_id) if u.incident_id != 0 else null
	if u.construction_job_id != 0:
		var job_id := u.construction_job_id
		world.release_crew_from_job(job_id, str(u.id))
		u.construction_job_id = 0
		_emit("construction_job_preempted", {"job_id": job_id, "unit_id": u.id,
				"incident_id": inc.id})
	if not fleet.dispatch(u, inc.id, inc.tile, role, manual):
		return false
	if previous != null and previous.id != inc.id:
		previous.assigned.erase(u.id)
		if previous.assigned.is_empty() and previous.status == Incident.STATUS_ASSIGNED:
			previous.status = Incident.STATUS_QUEUED
	inc.assigned[u.id] = {"role": role, "state": Vehicle.RESPONDING,
			"eta_h": u.arrive_at_h, "manual": manual}
	if inc.first_assign_h < 0.0:
		inc.first_assign_h = now_h
	if inc.status == Incident.STATUS_QUEUED or inc.status == Incident.STATUS_NEW:
		inc.status = Incident.STATUS_ASSIGNED
	_emit("incident_assigned", {"incident_id": inc.id, "unit_id": u.id, "role": role,
			"eta_h": u.arrive_at_h, "manual": manual})
	return true


# --------------------------------------------------------- player commands

## Bypasses all scoring and all policy; sets manual_lock. The auto-dispatcher
## will never reassign or recall a manually-locked unit.
func cmd_dispatch_unit(unit_id: int, incident_id: int, now_h: float) -> Dictionary:
	var u: Vehicle = fleet.unit(unit_id)
	var inc: Incident = system.incident(incident_id)
	if u == null:
		return CommandQueue.fail(&"E_UNKNOWN_UNIT")
	if inc == null or inc.is_terminal():
		return CommandQueue.fail(&"E_UNKNOWN_INCIDENT")
	if not u.is_dispatchable_now():
		return CommandQueue.fail(&"E_UNIT_UNAVAILABLE")
	var row := catalog.type_row(inc.type, inc.subtype)
	var role := String(row.get("primary_role", ""))
	if not u.has_capability_for(role):
		var best_role := ""
		var best_rate := 0.0
		for key in u.resolve_rate:
			if float(u.resolve_rate[key]) > best_rate:
				best_rate = float(u.resolve_rate[key])
				best_role = String(key)
		role = best_role
	inc.manual_requested = true
	if not _assign(u, inc, role, now_h, true):
		return CommandQueue.fail(&"E_UNREACHABLE")
	return CommandQueue.ok({"unit_id": unit_id, "incident_id": incident_id, "role": role})


## §2.11's verb: turn a unit around. Only a unit that is actually OUT can be
## turned around — `FleetSystem.recall` already no-ops on `IDLE` and `OFFLINE`,
## and a command that answers `ok` for a no-op is a door that lies to the player
## who just tapped it (doc 91 A91-D-24 gave this verb its first caller). `REFIT`
## and `RETURNING` are refusals for the same reason: the unit is already on its
## way home or already home and out of service.
func cmd_recall_unit(unit_id: int) -> Dictionary:
	var u: Vehicle = fleet.unit(unit_id)
	if u == null:
		return CommandQueue.fail(&"E_UNKNOWN_UNIT")
	if u.status != Vehicle.RESPONDING and u.status != Vehicle.ON_SCENE:
		return CommandQueue.fail(&"E_UNIT_NOT_DEPLOYED", {"status": u.status})
	var inc: Incident = system.incident(u.incident_id)
	if inc != null:
		inc.assigned.erase(u.id)
		if inc.assigned.is_empty() and not inc.is_terminal():
			inc.status = Incident.STATUS_QUEUED
		elif inc.status == Incident.STATUS_ACTIVE and inc.on_scene_unit_ids().is_empty():
			inc.status = Incident.STATUS_ASSIGNED
	fleet.recall(u)
	return CommandQueue.ok({"unit_id": unit_id})


func cmd_pin_incident(incident_id: int, pinned: bool) -> Dictionary:
	var inc: Incident = system.incident(incident_id)
	if inc == null:
		return CommandQueue.fail(&"E_UNKNOWN_INCIDENT")
	inc.pinned = pinned
	return CommandQueue.ok({"incident_id": incident_id, "pinned": pinned})


func cmd_acknowledge_incident(incident_id: int) -> Dictionary:
	var inc: Incident = system.incident(incident_id)
	if inc == null:
		return CommandQueue.fail(&"E_UNKNOWN_INCIDENT")
	inc.seen = true
	return CommandQueue.ok({"incident_id": incident_id})


func cmd_set_policy(key: String, value: Variant) -> Dictionary:
	if not policy.set_value(key, value):
		return CommandQueue.fail(&"E_UNKNOWN_POLICY")
	_emit("policy_changed", {"key": key, "value": value})
	return CommandQueue.ok({"key": key, "value": value})


# ------------------------------------------------------------------- stats

func record_outcome(inc: Incident, outcome: String, target_response_min: float) -> void:
	match outcome:
		Incident.STATUS_RESOLVED:
			stats["resolved_total"] = int(stats["resolved_total"]) + 1
		Incident.STATUS_FAILED:
			stats["failed_total"] = int(stats["failed_total"]) + 1
		Incident.STATUS_ABANDONED:
			stats["abandoned_total"] = int(stats["abandoned_total"]) + 1
	var response := inc.response_minutes()
	if response < 0.0:
		return
	var samples := int(stats["response_samples"]) + 1
	stats["response_samples"] = samples
	stats["avg_response_min"] = float(stats["avg_response_min"]) \
			+ (response - float(stats["avg_response_min"])) / float(samples)
	var alpha := catalog.response_score_ewma_alpha
	var sample := clampf(1.5 - response / maxf(0.001, target_response_min), 0.0, 1.0)
	stats["rolling_response_score"] = (1.0 - alpha) * float(stats["rolling_response_score"]) \
			+ alpha * sample


func drain_events() -> Array:
	var out := _events
	_events = []
	return out


func _emit(event_type: String, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


# ------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	return {"section_version": 1, "policy": policy.serialize(), "stats": stats.duplicate()}


func deserialize(data: Dictionary) -> void:
	policy.deserialize(data.get("policy", {}))
	for key in data.get("stats", {}):
		if stats.has(key):
			stats[key] = data["stats"][key]

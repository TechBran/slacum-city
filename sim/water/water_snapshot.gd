class_name WaterSnapshot
extends RefCounted
## Doc 05 §5.8 — the read-only overlay/HUD payload (spec §26). Rebuilt at the
## tick cadence; every array is emitted in sorted id order so the renderer sees
## a stable ordering frame to frame.
##
## The overlay must use COLOUR + ICON, never colour alone (constitution §11 /
## spec §49), which is why every zone carries a `color_band` STRING rather than
## a colour. `fuel_hours_left` is deliberately absent from the node payload —
## doc 04's generator panel owns it (C-36).


static func build(system: WaterSystem) -> Dictionary:
	var data: WaterData = system.data
	var bands: Dictionary = data.effects.get("bands", {})
	var zones: Array = []
	var total_demand := 0.0
	var total_supply := 0.0
	var total_storage := 0.0
	var storage_capacity := 0.0
	var zones_in_deficit := 0
	for z: PressureZone in system.topology.zones:
		zones.append({
			"zone_key": z.zone_key, "pressure": z.pressure,
			"demand_m3h": z.demand_m3h, "supply_m3h": z.supply_m3h,
			"delivered_m3h": z.delivered_m3h,
			"tank_volume_m3": z.tank_volume_m3, "tank_capacity_m3": z.tank_capacity_m3,
			"buffer_hours": z.buffer_hours(), "contaminated": z.contaminated,
			"dead": z.dead, "color_band": z.color_band(bands),
			"break_penalty": z.break_penalty, "leak_m3h": z.leak_m3h,
			"fire_draw_m3h": z.fire_draw_m3h,
			"building_count": z.building_count,
		})
		total_demand += z.demand_m3h
		total_supply += z.supply_m3h
		total_storage += z.tank_volume_m3
		storage_capacity += z.tank_capacity_m3
		if z.supply_m3h < z.demand_m3h:
			zones_in_deficit += 1
	var node_rows: Array = []
	for node_id in _sorted(system.nodes):
		var n: WaterNode = system.nodes[node_id]
		if n.variant == &"junction":
			continue
		var record: Dictionary = data.component(n.variant, n.level, n.subtype)
		var rated := float(record.get("rated_flow_m3h",
				record.get("throughput_m3h", record.get("yield_m3h",
				record.get("boost_flow_m3h", record.get("capacity_m3", 0.0))))))
		var fraction := system.power_fraction_of(n)
		var coverage := data.coverage_frac_for(n.level)
		node_rows.append({
			"id": node_id, "variant": String(n.variant), "subtype": n.subtype,
			"level": n.level, "tile": [n.tile.x, n.tile.y], "state": String(n.state),
			"condition": n.condition,
			"load_kw": data.kw_required(n.variant, n.level, n.subtype),
			"power_fraction": fraction,
			"on_backup": n.backup_installed and fraction > 0.0 and fraction < 1.0,
			"coverage_frac": coverage, "flow_m3h": n.flow_m3h, "rated_m3h": rated,
			"level_frac": (n.volume_m3 / maxf(float(record.get("capacity_m3", 0.0)), 1e-6)) \
					if n.variant == &"tank" else 1.0,
			"restart_timer_min": n.restart_timer_min,
		})
	var edge_rows: Array = []
	var active_breaks := 0
	for edge_id in _sorted(system.edges):
		var e: WaterEdge = system.edges[edge_id]
		var capacity := e.capacity_m3h
		var path: Array = []
		for tile: Vector2i in e.path:
			path.append([tile.x, tile.y])
		if e.is_broken():
			active_breaks += 1
		edge_rows.append({
			"id": edge_id, "path": path, "tier": e.tier, "state": String(e.state),
			"condition": e.condition, "flow_m3h": e.flow_m3h,
			"utilization": e.flow_m3h / maxf(capacity, 1e-6), "severity": e.severity,
		})
	var job_rows: Array = []
	for job_id in _sorted(system.repairs.jobs):
		var job: Dictionary = system.repairs.jobs[job_id]
		var tile: Vector2i = job["tile"]
		job_rows.append({
			"job_id": job_id, "kind": String(job["kind"]), "tile": [tile.x, tile.y],
			"severity": float(job["severity"]),
			"work_remaining_min": float(job["work_remaining_min"]),
			"assigned_vehicle": String(job["assigned_vehicle"]),
		})
	return {
		"zones": zones,
		"nodes": node_rows,
		"edges": edge_rows,
		"jobs": job_rows,
		"tiles": system.topology.quantized_factors(),
		"city": {
			"total_demand_m3h": total_demand, "total_supply_m3h": total_supply,
			"total_storage_m3": total_storage, "storage_capacity_m3": storage_capacity,
			"storage_frac": total_storage / maxf(storage_capacity, 1e-6),
			"water_health_pct": system.water_health_pct(),
			"zones_in_deficit": zones_in_deficit, "active_breaks": active_breaks,
		},
	}


static func _sorted(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys

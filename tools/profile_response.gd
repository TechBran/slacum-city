extends SceneTree
## Doc 06 §1.1's TWO response bands, measured rather than derived.
##
## §1.1 publishes a single "response-time band" that is arithmetic from doc 10
## §2.6's worked examples. Report 98 C-70 already noticed that the arithmetic is
## a *travel* figure, and Wave 8 measured the split for the first time: with the
## router wired the DISPATCH ETA (turnout + drive) stays inside the published
## band while the RESPONSE (created → first unit on scene) does not, because
## response carries the queue in front of the incident as well as the drive.
##
## This instrument is what produces both distributions. It drives the same
## strategies, the same `Api` facade and the same coarse-online step
## `BalanceGateRig` uses, and records every `unit_dispatched.eta_h` and every
## `incident_resolved.response_min` rather than counting them.
##
## Usage:
##   ~/.local/bin/godot --headless -s res://tools/profile_response.gd -- \
##       [days=21] [strategies=a,b] [seeds=1337,4242,9001]
const Playtest := preload("res://tools/playtest.gd")
const Rig := preload("res://tests/balance_gate_rig.gd")

const DEFAULT_STRATEGIES := ["greedy_growth", "balanced", "tax_squeezer",
		"disaster_neglect"]


func _initialize() -> void:
	var days := 21
	var strategies: Array = DEFAULT_STRATEGIES.duplicate()
	var seeds: Array = [1337, 4242, 9001]
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		var split := arg.find("=")
		if split < 0:
			continue
		var key := arg.substr(0, split)
		var value := arg.substr(split + 1)
		match key:
			"days":
				days = int(value)
			"strategies":
				strategies = []
				for p in value.split(",", false):
					strategies.append(String(p))
			"seeds":
				seeds = []
				for p in value.split(",", false):
					seeds.append(int(p))

	print("| strategy | seed | ETA mean | ETA p90 | ETA max | resp mean | resp p90 | resp max"
			+ " | >T1 % | resolved | failed | abandoned | destroyed | wall s |")
	print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	var all_eta: Array[float] = []
	var all_resp: Array[float] = []
	for strategy in strategies:
		for seed_value in seeds:
			var t0 := Time.get_ticks_msec()
			var row := _run(String(strategy), int(seed_value), days)
			var wall := float(Time.get_ticks_msec() - t0) / 1000.0
			all_eta.append_array(row["eta"] as Array[float])
			all_resp.append_array(row["resp"] as Array[float])
			var eta: Array[float] = row["eta"]
			var resp: Array[float] = row["resp"]
			print("| %s | %d | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %d | %d | %d | %d | %.1f |"
					% [strategy, seed_value, _mean(eta), _pct(eta, 0.90), _pct(eta, 1.0),
					_mean(resp), _pct(resp, 0.90), _pct(resp, 1.0),
					100.0 * float(row["above_tier1"]) / maxf(1.0, float(row["resolved"])),
					int(row["resolved"]), int(row["failed"]), int(row["abandoned"]),
					int(row["destroyed"]), wall])
	print("| **ALL** | — | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | — | %d | — | — | — | — |"
			% [_mean(all_eta), _pct(all_eta, 0.90), _pct(all_eta, 1.0),
			_mean(all_resp), _pct(all_resp, 0.90), _pct(all_resp, 1.0), all_resp.size()])
	quit(0)


## One run, same shape as `BalanceGateRig.run` but keeping payloads.
static func _run(strategy_id: String, seed_value: int, days: int) -> Dictionary:
	var sim := CitySim.boot_from_files(seed_value)
	var strategy := Playtest.Factory.make(strategy_id)
	var api := Playtest.Api.new(sim)
	var eta: Array[float] = []
	var resp: Array[float] = []
	var resolved := 0
	var failed := 0
	var abandoned := 0
	var destroyed := 0
	var above_tier1 := 0
	sim.bus.drain()
	for h in days * Rig.HOURS_PER_DAY:
		api.hour = h
		strategy.act(api, h)
		sim.advance_coarse_hours(1, false)
		for event in sim.bus.drain():
			match String(event["type"]):
				"unit_dispatched":
					# Game-minutes, so it is the same unit §1.1's table is in.
					eta.append(float(event.get("eta_h", 0.0)) * 60.0)
				"incident_resolved":
					resolved += 1
					var minutes := float(event.get("response_min", -1.0))
					if minutes >= 0.0:
						resp.append(minutes)
					if int(event.get("tier_peak", 1)) > 1:
						above_tier1 += 1
				"incident_failed":
					failed += 1
				"incident_abandoned":
					abandoned += 1
				"building_destroyed":
					destroyed += 1
	return {"eta": eta, "resp": resp, "resolved": resolved, "failed": failed,
			"abandoned": abandoned, "destroyed": destroyed, "above_tier1": above_tier1}


static func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


## Nearest-rank percentile on a copy, so the caller's array keeps its order.
static func _pct(values: Array[float], q: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(int(ceil(q * float(sorted.size()))) - 1, 0, sorted.size() - 1)
	return sorted[index]

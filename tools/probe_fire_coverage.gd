extends SceneTree
## Wave-23 scratch probe (doc 92 §62.6): what `fire_coverage` does the doc-06
## ignition rate actually see, per district, on a founding city — and does it
## survive an hour of play? Answers the one question the §AV4 ablation raised:
## the `burn` arm came back bit-identical with the lever on and off, which is
## either a station that provides no coverage or a lever that is not wired.
##
## A MEASURING instrument (constitution §3): boots the real `CitySim`, owns no
## constant, imported by nothing.


func _initialize() -> void:
	var hours := 24
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hours="):
			hours = int(arg.substr(8))
	var sim := CitySim.boot_from_files(1337)
	print("stations:")
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.archetype != &"fire_station" and b.archetype != &"police_station":
			continue
		print("  %s %s state=%s condition=%.3f level=%d district=%s" % [
			id, String(b.archetype), String(b.state), b.condition, b.level,
			sim.incident_world.district_of_tile(b.origin)])
	for h in [0, hours]:
		if h > 0:
			sim.scheduler.advance_coarse_n(h)
		print("after %d game-hours:" % h)
		for district_id in sim.districts.district_ids_sorted():
			var row := sim.incident_world.district(String(district_id))
			if row.is_empty():
				continue
			print("  district %-10s pop %6d  fire_coverage %.4f  police_coverage %.4f"
					% [String(district_id), int(row.get("population", 0)),
					float(row.get("fire_coverage", -1.0)),
					float(row.get("police_coverage", -1.0))])
	sim.dispose()
	quit(0)

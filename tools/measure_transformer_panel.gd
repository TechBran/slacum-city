extends SceneTree
## Wave 25's measuring instrument (report 98 §68, doc 92 §65).
##
## Four questions, on real cities, with no fixture anywhere:
##
##   1. **What does a transformer repair COST and how long does it take?** Every
##      transformer in the city, quoted through `cmd_repair_grid_component
##      (preview = true)` at its live condition and again with the unit forced
##      FAILED — the same call the panel's button makes, so the table and the
##      button can never disagree.
##   2. **How many buildings does a transformer serve?** The distribution of
##      `PowerGrid.buildings_served_by`, which is the list S18 has to draw and the
##      reason the panel needs a scroller.
##   3. **How long is the building panel?** Row count and laid-out height for a
##      house, a shop and a civic building — measured on the REAL panel in a real
##      layout pass, at three device widths. Run it on both sides of the diet.
##   4. **Is the pick reachable?** For every transformer, whether a tap on its
##      pad centre resolves to `PICK_COMPONENT` at a representative zoom.
##
## Like `tools/audit_power.gd` and `tools/playtest.gd` this is an INSTRUMENT: it
## owns no constant, boots the real `CitySim`, and is never imported by `sim/`.
##
## Usage:
##   ~/.local/bin/godot --headless --path <project> -s res://tools/measure_transformer_panel.gd \
##       -- [--hours=6] [--seed=1337] [--city=res://tests/fixtures/bench_city.json]
##       [--panel]        also mount the UI and measure the building panel (needs no display)

const DEFAULT_SEED := 1337
const DEFAULT_HOURS := 6.0


func _initialize() -> void:
	var seed_value := DEFAULT_SEED
	var hours := DEFAULT_HOURS
	var city := ""
	var want_panel := false
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--seed="):
			seed_value = text.trim_prefix("--seed=").to_int()
		elif text.begins_with("--hours="):
			hours = text.trim_prefix("--hours=").to_float()
		elif text.begins_with("--city="):
			city = text.trim_prefix("--city=")
		elif text == "--panel":
			want_panel = true
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city if city != "" else "res://data/starter_city.json"),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	sim.advance_hours(hours)
	print("measure_transformer_panel: seed %d, %.1f game-hours, city %s"
			% [seed_value, hours, city if city != "" else "data/starter_city.json"])
	_repairs(sim)
	_customers(sim)
	_picks(sim)
	if want_panel:
		_panel_rows(sim)
	quit()


# --------------------------------------------------------------- 1. the price

func _repairs(sim: CitySim) -> void:
	print("\n-- doc 92 §65.2: what a transformer repair costs --")
	print("id       L  cond    live: reason/cost    forced-FAILED: damage  cost  crew-h")
	var total_failed := 0
	var count := 0
	for id_value in sim.grid.component_ids_of_kind(&"transformer"):
		var id := String(id_value)
		var c := sim.grid.component(id)
		var level := int(c["level"])
		var condition := float(c["condition"])
		var live := sim.cmd_repair_grid_component(id, true)
		var live_text := "$%d" % int((live["payload"] as Dictionary).get("cost", 0)) \
				if bool(live["ok"]) else String(live["reason_code"])
		# Force the failure, quote, put it straight back — a READ, so the state is
		# restored before the next component is asked.
		var was_state: Variant = c["state"]
		c["state"] = &"FAILED"
		var failed := sim.cmd_repair_grid_component(id, true)
		var payload: Dictionary = failed.get("payload", {})
		c["state"] = was_state
		print("%-8s %d  %.4f  %-18s %.4f  $%-5d %.4f" % [id, level, condition,
				live_text, float(payload.get("damage_fraction", 0.0)),
				int(payload.get("cost", 0)), float(payload.get("crew_hours", 0.0))])
		total_failed += int(payload.get("cost", 0))
		count += 1
	if count > 0:
		print("forced-FAILED repair bill for the whole roster: $%d over %d transformers (mean $%d)"
				% [total_failed, count, int(round(float(total_failed) / float(count)))])


# ----------------------------------------------------------- 2. the customers

func _customers(sim: CitySim) -> void:
	print("\n-- doc 92 §65.1: who is behind each transformer --")
	var ids := sim.grid.component_ids_of_kind(&"transformer")
	var served := 0
	var worst := 0
	var worst_id := ""
	var empty := 0
	for id_value in ids:
		var n := sim.grid.buildings_served_by(String(id_value)).size()
		served += n
		if n == 0:
			empty += 1
		if n > worst:
			worst = n
			worst_id = String(id_value)
	print("transformers %d, attached buildings %d, mean %.2f, widest %s at %d, feeding nobody %d"
			% [ids.size(), served, float(served) / maxf(1.0, float(ids.size())),
			worst_id, worst, empty])
	print("unserved buildings: %d" % sim.grid.unserved_building_ids().size())


# ---------------------------------------------------------------- 3. the pick

func _picks(sim: CitySim) -> void:
	print("\n-- doc 92 §65.3: can a tap reach the pad? --")
	var controller := BuildController.new(sim)
	# 48 dp of finger at a representative mid zoom: `CameraState.m_per_dp` on the
	# starter city's default height. Asked of the shipped file, not assumed.
	var camera := CameraState.load_from_files()
	var m_per_dp := camera.m_per_dp(Vector2(412.0, 915.0))
	var radius := controller.set_tap_radius_from(m_per_dp)
	print("tap radius at the default camera height: %.3f m (48 dp at %.5f m/dp)"
			% [radius, m_per_dp])
	var hit := 0
	var missed: Array[String] = []
	var over_building := 0
	for id_value in sim.grid.component_ids_of_kind(&"transformer"):
		var id := String(id_value)
		var tile := sim.grid.component_tile(id)
		var point := Vector3((float(tile.x) + 0.5) * controller.tile_m, 0.0,
				(float(tile.y) + 0.5) * controller.tile_m)
		var pick := controller.pick_at_ground(point)
		if StringName(String(pick["kind"])) == BuildController.PICK_COMPONENT \
				and String(pick["id"]) == id:
			hit += 1
		else:
			missed.append("%s->%s" % [id, String(pick["kind"])])
		# What the FORK answered for the same tap, reconstructed from the two
		# queries `pick_at_ground` used to make and nothing else.
		if controller.sim_id_at_tile(tile) != "":
			over_building += 1
	print("pads reached by a tap on their own centre: %d of %d (the fork gave %d of those taps to a BUILDING)"
			% [hit, sim.grid.component_ids_of_kind(&"transformer").size(), over_building])
	if not missed.is_empty():
		print("missed: %s" % ", ".join(missed))
	# The honest reading of "the pad is in front of the house": how much of a
	# finger's worth of ground around each pad the fork handed to something else.
	var samples := 0
	var to_component := 0
	var fork := {"building": 0, "block": 0, "none": 0}
	for id_value in sim.grid.component_ids_of_kind(&"transformer"):
		var id := String(id_value)
		var tile := sim.grid.component_tile(id)
		var centre := Vector3((float(tile.x) + 0.5) * controller.tile_m, 0.0,
				(float(tile.y) + 0.5) * controller.tile_m)
		for ring in [0.33, 0.66, 1.0]:
			for step in 12:
				var a := TAU * float(step) / 12.0
				var probe := centre + Vector3(cos(a), 0.0, sin(a)) * (radius * float(ring))
				samples += 1
				var answer := controller.pick_at_ground(probe)
				if StringName(String(answer["kind"])) == BuildController.PICK_COMPONENT:
					to_component += 1
				var was := _fork_answer(controller, sim, probe)
				fork[was] = int(fork[was]) + 1
	print("a finger's worth of ground around every pad: %d sample points, %d (%.1f %%) now select the transformer"
			% [samples, to_component, 100.0 * float(to_component) / maxf(1.0, float(samples))])
	print("what the FORK answered for those same %d taps: building %d, block (S4, the LAND PURCHASE panel) %d, nothing at all %d"
			% [samples, int(fork["building"]), int(fork["block"]), int(fork["none"])])


## What `pick_at_ground` answered before `PICK_COMPONENT` existed, reconstructed
## from the two queries it made and nothing else — so the "before" column is the
## fork's own logic rather than a memory of it.
func _fork_answer(controller: BuildController, sim: CitySim, point: Vector3) -> String:
	var tile := BuildController.tile_at(point, controller.tile_m)
	if controller.sim_id_at_tile(tile) != "":
		return "building"
	var block_id := controller.block_id_at_tile(tile)
	if block_id != "" and LandPanelModel.stage_opens_panel(sim.world.block(block_id)):
		return "block"
	return "none"


# --------------------------------------------------------------- 4. the panel

func _panel_rows(sim: CitySim) -> void:
	print("\n-- doc 92 §65.4: how long is the building panel? --")
	var cfg := UIConfig.load_from_files()
	var controller := BuildController.new(sim)
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	root.config = cfg
	get_root().add_child(root)
	root.initialize()
	var panel: BuildingPanel = root.safe_area.get_node_or_null(
			"PanelLayer/BuildingPanel") as BuildingPanel
	if panel == null:
		print("no building panel in the scene")
		return
	panel.setup(cfg, controller)
	sim.treasury.balance = 500_000
	for width in [360, 412, 794]:
		root.force_layout(Vector2i(width, 915))
		for sim_id in _samples(sim):
			panel.show_building(String(sim_id))
			root.force_layout(Vector2i(width, 915))
			var body := panel.get_node_or_null(panel.body_path()) as Control
			var rows := _leaf_rows(body)
			print("%4d dp  %-12s rows %3d  content %.0f dp  (%.1f screenfuls of 915)"
					% [width, String(sim_id), rows, _content_h(body),
					_content_h(body) / 915.0])
	panel.close()


## One residential, one commercial and one civic building — asked of the roster
## rather than named, so the instrument survives a starter-city edit.
func _samples(sim: CitySim) -> Array:
	var want := ["residential", "commercial", "service"]
	var out: Array = []
	var keys := sim.buildings.keys()
	keys.sort()
	for category in want:
		for key: Variant in keys:
			var b: Building = sim.buildings[str(key)]
			if sim.catalog.category(String(b.archetype)) == category and not out.has(str(key)):
				out.append(str(key))
				break
	return out


## How tall the panel's content is, in dp: every visible leaf row's own minimum
## height plus the separation its parent puts under it. Measured rather than read
## off the body, because the body lives inside a `ScrollContainer` and therefore
## reports the VIEWPORT's height however long its contents are — which is exactly
## the number that hides the problem.
func _content_h(node: Node) -> float:
	if node == null:
		return 0.0
	var total := 0.0
	for child in node.get_children():
		var control := child as Control
		if control != null and not control.visible:
			continue
		if control is Label or control is Button or control is MeterBar:
			total += maxf(control.get_combined_minimum_size().y, 0.0)
		total += _content_h(child)
	return total


## Every leaf Control under `node` that a player reads as a ROW: a visible
## Label, Button or MeterBar. Containers are not rows; they hold them.
func _leaf_rows(node: Node) -> int:
	if node == null:
		return 0
	var count := 0
	for child in node.get_children():
		var control := child as Control
		if control != null and not control.visible:
			continue
		if control is Label or control is Button or control is MeterBar:
			count += 1
		count += _leaf_rows(child)
	return count

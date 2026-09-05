class_name LandPanelModel
extends RefCounted
## The headless half of S4, doc 12 §2.8 — the land purchase flow.
##
## Same contract `BuildController` has with the building panel: this class reads
## the sim and computes every value, and `ui/land_panel.gd` binds what it
## returns. It owns no threshold, no price and no copy (constitution §3,
## doc 12 §1); the price is `EconomySystem.land_price`'s, the phase costs are
## `development_phase_cost`'s, the schedule is `DevelopmentController`'s, and
## every sentence resolves from `data/strings.en.json`.
##
## ## Why the panel prices the block twice
##
## §2.8's item 2 asks the panel to show **advantages** — `Waterfront +18 % land
## value`, `Existing road stub`. Those percentages are the *terms* of doc 03
## §2.7's price product, and the honest way to name them is to ask the price
## function what the block would cost without each one:
##
##     waterfront advantage = land_price_raw(inputs) / land_price_raw(inputs
##                            with waterfront_edges = 0) − 1
##
## No coefficient is copied into `ui/`, no formula is restated, and a retune of
## `data/economy.json` moves the panel's percentages the same hour it moves the
## price. The neutral value for each term is the term's own identity element (0
## edges, 0 connections, 0 prestige, flat terrain, no risk), which is exactly
## what `land_price_raw` multiplies by 1.
##
## ## The two-step purchase (§2.8 items 3 and 4)
##
## `CitySim.cmd_buy_block` defaults to `auto_develop = true`, which is right for
## a script and wrong for this panel: the doc's flow is PURCHASE → the block
## flips to owned-undeveloped → the primary button becomes DEVELOP. `buy()`
## therefore passes `auto_develop = false` explicitly. The default is untouched,
## because the tests and the soak rely on it.

const PHASES := DevelopmentController.PHASES

## Which surface the block is at, in the order a block moves through them.
const STAGE_UNOWNED := &"unowned"       ## LOCKED or PURCHASABLE — the BUY face
const STAGE_OWNED := &"owned"           ## bought, pipeline not started — the DEVELOP face
const STAGE_DEVELOPING := &"developing" ## the six-step progress list
const STAGE_READY := &"ready"           ## buildable; the panel is a read-out

## The panel's one primary button, or none.
const ACTION_BUY := &"buy"
const ACTION_DEVELOP := &"develop"
const ACTION_NONE := &"none"

const PHASE_STATE_DONE := &"done"
const PHASE_STATE_ACTIVE := &"active"
const PHASE_STATE_PENDING := &"pending"

## The `data/ui.json` block this screen reads. Presentation only — no price, no
## crew-hour and no threshold of the sim's lives there.
const SECTION := "land"

## Every failure code the two land commands can raise, so the panel's params
## table is complete by construction rather than by memory.
const BUY_CODES: Array[StringName] = [
	&"E_UNKNOWN_BLOCK", &"E_ALREADY_OWNED", &"E_CITY_LEVEL", &"E_NOT_ADJACENT",
	&"E_FUNDS",
]
const DEVELOP_CODES: Array[StringName] = [
	&"E_UNKNOWN_BLOCK", &"E_NOT_OWNED", &"E_ALREADY_DEVELOPING", &"E_FUNDS",
]

## Each advantage row names the `land_price_inputs` key it neutralises. The
## order is the order the rows are *considered* in; they are then sorted by how
## much money they are worth, because that is what the player is reading for.
const ADVANTAGE_TERMS := {
	&"waterfront": {"key": "waterfront_edges", "neutral": 0},
	&"road_access": {"key": "arterial_connections", "neutral": 0},
	&"prestige": {"key": "prestige", "neutral": 0.0},
	&"elevation": {"key": "elevation_norm", "neutral": 0.0},
	&"terrain": {"key": "dev_terrain", "neutral": "flat"},
	&"risk": {"key": "risk_index", "neutral": 0.0},
}
const ADVANTAGE_ORDER: Array[StringName] = [
	&"waterfront", &"road_access", &"prestige", &"elevation", &"terrain", &"risk",
]

const _DEFAULT_RISK_ROWS: Array = ["flood", "wildfire", "subsidence", "pollution",
		"wind", "hazmat"]
const _DEFAULT_BAND_WORDS: Array = ["low", "moderate", "elevated", "high", "severe"]
const _DEFAULT_BAND_STATES: Array = ["normal", "normal", "warning", "warning", "critical"]
const _MINUTES_PER_HOUR := 60.0

var sim: CitySim
var formatter: RequirementFormatter
var config: UIConfig
var tile_m := BuildController.TILE_M_DEFAULT


func _init(p_sim: CitySim = null, p_formatter: RequirementFormatter = null,
		p_config: UIConfig = null, p_tile_m: float = -1.0) -> void:
	sim = p_sim
	formatter = p_formatter if p_formatter != null else RequirementFormatter.load_from_files()
	config = p_config if p_config != null else formatter.config
	if config == null:
		config = UIConfig.load_from_files()
	tile_m = p_tile_m if p_tile_m > 0.0 else BuildController.load_tile_m()


func section() -> Dictionary:
	return config.section(SECTION) if config != null else {}


# ===========================================================================
# Which blocks S4 answers for
# ===========================================================================

## §2.8's entry rule: the panel exists for land the player can still *do*
## something to — buy it, develop it, or watch it develop. A block that is owned
## and READY is finished ground, so a tap that lands there is a tap on the map,
## not on a block, and the shell deselects exactly as it does today.
func opens_for(block_id: String) -> bool:
	if sim == null:
		return false
	return LandPanelModel.stage_opens_panel(sim.world.block(block_id))


## The same rule, as a pure predicate on the block itself, so
## `BuildController.pick_at_ground` can route a tap without holding a model.
## One authority, two callers.
static func stage_opens_panel(block: LandBlock) -> bool:
	if block == null:
		return false
	return not (block.is_owned() and block.is_ready())


func stage_of(block: LandBlock) -> StringName:
	if not block.is_owned():
		return STAGE_UNOWNED
	if block.is_ready():
		return STAGE_READY
	if block.development_state == &"UNDEVELOPED":
		return STAGE_OWNED
	return STAGE_DEVELOPING


# ===========================================================================
# The view (doc 12 §2.8 items 2 and 4)
# ===========================================================================

## Everything the panel draws, as plain data. `exists = false` is the answer for
## an id the world does not carry, and the panel closes on it rather than
## rendering an empty card.
func block_view(block_id: String) -> Dictionary:
	if sim == null:
		return {"exists": false, "block_id": block_id}
	var block := sim.world.block(block_id)
	if block == null:
		return {"exists": false, "block_id": block_id}
	var stage := stage_of(block)
	var inputs := sim.land_price_inputs(block_id)
	var price := sim.economy.land_price(inputs)
	var m_dev := float(sim.treasury.difficulty().get("M_dev", 1.0))
	var d := float(sim.world.d_from_center(block_id))
	var development_total := sim.economy.development_total_cost(String(block.dev_terrain),
			d, block.arterial_connections, m_dev)
	var first_block := sim.development.is_first_block()
	var schedule_hours := sim.development.total_crew_hours(&"construction_crew", first_block)
	var phases := _phases(block, d, m_dev)
	var progress := _progress(block, phases)
	var action := _action(block, stage, price)
	var works := works_view(block, d, m_dev)
	return {
		"exists": true,
		"block_id": block_id,
		"label": block.label,
		"stage": stage,
		"ownership_state": String(block.ownership_state),
		"development_state": String(block.development_state),
		"district": _district_of(block),
		"header": _header(block),
		"facts": _facts(block, stage, price, development_total, schedule_hours),
		"risks": risks(block),
		"advantages": advantages(block_id, inputs, price),
		"phases": phases,
		"progress": progress,
		"works": works,
		"action": action,
		"blockers": action["blockers"],
		"price": price,
		"price_text": HudModel.money_exact(price),
		"development_total": development_total,
		"schedule_hours": schedule_hours,
		"note_key": _note_key(stage),
	}


# ===========================================================================
# §2.8b — what the crews find (doc 12 §2.8 D-117)
# ===========================================================================

## The excavation band, this block's running total and the city's materials
## yard, as the rows the panel draws under the advantages.
##
## **The band is shown BEFORE the purchase and that is the point.** Doc 03 §2.8's
## `Est. development` line has always told the player what a block will COST;
## this is the other half of the same sentence, and it is derived from the same
## table by the same function (`EconomySystem.works_yield_band`), so a retune of
## `data/economy.json` moves the quote the same hour it moves the money. Nothing
## here restates a fraction, a ceiling or a share.
##
## `Recovered so far` appears only once the block is the player's: a number that
## reads `$0` on land nobody owns is a question the panel is not answering.
## `Materials yard` is the CITY's stock, so it appears whenever there is any —
## the block being read is not necessarily the block that filled it.
func works_view(block: LandBlock, d: float, m_dev: float) -> Dictionary:
	var band := sim.economy.works_yield_band(String(block.dev_terrain), d,
			block.arterial_connections, m_dev)
	var rows: Array[Dictionary] = []
	var typical := _t("ui_land_works_typical_range", {
		"low": HudModel.money_exact(int(band["low"])),
		"high": HudModel.money_exact(int(band["high"])),
	})
	# A band of `$0 – $0` is what a data file with no `works_yield` block
	# produces, and a row that says nothing is worse than no row: the whole band
	# is dropped there and the panel is exactly what it was before Wave 25.
	if int(band["high"]) > 0:
		rows.append({"id": "typical", "label_key": "ui_land_works_typical",
				"value": typical, "state": HudModel.STATE_NORMAL})
	if block.is_owned():
		rows.append({"id": "recovered", "label_key": "ui_land_works_recovered",
				"value": HudModel.money_exact(block.works_yield_total)
						if block.works_yield_total > 0
						else _t("ui_land_works_none", {}),
				"state": HudModel.STATE_NORMAL})
	if sim.works_stockpile > 0:
		rows.append({"id": "yard", "label_key": "ui_land_works_yard",
				"value": HudModel.money_exact(sim.works_stockpile),
				"state": HudModel.STATE_NORMAL})
	return {
		"typical_low": int(band["low"]),
		"typical_high": int(band["high"]),
		"typical_text": typical,
		"ceiling": int(band["ceiling"]),
		"recovered": block.works_yield_total,
		"yard": sim.works_stockpile,
		"rows": rows,
	}


## `Block B4 · 16×16 tiles · 128 m` — §2.8's header line, with the metres derived
## from `data/world.json`'s tile size rather than restated here.
func _header(block: LandBlock) -> String:
	var edge := TileGrid.TILES_PER_BLOCK
	return _t("ui_land_header", {
		"label": block.label,
		"tiles": edge,
		"metres": int(round(float(edge) * tile_m)),
	})


func _district_of(block: LandBlock) -> String:
	if block.district_id == "":
		return ""
	var record := sim.districts.district(block.district_id)
	return str(record.get("name", block.district_id))


## The numbers §2.8 puts under the header: what it costs, what developing it
## costs, how long that takes, and how much ground the player actually gets.
func _facts(block: LandBlock, stage: StringName, price: int, development_total: int,
		schedule_hours: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if stage == STAGE_UNOWNED:
		out.append(_fact("price", "ui_land_fact_price", HudModel.money_exact(price)))
	out.append(_fact("development", "ui_land_fact_development",
			HudModel.money_exact(development_total)))
	out.append(_fact("time", "ui_land_fact_time", duration_text(schedule_hours * _MINUTES_PER_HOUR)))
	out.append(_fact("buildable", "ui_land_fact_buildable",
			_t("ui_land_tiles_of", {"have": block.buildable_tiles_est(),
					"total": TileGrid.TILES_PER_BLOCK * TileGrid.TILES_PER_BLOCK})))
	if block.water_tiles > 0 or block.blocked_tiles > 0:
		out.append(_fact("unusable", "ui_land_fact_unusable",
				_t("ui_land_tiles", {"n": block.water_tiles + block.blocked_tiles})))
	return out


static func _fact(id: String, label_key: String, value: String) -> Dictionary:
	return {"id": id, "label_key": label_key, "value": value}


## §2.8's risk profile: icon + 5-segment bar + word, one row per risk the block
## carries. The bar and the word both carry the reading, so the row survives
## grayscale (A5) — colour is the third channel, never the only one.
func risks(block: LandBlock) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var rows: Array = _array("risk_rows", _DEFAULT_RISK_ROWS)
	var words: Array = _array("risk_band_words", _DEFAULT_BAND_WORDS)
	var states: Array = _array("risk_band_states", _DEFAULT_BAND_STATES)
	var segments := maxi(1, UIConfig.get_int(section(), "risk_bar_segments", words.size()))
	for entry: Variant in rows:
		var id := str(entry)
		if not block.env_risk.has(id):
			continue
		var value := clampf(float(block.env_risk[id]), 0.0, 1.0)
		var band := clampi(int(floor(value * float(words.size()))), 0, words.size() - 1)
		out.append({
			"id": id,
			"label_key": "ui_land_risk_%s" % id,
			"value": value,
			# The bar is drawn from the **band**, not from the raw value, so the
			# two halves of the row can never disagree: `Moderate` is always two
			# segments and `Severe` is always five. A bar rounded independently of
			# the word is how `▮▮▯▯▯ Low` happens, and a player reading the bar
			# then gets a different answer from a player reading the word (A5).
			"bar": bar(float(band + 1) / float(words.size()), segments),
			"band": band,
			"word_key": "ui_land_risk_band_%s" % str(words[band]),
			"word": _t("ui_land_risk_band_%s" % str(words[band]), {}),
			"state": StringName(str(states[mini(band, states.size() - 1)])),
		})
	return out


## `▮▮▮▯▯` — the doc's own glyphs, read from `data/ui.json` so a font swap is a
## data edit. Filled count is `ceil(value × segments)` with a floor of one filled
## segment above zero: a risk that exists must never render as an empty bar.
func bar(value01: float, segments: int) -> String:
	var filled_glyph := str(section().get("bar_filled", "▮"))
	var empty_glyph := str(section().get("bar_empty", "▯"))
	var value := clampf(value01, 0.0, 1.0)
	var filled := 0 if value <= 0.0 else clampi(int(ceil(value * float(segments))), 1, segments)
	return filled_glyph.repeat(filled) + empty_glyph.repeat(segments - filled)


## §2.8's `advantages`, derived rather than authored — see the class note. A term
## worth less than `advantage_min_pct` either way is dropped: a 0 % row is noise,
## and rounding one to `+0 %` is a lie about a number that is not zero.
func advantages(block_id: String, inputs: Dictionary, price: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if price <= 0:
		return out
	var floor_pct := UIConfig.get_num(section(), "advantage_min_pct", 1.0)
	var actual := sim.economy.land_price_raw(inputs)
	for id: StringName in ADVANTAGE_ORDER:
		var term: Dictionary = ADVANTAGE_TERMS[id]
		var neutral_inputs := inputs.duplicate()
		neutral_inputs[str(term["key"])] = term["neutral"]
		var neutral := sim.economy.land_price_raw(neutral_inputs)
		if neutral <= 0.0:
			continue
		var pct := (actual / neutral - 1.0) * 100.0
		if absf(pct) < floor_pct:
			continue
		out.append({
			"id": String(id),
			"label_key": "ui_land_advantage_%s" % String(id),
			"pct": pct,
			"value": HudModel.percent_text(pct, true),
			"state": HudModel.STATE_NORMAL if pct > 0.0 else HudModel.STATE_WARNING,
		})
	out.sort_custom(LandPanelModel._advantage_less)
	return out


## Biggest effect first; ties broken by id so the list is deterministic.
static func _advantage_less(a: Dictionary, b: Dictionary) -> bool:
	var ma := absf(float(a["pct"]))
	var mb := absf(float(b["pct"]))
	if not is_equal_approx(ma, mb):
		return ma > mb
	return str(a["id"]) < str(b["id"])


# ===========================================================================
# The six-step pipeline (doc 09 §2.3, §2.8 item 4)
# ===========================================================================

## One row per phase, always six, whatever the block is doing — the player sees
## the whole pipeline from the first tap, not just the step it happens to be on.
func _phases(block: LandBlock, d: float, m_dev: float) -> Array[Dictionary]:
	var live := sim.development.active_view(block.id)
	var current := int(live.get("phase_index", -1))
	var job_id := int(live.get("job_id", 0))
	var ready := block.is_ready()
	var out: Array[Dictionary] = []
	for index in PHASES.size():
		var phase: StringName = PHASES[index]
		var state := PHASE_STATE_PENDING
		var progress01 := 0.0
		if ready or (current >= 0 and index < current):
			state = PHASE_STATE_DONE
			progress01 = 1.0
		elif current >= 0 and index == current:
			state = PHASE_STATE_ACTIVE
			progress01 = sim.construction.progress(job_id) if job_id > 0 else 0.0
		var cost := sim.economy.development_phase_cost(index, String(block.dev_terrain),
				d, block.arterial_connections, m_dev)
		# Ruling 93 §AZ3's yard, quoted on the two phases it may pay towards —
		# and only while they are still PENDING. A done phase already took
		# whatever the yard held at the moment it was charged, and re-quoting
		# today's yard against yesterday's invoice would print a discount the
		# player never got; an ACTIVE phase has been charged too. So the offset
		# is what the yard would take off this phase **if it were charged now**,
		# which is the only honest thing a quote can be.
		var offset := 0
		if state == PHASE_STATE_PENDING:
			offset = sim.economy.works_stockpile_offset(index, cost, sim.works_stockpile)
		out.append({
			"id": String(phase),
			"index": index,
			"label_key": "ui_land_phase_%s" % String(phase).to_lower(),
			"state": state,
			"glyph": _phase_glyph(state),
			"progress": progress01,
			"bar": bar(progress01, maxi(1, UIConfig.get_int(section(),
					"phase_bar_segments", 5))),
			"cost": cost,
			"cost_text": HudModel.money_exact(cost),
			"stockpile_offset": offset,
			"stockpile_offset_text": "" if offset <= 0 \
					else _t("ui_land_works_yard_offset",
							{"amount": HudModel.money_exact(offset)}),
			"crew_hours": sim.development.phase_crew_hours(phase, &"construction_crew",
					bool(live.get("first_block", sim.development.is_first_block()))),
		})
	return out


func _phase_glyph(state: StringName) -> String:
	match state:
		PHASE_STATE_DONE:
			return str(section().get("phase_glyph_done", "✓"))
		PHASE_STATE_ACTIVE:
			return str(section().get("phase_glyph_active", "▶"))
	return str(section().get("phase_glyph_pending", "·"))


## The live half: which phase is running, how far in, who is on it, and when it
## is expected to finish.
##
## The ETA quotes the **unmodified** construction rate and the crew that is on
## the job right now. Weather and doc 07's events move doc 01's
## `construction_rate` channel, and a crew can be pulled to an incident, so the
## copy says "about" and means it. Guessing a channel value the sim has not
## published yet would be a more precise lie.
func _progress(block: LandBlock, phases: Array[Dictionary]) -> Dictionary:
	var live := sim.development.active_view(block.id)
	if live.is_empty():
		return {"active": false, "phase_index": -1, "eta_minutes": -1.0,
				"eta_text": HudModel.NO_DATA, "crew": "", "paused": false,
				"progress": 1.0 if block.is_ready() else 0.0, "eta_total_text": HudModel.NO_DATA}
	var index := int(live["phase_index"])
	var job_id := int(live.get("job_id", 0))
	var eta := sim.construction.eta_game_minutes(job_id) if job_id > 0 else -1.0
	var remaining := 0.0
	for i in range(index + 1, phases.size()):
		remaining += float((phases[i] as Dictionary)["crew_hours"]) * _MINUTES_PER_HOUR
	var total := -1.0 if eta < 0.0 else eta + remaining
	return {
		"active": true,
		"phase_index": index,
		"phase_id": String(PHASES[index]),
		"phase_label_key": "ui_land_phase_%s" % String(PHASES[index]).to_lower(),
		"progress": float((phases[index] as Dictionary)["progress"]),
		"paused": bool(live.get("paused", false)),
		"crew": _crew_of(job_id),
		"eta_minutes": eta,
		"eta_text": duration_text(eta) if eta >= 0.0 else HudModel.NO_DATA,
		"eta_total_minutes": total,
		"eta_total_text": duration_text(total) if total >= 0.0 else HudModel.NO_DATA,
	}


func _crew_of(job_id: int) -> String:
	if job_id <= 0:
		return ""
	var job := sim.construction.job(job_id)
	if job.is_empty():
		return ""
	var crews: Array = (job["assigned_crews"] as Dictionary).keys()
	crews.sort()
	return ", ".join(PackedStringArray(crews))


# ===========================================================================
# The primary button (§2.8 items 3 and 4)
# ===========================================================================

func _action(block: LandBlock, stage: StringName, price: int) -> Dictionary:
	match stage:
		STAGE_UNOWNED:
			var preview := sim.cmd_buy_block(block.id, true, false)
			return _action_row(ACTION_BUY, "ui_land_action_buy", preview, block, price)
		STAGE_OWNED:
			var start := sim.cmd_start_development(block.id, true)
			return _action_row(ACTION_DEVELOP, "ui_land_action_develop", start, block,
					int((start.get("payload", {}) as Dictionary).get("phase_cost", 0)))
	return {"id": ACTION_NONE, "label_key": "", "enabled": false, "cost": 0,
			"cost_text": "", "blockers": [] as Array[Dictionary],
			"blocked_by": {} as Dictionary}


func _action_row(id: StringName, label_key: String, preview: Dictionary,
		block: LandBlock, cost: int) -> Dictionary:
	var payload: Dictionary = preview.get("payload", {})
	var codes: Array = payload.get("blockers", [])
	if not bool(preview["ok"]) and codes.is_empty():
		codes = [preview["reason_code"]]
	var rows := formatter.format_all(codes, {"cost": cost, "balance": sim.treasury.balance},
			blocker_params(block, cost))
	# Every row here is a refusal, so each carries the checklist's `ok`/`text`
	# pair — `first_blocker()` reads `ok`, and the view renders `text`, exactly as
	# the building panel's checklist rows do.
	for row: Dictionary in rows:
		row["ok"] = false
		row["text"] = str(row["body"])
	return {
		"id": id,
		"label_key": label_key,
		"enabled": bool(preview["ok"]),
		"cost": cost,
		"cost_text": HudModel.money_exact(cost),
		"blockers": rows,
		"blocked_by": RequirementFormatter.first_blocker(rows),
	}


## Per-code parameters for the land family. The sim returns codes and totals; the
## sentences quote numbers, so this is where a code becomes a number again — the
## same split `BuildController._check_params` uses for the upgrade checklist.
func blocker_params(block: LandBlock, cost: int) -> Dictionary:
	var at := block.label if block.label != "" else block.id
	return {
		&"E_CITY_LEVEL": {"city_level": sim.progression.city_level,
				"required_level": block.min_city_level},
		&"E_FUNDS": {"cost": cost, "balance": sim.treasury.balance},
		&"E_NOT_ADJACENT": {"at": at, "fix_target_id": block.id},
		&"E_ALREADY_OWNED": {"at": at, "fix_target_id": block.id},
		&"E_UNKNOWN_BLOCK": {"at": at},
		&"E_ALREADY_DEVELOPING": {"at": at, "fix_target_id": block.id,
				"phase": _t("ui_land_phase_%s" % String(block.development_state).to_lower(), {})},
		&"E_NOT_OWNED": {"at": at, "block_id": block.id, "fix_target_id": block.id},
	}


# ===========================================================================
# Commands (doc 12 §4.4 — the UI emits commands and reads back)
# ===========================================================================

## §2.8 item 3. `auto_develop = false` on purpose: the doc's flow is two taps,
## and the panel is the surface that spells them out (see the class note).
func buy(block_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_BLOCK", {"blockers": [&"E_UNKNOWN_BLOCK"]})
	return sim.cmd_buy_block(block_id, false, false)


## §2.8 item 4.
func develop(block_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_BLOCK", {"blockers": [&"E_UNKNOWN_BLOCK"]})
	return sim.cmd_start_development(block_id, false)


# ===========================================================================
# Helpers
# ===========================================================================

## `3h 20m` / `45m` / `2d 4h` — game time, in the units §2.8's line is written in.
## Never `—`: a negative is the caller's "no reading", and it is handled there.
##
## **The arithmetic and the copy moved to `UIWidgets.duration_text()` in Wave 17**
## (doc 12 §2.22): S16's queue needs the same span in the same words, and a
## second `{h}h {m}m` in the table is a second place for it to drift. The three
## keys went with it and are neutral now (`ui_time_*`) — a span of hours is not
## the land panel's private property. This delegate stays because §2.8's own
## prose calls it by name and every caller of it is inside this class.
func duration_text(minutes: float) -> String:
	return UIWidgets.duration_text(config, minutes)


func _note_key(stage: StringName) -> String:
	match stage:
		STAGE_UNOWNED, STAGE_OWNED:
			return "ui_land_note_roads"
		STAGE_DEVELOPING:
			return "ui_land_note_developing"
	return "ui_land_note_ready"


func _array(key: String, fallback: Array) -> Array:
	var raw: Variant = section().get(key, null)
	return (raw as Array) if raw is Array and not (raw as Array).is_empty() else fallback


func _t(key: String, args: Dictionary) -> String:
	if config != null and config.has_string(key):
		return config.t(key, args)
	return key

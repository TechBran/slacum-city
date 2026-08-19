class_name HudModel
extends RefCounted
## Every piece of HUD arithmetic, headless and Node-free (constitution §3, doc 12
## §1: "`ui/` is a dumb view over pure logic"). `ui/hud.gd` only binds what this
## class computes to pixels — it owns no thresholds, no formats and no layout.
##
## Doc 12 sub-classes folded in here, one class per concern being overkill for
## the P1-32 surface:
##   * `NumberFormat`        (§2.4) — money / rate / eta / pop / clock
##   * `TopBarLayoutSolver`  (§2.4) — the stat-chip collapse solver
##   * `InAppAlertGate`      (§2.13) — foreground banner/toast budgets, NEVER push
##   * `MarkerProjector`     (§2.15) — marker clamping + clustering
##   * the §2.11 speed/pause state machine
##
## Every constant comes from `data/ui.json` through `UIConfig`; the literals in
## the `_DEFAULT_*` fallbacks exist only so a malformed data file degrades to a
## readable HUD instead of a crash (same contract as `UIConfig.get_num`).

# --- State language (doc 12 §2.5) — exactly four, keyed as data/ui.json does --
const STATE_NORMAL := &"normal"
const STATE_WARNING := &"warning"
const STATE_CRITICAL := &"critical"
const STATE_OFFLINE := &"offline"

## `state_glyphs` in data/ui.json carries names, not characters, so the glyph set
## can never drift from the palette test. This is the name → character map.
const STATE_GLYPH_CHARS := {
	"circle_filled": "●", "triangle": "▲", "diamond": "◆", "cross": "✕",
}

# --- Chip collapse modes (doc 12 §2.4) --------------------------------------
const MODE_FULL := &"full"
const MODE_COMPACT := &"compact"
const MODE_HIDDEN := &"hidden"

# --- Alert surfaces (doc 12 §2.15) ------------------------------------------
const SURFACE_BANNER := &"banner"
const SURFACE_TOAST := &"toast"
const SURFACE_NONE := &"none"

const REASON_OK := &"ok"
const REASON_BUCKET_EMPTY := &"bucket_empty"
const REASON_GLOBAL_CAP := &"global_cap"
const REASON_TYPE_COOLDOWN := &"type_cooldown"
const REASON_DISABLED := &"disabled"

# --- Speed rail (doc 12 §2.11, A10) -----------------------------------------
const SPEED_PAUSE := &"pause"
const PAUSE_GLYPH := "⏸"
const PLAY_GLYPH := "▶"
const TIMES_GLYPH := "×"
## A10: "one tap raises the speed rail, the second selects any of the four
## targets" — pause + 1×/2×/3× is always reachable in ≤ 2 taps.
const SPEED_TAPS_TO_TARGET := 2

## U+2212 MINUS SIGN, not a hyphen: doc 12 §2.4 renders negatives as `−$1.2M`.
const MINUS := "−"
const PLUS := "+"
const NO_DATA := "—"

## §2.3's mock puts an icon only on the four chips whose value is not
## self-identifying; treasury/net income/stability carry their own `$`, sign or
## word. Kept here rather than in the scene so the view stays copy-free.
const CHIP_GLYPHS := {
	"treasury": "", "incidents": "⚠", "grid": "⚡", "water": "💧",
	"population": "👥", "net_income": "", "stability": "",
}

const STABILITY_HIGH := &"high"
const STABILITY_MODERATE := &"moderate"
const STABILITY_LOW := &"low"
const STABILITY_CRITICAL := &"critical"

## Band → copy. `data/strings.en.json` has no `ui_hud_stability_*` key yet (that
## file is doc 12's to author); `label_key` is emitted alongside so the view can
## prefer the table and fall back to this only while the key is missing.
const STABILITY_WORDS := {
	"high": "High", "moderate": "Moderate", "low": "Low", "critical": "Critical",
}

## Chip names for the tap target's accessibility name (A15). Same contract as
## `STABILITY_WORDS`: the view asks `data/strings.en.json` for
## `ui_hud_chip_<id>` first and only falls back here while the key is missing.
const CHIP_LABELS := {
	"treasury": "Treasury", "incidents": "Active incidents", "grid": "Grid health",
	"water": "Water health", "population": "Population", "net_income": "Net income",
	"stability": "Stability",
}

const _DEFAULT_CHIP_PRIORITY := ["treasury", "incidents", "grid", "water",
		"population", "net_income", "stability"]
const _DEFAULT_CHIP_GAP := 6.0
const _DEFAULT_CLOCK_W := 132.0
const _DEFAULT_NEVER_HIDDEN := 4
const _DEFAULT_ALERT_TTL := 6.0
const _DEFAULT_ALERT_STACK := 2
const _DEFAULT_TOAST_TTL := 2.5
const _DEFAULT_CLUSTER_DP := 40.0
const _DEFAULT_MARKER_INSETS := [12.0, 60.0, 12.0, 70.0]
const _DEFAULT_TOP_BAR_MARGIN := 16.0  ## 8 dp each side (§2.4 `avail` formula)
const _SECONDS_PER_HOUR := 3600.0
const _HOURS_PER_DAY := 24.0

var _layout: Dictionary = {}
var _thresholds: Dictionary = {}
var _alerts_cfg: Dictionary = {}
var _speed_cfg: Dictionary = {}
var _state_glyphs: Dictionary = {}

## §3.2 `settings.in_app_banners` — the one notification control this doc owns.
var banners_enabled := true

## The ⚡ and 💧 chips' readings, on `[0, 1]`, or `< 0` for "no reading yet"
## (which is what makes the chip say `—` in OFFLINE grey rather than `0%` in
## CRITICAL red — a city with no water system is not a city with no water).
##
## Doc 04 publishes power availability per building
## (`PowerGrid.power_availability_hour`) and doc 05 publishes the water service
## factor per building (`WaterServiceLedger.all_service_factors`); the city-wide
## figure the chip wants is the mean of those, which `mean01()` computes. They
## live here rather than in the per-refresh snapshot because they settle on the
## game-hour boundary while the HUD refreshes several times a second: re-deriving
## a mean over every building at 4 Hz to display one integer would be the most
## expensive thing the UI does.
var service_power01 := -1.0
var service_water01 := -1.0

# --- InAppAlertGate live state ----------------------------------------------
var _buckets: Dictionary = {}       # class id -> tokens (float)
var _bucket_time: Dictionary = {}   # class id -> last refill timestamp
var _global_tokens := -1.0
var _global_time := 0.0
var _last_type_s: Dictionary = {}   # event type -> last banner timestamp
var _banners: Array[Dictionary] = []
var _toasts: Array[Dictionary] = []
var _seq := 0


func _init(cfg: UIConfig = null) -> void:
	if cfg == null:
		return
	_layout = cfg.layout()
	_thresholds = cfg.section("thresholds")
	_alerts_cfg = cfg.section("in_app_alerts")
	_speed_cfg = cfg.section("speed")
	_state_glyphs = cfg.section("state_glyphs")
	banners_enabled = bool(_alerts_cfg.get("enabled_default", true))


static func load_from_files() -> HudModel:
	return HudModel.new(UIConfig.load_from_files())


# ===========================================================================
# Service readings (doc 12 §2.4 P3/P4 — the ⚡ and 💧 chips)
# ===========================================================================

## `{power01, water01}` on `[0, 1]`. Either key may be absent (that reading is
## left alone) or negative (that chip goes back to "no reading"). Called by the
## shell on the game-hour boundary, when docs 04/05 settle.
func ingest_service(snapshot: Dictionary) -> void:
	if snapshot.has("power01"):
		service_power01 = HudModel._clamp_or_unknown(float(snapshot["power01"]))
	if snapshot.has("water01"):
		service_water01 = HudModel._clamp_or_unknown(float(snapshot["water01"]))


static func _clamp_or_unknown(value: float) -> float:
	return -1.0 if value < 0.0 else clampf(value, 0.0, 1.0)


## The city-wide fraction from a per-building publication: `{id: fraction}` from
## `PowerGrid`/`WaterServiceLedger`, or a bare `Array` of fractions. An empty
## collection is `-1.0`, i.e. "no reading", not `0`.
##
## Unweighted on purpose: doc 04's own block-dark rule is population-weighted and
## doc 12 §2.4 asks the chip for "grid health", not for "how many people are in
## the dark" — that second number is what the alerts feed's `{count} blocks are
## dark` already says, and the two must not be the same statistic wearing
## different labels.
static func mean01(values: Variant) -> float:
	var total := 0.0
	var count := 0
	if values is Dictionary:
		for key: Variant in (values as Dictionary):
			total += clampf(float((values as Dictionary)[key]), 0.0, 1.0)
			count += 1
	elif values is Array:
		for value: Variant in (values as Array):
			total += clampf(float(value), 0.0, 1.0)
			count += 1
	elif values is PackedFloat32Array or values is PackedFloat64Array:
		for value: float in values:
			total += clampf(value, 0.0, 1.0)
			count += 1
	if count <= 0:
		return -1.0
	return total / float(count)


## The percentage a chip renders, resolved in one place: an explicit `*_pct` on
## the snapshot wins, then a `[0,1]` fraction on the snapshot, then the ingested
## reading, then "no reading".
func _service_pct(snapshot: Dictionary, pct_key: String, frac_key: String,
		stored: float) -> float:
	if snapshot.has(pct_key):
		return float(snapshot[pct_key])
	if snapshot.has(frac_key):
		return HudModel._clamp_or_unknown(float(snapshot[frac_key])) * 100.0
	return stored * 100.0 if stored >= 0.0 else -1.0


# ===========================================================================
# NumberFormat (doc 12 §2.4, test 14)
# ===========================================================================

## Thousands-grouped decimal digits. String-based so an int64 never round-trips
## through a float and loses its low digits.
static func group_digits(digits: String) -> String:
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits.substr(i, 1) + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return out


## `pop(n)` — thousands-grouped with `,` (§2.4).
static func pop(value: int) -> String:
	var parts := _split_sign(value)
	return str(parts["sign"]) + group_digits(str(parts["digits"]))


## `money(n)` — `$8,420` below 10K, `$842K` below 10⁶, `$8.42M` below 10⁹, else
## `$8.42B`; 3 significant digits above 10K, negatives as `−$1.2M` (§2.4).
## int64-safe end to end: the ladder is chosen from the digit *count* and the
## rounding is string arithmetic, so `9223372036854775807` formats exactly.
static func money(amount: int) -> String:
	var parts := _split_sign(amount)
	var digits: String = parts["digits"]
	var sign_text: String = parts["sign"]
	if digits.length() <= 4:
		return "%s$%s" % [sign_text, group_digits(digits)]
	return "%s$%s" % [sign_text, compact_magnitude(digits)]


## `rate(per_game_hour)` — per day (`value * 24`), `+`/`−` prefix, `/d` suffix.
## Doc 12 test 14: `rate(5750) == "+$138K/d"`.
static func rate_per_day(per_game_hour: float) -> String:
	var per_day := int(round(per_game_hour * _HOURS_PER_DAY))
	var sign_text := MINUS if per_day < 0 else PLUS
	var parts := _split_sign(per_day)
	var digits: String = parts["digits"]
	var body := group_digits(digits) if digits.length() <= 4 else compact_magnitude(digits)
	return "%s$%s/d" % [sign_text, body]


## Same, without the `/d` suffix — what the 64 dp compact net-income chip shows.
static func rate_per_day_compact(per_game_hour: float) -> String:
	return rate_per_day(per_game_hour).trim_suffix("/d")


## `eta(sec)` — `m:ss` under an hour, `h:mm` at or above one (§2.4, test 14).
static func eta(seconds: int) -> String:
	var s := maxi(0, seconds)
	if s < 3600:
		return "%d:%02d" % [s / 60, s % 60]
	return "%d:%02d" % [s / 3600, (s % 3600) / 60]


## Clock chip face: `06:12` from doc 01's `minute_of_day()`.
static func clock_hhmm(minute_of_day: int) -> String:
	var m := ((minute_of_day % 1440) + 1440) % 1440
	return "%02d:%02d" % [m / 60, m % 60]


## Day label. `data/strings.en.json` owns no `ui_hud_day` key yet, so the view
## prefers the table and falls back to this.
static func day_label(day_index: int) -> String:
	return "Day %d" % (day_index + 1)


## Compact form of a magnitude given as a digit string: `842` → `842K` is not it —
## the *unit* is derived from the digit count, so `"842000"` → `"842K"` and
## `"8420000"` → `"8.42M"`. Exposed because population uses the same ladder.
static func compact_magnitude(digits: String) -> String:
	var n := digits.length()
	if n <= 3:
		return digits
	var unit_index := 0
	if n >= 10:
		unit_index = 2
	elif n >= 7:
		unit_index = 1
	var exponent := 3 * (unit_index + 1)
	var int_digits := n - exponent
	if int_digits <= 0:
		return group_digits(digits)
	var keep := maxi(int_digits, 3)
	var rounded := _round_digits(digits, keep)
	if rounded.length() > keep:
		# 999,999 rounds to 1,000K: re-enter the ladder one digit higher.
		return compact_magnitude("1" + "0".repeat(n))
	var text: String = rounded.substr(0, int_digits)
	if rounded.length() > int_digits:
		text += "." + rounded.substr(int_digits)
	return _trim_trailing_zeros(text) + ["K", "M", "B"][unit_index]


static func _split_sign(value: int) -> Dictionary:
	# str() first: absi(INT64_MIN) overflows, the decimal string never does.
	var text := str(value)
	if text.begins_with("-"):
		return {"sign": MINUS, "digits": text.substr(1)}
	return {"sign": "", "digits": text}


static func _round_digits(digits: String, keep: int) -> String:
	if keep >= digits.length():
		return digits
	var head := digits.substr(0, keep)
	if digits.substr(keep, 1) < "5":
		return head
	return _increment_digits(head)


static func _increment_digits(digits: String) -> String:
	var out := ""
	var carry := 1
	for i in range(digits.length() - 1, -1, -1):
		var d := digits.unicode_at(i) - 48 + carry
		carry = 0
		if d >= 10:
			d -= 10
			carry = 1
		out = String.chr(48 + d) + out
	return ("1" + out) if carry > 0 else out


static func _trim_trailing_zeros(text: String) -> String:
	if not text.contains("."):
		return text
	var out := text
	while out.ends_with("0"):
		out = out.substr(0, out.length() - 1)
	return out.trim_suffix(".")


# ===========================================================================
# Chip values and states (doc 12 §2.4 thresholds, data/ui.json.thresholds)
# ===========================================================================

## `data/strings.en.json` key for a chip's accessibility name (G-8 convention
## `ui_<screen>_<element>`).
static func chip_label_key(chip_id: String) -> String:
	return "ui_hud_chip_%s" % chip_id


func chip_order() -> Array:
	var priority: Variant = _layout.get("chip_priority", _DEFAULT_CHIP_PRIORITY)
	return priority.duplicate() if priority is Array else _DEFAULT_CHIP_PRIORITY.duplicate()


## How many rows the top bar may wrap to before it starts hiding chips
## (`layout.top_bar_max_rows`). 1 is the doc's single-row behaviour exactly.
func top_bar_max_rows() -> int:
	return maxi(1, UIConfig.get_int(_layout, "top_bar_max_rows", 1))


func chip_width_dp(chip_id: String, mode: StringName) -> float:
	if mode == MODE_HIDDEN:
		return 0.0
	var key := "chip_widths_full_dp" if mode == MODE_FULL else "chip_widths_compact_dp"
	var block: Variant = _layout.get(key, {})
	var widths: Dictionary = block if block is Dictionary else {}
	return UIConfig.get_num(widths, chip_id, 64.0)


## `< 0` → CRITICAL; projected-insolvent-within-24 h → WARNING (§2.4 P1).
func treasury_state(balance: int, net_per_hour: float) -> StringName:
	if balance < 0:
		return STATE_CRITICAL
	if float(balance) + net_per_hour * _HOURS_PER_DAY < 0.0:
		return STATE_WARNING
	return STATE_NORMAL


## `< 0` → WARNING, below −5 % of treasury per day → CRITICAL (§2.4 P6).
func net_income_state(net_per_hour: float, balance: int) -> StringName:
	var per_day := net_per_hour * _HOURS_PER_DAY
	if per_day >= 0.0:
		return STATE_NORMAL
	if balance > 0 and per_day < -0.05 * float(balance):
		return STATE_CRITICAL
	return STATE_WARNING


## ≥95 NORMAL, 85–94 WARNING, 60–84 CRITICAL, <60 CRITICAL + pulse (§2.4 P3/P4).
## A negative percentage means "no reading yet" and reads as OFFLINE, which is
## exactly what the fourth data state is for.
func health_state(pct: float, prefix: String = "grid") -> StringName:
	if pct < 0.0:
		return STATE_OFFLINE
	if pct >= UIConfig.get_num(_thresholds, prefix + "_normal_pct", 95.0):
		return STATE_NORMAL
	if pct >= UIConfig.get_num(_thresholds, prefix + "_warning_pct", 85.0):
		return STATE_WARNING
	return STATE_CRITICAL


## <60 % pulses (§2.4: "CRITICAL+pulse"), which the view drives at
## `state_pulse_hz.critical`.
func health_pulses(pct: float, prefix: String = "grid") -> bool:
	return pct >= 0.0 and pct < UIConfig.get_num(_thresholds, prefix + "_critical_pct", 60.0)


## Δ < −0.5 %/day → WARNING (§2.4 P5).
func population_state(delta_pct_per_day: float) -> StringName:
	var limit := UIConfig.get_num(_thresholds, "population_decline_warn_pct_per_day", -0.5)
	return STATE_WARNING if delta_pct_per_day < limit else STATE_NORMAL


## doc 09 publishes `city_stability ∈ [0,1]`; the UI displays `round(100·s)` and
## bands it. §2.4: "The conversion happens once, in the chip" — this is it.
func stability_percent(stability01: float) -> int:
	return int(round(clampf(stability01, 0.0, 1.0) * 100.0))


func stability_band(stability01: float) -> StringName:
	var pct := float(stability_percent(stability01))
	if pct >= UIConfig.get_num(_thresholds, "stability_high", 75.0):
		return STABILITY_HIGH
	if pct >= UIConfig.get_num(_thresholds, "stability_moderate", 50.0):
		return STABILITY_MODERATE
	if pct >= UIConfig.get_num(_thresholds, "stability_low", 25.0):
		return STABILITY_LOW
	return STABILITY_CRITICAL


## The four bands are not the four data states, so the mapping is stated once
## here: High reads NORMAL, Moderate WARNING, Low and Critical CRITICAL.
func stability_state(stability01: float) -> StringName:
	match stability_band(stability01):
		STABILITY_HIGH: return STATE_NORMAL
		STABILITY_MODERATE: return STATE_WARNING
		_: return STATE_CRITICAL


## `tier = clamp(floor(severity), 1, 5)` is doc 06's; the chip badge is
## `max(tier)` over active incidents (§2.4 P2).
static func incident_tier(severity: float) -> int:
	return clampi(int(floor(severity)), 1, 5)


static func worst_tier(severities: Array) -> int:
	var worst := 0
	for value: Variant in severities:
		worst = maxi(worst, HudModel.incident_tier(float(value)))
	return worst


func incidents_state(count: int, badge_tier: int) -> StringName:
	if count <= 0:
		return STATE_NORMAL
	if badge_tier >= 4:
		return STATE_CRITICAL
	if badge_tier == 3:
		return STATE_WARNING
	return STATE_NORMAL


func state_glyph(state: StringName) -> String:
	var name := str(_state_glyphs.get(String(state), ""))
	return str(STATE_GLYPH_CHARS.get(name, ""))


# ===========================================================================
# TopBarLayoutSolver (doc 12 §2.4, test 10)
# ===========================================================================

## The §2.4 pseudocode verbatim, plus two things the doc's version cannot know
## about on its own:
##
##     avail = W - clock_w - 16
##     loop: demote the lowest-priority FULL chip, then hide the lowest-priority
##           COMPACT chip whose priority > 4; P1–P4 are never hidden.
##
## **`min_widths`** is what the view measured for each chip's actual text
## (`{chip_id: {full: dp, compact: dp}}`, or a bare number for both). The doc's
## widths are a layout *budget*; a chip whose value string is wider than its
## budget would clip, and A1/A2 forbid clipping. The effective width is therefore
## `max(doc width, measured width)`, so the collapse decisions are taken against
## the pixels that will actually be drawn.
##
## **`max_rows`** lets the bar wrap. With `max_rows == 1` this function is
## byte-identical to the doc's single-row solver. With more, the demotion phase
## still runs first, but when everything-compact still overflows the bar wraps
## instead of hiding: a wrapped chip is readable, a hidden one is gone, and on a
## near-square display (Fold inner, ~1:1) that is the difference between the
## whole top bar and four of its seven readings. Chips are only hidden once even
## the last row is full.
##
## `clock_w_dp < 0` takes `layout.clock_chip_w_dp`. Returns
## `{modes, order, visible, rows, row_widths, wrapped, avail, need, iterations}` —
## pure, deterministic, and bounded at 7 demotions + 3 hides.
func solve_top_bar(width_dp: float, clock_w_dp: float = -1.0,
		min_widths: Dictionary = {}, max_rows: int = 1) -> Dictionary:
	var order := chip_order()
	var gap := UIConfig.get_num(_layout, "chip_gap_dp", _DEFAULT_CHIP_GAP)
	var clock_w := clock_w_dp if clock_w_dp >= 0.0 \
			else UIConfig.get_num(_layout, "clock_chip_w_dp", _DEFAULT_CLOCK_W)
	var never_hidden := UIConfig.get_int(_layout, "chip_never_hidden_count",
			_DEFAULT_NEVER_HIDDEN)
	var avail := width_dp - clock_w - _DEFAULT_TOP_BAR_MARGIN
	var avail_rest := width_dp - _DEFAULT_TOP_BAR_MARGIN

	var modes: Dictionary = {}
	for chip_id: String in order:
		modes[chip_id] = MODE_FULL

	# --- demotion phase (§2.4, unchanged) ----------------------------------
	var iterations := 0
	var need := _top_bar_need(order, modes, gap, min_widths)
	while need > avail:
		var demoted := false
		for i in range(order.size() - 1, -1, -1):
			if modes[order[i]] == MODE_FULL:
				modes[order[i]] = MODE_COMPACT
				demoted = true
				break
		if not demoted:
			break
		iterations += 1
		need = _top_bar_need(order, modes, gap, min_widths)

	var rows: Array = [[]]
	var row_widths: Array = [need]
	var wrapped := false

	if need > avail and maxi(1, max_rows) > 1:
		# --- wrap phase: nothing is hidden while a row can still hold it ----
		var packed := _pack_rows(order, modes, gap, min_widths, avail, avail_rest,
				max_rows)
		while not (packed["leftover"] as Array).is_empty():
			var hidden := false
			for i in range(order.size() - 1, never_hidden - 1, -1):
				if modes[order[i]] != MODE_HIDDEN:
					modes[order[i]] = MODE_HIDDEN
					hidden = true
					break
			if not hidden:
				break  # P1–P4 stay, even if they overflow: the doc's final `break`.
			iterations += 1
			packed = _pack_rows(order, modes, gap, min_widths, avail, avail_rest, max_rows)
		rows = packed["rows"]
		row_widths = packed["widths"]
		wrapped = rows.size() > 1
		need = 0.0
		for width: Variant in row_widths:
			need = maxf(need, float(width))
	elif need > avail:
		# --- hide phase (§2.4, single-row behaviour) -----------------------
		while need > avail:
			var hidden := false
			for i in range(order.size() - 1, never_hidden - 1, -1):
				if modes[order[i]] == MODE_COMPACT:
					modes[order[i]] = MODE_HIDDEN
					hidden = true
					break
			if not hidden:
				break
			iterations += 1
			need = _top_bar_need(order, modes, gap, min_widths)

	var visible: Array[String] = []
	for chip_id: String in order:
		if modes[chip_id] != MODE_HIDDEN:
			visible.append(chip_id)
	if not wrapped:
		rows = [visible.duplicate()]
		row_widths = [need]
	return {
		"modes": modes,
		"order": order,
		"visible": visible,
		"rows": rows,
		"row_widths": row_widths,
		"wrapped": wrapped,
		"avail": avail,
		"avail_rest": avail_rest,
		"need": need,
		"iterations": iterations,
	}


## Effective width of one chip: the doc's budget, widened to whatever the view
## measured its text at. Hidden chips are 0.
func _effective_width(chip_id: String, mode: StringName, min_widths: Dictionary) -> float:
	if mode == MODE_HIDDEN:
		return 0.0
	var base := chip_width_dp(chip_id, mode)
	var entry: Variant = min_widths.get(chip_id, null)
	if entry is Dictionary:
		return maxf(base, UIConfig.get_num(entry,
				"full" if mode == MODE_FULL else "compact", 0.0))
	if entry is float or entry is int:
		return maxf(base, float(entry))
	return base


func _top_bar_need(order: Array, modes: Dictionary, gap: float,
		min_widths: Dictionary = {}) -> float:
	var total := 0.0
	var count := 0
	for chip_id: String in order:
		var mode: StringName = modes[chip_id]
		if mode == MODE_HIDDEN:
			continue
		total += _effective_width(chip_id, mode, min_widths)
		count += 1
	return total + gap * float(maxi(0, count - 1))


## Greedy priority-order packing. Row 0 shares its line with the clock chip, so
## it gets `avail`; every wrapped row below spans the whole bar. A chip wider
## than a whole row still gets its own row rather than being dropped — that is
## the caller's cue to raise `max_rows` or the player's to raise the window.
func _pack_rows(order: Array, modes: Dictionary, gap: float, min_widths: Dictionary,
		avail_first: float, avail_rest: float, max_rows: int) -> Dictionary:
	var rows: Array = []
	var widths: Array = []
	var leftover: Array = []
	var current: Array = []
	var width := 0.0
	for chip_id: String in order:
		if modes[chip_id] == MODE_HIDDEN:
			continue
		if rows.size() >= max_rows:
			leftover.append(chip_id)
			continue
		var chip_w := _effective_width(chip_id, modes[chip_id], min_widths)
		var limit := avail_first if rows.is_empty() else avail_rest
		var addition := chip_w if current.is_empty() else gap + chip_w
		if current.is_empty() or width + addition <= limit:
			current.append(chip_id)
			width += addition
			continue
		rows.append(current)
		widths.append(width)
		if rows.size() >= max_rows:
			leftover.append(chip_id)
			current = []
			width = 0.0
			continue
		current = [chip_id]
		width = chip_w
	if not current.is_empty():
		rows.append(current)
		widths.append(width)
	if rows.is_empty():
		rows.append([])
		widths.append(0.0)
	return {"rows": rows, "widths": widths, "leftover": leftover}


# ===========================================================================
# The whole HUD view (what `ui/hud.gd` binds)
# ===========================================================================

## `snapshot` keys (all optional, all plain data — the UI never holds a sim ref):
##   population:int · population_delta_pct_per_day:float · treasury:int
##   net_per_hour:float · stability:float ∈[0,1] · happiness:float
##   grid_pct:float · water_pct:float, or power01/water01 on [0,1]; absent on
##     both falls back to `ingest_service()`'s reading and then to OFFLINE "—"
##   incidents:int | {count, worst_tier | severities}
##   clock:int minutes | {minute_of_day, day_index} · speed:int · paused:bool
func build_view(snapshot: Dictionary, width_dp: float,
		clock_w_dp: float = -1.0, min_widths: Dictionary = {},
		max_rows: int = 1) -> Dictionary:
	var balance := int(snapshot.get("treasury", 0))
	var net_per_hour := float(snapshot.get("net_per_hour", 0.0))
	var solve := solve_top_bar(width_dp, clock_w_dp, min_widths, max_rows)
	var values := chip_values(snapshot)
	var chips: Array[Dictionary] = []
	for chip_id: String in solve["order"]:
		var chip: Dictionary = values[chip_id]
		var mode: StringName = (solve["modes"] as Dictionary)[chip_id]
		chip["mode"] = mode
		# The width the view stamps on the button: never below what its own text
		# measured, or the chip would clip on a narrow display.
		chip["width_dp"] = _effective_width(chip_id, mode, min_widths)
		chip["budget_dp"] = chip_width_dp(chip_id, mode)
		chip["text"] = chip["text_compact"] if mode == MODE_COMPACT else chip["text_full"]
		chips.append(chip)
	return {
		"chips": chips,
		"top_bar": solve,
		"clock": clock_view(snapshot),
		"speed": speed_view(int(snapshot.get("speed", 1)),
				bool(snapshot.get("paused", false))),
		"treasury_balance": balance,
		"net_per_hour": net_per_hour,
		"happiness": float(snapshot.get("happiness", 0.0)),
	}


func chip_values(snapshot: Dictionary) -> Dictionary:
	var balance := int(snapshot.get("treasury", 0))
	var net_per_hour := float(snapshot.get("net_per_hour", 0.0))
	var population := int(snapshot.get("population", 0))
	var pop_delta := float(snapshot.get("population_delta_pct_per_day", 0.0))
	var stability01 := float(snapshot.get("stability", 0.0))
	var grid_pct := _service_pct(snapshot, "grid_pct", "power01", service_power01)
	var water_pct := _service_pct(snapshot, "water_pct", "water01", service_water01)
	var incidents: Dictionary = _incident_block(snapshot.get("incidents", 0))
	var count := int(incidents["count"])
	var badge := int(incidents["worst_tier"])

	var stability_pct := stability_percent(stability01)
	var band := stability_band(stability01)
	var pop_digits: String = _split_sign(population)["digits"]

	var out := {
		"treasury": _chip("treasury", money(balance), money(balance),
				treasury_state(balance, net_per_hour)),
		"incidents": _chip("incidents", str(count), str(count),
				incidents_state(count, badge)),
		"grid": _chip("grid", _percent_text(grid_pct), _percent_text(grid_pct),
				health_state(grid_pct, "grid")),
		"water": _chip("water", _percent_text(water_pct), _percent_text(water_pct),
				health_state(water_pct, "water")),
		"population": _chip("population", pop(population),
				compact_magnitude(pop_digits) if pop_digits.length() > 4 else pop(population),
				population_state(pop_delta)),
		"net_income": _chip("net_income", rate_per_day(net_per_hour),
				rate_per_day_compact(net_per_hour),
				net_income_state(net_per_hour, balance)),
		"stability": _chip("stability",
				"%s %d" % [STABILITY_WORDS[String(band)], stability_pct],
				str(stability_pct), stability_state(stability01)),
	}
	(out["incidents"] as Dictionary)["badge_tier"] = badge
	(out["grid"] as Dictionary)["pulse"] = health_pulses(grid_pct, "grid")
	(out["water"] as Dictionary)["pulse"] = health_pulses(water_pct, "water")
	(out["stability"] as Dictionary)["band"] = band
	(out["stability"] as Dictionary)["label_key"] = "ui_hud_stability_%s" % String(band)
	(out["stability"] as Dictionary)["percent"] = stability_pct
	return out


func _chip(chip_id: String, text_full: String, text_compact: String,
		state: StringName) -> Dictionary:
	return {
		"id": chip_id,
		"glyph": str(CHIP_GLYPHS.get(chip_id, "")),
		"text_full": text_full,
		"text_compact": text_compact,
		"state": state,
		"state_glyph": state_glyph(state),
		"pulse": false,
	}


static func _percent_text(pct: float) -> String:
	return NO_DATA if pct < 0.0 else "%d%%" % int(round(pct))


static func _incident_block(raw: Variant) -> Dictionary:
	if raw is Dictionary:
		var block: Dictionary = raw
		var count := int(block.get("count", 0))
		var worst := int(block.get("worst_tier", 0))
		var severities: Variant = block.get("severities", null)
		if severities is Array:
			count = maxi(count, (severities as Array).size())
			worst = maxi(worst, HudModel.worst_tier(severities))
		return {"count": count, "worst_tier": worst}
	return {"count": int(raw), "worst_tier": 0}


func clock_view(snapshot: Dictionary) -> Dictionary:
	var raw: Variant = snapshot.get("clock", 0)
	var minute := 0
	var day := 0
	if raw is Dictionary:
		minute = int((raw as Dictionary).get("minute_of_day", 0))
		day = int((raw as Dictionary).get("day_index", 0))
	else:
		minute = int(raw)
		day = int(snapshot.get("day_index", 0))
	return {
		"time": clock_hhmm(minute),
		"day_index": day,
		"day": day_label(day),
		"minute_of_day": minute,
		# doc 07 owns weather; until it lands the chip carries the clock alone.
		"weather_glyph": "",
	}


# ===========================================================================
# Speed & pause (doc 12 §2.11, A10)
# ===========================================================================

## doc 01 locks `speed ∈ {1,2,3}`. JSON hands them back as floats, so they are
## normalised to ints once, here, and never compared as floats anywhere else.
func speed_options() -> Array[int]:
	var raw: Variant = _speed_cfg.get("options", [1, 2, 3])
	var out: Array[int] = []
	if raw is Array:
		for value: Variant in (raw as Array):
			out.append(int(value))
	return out if not out.is_empty() else ([1, 2, 3] as Array[int])


func clamp_speed(speed: int) -> int:
	var options := speed_options()
	if options.is_empty():
		return 1
	for value: Variant in options:
		if int(value) == speed:
			return speed
	return int(options[0])


static func speed_option_id(multiplier: int) -> StringName:
	return StringName("%dx" % multiplier)


## `{face, options[], expanded}`. The face shows `⏸` while paused, otherwise the
## current multiplier (§2.11); every option is its own 48 dp target (A3).
func speed_view(speed: int, paused: bool, expanded: bool = false) -> Dictionary:
	var current := clamp_speed(speed)
	var options: Array[Dictionary] = [{
		"id": SPEED_PAUSE,
		"text": PAUSE_GLYPH,
		"selected": paused,
		"multiplier": 0,
	}]
	for value: Variant in speed_options():
		var multiplier := int(value)
		options.append({
			"id": speed_option_id(multiplier),
			"text": "%s %d%s" % [PLAY_GLYPH.repeat(mini(multiplier, 3)), multiplier, TIMES_GLYPH],
			"selected": (not paused) and multiplier == current,
			"multiplier": multiplier,
		})
	return {
		"face": PAUSE_GLYPH if paused else "%d%s" % [current, TIMES_GLYPH],
		"speed": current,
		"paused": paused,
		"options": options,
		"expanded": expanded,
		"taps_to_target": SPEED_TAPS_TO_TARGET,
	}


## One selection on the raised rail. `pause` toggles the separate bool (doc 01);
## picking a multiplier both sets the speed and resumes — the target is labelled
## `▶ n×`, so leaving the clock frozen behind a play glyph would be a lie.
func apply_speed_option(option: StringName, speed: int, paused: bool) -> Dictionary:
	if option == SPEED_PAUSE:
		return {"speed": clamp_speed(speed), "paused": not paused}
	for value: Variant in speed_options():
		if option == speed_option_id(int(value)):
			return {"speed": int(value), "paused": false}
	return {"speed": clamp_speed(speed), "paused": paused}


## §2.11: `auto_speed_reset_on_critical` "resets speed to 1× and never
## force-pauses — pausing the player mid-crisis is worse than the crisis".
func auto_speed_reset(speed: int, paused: bool) -> Dictionary:
	if not bool(_speed_cfg.get("auto_speed_reset_on_critical", true)):
		return {"speed": clamp_speed(speed), "paused": paused}
	var options := speed_options()
	var floor_speed := int(options[0]) if not options.is_empty() else 1
	return {"speed": floor_speed, "paused": paused}


## §2.11: "A save that was paused resumes unpaused at its stored speed."
func resume_from_save(saved_speed: int, saved_paused: bool) -> Dictionary:
	if not bool(_speed_cfg.get("resume_unpaused", true)):
		return {"speed": clamp_speed(saved_speed), "paused": saved_paused}
	return {"speed": clamp_speed(saved_speed), "paused": false}


# ===========================================================================
# InAppAlertGate (doc 12 §2.13, test 17)
# ===========================================================================
# FOREGROUND banners and toasts only. These budgets are ~3× doc 08's push
# budgets and that is deliberate (C-72): this gate never reads
# data/notifications.json, never emits a push and never consults quiet hours.

func may_emit_push() -> bool:
	return bool(_alerts_cfg.get("may_emit_push", false))


func consults_quiet_hours() -> bool:
	return bool(_alerts_cfg.get("consults_quiet_hours", false))


func alert_class(class_id: String) -> Dictionary:
	var classes: Variant = _alerts_cfg.get("classes", {})
	if not (classes is Dictionary):
		return {}
	var block: Variant = (classes as Dictionary).get(class_id.to_lower(), {})
	return block if block is Dictionary else {}


## `alert` keys: `class` (`p1`/`p2`/`p3`), `event_type`, `title`, `body`,
## optional `id` and `payload`. Returns
## `{delivered, surface, coalesced, reason, id, count}` where `delivered` means a
## *banner* was raised; a refused banner degrades to the class's `degrade_to`
## surface (a toast), never to silence.
func submit_alert(now_s: float, alert: Dictionary) -> Dictionary:
	_prune(now_s)
	var class_id := str(alert.get("class", "p3")).to_lower()
	var cls := alert_class(class_id)
	var event_type := str(alert.get("event_type", ""))
	var never_drop := bool(cls.get("never_drop", false))
	var exempt := bool(cls.get("exempt_from_global", false))
	var surface := StringName(str(cls.get("surface", "banner")))
	var degrade := StringName(str(cls.get("degrade_to", "toast")))
	var cooldown_s := UIConfig.get_num(_alerts_cfg, "per_type_cooldown_s", 600.0)
	var coalesce_s := UIConfig.get_num(cls, "coalesce_window_s", 0.0)

	# The one control this doc owns (§2.13) suppresses *banners*; a never_drop P1
	# is still surfaced, as a toast, rather than being silently swallowed.
	if not banners_enabled:
		return _degrade(now_s, alert, class_id, SURFACE_TOAST, REASON_DISABLED)

	_refill_class(class_id, now_s)
	_refill_global(now_s)

	var reason := REASON_OK
	if event_type != "" and _last_type_s.has(event_type) \
			and now_s - float(_last_type_s[event_type]) < cooldown_s:
		reason = REASON_TYPE_COOLDOWN
	elif float(_buckets.get(class_id, 0.0)) < 1.0:
		reason = REASON_BUCKET_EMPTY
	elif not exempt and _global_tokens < 1.0:
		reason = REASON_GLOBAL_CAP

	if reason != REASON_OK and not never_drop:
		return _degrade(now_s, alert, class_id, degrade, reason)

	_buckets[class_id] = maxf(0.0, float(_buckets.get(class_id, 0.0)) - 1.0)
	if not exempt:
		_global_tokens = maxf(0.0, _global_tokens - 1.0)
	if event_type != "":
		_last_type_s[event_type] = now_s

	# P1 coalescing (§2.13): a P1 within `coalesce_window_s` of the previous one
	# replaces it in place with an updated title, so a cascade is one banner.
	if coalesce_s > 0.0:
		for i in range(_banners.size() - 1, -1, -1):
			var live: Dictionary = _banners[i]
			if str(live["class"]) != class_id:
				continue
			if now_s - float(live["shown_at"]) >= coalesce_s:
				break
			live["count"] = int(live["count"]) + 1
			live["title"] = str(alert.get("title", live["title"]))
			live["body"] = str(alert.get("body", live.get("body", "")))
			live["shown_at"] = now_s
			live["event_type"] = event_type
			return {"delivered": true, "surface": surface, "coalesced": true,
					"reason": reason, "id": str(live["id"]), "count": int(live["count"])}

	_seq += 1
	var banner := {
		"id": str(alert.get("id", "alert_%d" % _seq)),
		"class": class_id,
		"event_type": event_type,
		"title": str(alert.get("title", "")),
		"body": str(alert.get("body", "")),
		"payload": alert.get("payload", {}),
		"shown_at": now_s,
		"sticky": never_drop,
		"count": 1,
	}
	_banners.append(banner)
	var max_stack := UIConfig.get_int(_layout, "alert_max_stack", _DEFAULT_ALERT_STACK)
	while _banners.size() > max_stack:
		_banners.remove_at(0)
	return {"delivered": true, "surface": surface, "coalesced": false,
			"reason": reason, "id": str(banner["id"]), "count": 1}


func _degrade(now_s: float, alert: Dictionary, class_id: String,
		surface: StringName, reason: StringName) -> Dictionary:
	if surface != SURFACE_TOAST:
		return {"delivered": false, "surface": SURFACE_NONE, "coalesced": false,
				"reason": reason, "id": "", "count": 0}
	_seq += 1
	var toast := {
		"id": str(alert.get("id", "toast_%d" % _seq)),
		"class": class_id,
		"event_type": str(alert.get("event_type", "")),
		"title": str(alert.get("title", "")),
		"shown_at": now_s,
	}
	_toasts = [toast]  # §2.15: max 1, newest replaces.
	return {"delivered": false, "surface": SURFACE_TOAST, "coalesced": false,
			"reason": reason, "id": str(toast["id"]), "count": 0}


func _refill_class(class_id: String, now_s: float) -> void:
	var cls := alert_class(class_id)
	var capacity := UIConfig.get_num(cls, "bucket_capacity", 1.0)
	var rate := UIConfig.get_num(cls, "refill_per_real_hour", 1.0)
	if not _buckets.has(class_id):
		_buckets[class_id] = capacity
		_bucket_time[class_id] = now_s
		return
	var elapsed := maxf(0.0, now_s - float(_bucket_time.get(class_id, now_s)))
	_buckets[class_id] = minf(capacity,
			float(_buckets[class_id]) + elapsed * rate / _SECONDS_PER_HOUR)
	_bucket_time[class_id] = now_s


func _refill_global(now_s: float) -> void:
	var capacity := UIConfig.get_num(_alerts_cfg, "global_max_per_hour", 3.0)
	if _global_tokens < 0.0:
		_global_tokens = capacity
		_global_time = now_s
		return
	var elapsed := maxf(0.0, now_s - _global_time)
	_global_tokens = minf(capacity, _global_tokens + elapsed * capacity / _SECONDS_PER_HOUR)
	_global_time = now_s


## Live banners, oldest first, at most `alert_max_stack`. Non-sticky banners
## expire after `alert_ttl_s`; P1 is sticky until tapped (§2.15).
func active_alerts(now_s: float) -> Array[Dictionary]:
	_prune(now_s)
	return _banners.duplicate(true)


func active_toast(now_s: float) -> Dictionary:
	_prune(now_s)
	return (_toasts[0] as Dictionary).duplicate() if not _toasts.is_empty() else {}


## Tapping a banner dismisses it — the only way a sticky P1 leaves the stack.
func dismiss_alert(alert_id: String) -> bool:
	for i in _banners.size():
		if str((_banners[i] as Dictionary)["id"]) == alert_id:
			_banners.remove_at(i)
			return true
	return false


func clear_alerts() -> void:
	_banners.clear()
	_toasts.clear()


func alert_tokens(class_id: String) -> float:
	return float(_buckets.get(class_id.to_lower(), -1.0))


func global_tokens() -> float:
	return _global_tokens


func _prune(now_s: float) -> void:
	var ttl := UIConfig.get_num(_layout, "alert_ttl_s", _DEFAULT_ALERT_TTL)
	for i in range(_banners.size() - 1, -1, -1):
		var banner: Dictionary = _banners[i]
		if bool(banner["sticky"]):
			continue
		if now_s - float(banner["shown_at"]) >= ttl:
			_banners.remove_at(i)
	var toast_ttl := UIConfig.get_num(_layout, "toast_ttl_s", _DEFAULT_TOAST_TTL)
	if not _toasts.is_empty() \
			and now_s - float((_toasts[0] as Dictionary)["shown_at"]) >= toast_ttl:
		_toasts.clear()


# ===========================================================================
# MarkerProjector (doc 12 §2.15, test 18)
# ===========================================================================

## The rect off-screen pins clamp into. `marker_rect_inset_dp` is
## `[left, top, right, bottom]`; the drawer eats `drawer_w` off the right when it
## is open, so a pin never hides behind it.
func marker_rect(viewport_dp: Vector2, drawer_w_dp: float = 0.0,
		drawer_open: bool = false) -> Rect2:
	var raw: Variant = _layout.get("marker_rect_inset_dp", _DEFAULT_MARKER_INSETS)
	var insets: Array = raw if raw is Array and (raw as Array).size() >= 4 \
			else _DEFAULT_MARKER_INSETS
	var left := float(insets[0])
	var top := float(insets[1])
	var right := float(insets[2])
	var bottom := float(insets[3])
	var drawer := drawer_w_dp if drawer_open else 0.0
	return Rect2(left, top,
			maxf(0.0, viewport_dp.x - left - right - drawer),
			maxf(0.0, viewport_dp.y - top - bottom))


func marker_cluster_dp() -> float:
	return UIConfig.get_num(_layout, "marker_cluster_dp", _DEFAULT_CLUSTER_DP)


## Clamp a projected pin into the marker rect. Returns
## `{position, offscreen, direction}`; `direction` is the unit vector from the
## rect centre, which the view turns into the 32 dp edge arrow.
func clamp_marker(screen_dp: Vector2, rect: Rect2) -> Dictionary:
	var clamped := Vector2(
			clampf(screen_dp.x, rect.position.x, rect.position.x + rect.size.x),
			clampf(screen_dp.y, rect.position.y, rect.position.y + rect.size.y))
	var offscreen := not clamped.is_equal_approx(screen_dp)
	var delta := screen_dp - rect.get_center()
	return {
		"position": clamped,
		"offscreen": offscreen,
		"direction": delta.normalized() if delta.length() > 0.0001 else Vector2.ZERO,
	}


## Project world markers through doc 11's camera and clamp them into the rect.
## `markers`: `[{id, position: Vector3, tier: int}]`.
func project_markers(camera: CameraState, markers: Array, viewport_dp: Vector2,
		drawer_w_dp: float = 0.0, drawer_open: bool = false) -> Array[Dictionary]:
	var rect := marker_rect(viewport_dp, drawer_w_dp, drawer_open)
	var out: Array[Dictionary] = []
	for raw: Variant in markers:
		var marker: Dictionary = raw
		var world: Vector3 = marker.get("position", Vector3.ZERO)
		var projected := camera.project_to_screen(world, viewport_dp)
		var screen: Vector2 = projected["position"]
		if bool(projected["behind"]):
			# Behind the camera plane the projection is meaningless: fall back to
			# the ground-plane bearing so the edge arrow still points correctly.
			var rel := world - camera.focus
			var bearing := Vector2(rel.dot(camera.ground_right()),
					-rel.dot(camera.ground_forward()))
			if bearing.length() < 0.0001:
				bearing = Vector2(0.0, 1.0)
			screen = rect.get_center() + bearing.normalized() * (viewport_dp.length() + 1.0)
		var clamped := clamp_marker(screen, rect)
		out.append({
			"id": str(marker.get("id", "")),
			"tier": int(marker.get("tier", 1)),
			"position": clamped["position"],
			"raw_position": screen,
			"offscreen": bool(clamped["offscreen"]),
			"direction": clamped["direction"],
			"world": world,
		})
	return out


## "Two pins within 40 dp cluster into a badge showing count + worst tier digit"
## (§2.15). Deterministic: seeds are taken worst-tier first, then by id, so the
## same input always yields the same clusters.
func cluster_markers(screen_markers: Array, cluster_dp: float = -1.0) -> Array[Dictionary]:
	var radius := cluster_dp if cluster_dp >= 0.0 else marker_cluster_dp()
	var pending: Array = screen_markers.duplicate()
	pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ta := int(a.get("tier", 0))
		var tb := int(b.get("tier", 0))
		if ta != tb:
			return ta > tb
		return str(a.get("id", "")) < str(b.get("id", "")))
	var taken: Dictionary = {}
	var clusters: Array[Dictionary] = []
	for i in pending.size():
		if taken.has(i):
			continue
		var seed_marker: Dictionary = pending[i]
		var seed_pos: Vector2 = seed_marker.get("position", Vector2.ZERO)
		var ids: Array[String] = [str(seed_marker.get("id", ""))]
		var sum_pos := seed_pos
		var worst := int(seed_marker.get("tier", 0))
		var offscreen := bool(seed_marker.get("offscreen", false))
		taken[i] = true
		for j in range(i + 1, pending.size()):
			if taken.has(j):
				continue
			var other: Dictionary = pending[j]
			var other_pos: Vector2 = other.get("position", Vector2.ZERO)
			if seed_pos.distance_to(other_pos) > radius:
				continue
			taken[j] = true
			ids.append(str(other.get("id", "")))
			sum_pos += other_pos
			worst = maxi(worst, int(other.get("tier", 0)))
			offscreen = offscreen or bool(other.get("offscreen", false))
		clusters.append({
			"position": sum_pos / float(ids.size()),
			"anchor": seed_pos,
			"count": ids.size(),
			"worst_tier": worst,
			"ids": ids,
			"clustered": ids.size() > 1,
			"offscreen": offscreen,
		})
	return clusters

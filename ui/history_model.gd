class_name HistoryModel
extends RefCounted
## The city dashboard's memory (doc 12 §2.10): a fixed-size ring of hourly
## samples, so the Overview sparklines and the Economy tab's 7-day treasury
## chart are drawn from numbers the UI already has rather than from a query the
## sim would have to answer per frame.
##
## One sample per **settled game-hour**, pushed by the shell. The ring is
## `dashboard.history_capacity` deep (168 = 7 game-days, which is exactly what
## §2.10's "7-day treasury chart" needs) and it never grows: the 169th sample
## overwrites the first, allocation-free after the first lap.
##
## Deliberately **not persisted**. Doc 12 §3.2 fixes the `ui` save section and
## report 98 §E2 makes save identity exact and sacred; a chart is a convenience,
## not city state, so a loaded save starts its history empty and fills it in as
## the city runs rather than changing what a save file contains.
##
## Chart geometry lives here too — `normalized()` returns points in the unit
## square, so the line-fitting is headless and `ui/line_chart.gd` only has to
## multiply by its own rect.

const DEFAULT_CAPACITY := 168

## The five series doc 12 §2.10's Overview names, plus the two service fractions
## the chips read. A sample may carry any subset; a series with no samples is
## simply not drawn (never drawn as zero — a hole is not a value).
const DEFAULT_SERIES: Array[String] = ["population", "treasury", "net_per_hour",
		"happiness", "stability", "power01", "water01"]

var capacity: int = DEFAULT_CAPACITY

var _series: Array[String] = []
var _values: Dictionary = {}      # series -> Array[float], parallel ring
var _present: Dictionary = {}     # series -> Array[bool], "the sim said so"
var _stamps: Array[int] = []      # game-hour index of each slot
var _head := 0                    # next write slot
var _count := 0


func _init(cfg: UIConfig = null, series: Array[String] = []) -> void:
	var block: Dictionary = cfg.section("dashboard") if cfg != null else {}
	capacity = maxi(1, UIConfig.get_int(block, "history_capacity", DEFAULT_CAPACITY))
	_series = series.duplicate() if not series.is_empty() else _series_from(block)
	for key: String in _series:
		var column: Array[float] = []
		var flags: Array[bool] = []
		column.resize(capacity)
		flags.resize(capacity)
		_values[key] = column
		_present[key] = flags
	_stamps.resize(capacity)


static func _series_from(block: Dictionary) -> Array[String]:
	var raw: Variant = block.get("series", [])
	if not (raw is Array) or (raw as Array).is_empty():
		return DEFAULT_SERIES.duplicate()
	var out: Array[String] = []
	for value: Variant in (raw as Array):
		out.append(str(value))
	return out


static func load_from_files() -> HistoryModel:
	return HistoryModel.new(UIConfig.load_from_files())


func series_names() -> Array[String]:
	return _series.duplicate()


func has_series(key: String) -> bool:
	return _values.has(key)


# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

## One settled hour. `row` may carry any subset of the series plus an optional
## `hour` stamp (doc 01's absolute game-hour); a key it omits records as absent
## for that slot rather than as zero.
func sample(row: Dictionary) -> void:
	var slot := _head
	for key: String in _series:
		var column: Array[float] = _values[key]
		var flags: Array[bool] = _present[key]
		var has := row.has(key)
		column[slot] = float(row[key]) if has else 0.0
		flags[slot] = has
	_stamps[slot] = int(row.get("hour", _count))
	_head = (_head + 1) % capacity
	_count = mini(_count + 1, capacity)


func clear() -> void:
	for key: String in _series:
		var column: Array[float] = _values[key]
		var flags: Array[bool] = _present[key]
		for i in capacity:
			column[i] = 0.0
			flags[i] = false
	_head = 0
	_count = 0


# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

func size() -> int:
	return _count


func is_full() -> bool:
	return _count >= capacity


## Oldest first, newest last — the order a chart draws left to right. `limit`
## takes the newest `limit` samples (`<= 0` means everything). Slots the series
## was absent from are skipped, so a series that started late has a short line
## rather than a cliff from zero.
func series(key: String, limit: int = 0) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if not _values.has(key) or _count <= 0:
		return out
	var column: Array[float] = _values[key]
	var flags: Array[bool] = _present[key]
	var wanted := _count if limit <= 0 else mini(limit, _count)
	var first := _count - wanted
	for i in range(first, _count):
		var slot := (_head - _count + i + capacity * 2) % capacity
		if not flags[slot]:
			continue
		out.append(column[slot])
	return out


## The game-hour stamps matching `series()`'s slots, for a chart that labels its
## x axis. Absent-series slots are not filtered out here — this is the ring's own
## clock, not one series' — so callers pair it with `size()`, not with a series.
func stamps(limit: int = 0) -> PackedInt32Array:
	var out := PackedInt32Array()
	var wanted := _count if limit <= 0 else mini(limit, _count)
	for i in range(_count - wanted, _count):
		out.append(_stamps[(_head - _count + i + capacity * 2) % capacity])
	return out


func latest(key: String, fallback: float = 0.0) -> float:
	var values := series(key, 1)
	return values[0] if not values.is_empty() else fallback


func oldest(key: String, limit: int = 0, fallback: float = 0.0) -> float:
	var values := series(key, limit)
	return values[0] if not values.is_empty() else fallback


## `[min, max]` over the newest `limit` samples. Returns `Vector2.ZERO` for an
## empty series, which callers distinguish with `series(...).is_empty()`.
func range_of(key: String, limit: int = 0) -> Vector2:
	var values := series(key, limit)
	if values.is_empty():
		return Vector2.ZERO
	var low := values[0]
	var high := values[0]
	for value: float in values:
		low = minf(low, value)
		high = maxf(high, value)
	return Vector2(low, high)


## The chart's whole geometry, headless: points in the unit square with `y = 0`
## at the series minimum and `y = 1` at its maximum, plus the real range so the
## view can label the axis. A flat series draws down the middle rather than
## dividing by a zero span.
##
## Returns `{points: PackedVector2Array, min: float, max: float, count: int,
## first: float, last: float, delta: float}`; `count == 0` means "no line".
func normalized(key: String, limit: int = 0) -> Dictionary:
	var values := series(key, limit)
	var points := PackedVector2Array()
	if values.is_empty():
		return {"points": points, "min": 0.0, "max": 0.0, "count": 0,
				"first": 0.0, "last": 0.0, "delta": 0.0}
	var bounds := range_of(key, limit)
	var span := bounds.y - bounds.x
	var n := values.size()
	for i in n:
		var x := 0.5 if n == 1 else float(i) / float(n - 1)
		var y := 0.5 if absf(span) < 0.0000001 else (values[i] - bounds.x) / span
		points.append(Vector2(x, y))
	return {
		"points": points,
		"min": bounds.x,
		"max": bounds.y,
		"count": n,
		"first": values[0],
		"last": values[n - 1],
		"delta": values[n - 1] - values[0],
	}

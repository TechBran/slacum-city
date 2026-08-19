class_name StormCell
extends RefCounted
## The one spatial weather object in the game (doc 07 §2.3, report 98 C-59).
## Weather STATE is city-wide global; the thunderstorm cell affects exactly two
## things — lightning target eligibility (§2.7.3) and flood accumulation (§2.4).
## It never modulates an effect channel, so no boundary popping exists.
##
## Advection is deliberately decoupled from `wind_kph` (§9 item 4): a 72 kph
## storm would cross a 240-tile city in ~2.7 game-minutes and be useless as a
## gameplay object. 1.6–3.2 tiles/game-minute gives a 75–150 minute traverse.

var active: bool = false
var x_t: float = 0.0
var z_t: float = 0.0
var radius_t: float = 48.0
var heading_deg: float = 0.0
var speed_tpm: float = 2.0
var travelled_t: float = 0.0
var _entry_distance_t: float = 0.0


## `center` and `city_radius_tiles` come from doc 09's map bounds.
##
## The heading and speed draws are seeded from the SEGMENT ID rather than taken
## off the shared `weather` stream. That is a deliberate determinism call: the
## coarse 1-game-hour path can step straight over a short segment the fine path
## visited, so any stream consumption tied to *visiting* a segment would desync
## the two timelines. Hashing the segment id makes the cell a pure function of
## the committed timeline, which is what coarse/fine parity requires
## (constitution §4) — and the timeline itself is still rolled on the named
## `weather` stream, so nothing about the weather sequence becomes less random.
func spawn(center: Vector2, city_radius_tiles: float, tables: WeatherTables,
		seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var config: Dictionary = tables.storm_cell
	var speed_band: Array = config.get("speed_tiles_per_min", [1.6, 3.2])
	radius_t = maxf(float(config.get("radius_min_tiles", 48.0)),
			float(config.get("radius_frac_of_city", 0.6)) * city_radius_tiles)
	heading_deg = rng.randf_range(0.0, 360.0)
	speed_tpm = rng.randf_range(float(speed_band[0]), float(speed_band[1]))
	var unit := heading_unit()
	_entry_distance_t = city_radius_tiles + radius_t
	var spawn_pos := center - unit * _entry_distance_t
	x_t = spawn_pos.x
	z_t = spawn_pos.y
	travelled_t = 0.0
	active = true


func heading_unit() -> Vector2:
	var radians := deg_to_rad(heading_deg)
	return Vector2(cos(radians), sin(radians))


func center() -> Vector2:
	return Vector2(x_t, z_t)


func advance(dt_min: float) -> void:
	if not active:
		return
	var step := speed_tpm * dt_min
	var unit := heading_unit()
	x_t += unit.x * step
	z_t += unit.y * step
	travelled_t += step


## Game-minutes until the cell centre reaches the point it was aimed at.
func minutes_to_center() -> float:
	if not active or speed_tpm <= 0.0:
		return 0.0
	return (_entry_distance_t - travelled_t) / speed_tpm


func contains(pos: Vector2) -> bool:
	return active and pos.distance_to(center()) <= radius_t


func despawn() -> void:
	active = false
	travelled_t = 0.0


func serialize() -> Dictionary:
	return {
		"active": active, "x_t": x_t, "z_t": z_t, "radius_t": radius_t,
		"heading_deg": heading_deg, "speed_tpm": speed_tpm,
		"travelled_t": travelled_t, "entry_distance_t": _entry_distance_t,
	}


func deserialize(data: Dictionary) -> void:
	active = bool(data.get("active", false))
	x_t = float(data.get("x_t", 0.0))
	z_t = float(data.get("z_t", 0.0))
	radius_t = float(data.get("radius_t", 48.0))
	heading_deg = float(data.get("heading_deg", 0.0))
	speed_tpm = float(data.get("speed_tpm", 2.0))
	travelled_t = float(data.get("travelled_t", 0.0))
	_entry_distance_t = float(data.get("entry_distance_t", 0.0))

class_name LandBlock
extends RefCounted
## One 16×16-tile land block record (doc 09 §2.2). Authored attributes plus
## ownership/development state; derived quantities are computed, never stored.

const OWNERSHIP := [&"LOCKED", &"PURCHASABLE", &"OWNED"]
const DEV_PHASES := [
	&"UNDEVELOPED", &"SURVEY", &"CLEARING", &"GRADING",
	&"ROAD_INSTALL", &"UTILITY_CORRIDOR", &"FINAL_DEVELOPMENT", &"READY",
]
const ELEVATION_M := [0, 5, 12, 22, 34]
const ROAD_ACCESS_SCORE := {&"NONE": 0.00, &"STUB": 0.35, &"EDGE": 0.70, &"ARTERIAL": 1.00}

var id: String = ""
var grid := Vector2i.ZERO  # block coords (bx, bz)
var label: String = ""  # player-facing, e.g. "D2"
var terrain_class: StringName = &"flat"
var dev_terrain: StringName = &"flat"
var elevation_class: int = 0
var flood_risk: float = 0.0
var env_risk: Dictionary = {}  # {flood, wildfire, subsidence, pollution, wind, hazmat}
var road_access: StringName = &"NONE"
var arterial_connections: int = 0
var water_tiles: int = 0
var blocked_tiles: int = 0
var waterfront_edges: int = 0
var amenity_score: float = 0.0
var vegetation_density: float = 0.0
var slope_index: float = 0.0
var min_city_level: int = 0
var ownership_state: StringName = &"LOCKED"
var development_state: StringName = &"UNDEVELOPED"
var district_id: String = ""
var tags: Array = []
var survey_revealed: bool = false
var purchase_price: int = 0
var purchased_minute: int = 0
var phase_crew_minutes_remaining: int = 0
## Doc 03 §2.8b — every dollar of VALUE this block's excavation has handed
## back, cash and yard material together, for the life of the block. Persisted
## because it is the clamp: `CitySim._credit_land_works` caps the cumulative
## yield at `EconomySystem.works_yield_ceiling`, and a counter that reset on
## load would let a save/reload pay the ceiling twice. The land panel reads it
## as `Recovered so far` (doc 12 §2.8 D-117).
var works_yield_total: int = 0


func usable_tiles() -> int:
	return 256 - water_tiles - blocked_tiles


func road_tiles_est() -> int:
	return roundi(0.34 * usable_tiles())


func buildable_tiles_est() -> int:
	return usable_tiles() - road_tiles_est()


func env_risk_index() -> float:
	return 0.35 * float(env_risk.get("flood", 0.0)) \
			+ 0.15 * float(env_risk.get("wildfire", 0.0)) \
			+ 0.15 * float(env_risk.get("subsidence", 0.0)) \
			+ 0.20 * float(env_risk.get("pollution", 0.0)) \
			+ 0.10 * float(env_risk.get("wind", 0.0)) \
			+ 0.05 * float(env_risk.get("hazmat", 0.0))


func block_road_access_score() -> float:
	return float(ROAD_ACCESS_SCORE.get(road_access, 0.0))


func elevation_m() -> int:
	return ELEVATION_M[elevation_class]


func elevation_band() -> StringName:
	if elevation_class <= 1:
		return &"LOW"
	if elevation_class == 2:
		return &"MID"
	return &"HIGH"


func drain_rate_mm_h() -> float:
	return 25.0 * (1.0 - 0.80 * flood_risk) * (1.0 + 0.50 * float(elevation_class) / 4.0)


func land_value_index(district_stability: float) -> float:
	if development_state != &"READY":
		return 0.0
	return clampf(0.25 + 0.30 * amenity_score + 0.25 * (1.0 - env_risk_index())
			+ 0.20 * district_stability, 0.0, 1.0)


func is_owned() -> bool:
	return ownership_state == &"OWNED"


func is_ready() -> bool:
	return development_state == &"READY"


static func from_dict(data: Dictionary) -> LandBlock:
	var block := LandBlock.new()
	block.id = String(data.get("id", ""))
	var g: Array = data.get("grid", [0, 0])
	block.grid = Vector2i(int(g[0]), int(g[1]))
	block.label = String(data.get("label", ""))
	block.terrain_class = StringName(String(data.get("terrain_class", "flat")))
	block.dev_terrain = StringName(String(data.get("dev_terrain", "flat")))
	block.elevation_class = int(data.get("elevation_class", 0))
	block.flood_risk = float(data.get("flood_risk", 0.0))
	block.env_risk = data.get("env_risk", {})
	block.road_access = StringName(String(data.get("road_access", "NONE")))
	block.arterial_connections = int(data.get("arterial_connections", 0))
	block.water_tiles = int(data.get("water_tiles", 0))
	block.blocked_tiles = int(data.get("blocked_tiles", 0))
	block.waterfront_edges = int(data.get("waterfront_edges", 0))
	block.amenity_score = float(data.get("amenity_score", 0.0))
	block.vegetation_density = float(data.get("vegetation_density", 0.0))
	block.slope_index = float(data.get("slope_index", 0.0))
	block.min_city_level = int(data.get("min_city_level", 0))
	block.ownership_state = StringName(String(data.get("ownership_state", "LOCKED")))
	block.development_state = StringName(String(data.get("development_state", "UNDEVELOPED")))
	block.district_id = String(data.get("district_id", "") if data.get("district_id") != null else "")
	block.tags = data.get("tags", [])
	return block


func serialize() -> Dictionary:
	return {
		"id": id,
		"ownership_state": String(ownership_state),
		"development_state": String(development_state),
		"phase_crew_minutes_remaining": phase_crew_minutes_remaining,
		"purchase_price": purchase_price,
		"purchased_minute": purchased_minute,
		"road_access": String(road_access),
		"arterial_connections": arterial_connections,
		"survey_revealed": survey_revealed,
		"works_yield_total": works_yield_total,
		"district_id": district_id,
	}


func apply_save(data: Dictionary) -> void:
	ownership_state = StringName(String(data.get("ownership_state", String(ownership_state))))
	development_state = StringName(String(data.get("development_state", String(development_state))))
	phase_crew_minutes_remaining = int(data.get("phase_crew_minutes_remaining", 0))
	purchase_price = int(data.get("purchase_price", 0))
	purchased_minute = int(data.get("purchased_minute", 0))
	road_access = StringName(String(data.get("road_access", String(road_access))))
	arterial_connections = int(data.get("arterial_connections", arterial_connections))
	survey_revealed = bool(data.get("survey_revealed", false))
	# Absent on every save written before Wave 25, and 0 is the honest reading
	# there: those blocks were dug out before anyone was counting, so the
	# ceiling starts fresh rather than retro-charging a city for money it was
	# never paid.
	works_yield_total = int(data.get("works_yield_total", 0))
	district_id = String(data.get("district_id", district_id))

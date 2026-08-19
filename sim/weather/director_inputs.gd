class_name DirectorInputs
extends RefCounted
## The Director's read-only view of the city (doc 07 §2.6.1). Every field is
## OWNED elsewhere and read here — the Director writes back nothing except
## incident requests and, through doc 09's API, district stability deltas.
##
##   city_age_days, season_index      doc 01
##   population, pop_peak_7d,
##   city_stability, districts        doc 09
##   treasury, daily_opex, difficulty doc 03
##   grid_redundancy, customers_out   doc 04
##   water_redundancy                 doc 05
##   road_redundancy, roads_impassable doc 10
##   units_owned, active_incidents,
##   unresolved_major_incidents       doc 06

var city_age_days: int = 0
var season_index: int = 0
var population: int = 0
var pop_peak_7d: int = 0
var treasury: int = 0
var daily_opex: int = 1
var grid_redundancy: float = 0.0
var water_redundancy: float = 0.0
var road_redundancy: float = 0.0
var units_owned: Dictionary = {}  # department -> int
var total_response_units: int = 0
var city_stability: float = 1.0
var active_incidents: int = 0
var unresolved_major_incidents: int = 0
var customers_out_pct: float = 0.0
var roads_impassable_pct: float = 0.0
var difficulty: String = "standard"


static func make(fields: Dictionary) -> DirectorInputs:
	var inputs := DirectorInputs.new()
	for key in fields:
		inputs.set(String(key), fields[key])
	if inputs.total_response_units == 0:
		var total := 0
		for department in inputs.units_owned:
			total += int(inputs.units_owned[department])
		inputs.total_response_units = total
	return inputs

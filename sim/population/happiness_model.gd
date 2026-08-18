class_name HappinessModel
extends RefCounted
## City happiness H ∈ [0,100] (doc 09 §2.10.3). Slow and city-wide where
## stability is fast and per-district. Never spikes — it erodes and recovers
## on a 12 game-hour time constant.

const HAPPINESS_TAU_H: float = 12.0
const BASELINE: float = 60.0

var happiness: float = 82.0  # authored t0 value (doc 09 §3.1)


static func _u(x: float) -> float:
	return clampf(x, -1.0, 1.0)


static func target(city_stability: float, service_uptime_day: float,
		employment_balance: float, condition_mean: float,
		happiness_tax_delta: float) -> float:
	var t := BASELINE \
			+ 14.0 * _u((city_stability - 0.85) / 0.15) \
			+ 8.0 * _u((service_uptime_day - 0.97) / 0.03) \
			+ 8.0 * _u((employment_balance - 0.85) / 0.15) \
			+ 6.0 * _u((condition_mean - 0.85) / 0.15) \
			+ happiness_tax_delta
	return clampf(t, 0.0, 100.0)


func advance(dt_h: float, city_stability: float, service_uptime_day: float,
		employment_balance: float, condition_mean: float,
		happiness_tax_delta: float) -> float:
	var h_target := target(city_stability, service_uptime_day, employment_balance,
			condition_mean, happiness_tax_delta)
	happiness += (h_target - happiness) * (1.0 - exp(-dt_h / HAPPINESS_TAU_H))
	return happiness


## Doc 03's revenue multiplier.
func f_happiness() -> float:
	return clampf(1.0 + 0.50 * (happiness - BASELINE) / 100.0, 0.75, 1.25)


func serialize() -> Dictionary:
	return {"happiness": happiness}


func deserialize(data: Dictionary) -> void:
	happiness = float(data.get("happiness", 82.0))

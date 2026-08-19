class_name LightningTargeter
extends RefCounted
## Lightning target selection (doc 07 §2.7.3). This doc owns strike GENERATION
## and TARGET SELECTION — it is the only system that can see the storm cell,
## the asset roster and F4 target immunity at once — and nothing else
## (report 98 C-54). It emits `LightningStrike{target_ref, energy, event_uid,
## condition_floor}`; the owning doc resolves the damage.
##
##   w = base_type_weight · height_factor · condition_factor · exposure_factor
##       · protection_factor · immunity_factor · cell_factor
##
## F4 and F10 are FILTERS applied before weighting, never weights.
##
## Target descriptor (whatever supplies the roster fills this in):
##   {ref: String, weight_class: String, height_m: float, condition: float,
##    exposure: "outdoor"|"rooftop_shielded"|"underground",
##    protections: Array[String], pos: Vector2, f10_protected: bool}

var config: Dictionary  # data/director.json → storm.lightning


func _init(lightning_config: Dictionary) -> void:
	config = lightning_config


func base_type_weight(weight_class: String) -> float:
	return float(config.get("base_type_weight", {}).get(weight_class, 0.3))


func height_factor(height_m: float) -> float:
	return 1.0 + height_m / float(config.get("height_divisor_m", 40.0))


func condition_factor(condition: float) -> float:
	return 1.0 + float(config.get("condition_slope", 1.5)) * (1.0 - clampf(condition, 0.0, 1.0))


func exposure_factor(exposure: String) -> float:
	return float(config.get("exposure_factor", {}).get(exposure, 1.0))


## Product of every protection the asset carries, floored (§2.7.3).
func protection_factor(protections: Array) -> float:
	var table: Dictionary = config.get("protection_factor", {})
	var product := 1.0
	for name in protections:
		product *= float(table.get(String(name), 1.0))
	return maxf(product, float(table.get("floor", 0.2)))


## F4 (§2.6.4). `struck` is this storm's struck set — already-hit components are
## hard-excluded for the rest of the storm.
static func immunity_factor(ref: String, now_min: int, struck: Dictionary,
		hard_until: Dictionary, immune_until: Dictionary,
		immune_weight_mult: float = 0.15) -> float:
	if struck.has(ref):
		return 0.0
	if now_min < int(hard_until.get(ref, -1)):
		return 0.0
	if now_min < int(immune_until.get(ref, -1)):
		return immune_weight_mult
	return 1.0


## The full §2.7.3 weight for one target. `cell` may be null (no spatial gate).
func weight_for(target: Dictionary, cell: StormCell, now_min: int, struck: Dictionary,
		hard_until: Dictionary, immune_until: Dictionary,
		immune_weight_mult: float = 0.15) -> float:
	var cell_factor := 1.0
	if cell != null and cell.active:
		cell_factor = 1.0 if cell.contains(target.get("pos", Vector2.ZERO)) else 0.0
	return base_type_weight(String(target.get("weight_class", "building_generic"))) \
			* height_factor(float(target.get("height_m", 8.0))) \
			* condition_factor(float(target.get("condition", 1.0))) \
			* exposure_factor(String(target.get("exposure", "outdoor"))) \
			* protection_factor(target.get("protections", [])) \
			* immunity_factor(String(target.get("ref", "")), now_min, struck,
					hard_until, immune_until, immune_weight_mult) \
			* cell_factor


## Weights for the whole roster, in roster order. Roster order is the caller's
## responsibility to make deterministic (sort by ref).
func weights(targets: Array, cell: StormCell, now_min: int, struck: Dictionary,
		hard_until: Dictionary, immune_until: Dictionary,
		immune_weight_mult: float = 0.15) -> Array:
	var out: Array = []
	for target in targets:
		out.append(weight_for(target, cell, now_min, struck, hard_until, immune_until,
				immune_weight_mult))
	return out


## Weighted pick. Returns {} when every legal weight is zero — the caller then
## treats the attempt as a ground strike rather than forcing a hit.
func select(targets: Array, cell: StormCell, now_min: int, struck: Dictionary,
		hard_until: Dictionary, immune_until: Dictionary, u: float,
		immune_weight_mult: float = 0.15) -> Dictionary:
	var w := weights(targets, cell, now_min, struck, hard_until, immune_until,
			immune_weight_mult)
	var total := 0.0
	for value in w:
		total += float(value)
	if total <= 0.0:
		return {}
	var threshold := u * total
	var cumulative := 0.0
	for i in targets.size():
		cumulative += float(w[i])
		if threshold < cumulative:
			return targets[i]
	return targets[targets.size() - 1]


## `energy` is the one number this system hands the resolver. Doc 04's
## energy_scale_min/max are exactly these bounds, so the two agree by
## construction (§2.7.3).
func roll_energy(u: float) -> float:
	var band: Array = config.get("energy_range", [0.6, 1.6])
	return lerpf(float(band[0]), float(band[1]), clampf(u, 0.0, 1.0))

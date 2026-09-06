class_name ShapeCatalog
extends RefCounted
## The render's **(archetype, variant) → SHAPE** map, read once out of the
## gray-box manifest (doc 11 §2.14 / §3.3, Wave 31 RR-254).
##
## **The defect this exists to make impossible.** `game/meshes/generated/manifest.json`
## is keyed `archetype:level:lod` and carries exactly one `footprint_tiles` per
## archetype-level. For `water_facility` that key is doc 02's own row and doc 02
## says out loud what it is — `footprints_are_reference_variant_only`, the PUMP,
## 3×3 flat to L4. Doc 05 §6's other placeable shells are not pumps: a
## `treatment` plant is 2×2 at L1 and a `tank` is 2×2 to L2, and
## `CitySim.built_of_building` builds them on exactly that ground. So the
## renderer drew a tank with the pump's 3×3 shell centred on the tank's 2×2
## footprint — **4 m of building over every edge of its own lot**, which beside a
## street is a building standing in the road. That is the player's report of
## 2026-09-06 and it has been true of `WTR-2`, the founding city's own tank,
## since the founding city was authored.
##
## A SHAPE is therefore the unit the render keys on, not an archetype: it is the
## archetype for everything doc 02 owns outright, and `water_facility_tank` /
## `_treatment` / `_source` for the three doc-05 variants that have their own
## massing. `pump` keeps the id `water_facility` because it IS doc 02's reference
## variant — every one of its committed mesh hashes is unchanged by this pass.
##
## **Nothing here is authored.** The map is inverted from the manifest rows'
## `variant_of` / `variant` fields, which `tools/gen_graybox.gd` copies from
## `data/building_shapes.json`, which `tools/gen_building_shapes.py` checks
## against `data/water.json`'s own footprint columns before it will write. A
## variant that gains a shape is picked up by a regeneration and by nothing else.
##
## **A variant with no shape is not a hole.** `shape_of` answers the plain
## archetype for it, and `RenderStateModel` then SCALES that mesh into the built
## footprint (`footprint_of` is what it divides by), so the worst a future
## variant can look is squashed — never overhanging. `booster` is the live case:
## doc 05 §6 defers it, it is in no `placeable` roster, and it has no mesh.

const MANIFEST_PATH := "res://game/meshes/generated/manifest.json"

## `"archetype/variant"` → shape id, for every row that declares a variant.
var _shape_by_variant: Dictionary = {}
## shape id → the doc-02 archetype it belongs to (itself, for a plain archetype).
## This is what picks the TEXTURE PAGES: a tank wears the waterworks' utility
## facade because it is a water facility, not because it is a tank.
var _base_of: Dictionary = {}
## `"shape:level"` → Vector2i footprint in tiles, off the LOD0 row.
var _footprint: Dictionary = {}

static var _shared: ShapeCatalog = null


## The process-wide catalogue, built on first ask. Every reader wants the same
## answer from the same file, and the file is generated — there is nothing to
## configure and nothing to invalidate short of a rebuild.
static func shared() -> ShapeCatalog:
	if _shared == null:
		_shared = ShapeCatalog.new()
		_shared.read(StarterCityLoader.read_json(MANIFEST_PATH))
	return _shared


## Tests and harnesses that want a catalogue over a manifest of their own.
static func from_manifest(manifest: Dictionary) -> ShapeCatalog:
	var out := ShapeCatalog.new()
	out.read(manifest)
	return out


func read(manifest: Dictionary) -> void:
	_shape_by_variant.clear()
	_base_of.clear()
	_footprint.clear()
	for entry_v in manifest.get("meshes", []) as Array:
		var entry: Dictionary = entry_v
		var shape := String(entry.get("archetype", ""))
		if shape == "":
			continue
		var base := String(entry.get("variant_of", ""))
		if base == "":
			base = shape
		_base_of[shape] = base
		var variant := String(entry.get("variant", ""))
		if variant != "":
			_shape_by_variant["%s/%s" % [base, variant]] = shape
		if int(entry.get("lod", 0)) != 0:
			continue
		var foot: Array = entry.get("footprint_tiles", [1, 1])
		if foot.size() >= 2:
			_footprint["%s:%d" % [shape, int(entry.get("level", 1))]] = \
					Vector2i(int(foot[0]), int(foot[1]))


## The shape one building draws with. `variant` is `Building.variant`, empty for
## everything that has none; a variant with no shape of its own falls back to its
## archetype, which is the case the footprint scale then has to rescue.
func shape_of(archetype: StringName, variant: StringName = &"") -> StringName:
	if variant == &"":
		return archetype
	var found: Variant = _shape_by_variant.get("%s/%s" % [archetype, variant])
	if found == null:
		return archetype
	return StringName(found)


## The doc-02 archetype a shape belongs to — the key the texture manifest's
## `archetype_surface` table is written against.
func base_archetype_of(shape: StringName) -> StringName:
	return StringName(_base_of.get(String(shape), String(shape)))


## The MESH's own footprint at this level, in tiles. `Vector2i.ZERO` when the
## shape has no LOD0 row at that level, which is how a caller tells "no mesh"
## apart from "a 1×1 mesh".
func footprint_of(shape: StringName, level: int) -> Vector2i:
	return _footprint.get("%s:%d" % [shape, level], Vector2i.ZERO)


## Does this (archetype, variant) draw with a shape of its OWN? False means it is
## borrowing its archetype's mesh and depends on the footprint scale not to
## overhang.
func has_own_shape(archetype: StringName, variant: StringName) -> bool:
	return variant != &"" and _shape_by_variant.has("%s/%s" % [archetype, variant])

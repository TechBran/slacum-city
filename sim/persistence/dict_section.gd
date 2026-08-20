class_name DictSection
extends SaveSection
## A `SaveSection` whose body is a plain Dictionary supplied from outside.
##
## Doc 08 §3.1's registry has twenty owners, each implementing the contract on
## its own state. Milestone 1 does not have those twenty yet — `CitySim` ships
## ONE `capture_state()` — so the shell needs a way to put a body it already
## holds into the registry without inventing a fake system for it. That is all
## this is: the section contract, backed by a payload someone else owns.
##
## It is deliberately NOT a shortcut around the contract. `section_version` is
## real and per-key, and [migrator] is the hook a system fills in as it splits
## out: the day `city` becomes `buildings` + `power` + `water`, each new section
## registers itself and this adapter loses one key, with no change to either
## the manager above it or the shell beside it.

## Key this section occupies in the save body (doc 08 §3.1).
var key: StringName
## This section's own ladder position (doc 08 §2.8 — independent of the
## envelope's `schema_version`).
var version: int = 1
## What `serialize()` hands the manager. The owner writes it before a save.
var payload: Dictionary = {}
## What `deserialize()` received, already migrated to [version].
var restored: Dictionary = {}
## Optional `func(data: Dictionary) -> Dictionary` run by `commit_save()` on the
## WRITE thread — see `SaveSection.finalize` for the two rules it must obey. The
## city section installs `CitySim.encode_captured` here, which is what takes the
## float canonicalisation off the frame.
var finalizer: Callable = Callable()
## Optional `func(data: Dictionary, from_version: int) -> Dictionary`. Doc 08
## §2.8's rules apply to whatever is installed here: TOTAL (may not fail —
## missing input means a documented default), additive-first, and it must never
## read `data/`. Unset means the section has no ladder yet, which is the honest
## state for a version-1 section.
var migrator: Callable = Callable()
## Defaults used when the section is missing from a loaded body and
## `validate_structural()` repairs it.
var defaults: Dictionary = {}


func _init(p_key: StringName = &"", p_version: int = 1) -> void:
	key = p_key
	version = p_version


func section_key() -> StringName:
	return key


func section_version() -> int:
	return version


## Shallow copy on purpose: the manager stamps `section_version` into whatever
## it gets back, and it may not stamp it into the owner's live dictionary. A
## DEEP copy would mean duplicating a whole city body on every autosave, which
## is exactly the 25 ms budget doc 08 §2.6 is trying to protect.
func serialize() -> Dictionary:
	return payload.duplicate()


func needs_finalize() -> bool:
	return finalizer.is_valid()


## A finalizer that returns something other than a Dictionary is treated as "no
## finalization happened", for the same reason [migrate_section] treats a broken
## migrator that way: a section's own bug may cost it its canonical form, but it
## may not cost the player the city.
func finalize(data: Dictionary) -> Dictionary:
	if not finalizer.is_valid():
		return data
	var out: Variant = finalizer.call(data)
	return out if out is Dictionary else data


func deserialize(data: Dictionary) -> void:
	restored = data


func default_section() -> Dictionary:
	var out := defaults.duplicate(true)
	out["section_version"] = version
	return out


func migrate_section(data: Dictionary, from_version: int) -> Dictionary:
	if not migrator.is_valid():
		return data
	var migrated: Variant = migrator.call(data, from_version)
	# Totality is the migrator's contract, but a broken one must not cost a
	# city: a non-Dictionary return is treated as "no migration happened", the
	# loader's structural gate then decides whether the body is usable.
	return migrated if migrated is Dictionary else data


## True when `restored` carries nothing but its own version stamp — the shape a
## section has when it was written empty or repaired from defaults. Callers use
## it to tell "the player has no UI state" from "the player has UI state that
## happens to be empty", which are different answers on a load screen.
func restored_is_empty() -> bool:
	return restored.size() <= 1 and (restored.is_empty() or restored.has("section_version"))

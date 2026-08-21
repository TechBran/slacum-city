class_name SaveSection
extends RefCounted
## Contract every persisted system implements (doc 08 §2.8, report 98 §11).
## Sections own their own `section_version` ladder; the envelope's
## `schema_version` covers only the registry shape between sections.


func section_key() -> StringName:
	push_error("SaveSection.section_key not implemented")
	return &""


func section_version() -> int:
	return 1


func serialize() -> Dictionary:
	push_error("SaveSection.serialize not implemented")
	return {}


## True when [finalize] does anything. Sections answer `false` by default, and a
## `false` answer costs `SaveManager.commit_save()` exactly one array append it
## never makes.
func needs_finalize() -> bool:
	return false


## THE SECOND HALF OF `serialize()`, AND THE HALF THAT NEED NOT RUN ON THE SIM'S
## THREAD (doc 08 §2.6, report 98 §24).
##
## `serialize()` reads live simulation state, so it runs where the sim runs and
## while nothing is ticking. Everything a section does to that snapshot AFTERWARDS
## — canonicalising it, re-shaping it, compressing a field — is a pure function of
## bytes the section already owns, and `SaveManager.commit_save()` runs it on the
## write thread instead.
##
## The split exists because it was measured: `CitySim`'s float canonicalisation is
## **36 ms of a 75 ms capture** on the 1,500-building benchmark city, and moving it
## here takes the frame's share of a save from 85 ms to 39 (best of 7,
## `tools/profile_save.gd --async`).
##
## Two rules, and a section that breaks either breaks a save:
##
##   1. **It may not touch the sim.** Not a read, not a counter. The thread it
##      runs on has no ordering relationship with the tick loop.
##   2. **It must be idempotent.** The manager does not know whether a caller
##      finalized before handing the payload over, and a `capture` that is
##      committed twice (a retried write) must not encode twice.
##
## Mutating `data` and returning it is expected — it is already a private copy.
func finalize(data: Dictionary) -> Dictionary:
	return data


## NOTE: data arrives JSON-typed — every number is a float (Godot's JSON
## parser). Implementations MUST cast (int(...)) on read; never compare or
## store raw JSON numbers as ints without casting.
func deserialize(_data: Dictionary) -> void:
	push_error("SaveSection.deserialize not implemented")


## Used by structural repair when a section is missing from a loaded body.
func default_section() -> Dictionary:
	return {"section_version": section_version()}


## Per-section migration ladder: total, additive-first, never reads data/.
func migrate_section(data: Dictionary, _from_version: int) -> Dictionary:
	return data

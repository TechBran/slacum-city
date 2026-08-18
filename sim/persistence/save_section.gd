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

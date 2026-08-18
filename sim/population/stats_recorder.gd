class_name StatsRecorder
extends RefCounted
## Lifetime counters (doc 09 §2.12, gap G-5). Local only — no network, no
## INTERNET permission. Monotone int64; peaks are maxima; counters migrate by
## appending at 0 and never renaming.

var counters: Dictionary = {}


func add(counter: String, amount: int = 1) -> void:
	counters[counter] = int(counters.get(counter, 0)) + amount


func record_peak(counter: String, value: int) -> void:
	counters[counter] = maxi(int(counters.get(counter, 0)), value)


func get_counter(counter: String) -> int:
	return int(counters.get(counter, 0))


func serialize() -> Dictionary:
	return {"section_version": 1, "counters": counters.duplicate()}


func deserialize(data: Dictionary) -> void:
	counters = {}
	for key in data.get("counters", {}):
		counters[key] = int(data["counters"][key])

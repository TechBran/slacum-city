class_name ScheduledEventService
extends RefCounted
## Scheduled events with phase timelines (doc 01 §2.8): one framework for
## hazard warnings, stadium events and Director-authored disasters. An event
## is a template plus an anchor tick; each phase becomes a deadline timer.
## Phase offsets are in game-minutes relative to the anchor and may be
## negative — that is what makes forecasting work (spec §20.3).
##
## While a phase is open its modifier deltas ride the channel stack under
## source (&"scheduled_event", "evt_<id>"); each phase's push replaces the
## previous phase's, and the final phase clears the source.

const TIMER_KIND := &"scheduled_event_phase"

var templates: Dictionary = {}  # template_id -> {phases: [{name, offset_minutes, notify, modifiers}]}
var timers: TimerService
var modifiers: ModifierStack
var next_event_id: int = 1
var _events_out: Array = []
var _active: Dictionary = {}  # event_id -> record


func _init(p_templates: Dictionary, p_timers: TimerService, p_modifiers: ModifierStack) -> void:
	templates = p_templates
	timers = p_timers
	modifiers = p_modifiers


func drain_events() -> Array:
	var out := _events_out
	_events_out = []
	return out


func active_count() -> int:
	return _active.size()


func event(event_id: int) -> Dictionary:
	return _active.get(event_id, {})


## Anchor selection belongs to the caller (venue / Director); this service
## guarantees a scheduled phase fires on exactly the tick requested.
func schedule(template_id: String, anchor_tick: int, params: Dictionary = {}) -> int:
	assert(templates.has(template_id), "unknown event template: " + template_id)
	var event_id := next_event_id
	next_event_id += 1
	var record := {
		"id": event_id, "template_id": template_id, "anchor_tick": anchor_tick,
		"open_phase": "", "fired_phases": [], "params": params,
	}
	_active[event_id] = record
	for phase in templates[template_id]["phases"]:
		var due_tick: int = anchor_tick + int(phase["offset_minutes"]) * GameClock.TICKS_PER_MINUTE
		timers.schedule(TIMER_KIND, &"events", due_tick,
				{"event_id": event_id, "phase": String(phase["name"])},
				String(phase.get("notify", "none")) != "none")
	_events_out.append({"type": &"event_scheduled", "event_id": event_id,
			"template_id": template_id, "anchor_tick": anchor_tick})
	return event_id


## Feed due timers (from TimerService.collect_due at P03). A phase whose
## due_tick fell inside a coarse hour fires at the start of that step and is
## reported with its true due_tick (doc 01 §2.8 anchoring rule).
func process_due(due_timers: Array) -> void:
	for timer in due_timers:
		if timer.get("kind", &"") != TIMER_KIND:
			continue
		var payload: Dictionary = timer["payload"]
		var event_id := int(payload["event_id"])
		if not _active.has(event_id):
			continue
		var record: Dictionary = _active[event_id]
		var phase_name := String(payload["phase"])
		var phase := _phase_of(String(record["template_id"]), phase_name)
		if String(record["open_phase"]) != "":
			_events_out.append({"type": &"event_phase_end", "event_id": event_id,
					"phase": record["open_phase"]})
		(record["fired_phases"] as Array).append(phase_name)
		record["open_phase"] = phase_name
		var mults: Dictionary = phase.get("modifiers", {})
		var source_id := "evt_%d" % event_id
		if mults.is_empty():
			modifiers.remove_source(&"scheduled_event", source_id)
		else:
			modifiers.push_source(&"scheduled_event", source_id, mults)
		_events_out.append({"type": &"event_phase_begin", "event_id": event_id,
				"phase": phase_name, "due_tick": timer["due_tick"],
				"notify": phase.get("notify", "none")})
		if _is_last_phase(String(record["template_id"]), phase_name):
			modifiers.remove_source(&"scheduled_event", source_id)
			_events_out.append({"type": &"event_completed", "event_id": event_id})
			_active.erase(event_id)


func cancel(event_id: int) -> bool:
	if not _active.has(event_id):
		return false
	modifiers.remove_source(&"scheduled_event", "evt_%d" % event_id)
	_active.erase(event_id)
	# Orphaned timers fire into a missing event id and are ignored.
	return true


func _phase_of(template_id: String, phase_name: String) -> Dictionary:
	for phase in templates[template_id]["phases"]:
		if String(phase["name"]) == phase_name:
			return phase
	return {}


func _is_last_phase(template_id: String, phase_name: String) -> bool:
	var phases: Array = templates[template_id]["phases"]
	return String((phases[phases.size() - 1] as Dictionary)["name"]) == phase_name


func serialize() -> Dictionary:
	var out: Array = []
	var ids := _active.keys()
	ids.sort()
	for event_id in ids:
		out.append((_active[event_id] as Dictionary).duplicate(true))
	return {"next_event_id": next_event_id, "scheduled_events": out}


func deserialize(data: Dictionary) -> void:
	next_event_id = int(data.get("next_event_id", 1))
	_active.clear()
	for record in data.get("scheduled_events", []):
		_active[int(record["id"])] = record

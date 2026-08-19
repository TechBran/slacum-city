class_name SaveSlotsModel
extends RefCounted
## The save/load screen's logic: the slot list, the confirmation gate and the
## copy for both — headless, so the destructive-action rules are tested without
## a scene tree and without touching the disk.
##
## The files themselves belong to `game/save_service.gd`, which this class talks
## to **duck-typed**: `save_slot(sim, slot) -> Dictionary`,
## `load_slot(sim, slot) -> bool`, `list_slots() -> Array[Dictionary]`,
## `delete_slot(slot) -> bool`, `autosave(sim) -> void`. Nothing here reads or
## writes a file, so the tests inject a stub and the real service is free to
## change how it stores things. `is_available()` is false until a service is
## bound, and the screen then says so in words (A14) instead of showing dead
## buttons.
##
## Slot meta is the service's shape — `{slot, saved_at_unix, day_index,
## population, treasury}` — and this class only formats it, through
## `HudModel`'s number formats so a treasury reads the same here as it does in
## the HUD chip.
##
## The confirmation rule is the point of the class: **every action that can
## destroy progress asks first.** Overwriting a used slot, loading over a live
## city and deleting all pass through `request()` → `confirm()`; saving into an
## empty slot does not, because nothing is lost.

const ACTION_SAVE := &"save"
const ACTION_LOAD := &"load"
const ACTION_DELETE := &"delete"

const REASON_OK := &"ok"
const REASON_UNAVAILABLE := &"unavailable"
const REASON_EMPTY_SLOT := &"empty_slot"
const REASON_UNKNOWN_SLOT := &"unknown_slot"
const REASON_FAILED := &"failed"

const _DEFAULT_SLOT_COUNT := 3

var _cfg: UIConfig
var _slots_cfg: Dictionary = {}
var _service: Object = null
var _sim: Object = null
var _meta: Dictionary = {}          # slot:int -> meta Dictionary
var _pending: Dictionary = {}


func _init(cfg: UIConfig = null) -> void:
	if cfg == null:
		return
	_cfg = cfg
	_slots_cfg = cfg.section("save_slots")


static func load_from_files() -> SaveSlotsModel:
	return SaveSlotsModel.new(UIConfig.load_from_files())


## `service` is `game/save_service.gd`; `sim` is the live `CitySim` it captures.
## Both stay `Object` on purpose — `ui/` never depends on either type.
func bind(service: Object, sim: Object = null) -> void:
	_service = service
	_sim = sim
	refresh()


func set_sim(sim: Object) -> void:
	_sim = sim


func is_available() -> bool:
	return _service != null and _service.has_method("list_slots")


func slot_count() -> int:
	return maxi(1, UIConfig.get_int(_slots_cfg, "count", _DEFAULT_SLOT_COUNT))


func autosave_slot() -> int:
	return UIConfig.get_int(_slots_cfg, "autosave_slot", 0)


# ---------------------------------------------------------------------------
# Reading the slots
# ---------------------------------------------------------------------------

## Re-reads the service's slot list. Cheap enough to call whenever the screen
## opens, which is the only time it is called.
func refresh() -> Array[Dictionary]:
	_meta.clear()
	if is_available():
		var listed: Variant = _service.call("list_slots")
		if listed is Array:
			for raw: Variant in (listed as Array):
				if raw is Dictionary and (raw as Dictionary).has("slot"):
					_meta[int((raw as Dictionary)["slot"])] = (raw as Dictionary).duplicate()
	return rows()


func meta(slot: int) -> Dictionary:
	var block: Variant = _meta.get(slot, {})
	return (block as Dictionary).duplicate() if block is Dictionary else {}


func is_used(slot: int) -> bool:
	return _meta.has(slot)


## One row per slot, always `slot_count()` of them: an empty slot is a row that
## says "Empty", never a gap in the list.
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for slot in slot_count():
		var block := meta(slot)
		var used := not block.is_empty()
		out.append({
			"slot": slot,
			"is_autosave": slot == autosave_slot(),
			"used": used,
			"title": slot_title(slot),
			"summary": _summary(block) if used else _t("ui_saves_empty"),
			"saved_text": _saved_text(block) if used else "",
			"meta": block,
			"can_save": is_available(),
			"can_load": is_available() and used,
			"can_delete": is_available() and used,
		})
	return out


func row(slot: int) -> Dictionary:
	for entry: Dictionary in rows():
		if int(entry["slot"]) == slot:
			return entry
	return {}


func slot_title(slot: int) -> String:
	if slot == autosave_slot():
		return _t("ui_saves_slot_autosave")
	return _t_args("ui_saves_slot", {"n": slot})


func _summary(block: Dictionary) -> String:
	return _t_args("ui_saves_meta", {
		"day": int(block.get("day_index", 0)) + 1,
		"population": HudModel.pop(int(block.get("population", 0))),
		"treasury": HudModel.money(int(block.get("treasury", 0))),
	})


func _saved_text(block: Dictionary) -> String:
	var unix := int(block.get("saved_at_unix", 0))
	if unix <= 0:
		return ""
	return _t_args("ui_saves_saved_at", {"date": SaveSlotsModel.format_unix(unix)})


## Local wall-clock stamp, `YYYY-MM-DD HH:MM`. A UI-side conversion only —
## nothing in `sim/` may read a clock at all (constitution §3).
static func format_unix(unix: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(unix)
	return "%04d-%02d-%02d %02d:%02d" % [int(d.get("year", 1970)), int(d.get("month", 1)),
			int(d.get("day", 1)), int(d.get("hour", 0)), int(d.get("minute", 0))]


# ---------------------------------------------------------------------------
# Acting on them — request → (confirm) → perform
# ---------------------------------------------------------------------------

## Asks for an action. Returns
## `{ok, action, slot, confirm_required, prompt, reason}`; when
## `confirm_required` is true the action is parked until `confirm()`, and when
## it is false the action has already run and the result carries `message`.
func request(action: StringName, slot: int) -> Dictionary:
	_pending = {}
	if slot < 0 or slot >= slot_count():
		return _refused(action, slot, REASON_UNKNOWN_SLOT)
	if not is_available():
		return _refused(action, slot, REASON_UNAVAILABLE)
	if action != ACTION_SAVE and not is_used(slot):
		return _refused(action, slot, REASON_EMPTY_SLOT)
	var needs_confirm := action != ACTION_SAVE or is_used(slot)
	if not needs_confirm:
		return perform(action, slot)
	_pending = {
		"action": action,
		"slot": slot,
		"prompt": _prompt(action, slot),
	}
	return {
		"ok": true,
		"action": action,
		"slot": slot,
		"confirm_required": true,
		"prompt": str(_pending["prompt"]),
		"reason": REASON_OK,
		"message": "",
	}


func pending() -> Dictionary:
	return _pending.duplicate()


func has_pending() -> bool:
	return not _pending.is_empty()


func cancel() -> Dictionary:
	var was := _pending.duplicate()
	_pending = {}
	return was


## Runs the parked action. Refuses politely when nothing is parked, so a double
## tap on `YES` can never fire the action twice.
func confirm() -> Dictionary:
	if _pending.is_empty():
		return {"ok": false, "action": &"", "slot": -1, "confirm_required": false,
				"prompt": "", "reason": REASON_UNKNOWN_SLOT, "message": ""}
	var action: StringName = _pending["action"]
	var slot := int(_pending["slot"])
	_pending = {}
	return perform(action, slot)


## The unconditional path — the service call plus the refresh and the copy.
## `request()` routes here once the player has answered any confirmation.
func perform(action: StringName, slot: int) -> Dictionary:
	if not is_available():
		return _refused(action, slot, REASON_UNAVAILABLE)
	var title := slot_title(slot)
	var ok := false
	match action:
		ACTION_SAVE:
			if _service.has_method("save_slot"):
				var result: Variant = _service.call("save_slot", _sim, slot)
				ok = result is Dictionary and not (result as Dictionary).is_empty()
		ACTION_LOAD:
			if _service.has_method("load_slot"):
				ok = bool(_service.call("load_slot", _sim, slot))
		ACTION_DELETE:
			if _service.has_method("delete_slot"):
				ok = bool(_service.call("delete_slot", slot))
		_:
			return _refused(action, slot, REASON_UNKNOWN_SLOT)
	refresh()
	var message_key := "ui_saves_failed"
	if ok:
		match action:
			ACTION_SAVE: message_key = "ui_saves_saved"
			ACTION_LOAD: message_key = "ui_saves_loaded"
			ACTION_DELETE: message_key = "ui_saves_deleted"
	return {
		"ok": ok,
		"action": action,
		"slot": slot,
		"confirm_required": false,
		"prompt": "",
		"reason": REASON_OK if ok else REASON_FAILED,
		"message": _t_args(message_key, {"slot": title}),
	}


## Autosave is fire-and-forget and never prompts — it overwrites its own slot by
## definition. Returns false when no service is bound yet.
func autosave() -> bool:
	if not is_available() or not _service.has_method("autosave"):
		return false
	_service.call("autosave", _sim)
	refresh()
	return true


func _prompt(action: StringName, slot: int) -> String:
	var title := slot_title(slot)
	match action:
		ACTION_SAVE: return _t_args("ui_saves_confirm_save", {"slot": title})
		ACTION_LOAD: return _t_args("ui_saves_confirm_load", {"slot": title})
		ACTION_DELETE: return _t_args("ui_saves_confirm_delete", {"slot": title})
	return ""


func _refused(action: StringName, slot: int, reason: StringName) -> Dictionary:
	var message := ""
	if reason == REASON_UNAVAILABLE:
		message = _t("ui_saves_unavailable")
	elif reason == REASON_EMPTY_SLOT:
		message = _t("ui_saves_empty")
	return {"ok": false, "action": action, "slot": slot, "confirm_required": false,
			"prompt": "", "reason": reason, "message": message}


func _t(key: String) -> String:
	return _cfg.t(key) if _cfg != null else key


func _t_args(key: String, args: Dictionary) -> String:
	return _cfg.t(key, args) if _cfg != null else key

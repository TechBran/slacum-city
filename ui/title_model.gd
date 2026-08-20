class_name TitleModel
extends RefCounted
## S0's logic (doc 12 §2.2): what CONTINUE says, and what NEW CITY costs.
## Headless, so the slot arithmetic below — which is the whole point of the class
## — is tested without a scene tree and without touching the disk.
##
## The files belong to `game/save_service.gd`, which this class talks to
## **duck-typed and READ ONLY**: `list_slots() -> Array[Dictionary]`,
## `latest_slot() -> int` and, when it offers one, `autosave_slots() -> Array`.
## Nothing here saves, loads or deletes: at the front door the sim has not been
## restored yet, so every write belongs to the shell, which owns it. What this
## class produces is a PLAN and the words for it.
##
## ---------------------------------------------------------------------------
## THE SLOT RULING — why NEW CITY is not just "boot a fresh sim"
## ---------------------------------------------------------------------------
##
## `SaveService` gives the LIVE city an autosave **rotation**: every autosave
## lands on whichever of `AUTOSAVE_SLOT` / `AUTOSAVE_SHADOW_SLOT` is older, so an
## unclean exit still leaves one complete city behind (doc 13 §2.11). That
## rotation belongs to whatever city is running — it has no idea a city was
## replaced. So a new city takes it over, and two autosave intervals later BOTH
## halves hold the new city. There is no flag, no per-city slot family and no
## API on `SaveService` that can prevent that, and inventing one here would be a
## `ui/` file legislating about files.
##
## What follows from that is the design, and it is stated rather than hidden:
##
##   * **A manual slot is the only durable home.** Slots outside the rotation
##     (`1 …` up to `save_slots.count`) are never written except by the player.
##     `plan.kept` lists the occupied ones by name — doc 12's "name the save it
##     will NOT delete".
##   * **The autosave is what a new city costs.** `plan.replaced` says so in
##     words rather than letting the player discover it two intervals later.
##   * **A city that lives only in the rotation is offered a home first.**
##     `plan.archive_from` is the slot holding it and `plan.archive_to` is the
##     lowest free manual slot; the confirm then offers KEEP & START NEW beside
##     START NEW. The shell performs that with three published calls and no new
##     API — `load_slot` the old city into the sim, `save_slot` it into the free
##     slot, `restore_state` the founding capture back — which is exact because
##     save→load→advance identity is exact (doc 93 §E2).
##   * **When every manual slot is full, the plan says so and does not guess.**
##     `archive_to` is −1, `blocked_keep` is true, and the copy points at
##     Settings ▸ Manage saves. Silently overwriting one of the player's own
##     saves to make room is exactly the orphaning this rule exists to stop.
##
## Slot meta is `SaveService`'s shape — `{slot, saved_at_unix, day_index,
## population, treasury}` — and this class only formats it, through `HudModel`'s
## number formats and the `ui_saves_*` copy the save sheet already uses, so a
## treasury reads the same on the front door as it does in the slot list.

const ACTION_CONTINUE := &"continue"
const ACTION_NEW_GAME := &"new_game"
const ACTION_SETTINGS := &"settings"

const _DEFAULT_ACTIONS: Array[String] = ["continue", "new_game", "settings"]
const _DEFAULT_SLOT_COUNT := 3

var _cfg: UIConfig
var _title_cfg: Dictionary = {}
var _slots_cfg: Dictionary = {}
var _service: Object = null
var _meta: Dictionary = {}          # slot:int -> meta Dictionary


func _init(cfg: UIConfig = null) -> void:
	if cfg == null:
		return
	_cfg = cfg
	_title_cfg = cfg.section("title")
	_slots_cfg = cfg.section("save_slots")


static func load_from_files() -> TitleModel:
	return TitleModel.new(UIConfig.load_from_files())


## `service` is `game/save_service.gd`. It stays `Object`: `ui/` never depends on
## that type, which is what lets the tests hand in a stub.
func bind(service: Object) -> void:
	_service = service
	refresh()


func is_available() -> bool:
	return _service != null and _service.has_method("list_slots")


func config() -> UIConfig:
	return _cfg


# ---------------------------------------------------------------------------
# Reading the slots
# ---------------------------------------------------------------------------

## Re-reads the service's slot list. Called when the door opens, and again after
## the shell has acted on a plan.
func refresh() -> Dictionary:
	_meta.clear()
	if is_available():
		var listed: Variant = _service.call("list_slots")
		if listed is Array:
			for raw: Variant in (listed as Array):
				if raw is Dictionary and (raw as Dictionary).has("slot"):
					_meta[int((raw as Dictionary)["slot"])] = (raw as Dictionary).duplicate()
	return continue_row()


func slot_count() -> int:
	return maxi(1, UIConfig.get_int(_slots_cfg, "count", _DEFAULT_SLOT_COUNT))


func autosave_slot() -> int:
	return UIConfig.get_int(_slots_cfg, "autosave_slot", 0)


## The slots `SaveService`'s autosave alternates between, ascending. Asked of the
## service, because the shadow half deliberately sits OUTSIDE every slot the
## player can see and `data/ui.json` therefore does not name it. A service that
## does not publish the pair is treated as having one autosave slot, which is
## the conservative reading — it can only ever over-report what survives.
func rotation_slots() -> Array[int]:
	var out: Array[int] = []
	if _service != null and _service.has_method("autosave_slots"):
		var listed: Variant = _service.call("autosave_slots")
		if listed is Array:
			for raw: Variant in (listed as Array):
				out.append(int(raw))
	if out.is_empty():
		out.append(autosave_slot())
	out.sort()
	return out


## The player-facing slots that the autosave never writes: everything below
## `slot_count()` that is not part of the rotation.
func manual_slots() -> Array[int]:
	var rotation := rotation_slots()
	var out: Array[int] = []
	for slot in slot_count():
		if not rotation.has(slot):
			out.append(slot)
	return out


func meta(slot: int) -> Dictionary:
	var block: Variant = _meta.get(slot, {})
	return (block as Dictionary).duplicate() if block is Dictionary else {}


func is_used(slot: int) -> bool:
	return _meta.has(slot)


func has_any_save() -> bool:
	return not _meta.is_empty()


## The slot CONTINUE would resume, or −1. Asked of the service so the front door
## and a plain launch agree on what "the newest save" means; falls back to this
## class's own reading of the meta when the service does not publish it.
func latest_slot() -> int:
	if _service != null and _service.has_method("latest_slot"):
		return int(_service.call("latest_slot"))
	var best := -1
	var best_at := -1
	for slot: int in _meta:
		var at := int((_meta[slot] as Dictionary).get("saved_at_unix", 0))
		if at > best_at:
			best_at = at
			best = slot
	return best


## The CONTINUE button, as data: whether it is offered at all and, when it is,
## the one line that says which city it resumes (doc 12 §2.2 — "day N,
## population, treasury").
func continue_row() -> Dictionary:
	var slot := latest_slot()
	var block := meta(slot) if slot >= 0 else {}
	var enabled := slot >= 0 and not block.is_empty()
	return {
		"action": ACTION_CONTINUE,
		"slot": slot if enabled else -1,
		"enabled": enabled,
		"label": _t("ui_title_continue"),
		"summary": _summary(block) if enabled else _t("ui_title_continue_empty"),
		"saved_text": _saved_text(block) if enabled else "",
		"meta": block,
	}


## The three buttons, in `data/ui.json.title.actions` order. CONTINUE is the
## primary when there is a city to continue and NEW CITY is the primary when
## there is not, so the front door always has exactly one obvious answer.
func actions() -> Array[Dictionary]:
	var raw: Variant = _title_cfg.get("actions", _DEFAULT_ACTIONS)
	var ids: Array = raw if raw is Array else _DEFAULT_ACTIONS
	var resume_first := bool(continue_row()["enabled"])
	var out: Array[Dictionary] = []
	for value: Variant in ids:
		var action := StringName(str(value))
		var enabled := true
		if action == ACTION_CONTINUE:
			enabled = resume_first
		out.append({
			"action": action,
			"enabled": enabled,
			"label": _t("ui_title_%s" % String(action)),
			"primary": (action == ACTION_CONTINUE) == resume_first
					and action != ACTION_SETTINGS,
		})
	return out


# ---------------------------------------------------------------------------
# NEW CITY — the plan, and only the plan
# ---------------------------------------------------------------------------

## What starting a new city would cost, and what it would not. See the ruling in
## this file's header. Keys:
##
##   `needs_confirm`   false only when there is nothing saved at all.
##   `kept`            occupied manual slots — the saves this does NOT delete.
##   `replaced`        true when the autosave rotation holds a city today.
##   `archive_from`    slot holding the newest city when that city lives ONLY in
##                     the rotation, else −1.
##   `archive_to`      lowest free manual slot, or −1 when there is none.
##   `blocked_keep`    `archive_from >= 0` and `archive_to < 0` — the one case
##                     where a city genuinely cannot be preserved from here.
##   `prompt`          the question plus its consequences, already in words.
##   `keep_note`       what KEEP & START NEW would do, or the "no room" line.
func new_game_plan() -> Dictionary:
	var rotation := rotation_slots()
	var kept: Array[int] = []
	for slot: int in manual_slots():
		if is_used(slot):
			kept.append(slot)
	var replaced := false
	for slot: int in rotation:
		if is_used(slot):
			replaced = true
			break
	var latest := latest_slot()
	var archive_from := latest if latest >= 0 and rotation.has(latest) else -1
	var archive_to := -1
	if archive_from >= 0:
		for slot: int in manual_slots():
			if not is_used(slot):
				archive_to = slot
				break
	var blocked_keep := archive_from >= 0 and archive_to < 0
	var lines: PackedStringArray = [_t("ui_title_confirm_prompt")]
	if not kept.is_empty():
		lines.append(_t_args("ui_title_confirm_kept", {"slots": _names(kept)}))
	if replaced:
		lines.append(_t_args("ui_title_confirm_replaced",
				{"slots": _t("ui_saves_slot_autosave")}))
	var keep_note := ""
	if archive_to >= 0:
		keep_note = _t_args("ui_title_confirm_stored_as", {"slot": slot_title(archive_to)})
	elif blocked_keep:
		keep_note = _t("ui_title_confirm_no_room")
	return {
		"needs_confirm": has_any_save(),
		"kept": kept,
		"replaced": replaced,
		"rotation": rotation,
		"archive_from": archive_from,
		"archive_to": archive_to,
		"blocked_keep": blocked_keep,
		"can_keep": archive_to >= 0,
		"prompt": "\n".join(lines),
		"keep_note": keep_note,
	}


## The answer the shell acts on. `keep` is the player's choice between
## KEEP & START NEW and START NEW; it is honoured only when the plan actually
## offers it, so a stale view can never ask for a copy into slot −1.
##
## `slot` is **the slot the outgoing city was preserved into**, or −1 when
## nothing was preserved — which is exactly what `UIRoot.title_new_game(slot)`
## carries and what `game/main.gd` needs in order to know whether to run the
## archive round trip before it founds the new city.
func confirm_new_game(keep: bool = false) -> Dictionary:
	var plan := new_game_plan()
	var keeping := keep and bool(plan["can_keep"])
	return {
		"ok": true,
		"keep": keeping,
		"archive_from": int(plan["archive_from"]) if keeping else -1,
		"archive_to": int(plan["archive_to"]) if keeping else -1,
		"slot": int(plan["archive_to"]) if keeping else -1,
	}


# ---------------------------------------------------------------------------
# Copy
# ---------------------------------------------------------------------------

## The save sheet's own slot names, so one city is called the same thing on both
## screens (`ui_saves_slot` / `ui_saves_slot_autosave`).
func slot_title(slot: int) -> String:
	if rotation_slots().has(slot):
		return _t("ui_saves_slot_autosave")
	return _t_args("ui_saves_slot", {"n": slot})


func _names(slots: Array[int]) -> String:
	var parts: PackedStringArray = []
	for slot: int in slots:
		parts.append(slot_title(slot))
	return ", ".join(parts)


func _summary(block: Dictionary) -> String:
	if block.is_empty():
		return _t("ui_title_continue_empty")
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


func _t(key: String) -> String:
	return _cfg.t(key) if _cfg != null else key


func _t_args(key: String, args: Dictionary) -> String:
	return _cfg.t(key, args) if _cfg != null else key

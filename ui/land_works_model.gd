class_name LandWorksModel
extends RefCounted
## **The receipt for what the crews dug up** — doc 12 §2.8 D-117, doc 03 §2.8b.
##
## The headless half of the `land_works` income line, and the same contract
## `StreetModel` has with the payday: this class turns ONE sim event into the
## record `UIRoot._spend_feedback()` spends on the surfaces that can feel it —
## a toast, a treasury-chip flash and a haptic cue. It owns no threshold, no
## price and no copy (constitution §3, doc 12 §1): the dollars are
## `EconomySystem.works_yield_value`'s, and every sentence resolves from
## `data/strings.en.json`.
##
## ## Why this is a toast and not a tap
##
## `StreetModel.collect_feedback` answers a FINGER: the player pressed a bounty
## and the record is the answer to their press. Nothing is pressed here. A find
## happens while the player is looking somewhere else — three of them per block,
## at the completion of CLEARING, GRADING and UTILITY_CORRIDOR — so this is the
## same shape as `StreetModel`'s auto-collect arm: the bus says it happened and
## the screen says so out loud. `UIRoot.report_land_works()` is the one door and
## `_check_land_works()` is its only caller, so a find is felt exactly once
## however the batch reached the root (a tick, a `flush_sim_events`, a replay).
##
## ## The two sentences
##
## A CLEARING find is all cash and reads `Timber — $540`. A GRADING or
## UTILITY_CORRIDOR find keeps `STOCKPILE_SHARE` of itself as material and reads
## `Fill and aggregate — $297, $153 to the yard`, because a player who is told
## `$450` and sees `$297` land in the treasury has been lied to by rounding.
## When the yard is full the split does not happen and the first sentence is the
## honest one again — which is why the branch is on `stockpiled`, the payload's
## own number, and never on the phase.

const EVENT_FIND := &"land_works_find"
const EVENT_YARD := &"land_works_stockpile_spent"

## The chip the money lands on. `treasury` is the HUD's balance chip — the same
## one `StreetModel` flashes for a collected bounty, because it is the same
## treasury and the same beat.
const CHIP := &"treasury"

const _DEFAULT_FLASH_S := 0.9

var config: UIConfig


func _init(p_config: UIConfig = null) -> void:
	config = p_config if p_config != null else UIConfig.load_from_files()


static func load_from_files() -> LandWorksModel:
	return LandWorksModel.new(UIConfig.load_from_files())


## One `land_works_find` payload in, one feedback record out — or `{}` for an
## event that is not one (so a caller may hand it a whole batch entry without
## checking first). `ok` is true whenever money moved, which is the flag
## `UIRoot._spend_feedback` reads to pick the toast's state.
func find_feedback(event: Dictionary) -> Dictionary:
	if StringName(str(event.get("type", ""))) != EVENT_FIND:
		return {}
	var value := int(event.get("value", 0))
	if value <= 0:
		return {}
	var cash := int(event.get("amount", value))
	var kept := int(event.get("stockpiled", 0))
	var material := material_text(str(event.get("material", "")))
	var toast := ""
	if kept > 0:
		toast = _t("ui_land_works_toast_yard", {
			"material": material,
			"amount": HudModel.money_exact(cash),
			"kept": HudModel.money_exact(kept),
		})
	else:
		toast = _t("ui_land_works_toast", {
			"material": material, "amount": HudModel.money_exact(cash),
		})
	return {
		"ok": true,
		"block": str(event.get("block", "")),
		"phase": str(event.get("phase", "")),
		"material": material,
		"value": value,
		"amount": cash,
		"stockpiled": kept,
		"bonus": bool(event.get("bonus", false)),
		"toast": toast,
		# The chip only pulses for money that actually reached the treasury. A
		# find that went entirely to the yard moved no balance, and a balance
		# chip that flashes for a number that did not change is the kind of
		# feedback that teaches a player to stop reading it.
		"flash_chip": String(CHIP) if cash > 0 else "",
		"flash_s": _DEFAULT_FLASH_S,
		# **No haptic, deliberately** — `StreetModel`'s bounty rule, for its
		# reason: §2.14's cues answer something the player DID, and nobody
		# pressed anything here. A buzz in the hand for an event the hand had no
		# part in reads as an error, not as a reward. The sound is
		# `data/audio.json`'s rule on the event itself (`cash`, the same
		# identity a bounty rings), so nothing here plays it.
		"haptic": "",
	}


## **`land_works_stockpile_spent` gets no toast and that is the ruling.** The
## yard spending itself is not a thing that HAPPENED to the player — an invoice
## they were about to pay got smaller — and five toasts per block (three finds
## plus two yard draws) is the shape that teaches a player to swipe them away
## without reading. Its two consumers are the ones a smaller invoice owes: the
## event-log row (`data/ui.json.event_log.events`, so the number is findable an
## hour later) and the land panel's own `Yard materials −$1,160` line under the
## phase it came off. `EVENT_YARD` is named here because `phase_text` below is
## what renders that panel line.


## `timber` → `Timber`. Falls back to the raw id rather than to a blank: a
## missing key must cost the sentence its polish, never its meaning — the same
## rule `EventLogModel._lookup` follows for the same family.
func material_text(material: String) -> String:
	if material == "":
		return ""
	var key := "ui_land_works_material_%s" % material.to_lower()
	if config != null and config.has_string(key):
		return config.t(key, {})
	return material


## `ROAD_INSTALL` → `Roads`, through the same `ui_land_phase_*` copy the land
## panel's own progress line and the event log's charge row already use.
func phase_text(phase: String) -> String:
	if phase == "":
		return ""
	var key := "ui_land_phase_%s" % phase.to_lower()
	if config != null and config.has_string(key):
		return config.t(key, {})
	return phase


func _t(key: String, args: Dictionary) -> String:
	if config != null and config.has_string(key):
		return config.t(key, args)
	return key

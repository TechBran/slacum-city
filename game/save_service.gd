class_name SaveService
extends Node
## Player-facing save slots for the app shell — doc 13 §2.2's API riding doc
## 08's storage (§2.5–§2.9).
##
## **What changed and why.** This service used to own its own format: one flat
## JSON file per slot, a two-slot autosave shadow, and a `format` integer with
## no ladder behind it. Doc 08's `SaveManager` owned the real thing — generation
## files, a `manifest.json` commit point, SHA-256 digests, a retention ladder, a
## quarantine and a seven-check load gate — and was reachable from nowhere. Two
## save formats, one game (doc 91 §8, rows 2.5/2.7/2.8/2.9). The five-method API
## below is unchanged; everything underneath it is now `SaveManager`.
##
##     user://saves/slot_3/manifest.json     <- the commit point AND the header
##     user://saves/slot_3/gen_000042.sav    <- zstd JSON envelope, digested
##     user://saves/slot_3/quarantine/…      <- candidates that failed the gate
##     user://saves/slot_3.json              <- format 1, read-only, still loads
##
## **The header trick moved, it did not die.** The old file put `meta` in its
## first bytes so a load screen could list slots without deserializing a city.
## The envelope's body is sorted-key by law (doc 08 §2.5 — that is what makes
## the digest meaningful), so `meta` can no longer be first inside it. It is
## written into `manifest.active.meta` instead: still one small uncompressed
## read per slot, and now it survives a body that is corrupt *and* unparseable,
## which the old brace-scan did not.
##
## **The autosave shadow is gone; the ladder subsumes it.** `AUTOSAVE_SHADOW_SLOT`
## existed because one slot cannot survive a save that is structurally perfect
## and semantically wrong. Doc 08 §2.7's ladder answers the same failure with
## six generations spread across 30 minutes / 6 hours / 24 hours / 7 days, each
## digest-verified on the way back in, and `load_newest()` walking them in
## order. That is the shadow, five deep, with a checksum. Slot 7 is a player
## slot again.
##
## Constitution §3: this is `game/`, so wall-clock reads (`Time`) are legal here
## and illegal in `sim/` — which is why `SaveManager` takes `real_unix` as a
## parameter. The sim is passed in, never imported: the only methods called on
## it are `canonical_capture()` and `restore_state()`, plus read-only property
## lookups for the header (guarded with `in`, so any object exposing them works).

## Emitted after a successful write of any slot, including autosaves.
signal saved(meta: Dictionary)
## Emitted after a slot has been restored into a sim.
signal loaded(slot: int)
## Emitted when a save, load or delete could not complete. `reason` is one of
## `invalid_slot`, `no_dir`, `write_failed`, `rename_failed`, `delete_failed`,
## `missing`, `unreadable`, `bad_json`, `no_state`, and — new with the doc 08
## gate — `corrupt` (every candidate generation failed its digest or structural
## check) and `downgrade` (the save was written by a newer build of the app).
signal failed(slot: int, reason: String)

const SAVE_DIR := "user://saves"
## Format-1 layout: one flat file per slot. Read-only now; see [load_slot].
const FILE_TEMPLATE := "slot_%d.json"
const TEMP_SUFFIX := ".tmp"
## Slots the UI may address. 0 is reserved for the lifecycle autosave.
const MAX_SLOTS := 8
const AUTOSAVE_SLOT := 0
## The slot the retired autosave shadow used. Kept for one reason only: a phone
## upgrading from a build that alternated has a format-1 file here, and it may
## be the newer half. It is never written again — the first autosave after the
## upgrade lands on [AUTOSAVE_SLOT] and the ladder takes over — but until then
## [last_good_autosave_slot] must still be able to find the city that is
## actually there. See the class docs for why the alternation went away.
const LEGACY_AUTOSAVE_SHADOW_SLOT := 7
## The envelope this build writes. 1 = the flat `{format,meta,ui,state}` file;
## 2 = a doc 08 generation ladder under `slot_N/`. Format 1 is still READ (the
## migration path in [_load_legacy]) and never written again.
const FORMAT_VERSION := 2
const LEGACY_FORMAT_VERSION := 1
## Meta lived first in the format-1 file so `list_slots()` could read a header
## instead of a whole city. Only the legacy reader needs this now.
const META_SCAN_BYTES := 4096

## Save-body sections (doc 08 §3.1). Milestone 1 has one sim section, not the
## registry's twenty — see `DictSection`, and `_city_section_version` for the
## hook `sim/city_sim.gd` fills as it splits.
const META_SECTION := &"meta"
const CITY_SECTION := &"city"
const UI_SECTION := &"ui"
## Fallback when the sim exposes no `save_section_version()` of its own.
const CITY_SECTION_VERSION := 1
const UI_SECTION_VERSION := 1
const META_SECTION_VERSION := 1

## slot:int -> SaveManager. Declared before [base_dir] because that property's
## setter clears it.
var _managers: Dictionary = {}

## The in-flight write, or -1. Declared up here for the same reason `_managers`
## is: [base_dir]'s setter calls [flush_writes], which reads this, and a
## member declared after the property it is read from is not yet initialised
## when a caller assigns that property.
##
## At most ONE write is in flight per service. `commit_save` reads the
## generation number out of the manifest, so two concurrent commits to one slot
## would race for it; a second request settles the first, which costs the caller
## the tail of a write that was already most of the way done and never costs a
## save.
var _task_id: int = -1

## Where slots live. Overridable so tests never touch a real player profile.
## Assigning it drops every cached slot manager, because the managers are bound
## to paths under the old root.
var base_dir: String = SAVE_DIR:
	set(value):
		# A queued write holds a manager bound to a path under the OLD root.
		flush_writes()
		base_dir = value
		_managers.clear()
## Optional: the shell registers a Callable returning the UI save section
## (doc 12 §3.2 — overlay prefs, settings, tutorial progress). When set, every
## save carries it and `last_loaded_ui` hands it back after a load, so the
## tutorial never restarts on a city that already finished it.
var ui_provider: Callable = Callable()
## The `ui` section of the most recent successful load. A boot-time restore
## happens before the UI exists; the shell applies this once it does.
var last_loaded_ui: Dictionary = {}
## Reason string for the last failure, "" after a success. Useful for UI that
## wants the detail without connecting to `failed`.
var last_error: String = ""
## Unix seconds of the last successful autosave, 0 if none this session.
var last_autosave_unix: int = 0
## Which slot the last autosave landed on, -1 if none yet. Always
## [AUTOSAVE_SLOT] now that the ladder replaced the two-slot rotation; kept
## because `CrashSentinel` and the lifecycle node both read it.
var last_autosave_slot: int = -1

## Doc 08 §2.9 recovery bookkeeping, set by every successful [load_slot]:
## true when the generation that loaded was NOT the manifest's active one.
var last_load_recovered: bool = false
## Sim-minutes between the slot's high-water mark and the generation that
## actually loaded — doc 08 §2.9's "you lost about N minutes" figure.
var last_load_lost_minutes: int = 0
## 1 when the last successful load came from a format-1 file, 2 from the ladder.
var last_load_format: int = 0
## Structural repairs the last load had to make (doc 08 §2.9's repair notes).
var repair_notes: PackedStringArray = []

## Doc 08 §8's `save` block. Injectable so a test can shorten the ladder.
var policy: SavePolicy = SavePolicy.load_from_files()

## Wall milliseconds the last `save_slot` / `load_slot` cost THE CALLER —
## capture, envelope, digest, compress, write, manifest for a save; candidate
## walk, digest, decompress, migrate, restore for a load. Doc 13 §7's D-17 asks
## for these ON DEVICE and there was no instrument for it: the numbers doc 08
## quotes are workstation numbers taken from a test harness, and a phone's
## flash and a phone's CPU are the two things they cannot stand in for.
##
## With [async_writes] on, `last_save_ms` is the MAIN-THREAD half only — the
## capture — because that is what the frame budget actually pays. What the write
## itself cost, wherever it ran, is [last_write_ms].
var last_save_ms: float = 0.0
var last_load_ms: float = 0.0
## Wall milliseconds the envelope/digest/compress/write/manifest half took. Set
## by both paths, so a synchronous save reports the same split an asynchronous
## one does and the two are comparable.
var last_write_ms: float = 0.0
## The load's two halves, because they have very different futures. `read` is
## the candidate walk — open, zstd-decompress, parse, SHA-256, the seven-check
## gate, section deserialize — and every byte of it is pure: it touches no sim
## and could in principle run on a worker while a loading screen draws.
## `restore` is `CitySim.restore_state`, which rebuilds the live city and cannot
## leave the main thread for the same reason the capture cannot. Doc 08 §2.14
## costs the streaming design against this split.
var last_load_read_ms: float = 0.0
var last_load_restore_ms: float = 0.0
## Emit one `PERFIO` line per save/load, in the same shape doc 11 §7.4's `PERF`
## line uses so ONE logcat grep collects both halves of a device capture.
##
## **Off by default, and that is deliberate.** A service whose job is writing
## files should not print on every call: the suite drives thousands of saves and
## would drown its own runner, and the line costs a directory listing it should
## not pay for in a test. The shell turns it on — one line in `game/main.gd`,
## in the branch report's integration snippet — so a device build logs and
## nothing else does.
var log_io: bool = false

# ------------------------------------------------------------- async writes
#
# **Why (report 98 RR-40).** `tools/profile_save.gd` measured the shipped path
# at **149 ms to save and 484 ms to load** the 1,500-building benchmark city, on
# a workstation, on the main thread — and the Fold is expected at 2–3× that. Doc
# 08's autosave therefore lands as a visible hitch on any city a player has
# grown. The cadence is not the problem; the fact that the write is synchronous
# is. `SaveManager` now splits into `capture_save` (main thread, reads the live
# sim) and `commit_save` (bytes only), and this is the half that hands the
# second one to `WorkerThreadPool`.
#
# **The split is not where it was expected to be, and the measurement says so.**
# Of the 149 ms save, the write half is **52 ms** and the capture is **96** —
# `canonical_capture()` is the expensive one, not the envelope. Threading the
# write therefore takes the caller's cost from **148.7 ms to 97.5** on the
# benchmark city and 16.5 to 12.0 on the founding one: a third off, not the
# seven-eighths the doc's framing implies. It is worth taking, and the next
# lever on this path is the capture, not the file.
#
# **And the LOAD is not threadable at all.** Its split is 35 ms of reading
# (decompress, parse, digest, the seven-check gate) against **443 ms of
# `restore_state`**, which rebuilds the live city and can no more leave the main
# thread than the capture can. A streaming loader would move 7 % of a 484 ms
# load. The costed design and the refusal are in doc 08 §2.14.
#
# **What does NOT move.** The capture, always. And the whole of the PAUSE path:
# doc 13 §2.2 says the save must COMMIT before Android may kill the process, and
# a dispatched write is not a committed one. So [SYNC_REASONS] names the
# checkpoint reasons that finish before the call returns, and `pause` is the
# first of them. `AndroidLifecycle` already tags its lifecycle save `pause`, so
# it is synchronous whether or not the shell ever sets [async_writes].
#
# **The API does not change shape.** `save_slot` still returns the meta
# dictionary the moment it has one — the header is built from the capture, not
# from the file — and `saved` still fires exactly once per successful write,
# just later. Every reader of a slot ([load_slot], [list_slots], [delete_slot],
# [has_slot], [latest_slot], [slot_path], [last_good_autosave_slot]) flushes
# first, so nothing in the codebase can observe a half-written ladder.

## Turn the write half over to a worker thread. **Off by default**: a service
## that writes files should not start a thread because it was constructed, the
## suite drives thousands of saves through it, and the shell is the thing that
## knows whether there is a frame to protect. One line in `game/main.gd`.
var async_writes: bool = false

## Checkpoint reasons whose write must COMMIT before `save_slot` returns.
## `pause` is doc 13 §2.2's — the process may be killed the instant the
## callback returns. `quit` is the same contract on the desktop and task-close
## paths. `pre_migration` and `pre_catchup` are pinned generations taken
## immediately before something destructive, and a pin that has not landed is
## not a pin.
const SYNC_REASONS: PackedStringArray = ["pause", "quit", "pre_migration", "pre_catchup"]

## Everything `_settle_write` needs, written on the main thread before the task
## is queued and read after it completes. Never touched while the task runs.
var _write_slot: int = -1
var _write_reason: String = ""
var _write_meta: Dictionary = {}
var _write_capture: Dictionary = {}
var _write_manager: SaveManager = null
## The worker's answer. Written by the task, read only after
## `is_task_completed` / `wait_for_task_completion`, both of which are the
## happens-before edge that makes the read safe.
var _write_result: Dictionary = {}
var _write_usec: int = 0


func _ready() -> void:
	_ensure_dir()
	set_process(false)


## Signals must land on the main thread, so a completed write is picked up here
## rather than announced from the worker. Processing is armed only while a task
## is in flight — an idle `SaveService` costs the frame nothing.
func _process(_delta: float) -> void:
	if _task_id < 0:
		set_process(false)
		return
	if WorkerThreadPool.is_task_completed(_task_id):
		_settle_write()


## Block until the in-flight write has committed and its signal has fired.
## Called before every read of a slot, by the pause path, and on the way out of
## the tree — a process that ends with a write still queued is a lost save.
func flush_writes() -> void:
	if _task_id < 0:
		return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_settle_write()


## True while a write is queued or running.
func write_pending() -> bool:
	return _task_id >= 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE or what == NOTIFICATION_PREDELETE \
			or what == NOTIFICATION_WM_CLOSE_REQUEST:
		flush_writes()


## Doc 11 §7.4's log shape, for the I/O half. One line, `^PERF`-anchored so
## `tools/bench_device.sh`'s existing logcat filter picks it up, and shaped as
## `key=value` tokens so the same parser reads it — its `p95` lookup fails on
## this line and the row is skipped, which is the behaviour we want: the CSV
## keeps the frame rows clean and the I/O rows are still in the capture.
func _log_io(kind: String, slot: int, reason: String, ms: float, ok: bool) -> void:
	if not log_io:
		return
	var bytes := 0
	var path := _slot_dir(slot)
	var dir := DirAccess.open(path)
	if dir != null:
		for name in dir.get_files():
			bytes += _file_size(path.path_join(name))
	print(("PERFIO kind=%s slot=%d reason=%s ms=%.1f write_ms=%.1f read_ms=%.1f "
			+ "restore_ms=%.1f async=%d bytes=%d ok=%d")
			% [kind, slot, reason, ms, last_write_ms, last_load_read_ms,
			last_load_restore_ms, 1 if async_writes else 0, bytes, 1 if ok else 0])


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := int(f.get_length())
	f.close()
	return n


# ----------------------------------------------------------------- save path

## Capture `sim` and commit it to `slot`. Returns the meta dictionary
## {slot, saved_at_unix, day_index, population, treasury} on success, or an
## EMPTY dictionary on failure (check `last_error` / the `failed` signal).
##
## `reason` is doc 08 §2.7's checkpoint reason and rides the manifest entry:
## `manual` from the save screen, `autosave` from the timer, `pause`/`quit`
## from the lifecycle. `pre_migration` and `pre_catchup` additionally PIN the
## generation, which is why they are never swept.
##
## The body is `_save_slot`; this wrapper exists ONLY to time it. Wrapping is
## what makes the figure honest — `_save_slot` has seven early returns and a
## stopwatch threaded through them would have missed most of the failure paths,
## which are exactly the ones a slow phone shows up on first.
func save_slot(sim: Object, slot: int, reason: String = "manual") -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var meta := _save_slot(sim, slot, reason)
	last_save_ms = float(Time.get_ticks_usec() - t0) * 0.001
	# A DISPATCHED write logs from `_settle_write`, when there is an outcome to
	# report. Logging here would print a save that has not happened yet, and a
	# byte count of the generation before it.
	if not write_pending():
		_log_io("save", slot, reason, last_save_ms, not meta.is_empty())
	return meta


func _save_slot(sim: Object, slot: int, reason: String) -> Dictionary:
	if not _valid_slot(slot):
		return _fail_dict(slot, "invalid_slot")
	if sim == null or not sim.has_method("canonical_capture"):
		return _fail_dict(slot, "no_state")
	if not _ensure_dir():
		return _fail_dict(slot, "no_dir")
	# One write in flight per service. A second request settles the first, so
	# the manifest's generation counter is only ever read by one thread.
	flush_writes()

	var meta := _meta_of(sim, slot, reason)
	var manager := _manager(slot)
	var city := DictSection.new(CITY_SECTION, _city_section_version(sim))
	city.payload = sim.call("canonical_capture")
	city.migrator = _city_migrator(sim)
	var ui := DictSection.new(UI_SECTION, UI_SECTION_VERSION)
	if ui_provider.is_valid():
		var ui_state: Variant = ui_provider.call()
		if ui_state is Dictionary:
			ui.payload = ui_state
	var meta_section := DictSection.new(META_SECTION, META_SECTION_VERSION)
	meta_section.payload = meta.duplicate()
	manager.register_section(city)
	manager.register_section(ui)
	manager.register_section(meta_section)

	# The header rides the manifest (see the class docs): one small
	# uncompressed file per slot is what keeps `list_slots()` cheap.
	var capture := manager.capture_save(reason, _sim_time_minutes(sim),
			int(meta["saved_at_unix"]), {"meta": meta.duplicate()})
	if async_writes and not SYNC_REASONS.has(reason):
		_write_slot = slot
		_write_reason = reason
		_write_meta = meta
		_write_capture = capture
		# The manager is resolved HERE, not on the worker: `_managers` is a
		# dictionary the main thread may rewrite (`base_dir`, `delete_slot`), and
		# a worker reading it while it moves is the one race this design has.
		_write_manager = manager
		_write_result = {}
		_write_usec = 0
		_task_id = WorkerThreadPool.add_task(_run_write, false,
				"SaveService write slot %d" % slot)
		set_process(true)
		# The header is built from the capture, not from the file, so the caller
		# gets its answer now and the `saved` signal follows the commit.
		last_error = ""
		return meta
	var t0 := Time.get_ticks_usec()
	var result := manager.commit_save(capture)
	last_write_ms = float(Time.get_ticks_usec() - t0) * 0.001
	return _finish_write(slot, result, meta)


## Runs on a `WorkerThreadPool` thread. Everything it touches was fixed before
## the task was queued: the capture is self-contained, the manager's sections
## are not read by `commit_save`, and no other write to this slot can be in
## flight. It emits nothing — signals are the main thread's, in `_settle_write`.
func _run_write() -> void:
	var t0 := Time.get_ticks_usec()
	_write_result = _write_manager.commit_save(_write_capture)
	_write_usec = Time.get_ticks_usec() - t0


## Back on the main thread, once the task has completed.
func _settle_write() -> void:
	_task_id = -1
	set_process(false)
	var result := _write_result
	var meta := _write_meta
	var slot := _write_slot
	last_write_ms = float(_write_usec) * 0.001
	_write_capture = {}
	_write_result = {}
	_write_meta = {}
	_write_manager = null
	_write_slot = -1
	_log_io("save", slot, _write_reason, last_save_ms, bool(result.get("ok", false)))
	_write_reason = ""
	_finish_write(slot, result, meta)


## The one place a write's outcome becomes a signal, whichever thread produced
## it — so a synchronous save and an asynchronous one are indistinguishable to
## everything that listens.
func _finish_write(slot: int, result: Dictionary, meta: Dictionary) -> Dictionary:
	if not bool(result.get("ok", false)):
		# The generation write and the manifest commit fail differently, and the
		# difference matters: a failed generation wrote nothing, a failed
		# manifest left an orphan and the PREVIOUS save still active.
		return _fail_dict(slot,
				"rename_failed" if result.get("reason_code", &"") == &"E_MANIFEST_WRITE"
				else "write_failed")
	last_error = ""
	saved.emit(meta)
	return meta


## Lifecycle autosave (doc 13 §2.2 step 2): commit the live city to the
## autosave slot. Never throws, never blocks the caller on a result — listen to
## `saved` / `failed` if you need one.
##
## One slot, because doc 08 §2.7's generation ladder inside it already keeps the
## previous city — and five more behind that, spread out to a week. An unclean
## exit that ate this write falls through to the generation before it, which is
## what the two-slot shadow used to buy at a quarter of the depth and with no
## digest to prove the fallback was ever whole.
func autosave(sim: Object, reason: String = "autosave") -> void:
	var meta := save_slot(sim, AUTOSAVE_SLOT, reason)
	if not meta.is_empty():
		last_autosave_unix = int(meta["saved_at_unix"])
		last_autosave_slot = AUTOSAVE_SLOT


## The slots the autosave uses. A one-element array since the ladder replaced
## the rotation; kept as an array because callers iterate it.
static func autosave_slots() -> Array[int]:
	return [AUTOSAVE_SLOT]


## Where the next autosave will land. Always [AUTOSAVE_SLOT] — the depth that
## used to come from alternating slots now comes from the generation ladder
## inside this one.
func next_autosave_slot() -> int:
	return AUTOSAVE_SLOT


## The newest autosave that actually loads — the answer `CrashSentinel` asks for
## after an unclean exit. -1 when nothing in the autosave slot is readable.
##
## "Loads" means a full doc 08 §2.9 candidate walk: decompress, envelope parse,
## SHA-256 match, version range, structural check. It is a PROBE — nothing is
## quarantined, nothing is deserialized, and no failure is reported through the
## `failed` signal, because a damaged checkpoint found by a health check is an
## expected finding and not an error to put in front of a player.
func last_good_autosave_slot() -> int:
	flush_writes()
	if _has_ladder(AUTOSAVE_SLOT) \
			and bool(_manager(AUTOSAVE_SLOT).peek_newest()["ok"]):
		return AUTOSAVE_SLOT
	# Nothing in the ladder, so this is either a fresh install or a phone that
	# has not autosaved since the upgrade. On the latter the pre-unification
	# rotation's two halves are both still on disk and either may be the newer
	# complete city — the exact question this method was written to answer, and
	# it must keep answering it for those files even though nothing writes them.
	var best := -1
	var best_at := -1
	for slot: int in [AUTOSAVE_SLOT, LEGACY_AUTOSAVE_SHADOW_SLOT]:
		var envelope := _legacy_envelope_quiet(slot)
		if not (envelope.get("state", null) is Dictionary):
			continue
		var at := 0
		var meta: Variant = envelope.get("meta", {})
		if meta is Dictionary:
			at = int((meta as Dictionary).get("saved_at_unix", 0))
		if at >= best_at:
			best_at = at
			best = slot
	return best


# ----------------------------------------------------------------- load path

## Restore `slot` into `sim`. Returns false and leaves `sim` untouched if the
## slot is missing or nothing in it survives the load gate.
##
## Two readers, one decision: a slot written by this build is a generation
## ladder; a slot written before the unification is a format-1 file. The ladder
## wins when both exist, because the ladder is newer by construction — the
## legacy file is never written again once a slot has been saved.
##
## And when the ladder is exhausted, the format-1 file is the last candidate,
## in exactly the spirit of doc 08 §2.9's walk: it is a pinned checkpoint that
## predates every generation. The difference for a player whose ladder is
## somehow entirely unreadable is "your city is gone" versus "your city is back
## to before the update", and it costs one `file_exists` to offer.
##
## Timed by a wrapper for the same reason `save_slot` is: five returns, and the
## recovery paths are the slow ones.
func load_slot(sim: Object, slot: int) -> bool:
	flush_writes()
	var t0 := Time.get_ticks_usec()
	var ok := _load_slot(sim, slot)
	last_load_ms = float(Time.get_ticks_usec() - t0) * 0.001
	_log_io("load", slot, "slot", last_load_ms, ok)
	return ok


func _load_slot(sim: Object, slot: int) -> bool:
	if not _valid_slot(slot):
		_fail_dict(slot, "invalid_slot")
		return false
	if sim == null or not sim.has_method("restore_state"):
		_fail_dict(slot, "no_state")
		return false
	var has_legacy := FileAccess.file_exists(_legacy_path(slot))
	if _has_ladder(slot):
		if _load_ladder(sim, slot, not has_legacy):
			return true
		if not has_legacy:
			return false
	if has_legacy:
		var recovered := _has_ladder(slot)   # the ladder was tried and lost
		if not _load_legacy(sim, slot):
			return false
		last_load_recovered = last_load_recovered or recovered
		return true
	_fail_dict(slot, "missing")
	return false


## Doc 08 §2.5–§2.9's path: candidate walk, digest gate, quarantine, section
## ladders, structural repair. `report_failure` is false when a further
## candidate remains outside the ladder — the reason is still recorded in
## `last_error`, but a failure the caller is about to recover from is not one
## the player needs a toast about.
func _load_ladder(sim: Object, slot: int, report_failure: bool = true) -> bool:
	var manager := _manager(slot)
	var city := DictSection.new(CITY_SECTION, _city_section_version(sim))
	city.migrator = _city_migrator(sim)
	var ui := DictSection.new(UI_SECTION, UI_SECTION_VERSION)
	var meta_section := DictSection.new(META_SECTION, META_SECTION_VERSION)
	manager.register_section(city)
	manager.register_section(ui)
	manager.register_section(meta_section)

	var read_t0 := Time.get_ticks_usec()
	var result := manager.load_newest()
	last_load_read_ms = float(Time.get_ticks_usec() - read_t0) * 0.001
	last_load_restore_ms = 0.0
	if not bool(result["ok"]):
		_refuse(slot, _reason_for(result), report_failure)
		return false
	if city.restored_is_empty():
		# A body with no `city` section is a save of nothing. The structural
		# repair would hand us an empty default and the sim would restore into
		# a blank city, which is worse than refusing.
		_refuse(slot, "no_state", report_failure)
		return false

	var restore_t0 := Time.get_ticks_usec()
	sim.call("restore_state", city.restored)
	last_load_restore_ms = float(Time.get_ticks_usec() - restore_t0) * 0.001
	last_loaded_ui = {} if ui.restored_is_empty() else ui.restored
	var payload: Dictionary = result["payload"]
	last_load_recovered = bool(payload["recovered"])
	last_load_lost_minutes = int(payload["lost_minutes"])
	last_load_format = FORMAT_VERSION
	repair_notes = manager.repair_notes.duplicate()
	last_error = ""
	loaded.emit(slot)
	return true


## Format 1 → format 2 reader (doc 08 §2.8's rules applied to the shell's own
## envelope). The file is `{"format":1,"meta":{…},"ui":{…},"state":{…}}` with
## no digest and no generation, so the gate it gets is the one it can pass:
## the envelope parses, the format is not from the future, and `state` is a
## dictionary. It is left EXACTLY as found — the next save to this slot writes
## a generation beside it, and the untouched original is that migration's
## `pre_migration` checkpoint at zero cost.
func _load_legacy(sim: Object, slot: int) -> bool:
	var envelope := _read_legacy_envelope(slot)
	if envelope.is_empty():
		return false
	# Doc 08 §2.8's downgrade rule: a file from a newer build is refused and
	# not touched, rather than half-read into a city.
	var format := int(envelope.get("format", LEGACY_FORMAT_VERSION))
	if format > FORMAT_VERSION:
		_fail_dict(slot, "downgrade")
		return false
	var state: Variant = envelope.get("state", null)
	if not (state is Dictionary):
		_fail_dict(slot, "no_state")
		return false
	sim.call("restore_state", state)
	var ui_state: Variant = envelope.get("ui", {})
	last_loaded_ui = ui_state if ui_state is Dictionary else {}
	last_load_recovered = false
	last_load_lost_minutes = 0
	last_load_format = format
	repair_notes = PackedStringArray()
	last_error = ""
	loaded.emit(slot)
	return true


## The slot holding the newest save — manual or autosave, whichever the player
## touched last — or -1 when nothing is saved. This is what a plain launch
## resumes from: the most recent save IS the city.
func latest_slot() -> int:
	var best := -1
	var best_at := -1
	for meta in list_slots():
		var at := int(meta.get("saved_at_unix", 0))
		if at > best_at:
			best_at = at
			best = int(meta.get("slot", -1))
	return best


## Session restore: load the newest save into `sim`. Returns the slot loaded,
## or -1 when there was nothing (a genuinely new city) or nothing would load —
## the caller treats both as "fresh founding".
##
## Newest-first with a fallback ACROSS slots, on top of doc 08's fallback
## WITHIN a slot: a damaged newest generation costs one autosave interval, and
## only a slot whose whole ladder is unreadable costs the slot.
func load_latest(sim: Object) -> int:
	var candidates := list_slots()
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("saved_at_unix", 0)) > int(b.get("saved_at_unix", 0)))
	for meta: Dictionary in candidates:
		var slot := int(meta.get("slot", -1))
		if slot >= 0 and load_slot(sim, slot):
			return slot
	return -1


## Every occupied slot's meta, ascending by slot index. Reads one manifest per
## slot — a few hundred bytes — never a city.
func list_slots() -> Array[Dictionary]:
	flush_writes()
	var out: Array[Dictionary] = []
	for slot in MAX_SLOTS:
		var meta := _slot_meta(slot)
		if not meta.is_empty():
			out.append(meta)
	return out


## Remove a slot: the generation ladder, its quarantine, the legacy file, and
## any temp orphaned by a kill mid-write. Returns true if the slot is gone.
func delete_slot(slot: int) -> bool:
	flush_writes()
	if not _valid_slot(slot):
		_fail_dict(slot, "invalid_slot")
		return false
	_managers.erase(slot)
	_remove_tree(_slot_dir(slot))
	var legacy := _legacy_path(slot)
	if FileAccess.file_exists(legacy + TEMP_SUFFIX):
		DirAccess.remove_absolute(legacy + TEMP_SUFFIX)
	if FileAccess.file_exists(legacy):
		DirAccess.remove_absolute(legacy)
	var gone := not has_slot(slot)
	if not gone:
		_fail_dict(slot, "delete_failed")
	return gone


## True if the slot holds a save — a committed generation or a legacy file.
func has_slot(slot: int) -> bool:
	flush_writes()
	return _valid_slot(slot) \
			and (_has_ladder(slot) or FileAccess.file_exists(_legacy_path(slot)))


## The file that holds this slot's city right now: the active generation when
## the ladder is live, the format-1 file when it is all the slot has, and the
## legacy path (which may not exist) when the slot is empty. Consumers that
## want a byte count or a path to show want this one.
func slot_path(slot: int) -> String:
	flush_writes()
	var active := _active_generation_file(slot)
	if active != "":
		return "%s/%s" % [_slot_dir(slot), active]
	return _legacy_path(slot)


## The slot's generation directory (doc 08 §2.5), whether or not it exists.
func slot_dir(slot: int) -> String:
	return _slot_dir(slot)


## The doc 08 manager behind a slot — its `read_manifest()`, `peek_newest()`
## and `repair_notes` are what a recovery dialog needs. The five-method API
## above is what everything else should use.
func manager_for(slot: int) -> SaveManager:
	flush_writes()
	return _manager(slot) if _valid_slot(slot) else null


# ----------------------------------------------------------------- internals

func _slot_dir(slot: int) -> String:
	return "%s/slot_%d" % [base_dir, slot]


func _legacy_path(slot: int) -> String:
	return "%s/%s" % [base_dir, FILE_TEMPLATE % slot]


func _manifest_path(slot: int) -> String:
	return _slot_dir(slot) + "/manifest.json"


func _valid_slot(slot: int) -> bool:
	return slot >= 0 and slot < MAX_SLOTS


func _has_ladder(slot: int) -> bool:
	return FileAccess.file_exists(_manifest_path(slot))


## Managers are cached because `SaveManager._init` creates directories, and a
## load screen asks about every slot.
func _manager(slot: int) -> SaveManager:
	if not _managers.has(slot):
		_managers[slot] = SaveManager.new(_slot_dir(slot), policy)
	return _managers[slot]


func _ensure_dir() -> bool:
	if DirAccess.dir_exists_absolute(base_dir):
		return true
	return DirAccess.make_dir_recursive_absolute(base_dir) == OK


func _sim_time_minutes(sim: Object) -> int:
	var clock := _sub(sim, "clock")
	if clock != null and clock.has_method("sim_time_minutes"):
		return int(clock.call("sim_time_minutes"))
	return 0


## The sim's own section ladder position, when it has one. Duck-typed so
## `sim/city_sim.gd` can grow `save_section_version()` / `migrate_save_section()`
## on its own schedule without this file changing again.
func _city_section_version(sim: Object) -> int:
	if sim != null and sim.has_method("save_section_version"):
		return int(sim.call("save_section_version"))
	return CITY_SECTION_VERSION


func _city_migrator(sim: Object) -> Callable:
	if sim != null and sim.has_method("migrate_save_section"):
		return func(data: Dictionary, from_version: int) -> Dictionary:
			var out: Variant = sim.call("migrate_save_section", data, from_version)
			return out if out is Dictionary else data
	return Callable()


## The five documented header keys, plus doc 08 §3.2's `meta` identity fields.
## `has_all` on the five is what the UI checks, so the additions are additive
## by construction.
func _meta_of(sim: Object, slot: int, reason: String) -> Dictionary:
	return {
		"slot": slot,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
		"day_index": _day_index(sim),
		"population": _int_prop(_sub(sim, "population"), "city_population"),
		"treasury": _int_prop(_sub(sim, "treasury"), "balance"),
		"format": FORMAT_VERSION,
		"save_reason": reason,
		"sim_time_minutes": _sim_time_minutes(sim),
		"app_version": str(ProjectSettings.get_setting("application/config/version", "")),
	}


func _day_index(sim: Object) -> int:
	var clock := _sub(sim, "clock")
	if clock != null and clock.has_method("day_index"):
		return int(clock.call("day_index"))
	return 0


static func _sub(owner: Object, property: String) -> Object:
	if owner == null or not (property in owner):
		return null
	var value: Variant = owner.get(property)
	if value is Object:
		return value as Object
	return null


static func _int_prop(owner: Object, property: String) -> int:
	if owner == null or not (property in owner):
		return 0
	return int(owner.get(property))


## Doc 08 §2.9's per-candidate failure codes, mapped onto this service's
## reasons. The distinction the UI needs is "this file is not a save" versus
## "this file is a save that did not survive", and only the first is a JSON
## problem.
func _reason_for(result: Dictionary) -> String:
	var failures: Array = (result.get("payload", {}) as Dictionary).get("failures", [])
	if failures.is_empty():
		return "missing"
	var first := String((failures[0] as Dictionary).get("reason", ""))
	match first:
		"unreadable": return "unreadable"
		"bad_envelope": return "bad_json"
		"downgrade": return "downgrade"
		_: return "corrupt"


# --------------------------------------------------------------- slot headers

## A slot's header without deserializing a city: the manifest's `meta` record,
## or the legacy file's leading bytes when the slot predates the ladder.
func _slot_meta(slot: int) -> Dictionary:
	var meta := _ladder_meta(slot)
	if not meta.is_empty():
		return meta
	if FileAccess.file_exists(_legacy_path(slot)):
		return _legacy_meta(slot)
	return {}


func _ladder_meta(slot: int) -> Dictionary:
	if not _has_ladder(slot):
		return {}
	var parsed: Variant = _parse_quiet(
			FileAccess.get_file_as_string(_manifest_path(slot)))
	if not (parsed is Dictionary):
		return {}
	var active: Variant = (parsed as Dictionary).get("active", null)
	if not (active is Dictionary):
		return {}
	var entry: Dictionary = active
	var meta: Variant = entry.get("meta", null)
	var out: Dictionary = (meta as Dictionary).duplicate() if meta is Dictionary else {}
	if out.is_empty():
		# A manifest written without a header — hand-edited, or by a build
		# older than this one. Pay for the decompress rather than hide the slot.
		out = _meta_from_generation(slot, String(entry.get("file", "")))
	if out.is_empty():
		return {}
	out["slot"] = slot  # the directory name is the authority on identity
	if not out.has("saved_at_unix"):
		out["saved_at_unix"] = int(entry.get("real_unix", 0))
	return out


## The expensive header read: decompress the generation and take its `meta`
## section. Only reached when the manifest has no header of its own — a
## hand-edited manifest, or one written by a build older than this file's
## header convention. A full parse rather than a brace-scan because the whole
## file has already been decompressed by then, so the scan would be a guess
## bought at no saving.
func _meta_from_generation(slot: int, file_name: String) -> Dictionary:
	if file_name == "":
		return {}
	var path := "%s/%s" % [_slot_dir(slot), file_name]
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open_compressed(path, FileAccess.READ,
			FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return {}
	var text := file.get_as_text()
	file = null
	var envelope: Variant = _parse_quiet(text)
	if not (envelope is Dictionary):
		return {}
	var body: Variant = (envelope as Dictionary).get("body", null)
	if not (body is Dictionary):
		return {}
	var meta: Variant = (body as Dictionary).get(String(META_SECTION), null)
	return (meta as Dictionary).duplicate() if meta is Dictionary else {}


## Format-1 header read: pull the leading bytes and brace-match the `meta`
## object out of them. The whole reason that file put `meta` first, and the
## only caller of [_extract_meta] that remains.
func _legacy_meta(slot: int) -> Dictionary:
	var file := FileAccess.open(_legacy_path(slot), FileAccess.READ)
	if file == null:
		return _fail_dict(slot, "unreadable")
	var head := file.get_buffer(META_SCAN_BYTES).get_string_from_utf8()
	file = null
	var meta := _extract_meta(head)
	if not meta.is_empty():
		meta["slot"] = slot
		meta["format"] = LEGACY_FORMAT_VERSION
		return meta
	var envelope := _read_legacy_envelope(slot)
	var fallback: Variant = envelope.get("meta", {})
	if fallback is Dictionary and not (fallback as Dictionary).is_empty():
		var out: Dictionary = fallback
		out["slot"] = slot
		out["format"] = LEGACY_FORMAT_VERSION
		return out
	return _fail_dict(slot, "bad_json")


static func _extract_meta(head: String) -> Dictionary:
	var key := head.find("\"meta\":")
	if key < 0:
		return {}
	var start := head.find("{", key)
	if start < 0:
		return {}
	# The meta object holds numbers and short identifiers only, so brace
	# counting cannot be fooled by a brace inside a string value.
	var depth := 0
	for i in range(start, head.length()):
		var c := head[i]
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				var parsed: Variant = _parse_quiet(head.substr(start, i - start + 1))
				return parsed if parsed is Dictionary else {}
	return {}


# ---------------------------------------------------------------- legacy IO

## Whole-file parse of a format-1 slot — only the legacy load path pays for it.
func _read_legacy_envelope(slot: int) -> Dictionary:
	var path := _legacy_path(slot)
	if not FileAccess.file_exists(path):
		return _fail_dict(slot, "missing")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _fail_dict(slot, "unreadable")
	var text := file.get_as_text()
	file = null
	var parsed: Variant = _parse_quiet(text)
	# An empty dictionary is indistinguishable from this function's failure
	# return, so it is rejected here rather than reported as a stale error.
	if not (parsed is Dictionary) or (parsed as Dictionary).is_empty():
		return _fail_dict(slot, "bad_json")
	return parsed


## A format-1 parse that reports nothing — the health-check read.
func _legacy_envelope_quiet(slot: int) -> Dictionary:
	if not _valid_slot(slot) or not FileAccess.file_exists(_legacy_path(slot)):
		return {}
	var file := FileAccess.open(_legacy_path(slot), FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file = null
	var parsed: Variant = _parse_quiet(text)
	return parsed if parsed is Dictionary else {}


## `JSON.parse_string()` pushes an engine error on malformed input; a corrupt
## save is an expected outcome here, not an engine fault, so parse through an
## instance and read the status instead.
static func _parse_quiet(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


func _active_generation_file(slot: int) -> String:
	if not _has_ladder(slot):
		return ""
	var parsed: Variant = _parse_quiet(
			FileAccess.get_file_as_string(_manifest_path(slot)))
	if not (parsed is Dictionary):
		return ""
	var active: Variant = (parsed as Dictionary).get("active", null)
	if not (active is Dictionary):
		return ""
	return String((active as Dictionary).get("file", ""))


## Depth-first removal. `DirAccess.remove_absolute` refuses a non-empty
## directory, and a slot directory has a `quarantine/` child.
##
## The listing is taken in full BEFORE anything is deleted. Removing entries
## inside a `list_dir_begin()` walk mutates the directory the walk is reading,
## and the entries it then skips are files that silently survive — a
## `delete_slot` that leaves the city behind for the next launch to resume,
## which is the worst possible way for this to fail.
static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	var files: Array[String] = []
	var dirs: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			dirs.append(entry)
		else:
			files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	for child in files:
		DirAccess.remove_absolute(path + "/" + child)
	for child in dirs:
		_remove_tree(path + "/" + child)
	DirAccess.remove_absolute(path)


func _fail_dict(slot: int, reason: String) -> Dictionary:
	last_error = reason
	failed.emit(slot, reason)
	return {}


## Record a refusal, announcing it only when nothing further will be tried.
func _refuse(slot: int, reason: String, announce: bool) -> void:
	if announce:
		_fail_dict(slot, reason)
	else:
		last_error = reason

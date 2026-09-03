# 13 — Android Native Integration & Export Pipeline

**Status:** Draft for overseer review. Complies with `00-constitution.md` (LOCKED) and with the binding rulings in `98-consistency-report.md` (see the final section for the amendments applied).
**Owns:** Android export pipeline, signing, lifecycle, the notification **platform** (channels, `AlarmManager`, permission flow, scheduling mechanics), battery/thermal policy, permissions, Play readiness, crash breadcrumbs, device test matrix. Files: `data/android.json`, `data/notifications_text.json`; save section `android`.
**Does NOT own:** persistence (doc 08 — save format, atomic write, retention, recovery), the offline cap and coarse schedule (doc 01 `data/time.json`, doc 08 fidelity policy), notification *policy* (doc 08 `data/notifications.json` — classes, budgets, quiet hours, event→class mapping), or any other system's save section.
**Code roots:** `game/android/` (GDScript shell) + `android/plugins/slacum_native/` (Kotlin AAR, build-system territory). **There is no `platform/` source layer** — constitution §3's four layers stand unchanged (report 98 C-04).
**Spec refs:** §21 (Persistent Simulation), §22 (Notifications), §27.3 (Android Native Layer), §29.6, §43, §45 Phase 4, §49, §50.

---

## 1. Overview & Goals

The sim is engine- and platform-agnostic by constitutional decree (§3): `sim/` never touches `Node`, `OS`, `Input`, or the wall clock. Everything platform-specific therefore lives in exactly one place — the **app shell**, a thin `game/` layer that sits between Android and the sim. This document specifies that shell and the build pipeline that puts it on a phone.

Four responsibilities:

1. **Export pipeline.** A reproducible, scriptable path from a git checkout to (a) a debug APK on a tethered device in under 90 seconds and (b) a signed release AAB for Play. No editor GUI in the loop.
2. **Lifecycle.** Android can background and then kill the process at any moment with no further callbacks. The shell must guarantee: *no city is ever lost*, and *returning to the app produces the WHILE YOU WERE AWAY report* (spec §21.2) computed from real elapsed time.
3. **Local notifications — the platform half.** Godot 4.7 ships **zero** notification API. The city does not run in the background, so notifications must be *scheduled at save time*. Doc 08 decides **what** is worth sending (classes, budgets, quiet hours, event→class mapping in `data/notifications.json`); this doc delivers it — Android channels, `AlarmManager`, ids, permission flow, reboot replay — through a first-party Kotlin plugin, and owns the copy in `data/notifications_text.json`.
4. **Battery, thermal, and store readiness.** A game that is checked five times a day must be cheap to leave installed. Frame caps, thermal response, and a permissions manifest so lean that the Play Data Safety form reads "collects nothing".

**Design position — RULED (report 98 §12, spec §21.1 amendment APPROVED):** there is **no background simulation, ever**. Spec §21.1's clause "when background execution occurs" is **struck**; the sim advances only when the app reopens, mathematically, from measured elapsed real time. Catch-up-on-resume is the architecture, not a compromise — see §2.1 for the argument and §9 for the ruling record.

**Success criteria for this layer:**

| Metric | Target |
|---|---|
| Cold start → interactive city (Tier B device) | ≤ 4.0 s |
| Pause sequence, shell main-thread cost | ≤ 250 ms (hard budget, §2.2) — excludes doc 08's worker-side encode/write |
| Worst-case play lost to process death | ≤ 60 s of real play — **requires doc 08 to run a 60 s foreground autosave on Android**; doc 08 §2.7 currently specifies 5 real minutes (flagged, §9) |
| Offline catch-up main-thread hitch | ≤ 12 ms per frame (sliced, §2.9), never an ANR |
| Battery drain, Tier B, Balanced 60 fps | ≤ 6.0 %/hour |
| Battery drain, Tier B, Battery-Saver 30 fps | ≤ 3.5 %/hour |
| Notification volume | doc 08's budget: global **8 per rolling 24 h**, ≥ 5 min between any two (doc 08 §2.13.2). This doc enforces nothing of its own. |
| Permissions in release manifest | 4 (§2.7) |

## 2. Mechanics

### 2.0 Toolchain (verified present on this machine)

| Component | Version / path |
|---|---|
| Godot | 4.7.2.stable — `/home/bbx/.local/bin/godot` |
| Export templates | `~/.local/share/godot/export_templates/4.7.2.stable/` (`android_debug.apk`, `android_release.apk`, `android_source.zip` present) |
| Android SDK | `~/Android/Sdk` — platform `android-37.0`, build-tools `36.0.0` + `37.0.0`, `platform-tools`, `cmdline-tools` |
| JDK | Temurin 21.0.12 LTS |
| targetSdk / minSdk / ABI | 37 / 29 / `arm64-v8a` only |

`arm64-v8a` only is deliberate: Vulkan-capable Android 10+ devices are universally 64-bit, Play has required 64-bit since 2019, and dropping `armeabi-v7a` halves the native payload (~35 MB saved) and halves build time.

### 2.1 Why catch-up-on-resume, not background simulation

The platform has spent a decade closing every door a background simulation would need:

| API level | Restriction | Effect on a background sim |
|---|---|---|
| 23+ / 28 (P) | Doze (`setAndAllowWhileIdle` ~1 fire per 9 min) + App Standby Buckets | No fine-grained ticking; wake cadence varies per user |
| 26 (O) | Background execution limits — no background services | A plain `Service` cannot run |
| 31 (S) | `SCHEDULE_EXACT_ALARM` gated; FGS cannot be started from background | Exact ticking needs a permission a game cannot justify |
| 33 (T) | `POST_NOTIFICATIONS` runtime permission | Notifications are opt-in, never guaranteed |
| 34 (U) | Foreground services require a declared *type* + permission, Play-reviewed | **No FGS type exists for "keep simulating a city"** — fatal on its own |
| 35 (V) / 36+ | FGS runtime timeouts (~6 h/24 h); tighter JobScheduler quotas; unused-app hibernation | Even an abusive FGS would be reaped; long absences kill scheduled work |
| n/a | OEM process killers (One UI, MIUI, EMUI, ColorOS) | Kills compliant apps anyway; unfixable from our side |

Even if all that were survivable, a background sim would be *worse gameplay*: partial progress makes offline outcomes depend on the user's battery settings — non-deterministic and untestable, a direct violation of constitution §5 (same save + same elapsed time ⇒ same outcome). Catch-up-on-resume instead is deterministic and **headless-testable** (the same code path runs in `tests/`), costs exactly **zero** battery while away (Play vitals stay clean — no wakelocks, no excessive wakeups), behaves identically after 10 minutes or 3 days or a reboot + force-stop, and keeps one implementation of the rules (constitution §4).

The only capability genuinely lost is *notifying the player about something we did not know at save time*. §2.4 shows that this loss is small: everything the vertical slice needs to notify about is either a deterministic timer or a pre-rolled Director event, both of which are already in the save at pause time. Truly emergent events would need a look-ahead projection, which is budget-bounded and **ships disabled in MVP** (§2.4c). **Constitutional read:** compliant. The spec §21.1 amendment is **approved** (report 98 §12) — see §9.

**Layering (report 98 C-04).** Nothing here creates a fifth source layer. The shell is `game/android/*` in GDScript plus a Kotlin AAR under `android/plugins/slacum_native/`, which is build-system territory. `sim/` reaches Android only through the injected interfaces `IClockSource`, `IFileSink` and `INotificationSink` (doc 08 §4), whose only implementations live in `game/android/`. Doc 08's proposed `platform/` directory is withdrawn.

### 2.2 Lifecycle state machine

Godot delivers Android lifecycle as `MainLoop`/`Node` notifications. The shell node `game/app_shell.gd` (autoload, `process_mode = PROCESS_MODE_ALWAYS`) handles:

```
NOTIFICATION_APPLICATION_FOCUS_OUT   → soft: pause input, mute audio bus, drop fps cap to IDLE_FPS
NOTIFICATION_APPLICATION_PAUSED      → hard: the pause sequence below
NOTIFICATION_APPLICATION_RESUMED     → the resume sequence below
NOTIFICATION_APPLICATION_FOCUS_IN    → restore audio + fps cap
NOTIFICATION_WM_GO_BACK_REQUEST      → close topmost modal, else open pause menu. NEVER quits.
NOTIFICATION_OS_MEMORY_WARNING       → drop far-LOD chunk cache, flush texture streaming (doc 11)
```

`application/config/quit_on_go_back` **must be `false`** in `project.godot`, otherwise the back button destroys the process before the pause sequence completes.

**Pause sequence — hard budget 250 ms of shell main-thread work, ordered, each step guarded.** Persistence itself is **doc 08's** (report 98 C-24): this doc no longer writes, rotates or recovers any file. It owns the *ordering* and the *budget*.

| # | Step | Main-thread budget | Notes |
|---|---|---|---|
| 1 | Stamp `android.last_pause` into `AndroidState` (§3.2) | 1 ms | unix_s, elapsed_realtime_ms, boot_id, clock ticks. **Must precede the snapshot** or the stamp misses the generation being written. |
| 2 | `SaveManager.request_save("pause")` (doc 08 §2.6) | 25 ms | Doc 08's snapshot barrier runs on the sim thread; encode → SHA-256 → zstd → `gen_NNNNNN.sav` → `manifest.json` rename (the commit) run on doc 08's worker. |
| 3 | Build the notification candidate list — classes (a) + (b) only in MVP (§2.4) | 80 ms | Droppable. Guarded by the recorded rolling mean, not a mid-step abort. |
| 4 | `NotificationBridge.cancel_all()` then `schedule()` × the plan doc 08 accepted | 30 ms | JNI calls; the plan size is doc 08's budget, not ours. |
| 5 | Await doc 08's manifest commit | ≤ 110 ms worst case | Overlapped with steps 3–4: doc 08 budgets ≤ 120 ms for encode+write and that clock starts at ~26 ms, so ~10 ms of real waiting is typical. |
| 6 | Delete `user://runtime/session_open.flag` (clean-exit marker, §2.11) | 1 ms | |
| | slack | 13 ms | |

Arithmetic: nominal `1 + 25 + 80 + 30 + 10 + 1 = 147 ms`; worst case `1 + 25 + 80 + 30 + 110 + 1 = 247 ms ≤ 250 ms`. Steps 1, 2, 5 and 6 always complete (correctness beats budget); steps 3–4 are the only droppable ones.

**Interface requirement on doc 08.** `request_save("pause")` must return once the snapshot barrier is done and complete encode/write asynchronously, so the shell can overlap steps 3–4 with the write. Doc 08 §2.6 permits blocking up to 400 ms on a `pause` trigger; blocking synchronously for 400 ms *before* returning would blow this budget on its own. Flagged in §9.

**Autosave cadence is doc 08's** (`CheckpointPolicy`, doc 08 §2.7). This doc no longer defines an interval; it only supplies the Android-specific triggers — `NOTIFICATION_APPLICATION_PAUSED`, `NOTIFICATION_APPLICATION_FOCUS_OUT` — as `request_save` reasons. The ≤ 60 s process-death goal in §1 needs doc 08's foreground autosave at 60 s on Android rather than its current 5 real minutes (§9).

**Process-death safety.** After `onStop`, Android may kill the process with no callback whatsoever, so nothing important may happen in `NOTIFICATION_WM_CLOSE_REQUEST`, `_exit_tree`, or a destructor — those are best-effort on Android and are not part of the design. The save requested at pause is the *only* Android-specific recovery point, and it is requested before the process is at risk. Torn writes are impossible by doc 08's construction: generation files are immutable once renamed and the `manifest.json` rename is the commit point, so a kill at any moment leaves the previous generation active plus one orphan. Corruption handling — the 7-check load gate, quarantine-never-delete, the 6 unpinned + 2 pinned retention ladder and the repair notes — is doc 08 §2.7/§2.9 and is **not** reimplemented here.

### 2.3 Resume: measuring elapsed real time

> **As built:** §10.7. Both bounds now exist in `AndroidLifecycle`; the two places
> where the implementation reads this pseudocode deliberately are recorded there.

The sim never reads a clock (constitution §4); the shell measures once and hands the sim a tick count.

Wall clock (`Time.get_unix_time_from_system()`) can jump — the user changes the device clock, a timezone transition happens, NTP corrects. `Time.get_ticks_msec()` uses `CLOCK_MONOTONIC`, which **does not advance while the device is in deep sleep**, so it is useless for offline measurement. The plugin therefore exposes `SystemClock.elapsedRealtime()` (advances during sleep, resets on reboot) plus a `boot_id`, giving a monotonic cross-check.

```
raw_s = now_unix_s - stamp.unix_s

if raw_s < 0:
    anomaly = "clock_backwards"; elapsed_s = 0
elif plugin_available and stamp.boot_id == current_boot_id:
    mono_s   = (elapsed_realtime_ms_now - stamp.elapsed_realtime_ms) / 1000.0
    elapsed_s = min(raw_s, mono_s + clock_tolerance_s)      # tolerance = 120
else:
    elapsed_s = raw_s                                        # rebooted or plugin absent

offline_cap_s = time_json.catchup.offline_cap_real_ms / 1000        # doc 01, = 43 200 s
elapsed_s   = clamp(elapsed_s, 0, offline_cap_s)             # 12 real hours
game_minutes = int(elapsed_s * time_scale_gmin_per_rsec * offline_rate)   # 1.0 * 1.0
ticks        = game_minutes * GameClock.TICKS_PER_MINUTE                  # ×4
```

**The offline cap is not ours** (report 98 C-19). It is `catchup.offline_cap_real_ms = 43 200 000` in `data/time.json`, owned by doc 01: **12 real hours = 720 game-hours = 30 game-days**. This doc reads it and defines no constant of its own; the deleted `offline_max_hours` used to live in §8 and is gone. Surplus beyond the cap is discarded and reported, never banked (constitution §4).

`offline_rate` exists so doc 08 can slow offline progression without every other formula in this doc changing; default `1.0`. It multiplies *credited* time only — it never changes the cap.

**Branching on `elapsed_s`:**

| Range | Path | UI |
|---|---|---|
| `< 60 s` | Fine ticks: `sim.tick()` × `elapsed_s × 4`, capped at 240 ticks, executed inside one frame | None — seamless |
| `60 s … 12 h` | Coarse offline path (`CitySim.begin_catchup(plan)` → `CatchUpCursor`, under doc 08's fidelity bands), sliced (§2.9) | Progress veil → WHILE YOU WERE AWAY report |
| `> 12 h` | Same, clamped to 12 h | Report additionally shows "Your city ran for 30 game-days; N hours of your absence were beyond the cap and were not simulated" |

The 60 s threshold is exactly one coarse step, since 1 real second = 1 game minute ⇒ 60 real s = 1 game hour = the coarse granularity.

**Worked example — at the cap exactly.** Player backgrounds at `unix_s = 1 800 000 000` with `GameClock.ticks = 49 920` (game-minute 12 480 = day 8, 16:00). They return at `unix_s = 1 800 043 200`.
`raw_s = 43 200` (12 real hours). No reboot; `mono_s = 43 190` → `elapsed_s = min(43 200, 43 310) = 43 200`, which is exactly `offline_cap_s`.
`game_minutes = 43 200` → 720 game-hours = **30 game-days**. `ticks = 172 800`. New `GameClock.ticks = 222 720`, game-minute 55 680, day 38, 16:00. Coarse path executes 720 one-game-hour steps.

**Worked example — over the cap.** A three-day absence: `raw_s = 259 200` (72 real hours). `elapsed_s = clamp(259 200, 0, 43 200) = 43 200`; `216 000 s = 60 real hours` are discarded. The city still advances exactly 720 game-hours = 30 game-days — the same as the 12-hour absence above — and the report says so. This is the whole point of C-19's ruling: the old 72-hour cap would have credited 4 320 game-hours = **180 game-days** for the same absence, handing back six months of city and breaking doc 03's offline/online income guardrail G4, doc 07's fairness budget and doc 08's damage-cap arithmetic at once.

**Cold start after process death** uses the identical code, reading `stamp` out of the loaded save instead of memory. There is no second implementation.

### 2.4 Notification scheduling: the schedule-at-save-time model

Because nothing runs while the app is closed, every notification must be *predicted at pause time*. Report 98 C-23 splits the problem by **predictability class**, and the split is what makes the horizon question disappear:

| Class | Needs a projection? | Scheduling horizon | MVP |
|---|---|---|---|
| (a) deterministic timers | **No** — the fire time is already in the save | the full offline cap, **12 real hours** (43 200 s = 720 game-hours) | ships |
| (b) pre-rolled Director forecast events | **No** — the onset is already in the save | the full offline cap, **12 real hours** | ships |
| (c) emergent events | Yes — only running the sim reveals them | budget-bounded, **12–60 coarse steps** (§2.4c) | **disabled** |

Classes (a) and (b) carry every notification the vertical slice needs, at the full cap, for free. The previous version of this doc ran `advance_coarse_hours(1) × plan_horizon_hours = 24` and called the result "24 real hours of look-ahead": **at the locked 60× scale, 24 coarse game-hours = 24 REAL MINUTES** (24 game-hours × 60 game-min/game-h ÷ 60 game-min per real min = 24 real minutes). A true 24-real-hour horizon would need `24 × 60 = 1 440` coarse steps — at doc 08 §2.12's cost model that is `1 440 × 27.3 ms ≈ 39 s` raw, or `1 440 × 55 ms ≈ 79 s` with allocation overhead, against an **80 ms** pause budget: three orders of magnitude out. The horizon was never real; the ruling replaces it with the table above. `plan_horizon_hours` is deleted from §8.

**(a) Deterministic timers — free.** Construction/upgrade completion, land development completion, research completion. The sim already knows the completion game-minute. Conversion is the identity at default scale:

```
real_delay_s   = (event_gmin - now_gmin) / (time_scale_gmin_per_rsec * offline_rate)
fire_at_unix_s = now_unix_s + real_delay_s - lead_s[class]
```

*Worked:* a Level-3 office completes at game-minute 14 760; now 12 480. Δ = 2 280 game-min → **2 280 real seconds = 38 min**. Class `routine`, `lead_s = 0` → fires 38 min after backgrounding.

*Worked, at the horizon:* a land development completes at game-minute 54 480; now 12 480. Δ = 42 000 game-min → **42 000 real seconds = 11 h 40 m**, which is ≤ `offline_cap_s = 43 200` → **scheduled**. A timer 44 000 real seconds out is **dropped**: the cap would clamp the catch-up before it ever fired, so the alarm would describe a future the sim never reaches.

**(b) Pre-rolled forecastable events — requires doc 07.** The Disaster Director must commit its next forecastable event *at roll time*, not at onset. Interface demanded of doc 07 in §5. Given that, the storm exists in the save before the player leaves, and its warning can be scheduled — also out to the full 12-hour cap, with no projection.

*Worked:* Director has a severe thunderstorm with `onset_gmin = 13 920` and `warning_lead_gmin = 180`. Warning game-minute = 13 740; Δ from now (12 480) = 1 260 game-min = **1 260 real seconds = 21 min**. Class `critical`.
Doze slop guard: require `real_delay_s ≥ doze_slop_s (900) + min_useful_lead_s (300) = 1200`. 1 260 ≥ 1 200 → **accepted**. Had the storm been 15 real minutes out, the warning would arrive after landfall and is **dropped** rather than shown late.

**(c) Emergent events — requires a projection. DISABLED IN MVP.** Blackouts, fires, crime surges, treasury thresholds. These are knowable only by running the sim — and because of constitution §5 determinism, *running it now produces exactly the same events as running it later*. So the shell would run the offline path on a throwaway sim and read off the events:

```
projection_steps = clamp(floor(projection_budget_ms / measured_coarse_ms), 12, 60)

plan_sim = Sim.deserialize(save_dict)          # fresh instance from the dict doc 08 just snapshotted
events   = []
for h in range(projection_steps):              # coarse steps == game-hours == real minutes
    plan_sim.advance_coarse_hours(1)
    events += [e for e in plan_sim.drain_events() if e.notify_class != NONE]
discard plan_sim
```

**The horizon is bounded by budget, not by wishful hours.** One coarse step = 1 game-hour = **1 real minute** of look-ahead at 60×, so the clamp `[12, 60]` buys **12–60 game-hours = 12–60 real minutes** of emergent look-ahead. `measured_coarse_ms` comes from doc 08's Phase-0 benchmark `tests/perf/test_coarse_step_cost.gd` (task P0-27, report 98 C-21) — never from a guess in this doc.

Generating formula: `projection_steps = clamp(floor(80 / measured_coarse_ms), 12, 60)`; realised cost `= projection_steps × measured_coarse_ms`.

| `measured_coarse_ms` | `floor(80 / m)` | `projection_steps` | Realised cost | Verdict |
|---|---|---|---|---|
| 55.0 (doc 08 §2.12 per-entity estimate) | 1 | 12 (floor) | 660 ms | **8× over the 80 ms budget → class (c) stays off** |
| 12.0 | 6 | 12 (floor) | 144 ms | over budget → off |
| 6.67 (break-even) | 12 | 12 | 80 ms | the point at which class (c) becomes affordable |
| 4.00 | 20 | 20 | 80 ms | 20 real minutes of look-ahead |
| 1.33 | 60 | 60 (ceiling) | 80 ms | 60 real minutes — the maximum this doc will ever buy |
| 0.60 (doc 01's retired estimate) | 133 | 60 (ceiling) | 36 ms | ceiling binds, not budget |

So: **class (c) ships disabled** (`projection_enabled: false`). It may be switched on only when P0-27 measures `measured_coarse_ms ≤ 6.67`, and even then it buys minutes, not hours. Classes (a) and (b) carry every notification the slice needs, at the full 12-hour cap. The live sim is never touched by a projection, so a surviving process resumes from correct in-memory state.

**Budget guard (retained).** When enabled, the shell records the measured pause cost of the projection; if the 5-sample rolling mean exceeds `pause_projection_abort_ms = 120`, projection is disabled for the rest of the session and only classes (a) and (b) are scheduled (`projection_degraded = true` recorded in `android.diagnostics` for telemetry). Note the floor of 12 means the guard can trip on the very first pause — `floor(80/m)` clamps *up* to 12, it does not shrink below it.

### 2.5 The notification platform: channels, ids, delivery

**Policy is doc 08's; this section is the platform half only** (report 98 C-71). Doc 08 owns the four priority classes, the token buckets, the min-gaps, quiet hours, coalescing and the event→class table in `data/notifications.json`. **This doc's parallel rate limiter is deleted** — the old `max_per_wake` / `max_p3_per_wake` / `min_gap_s` / `max_per_day` / `quiet_shift_max_s` constants are gone from §8; the equivalents live in `data/notifications.json` (doc 08 §3.3) and the in-app banner gate lives in `data/ui.json` under `in_app_alerts` (doc 12). There is exactly one push budget in the game: doc 08's.

**Class → Android channel map** (this doc owns the right-hand side):

| Doc 08 class | Channel id | Android importance | Behaviour | MVP |
|---|---|---|---|---|
| `P1_critical` | `slacum_critical` | `IMPORTANCE_HIGH` | sound + vibrate | created |
| `P2_important` | `slacum_important` | `IMPORTANCE_DEFAULT` | sound, no vibrate | created |
| `P3_routine` | `slacum_routine` | `IMPORTANCE_LOW` | silent | created |
| `P4_ambient` | `slacum_ambient` | `IMPORTANCE_MIN` | silent | **not created** — doc 08 ships P4 disabled |

Channels are created once at plugin init (mandatory since API 26) and never mutated afterwards — importance is user-owned after creation. P4's channel is deliberately absent rather than created-and-silent: an unused row in the system settings screen is user-visible clutter. If doc 08 ever enables P4, adding `slacum_ambient` is a plugin-init change, not a schema change.

**What examples belong to which class is doc 08's `events` table**, not this doc's. The thresholds that used to sit in §8 (`blackout_demand_fraction`, `fire_unresolved_gmin`, `district_stability_critical`, `water_break_demand_fraction`, `large_construction_cost`) are deleted: the events themselves are emitted by their owning systems (doc 04 blackouts, doc 06 fires, doc 09 stability, doc 05 water, doc 02 construction) and classified by doc 08's table.

**The delivery contract.** Doc 08's `NotificationPlanner.plan()` returns an accepted, budgeted, quiet-hours-resolved list. This doc:

1. supplies the platform inputs doc 08's planner cannot obtain from `sim/` — the device-local UTC offset for quiet hours (`Time.get_time_zone_from_system().bias`, the only device-local wall-clock read in the game), `now_unix_s`, and `notifications_enabled()`;
2. converts each accepted entry's `fire_unix` into an `AlarmManager` alarm;
3. assigns the platform alarm id and returns it, so doc 08's `notifications.scheduled[].alarm_id` is truthful;
4. renders title/body from `data/notifications_text.json` (owned here) using doc 08's conventional keys `n_<event>_title` / `n_<event>_body`;
5. reports back what actually fired.

**Doze slop guard (platform, ours).** Alarms are inexact by choice (§2.6), so any entry whose `real_delay_s < doze_slop_s (900) + min_useful_lead_s (300) = 1 200 s` is **dropped before scheduling** rather than delivered after the event it warns about. This is a delivery-feasibility filter, not a budget: doc 08 has already decided the item is worth sending.

**Ids.** `cancel_all_notifications()` runs before every batch, so ids need only be unique within a batch: `id = id_base + index = 1000 + index`. This makes the plugin's persisted schedule trivially replaceable and removes a whole class of stale-notification bugs.

**On resume:** cancel everything immediately (`cancel_all_notifications()`), because every scheduled item now describes a future that the player has just changed; doc 08 re-plans. Log which ones fired (`delivered_log`, §3.2) for doc 08's report reconciliation ("we told you about the storm") and for tuning.

**Never notify in the foreground.** If the app is running, a P1 is an in-game alert owned by doc 12 (`in_app_alerts` in `data/ui.json`).

### 2.6 The `SlacumNative` Kotlin plugin

> **As built:** §10.6. v1 ships the time and power methods only —
> `elapsed_realtime_ms`, `boot_id`, `thermal_status` + its push signal, and
> sustained performance mode. The notification, permission and alarm half of the
> surface below is Milestone B and is not written yet.

**What ships built-in with Godot 4.7 on Android: nothing relevant.** There is no notification API, no thermal API, no power-save query, no `elapsedRealtime`, no runtime-permission request flow beyond `OS.request_permission()` (which handles the request but gives no rationale/permanent-denial state). Third-party notification plugins exist but are unmaintained across Godot minor versions and CLAUDE.md rules out external plugins. We write our own — it is ~450 lines of Kotlin.

**Plugin requires the Gradle build template.** `res://android/plugins/slacum_native.gdap` + `slacum_native.aar`:

```ini
[config]
name="SlacumNative"
binary_type="local"
binary="slacum_native.aar"

[dependencies]
local=[]
remote=["androidx.core:core-ktx:1.13.1"]
custom_maven_repos=[]
```

**Kotlin surface** (`org.godotengine.godot.plugin.GodotPlugin`, methods `@UsedByGodot`):

```kotlin
// permissions
fun notifications_enabled(): Boolean     // NotificationManagerCompat.areNotificationsEnabled()
fun permission_state(): String           // granted|denied|denied_permanent|never_asked|unsupported
fun request_notification_permission()    // -> signal permission_result(granted: Boolean)
fun open_app_notification_settings()     // ACTION_APP_NOTIFICATION_SETTINGS
// scheduling
fun schedule_notification(req: Dictionary): Int   // returns id, or -1
fun cancel_notification(id: Int); fun cancel_all_notifications(); fun scheduled_ids(): IntArray
// time
fun elapsed_realtime_ms(): Long          // SystemClock.elapsedRealtime()
fun boot_id(): String                    // hash of /proc/sys/kernel/random/boot_id
// device / power
fun thermal_status(): Int                // PowerManager.getCurrentThermalStatus(), 0..6, API 29+
fun is_power_save_mode(): Boolean; fun battery_percent(): Int; fun is_charging(): Boolean
fun display_refresh_hz(): Int; fun set_sustained_performance(on: Boolean)
// launch payload ("" if not opened from a notification)
fun consume_launch_payload(): String
// launch ARGUMENTS (D-20) — the Intent's `command_line_params` string array and
// its `args` string, verbatim, because the export template drops both before
// `OS.get_cmdline_user_args()` sees them. `game/dev_args.gd` owns the merge.
fun launch_args(): Array<String>
// signals: permission_result(Boolean), thermal_status_changed(Int), notification_opened(String)

// schedule_notification request dictionary:
// { "id":1000, "at_unix_ms":1800045600000, "channel":"slacum_critical", "group":"storm",
//   "title":"Severe thunderstorm warning",
//   "body":"Storm reaches Slacum City in about 3 hours. Crews on standby?",
//   "payload":"disaster:thunderstorm:d_0031" }
```

**Implementation decisions:**

- **`AlarmManager.setAndAllowWhileIdle(RTC_WAKEUP, …)` for every notification. Inexact, always.** We deliberately do **not** request `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM`: Play restricts `USE_EXACT_ALARM` to alarm-clock and calendar apps, and a city builder cannot justify it — requesting it risks store rejection. Consequence: up to ~15 min of Doze slop, which the `doze_slop_s = 900` guard in §2.5 already accounts for. Notification copy therefore **never states an exact time** — "in about 3 hours", never "at 19:00".
- `PendingIntent` flags `FLAG_IMMUTABLE or FLAG_UPDATE_CURRENT` (mutability is explicit since API 31).
- `AlarmReceiver : BroadcastReceiver` builds the notification with `NotificationCompat` and posts through `NotificationManagerCompat`. Tap → `PendingIntent` to `com.godot.game.GodotApp` with extra `slacum_payload`; if the process is alive the plugin emits `notification_opened`, otherwise the payload is stashed for `consume_launch_payload()`.
- **Reboot survival.** Alarms are cleared on reboot. The plugin owns `filesDir/notif_schedule.json`, rewritten on every schedule/cancel; `BootReceiver` (`RECEIVE_BOOT_COMPLETED`) replays entries whose `at_unix_ms` is still in the future and drops the rest. `am force-stop` also cancels alarms and *cannot* be recovered from until the user launches the app — accepted and documented, not worked around.
- The plugin ships its own `AndroidManifest.xml` declaring its receivers and its permissions, so manifest merging keeps the plugin self-contained and `export_presets.cfg` needs no `custom_permissions` entries. ~~**Half of this is measured false (2026-08-21)** — the four `<uses-permission>` elements do not merge; `dumpsys package` on the installed APK lists no requested permissions at all.~~ **THAT ANNOTATION IS ITSELF FALSE, and it is reversed rather than deleted because it cost a session (Wave 14, report 98 §29 RR-70).** Re-measured on four locally built debug APKs with `aapt2 dump permissions`: a build whose AAR declares the four and whose preset does not **requests all four**, so merging carries `<uses-permission>` exactly as this bullet says. The failing build had **neither** source — an AAR that predated this permission block, which is the same stale-AAR root cause the session before it had just fixed by tracking the binary. `export_presets.cfg` now carries the four as well (§2.7, §3.4), and the redundancy is the point rather than the fix: with it, a stale AAR can no longer take a runtime permission with it.

**Bounded scope.** The plugin contains no game logic, no scheduling policy, and no strings — GDScript decides *what* and *when*; Kotlin only knows *how*. That keeps the untestable-headlessly surface as small as possible.

### 2.7 Permissions

Release manifest, complete:

| Permission | Type | Why |
|---|---|---|
| `android.permission.POST_NOTIFICATIONS` | runtime (API 33+) | All notifications |
| `android.permission.RECEIVE_BOOT_COMPLETED` | normal | Re-arm alarms after reboot |
| `android.permission.WAKE_LOCK` | normal | Godot keep-screen-on while playing |
| `android.permission.VIBRATE` | normal | Haptics (spec §49) + P1 channel vibration |

**Deliberately absent:** `INTERNET` (MVP is fully offline — this is what lets the Data Safety form say "no data collected"), `SCHEDULE_EXACT_ALARM`, `USE_EXACT_ALARM`, `FOREGROUND_SERVICE*`, `ACCESS_NETWORK_STATE`, any storage permission, `QUERY_ALL_PACKAGES`, and `com.google.android.gms.permission.AD_ID` (if any future dependency injects it, strip it with `tools:node="remove"`).

~~Godot injects `INTERNET` into **debug** exports for the remote debugger~~ — **not on the Gradle path (§10.8): the debug APK declares zero permissions.** The release build must not have `INTERNET` either, which is what the `aapt2 dump permissions` gate in §2.10 enforces on every release; it now passes on debug builds too, and the consequence for the editor's remote debugger is recorded in §10.8.

**POST_NOTIFICATIONS runtime flow.** Never ask on first launch — cold permission prompts convert poorly and a denial on Android 13+ is effectively permanent after two dismissals.

```
1. Trigger point: the FIRST time the shell wants to schedule anything, which in practice is
   the end of onboarding step 10 ("Upgrade one building" → first construction timer exists).
2. If plugin.notifications_enabled() → done, state = granted.
3. Show an in-game rationale modal (ours, not the system's):
     "Get told when your city is in trouble."
     "Storm warnings, major outages, and finished construction — nothing else."
     [ Turn on ]  [ Not now ]
4. [Turn on] → plugin.request_notification_permission() → system dialog
             → signal permission_result(granted) → persist state.
5. [Not now] → state = denied, asked_count += 1. Do not ask again this session.
6. denied_permanent (system auto-denies): stop prompting forever. Settings shows
   "Notifications: Off — Open system settings" → open_app_notification_settings().
7. Re-prompt policy: allowed at most reprompt_max (2) times in the app's lifetime,
   only if (now - last_asked) >= reprompt_cooldown_days (7) AND the player has just
   returned to a city where a P1 event occurred offline. The modal then reads
   "You missed a citywide blackout. Want a heads-up next time?"
8. API < 33: no runtime permission exists; notifications_enabled() still reports the
   user's system toggle, so the Settings row stays truthful.
```

> **As built (Wave 18, PA-14 · A91-D-69) — the eight steps had a state machine
> and no caller.** `game/notifications/permission_flow.gd` implemented all eight
> and had been tested since Wave 11; `grep -rn "note_trigger\|request_rationale\|
> should_prompt\|\.accept(\|\.decline(" game/ ui/ | grep -v permission_flow.gd`
> returned **nothing**, and `main.gd` connected only `permission_result → confirm`.
> So on a targetSdk-33+ device the app had never asked, could not post, and doc
> 13 §11.10's "no notification has ever been posted on real hardware" was the
> consequence rather than a coincidence. Five seams close it:
>
> | step | seam | file |
> |---|---|---|
> | 1 trigger | `upgrade_started_sim` **or** `incident_resolved` in the batch | `Main._note_permission_trigger` |
> | 3 modal | next idle frame, on a frame nothing else owns | `Main._pump_permission_prompt` → `UIRoot.present_permission_rationale` → `ui/permission_sheet.gd` |
> | 4/5 answer | TURN ON → `accept()`, NOT NOW → `decline()`, **BACK → neither** | `Main._on_permission_answered` |
> | 6 fallback | S10's `notification_permission` row, four states (doc 12 §2.13) | `Main._on_permission_row_tapped` |
> | 7 evidence | a P1 in the batch an **absence** produced, while `notifications_enabled()` is false | `Main._note_permission_evidence`, off the router's own classification, gated on `_draining_offline` |
>
> **`building_placed_sim` is deliberately not a trigger** even though it creates a
> construction timer: the tutorial has the player place a house inside its first
> minute, and asking there is the cold prompt this section exists to forbid, with
> extra steps. Step 1's own words — *"the end of onboarding step 10 (`Upgrade one
> building`)"* — are what `upgrade_started_sim` means.
>
> **BACK is not step 5.** Doc 12 §2.2 makes BACK the universal "close the thing
> in front of me"; a player who reached for it did not answer a question, and
> counting it as a dismissal would spend one of Android's two chances silently.
> `PermissionSheet.answered` is emitted by the two buttons and never by `close()`.
>
> **…and that has a trap in it, which cost this lane a bug.** `_asked_this_session`
> is set by `accept()` and `decline()` and by *nothing else* — deliberately — so
> `should_prompt()` is **still true on the very next frame after a BACK**. A pump
> that trusted it alone re-opened the sheet every frame and handed the player a
> modal they could not get out of. The shell therefore keeps its own
> `_permission_prompt_shown` guard, and the two rules are not the same rule: the
> flow's counts **chances spent**, the shell's counts **sheets shown**. S10's row
> is not *gated* by the shell's guard — a row that did nothing for the rest of
> the session would be the control doc 12 §2.13 forbids — but it does **raise**
> it, because the row's own `note_trigger()` is exactly what would otherwise let
> the pump re-open a sheet the player had just backed out of.
> `tests/test_android_notifications.gd::test_31b` walks 300 idle frames after the
> pump and 100 after the row, and asserts one modal each and `asked_count == 0`.
>
> **Step 7's "offline" is load-bearing, and the gate is one flag.** The evidence
> hook rides `_on_sim_batch`, which every batch goes through — including the live
> ones. Recording a foreground P1 as *missed* would let the second prompt say
> *"you missed a citywide emergency"* about a storm the player sat through, which
> is a lie told to obtain a permission and is the one thing this flow exists not
> to do. `Main._draining_offline` is set only around `_finish_catchup`'s drain of
> the absence's batch, and `_note_permission_evidence` refuses everything else.
>
> **The counters are device-scoped** (`user://settings.cfg`, section
> `permission`, doc 08 §2.5), and that is a correctness argument rather than a
> convenience: Android's two dismissals are spent per INSTALL, so a counter that
> rode in the city's save would hand a player who deleted their city a third
> prompt the system will not show — a modal that opens a dialog which never
> appears. `PermissionFlow.load_device()` runs before anything can ask;
> `save_device()` runs on the answer, not at the next autosave.
>
> **Still unverified on hardware.** Everything above is derived from code, data
> and the headless suite; `dumpsys notification` after a pause is the check this
> ruling is owed, and doc 99 §4.1 already lists "the permission dialog never
> appearing" among the on-device claims no lens has seen.

> **As built (Wave 14) — the four permissions have TWO sources now, and the reason is not the one this wave was sent to fix.** The third Fold session concluded that the plugin manifest's `<uses-permission>` elements never reach an APK and that the preset is the only source; **that is measured false** (report 98 §29 RR-70). The 2×2, `aapt2 dump permissions` on four locally built debug APKs:
>
> | plugin AAR declares the four | `export_presets.cfg` declares the four | APK requests |
> |---|---|---|
> | yes | yes | **4** ← shipped |
> | yes | no | **4** |
> | no | yes | **4** |
> | no | no | **0**, with the plugin meta-data and both receivers still merged |
>
> Either source suffices, and the bottom row is the phone reading reproduced exactly — so the APK on the Fold was built against an AAR that predated the plugin manifest's permission block. Same stale-AAR root cause as the session before it.
>
> **The presets carry the four anyway, on all three, and that is a deliberate redundancy rather than a fix:**
>
> ```ini
> permissions/custom_permissions=PackedStringArray()
> permissions/post_notifications=true
> permissions/receive_boot_completed=true
> permissions/vibrate=true
> permissions/wake_lock=true
> ```
>
> With it, the APK's permission set no longer depends on a 36 KB binary being current — it depends on a committed, diffable text file the exporter reads directly, and a stale AAR degrades from *silently drops a runtime permission* to *nothing at all*. `custom_permissions` stays empty: all four are in 4.7.2's own permission table (`"permissions/" + PERMISSION.to_lower()` is the option key), so the boolean flags are the idiomatic spelling and the "presets add no permissions of their own" assertion keeps its meaning.
>
> Shipped state, read back off the binary (`godot --headless --export-debug "Android"`, build-tools 36.1.0):
>
> ```
> $ aapt2 dump permissions build/slacum-debug.apk
> package: com.slacumcity.game
> uses-permission: name='android.permission.POST_NOTIFICATIONS'
> uses-permission: name='android.permission.RECEIVE_BOOT_COMPLETED'
> uses-permission: name='android.permission.VIBRATE'
> uses-permission: name='android.permission.WAKE_LOCK'
> ```
>
> Four, exactly, and **no `INTERNET`** — which the preset flags do not put back. `aapt2 dump xmltree` on the same binary shows `org.godotengine.plugin.v2.SlacumNative → com.slacumcity.nativeplugin.SlacumNative` and both receivers, so nothing was traded for it.
>
> **What this does NOT establish, and the flow above still waits on it:** every line of the POST_NOTIFICATIONS flow remains untested on a device. Nothing here proves that step 4's dialog appears, that `permission_result` arrives, or that a channel is created — only that the permission the dialog is for is now requested by every artefact this repository can build, from two independent sources. Doc 91 §13's remaining item is one device session.
>
> **The headless gate that would have caught the stale AAR's consequence now exists.** `tests/test_release_plumbing.gd` asserted what the plugin manifest AUTHORS and that `custom_permissions` was empty; it had no assertion at all about what the presets REQUEST, so the second source could go missing in silence. `test_every_preset_requests_exactly_the_four_permissions` closes that.

### 2.8 Battery, frame pacing, and thermal policy

> **The modal row is implemented (2026-09-02, report 98 RR-154).** It was
> authored here and never built, and the gap had a symptom: with a sheet up the
> quality ladder read the menu's headroom as the world's and took a rung back
> every 30 s, resizing the 3D render target under a composited panel and drawing
> a static band across the player's screen. `PerfGovernor.set_suspended()` is
> the gate; `UIRoot.modal_open()` is the question; `game/main.gd` asks it once a
> frame before the frame is submitted.

**Frame cap** (`Engine.max_fps`), resolved every 2 s from the highest-priority active rule:

| Rule | Cap | Extra effects |
|---|---|---|
| Modal/menu open (3D viewport not visible) | `idle_fps` 30 | `SubViewport.render_target_update_mode = UPDATE_DISABLED` |
| Thermal `CRITICAL`(4) / `EMERGENCY`(5) / `SHUTDOWN`(6) | 30 | Force Performance preset; one-time toast |
| Thermal `SEVERE`(3) | 30 | Glow off, particles ×0.25, shadows off |
| Thermal `MODERATE`(2) | 45 | Shadow distance ×0.7, particles ×0.5 |
| Device power-save on, or battery < 20 % and not charging, or user Battery Saver toggle | 30 | Weather VFX ×0.5, glow half-res, night lights LOD −1 |
| High-refresh opt-in (user, flagship only) | `min(display_hz, 120)` | |
| Default | `min(display_hz, 60)` | |

Thermal is push-based: the plugin registers `PowerManager.addThermalStatusListener` (API 29+, exactly our minSdk) and emits `thermal_status_changed`. Hysteresis: a *downward* (cooler) transition only applies after `thermal_recover_s = 30` at the lower status, so the preset does not oscillate.

**Frame pacing.** Godot 4.3+ integrates Swappy. Set in `project.godot`:

```ini
display/window/frame_pacing/android/enable_frame_pacing=true
display/window/frame_pacing/android/swappy_mode=2      ; auto-fps + auto-pipeline
display/window/vsync/vsync_mode=1                      ; VSYNC_ENABLED, always
display/window/energy_saving/keep_screen_on=true
application/config/quit_on_go_back=false
```

Capping at 60 on a 120 Hz panel is the single biggest battery lever available (roughly halves GPU work); the high-refresh toggle is off by default and lives under Settings → Graphics with the label "High refresh rate (uses more battery)".

#### The rate is DECLARED, not merely capped — RR-126, Wave 17 (2026-09-01)

**The half of this subsection that was never built.** Every rule in the table
above resolves to a number written into `Engine.max_fps`, and until this wave
**nothing told the display about it**. `vsync_mode=1` is a swapchain property and
Swappy is a *consumer* of the refresh rate, not a declarer of it, so on the
reference device — a Galaxy Z Fold 6 whose inner panel is **1856 × 2160 LTPO,
1–120 Hz adaptive** — the platform's only input to its mode policy was the app's
observed present cadence. The panel therefore re-derived its mode whenever the
cadence changed, and an adaptive re-time part-way down a scan is a horizontal
band. Doc 93 §AE has the analysis and the falsifier; the player's own verdict
after days on the Aug-21 build is *"tearing only happens in the sub menus"*,
which is exactly where a workload step lands on a still image.

**What now happens.** `game/render/refresh_pin.gd` is fed the same number the
frame cap is, and declares it:

| what | where | how |
|---|---|---|
| the app's own rate | `Surface.setFrameRate(fps, FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)` | API 30+, cast on the Vulkan surface Godot presents to, and **re-cast on `onVkSurfaceCreated` / `onVkSurfaceChanged`** — a vote lives on the surface and dies with it, and the Fold's fold/unfold recreates it |
| the panel's mode | `window.attributes.preferredRefreshRate` + `preferredDisplayModeId` | the smallest supported mode at the current resolution that is an integer multiple of the rate; `preferredDisplayModeId` is set only for a same-resolution mode, because anything else is a reconfiguration rather than a refresh-rate switch |

**The mode rule**, table-tested in `tests/test_refresh_pin.gd` and written in
`RefreshPin.choose_refresh_hz()`: the **smallest integer multiple** at or above
the cap (60 → 60 and 30 → 60 on a {60, 120} panel; 45 → 90 on {60, 90, 120});
failing that the **fastest mode at or above** it (45 → 120 on {60, 120}, because
neither 60 nor 120 divides 45 and the faster mode halves the one-scanout error);
failing that the fastest mode there is. Smallest-multiple rather than fastest is
this section's own battery lever restated — pinning a 60 fps game to 120 Hz would
hand back the sentence above it.

**The two-argument `setFrameRate` overload is deliberate**: on API 31+ it means
`CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS`, so a mode switch the panel could not make
invisibly is refused rather than made. A fix for banding may not be a new source
of it. `minSdk` is 29 and the surface vote is API 30, so an API-29 device takes
the stated fallback — **no vote, today's behaviour exactly**, reported as `false`
rather than pretended.

**Levers.** `--refresh=auto|60|90|120|off` (doc 13 D-20's argument path) and a
Settings row, `Auto / 60 / 120 / Off` (doc 12 D-75). `off` declares **nothing at
all** rather than declaring zero, so the A/B's control arm is the shipped
behaviour in the same binary — report 98 §46 has the protocol and RR-128 has the
reason. The ladders live in `data/render.json.refresh`.

**Still open:** the modal row of the table above. `idle_fps` and
`render_target_update_mode = UPDATE_DISABLED` remain unimplemented — `grep -rn
"idle_fps\|UPDATE_DISABLED" game/ ui/` returns nothing — which is why a sheet
over the world is a cost *step* rather than a cost *drop*, and is the second
half of doc 93 §AE3's mechanism. The pin does not close it and does not claim to.

**Sim cost while foregrounded** is negligible by construction — 4 Hz utility tick, 1 Hz incidents, per-game-hour economy (constitution §4). No battery rule touches sim cadence; slowing the sim to save battery would change gameplay, which is not allowed.

**Measurement protocol.** `dumpsys batterystats --reset`, play a scripted 30-minute session (§7 D-07), then `dumpsys batterystats com.slacumcity.game`, and convert: `drain_pct_per_hour = (level_start - level_end) * 2`. Ship gate: Tier B ≤ 6.0 %/h Balanced, ≤ 3.5 %/h Saver.

### 2.9 Long catch-up without an ANR

The worst case is the C-19 cap and, since report 98 §58 (RR-160), it is also the ORDINARY case: **12 real hours of absence = 720 coarse steps** (720 game-hours = 30 game-days). Doc 08 may no longer lower the effective count — `max_coarse_hours` clamped the *credited absence*, shipped at 360 = six real hours, and is retired (RR-161); doc 08 §2.12's budget now bounds this section's veil instead, which is the thing it was always a budget for. **This section therefore has to carry the full 720 steps on every absence, and the table below is the honest reading of that.** Catch-up is **sliced on the main thread** — report 98 C-22 ruled against threading it, because sim state is single-owner `RefCounted` (constitution §3) and the platform can kill the process mid-task:

```
veil.show()                                  # animated "Simulating 30 days…" with a progress bar
while not sim.advance_coarse_sliced(12):     # doc 01 §4: whole coarse steps until the budget is spent
    veil.set_progress(sim.steps_done() / float(sim.steps_total()))
    await get_tree().process_frame
veil.hide(); report.show(catchup.summary())
```

Veil wall time = `steps × measured_coarse_ms`, generated from doc 08's P0-27 measurement:

| `measured_coarse_ms` | 720 steps (12 h cap) | Frames at a 12 ms slice | Veil reads as |
|---|---|---|---|
| 0.60 (doc 01's retired estimate) | 432 ms | 36 | a blink |
| 4.00 | 2.88 s | 240 | a short load |
| **7.65 — MEASURED, settled reference city (doc 92 §55.6)** | **5.50 s** | 459 | a real load screen, once a night |
| **8.95 — MEASURED, settled L4 city; the shipped `veil_ms_at_cap`** | **6.43 s** | 536 | the budget's worst passing case |
| 12.0 | 8.64 s | 720 | at the 9 s budget's edge |
| **162.6 — MEASURED, 1,500-building `bench_city`** | **116.9 s** | 7 013 (one step per frame) | over budget by 13×; **doc 92 §55.7 AC-19-1** |

**ANR safety is structural, not budgetary.** `advance_coarse_sliced` runs *whole* coarse steps, so a single step longer than the budget still runs to completion; the main loop is therefore blocked for at most one step. Android's ANR line is 5 s, so the design is safe for any `measured_coarse_ms < 5 000` — a 90× margin even at the pessimistic 55 ms. The 12 ms budget is about keeping the 30 fps veil animation smooth, not about avoiding the ANR.

Progress fraction = `steps_done() / steps_total()`, so the bar is honest. If `steps_total ≤ 4` (`catchup_veil_min_steps = 5`) the veil is skipped entirely — sub-frame work.

> **As built (Wave 13):** the veil is `ui/loading_veil.gd` + `ui/veil_model.gd`, doc 12 §2.20, and this phase's copy is `Your city ran {hours} hours` with the 12-hour cap named in words underneath when the absence ran past it. `catchup_veil_min_steps` lives at `data/ui.json.veil.min_steps`, and a refused catch-up also takes a *showing* veil down with it — which is the sequence a returning player actually produces, since the restore in front of it raised one.
>
> ~~**What is still doc 13's to do, and it is the shell's half rather than the screen's:**~~ **DONE (Wave 14).** `game/main.gd::_on_app_resumed` ran the planner's segments in a synchronous `for` loop, so there was no frame between them for the veil to draw in. It now takes a **`CatchUpCursor`** and spends units out of it inside the same guard `_restore_cursor` already owns — one `_process` frame per slice, `advance_veil_catchup(cursor.done_ticks())` per slice, and the post-catch-up work (`residual_game_ms`, the bus drain into `_on_sim_batch`, the away report) moved to the completion branch where it belongs.
>
> **Two shell-side consequences of the catch-up no longer being one frame, both handled in the snippet and neither of them a UI question.** First, `SimHost` is **paused for the duration**: it is a separate node with its own `_process`, and unpaused it would add `delta × 60` to `clock.residual_game_ms` and spend LIVE fine ticks between the plan's slices — so the sliced resume would land on a different city from the synchronous one. The pause is a determinism requirement, not tidiness. Second, a player can now background the app *while the veil is up*, which was unreachable before; a second `_on_app_resumed` therefore drains the unfinished cursor on the spot and then plans the new absence, rather than dropping it. Draining synchronously is exactly what this path did with the whole plan at HEAD, so it is no worse than the frame it replaces.
>
> **The unit is one coarse hour or one fine tick, and the BUDGET is the shell's**, which is where this section's own pseudocode already put it and where constitution §5 requires it — `sim/` may not read a clock, so a cursor cannot decide for itself that it has spent long enough. The shell writes `while not cursor.step(): if Time.get_ticks_usec() - t0 >= CATCHUP_SLICE_USEC: break`, spends 12 ms of whole steps and returns the frame. ANR safety is unchanged and still structural: a step longer than the budget runs to completion, so the worst blocked frame is one coarse step (190 ms on the benchmark city) against the 5 s line.
>
> **Two shapes in this section did not survive contact with the shipped planner, and both are recorded rather than quietly dropped.** `advance_coarse_sliced(hours_per_slice)` returning "done yet?" cannot advance a real resume: a returning player's plan carries a fine head-align segment and a 40-tick fine tail (doc 91 D-1), and a coarse-only entry point has nothing to do with either. And `hours_per_slice = 12` came from the retired 0.60 ms/step estimate — at the measured 6.3 ms (founding) to 190 ms (bench) per coarse step, a 12 ms budget spends **one** step per frame on any city in the project, which is this section's own worst-case row.
>
> **Slicing changes nothing about the city, and the seam that guarantees it is `TickScheduler.advance_coarse_n`'s `catchup_index_base`.** A coarse step reads `ctx.catchup_index` / `ctx.catchup_total` — doc 03's offline yield decay and doc 07's 72-hour offline event gate both consume them — so an hour has to be told which hour OF ITS SEGMENT it is, not of its slice. `tests/test_catchup_cursor.gd` proves bit-identity against the old loop on both cities at 1, 3, 12 and unbounded units per frame, on `state_hash()` **and** on the drained event stream, and pins the index mechanism directly so a regression names its own cause. `catchup_begin()` still fires once per coarse segment (doc 07 C-55), not once per slice. Report 98 §29 RR-73.

#### 2.9.1 The term this section forgot: the LOAD in front of the catch-up (Wave 12)

Every number above is about the catch-up. **Nothing above it is about getting the city into memory in the first place**, and until Wave 12 measured it there was no figure to put there. There is now, and it is not small: the arithmetic above was written as though a returning player's first frame begins at `advance_coarse_sliced`, when in fact it begins at `SaveService.load_slot()` and the catch-up does not start until that has finished.

The full sequence a returning player pays, in order, with `tools/profile_save.gd` figures (workstation, best of 7, at `28b9550` → Wave 12):

| Term | Founding city | Benchmark city (1,500 buildings) | Thread |
|---|---|---|---|
| read (decompress, parse, digest, 7-check gate) | 2.6 ms | 28.4 ms | main |
| **restore** (`CitySim.restore_state`) | 45.4 → **42.2 ms** | 396.8 → **202.1 ms** | main |
| catch-up | `steps × measured_coarse_ms` | as above | main, sliced |
| pause-path save on the way back out | 13.9 → **11.2 ms** | 125.3 → **106.4 ms** | main (`SYNC_REASONS`) |

**The load term is 230 ms of main-thread work on the benchmark city and it is not sliceable by the same mechanism the catch-up uses** — `advance_coarse_sliced` slices a loop of identical steps, and a restore is eleven different ones. So it gets its own mechanism, `CitySim.begin_restore()`, and the veil budget for it is written against the LONGEST STEP rather than the total:

```
veil.show()                                  # "Opening <city>…", indeterminate — see below
var cursor := sim.begin_restore(body)
while not cursor.step():                     # one step per frame
    veil.set_progress(cursor.completed() / float(cursor.step_count()))
    await get_tree().process_frame
# …and only now does the catch-up above begin.
```

> **Wave 14 moved 108 ms off the table below, and it was never a restore term to begin with.** Doc 04's per-tile transformer memo was cold-filled by the signal-power sample at the load seam — the five `roads_signals` steps RR-60b split it into — and it is now warm-filled once in `CitySim._boot_power`. Interleaved A/B, three rounds, benchmark city: `roads_signals` **109.5 → 1.54 ms**, restore total **316 → 207 ms**, against **cold `CitySim.boot()` 211 → 222 ms** on the other side of the trade. The longest step is unchanged, which is what the veil budget is written against. Doc 04 §2.2 carries the full table; report 98 §29 RR-71.

Per-step cost, benchmark city, `profile_save.gd --steps` (best of 7):

| Step | ms | | Step | ms |
|---|---|---|---|---|
| `decode` | 31.6 | | `incidents` | 0.8 |
| `core` | 3.7 | | `roads_tiles` | 15.4 |
| `world` | 21.8 | | **`roads_graph`** | **76.5** |
| `records` | 0.2 | | `roads_state` | 29.4 |
| `roster` | 7.9 | | `finish` | 1.6 |
| `water` | 18.8 | | **total** | **207.6** |

**ANR safety is structural here for exactly the reason it is above**, and the margin is the same order: the longest step is 76.5 ms on a workstation, so at the Fold's measured 3–5× penalty (§2.13) the worst frame a restore can produce is **≈0.4 s against a 5 s ANR line** — a 13× margin, and the same argument as `advance_coarse_sliced`'s. What the slicing buys is not ANR safety, it is the veil: an unsliced restore freezes the animation for 0.2 s on a workstation and up to 1 s on a phone, and a frozen loading animation is how a player decides an app has hung.

**The progress bar over a restore is indeterminate, and the doc says so rather than lying with a fraction.** `cursor.completed() / cursor.step_count()` is honest about how many steps have run and dishonest about how much time is left — `roads_graph` alone is 37 % of the work and one step of eleven. ~~Doc 12's veil therefore shows a spinner for the restore and switches to the real bar when the catch-up starts, where `steps_done() / steps_total()` *is* proportional to time.~~

> **As built (Wave 13, doc 12 §2.20 / D-60): the veil exists, and it shows a stepped BAR over the restore rather than a spinner.** The objection above is answered by **naming the unit** instead of hiding it: `Step 7 of 11` sits under the bar, so the bar means exactly what the line says and claims nothing about elapsed time. Two reasons it went this way rather than the doc's. First, a spinner would be the only animation in the deck that doc 12's A8 `reduce_motion` would have to suppress — and *a loading screen whose animation has been suppressed is indistinguishable from a hung one*, which is the failure this section spends a paragraph avoiding. A stepped bar has no motion to suppress and still moves eleven times. Second, the fraction the doc calls dishonest is the only progress signal that exists at all during a restore; discarding it leaves the veil with nothing to say. **The catch-up half is unchanged and takes the doc's own bar**, where `steps_done() / steps_total()` *is* proportional to time. Doc 12 §2.20 item 2 carries the same argument from the UI side.
>
> `catchup_veil_min_steps` ships as `data/ui.json.veil.min_steps` (doc 12 owns the screen, so it owns the screen's tunables) and applies to the **catch-up only**. A restore is never refused a veil however few steps it has: this section's own per-step table runs from 0.2 ms to 76.5 ms, so "few steps" does not mean "fast", and `SaveService.begin_load_slot()`'s one-step fallback for a legacy file is the *slowest* load in the project.
>
> The shell calls `UIRoot.present_veil_load(city, cursor.step_count())` where the pseudocode says `veil.show()`, `advance_veil_load(cursor.completed())` where it says `set_progress`, and `dismiss_veil()` where it says `hide` — and the city's name is S8's own slot title, because `ui/` has no slot list and `sim/` has no name for a city.

**Why the restore cannot simply move off the main thread, restated because it is asked every wave.** It writes the live sim, and the sim is single-owner `RefCounted` (constitution §3) — the same C-22 ruling that refused to thread the catch-up. What *did* move is the SAVE's second half: the float canonicalisation is a pure function of a detached snapshot and now runs on the write thread (report 98 §24 RR-49), which is why the pause-path row above fell 125 → 106 ms and the autosave row fell 85 → 39.

##### The budget lines, re-derived against the 2026-09-01 device numbers

**Every figure in this section above is a workstation figure or a single device
sample. The 2026-09-01 Fold session produced FIFTEEN load rows and one
lifecycle-save row on the player's live 288 KB slot**, so the arithmetic can be
re-derived against medians instead of estimates. Source:
`tools/device_results/run_matrix_2026-09-01.log`; extract with

    grep -a 'PERFIO' tools/device_results/run_matrix_2026-09-01.log

| term | 2026-08-21 (one sample, 202,946 B) | **2026-09-01 (median of 15, 288,385 B)** | change |
|---|---|---|---|
| `read_ms` | 24.0 | **11.4** | −52.5 % |
| **`restore_ms`** | **136.2** | **138.9** | **+2.0 %** |
| unaccounted (`ms` − read − restore) | 5.3 | **0.7** | — |
| **total `ms`** | **165.5** | **151.0** | −8.8 % |
| slot bytes | 202,946 | 288,385 | **+42.1 %** |
| spread (min … max of 15) | — | **147.8 … 171.4** | the two outliers are `read_ms` 17.8 and 21.6 |

| the save (`reason=pause`, the real backgrounding path) | 2026-08-21 | **2026-09-01** | change |
|---|---|---|---|
| `write_ms` | 42.9 | **43.3** | **+0.9 %** |
| total `ms` | 159.4 | **88.1** | **−44.7 %** |
| the non-write half (`ms` − `write_ms`) | 116.5 | **44.8** | −61.5 % |
| bytes | 203,538 | 345,597 | **+69.8 %** |

**Four budget lines, re-derived.**

1. **The restore is still the longest term, and by more than it was.** It is
   **138.9 of 151.0 ms = 92.0 %** of the load, and **12.2×** the read. The 2026-08-21
   read of this section — *"the load is CPU-bound on deserialisation, not on
   storage, and shaving it is a restore-path question"* — is not merely confirmed,
   it is sharper: storage has fallen to **7.6 %** of the load and the residual
   term to 0.5 %. **There is exactly one term left to optimise and §2.9.1's
   per-step table is where it lives.**
2. **The restore does not scale with slot size, and that is new information.**
   The slot grew **42.1 %** between the two sessions and the restore grew
   **2.0 %**. A restore whose cost is 42× less elastic than its input is
   dominated by fixed per-structure work (`roads_graph` is 37 % of the
   workstation step table and rebuilds a graph, not a byte count), which is the
   same conclusion the per-step table reaches from the other end. **It also means
   the veil budget does not have to be re-derived every time a city grows** — the
   number this section has always feared, "what happens at 1,500 buildings", is a
   step-count question and not a byte question.
3. **ANR safety is structural and the measured margin is 33×.** Android's line is
   5 s. The whole device load — read, restore and residual together, in the worst
   of fifteen samples — is **171.4 ms, a 29× margin**; at the median 151.0 ms it
   is **33×**, and the restore alone (138.9 ms) is **36×**. That holds *even if
   the restore ran wholly unsliced in one frame*, which is the pessimistic
   reading, and it is the first time this section has been able to say so from a
   phone rather than from a 3–5× guess.
4. **The `onPause` window has gone from comfortable to uncontested.** The save is
   **88.1 ms against the 500 ms budget — 17.6 %, a 5.7× margin**, where
   2026-08-21's 159.4 ms was 31.9 % and 3.1×. And it got there on a payload
   **70 % larger**: `write_ms` is flat at 43.3 ms, so the whole of the gain is in
   the non-write half, which is where RR-49 moved the float canonicalisation onto
   the write thread. **This is the first device confirmation that RR-49's move
   pays on hardware**, and it pays about as much as it did on the workstation
   (125 → 106 ms there, 116.5 → 44.8 ms here).

**Two things this still does NOT measure, stated so nobody quotes it for them.**

* **The 3–5× device penalty is still an estimate.** This section's *"at the
  Fold's measured 3–5× penalty the worst frame a restore can produce is ≈0.4 s"*
  cannot be checked against these rows, because no workstation run of *this* save
  exists — the player's city lives on the phone, and the two workstation
  reference cities (founding, 42.2 ms restore; benchmark, 202.1 ms) bracket the
  device's 138.9 ms without pinning a ratio. The ≈0.4 s figure remains the
  conservative planning number; what these rows prove is that the *total* is
  151.0 ms, so the estimate is an over-estimate for this city by at least 2.6×
  even in the unsliced case.
* **`PERFIO` carries no per-step breakdown, so the veil's actual budget line —
  the LONGEST step — has never been measured on a phone.** `kind=load` reports
  `read_ms` and `restore_ms` and nothing between them. The workstation says
  `roads_graph` is 76.5 ms of 207.6 ms on the benchmark city; the device says the
  whole restore of a smaller city is 138.9 ms; neither statement constrains the
  other. **A `step_ms_max=` field on the load row would close doc 91 §20.4 device
  item 6's arithmetic half without a 12-hour absence**, and it is the second
  cheap instrument fix this session's data asks for (the first is doc 11 §2.13's
  `hour=` column).

### 2.10 Export pipeline

> **As built:** §10.1–§10.4. The `--install-android-build-template` line below
> does not work headless on 4.7.2 — the manual unzip beneath it is the procedure,
> and `tools/setup_android.sh` runs it. Sizes and the verified preset keys are in
> §10.2 and §10.4.

**One-time setup — `tools/setup_android.sh`:**

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(which java)")")")"
yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses

# Headless export reads SDK/JDK paths from editor settings, so they must exist:
godot --headless --editor --quit --path "$P"        # generates ~/.config/godot/editor_settings-4.7.tres
# then set:  export/android/android_sdk_path = "$ANDROID_HOME"
#            export/android/java_sdk_path    = "$JAVA_HOME"

keytool -keyalg RSA -genkeypair -alias androiddebugkey \
  -keystore "$HOME/.android/debug.keystore" -storepass android -keypass android \
  -dname "CN=Android Debug,O=Android,C=US" -validity 10000 -deststoretype pkcs12

# Gradle build template — required for the plugin. Do once; commit the result.
godot --headless --path "$P" --install-android-build-template
# Manual equivalent if the CLI flag misbehaves:
#   unzip ~/.local/share/godot/export_templates/4.7.2.stable/android_source.zip -d android/build
#   echo "4.7.2.stable" > android/.build_version
```

`.gitignore` currently excludes `android/build/`. **That must change** — with a custom template it is source. Narrow it to `android/build/.gradle/`, `android/build/build/`, `android/build/local.properties` (§9). Reinstalling the template (a Godot upgrade forces this) overwrites the directory, so every edit lives as a patch in `tools/android_patches/*.patch`, reapplied by `tools/reinstall_android_template.sh`. ~~**Design goal: keep that patch set empty** — the plugin owns its own manifest entries, so no template edit is currently needed.~~ **The patch set is ONE patch, not zero (2026-08-20): `res/values/themes.xml` carries §2's dark `android:windowBackground` and the removal of a dangling splash-branding drawable reference. `tools/setup_android.sh` reapplies every `tools/android_patches/*.patch` after the unzip; §10.1 has the measurement and the verification.**

**Signing.** No secret ever enters `export_presets.cfg` (which is committed). Godot 4.2+ reads keystores from the environment:

```bash
export GODOT_ANDROID_KEYSTORE_DEBUG_PATH="$HOME/.android/debug.keystore"
export GODOT_ANDROID_KEYSTORE_DEBUG_USER="androiddebugkey"
export GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD="android"
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$HOME/keys/slacum-upload.keystore"
export GODOT_ANDROID_KEYSTORE_RELEASE_USER="slacum-upload"
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="…"    # password manager, never a repo file

# Upload keystore, generated once, backed up in two offline places:
keytool -genkeypair -v -keystore ~/keys/slacum-upload.keystore -alias slacum-upload \
  -keyalg RSA -keysize 4096 -validity 10950 -storetype pkcs12 \
  -dname "CN=Slacum City, O=<legal entity>, L=<city>, C=<cc>"
```

We enrol in **Play App Signing**, so this is the *upload* key only and Google holds the app signing key: losing the upload key is recoverable, losing a self-managed app signing key would be terminal.

**Version code:** `major*10000 + minor*100 + patch` → `0.1.0 → 100`, `1.0.0 → 10000`. `tools/build_android.sh` derives `version/code` and `version/name` from `project.godot`'s `config/version` and refuses to build if the code is ≤ `tools/.last_uploaded_version_code`.

**Build, verify, deploy:**

```bash
P="/home/bbx/Slacum City game"
godot --headless --path "$P" --export-debug   "Android Debug APK" "$P/build/slacum-debug.apk"
godot --headless --path "$P" --export-release "Android Test APK"  "$P/build/slacum-test.apk"
godot --headless --path "$P" --export-release "Android Play AAB"  "$P/build/slacum-release.aab"
# First Gradle build ~3–5 min; incremental ~40 s with the daemon warm.

# 16 KB page-size gate (Play requirement for target-15+ apps; verify EVERY release):
unzip -o build/slacum-release.aab -d /tmp/aab
llvm-readelf -l /tmp/aab/base/lib/arm64-v8a/libgodot_android.so | grep LOAD
#   every LOAD segment must report Align 0x4000 (16384)
"$ANDROID_HOME/build-tools/37.0.0/aapt2" dump permissions build/slacum-release.aab   # expect exactly 4

adb devices -l
adb install -r -d build/slacum-debug.apk
adb shell am start -n com.slacumcity.game/com.godot.game.GodotApp
adb logcat -c && adb logcat -v time godot:V GodotPlugin:V SlacumNative:V AndroidRuntime:E *:S
```

Three presets exist because release builds behave differently from debug: the **Test APK** is release-signed and used for all perf and battery measurement, while the AAB goes to Play and the debug APK drives the dev loop.

### 2.11 Crash reporting without a heavy SDK

Ranked, with the MVP decision:

1. **Play Console Android vitals + Pre-launch report — CHOSEN for MVP.** Zero SDK, zero permissions, zero Data Safety impact, free. Gives native crash clusters, ANR rate, excessive-wakeup flags, and startup-time percentiles across real devices. Gate thresholds to stay under: crash rate < 1.09 %, ANR rate < 0.47 % (Play "bad behaviour" thresholds). Godot's shipped release `.so` is stripped, so native frames are partly unsymbolicated — acceptable, because most of our failures will be GDScript.
2. **Local breadcrumb ring — CHOSEN for MVP, ours.** On launch the shell writes `user://runtime/session_open.flag`; the pause sequence deletes it. Finding the flag at launch means the previous session died uncleanly. The shell then writes `user://logs/incident_<unix>.json` (ring of 5) containing: app version, `OS.get_model_name()`, API level, thermal status at last sample, `GameClock.ticks`, the last 64 event-bus entries, the last 20 GDScript errors captured via a `push_error` hook, and free RAM. Settings → "Report a problem" renders that JSON and offers an Android share intent — **no network permission required**, the user chooses the channel.
3. **Sentry (native + GDScript)** — post-alpha only. Adds `INTERNET`, changes the Data Safety declaration to "Crash logs collected", and needs an opt-in toggle. Revisit at Phase 3.
4. **Firebase Crashlytics — rejected.** Pulls in Google Play services, risks `AD_ID` injection, heavy, and the Data Safety story degrades for a solo-dev offline game.

### 2.12 Play Store readiness (targetSdk 37)

| Item | State for MVP | Note |
|---|---|---|
| targetSdk | 37 | Within Play's 1-year window |
| Format | AAB, Play App Signing | APK uploads not accepted for new apps |
| ABI | `arm64-v8a` only | 64-bit requirement satisfied |
| 16 KB pages | Verified per build (§2.10) | Hard requirement for target-15+ apps |
| Data Safety | "No data collected, no data shared" | True only while `INTERNET` is absent; re-file the moment crash reporting or billing lands |
| Privacy policy | Required field — publish a one-page policy (GitHub Pages) stating no collection | Cheap now, mandatory later |
| Content rating (IARC) | Disasters, fire, no gore, no blood → expect PEGI 7 / ESRB E10+ | Post-launch zombie/alien packs likely push to Teen — re-run the questionnaire then |
| Ads / IAP | "Contains ads": No. No `BILLING` permission, no Play Billing Library in the binary | Deferred post-alpha per constitution §7 |
| App access / audience | "All functionality available without restrictions" — no login; 13+, not designed for children | Avoids Families policy obligations |
| Store assets | Icon 512×512 32-bit PNG; feature graphic 1024×500; ≥ 4 landscape phone screenshots ≥ 1080p; 7" + 10" tablet screenshots | Landscape only (constitution §1) |
| Release track path | Internal testing (≤ 100 testers, no review wait) → closed testing → production; enable the Pre-launch report | Free crash/perf sweep on real devices |
| **Closed-testing gate** | Personal developer accounts must run a closed test with **≥ 12 testers opted in for ≥ 14 continuous days** before production access | Schedule-critical; recruit at Milestone C, not at launch |
| Base install size | Target ≤ 150 MB | Play Asset Delivery not needed for MVP |

## 3. Data Schema

### 3.1 `data/android.json` — see the consolidated block in §8.

This doc owns exactly two data files (report 98 C-71): **`data/android.json`** (platform config — channels, alarm mechanics, power, build) and **`data/notifications_text.json`** (copy, §3.1.1). It owns **no** notification policy file; `data/notifications.json` is doc 08's.

#### 3.1.1 `data/notifications_text.json` — owned here, reviewed by whoever owns tone

Keyed by doc 08's convention (`n_<event key>_title` / `n_<event key>_body`, doc 08 §3.3), so adding an event touches doc 08's policy file and this copy file only. Copy **never states an exact time** — alarms are inexact by choice (§2.6).

```json
{
  "schema_version": 1,
  "strings": {
    "n_storm_forecast_title":        "Severe thunderstorm warning",
    "n_storm_forecast_body":         "A storm reaches Slacum City in about {hours} hours. Crews on standby?",
    "n_district_blackout_title":     "{district} has gone dark",
    "n_district_blackout_body":      "Power has been out for about {hours} hours.",
    "n_hospital_service_lost_title": "The hospital has lost power",
    "n_hospital_service_lost_body":  "Backup generators are running.",
    "n_major_fire_title":            "Fire still burning",
    "n_major_fire_body":             "{building} has been alight for a while and crews have not contained it.",
    "n_construction_complete_title": "Construction finished",
    "n_construction_complete_body":  "{building} is ready.",
    "n_coalesced_summary_title":     "{count} problems in your city",
    "n_coalesced_summary_body":      "Tap to review."
  }
}
```

English only in MVP; when doc 12's `data/strings.en.json` (report 98 G-8) gains a localization pipeline, this file becomes one of its namespaces rather than a second mechanism.

### 3.2 Save-file section: `save.android`

Owned by this system; serialized/deserialized by `AndroidState` (constitution §9: each system owns its section).

Per the canonical registry (report 98 §11) this section carries exactly three things: **the last pause stamp, the permission state, and the device profile** — plus platform diagnostics. Notification *preferences* (`class_enabled`, `quiet_hours`) and the *scheduled plan* live in doc 08's `notifications` section and are **deleted from here**; `delivered_log` stays because it is platform delivery feedback that doc 08 has no field for and consumes for report reconciliation.

```json
"android": {
  "section_version": 1,
  "last_pause": { "unix_s": 1800000000, "elapsed_realtime_ms": 88123456, "boot_id": "3f2a…c19",
                  "clock_ticks": 49920, "app_version": "0.1.0", "clean": true },
  "permission": {
    "post_notifications": "granted", "asked_count": 1, "last_asked_unix": 1799000000,
    "reprompt_count": 0, "channels_created": ["slacum_critical", "slacum_important", "slacum_routine"]
  },
  "delivered_log": [ { "id": 1000, "class": "P1_critical", "key": "storm_forecast",
                       "fired_at_unix_s": 1800001291, "opened": true } ],
  "device_profile": { "graphics_preset": "balanced", "fps_cap": 60, "high_refresh_opt_in": false,
                      "battery_saver_mode": "auto", "last_thermal_status": 0 },
  "diagnostics": { "pause_ms_mean": 147.0, "projection_ms_mean": 0.0, "projection_degraded": false,
                   "unclean_exits": 0 }
}
```

`delivered_log` is capped at 32 entries (ring). `projection_ms_mean` is 0.0 while class (c) is disabled (§2.4c). The `scheduled` array is doc 08's (`notifications.scheduled`, capped by doc 08's budget), and `saves_recovered_from_backup` is deleted — recovery is doc 08's and is reported through `meta.repair_notes` (doc 08 §3.2).

### 3.3 Non-save runtime files

| Path | Purpose | Lifetime |
|---|---|---|
| `user://runtime/session_open.flag` | Unclean-exit sentinel (§2.11) | Created at launch, deleted at pause |
| `user://logs/incident_<unix>.json` | Crash breadcrumb, ring of 5 | Manual share / auto-pruned |
| `user://perf/session_<unix>.csv` | 1 Hz perf sample, **debug builds only** | Pulled by adb, ring of 3 |
| `filesDir/notif_schedule.json` | Plugin-owned, for `BOOT_COMPLETED` replay | Rewritten per batch |

### 3.4 `export_presets.cfg` (committed; secrets by env only)

> **Superseded in detail by §10.2**, which is the diffed 4.7.2 key set from a
> build that actually ran. The block below is kept for its intent (one preset per
> output, secrets by env, ABI and version policy); where the two disagree, §10.2
> is what the exporter accepts.

```ini
[preset.0]
name="Android Debug APK"
platform="Android"
runnable=true
advanced_options=true
export_filter="all_resources"
export_path="build/slacum-debug.apk"
script_export_mode=2

[preset.0.options]
gradle_build/use_gradle_build=true
gradle_build/export_format=0            ; 0 = APK, 1 = AAB
gradle_build/min_sdk="29"
gradle_build/target_sdk="37"
gradle_build/compress_native_libraries=false
architectures/armeabi-v7a=false
architectures/arm64-v8a=true
architectures/x86=false; architectures/x86_64=false
version/code=100
version/name="0.1.0"
package/unique_name="com.slacumcity.game"
package/name="Slacum City"
package/signed=true
package/app_category=2                  ; Game
package/retain_data_on_uninstall=false
package/show_in_android_tv=false
launcher_icons/main_192x192="res://game/branding/icon_192.png"
launcher_icons/adaptive_foreground_432x432="res://game/branding/icon_fg_432.png"
launcher_icons/adaptive_background_432x432="res://game/branding/icon_bg_432.png"
launcher_icons/adaptive_monochrome_432x432="res://game/branding/icon_mono_432.png"
keystore/debug=""; keystore/debug_user=""; keystore/debug_password=""     ; env-supplied
keystore/release=""; keystore/release_user=""; keystore/release_password="" ; env-supplied
screen/immersive_mode=true
screen/support_small=false                        ; support_normal/large/xlarge = true
user_data_backup/allow=false
apk_expansion/enable=false
permissions/custom_permissions=PackedStringArray()   ; ^ the plugin manifest DOES merge its four
                                                     ;   (2×2 in §2.7; the 2026-08-21 "measured
                                                     ;   false" note was itself false and is
                                                     ;   reversed). custom_permissions stays empty.
permissions/post_notifications=true                  ; Wave 14: the four, on every preset, as a
permissions/receive_boot_completed=true              ; SECOND source. A stale AAR then degrades from
permissions/vibrate=true                             ; "silently drops a runtime permission" to
permissions/wake_lock=true                           ; "nothing at all", which is the failure that
                                                     ; has now cost two sessions. See §2.6 / §2.7.

[preset.1]  name="Android Play AAB"
;   as preset.0, but export_path="build/slacum-release.aab" and gradle_build/export_format=1
[preset.2]  name="Android Test APK"
;   as preset.0, release-signed, export_path="build/slacum-test.apk" (perf/battery measurement)
```

(The `; a; b` one-line pairings above are documentation shorthand — the real file puts each key on its own line.)

**Implementation note:** Godot's exporter option keys occasionally shift between minor versions. The authoritative procedure is to configure preset 0 once in the editor GUI, `git diff` the generated `export_presets.cfg` against this block, and update this document with any deltas in the same commit (constitution §12).

## 4. Sim API Sketch

Nothing in this document lives in `sim/`. The shell classes below are `game/` layer.

| Class | Location | Responsibility |
|---|---|---|
| `AppShell` | `game/app_shell.gd` (autoload, `PROCESS_MODE_ALWAYS`) | `_notification()` router; owns the pause/resume sequences |
| `LifecycleStamp` | `game/android/lifecycle_stamp.gd` | Builds and reads `save.android.last_pause`; the elapsed-time formula (§2.3) |
| `NotificationScheduler` | `game/android/notification_scheduler.gd` | Collects class (a)/(b) candidates, calls doc 08's `sim/notify/NotificationPlanner.plan()`, then schedules whatever it returns. **Owns no budget, no classes, no quiet hours** (C-71). Also runs the optional class (c) projection when enabled. |
| `NotificationTextStore` | `game/android/notification_text.gd` | Renders `n_<event>_title` / `n_<event>_body` from `data/notifications_text.json` |
| `NotificationBridge` | `game/android/notification_bridge.gd` | Thin wrapper over `Engine.get_singleton("SlacumNative")`; **stubs cleanly to no-ops on desktop/headless** |
| `PermissionFlow` | `game/android/permission_flow.gd` | The POST_NOTIFICATIONS state machine (§2.7) |
| `PowerPolicy` | `game/android/power_policy.gd` | Frame caps, thermal/power-save rules, preset switching |
| `CrashSentinel` | `game/android/crash_sentinel.gd` | Session flag, breadcrumb ring, error hook |
| `AndroidState` | `game/android/android_state.gd` | serialize/deserialize of `save.android` |

**Injected-interface implementations (C-04).** These three are the *only* way `sim/` reaches Android; there is no `platform/` layer:

| Interface (declared by doc 08 §4) | Implementation | Provides |
|---|---|---|
| `IClockSource` | `game/android/lifecycle_stamp.gd` | `now_unix()`, `elapsed_realtime_ms()`, `boot_id()` |
| `IFileSink` | `game/android/file_sink.gd` | `write/rename/list/delete` under `user://` for doc 08's atomic protocol |
| `INotificationSink` | `game/android/notification_bridge.gd` | `schedule(entry) -> alarm_id`, `cancel(id)`, `cancel_all()`, `channels()`, `local_utc_offset_s()` |

**Commands accepted** (from `ui/`): `request_notification_permission()`, `open_system_notification_settings()`, `set_graphics_preset(name)`, `set_high_refresh_opt_in(bool)`, `set_battery_saver_mode(auto|on|off)`, `export_incident_report()`. *(`set_notification_class_enabled` and `set_quiet_hours` are deleted from this doc's command list — those preferences are doc 08's `notifications` section; the UI sends them to doc 08 and this doc only re-reads the resulting plan.)*

**Events emitted** (onto the shell's own bus, not the sim's): `app_paused`, `app_resumed(elapsed_s, anomaly)`, `catchup_started(steps_total)`, `catchup_progress(fraction)`, `catchup_finished(summary)`, `notification_permission_changed(state)`, `notification_opened(payload)`, `notification_delivered(id, key)`, `thermal_changed(status)`, `power_preset_changed(preset, reason)`, `unclean_exit_detected(path)`.

**Nothing here ever calls into `sim/` except through the sanctioned surface**: `Sim.deserialize()`, `Sim.tick()`, `Sim.advance_coarse_hours()`, ~~`Sim.advance_coarse_sliced(max_ms)`~~ **`Sim.begin_catchup(plan)` → `CatchUpCursor.step()` + `steps_done()` / `steps_total()` / `done_ticks()` / `total_ticks()`** (Wave 14 — §2.9), `Sim.drain_events()`, `SaveManager.request_save(reason)` and `SaveManager.load_slot(slot)`. **`Sim.serialize()` is no longer called from here** — snapshotting is inside doc 08's `request_save`.

## 5. Cross-System Interfaces

**Doc numbers are the on-disk filenames** — the canonical map ruled in report 98 §0 (Ruling Zero). The previous version of this table used a private numbering in which persistence was 10, the Director was 08, incidents were 07, buildings were 03 and economy was 02; every one of those is corrected below. No number in this doc is a guess any more.

| Doc | System | What this doc needs / provides |
|---|---|---|
| **01** Time model & tick scheduler | needs | `GameClock.TICKS_PER_MINUTE`, `time_scale_gmin_per_rsec = 1.0`, and **`catchup.offline_cap_real_ms` from `data/time.json`** (the 12-real-hour cap, C-19 — this doc stores no cap of its own). Also `advance_coarse_sliced(max_ms) -> bool` with `steps_done()` / `steps_total()` (C-22) and `advance_coarse_hours(n)` usable on a throwaway instance with no global side effects. This doc converts real seconds → ticks and must be the **only** place that does so. |
| **02** Buildings, upgrades & construction | needs | `ConstructionQueue.pending_completions() -> Array[{project_id, kind, completion_gmin, cost}]`, valid at snapshot time. Drives class (a) notifications; the "large construction" threshold is doc 08's, not ours. |
| **03** Economy, taxes & land market | needs | Treasury-crossing events emitted with the keys doc 08's event table classifies (e.g. `treasury_threshold`). |
| **06** Incidents, dispatch & fleets | needs | Every emitted incident event carries a stable event `key` and a `payload` string usable as a deep link (`incident:<type>:<id>`). Classification is doc 08's `data/notifications.json`; this doc only delivers. |
| **07** Weather & Disaster Director | **needs (hard dependency)** | `Director.forecast_queue() -> Array[{event_id, kind, severity, onset_gmin, warning_lead_gmin}]`, **pre-rolled and committed to the save**, deterministic under the `director` RNG stream. This is predictability class (b): without pre-rolling, storm-warning notifications (spec §22 P1) are impossible — the single most important notification in the game — because class (c) projection ships disabled. |
| **08** Persistence, offline policy & notification policy | **needs (hard dependency)** | (a) `SaveManager.request_save(reason)` returning after the snapshot barrier, `load_slot(slot) -> LoadResult`, and all recovery/retention (C-24); (b) `Sim.deserialize()` round-trip fidelity, for the optional class (c) projection; (c) `OfflinePolicy.band_for(hour_index)` and — since RR-161 — the §2.12 **veil** budget, not a clamp on the credit (C-21 retired); (d) `NotificationPlanner.plan()` — classes, budgets, quiet hours, coalescing, event→class mapping in `data/notifications.json` (C-71). |
| **08** | provides | Implementations of `IClockSource`, `IFileSink` and `INotificationSink`; the elapsed-time measurement and `offline_rate` hook; the device-local UTC offset for quiet hours; alarm ids for `notifications.scheduled[].alarm_id`; delivery receipts (`delivered_log`) for report reconciliation. |
| **09** Map, land, districts, population & stability | needs | Land-development completion times for class (a) notifications. |
| **11** Rendering & performance | provides | Authoritative frame cap and graphics preset, with the reason (`thermal`, `power_save`, `user`). Doc 11 owns what each preset *means*; this doc owns *when* it switches. needs: `GraphicsPresets.apply(name)` and the `SubViewport` handle for idle-render suspension. |
| **12** UI/UX & onboarding | provides | `catchup_progress` for the veil, `catchup_finished(summary)` for the WHILE YOU WERE AWAY modal, permission state for the Settings rows. needs: the rationale modal, the Settings → Notifications page (whose toggles write doc 08's prefs), the Battery Saver toggle, the "Report a problem" screen. |

## 6. MVP Cut

**Milestone A — first build on a real device (target: day 1 of Android work).**
Ships: prebuilt-template debug APK (no Gradle yet — fastest possible path to validating the device, drivers, and Vulkan), `arm64-v8a`, debug keystore, `adb install` loop, back-button handling, pause/resume with save + elapsed measurement + catch-up + report, perf HUD overlay, `CrashSentinel`. **No notifications, no plugin, no permissions beyond Godot's defaults.**
Rationale for prebuilt-first: the Gradle path has more failure modes (SDK licences, JDK mismatch, Gradle daemon), and none of them should block "does the city render on the phone at all?".

**Milestone B — alpha on-device (Phase 2, spec §45).**
Adds: Gradle build template installed and committed; `SlacumNative` plugin v1 (notifications, thermal, power-save, `elapsedRealtime`, `boot_id`, launch payload); `NotificationScheduler` driving doc 08's planner over predictability classes (a) and (b) only — **class (c) projection is not built for MVP** (§2.4c); `data/notifications_text.json`; POST_NOTIFICATIONS flow; `PowerPolicy` with thermal + Battery Saver; Settings → Notifications; release-signed test APK for battery measurement.

**Milestone C — Play internal testing (Phase 4).**
Adds: release AAB, upload keystore + Play App Signing, store listing assets, Data Safety, privacy policy, content rating, 16 KB verification in the build script, pre-launch report enabled, closed-testing tester recruitment started (the 12-tester/14-day gate).

**Deferred, explicitly:** Google Play Billing and all IAP (constitution §7: no premium currency in MVP); ads; cloud save / Play Games Services; achievements and leaderboards; app shortcuts and widgets; deep links beyond the notification payload; a network crash SDK; `armeabi-v7a`; Android TV / large-screen optimisation; Play Asset Delivery; localisation beyond English.

## 7. Test Plan

### Headless tests (`tests/test_android_*.gd`, run by the existing runner)

`NotificationBridge` stubs to no-ops off-device, so everything except the Kotlin itself is headless-testable.

| ID | Case | Assertion |
|---|---|---|
| A-01 | Elapsed, normal | `raw=43 200`, `mono=43 190`, same boot → `elapsed_s = 43 200`, `ticks = 172 800` |
| A-02 | Clock moved forward | `raw=86 400`, `mono=600`, same boot → `elapsed_s = 720` (mono + 120 tolerance) |
| A-03 | Clock moved backwards | `raw = -5 000` → `elapsed_s = 0`, `anomaly = "clock_backwards"` |
| A-04 | Reboot | `boot_id` differs → mono ignored, `elapsed_s = raw` |
| A-05 | Clamp at the C-19 cap | `raw = 30 × 86 400 = 2 592 000` → `elapsed_s = 43 200` (= `offline_cap_real_ms / 1000`), `game_minutes = 43 200`, `ticks = 172 800`, `steps_total = 720`, report flagged `capped: true` with `discarded_real_s = 2 548 800` |
| A-06 | Sub-threshold | `elapsed_s = 45` → fine-tick path, `catchup_started` never emitted |
| A-07 | Delay formula | `event_gmin=14 760`, `now=12 480` → `real_delay_s = 2 280` |
| A-08 | Doze guard | `real_delay_s = 900` on a P1 warning → dropped; `= 1 260` → accepted |
| A-09 | *(deleted — rate limiting is doc 08's; see doc 08 §7)* | — |
| A-10 | *(deleted — P3 cap is doc 08's)* | — |
| A-11 | *(deleted — min-gap is doc 08's)* | — |
| A-12 | *(deleted — quiet-hours shifting is doc 08's)* | — |
| A-13 | Quiet-hours input | `local_utc_offset_s()` handed to doc 08's planner equals `Time.get_time_zone_from_system().bias × 60`, including a negative-offset and a 30-minute-offset zone |
| A-14 | Plan pass-through | Given a 9-entry plan from doc 08, exactly 9 alarms are scheduled — the shell adds no cap of its own |
| A-15 | Id allocation | Accepted list of 3 → ids `1000,1001,1002`, stable across re-runs; each id is written back into doc 08's `notifications.scheduled[].alarm_id` |
| A-16 | Scheduling horizon (classes a+b) | `now_gmin = 12 480`. A timer at `54 480` (Δ = 42 000 game-min → 42 000 real s ≤ 43 200) is **scheduled**; one at `56 480` (Δ = 44 000 real s > the 12 h cap) is **dropped**. No coarse step is executed to decide either |
| A-17 | Projection step derivation (C-23) | `projection_steps = clamp(floor(80 / m), 12, 60)`: `m = 55 → 12`; `m = 6.67 → 12`; `m = 4.0 → 20`; `m = 1.33 → 60`; `m = 0.6 → 60`. Projected span = `projection_steps` game-hours = the same number of **real minutes**, never hours |
| A-18 | Projection ≡ reality, and isolated | With projection forced on at `m = 4.0` (20 steps): project 20 coarse hours, then advance the live sim 20 coarse hours → the notified event set matches exactly; the live sim's state hash is unchanged by the projection |
| A-19 | Projection disabled + budget guard | Default config → `projection_enabled = false`, zero coarse steps run at pause, plan contains only classes (a)+(b). With it forced on and an injected `m = 200 ms` (⇒ 12 steps × 200 = 2 400 ms) ×5 samples → rolling mean > `pause_projection_abort_ms = 120` → `projection_degraded = true`, class (c) off for the session |
| A-20 | Permission FSM | never_asked→denied→denied(2nd)→`denied_permanent`; no further prompts; re-prompt only after 7 days + a P1-offline event + `reprompt_count < 2` |
| A-21 | Section round-trip | `AndroidState.deserialize(serialize())` is identity, including `delivered_log` ring truncation at 32; the section contains no `class_enabled`, `quiet_hours` or `scheduled` keys (those are doc 08's) |
| A-22 | Unclean exit | Flag present at launch → breadcrumb written, ring pruned to 5 |
| A-23 | Pause delegates persistence | One pause emits exactly one `SaveManager.request_save("pause")`; the shell opens no file under `user://saves/` itself; `android.last_pause` is present in the committed generation (stamped before the snapshot); the pause sequence never references a `.bak` file. Corruption/fallback assertions live in doc 08's test plan |
| A-24 | Power policy resolution | `thermal=3` + `power_save=true` + `high_refresh=true` → cap 30, Performance preset, reason `thermal` |
| A-25 | Thermal hysteresis | 3→2 transition does not change the cap until 30 s have elapsed at status 2 |
| A-26 | Pause budget arithmetic | Simulated step costs `1 + 25 + 80 + 30 + 110 + 1 = 247 ms ≤ 250 ms`; dropping steps 3–4 yields `1 + 25 + 110 + 1 = 137 ms`; steps 1, 2, 5, 6 always run |
| A-27 | Channel map | Plugin init creates exactly three channels — `slacum_critical` HIGH, `slacum_important` DEFAULT, `slacum_routine` LOW — mapped from doc 08's `P1_critical` / `P2_important` / `P3_routine`; `slacum_ambient` is **not** created while doc 08 ships P4 disabled |

### On-device tests (adb, manual/scripted `tools/android_smoke.sh`)

| ID | Case | Method |
|---|---|---|
| D-01 | Install + launch | `adb install -r -d`; `am start -n com.slacumcity.game/com.godot.game.GodotApp`; no `AndroidRuntime: FATAL`, no `SCRIPT ERROR` in logcat |
| D-02 | Background kill (OOM-like) | `adb shell am kill com.slacumcity.game` → relaunch → city state matches the last autosave; alarms **survive** (`dumpsys alarm \| grep slacumcity`) |
| D-03 | User force-stop | `adb shell am force-stop …` → alarms are gone (expected); relaunch rebuilds them at next pause |
| D-04 | Reboot | `adb reboot` with alarms pending → `dumpsys alarm` shows them re-armed by `BootReceiver` |
| D-05 | Doze delivery | `dumpsys deviceidle force-idle`, wait past a scheduled fire time, `dumpsys deviceidle unforce` → notification arrives within 15 min of target |
| D-06 | Notification tap, cold | Force-stop, fire a notification, tap → app launches and `consume_launch_payload()` deep-links to the incident |
| D-07 | Battery | `dumpsys batterystats --reset`; scripted 30-min session; `dumpsys batterystats com.slacumcity.game` → ≤ 6.0 %/h Balanced, ≤ 3.5 %/h Saver |
| D-08 | Frame times | `dumpsys gfxinfo com.slacumcity.game framestats` over a 60 s scripted camera pan → 99th-percentile frame ≤ 22 ms at the 60 fps cap |
| D-09 | Thermal response | Sustained 15-min play until `dumpsys thermalservice` reports MODERATE+ → confirm cap drops and no oscillation |
| D-10 | Memory | `dumpsys meminfo com.slacumcity.game` after 30 min → PSS stable within ±10 % of the 5-min reading (no leak) |
| D-11 | Permission denial | Deny POST_NOTIFICATIONS twice → app functions fully, Settings row reads "Off", no crash, no re-prompt |
| D-12 | Trim memory | `adb shell am send-trim-memory com.slacumcity.game COMPLETE` → no crash, caches dropped |
| D-13 | Manifest audit | `aapt2 dump permissions` on the release AAB → exactly the four permissions in §2.7 |
| D-14 | 16 KB alignment | `llvm-readelf -l` on every shipped `.so` → `Align 0x4000` |
| D-15 | Long absence | Set device clock +3 days, relaunch → elapsed clamps to 12 real hours (720 coarse steps), catch-up sliced, no ANR (`dumpsys activity anr` clean), report renders and states the discarded surplus |
| D-16 | Cold start | `am start -W` → `TotalTime` ≤ 4 000 ms on Tier B |
| **D-17** | **Save and load, timed** | Three cold starts, five runs each, median `TotalTime`: **A** `--esa command_line_params "--,--title"` (no city load), **B** `"--,--resume"`, **C** `"--,--resume,--save-now"`. **`B − A` is the load, `C − B` is the save** — the difference cancels process start, Vulkan init and shader warm-up, which is what makes it work with no instrumentation in the build. Provisional (workstation, `tools/profile_save.gd`, the shipped `SaveService` path): founding city **14.4 ms save / 49.2 ms load**, 1,500-building city **138 ms / 456 ms**. Expect 2–3× on device. On a telemetry build, read `PERFIO` off logcat instead. **NOT RUN 2026-08-20 — blocked twice over:** the three arms are selected by arguments and no argument arrives (D-20), and the `PERFIO` fallback could not cover the LOAD either, because `game/main.gd` set `save_service.log_io` inside `_build_city_view()` (~line 344) while the boot load runs at ~line 133. **The flag now moves to `SaveService` construction**, so the next build times the load — which is the one number §2.9's ANR arithmetic has never had. **MEASURED 2026-08-21 (third session), both rows, on the player's real 203 KB slot** — and the `SaveService`-construction fix is confirmed on device, because the boot load emitted at last: **load `ms=165.5` (`read_ms=24.0`, `restore_ms=136.2`, `bytes=202946`, `ok=1`)** and **save `reason=pause ms=159.4` (`write_ms=42.9`, `bytes=203538`, `ok=1`)**. Read for §2.9: the load is **CPU-bound on restore, not on I/O** — 24 ms of the 165.5 ms is storage and 136.2 ms is deserialisation — so the ANR margin is a restore-path question, not a flash-speed one; and both operations sit inside a 500 ms `onPause` budget with room. The save was triggered by real lifecycle backgrounding, not `--save-now`, so it is the path a player actually takes. The A/B/C `TotalTime` differential is no longer needed for these two numbers. **RE-TAKEN 2026-09-01 (`tools/run_matrix.sh` end to end, the player's 288 KB slot, fifteen load rows and one pause save): load median `ms=151.0` (`read_ms=11.4`, `restore_ms=138.9`, `bytes=288385`), spread 147.8–171.4; save `reason=pause ms=88.1` (`write_ms=43.3`, `bytes=345597`).** The slot grew 42 % and the restore grew 2 %; the save fell 45 % on a 70 % larger payload with `write_ms` flat. Full re-derivation in §2.9.1, "The budget lines, re-derived against the 2026-09-01 device numbers" |
| **D-18** | **Frame time and jank at the three poses, day and night** | Six runs: `--zoom=` 0.0 / 0.5 / 1.0 × hour 13 / hour 21, 60 s of `dumpsys gfxinfo … framestats` each. **Hour 13 is the shadow worst case and is the one that matters** — doc 11's whole measured record was taken at 21:00 with the sun down and an empty shadow pass, and daylight costs the benchmark city +142 draw calls at Z0. Gate: doc 11 §7.4's table, read against the DAY rows |
| **D-19** | **Harness pre-flight** | Before D-17/D-18: **(0) confirm the phone is UNLOCKED** — `adb shell dumpsys window \| grep mDreamingLockscreen` — because a locked device accepts `am start`, reports success, and then stops the app in 21 ms with no GDScript run at all, which is indistinguishable from a D-20 regression (2026-08-21; runbook §1.0). **(1) quote for the REMOTE shell** — `adb shell "am start … --es args '…'"`, since `adb` joins argv on spaces and `am` rejects the split tokens before launching. **(2)** confirm the launcher activity (`com.godot.game.GodotAppLauncher`). **(3)** confirm `--zoom=1.0` reaches the camera (a visible signal, not a log line). **(4)** confirm the shell actually parses the flag the session is built around — `grep -n 'road-detail\|pad-shadows\|flood-detail' game/main.gd` — three of the 2026-08-21 questions had no lever in `game/` at all. "Profile HWUI rendering" no longer matters (D-21: `gfxinfo` sees nothing here). `tools/device_runbook.md` §1 is the procedure; `tools/run_matrix.sh` runs the whole session and refuses to start on a locked phone |
| **D-20** | **Make `--esa command_line_params` reach the game** *(blocked D-17 and D-18)* | **FAILED 2026-08-20, FIXED the same day — re-run to confirm on device.** *The finding:* arguments do not reach `OS.get_cmdline_user_args()` on this export template — two runs at `--zoom=0.0` / `--zoom=0.5` produced byte-identical `dc`/`prim` sequences, and `--rain=1.0,--overlay=2` came up clear with no overlay. The city still loaded on every launch, through `CrashSentinel`'s recovery branch (`am force-stop` registers as an unclean exit), which is what disguised the fault. *The fix, and why it is where it is:* the extra is on the Intent — `GodotAppLauncher` is an `activity-alias` for `.GodotApp` and Android forwards extras across an alias — so the loss is inside the template's own command-line plumbing, which we do not patch (doc 13 §10.5: the patch set under `android/build/` is kept empty on purpose). **`SlacumNative.launch_args()` reads the Intent extras in Kotlin**, where they demonstrably survive, and **`game/dev_args.gd` merges that list with `OS.get_cmdline_user_args()`**, de-duplicating so a future engine fix cannot make `--advance-hours=4` count twice. Two extras are accepted: `--esa command_line_params "--,--resume,--zoom=1.0"` (Godot's own form, separator included) and `--es args "--resume --zoom=1.0"` (the one with no syntax to get wrong). Consumers read `DevArgs.user_args()`. **Verified off device:** `tests/test_dev_args.gd` (10 cases), `launch_args()` present in the exported APK's `classes.dex`, `aapt2` badging clean, debug APK 89.2 MB and signed. **The device half is the §1.2 probe: `--zoom=1.0` must visibly put the camera at the Z2 stop** — **RUN 2026-08-21 (third session): the transport PASSED and the receiver was MISSING.** `logcat` shows the launch reaching `am` byte-perfect in both forms, and `GodotActivity` logging `Launch intent … (has extras) with parameters []` — the engine-side drop, observed directly. But `launch_args` was absent from **all three `classes*.dex`** of the *installed* APK (control `thermal_status`: present), so `has_method("launch_args")` was false and `DevArgs.user_args()` returned empty on every launch. **Cause: `android/plugins/slacum_native.aar` is a gitignored BUILD ARTIFACT that exporting does not rebuild and a fresh `git worktree` does not contain at all.** The tree's AAR was still the 2026-08-19 build (6,201 bytes) while D-20's Kotlin landed 08-20/21; the export packaged it and nothing complained. The "verified off device" note above was taken against a tree whose AAR happened to be fresh — **an APK verification is only as good as the AAR that went into it, so verify the APK that is actually INSTALLED.** Rebuilt (35,808 bytes), re-exported, `adb install -r` (saves preserved), and confirmed on device: `tools/run_matrix.sh build_check` → `launch_args in dex: 1`. **That step is now a gate: the matrix refuses to run on a build that cannot receive arguments.** Second trap on the same path: `android/build/libs/{debug,release}/godot-lib.template_*.aar` is also gitignored, and its absence fails the export with 21 misleading `cannot find symbol: variable super` errors in `GodotApp.java` whose real first error is `package org.godotengine.godot does not exist` |
| **D-21** | **Replace `gfxinfo` with the `PERF` line everywhere** *(new)* | **`dumpsys gfxinfo` measures nothing on this app** — every `framestats` read returned `Total frames rendered: 0` and the `4950ms` sentinel, because Godot renders through a `SurfaceView` and never touches HWUI. Verified 2026-08-20. D-18's "60 s of `dumpsys gfxinfo … framestats`" is unrunnable as written; `adb logcat -s godot:V \| grep '^PERF'` is the replacement and carries `dc`, `prim`, `vram` and the chunk census besides |

**The runbook.** `tools/device_runbook.md` is the whole session as commands — the
retry loop that gets a sleeping Fold back on the wire, the pre-flight, the six
Wave-8 questions with their exact poses and expected columns, and a workstation
provisional in every cell so a device number that disagrees is a finding rather
than a surprise. It was written on 2026-08-20 during a 45-minute window in which
the device never appeared (135 polls, zero endpoints), and it drives the
**installed** build: the user's saves are in that app's private storage and there
is no export path, so nothing in it installs, reinstalls or uninstalls anything.

**It was then run, the same day.** The file now opens with a box recording what
it got wrong — the launcher activity name, the argument delivery (D-20) and the
whole of its `gfxinfo` instrumentation (D-21) — and its Fold columns are filled
in or explicitly left as em-dashes. Results in doc 11 §2.13, "Fold 6 measured";
raw captures in `tools/device_results/`. **Add one line to the top of the next
session's checklist:** back the saves up with `adb exec-out run-as
com.slacumcity.game tar czf - -C /data/data/com.slacumcity.game/files saves`
before the first launch. The generational ladder keeps three entries, and a
dozen relaunches rotate the player's pre-session city off the device — this
session's backup is the only surviving copy of the city as it stood at 14:00.

**Run again 2026-08-21, against the D-20 build. Three further blockers, none of
them D-20** (doc 11 §2.13, "The 2026-08-21 session"). The checklist above is
still right and is still not sufficient; add these three, in this order.

1. **`adb shell` re-splits the command — quote for the REMOTE shell.** `adb`
   joins everything after `shell` with single spaces and hands one string to the
   device's `sh -c`, so `--es args "--resume --zoom=1.0"` arrives at `am` as
   three tokens and dies with `IllegalArgumentException: Unknown option:
   --zoom=1.0` before the app launches. The `--esa` form survived only because
   its CSV has no spaces — so **the `--es args` half of D-20's two-form
   insurance had never once reached hardware.** Send
   `adb shell "am start -n … --es args '…'"`, which is what
   `bench_device.sh`'s `remote_start_cmd` now composes.
2. **Confirm the phone is UNLOCKED before anything else** (runbook §1.0). A
   locked device answers `adb`, accepts `am start` and reports success, but the
   app gets `OnResume → OnPause → OnStop` in 21 ms and no GDScript ever runs —
   which presents exactly as "D-20 has regressed" or "the telemetry is not
   armed". `mCurrentFocus` is the field that moves; `mResumedActivity` keeps
   naming the game behind both a lockscreen and another app.
3. **Confirm the shell parses the flag before planning a window around it.**
   `--road-detail`, `--pad-shadows`, `--flood-detail` and `--flood` were
   `tools/profile_frame.gd`-only; nothing in `game/` parsed them, so three of
   the session's five questions were undrivable *independently* of argument
   delivery. `game/main.gd`'s `_apply_render_ab_args()` closes that and needs a
   build.

**D-20's own device half is still unconfirmed** — the probe needs a surface, and
the phone never gave one. What *is* confirmed on device: Godot's own reader
returns `[]` even when `--esa command_line_params` is delivered correctly
(`GodotActivity: Launch intent … with parameters []`), so the plugin is the only
delivery path and the `--es args` form that feeds it is the one that had to be
quoted right.

**One question closes without a surface.** The game resolves to the **stock
vendor GPU driver** — `Adreno 0762.41`, built 2025-09-19,
`/vendor/lib64/hw/vulkan.adreno.so`, both updatable-driver opt-in lists `null` —
so the Qualcomm pre-release driver is not a suspect for the presentation-
corruption bands, and "switch to the stable driver" is not an available
mitigation because it already is stable.

### Device matrix

| Tier | Representative | Android | Purpose | Perf target |
|---|---|---|---|---|
| A — flagship | Pixel 9 / Galaxy S24 class | 15+ | Ceiling, 120 Hz opt-in, thermal headroom | 60 fps High |
| **B — reference** | Pixel 7a / Galaxy A54 class | 13–15 | **All balance and battery numbers are defined on this tier** | 60 fps Balanced |
| C — min spec | Any Adreno 610 / Mali-G52, 4 GB RAM | 10 (API 29) | minSdk floor, Vulkan baseline, worst case | 30 fps Performance |
| D — OEM hostile | Any Samsung One UI + any Xiaomi MIUI | any | Process-killer and autostart-restriction behaviour for D-02…D-05 | n/a |
| E — emulator | `system-images;android-37;google_apis;x86_64` | 37 | Lifecycle, permissions, notification logic in CI. **Never** for perf | n/a |

**Tier A has a real device against it as of 2026-08-20, and it did not meet the
row.** Galaxy Z Fold 6 (Adreno 750, Android 16, inner panel **1856 × 2160 at
120 Hz**) auto-detected into **Balanced, not High**, and on the player's own
70-building city it held 60.6–96.6 fps ungoverned but fell to **53.8 fps with
the governor four rungs down** on the more expensive captures. The tier's "60 fps
High" target is therefore **unverified and looks optimistic**: the frame is
GPU-bound on fragments at a 2.90 MP render target (`render_scale` 0.85), with the
CPU at 0.5–0.8 ms of its 4 ms budget. Note also that this row's "Pixel 9 /
Galaxy S24 class" representative is a **1080p-class** phone; a 4 MP foldable is a
materially harder tier-A device and the matrix does not currently distinguish
them. Doc 11 §2.13 has the numbers.

Axes to cross: {A, B, C} × {permission granted, denied} × {battery saver on, off}. D-tier runs only the lifecycle/notification subset.

## 8. Tunables — `data/android.json`

```json
{
  "schema_version": 1,

  "time_bridge": {
    "time_scale_gmin_per_rsec": 1.0, "offline_rate": 1.0,
    "clock_tolerance_s": 120, "silent_catchup_threshold_s": 60, "silent_catchup_max_ticks": 240
  },
  "//time_bridge": "offline_max_hours DELETED (report 98 C-19) — read data/time.json catchup.offline_cap_real_ms (doc 01, 43200000 ms = 12 real h = 720 game-h).",

  "lifecycle": {
    "pause_budget_ms": 250, "stamp_budget_ms": 1, "snapshot_barrier_budget_ms": 25,
    "projection_budget_ms": 80, "schedule_budget_ms": 30, "save_commit_wait_budget_ms": 110,
    "pause_projection_abort_ms": 120, "projection_cost_samples": 5,
    "catchup_slice_ms": 12, "catchup_veil_min_steps": 5
  },
  "//lifecycle": "serialize/write budgets, autosave_interval_s, autosave_on_purchase_over and save_backup_depth DELETED (report 98 C-24) — snapshot, encode, write, cadence and retention are doc 08 (data/persistence.json, doc 08 §2.6/§2.7).",

  "notification_platform": {
    "projection_enabled": false,
    "projection_steps_min": 12, "projection_steps_max": 60,
    "doze_slop_s": 900, "min_useful_lead_s": 300,
    "delivered_log_capacity": 32, "id_base": 1000, "cancel_all_on_resume": true,
    "text_file": "data/notifications_text.json",
    "lead_s": { "P1_critical": 0, "P2_important": 0, "P3_routine": 0 },
    "channels": {
      "P1_critical":  { "id": "slacum_critical",  "importance": "high",    "vibrate": true,  "sound": true,  "create": true },
      "P2_important": { "id": "slacum_important", "importance": "default", "vibrate": false, "sound": true,  "create": true },
      "P3_routine":   { "id": "slacum_routine",   "importance": "low",     "vibrate": false, "sound": false, "create": true },
      "P4_ambient":   { "id": "slacum_ambient",   "importance": "min",     "vibrate": false, "sound": false, "create": false }
    }
  },
  "//notification_platform": "plan_horizon_hours, max_per_wake, max_p3_per_wake, max_per_day, min_gap_s, quiet_hours_*, quiet_shift_max_s and the thresholds block DELETED (report 98 C-23, C-71, C-72) — budgets, quiet hours and event→class mapping are doc 08 (data/notifications.json); in-app banner rates are doc 12 (data/ui.json in_app_alerts). projection_steps = clamp(floor(projection_budget_ms / measured_coarse_ms), 12, 60), where measured_coarse_ms comes from doc 08's P0-27 benchmark.",

  "permission_flow": {
    "reprompt_max": 2, "reprompt_cooldown_days": 7, "reprompt_requires_missed_p1": true
  },

  "power": {
    "default_fps_cap": 60, "high_refresh_fps_cap": 120, "idle_fps": 30,
    "battery_saver_fps": 30, "low_battery_percent": 20,
    "thermal_recover_s": 30, "thermal_poll_fallback_s": 10,
    "thermal_rules": [
      { "status": 0, "fps_cap": 60, "preset": null,          "shadow_distance_mul": 1.0, "particle_mul": 1.0 },
      { "status": 1, "fps_cap": 60, "preset": null,          "shadow_distance_mul": 1.0, "particle_mul": 1.0 },
      { "status": 2, "fps_cap": 45, "preset": null,          "shadow_distance_mul": 0.7, "particle_mul": 0.5 },
      { "status": 3, "fps_cap": 30, "preset": "performance", "shadow_distance_mul": 0.0, "particle_mul": 0.25 },
      { "status": 4, "fps_cap": 30, "preset": "performance", "shadow_distance_mul": 0.0, "particle_mul": 0.0 },
      { "status": 5, "fps_cap": 30, "preset": "performance", "shadow_distance_mul": 0.0, "particle_mul": 0.0 },
      { "status": 6, "fps_cap": 30, "preset": "performance", "shadow_distance_mul": 0.0, "particle_mul": 0.0 }
    ],
    "battery_saver_effects": { "weather_vfx_mul": 0.5, "glow_resolution_scale": 0.5,
                               "night_light_lod_bias": -1 },
    "targets": { "drain_pct_per_hour_balanced": 6.0, "drain_pct_per_hour_saver": 3.5,
                 "cold_start_ms": 4000, "frame_p99_ms_at_60": 22.0 }
  },

  "build": {
    "package_id": "com.slacumcity.game", "min_sdk": 29, "target_sdk": 37, "abis": ["arm64-v8a"],
    "version_code_formula": "major*10000 + minor*100 + patch",
    "max_base_install_mb": 150, "required_so_alignment_bytes": 16384
  },

  "diagnostics": {
    "breadcrumb_ring": 5, "breadcrumb_event_count": 64, "breadcrumb_error_count": 20,
    "perf_csv_ring": 3, "perf_sample_hz": 1,
    "play_crash_rate_ceiling": 0.0109, "play_anr_rate_ceiling": 0.0047
  }
}
```

## 9. Conflicts & Open Questions

### Conflicts with the parent spec

1. **Spec §21.1 — RULED, AMENDMENT APPROVED (report 98 §12).** The clause "When background execution occurs or the app reopens, advance the simulation" has its **first clause struck**: §21.1 now reads *"When the app reopens, advance the simulation mathematically."* **Catch-up-on-resume is the architecture; no background simulation ships, ever.** §2.1 carries the argument (Android 14 foreground-service types alone are fatal; OEM killers and Play vitals make it worse; partial background progress would break constitution §5 determinism). Constitution §4 already specified resume-only measurement, so no constitutional amendment was needed. This is no longer a request — it is a ruling, and the rest of this doc is written on top of it.
2. **Spec §22 assumes notifications can describe emerging events.** Ruled by report 98 C-23 and now settled by construction rather than by look-ahead: predictability classes (a) deterministic timers and (b) pre-rolled Director events cover the vertical slice out to the full 12-hour cap with **no** projection. The dependency that matters is therefore doc 07 pre-rolling forecastable events (§5). If doc 07 rolls disasters lazily during catch-up instead, storm-warning notifications become impossible and spec §22's flagship example dies — class (c) projection cannot rescue it, because it buys 12–60 real minutes of look-ahead, not hours.
3. **Spec §27.3 lists Google Play Billing under the Android Native Layer.** Deferred entirely — constitution §7 forbids premium currency in MVP, and adding the Billing library changes the Data Safety declaration. Recorded here so the omission is intentional, not an oversight.

### Conflicts with the repo as it stands

4. **`.gitignore` line `android/build/` must change. — DONE, see §10.5.** Shipped with the three exclusions asked for, plus `android/build/libs/` (the 215 MB of engine AAR, each file over GitHub's 100 MB limit) and the paths the exporter regenerates on every export. `export_presets.cfg` is committed, `export_presets.cfg.secret` stays ignored, and 4.7.2 has no keystore fields in the preset at all (§10.2), so the secrets story only got safer.
5. **`project.godot` needs four additions** before Milestone A: `quit_on_go_back=false`, `keep_screen_on=true`, `enable_frame_pacing=true`, `swappy_mode=2`. These are shell concerns; requesting permission to add them in the Milestone A commit.

### Ruled since the last revision — recorded, not open

6. **Offline cap — RULED (C-19).** 12 real hours, owned by doc 01 in `data/time.json`. This doc's `offline_max_hours = 72` is deleted; the old open question ("should the cap be 72 h with a grace rule?") is closed with it. The grace behaviour it asked for already exists in a stronger form: doc 08 §2.3 rule 1 allows at most one pre-warned Tier-1 Director hazard per catch-up, in the FULL band only, zero on casual (report 98 C-55).
7. **Doc numbering — RULED (Ruling Zero).** The on-disk filenames are canonical. §5's table is corrected: persistence/offline/notification policy is **08**, the Weather & Disaster Director is **07**, incidents & dispatch is **06**, buildings & construction is **02**, economy is **03**. This doc no longer guesses a number anywhere.
8. **Notification copy ownership — RULED (C-71).** `data/notifications_text.json` is owned here (§3.1.1), keyed by doc 08's convention, reviewed by whoever owns tone. Notification *policy* is doc 08's; the in-app banner gate is doc 12's.
9. **Notification rate limiting — RULED (C-71/C-72).** This doc's parallel limiter is deleted. One push budget exists, doc 08's: global 8 per rolling 24 h, ≥ 5 min between any two, per-class buckets and quiet hours as in doc 08 §2.13.

### Open questions for the overseer

10. **Offline rate.** 12 real hours away = 30 game-days at the locked 60× scale (§2.3 worked example) — and, after C-19, that is *also* what a three-day absence returns. Is that the intended feel, or should doc 08 apply an `offline_rate < 1.0` (e.g. 0.25, making a full-cap absence ≈ 7.5 game-days)? This doc supports either via one tunable, but the answer changes how much a returning player has to read. **Recommendation: keep 1.0 for the vertical slice and revisit after the first WHILE YOU WERE AWAY report is playable.**
11. **Autosave cadence on Android (needs doc 08).** This doc's §1 gate — ≤ 60 s of play lost to process death — needs a 60 s foreground autosave; doc 08 §2.7 currently specifies 5 real minutes. Android is the platform where process death is routine, not exceptional. **Recommendation: doc 08 adds a platform-supplied `autosave_interval_s` and this doc requests 60 s on Android.** If doc 08 declines, the §1 gate relaxes to ≤ 5 minutes and should be restated there rather than left aspirational.
12. **Pause save must be non-blocking (needs doc 08).** §2.2 requires `request_save("pause")` to return after the snapshot barrier (≤ 25 ms) and finish encode/write on doc 08's worker. Doc 08 §2.6 permits blocking up to 400 ms on a `pause` trigger, which would exceed this doc's 250 ms pause budget by itself. **Recommendation: doc 08 exposes the wait as `await`-able so the shell can overlap it with notification scheduling, as §2.2 step 5 assumes.**
13. **Godot exporter key drift.** ~~The `export_presets.cfg` block in §3.4 is written from the 4.2–4.4 key set…~~ **CLOSED — the diff is done, §10.2 carries the real 4.7.2 key set.**
14. **Prebuilt-template first, or Gradle from day one?** §6 recommends prebuilt for Milestone A to decouple "does it render on the phone" from Gradle toolchain risk. The cost is one pipeline switch a few days later. If the overseer prefers a single pipeline forever, Milestone A goes straight to Gradle and accepts the added first-build risk. **Resolved as written: Milestone A shipped prebuilt, the switch to Gradle happened in one commit (§10) and cost nothing but this section.**

---

## 10. As shipped — Gradle pipeline and `SlacumNative` v1

Written from the commit that flipped the pipeline, against Godot 4.7.2.stable on
the machine in §2.0. Everything below was **verified by building**, not inferred;
where reality disagreed with the design, reality is recorded and the reason given.

### 10.1 What is on disk

| Path | What it is | Committed? |
|---|---|---|
| `android/.build_version` | `4.7.2.stable` — the engine the template belongs to | yes |
| `android/.gdignore` | keeps the editor from importing 200 MB of build system | yes |
| `android/build/**` | the Gradle build template, unzipped from `android_source.zip` | yes, minus the generated paths below |
| `android/build/libs/**` | `godot-lib.template_{debug,release}.aar`, 215 MB of engine | **no — see §10.5** |
| `android/plugins/slacum_native.gdap` | tells the exporter where the plugin binary is | yes |
| `android/plugins/slacum_native/**` | the Kotlin sources + their own Gradle build | yes |
| `android/plugins/slacum_native.aar` | the built plugin, 6 KB | no — built by `tools/setup_android.sh` |
| `tools/setup_android.sh` | restores both AAR sets after a clone or an engine upgrade | yes |
| `tools/build_native_plugin.sh` | builds the plugin AAR alone | yes |
| `game/android_native.gd` | the `Engine.has_singleton` bridge | yes |

`tools/reinstall_android_template.sh` from §2.10 was **not** written as a separate
script: `tools/setup_android.sh` does that job, because the patch set is empty
(as designed) and re-unzipping the template is therefore the whole procedure. The
moment a patch exists, it goes to `tools/android_patches/*.patch` and that script
grows a reapply step — the hook is documented in its header.

> **CORRECTED 2026-08-20 (Wave 12). The patch set was NEVER empty, and the
> reapply step the paragraph above defers has been written.** `unzip -o
> android_source.zip` overwrites every committed file the template also carries,
> and a file-by-file comparison against the 4.7.2 template settles the size of
> it: **of the 34 tracked files under `android/build/` that the zip carries, 33
> are byte-identical and exactly one is ours** —
> `android/build/res/values/themes.xml`. It holds two deviations, both §2's:
> `android:windowBackground` `#050a13` on `GodotAppMainTheme` (the fourth surface
> in the no-white-flash chain, after the export preset's
> `screen/background_color`, `project.godot`'s `boot_splash/bg_color` and the 3D
> clear colour), and the removal of `android:windowSplashScreenBrandingImage`,
> which points at a `@drawable/splash_branding_image` that neither this project
> nor the template ships.
>
> So running `tools/setup_android.sh` on a working clone silently reverted the
> dark window background and the next debug build flashed white on launch. That
> is the shell-polish branch's deviation 5, and it is closed:
> `tools/android_patches/0001-themes-dark-window-background.patch` is the patch,
> and `setup_android.sh` applies every `tools/android_patches/*.patch` with
> `patch -p1 --forward` immediately after the unzip and before the plugin build.
> A patch that already applies in REVERSE is skipped rather than re-run, so the
> script is idempotent; a patch that applies **neither** way is a hard stop with
> the file named, which is the whole reason to ship a patch rather than a copy of
> the file — a Godot upgrade that moves those lines has to be noticed.
>
> **Verified end to end in a worktree, 2026-08-20**, in three steps, all
> reproducible: (1) a bare `unzip -o` of just that file leaves
> `git status --porcelain android/build/res/values/themes.xml` reporting ` M` and
> the diff is exactly the two hunks; (2) the patch step restores it **byte for
> byte** — `git status` empty; (3) a full `tools/setup_android.sh` run
> (215 MB unzip + Kotlin plugin build, `BUILD SUCCESSFUL`) leaves
> `git status --porcelain android/` **completely empty**, with no `.rej` and no
> `.orig` anywhere under `android/build/`.
>
> **And the exporter does not undo it.** `themes.xml`'s own header says it is
> "auto-generated during export", which would make the patch pointless at build
> time. Measured: `godot --headless --export-debug "Android"` completes (the
> gradle log shows it passing `--background_color #050a13` to the splash), and
> the file is **unchanged afterwards** — `diff` empty, `git status` empty. The
> exporter writes `res/drawable/` and `res/mipmap*/` (both `.gitignore`d) and
> leaves `res/values/themes.xml` alone on this template.

### 10.2 `export_presets.cfg` — the real 4.7.2 key set (closes §9.13)

Deltas from the §3.4 block, all verified against a successful export:

* **`plugins/<PluginName>=true` is a required preset key.** It is generated at
  runtime, one per `.gdap` found under `res://android/plugins/`, and it defaults
  to **false** — a plugin that is present but not listed is silently left out of
  the build, which is exactly what happened on the first attempt here (the APK
  built fine and simply had no plugin in it). `plugins/SlacumNative=true` is now
  in the preset. Godot also *refuses* to export when a plugin is enabled and
  `use_gradle_build` is false, which is the check that makes the coupling safe.
* **`keystore/*` keys do not exist in the preset any more.** 4.7.2 takes the debug
  keystore from editor settings (`export/android/debug_keystore*`) and the release
  one from `GODOT_ANDROID_KEYSTORE_RELEASE_*`. §2.10's env-var discipline is
  unchanged and no secret can leak through the committed file — there is now
  literally no field to leak through.
* **Keys that exist in 4.7.2 and were not in §3.4:** `gradle_build/gradle_build_directory`,
  `gradle_build/android_source_template`, `package/exclude_from_recents`,
  `package/show_in_app_library`, `package/show_as_launcher_app`,
  `graphics/opengl_debug`, `screen/edge_to_edge`, `screen/background_color`,
  `command_line/extra_args`, and at preset level `patches`, `seed`,
  `encrypt_pck`, `encrypt_directory`, `encryption_*_filters`, `script_export_mode`,
  `dedicated_server`, `advanced_options`.
* **`screen/support_small`** is `true` in the repo, not §3.4's `false`. Left alone:
  it is not this doc's call to change a shipped screen-support matrix in a build
  commit.
* **`min_sdk` / `target_sdk` are only accepted when `use_gradle_build=true`.**
  With the prebuilt template Godot rejects the whole preset as misconfigured, so
  the two settings move together — which is also why the size comparison in §10.4
  needed the fields blanked.

**targetSdk is 36, not §2.0/§2.12's 37.** The template pins `compileSdk = 36`
(`android/build/config.gradle`), and a `targetSdk` above `compileSdk` is a build
this project has no reason to attempt. The SDK dir does contain a
`platforms/android-37.0` package, but its `source.properties` reads
`AndroidVersion.ApiLevel=37.0` — not an integer API level and not what AGP 8.6.1
consumes. **37 becomes reachable when the engine's template moves to
`compileSdk 37`, not before**; Play's one-year window does not bite for this
milestone. §2.12's "targetSdk 37" row is therefore aspirational until then.

### 10.3 Toolchain reality

* `platforms;android-36` and `build-tools;36.1.0` were **not installed** and had to
  be added (`sdkmanager "platforms;android-36" "build-tools;36.1.0"`). §2.0's table
  listed 36.0.0/37.0.0 build-tools, neither of which is the `36.1.0` the template
  pins. Recorded so the next machine is provisioned in one go.
* `godot --headless --path . --install-android-build-template` **does not work**:
  it installs nothing and never returns (reproduced on this project and on an
  empty scratch project). The standalone tool is editor-side; headless falls
  through it. §2.10's documented manual equivalent — unzip `android_source.zip`
  into `android/build/`, write `android/.build_version` — is what actually works
  and is what `tools/setup_android.sh` does. The `.gdignore` file the editor also
  writes is created by hand there.
* No NDK is required for the app build (nothing compiles native code; the engine
  arrives prebuilt in the AAR) even though `config.gradle` declares an
  `ndkVersion`. AGP 8.6.1 warns that it was tested only up to `compileSdk 35`; the
  build is otherwise clean.
* First Gradle build ≈ 60 s; a repeat export with a warm daemon and unchanged
  sources is **≈ 5 s end to end** (52 Gradle tasks, all up to date). Both are far
  under §2.10's 3–5 min estimate, because the Maven and Gradle caches on this
  machine were already populated — a genuinely cold machine still pays for
  Gradle 8.11.1, AGP 8.6.1 and Kotlin 2.1.21 downloads on the first run.
* The plugin AAR builds in ≈ 35 s cold, under 1 s warm, through the template's
  own `gradlew`.

### 10.4 APK size — Gradle vs prebuilt template

Same tree, same debug build, `arm64-v8a` only, measured three ways:

| Build | APK | vs prebuilt |
|---|---|---|
| Prebuilt template (what shipped at Milestone A) | 35 385 245 B (33.7 MiB) | — |
| **Gradle, `compress_native_libraries=false` (shipped)** | **87 665 826 B (83.6 MiB)** | **+52.3 MB** |
| Gradle, `compress_native_libraries=true` | 38 446 566 B (36.7 MiB) | +3.1 MB |

**The +52 MB is packaging policy, not payload.** `lib/arm64-v8a/libgodot_android.so`
is byte-identical in all three (same CRC, 76 181 608 B): the prebuilt path deflates
it to ~25 MB inside the APK, the Gradle path with `compress_native_libraries=false`
stores it raw so the loader can `mmap` it straight out of the APK. The device pays
*less* total storage for the uncompressed build — one copy at 87.7 MB against
38.4 MB of APK plus ~77.5 MB extracted — and gains the 16 KB page alignment §2.12
requires (verified: every `LOAD` segment reports `Align 0x4000`). The honest
Gradle-vs-prebuilt overhead, measured like-for-like, is the **+3.1 MB** row:
the plugin (6 KB) plus AGP's androidx additions and resources.

Two caveats for the release build, neither of them a surprise:

1. This is a **debug** APK, so the engine `.so` is the unstripped debug template.
   The engine archives it comes from are `godot-lib.template_debug.aar` at 112.7 MB
   against `godot-lib.template_release.aar` at 103.3 MB, and the release `.so` is
   stripped on top of that — so the release APK is a different measurement, not a
   scaled one, and it has not been taken yet (no release keystore on this machine).
2. `config.gradle` would default `useLegacyPackaging` to **true** at `minSdk ≤ 29`,
   citing godot#108842 for API-29 device compatibility. The preset overrides that
   to false per §3.4. The Z Fold 6 is Android 16, so nothing in the test matrix
   exercises the case — **flagged for the device matrix, not for this commit.**

### 10.5 `.gitignore` (closes §9.4, with one amendment)

§9.4 asked for `android/build/` to become source with three exclusions. Shipped as
asked, **plus `android/build/libs/`**, and that addition is not optional: the two
`godot-lib.template_*.aar` files are 112 MB and 103 MB, and GitHub rejects any file
over 100 MB. They are also verbatim engine payload — not ours, not patched, and
reproducible in one command — so they fail the "is it source?" test on the merits
as well as on the mechanics.

Ignored beyond §9.4's three: `android/build/src/main/assets/` (the exported game,
rewritten every export), `android/build/src/{debug,release}/AndroidManifest.xml`
(generated from the preset), `android/build/res/mipmap*/` and `res/drawable/`
(launcher icons and splash, generated from `game/branding/`),
`android/build/res/values*/godot_project_name_string.xml` (40-odd locale files
whose own first line reads *"WARNING: THIS FILE WILL BE OVERWRITTEN AT BUILD
TIME"*), and the plugin's own `build/`, `.gradle/`, `local.properties` and built
`.aar`. Total committed footprint under `android/`: **43 files, 166 583 B**, the
largest of them the 59 KB Gradle wrapper jar.

### 10.6 `SlacumNative` v1 — what the plugin actually contains

§2.6 specifies the full Kotlin surface. **Shipped now (the time and power half):**

```kotlin
fun elapsed_realtime_ms(): Long              // SystemClock.elapsedRealtime()
fun boot_id(): String                        // /proc/sys/kernel/random/boot_id
fun thermal_status(): Int                    // PowerManager.getCurrentThermalStatus()
fun is_sustained_performance_supported(): Boolean
fun set_sustained_performance(on: Boolean)
// signal thermal_status_changed(Int)        // addThermalStatusListener, push
fun launch_args(): Array<String>             // D-20; Intent extras, verbatim
```

**`launch_args()` is not in §2.6's original surface** — it exists because D-20
found that nothing else could get an argument into the game on device. It reads
`command_line_params` (string array) and `args` (string, whitespace-split) off
`activity.intent`, appends them in that order, and does **not** strip them: unlike
a notification deeplink, a dev argument is *supposed* to survive a rotation and to
answer the same way each of the three times `game/main.gd` asks. Everything about
what an argument MEANS stays in `game/dev_args.gd` and `game/main.gd`, which is
the same boundary the rest of this plugin keeps.

**Not yet built:** every notification, permission and alarm method
(`schedule_notification`, `cancel_*`, `scheduled_ids`, `notifications_enabled`,
`permission_state`, `request_notification_permission`,
`open_app_notification_settings`, `consume_launch_payload`), plus
`is_power_save_mode`, `battery_percent`, `is_charging` and `display_refresh_hz`.
Those are the Milestone B half (§6) and they bring `AlarmReceiver`,
`BootReceiver`, `filesDir/notif_schedule.json` and the four permissions of §2.7
with them. The manifest this plugin ships today declares **no permissions at all**,
which is why the debug APK's permission set is still Godot's default.

Mechanics worth recording:

* **Registration is v2 manifest meta-data**, not the `.gdap`:
  `org.godotengine.plugin.v2.SlacumNative` → the class name, inside the AAR's own
  manifest. The `.gdap` only feeds `-Pplugins_local_binaries` to Gradle. 4.7.2
  writes no v1 metadata of its own, so there is exactly one registration path and
  no risk of the plugin being instantiated twice.
* **Compiled against `org.godotengine:godot:<android/.build_version>`** from Maven
  Central, `compileOnly`, and against the template's own `config.gradle` version
  pins (AGP 8.6.1, Kotlin 2.1.21, Java 17, `compileSdk 36`). The plugin build
  borrows `android/build/gradlew`, so the repo has exactly one Gradle version and
  it is the engine's.
* `GodotPlugin.runOnUiThread` is deprecated in 4.7; `runOnHostThread` is the
  replacement and is what `set_sustained_performance` uses.
* The plugin's `minSdk` is 29 because `addThermalStatusListener` is 29 — the same
  floor as the app, so no API guards are needed anywhere in the file.

### 10.7 Elapsed time now has both bounds (implements §2.3)

`AndroidLifecycle.measure_elapsed` was the "plugin-free half": monotonic as a
lower bound only. With the plugin it brackets the wall clock from both sides —
floor `Time.get_ticks_msec()`, ceiling `elapsed_realtime_ms() + clock_tolerance`,
the ceiling disabled whenever `boot_id()` differs from the one stamped at pause
(or is unreadable, or the reading went backwards). `last_anomaly` gains
`"clock_forward"` alongside `"clock_backwards"`, and `last_cross_checked` says
whether the ceiling applied at all.

Two deliberate readings of §2.3's pseudocode, both covered by tests in
`tests/test_android_native.gd`:

1. §2.3 returns `0` with `anomaly = "clock_backwards"` when `raw_s < 0`. The repo
   returns the **monotonic delta** instead, which is a strictly better lower bound
   and was already shipped and tested. Kept; the ceiling is layered on top rather
   than replacing it.
2. §2.3 writes `min(raw_s, mono_s + tolerance)`. Implemented exactly, with the
   tolerance added once — the two clocks are sampled milliseconds apart and
   neither is a stopwatch.

Sustained performance mode is turned on once, from `AndroidLifecycle._ready()`,
and thermal transitions are re-emitted as `AndroidLifecycle.thermal_status_changed`
so doc 11's power policy has one node to listen to. Off-device — desktop, the
headless runner, a prebuilt-template APK — `AndroidNative.detect()` finds no
singleton and every one of these paths is skipped, which is asserted directly.

### 10.8 The debug APK declares zero permissions

`aapt2 dump permissions build/slacum-debug.apk` prints the package line and
nothing else. §2.7 expected `INTERNET` to be injected into debug exports; on the
Gradle path 4.7.2 does not inject it, and the plugin's manifest declares nothing,
so **the permission set is empty in debug as well as release**. Two consequences:

* Good: the §2.10 permission gate now passes on every build, not just release,
  and the "no data collected" Data Safety story is true of the artefacts a tester
  might sideload.
* **Open:** the editor's remote debugger and profiler talk to the device over TCP
  and therefore need `INTERNET`. Nothing in the current loop uses them — logcat
  and the on-device perf HUD cover it — but if remote debugging is wanted, the
  fix is `permissions/custom_permissions=PackedStringArray("android.permission.INTERNET")`
  on a **debug-only preset**, never on the one that produces the AAB. That is a
  reason to split the presets the way §3.4 always intended, and it is the only
  argument for doing so that this commit found.

**Superseded by §11.2** — and that supersession is CORRECT, re-verified Wave 14
on a locally built debug APK. This section's own measurement was taken before the
plugin manifest carried §2.7's four; once it did, the merged manifest carries
them into every build, debug included. `aapt2 dump permissions build/slacum-debug.apk`
returns exactly the four and nothing else. See report 98 §29 RR-70 for the 2×2
that settles which file supplies them (either does) and for what the third Fold
session's zero-permission reading actually was (a stale AAR).

The **`INTERNET`-for-remote-debugging** note above still stands unchanged: it is
still absent, still deliberately, and the fix is still a debug-only preset if it
is ever wanted.

---

## 11. As shipped — Milestone B: notifications, release signing, store assets

Written from the commit that closed doc 91 §15 items 8 and 15. As in §10,
everything below was **verified by running it**; where reality disagreed with the
design, reality is recorded with the reason.

### 11.1 `SlacumNative` v2 — the notification half exists now

§10.6 listed the notification, permission and alarm surface as "not yet built".
It is built. The plugin is now four Kotlin files (~700 lines):

| File | What it is |
|---|---|
| `SlacumNative.kt` | the `@UsedByGodot` surface: time, thermal, permissions, channels, post/schedule/cancel, launch payload |
| `NotificationCenter.kt` | channels, `AlarmManager`, the notification build, and `filesDir/notif_schedule.json` |
| `AlarmReceiver.kt` | posts a scheduled notification **with the game process dead** — the entire point of the feature |
| `BootReceiver.kt` | re-arms the schedule after a reboot, dropping whatever is already past |

Six decisions worth recording, because each of them looks like a bug from the
outside:

1. **No `androidx`.** §2.6 specified `NotificationCompat` and a
   `androidx.core:core-ktx` dependency in the `.gdap`. The framework's own
   `Notification.Builder` + `NotificationChannel` cover everything this plugin
   does at minSdk 29, so the dependency is gone and the `.gdap`'s `remote=[]` list
   stays empty. One fewer version to keep in step with the engine's own androidx.
2. **The alarm `PendingIntent` carries the id in its `data:` URI**, not only in
   its extras. `PendingIntent` equality ignores extras entirely, so two alarms
   that differ only by extras collapse into one and the second silently
   overwrites the first. This is the single most common `AlarmManager` bug there
   is, and the URI is what makes ids independent.
3. **The tap intent is resolved through `getLaunchIntentForPackage`**, not by
   naming `com.godot.game.GodotApp` as §2.6 wrote. The host activity is the
   *template's* business; hardcoding it would break the day the template renames
   it, and the package manager already knows the answer.
4. **`notifications_enabled()` is the question that matters**, not
   `permission_state()`. The per-app master switch exists on every API level and
   no permission state reports it, so the shell asks both: the state drives the
   prompt flow, `areNotificationsEnabled()` drives whether anything is posted.
5. **`denied_permanent` is inferred**, because Android exposes no such state:
   not granted + asked at least once + the system now declining to show a
   rationale. The "asked at least once" bit lives in the plugin's own
   `SharedPreferences`, since `shouldShowRequestPermissionRationale` is also
   false *before* the first ask and reading it alone would report every fresh
   install as permanently denied.
6. **Both receivers are `exported="false"`.** Nothing outside the package has any
   business firing a Slacum notification, and the system holds the alarm's
   `PendingIntent` directly, which needs no export.

### 11.2 The four permissions are real now

> **RE-VERIFIED Wave 14, and this section was right.** The 2026-08-21 Fold
> session read `dumpsys package` on a build that requested no permissions at all
> and concluded that this section's `aapt2` block had been written from intent
> rather than from a binary. It had not: a fresh export whose plugin AAR carries
> §2.7's four and whose preset does not still requests all four, because manifest
> merging carries `<uses-permission>` (report 98 §28 RR-69's 2×2). The build on
> the phone was made against an AAR that predated the permission block — the
> stale-AAR root cause the previous session had just fixed by tracking the
> binary. `export_presets.cfg` now declares the four as a **second** source, so
> the set survives a stale AAR; §2.7 carries the current `aapt2` output.

The plugin's manifest declares `POST_NOTIFICATIONS`, `RECEIVE_BOOT_COMPLETED`,
`VIBRATE` and `WAKE_LOCK` — §2.7's list, exactly, and nothing else. Verified on
the built artefacts rather than on the source:

```
$ aapt2 dump badging build/slacum-release.apk
package: name='com.slacumcity.game' versionCode='400' versionName='0.4.0' compileSdkVersion='36'
minSdkVersion:'29'   targetSdkVersion:'36'   native-code: 'arm64-v8a'
uses-permission: name='android.permission.POST_NOTIFICATIONS'
uses-permission: name='android.permission.RECEIVE_BOOT_COMPLETED'
uses-permission: name='android.permission.VIBRATE'
uses-permission: name='android.permission.WAKE_LOCK'
```

No `INTERNET`, which is what keeps the Play Data Safety form at "no data
collected"; no `SCHEDULE_EXACT_ALARM` or `USE_EXACT_ALARM`, which is why every
alarm is inexact and why the copy never states a time. `tests/test_release_plumbing.gd`
holds the manifest to the same list without building anything, so the two halves
of the gate fail in different places for the same reason.

### 11.3 Offline scheduling: what the city can honestly promise

`game/notifications/notification_scheduler.gd` implements §2.4's classes (a) and
(b) and nothing else — class (c) projection ships disabled, as ruled.

* **(a) deterministic completions.** Doc 01 §2.11's conversion,
  `real_ms = (due_tick − now_tick) × 250`, lives here and nowhere else. Two
  sources feed it: any `TimerService` entry flagged `notify_offline` (whose
  `due_tick` is already absolute), and the construction queue.
* **Construction needed a derivation §2.4 did not anticipate.** §2.4 assumed
  `ConstructionQueue.pending_completions()` with a `completion_gmin` already in
  it. There is no such field: a job carries *work units*, and its rate is crew ×
  site multiplier × the `construction_rate` **day curve**. So the shell walks the
  curve hour by hour, accumulating exactly as `ConstructionQueue.advance()` does,
  and returns the tick the job crosses its requirement. `tests/test_android_notifications.gd`
  asserts the prediction against the real queue actually running, which is the
  only honest test of a derived time. A job with no crew returns "no date" rather
  than a guess.
* **(b) forecast hazards** come from `DisasterDirector.forecast_queue()`, which
  doc 07 already pre-rolls and commits to the save — the hard dependency §5 named,
  and it is met. Scheduled only at `confidence ≥ 0.80` and only with a positive
  warning lead.
* **Two guards drop things on purpose:** anything beyond `catchup.offline_cap_real_ms`
  (the sim will not have reached that tick when the player returns) and anything
  inside `doze_slop_s + min_useful_lead_s = 1 200 s` (it would arrive after the
  event). Both are recorded in `last_drops` with a reason, so a missing
  notification is explainable rather than mysterious.

### 11.4 The budget rewind — spending tokens on a future that may not happen

Doc 08 §2.13 says the plan is budgeted *at scheduling time*, with the buckets
simulated forward. That is what `NotificationRouter.plan_offline()` does, and it
raises a question the docs do not answer: what happens to those spent tokens when
the player comes back in five minutes and every alarm is cancelled unfired?

Answer, implemented in `replan_after_resume()`: the budget is **snapshotted**
before the offline pass, and on resume the snapshot is restored and only the
entries whose fire time has already passed are re-spent. A player who checks in
constantly gets their whole budget back; one who stays away keeps the cost of the
notifications they actually received. No delivery receipt is involved, which
matters — the receipt only exists when the process happened to be alive when the
alarm rang.

That rewind exposed a real defect in `NotificationBudget.deserialize()`: it
*merged* `last_class_min` / `last_key_min` instead of replacing them, so a restore
left stamps from the discarded timeline behind and would have muted the next real
notification of that key for its whole cooldown. It replaces now. The same bug
would have bitten a checkpoint rollback, which is doc 08's own use of that method.

### 11.5 Release signing, end to end

`tools/make_release.sh` builds the AAB and the release APK and verifies both.
Signing is env-only (`GODOT_ANDROID_KEYSTORE_RELEASE_PATH` / `_USER` /
`_PASSWORD`); the script refuses to run without them, refuses a keystore that
lives inside the repository, and opens the keystore with `keytool` before it
builds anything so a wrong password fails in two seconds rather than after two
Gradle builds.

A **real** upload keystore now exists at
`~/.local/share/godot/keystores/release.keystore` (4096-bit RSA, 30 years,
PKCS#12, alias `slacum-upload`, mode 600), created by `--init-keystore`. The
passphrase is in the environment and in a password manager and **nowhere in this
repository** — there is no `.env`, no `secrets.sh`, and 4.7.2's preset has no
keystore field to leak through in the first place (§10.2). We enrol in Play App
Signing, so this is the *upload* key: losing it is a support ticket, not the end
of the listing.

Verified output of one run:

| | AAB | release APK |
|---|---|---|
| size | 31 084 058 B (30 MiB) | 82 398 019 B (79 MiB) |
| version | 0.4.0 / 400 | 0.4.0 / 400 |
| min / target SDK | 29 / 36 | 29 / 36 |
| ABI | `arm64-v8a` | `arm64-v8a` |
| permissions | 4 | 4 |
| signature | jar verified, `slacum-upload` | APK Signature Scheme v2, `CN=Slacum City` |
| 16 KB alignment | 2 `.so`, every LOAD `0x4000` | 2 `.so`, every LOAD `0x4000` |

Three corrections to §2.10, all found by running it:

1. **`aapt2` cannot read an AAB at all** — `dump badging`, `dump permissions` and
   `dump xmltree` all answer `could not identify format of APK`, because every
   `dump` subcommand expects a *binary* manifest inside an APK and an AAB carries
   aapt2's **protobuf** encoding. Google's answer is `bundletool`, a 60 MB jar
   that is not in the SDK. `tools/aab_badging.py` reads the protobuf directly
   (150 lines, no dependency, four field numbers from `Resources.proto`) and is
   what the permission gate uses for the bundle.
2. **`jarsigner -verify` reports "jar is unsigned" on a correctly signed APK.**
   Godot writes only an APK Signature Scheme v2/v3 block at minSdk 29 — v1 has
   been optional since API 24 — so the APK needs `apksigner` and the AAB, which
   is still plain jar-signed, needs `jarsigner`. Two formats, two verifiers.
3. **`readelf -l` wraps program headers over two lines**, so the alignment check
   needs `-W`; without it the check reads the wrong word and passes anything.

**Not reproducible byte-for-byte**, and it is the signature's fault rather than
the build's: two runs of the same tree produced an identical AAB
(`f3edbace…9961` twice) and two different APKs (`9af9710c…bad6`, `afa31d99…fa62`),
because the v2 signature block is timestamped. Recorded rather than chased.

### 11.6 Crash sentinel, and what an unclean exit falls back to

*Rewritten 2026-08-19 (Wave 7). This section specified a two-slot autosave
rotation — slot 0 alternating with a shadow at slot 7 — and **doc 08 §2.7's
ruling retired it** ("the ladder subsumes doc 13's autosave shadow"). What
follows is what `game/save_service.gd` and `sim/persistence/save_manager.gd`
actually do.*

`game/crash_sentinel.gd` implements §2.11's local breadcrumb ring: a flag at
launch, deleted by the pause sequence, and an `incident_<unix>.json` written when
the next launch still finds it. No network, no SDK, no Data Safety impact —
**the hook point for a future reporter is `breadcrumb_path()`** and it is
documented in the class rather than built.

The part §2.11 did not specify is what an unclean exit should *do*, and the
answer needs somewhere to fall back to. Four rules answer it.

**Every autosave lands on slot 0.** `SaveService.autosave()` is
`save_slot(sim, AUTOSAVE_SLOT, "autosave")` and nothing else; `next_autosave_slot()`
returns `0` unconditionally and `autosave_slots()` is a one-element array, kept
as an array only because callers iterate it. **Slot 7 is a player slot again.**

**The depth moved inside the slot.** A slot is a doc 08 generation ladder —
`user://saves/slot_0/gen_000042.sav` beside a `manifest.json` whose rename is the
commit point — retaining at most **6 unpinned + 2 pinned** generations, the five
fallbacks spread across **0 / 30 min / 6 h / 24 h / 7 days**
(`data/persistence.json.save`, read through `sim/persistence/save_policy.gd`, so
the ladder is retunable without a code change). An unclean exit that ate the
newest write falls through to the generation behind it and to four more behind
that, where the rotation bought exactly one fallback.

**And the fallback is verified before it is offered.** `last_good_autosave_slot()`
runs doc 08 §2.9's candidate walk — decompress, envelope parse, SHA-256 of the
body, version range, structural check — rather than the whole-file parse the
rotation used. It is a **probe**: nothing is quarantined, nothing is
deserialized, and no `failed` signal is emitted, because a damaged checkpoint
found by a health check is an expected finding and not an error to put in front
of a player. `CrashSentinel.recovery_slot()` asks it first and falls back to
`latest_slot()`, exactly as this section always specified.

**One thing outlives the rotation: the files.** A phone upgrading from a build
that alternated still has a format-1 `user://saves/slot_7.json` on disk, and it
is the *newer* half half the time. `SaveService.LEGACY_AUTOSAVE_SHADOW_SLOT = 7`
is kept for that read alone — never written again, consulted only when the ladder
is empty — so an upgrading player's first unclean launch does not cost them the
interval the rotation existed to save. It stops mattering the moment the first
post-upgrade autosave commits generation 1.
`tests/test_save_migration.gd::test_an_upgrading_phone_still_finds_the_shadow_it_arrived_with`
holds that path open.

What this defends against is unchanged, and it is the reason any of it exists:
not a torn file (the atomic rename already makes that impossible) but a
*complete* one written seconds before the process died.

### 11.7 S10, and what a settings row is allowed to write

`data/ui.json.settings.rows` gains five toggles: the master switch, one per
enabled class, and doc 08 §2.13.3's quiet-hours critical bypass. The row key **is**
the class id lowercased (`P1_critical` → `notify_p1_critical`), so `data/ui.json`
and `data/notifications.json` cannot drift; `NotificationRouter.apply_settings()`
is the only writer and it writes to `NotificationBudget`, never to a second copy
of the policy. All five are device-scoped (`user://settings.cfg`), per doc 08
§2.13.4: a player who turned notifications off stays off across city deletion.

P4 has no row, because it has no channel and the budget refuses to enable it.
Doc 12 §2.13's "P3 routine off by default" is **superseded**: C-71 made doc 08
sole owner of that answer and `data/notifications.json` says on.

### 11.8 `data/notifications.json` gains a `delivery` block

One block in doc 08's file is doc 13's (the policy/platform line, not a
file/file line): ids (`id_base = 1000`), the Doze feasibility numbers
(`doze_slop_s = 900`, `min_useful_lead_s = 300`), `cancel_all_on_resume`, the
channel-name string prefix, and `offline_sources` — which events are predictable
at pause time and by which class. No budget, no classes, no quiet hours.

Channel *names* come from `data/strings.en.json` (`ui_notif_channel_<class>`),
not from a second copy file: §3.1.1's `data/notifications_text.json` is
**withdrawn** in favour of G-8's one string table, which is what doc 12 §5 already
records doc 13 as rendering from. Two tables would let a push and its in-app row
drift apart by one careless edit, and that is precisely what G-8 exists to stop.
`NotificationText.clock_time_offenders()` is the test hook that keeps §2.6's "never
state a time" rule enforceable rather than aspirational.

### 11.9 Store assets

`tools/gen_store_assets.py` produces the whole Play listing set, deterministically:

* **icon 512×512** and **feature graphic 1024×500**, drawn from `tools/gen_icon.py`'s
  authored skyline coordinate system — the feature graphic is the same mark and
  the same lit window as the launcher icon and the boot splash, at a third crop;
* **five screenshots × three form factors** (phone 1920×1080, 7" 2048×1152, 10"
  2560×1440), landscape, re-rendered at each aspect rather than upscaled:
  `night_skyline`, `dusk_skyline` and `night_storm` off `game/showcase.tscn` (the
  scene that exists to be the frame the project is marketed on), plus
  `power_overlay` and `first_run` off `game/main.tscn`, so the listing shows the
  real HUD and not only the hero renders.

Screenshots run under `xvfb-run` when there is no display, and every frame is
checked for flatness before it is accepted — a black rectangle that exits 0 is
the failure mode `--headless` produces and the one worth catching here rather
than in the Play review queue. Output goes to `build/store/` and is gitignored:
the generator is deterministic, so the repository keeps the recipe and the
Console keeps the pixels.

### 11.10 Still open after this commit

> **RE-SWEPT 2026-08-21 (doc 91 §20.5's marker sweep).** Three Fold sessions have
> run since this list was written and it had never been re-read against them.
> Two bullets close, one halves, two stand. Each is marked in place; the original
> wording is kept struck rather than deleted, because the list's value is that it
> was right about what would be hard.

* ~~**Nothing consumes the thermal ladder** (§2.8) — `AndroidLifecycle` forwards
  the status and no policy acts on it. Unchanged by this commit, still doc 11's.~~
  **CLOSED 2026-08-20 (Fold session 1).** `game/render/perf_governor.gd` consumes
  it, and it was watched doing so on hardware: the `PERF` line reported
  `thermal=0` then `thermal=1` (NONE → LIGHT) pushed through
  `AndroidNative.thermal_status_changed`, and the governor stepped `knob` 0 → 4 in
  the foreground. **What is still unproven is the heat half**, and that is §2.8's
  row, not this bullet's: the Fold sat at 45.7–49.6 °C and was *cooling*, so no
  thermal step-DOWN was ever exercised, and battery (D-07) was never measured.
* **On-device verification** (§7's D-01…D-16) is **partly run, and the alarm path
  still has not fired.** Three sessions: 2026-08-20 (governor and `PERF` on
  device), 2026-08-21 (the plugin registers; the AAR staleness found), and the
  matrix session that established the transport. ~~this commit was built and
  tested off-device by instruction~~ — that premise is retired. What has *not*
  happened is unchanged and is the one this bullet was written for:
  **`dumpsys alarm | grep slacumcity` after a pause has never been read**, and
  no notification has ever been posted by this app on real hardware. Blocked
  behind the permission gap in the row below.
* **`consume_launch_payload()` has no consumer — HALF CLOSED 2026-08-21.** The
  *warm* path is wired: `game/main.gd:129` connects
  `android_lifecycle.native.notification_opened` and `main.gd:1473`'s
  `_on_notification_opened(payload)` routes all four payload forms
  (`overlay/…` → the overlay rail, `incident/…` → the drawer, `building/…` →
  `camera_state.focus_on`, `report` → S11). **The cold-start path is not:**
  `AndroidNative.consume_launch_payload()` (`game/android_native.gd:304`) has no
  caller anywhere outside the plugin, so a tap that *launches* the app lands on
  the city rather than on the thing the notification was about. Same few lines as
  before, now on a smaller surface — one call at the end of boot.
* **`targetSdk` is 36, not §2.0/§2.12's 37**, for the reason §10.2 records: the
  template pins `compileSdk 36`. Unchanged — and now **confirmed on the installed
  artefact** rather than on the preset (Fold session 1, `dumpsys package`).
* **The pause pass now posts in-session events, and that is a policy question.**
  `NotificationRouter.plan_for_background()` flushes the queued in-session
  candidates before it plans the offline future — doc 08 §2.13's shipped
  behaviour, pinned by `tests/test_notifications.gd` §30. With an inert sink that
  flush was free; with a live one it *posts*, immediately, as the app goes away,
  and it spends tokens the offline plan then does not have. Two readings, and
  this doc does not own the answer:
  - **as shipped:** the player just backgrounded the app with a fire burning, and
    a buzz on the way out is the point of the feature;
  - **the alternative:** they were looking at the city when it happened and
    already saw the in-app alert, so the push is the same news twice and the
    token would be better spent on the storm at 03:00.
  Recommend the overseer rules; the change is one line either way.

---

## Amendments applied (report 98)

Every row of this doc's worklist in report 98 §12, with what changed and where.

| Ruling | Change |
|---|---|
| **Ruling Zero** (canonical doc numbering) | §5's cross-reference table renumbered to the on-disk filenames: persistence/offline/notifications **10 → 08**, Weather & Disaster Director **08 → 07**, incidents & dispatch **07 → 06**, buildings & construction **03 → 02**, economy **02 → 03**; doc 09 retitled *Map, Land, Districts, Population & Stability*. Every in-body reference (§2.3, §2.4, §2.9, §4, §6, §9) fixed to match. The old "doc numbers assumed…" disclaimer and open question 8 are deleted — no number in this doc is a guess. |
| **C-04** (no `platform/` layer) | §1 and §2.1 state the ruled structure: the shell is `game/android/*` (GDScript) plus a Kotlin AAR under `android/plugins/slacum_native/` (build-system territory, not a source layer). Constitution §3's four layers stand; `sim/` reaches Android only through `IClockSource` / `IFileSink` / `INotificationSink`, whose implementations are listed in §4. Doc 08's proposed fifth layer is withdrawn. |
| **C-19** (offline cap = 12 real hours) | `offline_max_hours = 72` **deleted** from §8; §2.3 now reads `catchup.offline_cap_real_ms = 43 200 000` from doc 01's `data/time.json`. Branch table, clamp, both worked examples and test **A-05** recomputed: `elapsed_s = 43 200 s`, `game_minutes = 43 200`, `ticks = 172 800`, `steps_total = 720` = 720 game-hours = **30 game-days** (was 4 320 game-hours = 180 game-days). A 72-hour absence now discards 60 real hours and reports it. |
| **C-23** (look-ahead horizon off by 60×) | §2.4 restructured by predictability class. (a) deterministic timers and (b) pre-rolled Director events need **no projection** and are scheduled to the full 12-hour cap. (c) emergent projection is budget-bounded — `projection_steps = clamp(floor(80 / measured_coarse_ms), 12, 60)` = **12–60 coarse steps = 12–60 game-hours = 12–60 real minutes** — and **ships disabled**. `plan_horizon_hours = 24` deleted (it was 24 real *minutes*, not hours). Tests **A-16..A-19** rewritten: horizon at the cap, the clamp table, projection ≡ reality at 20 steps, and the disabled-by-default + budget-guard case. |
| **C-24** (persistence belongs to doc 08) | §2.2 pause step 3 is now `SaveManager.request_save("pause")`. The `city.tmp → city.json` write, the 3-deep `city.bak` rotation, the launch fallback chain and the `saves_recovered_from_backup` counter are **deleted** — recovery, quarantine, retention and the 7-check load gate are doc 08 §2.6/§2.7/§2.9. The ≤ 250 ms budget and the lifecycle ordering are kept, with the step arithmetic restated (`1 + 25 + 80 + 30 + 110 + 1 = 247 ms`). `save_backup_depth`, `serialize_budget_ms`, `write_budget_ms`, `autosave_interval_s` and `autosave_on_purchase_over` deleted from §8. Test **A-23** recomputed as a delegation assertion; **A-26** added for the budget arithmetic. |
| **C-71** (one notification owner per layer) | §2.5 rewritten as the platform half only. The parallel rate limiter and its constants (`max_per_wake`, `max_p3_per_wake`, `max_per_day`, `min_gap_s`, `quiet_hours_*`, `quiet_shift_max_s`) and the `thresholds` block are **deleted**; this doc consumes doc 08's `NotificationPlanner.plan()` and `data/notifications.json`. The three Android channels are mapped explicitly to **P1_critical / P2_important / P3_routine** (P4 has no channel while doc 08 ships it disabled). This doc keeps `data/android.json` (platform config) and gains `data/notifications_text.json` (copy, §3.1.1). Save section trimmed to the registry's three responsibilities; tests A-09..A-12 deleted, A-13/A-14 repurposed, **A-27** added. |
| **C-72** (budgets differ 3×) | The §1 success-criteria row "≤ 3 per offline session, ≥ 30 min apart" is replaced by doc 08's budget: **global 8 per rolling 24 h, ≥ 5 min between any two**. This doc enforces no volume rule of its own. |
| **C-25** (`section_version`) | No change required — `save.android` already used `section_version`; this doc is not listed under C-25. Recorded so the next reader does not re-check. |
| **Spec §21.1 amendment** | **APPROVED** and recorded in §9 item 1: the background-execution clause is struck, catch-up-on-resume is the architecture, and no background simulation ships. It is stated as a ruling, not a request, in §1 and §2.1 as well. |

**Deliberate readings, flagged rather than assumed.**

1. Report 98 C-23 phrases the emergent budget as "12–60 game-minutes of real-world look-ahead". Its own arithmetic — and C-23's headline that 24 coarse game-hours = 24 real minutes — makes a coarse step one game-hour, so `clamp(…, 12, 60)` steps buys 12–60 game-**hours** = 12–60 real **minutes**. The formula is implemented verbatim; the units are stated the way the arithmetic requires.
2. The report does not rule on autosave cadence, but C-24 gives doc 08 persistence outright, so this doc deleted its own `autosave_interval_s = 60` rather than keep a second cadence. The resulting gap against the ≤ 60 s process-death gate is raised as open question 11 instead of being papered over.
3. Doc 08 §2.6 allows a `pause` save to block for 400 ms, which cannot coexist with this doc's kept 250 ms budget. Rather than change either number, §2.2 requires the wait to be `await`-able and overlapped; open question 12.

---

## Wave 17 — the pause stamp as built, and the ANR arithmetic with the clamp (2026-09-01)

*Appended rather than woven in: sibling branches are editing this document in the
same wave. Report 98 §48 (RR-132 … RR-134) carries the rulings; this section
carries what §3.2 and §2.9 now say.*

### §3.2 — `save.android.last_pause`, as built

The section existed on paper and in no save file. It does now, at
`section_version = 1`, written by `game/android/lifecycle_stamp.gd` through
`AndroidLifecycle.capture_stamp` and `SaveService.android_provider` (the same
shape of contract `ui_provider` has had since doc 12 §3.2). §3.2's field list is
built exactly as specified:

```jsonc
"android": {
  "section_version": 1,
  "last_pause": {
    "unix_s": 1800000000,          // the pause, or the save, per `clean`
    "elapsed_realtime_ms": 88123456,  // -1 without the plugin
    "boot_id": "3f2a…c19",            // "" without the plugin, and "" is NEVER "same boot"
    "clock_ticks": 49920,             // the generation's own tick index
    "app_version": "0.4.0",
    "clean": true,                    // stamped at APPLICATION_PAUSED, not at an autosave
    "unfinished": { … }               // Wave 17: the unspent tail of an interrupted catch-up
  }
}
```

Three things §3.2 did not say, and now does:

1. **The stamp rides EVERY save, not only the pause.** §2.2's step table says
   "must precede the snapshot", and it still does — `_on_paused` writes the
   members before `_autosave()`. But a periodic autosave the process was killed
   two seconds after is just as much "the last time this city was awake", and the
   launch that has to measure the absence cannot know which generation it will
   find. `clean` is the field that tells a lifecycle pause from any other save,
   and it is what the ruling in report 98 §48 leans on.
2. **`unfinished`.** The unspent segments of a catch-up the process died in the
   middle of, carrying each partially-spent coarse segment's original
   `index_base` and `total`, plus the away report's pre-absence snapshot. See
   §2.9 below.
3. **It is registered on the WRITE side only.** `SaveManager._validate_structural`
   files a `repair_notes` entry for every registered section a body is missing,
   and every generation ever written predates this one. The read side takes the
   section out of the loaded body directly. Doc 08 §2.8 / RR-75 terms are
   otherwise unchanged: version 1, no migrator, no epoch marker owed.

### §2.3 / §3.2 — the elapsed-time rule on a COLD launch

§2.3's bracket (monotonic floor, `elapsedRealtime` ceiling) is about a process
that lived through the absence. A process that did not has no monotonic reading
to compare against — `Time.get_ticks_msec()` restarts at 0 — so the cold path has
its own arithmetic, in `LifecycleStamp.elapsed_since`, and it is three readings in
a fixed order of precedence:

| # | Reading | Role | When it applies |
|---|---|---|---|
| 1 | `manifest.max_seen_unix` (doc 08 §2.9) | **absolute** — credit zero | `now + 120 s < max(max_seen_unix, stamp.unix_s)` |
| 2 | `SystemClock.elapsedRealtime()` delta | **ceiling** | same `boot_id`, both known |
| 3 | `SystemClock.elapsedRealtime()` absolute | **floor** | `boot_id` CHANGED — a reboot |

Row 3 is the one §3.2 only gestured at with *"a reboot resets elapsed_realtime —
boot_id decides"*. What it decides, concretely: a changed boot id means the
device restarted **during** the absence, so the absence is at least as long as the
device has been up, and `elapsedRealtime` stops being a ceiling and becomes a
floor. A wall clock claiming less than that has lost time and is raised to it.
The 120 s tolerance on all three is §2.3's own, unchanged — the two clocks are
sampled milliseconds apart and neither is a stopwatch.

Off device (no plugin ⇒ `elapsed_realtime_ms = -1`, `boot_id = ""`) only row 1
applies, which is exactly what desktop and the headless runner have always done.

### §2.9 — the ANR arithmetic, with the clamp and with the interruption

**The clamp.** §2.9's table was parameterised on `measured_coarse_ms` with
`max_coarse_hours` as a promise. Both halves are now numbers (doc 08 §2.12, report
98 §48 RR-133): **5.488 ms/hour** on the reference city and **165.493 ms/hour** on
the 1,500-building bench fixture, this workstation, `tools/profile_sim.gd
--coarse-hours=48 --repeats=3`. The shipped clamp is **360 game-hours**.

| City | ms/hour | Steps at the clamp | Wall time | Frames at 12 ms | On the Fold (§2.13, 3–5×) |
|---|---|---|---|---|---|
| Starter (reference) | 5.488 | 360 | **1.98 s** | 165 | 5.9 – 9.9 s |
| Bench (1,500 buildings) | 165.493 | 360 | **59.6 s** | 360 | 3 – 5 minutes |

> **AMENDED 2026-09-03 — report 98 §58, RR-160/RR-161.** The clamp in this
> table is deleted: it bounded the *credited absence*, not the veil, and 360
> game-hours is six real hours of a player's night (doc 92 §55 prices the
> difference at **$73,511** for one eight-hour absence). Both rows above are
> therefore read at **720 steps**, not 360 — starter **3.95 s**, bench
> **119.2 s** — and the veil is measured directly now rather than multiplied out:
> **6.43 s** on a settled reference city, **116.9 s** on the bench fixture (doc 92
> §55.6). Every sentence below about ANR safety and about the interruption stands
> unchanged; only the step count doubles.

The bench row is the honest one to look at and it is why `bench_coarse_ms` is
recorded in `data/persistence.json` beside the measured veil rather than
forgotten. **ANR safety is unaffected** and is still structural, not budgetary:
the blocked frame is one whole coarse step — 165 ms on the bench city on this
workstation, 0.5–0.8 s on the Fold — against Android's 5 s line, a 6× margin at
the worst measured combination. What the bench row costs is *veil length*, not an
ANR, and a 2-minute veil is a product problem for the lead — filed as doc 92
§55.7 **AC-19-1** against the coarse step, where it belongs, rather than deducted
from the player's night.

**The interruption.** This section's own Wave-14 note said a second
`_on_app_resumed` "drains the unfinished cursor on the spot and then plans the new
absence… no worse than the frame it replaces." **That was wrong, and the row
above is the arithmetic that shows it.** Draining 720 unspent coarse steps
synchronously is `720 × 165 ms = 119 s` of blocked main thread on the bench city
— twenty-four ANRs, not one frame — and it was reachable precisely because Wave
14 had made the catch-up long enough to background out of. Report 98 §48 RR-134
replaces it: the old cursor keeps stepping under the veil, the second absence is
queued, and a pause taken in between is tagged `pause_mid_catchup` and carries the
unspent tail in `last_pause.unfinished` so a cold launch finishes the plan.

**§2.11's unclean-exit accounting is unchanged** by any of this: the clean-exit
flag still comes down at `APPLICATION_PAUSED` and back up on resume, and a
`pause_mid_catchup` save is a clean exit like any other pause.

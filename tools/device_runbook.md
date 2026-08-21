# The Fold 6 runbook — the six Wave-8 device questions, as commands

> ## READ FIRST, 2026-08-21 (third session) — the two faults that ate THIS window
>
> The box below says "three are now fixed; the fourth needs a person". The phone
> was unlocked, awake and in hand for this session, so the fourth was not the
> problem. **Two new faults were, and both are now fixed. Neither was visible
> from anything the game printed.**
>
> ### 0. The installed APK could not receive a single argument — the AAR is a gitignored artifact
>
> `SlacumNative.launch_args()` is the whole of D-20's delivery path, and it lives
> in **`android/plugins/slacum_native.aar`**, which is a **build artifact, not
> source**: exporting does not rebuild it, and it **does not exist at all in a
> fresh `git worktree`**. D-20's Kotlin landed on 2026-08-20/21; the AAR in the
> main tree was still the one built on **2026-08-19 (6,201 bytes)**. The export
> at 05:59 packaged that stale AAR, so:
>
> * `launch_args` was **absent from all three `classes*.dex`** of the installed
>   APK, while `SlacumNative` and `thermal_status` were present — the plugin was
>   there, the method was not;
> * `AndroidNative.launch_args()` tests `_plugin.has_method("launch_args")`,
>   found `false`, and returned empty;
> * `OS.get_cmdline_user_args()` returned `[]`, as it always does here;
> * so `DevArgs.user_args()` was **empty on every launch** and every dev argument
>   was dropped in silence.
>
> **The transport was never the problem this time.** `logcat` shows the line
> arriving at `am` byte-perfect in both forms —
> `--esa command_line_params '--,--resume,--zoom=1.0,--perf' --es args '--resume --zoom=1.0 --perf'`
> — so §1.2's quoting fix is **confirmed good on hardware**. The receiver simply
> was not built.
>
> **The symptom is indistinguishable from a working session**: the city loads,
> the game renders the real save, `am start` reports success. Only the arguments
> do nothing, which reads as "the poses did not separate" — the exact 2026-08-20
> symptom, from a completely different cause. The clean discriminator, and it is
> free:
>
> ```sh
> # --perf is the ONLY thing arming telemetry (do not create the flag file first)
> bash tools/cap_pose.sh probe "--resume --perf" 20
> # 0 PERF lines  -> the argument did not arrive
> # N PERF lines  -> arguments reach GDScript
> ```
>
> It was confirmed both ways on device: with `--perf` on the command line, **0
> PERF lines**; with `touch files/perf_capture.flag` and nothing else, **19 PERF
> lines**, same build, same pose.
>
> **`tools/run_matrix.sh build_check` now checks the installed APK's own dex for
> `launch_args` (with `thermal_status` as a control) and the matrix REFUSES to
> run when it is missing.** The repair, ~4 minutes end to end:
>
> ```sh
> tools/build_native_plugin.sh --debug          # rebuild the AAR (8 s)
> godot --headless --path . --export-debug "Android" build/slacum-debug.apk
> adb install -r build/slacum-debug.apk          # -r KEEPS THE SAVES
> ```
>
> **Second gitignored-artifact trap, hit on the way:** `android/build/libs/{debug,release}/godot-lib.template_*.aar`
> (~110 MB each) is *also* absent in a fresh worktree, and the export then fails
> with **21 errors in `GodotApp.java` about `cannot find symbol: variable super`**
> — which is a red herring. The real first error is `package org.godotengine.godot
> does not exist`; the superclass is unresolvable, so every `super` reference
> cascades. Copy the two AARs from the main tree and re-export.
>
> ### 1. `run_matrix.sh` refused to run on an UNLOCKED phone, 100% of the time
>
> The lock fail-safe was written to fail closed, and it did — permanently. It
> used `printf '%s' "$d" | grep -q 'mDreamingLockscreen=false'`. `grep -q` exits
> at the first match; `printf` is still pushing the other ~200 KB, takes SIGPIPE
> and dies **141**; and under `set -o pipefail` **the pipeline takes the writer's
> failure rather than grep's success**, so a match was read as a non-match.
> Measured on an awake, unlocked, focused device: status `141` on the 200 KB dump,
> status `0` on a 25-byte test string — which is why it passed every test that
> was not a real `dumpsys`. `dumpsys window` is ~200 KB against a 64 KB pipe
> buffer, so **on a real phone it fired every time.**
>
> `cap_pose.sh`'s `is_foreground()` had the same construct, where it is *racy*
> rather than constant (`mCurrentFocus` appears early in the dump), so it
> intermittently stamped good captures `CONTAMINATED` — a guard that marks good
> data bad, on the one check the trustworthiness of every number depends on.
>
> **Both are now pipe-free**, using bash's own `==` / a line loop. The rule this
> file should have carried from the start: **never put `grep -q` downstream of a
> large writer under `pipefail`.** Use bash matching, or `grep -c` and compare.
>
> ### What this session actually measured, and what it did not
>
> Measured (doc 11 §2.13, "the 2026-08-21 session"): a foreground baseline on the
> player's real city, and **both PERFIO rows including the boot `load` line that
> had never been capturable before**. Not measured: the pose matrix, the zebra
> A/B, the flood A/B and the pad-shadow A/B — all four need arguments, and
> arguments only started working after the reinstall, by which point the user was
> using the phone. **The fixed build is installed and verified**
> (`run_matrix.sh build_check` → `launch_args in dex: 1`), so the next window
> starts at step 2 with no repair work in front of it.

> ## START HERE, 2026-08-21 — the four things that have eaten two windows
>
> **The pose matrix has never been run.** Not because the phone is slow or the
> questions are hard, but because four separate faults sit in front of the first
> frame. Three are now fixed; the fourth needs a person. Check them in this
> order — each one, when it fires, looks exactly like the next one down.
>
> 1. **Is the phone UNLOCKED?** `adb shell dumpsys window | grep mDreamingLockscreen`
>    A locked Fold answers `adb`, accepts `am start`, reports success — and then
>    stops the app 21 ms after resume, so **no GDScript runs at all**. That
>    presents as "arguments not delivered" and as "telemetry not armed". §1.0.
>    **This is what stopped 2026-08-21**, and `adb` cannot fix it.
> 2. **Is the launch quoted for the REMOTE shell?** `adb shell` joins argv on
>    spaces, so `--es args "a b"` reaches `am` as separate tokens and dies with
>    `Unknown option:` before launching. §1.2's box. Fixed in
>    `tools/bench_device.sh`; it had never worked on a device before.
> 3. **Does `game/main.gd` parse the flag you are planning the session around?**
>    `--road-detail`, `--pad-shadows`, `--flood-detail` and `--flood` were
>    `tools/profile_frame.gd`-only, so three of the 2026-08-21 questions were
>    undrivable *independently* of everything else. Now wired — **needs a build.**
> 4. **Is the build a D-20 build?** `grep -c DevArgs.user_args game/main.gd`
>    must be ≥ 4. Godot's own `command_line_params` reader returns `[]` on this
>    export template even when delivered correctly, so the plugin is the only
>    path.
>
> Then: `bash tools/run_matrix.sh` runs the whole session and **refuses to start
> on a locked phone** rather than collecting empty captures.
>
> **First command of the next session, before any of the above:**
> `adb shell run-as com.slacumcity.game rm -f files/perf_capture.flag` — it was
> left armed on 2026-08-21 when the wire dropped, and while it is there every
> player session pays a per-frame GPU timestamp query. §5 has the detail.
>
> Two standing rules, both learned expensively: **back the saves up before the
> first launch**, and **prefer one long foreground hold to many short launches**
> (the 2026-08-20 session cost the player ~12 sim-hours and ~$46K; 2026-08-21
> cost zero, because nothing ever ran).

> ## RUN ONCE, 2026-08-20 — read this box before you use anything below
>
> **The device appeared and the session ran.** Results are in doc 11 §2.13,
> "Fold 6 measured"; raw captures are in `tools/device_results/`. The window was
> about 20 minutes and ended when the user picked the phone up.
>
> **Three things in this runbook are WRONG against the shipped build. Fix them
> before the next session or lose the window the same way.**
>
> 1. **§1.1 — the launcher activity is `com.godot.game.GodotAppLauncher`**, an
>    `activity-alias` for `.GodotApp`. Not `com.godot.game.GodotApp`, which is
>    what §1.1 and `tools/bench_device.sh` say. `am start` on the old name fails.
> 2. **§1.2 — `--esa command_line_params` DID NOT REACH
>    `OS.get_cmdline_user_args()` on this export template, and is now FIXED in
>    the plugin.** The finding stands and is worth reading before you trust
>    anything below: two runs at `--zoom=0.0` and `--zoom=0.5` produced
>    byte-identical `dc`/`prim` sequences, and a run carrying
>    `--rain=1.0,--overlay=2` came up in clear weather with no overlay. The city
>    still loads on every launch, which is what disguises the fault — but it
>    loads through `CrashSentinel`'s recovery branch, because `am force-stop`
>    registers as an unclean exit, **not** through `--resume`.
>
>    **The fix (doc 13 D-20) is `SlacumNative.launch_args()`**: the Kotlin plugin
>    reads the launching Intent's extras itself and `game/dev_args.gd` merges
>    them with the engine's list, so every consumer sees one list. **It needs a
>    NEW BUILD — the installed APK does not have it.** Until you have installed a
>    build from this branch or later, §2's scenario vocabulary is still
>    unavailable and the pose matrix is still undrivable. §1.2 is now the
>    procedure for confirming the fix, and it is still the first thing you run.
> 3. **§2 — `dumpsys gfxinfo` MEASURES NOTHING on this app.** Every `framestats`
>    read returned `Total frames rendered: 0` and every percentile came back as
>    the sentinel `4950ms`, because Godot renders through a `SurfaceView` and
>    never touches HWUI. **All of §2's instrumentation is void.** Use the `PERF`
>    line instead — it works, it is in the shipped build, and it carries `dc`,
>    `prim`, `vram` and the chunk census that `gfxinfo` never had.
>
> **What §1.5 says is out of date in the good direction:** the `PERF` line *is*
> emitted by the installed build (`game/render/perf_telemetry.gd` is wired in
> `game/main.gd`), so `adb logcat -s godot:V | grep '^PERF'` is the instrument
> for everything below. `PERFIO` on **save** works; `PERFIO` on **load** could
> not, because `log_io` was set ~211 lines after the boot load — fixed in this
> branch, needs a build.
>
> **Two rules the session learned the expensive way.** *Back up the saves before
> the first launch* — `adb exec-out run-as com.slacumcity.game tar czf - -C
> /data/data/com.slacumcity.game/files saves > saves_backup.tgz` — because the
> generational ladder keeps three entries and a dozen relaunches rotate the
> player's pre-session city off the device. And *prefer one long foreground hold
> to many short launches*: each relaunch resumes the save and runs the sim, and
> this session cost the player ~12 sim-hours and ~$46K of treasury.

**Status when written: the device did not appear.** This file was written on
2026-08-20 during a 45-minute window in which `adb` was polled every 20 seconds —
135 attempts, `adb mdns services` re-run on each one, zero endpoints advertised,
zero devices authorised. Everything below was therefore a **runbook, not a
result**: the session that was prepared and could not be run, written so that
whoever next had the Fold on the wire spent the window measuring instead of
working out how. It served that purpose, and the box above is what it cost.

Every table has a **provisional** column already filled in from the workstation
(NVIDIA RTX 2000 Ada, Godot **Forward Mobile** — the same renderer the phone
runs, a very different GPU) and an empty **Fold 6** column. Every A/B in them is
interleaved *within* its round, on a machine that was carrying other Godot work
for part of the session, so **the round-paired delta is the claim and the
absolute millisecond is not**; where an arm's spread is quoted it is the real
min..max across rounds, and a delta smaller than that spread is written as
"below the noise floor" rather than as a number. The draw-call, chunk-census and
primitive columns are exact and repeat to the digit — those are the ones a device
should reproduce. The provisional
numbers are there to be *contradicted*: they say what shape the answer should
have, and a device number that disagrees by more than the stated factor is the
finding, not the noise. Doc 11 §2.13's "Fold 6 measured" table is the place the
filled-in version lands.

Read §1 before §2. Two of the three assumptions `tools/bench_device.sh` is built
on are **wrong against the shipped shell**, and a session that does not know that
collects an empty CSV and calls it a result.

---

## 0. Getting the device on the wire

Wireless debugging sleeps. The loop below is the one that has worked in this
repo; run it in a spare terminal and leave it running while you do something
else — the device tends to reappear within minutes once the screen is on.

```bash
while true; do
  dev=$(adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')
  if [ -n "$dev" ]; then echo "FOUND $dev"; break; fi
  adb mdns services | awk '/_adb-tls-connect/{print $NF}' | sort -u \
    | while read -r hp; do adb connect "$hp"; done
  sleep 20
done
```

Then, immediately, pin the endpoint so a sleep does not cost you the session:

```bash
adb devices -l                       # note the ip:port
adb shell settings put global stay_on_while_plugged_in 7   # screen stays up
adb shell svc power stayon true
```

**NEVER `adb uninstall com.slacumcity.game`.** The user's saves live in that
app's private storage and there is no export path. Everything in this runbook is
either read-only or runs against the installed build.

---

## 1. Pre-flight — six things that are not what the old harness assumes

### 1.0 The phone must be UNLOCKED, and this is check zero (2026-08-21)

**`adb` reaching the device is not the same as the device being able to run the
game, and the difference is invisible in every command above.** A locked Fold
answers `adb devices`, answers `dumpsys`, accepts `am start` and reports
`Starting: Intent {…}` exactly as it does when unlocked. `am` even resolves and
launches the activity. What it will not do is let the app hold a surface:

```
V Godot: OnResume: GodotFragment{…}
V Godot: OnPause:  GodotFragment{…}      <- 21 ms later
V Godot: OnStop:   GodotFragment{…}
```

Godot's main loop is tied to the `SurfaceView`, so **no GDScript ever runs** —
no `_ready`, no city load, no argument parsing, no `PERF` line, no screenshot.
The failure looks precisely like "the telemetry is not armed" or "the arguments
did not arrive", which is how it can eat a window: on 2026-08-21 it presented as
a §1.2 probe failure and was only distinguishable from a real D-20 regression by
reading the lifecycle callbacks.

```bash
# The check. Non-zero output means STOP and get the phone unlocked.
adb shell dumpsys window | grep -c 'mDreamingLockscreen=true'

# Only dismisses a NON-secure lockscreen. A secure one raises the Bouncer and
# there is nothing adb can do about it — it needs a human and a PIN.
adb shell wm dismiss-keyguard
```

`svc power stayon true` and `stay_on_while_plugged_in=15` keep the screen ON but
do **not** keep it unlocked, and the device may well be sitting at 100 % on AC
with the screen lit and the keyguard up. Confirm the game actually holds the
foreground before trusting any capture:

```bash
adb shell dumpsys window | grep 'mCurrentFocus'   # must name com.slacumcity.game
```

Note `mResumedActivity` keeps naming the game behind a lockscreen and behind
another app, so it is the wrong field; **`mCurrentFocus` is the one that moves.**
`tools/cap_pose.sh` asserts it before and after every hold.

### 1.1 The launcher activity

```bash
adb shell cmd package resolve-activity --brief com.slacumcity.game | tail -1
```

~~`tools/bench_device.sh` hard-codes `com.godot.game.GodotApp`.~~ **Since
2026-08-20 the script runs the line above itself, in pre-flight, and uses the
answer** — the hard-coded name is only the `--dry-run` fallback, and it is
`GodotAppLauncher` now. Confirm it anyway; an export-template change moves it and
a session that assumes it fails with a bare "Activity not started" that reads
like a crash.

### 1.2 How arguments reach the game — **do this probe first**

~~`tools/bench_device.sh` launches with `--es cmdline "…"`~~ — **it sends both
correct forms as of 2026-08-20**; the three faults below are why, and they are
readable in the source rather than guessed at:

* Godot's Android launcher reads a **string ARRAY** extra, so `--es` (a single
  string) is the wrong `am` flag; `--esa` is the one that produces an array.
* `game/main.gd` parses the merged dev-argument list, whose engine half returns
  only what follows a literal `--`. The extra must therefore CARRY the separator.
* **And on this export template the extra never arrived at all** — doc 13 D-20.
  `SlacumNative.launch_args()` now reads it off the Intent in Kotlin and
  `game/dev_args.gd` merges it with `OS.get_cmdline_user_args()`, which is what
  makes everything in §2 drivable. That fix ships in the AAR, so **it is only in
  the app once you have installed a build that contains it** — and only once
  `game/main.gd`'s own argument loop reads `DevArgs.user_args()` rather than
  `OS.get_cmdline_user_args()` directly. Both halves or neither: the plugin can
  deliver the list, but the shell has to be the thing that reads it. Confirm
  before the session, not during it:

```bash
grep -n 'DevArgs.user_args\|OS.get_cmdline_user_args' game/main.gd
```

  Three `OS.` hits and no `DevArgs` means the shell half has not landed and the
  probe below will fail no matter how good the AAR is.

> ### THE QUOTING FAULT — read this before you type either form (2026-08-21)
>
> **Both command forms as they were written below are WRONG, and the second one
> fails outright.** `adb shell` does not preserve your local argv: it joins
> everything after `shell` with single spaces and hands one string to the
> device's `sh -c`. Your own shell has already eaten the quotes by then, so
>
> ```bash
> adb shell am start … --es args "--resume --zoom=1.0"     # WRONG
> ```
>
> arrives at `am` as `--es args --resume --zoom=1.0` and dies before the app is
> launched:
>
> ```
> java.lang.IllegalArgumentException: Unknown option: --zoom=1.0
>     at android.content.Intent.parseCommandArgs(Intent.java:9908)
> ```
>
> The `--esa` form survived only because its CSV payload has no spaces in it —
> which is exactly why this went unnoticed: **the `--es args` half of the "send
> both forms" insurance had never once reached a device.** Quote for the REMOTE
> shell, i.e. put the whole command in one string:
>
> ```bash
> adb shell "am start -n com.slacumcity.game/com.godot.game.GodotAppLauncher \
>   --esa command_line_params '--,--resume,--zoom=1.0' --es args '--resume --zoom=1.0'"
> ```
>
> `tools/bench_device.sh` composes exactly this via `remote_start_cmd`, and
> `--self-test` now asserts it (`the launch is ONE remote-shell string`).
> `tools/cap_pose.sh` is the one-pose version.

Two forms work, and they are equivalent — **inside the remote quoting above**.
Godot's own:

```bash
adb shell "am start -n com.slacumcity.game/com.godot.game.GodotAppLauncher \
  --esa command_line_params '--,--resume,--zoom=1.0'"
```

and the one with no comma syntax and no separator to forget, which is the one to
reach for when a scenario has quoting in it:

```bash
adb shell "am start -n com.slacumcity.game/com.godot.game.GodotAppLauncher \
  --es args '--resume --zoom=1.0'"
```

> **And Godot's own reader is still empty on this template (re-confirmed
> 2026-08-21 against the D-20 build).** With `--esa command_line_params` sent
> correctly, `GodotActivity` still logs
> `Launch intent Intent { … (has extras) } with parameters []`. So the `--esa`
> form is *not* a working second opinion on this export template — **everything
> rides on `SlacumNative.launch_args()`**, and the `--es args` form that the
> plugin reads is the one that has to be quoted right. Grep for it:
>
> ```bash
> adb logcat -d | grep -E 'GodotActivity: Launch intent|SlacumNative.*launch args'
> ```

Pass both if you like: the merge de-duplicates, so an argument that arrives twice
is applied once. (That is not tidiness — `--advance-hours=4` counted twice would
run the city eight hours forward before the first frame.)

**Verify it with a visible signal, not with a log line.** `--zoom=1.0` puts the
camera at the Z2 stop; if the app comes up at the default mid-zoom, the arguments
did not arrive and every scenario below has to be driven by hand instead. Do this
check FIRST — it decides which half of §2 you can run.

The plugin also says so in logcat, which is the second opinion when the camera
answer is ambiguous:

```bash
adb logcat -c && adb shell am start -n com.slacumcity.game/com.godot.game.GodotAppLauncher \
  --es args "--resume --zoom=1.0"
adb logcat -d -s SlacumNative:I | grep 'launch args'
```

A line reading `launch args: [--resume, --zoom=1.0]` means the Kotlin side has
them. If that line is present and the camera still does not move, the fault is in
`game/main.gd`'s arg loop, not in delivery — which is a different bug and a much
easier one.

### 1.3 `--bench=S1|S2|S3` does not exist

> **As of 2026-08-20 `tools/bench_device.sh` no longer sends it** — the script
> was rewritten against this table (§3's closing note). The table below is still
> the authority on what the installed build understands, and it is what the
> script's `--self-test` greps `game/main.gd` for.

Doc 11 §7.4 and `tools/bench_device.sh` both drive three scenarios with
`--bench=S1 --preset=balanced --city=res://tests/fixtures/bench_city.json`.
**`game/main.gd` parses none of those three flags.** What it does parse is:

| flag | effect |
|---|---|
| `--resume` | load the newest save — **the player's own city**, which is what these questions are about |
| `--title` | open the title door (the plain-launch default) |
| `--zoom=T` | camera `zoom_t`, `0.0` = Z0, `0.5` = Z1, `1.0` = Z2 |
| `--focus=X,Z` | camera focus, WORLD METRES |
| `--advance-hours=H` | run the sim forward before the first frame |
| `--overlay=N` | select an overlay |
| `--rain=F` / `--storm=F` / `--wet=F` | pin weather |
| `--blackout` | trigger the signature moment partway in |
| `--cut-feeder=ID` | open a feeder |
| `--save-now` | autosave immediately, then print `[save-now] autosaved…` |
| `--screenshot=PATH`, `--shot-at=T` | capture |

That list is the whole scenario vocabulary available on the installed build, and
it is enough for all six questions. **Do not rebuild the app to get `--bench`.**

### 1.4 The preset does not fully reach the layers at boot

Read the graphics setting off the device before trusting any preset column:

```bash
adb shell run-as $PKG cat /data/data/$PKG/files/settings.cfg 2>/dev/null | grep -i graphics
```

`game/main.gd` calls `set_preset()` on `VehicleView` and
`ConstructionVehicleView` **only** when the player changes the settings row or
when the governor latches a preset drop — never at boot. A phone that
auto-detected into Performance therefore comes up with Balanced traffic counts
until something touches that row. It is not a large error (the vehicle layer is a
handful of draw calls) but it means **"Performance" in a boot-time capture is not
the whole Performance preset**, and a device number taken that way is not
comparable with a workstation `--preset=performance` run. Force the row through
the settings sheet once at the start of a session, or take the tier columns as
Balanced. `RoadSurfaceView.set_preset()` has the same gap and the branch report's
integration snippet closes it for all three.

### 1.5 The `PERF` line is not emitted by the installed build

`PerfGovernor.perf_line()` has existed since Wave 6 and
`tests/test_perf_governor.gd` covers its shape. **Nothing called it.** So
`adb logcat -s godot:V | grep '^PERF'` returns nothing on the installed build and
`bench_device.sh`'s own summariser prints "NO PERF LINES". `game/render/perf_telemetry.gd`
(this branch) is the wiring; it needs `game/main.gd`'s integration snippet and a
new build before any `PERF` row can be collected.

> **Amended 2026-08-20, post-integration:** the wiring landed and then was
> GATED behind `_perf_capture_armed()`, which accepts either of two arming
> switches. **`--perf` reaches the device once D-20's fix is in the build AND
> `_perf_capture_armed()` reads the merged list** (`DevArgs.user_args()` — one
> line in `game/main.gd`, which is the lead's; the branch report carries the
> snippet). With both,
>   `adb shell am start -n $PKG/$ACT --es args "--resume --perf"`
> arms the capture the way it does on the workstation. Until then — and as the
> belt-and-braces route for a session that wants the capture armed across
> relaunches without repeating the argument — use the flag file
>   `adb shell run-as com.slacumcity.game touch files/perf_capture.flag`
> (delete it to disarm; debug builds only). Without one of the two, no
> `PERF`/`PERFIO` row is emitted. Always-on it
> cost every player session a per-frame `viewport_set_measure_render_time`
> GPU timestamp query, which is the class of sync point that irritates mobile
> drivers; it was withdrawn from plain launches while chasing intermittent
> presentation-corruption bands on the Fold (horizontal glitch stripes crossing
> world AND UI — swapchain-level, seen under FIFO vsync, so not a vsync miss).
> While that investigation is open, §2's platform instruments remain the
> corruption-safe capture path. Device driver facts recorded from the first
> window: Android 16, Adreno 750 (SM8650 "pineapple"), Samsung stable
> GameDriver AND a Qualcomm pre-release driver both installed — ~~WHICH one the
> game resolves to is unverified (the window closed mid-query)~~ **ANSWERED
> 2026-08-21: the game runs on the STOCK VENDOR driver, and the pre-release
> driver is not a suspect.** Four independent confirmations, all readable with
> the phone still LOCKED (this is the one useful thing a locked device gives
> you — the process starts and logs its graphics environment before it needs a
> surface):
>
> ```
> V GraphicsEnvironment: com.slacumcity.game is not listed in per-application setting
> V GraphicsEnvironment: App is not on the allowlist for updatable production driver.
> V GraphicsEnvironment: No special selections for ANGLE, returning default driver choice
> I AdrenoVK-0: Driver Path : /vendor/lib64/hw/vulkan.adreno.so
> ```
>
> and `settings get global updatable_driver_prerelease_opt_in_apps` → `null`
> (production opt-in likewise `null`; both allowlist and denylist empty). The
> resolved driver is **Adreno `0762.41`**, QUALCOMM build `f6b5df5188`, built
> **2025-09-19**, shader compiler `E031.45.02.26`, branch
> `AU_LINUX_ANDROID_LA.VENDOR.14.3.0.11.00.00.974.010`, `Build Config S P 16.1.2
> AArch64`. **Record that string with any corruption-band report** — it is the
> driver the bands were seen on, and "move it to stable" is not an available
> mitigation because it already is stable.

**Therefore §2 is written entirely against PLATFORM instruments** — `gfxinfo`,
`SurfaceFlinger`, `meminfo`, `thermalservice`, `am start -W` — which work against
the app as installed. §3 lists what the telemetry build adds.

---

## 2. The six questions, as commands against the installed build

Common preamble for every run:

```bash
PKG=com.slacumcity.game
ACT=com.godot.game.GodotAppLauncher   # the activity-alias; `.GodotApp` fails (§1.1)
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
# Developer options → "Profile HWUI rendering" MUST be OFF (not "bars on screen"),
# or framestats reports the profiler instead of the game.
```

Every measurement is: reset, run, read.

```bash
adb shell dumpsys gfxinfo $PKG reset
# ... play the pose for 60 s ...
adb shell dumpsys gfxinfo $PKG framestats > framestats_<label>.txt
```

`framestats` gives 120 rows of nanosecond timestamps per read; the frame time is
`FRAME_COMPLETED − INTENDED_VSYNC` per row. The one-liner that turns a capture
into the columns this runbook wants:

```bash
python3 - framestats_<label>.txt <<'PY'
import sys, statistics
# framestats columns (stable across Android versions for the ones used here):
#   0 FLAGS   1 INTENDED_VSYNC   ...   13 FRAME_COMPLETED
# A nonzero FLAGS marks a frame the platform says not to count (first frame after
# a resume, a window layout, …). Counting them is the classic way to invent jank.
rows = []
for line in open(sys.argv[1]):
    p = line.strip().split(',')
    if len(p) <= 13 or not p[0].isdigit():
        continue
    if int(p[0]) != 0:
        continue
    try:
        rows.append((int(p[13]) - int(p[1])) / 1e6)
    except ValueError:
        pass
rows = [r for r in rows if 0 < r < 500]
rows.sort()
n = len(rows)
q = lambda f: rows[min(n - 1, int(f * n))]
print("n=%d  mean %.2f  p50 %.2f  p95 %.2f  p99 %.2f  max %.2f  "
      "jank>16.7 %.1f%%  jank>33 %.1f%%"
      % (n, statistics.mean(rows), q(.50), q(.95), q(.99), rows[-1],
         100 * sum(r > 16.7 for r in rows) / n,
         100 * sum(r > 33.3 for r in rows) / n))
PY
```

One `framestats` read returns at most 120 frames, i.e. two seconds at 60 Hz — so a
60-second hold needs the read repeated. Loop it:

```bash
for i in $(seq 1 30); do
  adb shell "dumpsys gfxinfo $PKG framestats" >> framestats_<label>.txt
  sleep 2
done
```

> **`gfxinfo` on a Godot app measures the SurfaceFlinger side of the frame, not
> the renderer's own GPU time.** It is the right instrument for jank (it is what
> doc 11 §7.4's jank gate is written against) and the wrong one for "how long did
> the asphalt shader take". Where a question needs the second thing, this runbook
> says so and answers it by A/B instead of by absolute time.

### Q1 — frame time and jank at Z0/Z1/Z2, day and night, Balanced

Six poses. Each one: launch pinned to the pose, let it settle 10 s, reset
gfxinfo, hold still 60 s, read.

**`--advance-hours` is a DELTA, not an hour of day.** It advances the city clock
from wherever the save happens to sit, so the difference has to be computed
against the save's current hour. Getting this wrong is the easiest way to spend a
device window measuring dusk twice.

> **Do not read it off the HUD by eye (2026-08-21).** The save manifest carries
> the clock exactly, so the delta can be computed and — more importantly —
> **re-computed before every launch**, which is what the "re-base `NOW` after
> every pose" instruction below is really asking for. It also tells you the
> city you are about to measure before you launch it:
>
> ```bash
> adb exec-out run-as com.slacumcity.game cat files/saves/slot_0/manifest.json \
>   | python3 -c 'import json,sys; m=json.load(sys.stdin)["active"]["meta"]; \
>       print("day %d  %02d:%02d  pop %d  $%d" % (m["day_index"],
>             m["sim_time_minutes"]%1440//60, m["sim_time_minutes"]%60,
>             m["population"], m["treasury"]))'
> ```
>
> On 2026-08-21 that read `day 31  09:46  pop 359  $174414` in one command, with
> the phone still locked. `tools/cap_pose.sh` does this per launch; pass it a
> target hour and it works out the delta itself.
>
> **It also bounds the cost to the player's city.** A `force-stop` is an unclean
> exit and does not write the advanced clock back, so a matrix that re-launches
> per pose advances from the SAME base every time — the delta is paid once per
> pose, not accumulated. Verify by re-reading the manifest after the first pose;
> if the sim time moved, an autosave landed inside the hold and the next delta
> must be recomputed (which is what `cap_pose.sh` does unconditionally).

```bash
NOW=17            # <-- the in-game hour on the HUD right now, read it first
delta () { python3 -c "print(($1 - $NOW) % 24)"; }

for Z in 0.0 0.5 1.0; do
  for H in 13 21; do          # 13 = the shadow worst case, 21 = the emissive one
    adb shell am force-stop $PKG
    adb shell am start -n $PKG/$ACT --esa command_line_params \
      "--,--resume,--zoom=$Z,--advance-hours=$(delta $H)"
    sleep 12                                   # settle: shader warm-up, LOD dwell
    adb shell dumpsys gfxinfo $PKG reset
    : > fs_z${Z}_h${H}.txt
    for i in $(seq 1 30); do                   # 120 frames per read, so poll it
      adb shell "dumpsys gfxinfo $PKG framestats" >> fs_z${Z}_h${H}.txt
      sleep 2
    done
    adb shell "dumpsys gfxinfo $PKG" | grep -E "Total frames|Janky|50th|90th|95th|99th"
    NOW=$H                                     # the clock kept running; re-base
  done
done
```

Two things this loop deliberately does NOT do. It does not touch the device
between the reset and the reads — **put the phone down**, because a finger on the
glass is a pan and a pan is a different measurement. And it does not advance
past a full day per pose, because `--advance-hours` runs a real catch-up and a
large delta puts a multi-second veil in front of the frames you are about to
measure. Re-base `NOW` after every pose, as above.

**Expected columns, and the workstation provisional.** Preset Balanced,
1920×1080, 90 warm-up + 300 measured frames, `tools/profile_frame.gd`. Draw calls
are the *renderer's* count and are platform-independent — those are the ones a
device number should reproduce almost exactly. The millisecond columns are a
different GPU and are a shape, not a target.

| city | pose | hour | mean ms (desk) | p95 ms (desk) | dc | dc+UI | budget | **Fold p50** | **Fold p95** | **Fold jank%** |
|---|---|---|---|---|---|---|---|---|---|---|
| founding (34 bldg) | Z0 | 21 | 1.77 | 1.85 | 31 | 56 | 320 | — | — | — |
| founding | Z1 | 21 | 1.24 | 1.39 | 42 | 67 | 320 | — | — | — |
| founding | Z2 | 21 | 1.19 | 1.39 | 80 | 105 | 320 | — | — | — |
| founding | Z0 | **13** | 2.16 | 2.38 | **69** | 94 | 320 | — | — | — |
| founding | Z1 | **13** | 1.48 | 1.52 | **80** | 105 | 320 | — | — | — |
| founding | Z2 | **13** | 1.33 | 1.39 | 80 | 105 | 320 | — | — | — |
| bench (1,500) | Z0 | 21 | 12.43 | 12.50 | 95 | 120 | 320 | — | — | — |
| bench | Z1 | 21 | 12.40 | 14.27 | 113 | 138 | 320 | — | — | — |
| bench | Z2 | 21 | 12.08 | 12.96 | 196 | 221 | 320 | — | — | — |
| bench | Z0 | **13** | 13.02 | 13.33 | **237** | **262** | 320 | — | — | — |
| bench | Z1 | **13** | 12.83 | 13.33 | **233** | **258** | 320 | — | — | — |
| bench | Z2 | **13** | 13.72 | 14.82 | 196 | 221 | 320 | — | — | — |

**Every Fold column above is still an em-dash after two sessions.** ~~The pose
matrix needs `--zoom` and `--advance-hours`, and neither argument reaches the
game~~ — **that reason expired on 2026-08-21 and was replaced by three others.**
The delivery fix (D-20) is in the installed build and the shell reads the merged
list; what stopped the matrix the second time was, in order: the launch command
being re-split by `adb shell` (§1.2's box, fixed), a **secure lockscreen** that
stops the app 21 ms after resume so no GDScript runs at all (§1.0, needs a
person), and — for the A/B rows specifically — the fact that `--road-detail`,
`--pad-shadows` and `--flood-detail` had **no parser in `game/main.gd`** (fixed,
needs a build). The jank column additionally needs `gfxinfo`, which measures
nothing here, so it should be deleted rather than filled: use the `PERF` line's
`p95` instead.

**The matrix is now one command against an unlocked phone**:
`bash tools/run_matrix.sh q1`. It computes each pose's `--advance-hours` from the
save manifest, asserts the app holds the foreground across every hold, and marks
any capture that loses it `CONTAMINATED` rather than averaging it in. The column
that proves the poses actually separated is **`near`**: 2026-08-20 read `near=4`
at every nominal zoom because no argument landed, and a real Z2 pose must read
`near=0`. **What the session got instead is one pose, and it is not a row in
this table** — it is the player's own 70-building city at whatever camera the
save restored, on the 1856×2160 inner screen, Balanced, `render_scale` 0.85:

| what | Fold 6 measured (steady state, `PERF` line) |
|---|---|
| ungoverned frame | **60.6–96.6 fps**, p95 **14.1–21.4 ms** |
| governed (`knob`=4) frame | **53.8 fps**, p95 **26.8 ms** |
| GPU (`gpu_est`) | **7.0–12.6 ms** |
| CPU | **0.50–0.80 ms** against a 4 ms budget |
| draw calls | **141–189 of 320** — 41–56 % headroom |
| primitives | ~125,000 |
| `vram` / process PSS | 144–167 MB / **1.01 GB** (Graphics 501 MB) |
| chunks / near / inst | 9 / 4 / 70 |
| thermal | status 1 (LIGHT), zone0 45.7–49.6 °C and **falling** |

The one number that transfers to this table is the **draw-call column**, and it
is the one the budget is written against: 141–189 against 320 on a real device,
with the frame GPU-bound and the CPU at a fifth of its budget.

**Read the bold rows before anything else.** Every measured frame-cost table in
doc 11 §2.13 was taken at hour 21, and at 21:00 the sun is below the horizon and
**the shadow pass is empty**. In daylight the benchmark city costs **+142 draw
calls at Z0 and +120 at Z1**, taking the with-UI figure from 120/138 to 262/258.
The published "31.6 % headroom" is a night figure; the daylight headroom at the
tightest pose is **18.1 %**. Nothing is over budget — but the margin the doc
advertises is roughly twice the margin the game actually has at noon, **and the
tightest pose moves**: every table in doc 11 makes Z2 the expensive one, and in
daylight it is **Z0**, because Z2 has no shadow pass to fill and Z0 has twelve
NEAR chunks' worth. If a Fold run has time for only one pose, make it **Z0 at
hour 13**.

**The chunk census is identical day and night** (bench Z0 12 NEAR / 24 MEDIUM /
0 FAR at both hours, Z1 8 / 28 / 0, Z2 0 / 16 / 20), so the whole delta is the
shadow pass: **5.92 extra calls per NEAR chunk per split at Z0, 7.50 at Z1.**
Doc 11 §2.13's D-16 worst case budgets `16.4 buckets × 2 splits` per NEAR chunk;
the sunlit measurement is a quarter of that, because the split frustum culls most
of a chunk's buckets. **Reproduce the census on device and compare** — the
per-chunk-per-split figure is the one number that says whether the Fold's shadow
pass behaves like the workstation's.

Two things the same table confirms rather than assumes: **Z2 is genuinely the
shadow-free pose** — its draw-call count is identical at hour 13 and at hour 21,
to the digit, on both cities (196 on the bench, 80 on the founding), because no
chunk is NEAR there and `shadow_max_m` 150 m is below the 370.8 m camera — and
the founding city moves the same way at a tenth of the scale. **If the Fold
disagrees with either, it is the first thing to chase**: an unexpected Z2 shadow
pass means the LOD tiering is wrong on device, not that the phone is slow.

### Q2 — the asphalt shader's fragment cost, and whether the dashes hold still

**The A/B knob now exists.** `data/render.json` → `road_surface.detail`, and
`presets.*.road_detail` as a per-tier ceiling: **2** every line, joint, patch,
wheel track and zebra; **1** drops the wear terms and keeps every line of paint
including the crossings; **0** also drops the four-leg zebra loop.
`RoadSurfaceView.set_detail()` moves the live rung.

On the installed build there is no way to move it — the rung is read at
`setup()`. So Q2 on the installed build is answered by **pose delta plus the
workstation ladder**; with the telemetry build it is answered by running §3's
`--road-detail` A/B on the device.

Workstation ladder, founding city, camera aimed at the Grand/Slacum junction so
the carriageway fills the Z0 frame, `RenderingServer`'s own GPU time, three
interleaved rounds per arm:

| pose | hour | rung 2 | rung 1 | rung 0 | wear (2→1) | zebra (1→0) | ladder (2→0) | ladder as % of the pose's GPU |
|---|---|---|---|---|---|---|---|---|
| Z0 | 21 | 1.5176 | 1.4730 | 1.3637 | 0.0446 | **0.1093** | 0.1539 | **10.1 %** |
| Z1 | 21 | 1.1181 | 1.1136 | 1.0832 | 0.0045 | 0.0304 | 0.0348 | 3.1 % |
| Z2 | 21 | 0.9929 | 0.9899 | 0.9677 | 0.0030 | 0.0222 | 0.0252 | 2.5 % |
| Z0 | 13 | 1.8584 | 1.8030 | 1.6956 | 0.0554 | **0.1074** | 0.1628 | 8.8 % |

Milliseconds, and the arms do not overlap at Z0 in either lighting (rung 2 spans
1.5134–1.5223, rung 1 1.4652–1.4827, rung 0 1.3505–1.3765 at hour 21).

**The finding is the split, not the total: the four-leg zebra loop is 2.4× more
expensive than every wear term put together**, and it paints only on junction
tiles. It is the one place in the file where `fwidth()` is taken eight times and
`dashes()` four times inside a loop.

**What to do with it on the Fold:** the ladder is 8.8–10.1 % of the Z0 GPU pass.
If the device's GPU pass at Z0 lands near Balanced's 13 ms budget, that is ~1.3
ms, of which ~0.9 ms is the zebra. Measure the GPU pass first (§3's `PERF` line
carries `gpu_est`, or use `dumpsys SurfaceFlinger --latency` below), then decide.

**Do the dashes hold still at Z2?** This is answered analytically and the
derivation reproduces doc 11 §2.5's own geometry, so it is checkable rather than
asserted. At the Z2 pose the camera sits `420·sin 62° = 370.83` m up and the
40° vertical FOV spans 42°–82° below horizontal — which puts the near ground edge
at `370.83/tan 82° = 52.1` m and the far edge at `370.83/tan 42° = 411.8` m,
doc 11 §2.13's own `r_near` and `r_far` to one decimal. The per-pixel ground
footprint over 1080 rows is then `(h/sin²θ)·(40°/1080)` = **0.245 m/px at the
bottom of the frame, 0.535 m/px at the top**. Against that:

| pattern | period | px per period at Z2 | `dashes()` band-limit mix |
|---|---|---|---|
| lane divider (`lane_dash_mark + gap`) | 8.00 m | 33 → 15 | 0.05 → 0.17 |
| centre dash (`dash_mark + gap`) | 6.00 m | 24 → 11 | 0.06 → 0.23 |
| crosswalk ladder (`crosswalk_period`) | 0.85 m | 3.5 → **1.6** | 0.45 → **1.00** |

*The two right-hand columns are on different bases and both are right:
pixels-per-period uses the footprint along the dash's own axis (0.245 → 0.535
m/px), while the mix is `clamp(0.75·fwidth·2/period)` and GLSL's `fwidth` SUMS
both screen partials, worst case `0.535 + 0.374 = 0.909` m/px here. The mix
column is the pessimistic one, which is the direction to err in.*

`dashes()` reaches a full duty-cycle fade at `aa ≥ period/2`, i.e. at
`fwidth ≥ period/1.5` = **5.33 m/px** for the lane dash — ten times the worst
per-pixel footprint anywhere in a Z2 frame, and six times the worst `fwidth`. So: **the lane and centre dashes at Z2 are
sampled 5×–16× above Nyquist and cannot crawl; what keeps them still is
`band()`'s own smoothstep, not the band limit.** The band limit is doing real
work on exactly one pattern — the 0.85 m crosswalk ladder, which is at or below
two pixels per period at the top of the frame and is fully faded to duty cycle
there, which is correct. Doc 11 §2.1.2's sentence "the `mix` at the end … is what
keeps Z2 still" is therefore **true of the crossings and not of the lane lines**,
and should be re-worded.

**Checked with the eye as well, on the workstation.** A Z2 dolly along Slacum
Ave — eight 1920×1080 frames at 1 m steps, i.e. one full 8 m lane-dash period, so
a crawling pattern would visibly reshuffle across the set:

```bash
for i in 0 1 2 3 4 5 6 7; do
  z=$(python3 -c "print(48.0 + $i * 0.125)")
  ~/.local/bin/godot --path "/home/bbx/Slacum City game" -s res://tools/profile_frame.gd -- \
    --quiet --city=res://data/starter_city.json --poses=z2 --hour=13 \
    --focus=48.0,"$z" --resolution=1920x1080 --warmup=40 --frames=10 --shots=/tmp/pan/f$i
done
```

The dashes **translate** — identical mark length and spacing in every frame, at
every depth, no beat — and the crossings read as solid white squares rather than
bars, which is the band limit reaching 1.0 on the 0.85 m ladder exactly where the
table says it should. The device check below is a confirmation, not the proof.

Screen-size sensitivity, since this is a foldable: the footprint scales as
`1080 / rendered_rows`. **Unfolded** (2160×1856 panel, landscape height 1856,
`render_scale` 0.85 → ~1578 rows) the footprint is **0.68×** the table's and
every margin improves. **Folded** (2376×968 cover, → ~823 rows) it is **1.31×**,
so the lane dash is 25→11 px/period — still 5× above Nyquist. **Neither screen
aliases**, and the cover screen is the one to check first if the eye disagrees.

**On-device confirmation, if the eye is wanted anyway:**

```bash
adb shell am start -n $PKG/$ACT --esa command_line_params "--,--resume,--zoom=1.0"
adb shell screenrecord --time-limit 20 --bit-rate 16000000 /sdcard/z2_pan.mp4
# ... during those 20 s, pan slowly across the city with one finger ...
adb pull /sdcard/z2_pan.mp4 . && adb shell rm /sdcard/z2_pan.mp4
```

Watch the lane lines, not the crossings. Crawl looks like the dashes changing
LENGTH as the camera moves; correct behaviour is that they slide.

### Q3 — pad shadows

`PowerInfraView.set_pad_shadows(false)` is now behind
`data/render.json` → `power_infra.pad_shadows`, default **true**, and
`tools/profile_frame.gd --pad-shadows=0|1` is the A/B.

**This question can only be asked in daylight.** The first attempt at it was run
at hour 21 and measured nothing at all, because with the sun down there is no
shadow pass for the pads to be in. Both arms below are hour 13.

| city | pads | pose | dc with | dc without | Δ dc | GPU with | GPU without | Δ GPU | instrument spread |
|---|---|---|---|---|---|---|---|---|---|
| founding | 18 | Z0 | 69 | 68 | **+1** | 2.0641 | 2.0680 | −0.0039 | ±0.011 |
| founding | 18 | Z1 | 80 | 79 | **+1** | 1.4034 | 1.4088 | −0.0054 | ±0.013 |
| founding | 18 | Z2 | 80 | 80 | **0** | 1.1710 | 1.1541 | +0.0170 | ±0.035 |
| bench | 144 | Z0 | 237 | 236 | **+1** | 2.2780 | 2.2433 | +0.0347 | ±0.28 |
| bench | 144 | Z1 | 233 | 232 | **+1** | 3.2518 | 3.0258 | +0.2260 | ±0.46 |
| bench | 144 | Z2 | 196 | 196 | **0** | 3.0507 | 2.9658 | +0.0848 | ±0.28 |

Four interleaved rounds per arm. **The price is exactly one draw call at the two
poses that have a shadow pass at all, and zero at Z2** — the pad buffer is one
city-wide MultiMesh with one custom AABB, so it is submitted whole, once, and the
count does not grow with the roster. The GPU column on the founding city, where
the instrument's own spread is ±0.011 ms, is **negative in two of three poses**:
there is no cost to find. On the benchmark city the spread is 40× worse and the
largest arm difference (+0.226 ms at Z1, 7 % of that pose's GPU pass) should be
read as an **upper bound**, not a measurement.

**Ruling, shipped: `pad_shadows: true`.** It costs one draw call of 320 (0.3 %)
and no measurable GPU time on 144 transformers in full sun; turning it off costs
the read the layer exists for — a 1.5 m cabinet with no contact shadow at Z0 is a
decal printed on the pavement. Revisit only if a Fold measurement puts a daylight
Z0/Z1 pose within 5 % of the draw-call budget.

**On device**, with the telemetry build, the arm is one flag apart; without it,
the honest device check is the draw-call count in the `PERF` line, which is the
column that actually moves.

### Q4 — the construction layer's CPU at real site counts

`tools/profile_frame.gd --sites=N` on the workstation, layer CPU timed on the
main thread with `Time.get_ticks_usec()` (the frame delta cannot see a
sub-millisecond layer on a fast desktop):

| city | sites | layer CPU mean (Z1) | p95 | draw calls | §2.16 budget |
|---|---|---|---|---|---|
| founding | 0 | layer not built | — | 42 | — |
| founding | 1 | **0.045 ms** | 0.055 | 47 (**+5**) | 0.8 ms |
| founding | 2 | **0.081 ms** | 0.085 | 47 (+5) | 0.8 ms |
| founding | 3 | **0.105 ms** | 0.112 | 47 (+5) | 0.8 ms |
| founding | 28 (`max_sites`) | **0.549 ms** | 0.590 | 47 (+5) | 0.8 ms |
| bench | 20 | 0.539 ms | 0.567 | +5 | 0.8 ms |
| bench | 28 (`max_sites`) | **0.728 ms** | **0.767** (0.818 at Z2) | +5 | 0.8 ms |

Three results:

1. **At the counts the founding city actually runs, the layer is free.** 0–3
   simultaneous sites is 0.000–0.105 ms, i.e. **at most 2.6 % of Balanced's 4 ms
   CPU budget**. §2.16's estimate of 1.5–1.9 ms at 20 sites was 3× pessimistic;
   the measured slope is **0.020 ms/site** on the founding city and 0.026 on the
   benchmark.
2. **The +5 draw calls are flat and now measured from a true zero.** §2.16 could
   only quote 5 as a ceiling because the no-site case was never run; 0 sites is
   42 calls and 1 site is 47, so five is the whole layer, one MultiMesh per model
   kind, and it does not move between 1 and 28 sites.
3. **At the shipped ceiling the layer is at its own budget line on a
   workstation.** 28 sites on the benchmark city measures 0.728 ms mean and
   0.818 ms p95 against the authored 0.8 ms — and §2.16's budget was written
   against 20 sites, not against `max_sites`.

**Recommendation on the governor knob (construction q2): no.** A governor rung
that lowers `max_sites` would only ever fire on a city with twenty-plus
simultaneous sites, which is a *player action* (a mass rezone) and not a device
condition, and what it would buy — 0.6 ms — is bought by taking half the working
sites in view still, mid-pan. That is the loudest artefact on the ladder for the
smallest saving on it. The ladder's existing rungs (`render_scale`,
`particle_ratio`, `far_cull`, `street_lights`, preset drop) all degrade
*fidelity*; this one would degrade *content*, and the governor's contract does
not extend there.

**What should happen instead, and it is the lead's call**: `max_sites` is
currently one number in `construction_vehicles` for every tier, with
`construction_vehicle_view.gd` explicitly ruling that "how many sites are worth
animating is an art call and not a device tier". The measurement gives a reason
to revisit that on **tier C only** — a `presets.performance.construction_sites`
row of 12 would cost 0.31 ms on this workstation and would sit beside `civ_cars`
and `emergency_nodes`, which cap exactly this kind of population per tier. It is
NOT taken in this branch, because overturning another branch's stated ruling
wants the device number that this session did not get.

**On device**: the founding city runs 0–3 sites, so Q4's device half is a
one-line check — hold Z1 over a block you have just rezoned and confirm the frame
does not move. The interesting number needs `--sites` and therefore §3.

### Q5 — wire fade and the pad super-block

Asked as "only if numbers say primitives hurt on Vulkan mobile". **They do not,
and the question closes without a change.**

* The pad buffer is a flat **+29,376 primitives** at every pose on the benchmark
  city (144 × 204) and **+1 draw call in the shadow pass, 0 elsewhere** (Q3's
  table). A per-chunk super-block would spend 16 calls at Z2 to cull a buffer
  smaller than the cull test's own bookkeeping.
* The wire buckets are **0 at Z1 and 0 at Z2** on both cities — `wire_fade_end_m`
  58 m is below the Z1 camera height of 64.6 m, so the layer gates itself out
  before distance could matter. There is nothing for a fade change to buy.
* The one primitive figure that IS large — the merged MEDIUM tier's 209,546 at
  Z2 — was already ruled on in doc 11 §2.6: the extra triangles are degenerate,
  and the GPU column did not move when they were added.

Re-open only if a Fold `PERF` line reports `prim` climbing while `dc` holds and
the frame is late at the same time. That is the signature of a primitive-bound
frame and nothing in the desktop record looks like it.

### Q6 — save and load, on device

**There is no timing instrument in the installed build**, so this is a
differential measurement off `am start -W`, which reports `TotalTime` to first
frame — and both the save and the load happen in `_ready()`, before that frame.

```bash
# A: cold start, title door, no city load
adb shell am force-stop $PKG; sleep 2
adb shell am start -W -n $PKG/$ACT --esa command_line_params "--,--title"

# B: cold start that LOADS the newest save
adb shell am force-stop $PKG; sleep 2
adb shell am start -W -n $PKG/$ACT --esa command_line_params "--,--resume"

# C: the same, plus one autosave before the first frame
adb shell am force-stop $PKG; sleep 2
adb shell am start -W -n $PKG/$ACT --esa command_line_params "--,--resume,--save-now"
```

Run each five times, take the median `TotalTime`. **`B − A` is the load,
`C − B` is the save.** Both differences cancel process start, Vulkan init and
shader warm-up, which is why this works without instrumentation. Sanity-check
`C` against logcat: `adb logcat -d | grep save-now` must show the line, or the
arguments did not arrive (§1.2).

Workstation provisional, `tools/profile_save.gd` (new in this branch — it drives
the shipped `SaveService.save_slot` / `load_slot`, not a harness path), headless,
best of 7 / best of 5:

| city | save best/mean/worst | load best/mean/worst | slot bytes (whole ladder) |
|---|---|---|---|
| founding (34 buildings) | 13.9 / 14.4 / 14.8 ms | **48.5 / 49.2 / 50.0 ms** | 42,359 |
| bench (1,500 buildings) | 119.9 / 138.5 / 154.2 ms | **428.8 / 455.6 / 482.9 ms** | 263,027 |

**These are worse than anything in the docs and they are the shipped path.** A
load of the founding city is **49 ms — three frames at 60 Hz — on a workstation**,
and a save is 14 ms, which is most of one frame. On the 1,500-building city a
load is **0.46 s** and a save is **0.14 s**, on the main thread, and a phone will
not be faster. Two consequences the lead should route:

* doc 08's autosave lands a **visible hitch** as soon as a city is a few hundred
  buildings. The cadence is not the problem; the fact that the write is
  synchronous is.
* doc 13 §2.9's ANR arithmetic budgets the CATCH-UP and does not budget the
  LOAD in front of it. On the benchmark city the load alone is half a second
  before a single coarse step runs.

Expect the Fold to land **2–3× the workstation** on both columns (interpreted
GDScript on a Cortex-X4, plus UFS instead of NVMe): founding city ≈ 30–45 ms
save, ≈ 100–150 ms load; a 1,500-building city ≈ 0.3–0.5 s save, ≈ 0.9–1.4 s
load. **Confirm or refute that factor first** — it is the multiplier every other
provisional number in this file leans on.

> **Amended 2026-08-20 (report 98 RR-44).** Both operations are now split by the
> instrument, and the split is the finding: a benchmark-city **save is 148.7 ms
> of which the WRITE is only 52.4** — `canonical_capture()` is the expensive
> half — and a **load is 483.9 ms of which `restore_state` is 442.6**, i.e.
> 91 %. `SaveService.async_writes` moves the write to a worker and takes the
> caller's cost to **97.5 ms**; `PERFIO` now carries `write_ms`, `read_ms`,
> `restore_ms` and `async`, so a device capture reports all four columns
> directly instead of by difference. **On device, ask for the RESTORE column
> first**: if the Fold's 2–3× factor holds it is 0.9–1.3 s of main-thread work
> in front of doc 13 §2.9's catch-up, and nothing in this branch touches it.

### Extras worth taking while the device is up

```bash
# Memory, after 5 min and after 30 min — the leak gate is the DIFFERENCE.
adb shell dumpsys meminfo $PKG | head -30

# Thermal, sampled through a 20-minute session (doc 11 §7.4's rise gate).
adb shell 'while true; do date +%s; cat /sys/class/thermal/thermal_zone0/temp; sleep 10; done' \
  > thermal.log
adb shell dumpsys thermalservice | grep -iE "status|Temperature"

# Battery over a scripted 30 min (doc 13 D-07).
adb shell dumpsys batterystats --reset   # ...play 30 min...
adb shell dumpsys batterystats $PKG > batt.txt

# The compositor's own view, when gfxinfo and the eye disagree.
adb shell dumpsys SurfaceFlinger --latency \
  "$(adb shell dumpsys SurfaceFlinger --list | grep -i slacum | head -1)"
```

---

## 3. What needs the telemetry build

Three things in this branch turn the questions above from differential into
direct, and all three need `game/main.gd`'s integration snippet plus one
`--export-debug` build:

1. **`PERF` lines.** `game/render/perf_telemetry.gd` calls the `perf_line()`
   that has been sitting uncalled since Wave 6. With it,
   `tools/bench_device.sh`'s existing logcat capture works as documented and
   every Q1 row gains `p95`, `dc`, `prim`, `vram`, `chunks` and `knob` from the
   renderer's own counters instead of from the compositor. Note it deliberately
   reports `inst=0` unless the shell hands it
   `set_instance_source(render_model.building_count)`: `Performance.OBJECT_COUNT`
   counts every engine `Object`, which on this shell is thousands of UI nodes,
   and a number that looks like an answer and is not one is worse than a zero.
2. **`PERFIO` lines.** `SaveService` now times `save_slot` / `load_slot` and can
   print one line each, `^PERF`-anchored so the same grep collects them — Q6
   stops being a difference of cold starts. **`SaveService.log_io` is `false` by
   default** (a service that writes files should not print on every call, and
   the suite drives thousands of saves), so the shell has to set it: one line,
   in the integration snippet.
3. **The A/B flags.** ~~`--road-detail`, `--pad-shadows` and `--sites` are
   `tools/profile_frame.gd` flags and do not exist in the shell.~~ **WIRED INTO
   THE SHELL 2026-08-21** — `game/main.gd`'s `_apply_render_ab_args()` now parses
   `--road-detail=N`, `--pad-shadows=0|1`, `--flood-detail=N` and `--flood=<mm>`.
   **It needs a build**; the installed APK does not have them.

   > **This was the real blocker on the three A/B questions, and it is separate
   > from both D-20 and the lockscreen.** On 2026-08-21 the session confirmed by
   > grep that *none* of these flags existed anywhere in `game/` — they were
   > `tools/` only. So the zebra A/B, the flood A/B and the daylight pad-shadow
   > re-check were undrivable on the installed build **no matter how perfectly
   > the arguments were delivered**. A session that had walked in, found the
   > phone unlocked and run the pose matrix would still have collected nothing
   > for questions 3-5. Check the shell parses a flag before planning a window
   > around it:
   >
   > ```bash
   > grep -n 'road-detail\|pad-shadows\|flood-detail\|--flood=' game/main.gd
   > ```
   >
   > They are applied AFTER the boot preset seeding, deliberately: an A/B lever
   > asks "what would this rung cost here", so it has to override the per-tier
   > ceiling `set_preset()` just applied, not be overridden by it.

   `--sites` is still workstation-only, and Q4's device half does not need it
   (0-3 simultaneous sites is the real load).

~~`tools/bench_device.sh` also needs its `--es cmdline` corrected to
`--esa command_line_params "--,…"` (or the simpler `--es args "…"`, which the
plugin now also reads) and its `--bench=` scenarios replaced with the flag
vocabulary in §1.3 before it can be run at all.~~

> **DONE 2026-08-20 (Wave 12). `tools/bench_device.sh` is rewritten against this
> file.** Everything §1.1, §1.2 and §1.3 recorded as wrong with it is fixed *in
> the script*: the activity is resolved live rather than hard-coded, every launch
> carries **both** extra forms (`--esa command_line_params "--,a,b"` and
> `--es args "a b"` — `game/dev_args.gd` merges and de-duplicates, so sending
> both is free insurance), and `--bench=` is gone. The script now drives §Q1's
> six poses (`--question=Q1 --now=17`), §Q6's three cold-start arms
> (`--question=Q6`), §1's five pre-flight checks (`--question=preflight`) and the
> "extras" block, and doc 11 §7.4's S1/S2/S3 survive as `--scenario=` re-expressed
> in real flags. It carries §2's `framestats` parser and the `PERF`/`PERFIO`
> summariser as functions, so the same code that reads a device capture is what
> `--self-test` checks against known answers.
>
> **`--self-test` is the part to run before a session**: 20 checks, no device
> needed, covering the flag vocabulary against `game/main.gd`'s own parse table,
> the `--hour=` → `--advance-hours=` delta arithmetic including §Q1's day wrap and
> its re-base, both launch forms, and both summarisers. **The device half is
> still unverified and the script prints that in its own summary.** Start with
> `--question=preflight`.

---

## 4. Provisional knob settings, and what would overturn each

> **No knob moved on 2026-08-21, and that is the correct outcome rather than a
> deferral.** The session reached no frame (§5), so every value below still rests
> on the workstation ladder and the single 2026-08-20 pose. In particular
> **`presets.performance.road_detail` stays at 1** and **the ladder is NOT
> retired**: RR-42's note that the junction early-out may have made the ladder
> pointless is a hypothesis the device was supposed to test, and setting every
> preset to 2 on the strength of a workstation delta would be exactly the kind of
> device-shaped claim this file exists to prevent. What would settle it is now a
> single command against an unlocked phone carrying a build from this branch:
>
> ```bash
> bash tools/run_matrix.sh zebra     # rung 2 vs rung 0, Z0, hours 13 and 21
> ```
>
> **Read it as: if `gpu_est` at rung 2 and rung 0 sit inside each other's spread
> across the rounds, the ladder buys nothing on Adreno 750 and every preset row
> goes to 2 with the ladder marked dormant.** If rung 0 is clearly cheaper, the
> tier-C rung keeps its reason to exist. Either way the numbers go in the table
> below and in doc 11 §2.13.

| knob | shipped value | basis | overturned by |
|---|---|---|---|
| `power_infra.pad_shadows` | **true — CONFIRMED on device 2026-08-20** | +1 draw call of 320, GPU delta negative on the low-noise instrument (§Q3); the Fold measured **141–189 of 320** and is fragment-bound, not submission-bound | ~~a daylight Z0/Z1 Fold pose within 5 % of the draw-call budget~~ — tested at the one reachable pose and missed by an order of magnitude. Re-open only if a true Z0 daylight pose (needs the argument fix) lands within 5 % |
| `road_surface.detail` | **2** | the project ceiling; rung 2 is pixel-identical to the pre-ladder shader (0 of 2,073,600 pixels differ at Z0) | nothing — this is the authored look |
| `presets.balanced.road_detail` | **2** | the ladder is 10.1 % of the Z0 GPU pass and the Fold is a flagship | a Fold Z0 GPU pass over ~11 ms with the street a visible share of it |
| `presets.high.road_detail` | **2** | as above | as above |
| `presets.performance.road_detail` | **1** *(provisional — held after the device pass)* | drops the wear terms only — every line of paint, including the crossings, survives; a tier-C part at `render_scale` 0.70 resolves an 11 m hash mottle as noise, and tier-C ALU:bandwidth is far worse than this workstation's. The Fold adds a reason to hold it: the frame is fragment-bound (`gpu_est` 7.0–12.6 ms vs `cpu` 0.5–0.8 ms) at a 2.90 MP render target, 3.14× what the ladder was measured at | a tier-C measurement showing the wear terms below 1 % of its GPU pass — then raise it to 2. **The Fold is tier A and auto-detected into `balanced`, so it cannot fire this condition; tier C is still unmeasured** |
| **the ladder's shape** *(new, 2026-08-20)* | — | rung 1 buys only ~29 % of the ladder: the workstation split prices the zebra loop at 2.4× every wear term combined, and rung 1 keeps the zebra. Rung 0 buys the other 71 % and deletes the crossings | nothing — this is a note that the ladder is the wrong lever. ~~**The lever to build is an optimised zebra**~~ **BUILT, 2026-08-20 (report 98 RR-42).** The eight `fwidth()` calls are four and the block early-outs on `cw_mask` — a `flat` varying, so the branch is quad-uniform. **The zebra term falls 0.1156 → 0.0355 ms at Z0/21 (−69 %) and 0.1096 → 0.0427 at Z0/13 (−61 %)**, byte-identical at Z0 at every rung and both hours. The ladder now costs 0.092 ms at Z0/21 instead of 0.153, and `presets.performance.road_detail` has that much less to buy |
| `road_detail` as a governor rung | **not taken** | 0.15 ms saved against a street that changes appearance mid-pan | nothing short of a device that cannot hold 30 fps at rung 1 |
| `construction_vehicles.max_sites` | **28, unchanged** | 0–3 sites is the real load and costs 0.105 ms (§Q4) | a tier-C device measuring over 1.5 ms at 28 sites — then a `presets.performance.construction_sites` row, not a governor rung |

---

## 5. Session checklist

### The 2026-08-21 run — three blockers, no frame

`[x]` done, `[~]` partial, `[ ]` not reached, `[!]` blocked by something new.

- [x] device on the wire (already connected), `svc power stayon true`
- [x] **saves backed up before the first launch** — `gen_000062–64`, 207 KB
- [x] save read WITHOUT launching: `day 31, 09:46, pop 359, $174,414`
- [x] §1.1 activity confirmed `GodotAppLauncher`; D-20 build installed 01:10:59;
      `game/main.gd` reads `DevArgs.user_args()` at all four sites
- [x] `--self-test` 25/25 green
- [!] **§1.2 probe — could not be answered.** Not a D-20 failure and not a pass:
      the game never ran. Three faults, in the order they were hit:
      **(1) the launch command was malformed** — `adb shell` re-splits the
      space-bearing extra and `am` died with `Unknown option: --zoom=1.0`
      (fixed, §1.2's box); **(2) the phone was behind a secure lockscreen**, so
      after the fix the app launched and was stopped 21 ms later with no
      GDScript run (§1.0); **(3)** Godot's own reader returns `[]` even for a
      correctly delivered `--esa`, so the plugin is the only path and its
      `launch args:` line needs a surface to be printed
- [!] **the pose matrix, the zebra A/B, the flood A/B, the pad-shadow re-check
      and the `PERFIO` rows — all not reached.** The first two of the three
      blockers are fixed; the third was that **`--road-detail`, `--pad-shadows`,
      `--flood-detail` and `--flood` did not exist in `game/` at all**, so three
      of these were undrivable on the installed build regardless. Now wired
      (`_apply_render_ab_args()`), needs a build
- [x] **GPU driver question CLOSED** (§1.5): stock vendor driver, Adreno
      `0762.41`, both updatable-driver opt-ins `null`. The pre-release driver is
      not a corruption-band suspect
- [x] **doc 91 §13's premise overturned**: the debug APK *does* carry the plugin
      and registers it; its `<uses-permission>` elements are what do not reach
      the APK, and `export_presets.cfg` is why
- [!] **`files/perf_capture.flag` IS STILL ARMED ON THE DEVICE — disarm it.** It
      was touched early so that any launch would capture, and the wire dropped
      before it could be removed (`adb` went to "no devices" at ~02:08 and ten
      minutes of the §0 reconnect loop found nothing). While it is there **every
      player session pays a per-frame `viewport_set_measure_render_time` GPU
      timestamp query** — the exact class of driver sync point filed against the
      Fold's presentation-corruption bands. First command of the next session,
      before anything else:

      ```bash
      adb shell run-as com.slacumcity.game rm -f files/perf_capture.flag
      ```

      `tools/run_matrix.sh` arms it itself, so nothing is lost by removing it.
- [x] **app NOT uninstalled**, no save deleted, no data cleared, nothing advanced
      (the sim never ran, so this session cost the player **zero** sim-hours and
      zero treasury — the first one that did not)

**The one-command version of everything above is `tools/run_matrix.sh`**, which
refuses to start on a locked phone rather than collecting six empty captures.

### The 2026-08-20 run

Marked up as run on 2026-08-20. `[x]` done, `[~]` partial, `[ ]` not reached.

- [x] device on the wire, `stay_on_while_plugged_in` set *(and restored to
      `stayon false` + animation scales 1 at the end)*
- [x] **saves backed up before the first launch** — add this line to the top of
      any future checklist; it is the only reason the pre-session city survives
- [x] §1.1 activity name confirmed — **it is `GodotAppLauncher`, not `GodotApp`**
- [x] §1.2 `--esa command_line_params` probe — **FAILED. Arguments do not reach
      the game.** This is what capped the session; everything `[ ]` below is
      downstream of it. **Fixed since, in the plugin (doc 13 D-20) — re-run the
      probe against a build from that branch or later before you conclude
      anything from the `[ ]` rows**
- [x] §1.4 graphics row read off `settings.cfg` — **no such file exists**; the
      preset was auto-detected and `PERF` reported `preset=balanced`. Could not
      be forced through the settings sheet (that needs UI driving, not args)
- [x] animation scales 0 *(HWUI profiling irrelevant — `gfxinfo` sees nothing)*
- [ ] Q1 six poses — **not possible**, needs `--zoom` / `--advance-hours`
- [~] Q3 draw-call count — read at the one available pose, not at a daylight Z0.
      141–189 of 320; the pad-shadow ruling is confirmed by a wide margin
- [ ] Q6 A/B/C cold starts — **not possible**, needs `--title` / `--resume` /
      `--save-now` to select the arm
- [~] thermal + meminfo captured; **batterystats not taken**, and the soak was
      not foreground-verified for its whole length
- [ ] `screenrecord` of a Z2 pan for the dash eyeball — needs a Z2 pose
- [~] doc 11 §2.13's "Fold 6 measured" — written, with the pose matrix left open
- [x] doc 91 §13's stale rows re-graded on device evidence
- [x] **app NOT uninstalled**, no save deleted, no data cleared

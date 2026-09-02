# Raw captures — Fold 6 device sessions

## 2026-09-01, fourth session — the first COMPLETE matrix

`tools/run_matrix.sh` ran end to end for the first time: unlocked, connected
Galaxy Z Fold 6 (`SM-F956U`), Android 16, inner panel, the **Wave-15 build**
(`versionName` 0.4.0, installed 2026-08-21), the player's **live** city,
`--preset=balanced` pinned in sections 2–4, `MATRIX EXIT: 0`. Write-up: **doc 11
§2.13, "The 2026-09-01 session"**; rulings: **report 98 §47 (RR-129, RR-130,
RR-131)**; the `PERFIO` arithmetic: **doc 13 §2.9.1**.

| file | what it is |
|---|---|
| `run_matrix_2026-09-01.log` | **the session log** — every launch line, every `perf_rows.py` row, the `meminfo`/thermal dumps and the `MATRIX EXIT`. Read this first; it is the only file that carries the *arguments* each capture was launched with |
| `log_z{0.0,0.5,1.0}_h{13,21}.txt` | the pose matrix, six captures. **They are one pose, not six** — see the warning below |
| `log_rd{0,2}_h{13,21}.txt` | the `road_detail` A/B. `log_rd0_h21.txt` is the one capture in the session whose camera moves mid-hold (`near: 6 → 0` at `t = 14.0 s`); its `perf_rows.py` row is a pose result, not a detail result — RR-129 |
| `log_flood{0,2}.txt`, `flood_night.png` | the `flood_detail` A/B and **the first device photograph of standing water** (2,618,648 bytes, snapped through `cap_pose.sh --snap`, which resolves the display) |
| `log_pads{0,1}.txt` | the pad-shadow A/B. **`log_pads0.txt` is stamped `CONTAMINATED`** — see below |
| `log_io_boot.txt`, `perfio_save.txt` | the `PERFIO` pair, isolated. `perfio_load.txt` is **0 bytes and that is not a fault**: the load row is emitted by every launch and is captured inside each of the fourteen matrix `log_*.txt` files, with the fifteenth printed inline by the `io` step; those fifteen are what doc 13 §2.9.1's medians are taken over |
| `log_probe_zoom.txt`, `log_argprobe.txt` | §1.2's args probe. **`log_probe_zoom.txt` still contains 0 `PERF` lines and that is still the expected result** — it launches `--perf` with nothing else arming the capture, and the plugin's own `SlacumNative: launch args: […]` line in the session log is the half that proves delivery |
| `meminfo.txt`, `thermal.txt` | end-of-session `dumpsys`. **Total PSS 840,172 KB = 820 MB against `presets.balanced.pss_budget_mb = 900`**, the tightest budget in the session; `Thermal Status: 1`, `AP 47.4 °C` |
| `fs_*.txt` | 2026-08-20 leftovers, kept for the reason the older section below gives (`Total frames rendered: 0` — Godot draws through a `SurfaceView` and never touches HWUI) |

### Read the labels before you use a number — three captures are not what their filenames say

**1. The six `log_z*_h*.txt` are ONE pose, again.** `--zoom` is delivered (the
plugin logs it) and parsed (`game/main.gd:218`) and **does not move the camera**.
Eleven of the fourteen captures share one `md5` over their entire render column
set:

    for f in log_z0.0_h13 log_z0.5_h13 log_z1.0_h13 log_z0.0_h21 log_z1.0_h21 \
             log_rd0_h13 log_rd2_h13 log_rd2_h21 log_flood0 log_pads0 log_pads1; do
      printf '%s ' "$f"; grep -ao 'dc=.* lights=[0-9]*' "$f.txt" | md5sum
    done
    # cc761e3e782311b8db9b578f109b2417, eleven times

`near` — `tools/run_matrix.sh:152`'s own stated discriminator for whether the
poses separated — reads **4 in every one**. The **day/night** half of the matrix
is valid and is the session's headline (`gpu_est` 6.03 → 8.63 ms at identical
`dc`/`prim`/`vram`); the **zoom** half is not. Filed as doc 91 `A91-D-84`.

**2. `log_pads0.txt` is stamped `CONTAMINATED` and, unlike 2026-08-21's stamp,
the ordering argument does NOT rescue it.** `cap_pose.sh` wrote
`CONTAMINATED fg_before=0 fg_after=1`; the capture nevertheless emits all 25
samples across the full 50 s, so the foreground loss is not cleanly outside the
sampled window. Two further reasons the pads pair cannot be quoted: `thermal`
rises `0 → 1` *inside* `log_pads1.txt` at `t = 14.1 s`, so the pair straddles a
thermal step; and the `pads1` arm sets `pad_shadows` to the value the build
already boots with (`data/render.json:184`) yet costs 2.5 ms more than the
no-lever daylight captures. **RR-131: the pair is unusable, RR-33 stands
unrevisited, and the re-run command is in doc 91 §20.4 device item 3.**

**3. `log_rd0_h21.txt` changes pose at `t = 14.0 s`.** `near: 6 → 0`,
`prim: 45,820 → 53,666`, `dc: 90 → 130`, then flat for eighteen samples; the
governor steps `knob 0 → 1 → 2` twenty-four seconds later at `thermal = 0` and
does not recover. `perf_rows.py`'s median for this file spans both halves. Use
`t = 4–12 s` when comparing it against `log_rd2_h21.txt` — RR-129 does.

### The harness fault found and fixed this session

**`bash tools/run_matrix.sh` with no arguments ran nothing and exited 0.**
`"${@:-build_check probe q1 …}"` expands to **one word**, so the dispatcher
printed `unknown step: build_check probe q1 zebra flood pads io extras` and fell
through a `case` arm that did not exit. Eleven days of "the whole session runs
with no argument" was untrue and nothing said so. Fixed in **`6a763a9`** — the
default list is an array, `set --` installs it when `$# -eq 0`, and an unknown
step now exits **2** instead of being ignored. *(This is the third harness fault
in three sessions whose signature is "success with no work done", after the
`grep -q`/`SIGPIPE`/`pipefail` lockscreen gate and the two-display `screencap`.
The pattern is worth naming: on this rig, a zero exit status is not evidence.)*

### Reconnecting the phone — the recipe, because the port changes

Wireless-debugging **ports are re-randomised between sessions**, so the
`adb connect host:port` that worked last window will not work this one — and
`adb mdns services` is not the fallback it looks like: the 2026-08-20 session
re-ran it on 135 consecutive polls over 45 minutes and got **zero endpoints**.
What works is a **throttled** parallel `/dev/tcp` sweep of the
wireless-debugging range, then a pinned serial:

    HOST=192.168.1.XXX                        # the phone's LAN address
    : > /tmp/adbports
    n=0
    for p in $(seq 30000 49999); do
      ( timeout 0.2 bash -c "</dev/tcp/$HOST/$p" 2>/dev/null \
          && echo "$p" >> /tmp/adbports ) &
      (( ++n % 256 )) || wait                 # 256 probes in flight, NOT 20,000
    done
    wait
    sort -n /tmp/adbports                     # ~20 s; expect one or two hits
    adb connect "$HOST:<port>"
    adb devices -l                            # confirm the SM-F956U row

**The `wait` every 256 is not decoration.** The unthrottled form of this loop
forks twenty thousand subshells at once and will put the workstation into swap
before it finds the phone.

Then **pin it for everything that follows**, because a Fold that is also plugged
in, or a leftover offline endpoint, makes every `adb` call ambiguous:

    export ANDROID_SERIAL=$HOST:<port>

`tools/run_matrix.sh` and `tools/cap_pose.sh` both inherit `ANDROID_SERIAL`;
pinning it is what makes a two-display `screencap -d` and a `run-as` land on the
same device the captures came from. **Order matters:** connect, pin, then
`bash tools/run_matrix.sh build_check` — which is the step that refuses a build
that cannot receive `launch_args`, and the reason the 2026-09-01 window started
at the measurements instead of at a rebuild.

---

## 2026-08-21, third session — the argument-delivery verdict

Same phone. The city is the player's own save, now **day 31, population 359**,
`sim_time_minutes` 45,262. Write-up: **doc 11 §2.13, "The 2026-08-21 third
session"**; procedure corrections: the "READ FIRST" box in
`tools/device_runbook.md`.

| file | what it is |
|---|---|
| `log_probe_zoom.txt` | The §1.2 args probe, launched `--resume --zoom=1.0 --perf` with **nothing else arming telemetry**. **It contains 0 `PERF` lines and that IS the result**: the argument did not reach GDScript. Three engine lines and then silence is what a stale plugin looks like |
| `log_baseline_flagarmed.txt` | The same build minutes later, armed by `touch files/perf_capture.flag` and **no argument at all** — 19 `PERF` lines and **both `PERFIO` rows**. The pair of files is the experiment: flag works, `--perf` does not, therefore arguments are not arriving |
| `probe_d0.png` | The game rendering the player's city, `screencap -d <inner display>`. Kept because it is the first visual confirmation the build runs the real save — and because the bare `screencap` that produced it first came back **corrupt** (see below) |
| `saves_backup_prewf187.tgz` | `run-as … tar` of `files/saves`, taken **before the first launch**, per the standing rule. The pre-session generations survive only here |

**Why `log_probe_zoom.txt` is empty, and it is not the lockscreen.**
`launch_args` was absent from all three `classes*.dex` of the installed APK
(control symbol `thermal_status`: present), because
`android/plugins/slacum_native.aar` is a **gitignored build artifact** that had
never been rebuilt after D-20's Kotlin landed. The transport was fine — `logcat`
caught the launch reaching `am` byte-perfect in both extra forms. The build was
rebuilt, re-exported and reinstalled during this session, and
`tools/run_matrix.sh build_check` now verifies it before a window is spent.

**Both `PERFIO` rows, extracted:**

    grep PERFIO log_baseline_flagarmed.txt

`kind=load … ms=165.5 read_ms=24.0 restore_ms=136.2 bytes=202946 ok=1` — the
**boot load, captured for the first time**, and `kind=save reason=pause
ms=159.4 write_ms=42.9 bytes=203538 ok=1`.

**`log_baseline_flagarmed.txt` is stamped `CONTAMINATED` and its frames are
still good.** The stamp records that the foreground assertion failed *after* the
hold (the user picked the phone up). Godot stops emitting once it loses its
surface, and the ordering proves the frames predate that: last `PERF` at
`06:05:29.030`, `PERFIO … reason=pause` at `06:05:29.752`. Every frame in the
file was rendered in the foreground; the backgrounding is what produced the save
row. Read the two regimes separately — `t = 2–14 s` is still streaming in
(`inst=34`), `t = 18–38 s` is settled (`inst=81`, `dc≈104`), and `t = 16 s` is
the one-sample incremental-add spike (`dc=149`, `p95=36.5 ms`).

**Two harness faults were found here and are fixed in the tools.** `run_matrix.sh`
refused to run on an unlocked phone 100% of the time (`grep -q` + SIGPIPE +
`pipefail` → status 141 read as "no match"), and `adb exec-out screencap -p`
with no `-d` prints a *"Multiple displays were found"* warning **ahead of the PNG
bytes** on this two-display phone, producing a file that is not an image. The
corrupt capture is not kept; `cap_pose.sh --snap` is the fixed path.

---

# Raw captures — Fold 6 device session, 2026-08-20

Galaxy Z Fold 6, Android 16, Adreno 750, Vulkan 1.3.128 "Forward Mobile",
inner panel 1856 × 2160 @ 120 Hz. App `com.slacumcity.game` `versionCode` 400,
debug-signed, `targetSdk` 36. The city is the **player's own save** — 70
buildings, population 255, day 22.

The write-up is **doc 11 §2.13, "Fold 6 measured"**. The session's corrections to
the procedure are in the box at the top of `tools/device_runbook.md`. These files
are the evidence behind both.

## What is here

| file | what it is |
|---|---|
| `log_*.txt` | `adb logcat -s godot:V` per capture. The `PERF` line is the instrument — `game/render/perf_telemetry.gd` |
| `fs_*.txt` | `dumpsys gfxinfo … framestats`. **All of these are empty of data** and are kept only as the proof of that: `Total frames rendered: 0`, every percentile the `4950ms` sentinel. Godot draws through a `SurfaceView` and never touches HWUI |
| `soak_meminfo.txt` | `dumpsys meminfo` sampled every 10 s |
| `soak_thermal.txt` | `thermal_zone0` sampled every 10 s (milli-°C) |
| `soak_perf.txt`, `log_sustained.txt` | the long run — **contaminated, see below** |

## Read the labels before you use a number

**`log_z*_h*.txt` are NOT six different poses.** They are named for the
`--zoom` / `--advance-hours` arguments the launcher was given, and **those
arguments never reached the game** — two of them produced byte-identical
`dc`/`prim` sequences, and a separate probe carrying `--rain=1.0,--overlay=2`
came up in clear weather. Every one of these files is the same camera on the
same city. The filenames are kept as the record of what was attempted.

**`log_sustained.txt` and `soak_perf.txt` are contaminated and must not be
quoted.** They appear to show the governor running its full ladder to a latched
`preset=performance` at ~30 fps, but the app was not reliably in the foreground
for that run — the user picked the phone up partway through. A `SurfaceView`
that keeps ticking behind another app is not a frame measurement. The tell is in
the data: `gpu_est` *rises* from 11 ms to 18 ms *after* a degradation step,
which is backwards.

**The trustworthy captures are `log_probe_z0.txt` and the six `log_z*_h*.txt`**,
taken 14:02–14:07 with the game verified in the foreground and the phone
untouched between reset and read.

## Reproducing the aggregate

The per-run medians in doc 11 come from the steady-state lines only (`t ≥ 12 s`,
after shader warm-up and after the city finishes streaming — `inst` climbs to 70
and settles). Extract with:

    grep -a 'PERF t=' log_z0.0_h21.txt

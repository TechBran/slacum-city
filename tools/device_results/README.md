# Raw captures — Fold 6 device sessions

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

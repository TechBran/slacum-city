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

#!/usr/bin/env bash
# run_matrix.sh — the whole Fold session, in priority order, one command.
#
# Written 2026-08-21 while the phone sat behind a secure lockscreen, so that a
# window that opens for ten minutes is spent measuring rather than composing
# `adb` lines. Every step is independent and writes as it goes: if the window
# closes at step 3, steps 1-2 are already on disk and already correct.
#
#   bash tools/run_matrix.sh            # everything
#   bash tools/run_matrix.sh probe      # just the 1.2 args probe
#   bash tools/run_matrix.sh q1 zebra   # a subset, in the order given
#
# Nothing here uninstalls, clears, or deletes a save.
set -uo pipefail
cd "$(dirname "$0")/.."

PKG=com.slacumcity.game
OUT=tools/device_results
HOLD="${HOLD:-40}"
mkdir -p "$OUT"

cap() { bash tools/cap_pose.sh "$@"; }
hr()  { printf '\n=== %s\n' "$*"; }

## Fail-safe: anything short of a POSITIVE "not locked" counts as locked.
##
## The obvious spelling — `grep -c 'mDreamingLockscreen=true'` equals zero means
## unlocked — is wrong, and produced a false UNLOCKED on 2026-08-21 at 01:24:48:
## an empty or failed `dumpsys` (adb hiccup, device asleep, transport dropped)
## also greps to zero, and the caller then runs the whole matrix against a phone
## that cannot render, collecting captures that look exactly like an unarmed
## telemetry build. Require the dump to be substantial AND to say `=false`.
locked() {
  local d
  d="$(adb shell dumpsys window 2>/dev/null)"
  [[ "$(printf '%s' "$d" | wc -l)" -gt 20 ]] || return 0
  printf '%s' "$d" | grep -q 'mDreamingLockscreen=false' && return 1
  return 0
}

# ---------------------------------------------------------------- 1. the probe
# The §1.2 question, and it outranks everything: did the argument actually
# arrive? Answered THREE ways, because on 2026-08-21 the first two disagreed
# with each other and only the third was decisive.
step_probe() {
  hr "1. args-delivery probe (runbook §1.2)"
  cap probe_zoom "--resume --zoom=1.0 --perf" 20
  echo "-- plugin's own answer (Kotlin read the Intent):"
  adb logcat -d 2>/dev/null | grep -E 'SlacumNative.*launch args' | tail -3
  echo "-- Godot's own reader (expected [] on this template):"
  adb logcat -d 2>/dev/null | grep -E 'GodotActivity: Launch intent' | tail -2
  echo "-- lifecycle (OnStop right after OnResume == lockscreen, runbook §1.0):"
  adb logcat -d -s Godot:V 2>/dev/null | grep -E 'OnResume|OnPause|OnStop' | tail -4
  echo "-- the visible check: zoom=1.0 is the Z2 stop, near should read 0"
  python3 tools/perf_rows.py "$OUT/log_probe_zoom.txt"
}

# ------------------------------------------------------------- 2. pose matrix
# Three zooms x day/night. `near` is the column that proves the poses actually
# separated: 2026-08-20 got near=4 at every "zoom" because no argument landed.
step_q1() {
  hr "2. pose matrix — 3 zooms x day 13 / night 21, balanced"
  local z h
  for h in 13 21; do
    for z in 0.0 0.5 1.0; do
      echo "-- pose z$z h$h"
      cap "z${z}_h${h}" "--resume --zoom=$z --perf" "$HOLD" "$h"
    done
  done
  python3 tools/perf_rows.py "$OUT"/log_z*_h*.txt
}

# ------------------------------------------------------- 3. the zebra A/B
# Does the workstation's -61..-69% junction early-out win survive on Adreno 750?
# Junction pose, Z0, both hours, rung 2 vs rung 0. If rung 2 and rung 0 are
# within each other's spread on device, the ladder is pointless and every preset
# should read 2 (RR-42's note).
step_zebra() {
  hr "3. road_detail A/B at a junction pose (Q2)"
  # Pin `balanced` explicitly: `set_detail` clamps to the preset's ceiling, so on
  # a phone that auto-detected into `performance` (road_detail 1) the rung-2 arm
  # would silently BE rung 1 and the A/B would report no difference — which is
  # also the answer the session is hoping for, i.e. the failure would flatter the
  # hypothesis. Balanced's ceiling is 2, so both arms are reachable.
  local d h
  for h in 13 21; do
    for d in 2 0; do
      echo "-- road_detail=$d h$h"
      cap "rd${d}_h${h}" "--resume --zoom=0.0 --preset=balanced --road-detail=$d --perf" "$HOLD" "$h"
    done
  done
  python3 tools/perf_rows.py "$OUT"/log_rd*_h*.txt
}

# ------------------------------------------------------------- 4. flood on device
step_flood() {
  hr "4. flood + flood_detail A/B (flood wave q2)"
  # 2 vs 0 is the WHOLE ladder. Both `set_detail`s clamp to the preset's
  # ceiling, so this A/B is only honest on a preset whose ceiling is 2 —
  # `balanced` (flood_detail 2, road_detail 2) is, `performance` is not.
  local d
  for d in 2 0; do
    cap "flood${d}" "--resume --zoom=0.5 --preset=balanced --flood=350 --flood-detail=$d --perf" "$HOLD" 21
  done
  python3 tools/perf_rows.py "$OUT"/log_flood*.txt
  echo "-- the first device look at standing water:"
  adb exec-out screencap -p > "$OUT/flood_night.png" 2>/dev/null \
    && echo "   $OUT/flood_night.png ($(stat -c%s "$OUT/flood_night.png" 2>/dev/null) bytes)"
}

# --------------------------------------------------------- 5. pad shadows, daylight
step_pads() {
  hr "5. pad_shadows re-check at a DAYLIGHT pose (Q3/RR-33)"
  local p
  for p in 1 0; do
    cap "pads${p}" "--resume --zoom=0.0 --pad-shadows=$p --perf" "$HOLD" 13
  done
  python3 tools/perf_rows.py "$OUT"/log_pads*.txt
}

# ------------------------------------------------------------------ 6. save/load
# PERFIO. The save row wants a real lifecycle pause (backgrounding the app is
# what triggers it); the load row is read off the NEXT launch's boot.
step_io() {
  hr "6. PERFIO save / load"
  adb shell input keyevent KEYCODE_HOME
  sleep 4
  adb logcat -d -s godot:V 2>/dev/null | grep PERFIO | tail -5 | tee "$OUT/perfio_save.txt"
  cap io_boot "--resume --perf" 16
  grep PERFIO "$OUT/log_io_boot.txt" | tail -5 | tee "$OUT/perfio_load.txt"
}

# ----------------------------------------------------------------- 7. the extras
step_extras() {
  hr "7. thermal, memory, driver"
  adb shell dumpsys meminfo "$PKG" 2>/dev/null | head -22 | tee "$OUT/meminfo.txt"
  adb shell dumpsys thermalservice 2>/dev/null \
    | grep -iE "Temperature|status" | head -8 | tee "$OUT/thermal.txt"
}

if locked; then
  echo "REFUSING TO RUN: the phone is LOCKED (runbook §1.0)."
  echo "Every capture would come back empty and look like an unarmed telemetry"
  echo "build. Unlock the Fold, confirm with:"
  echo "  adb shell dumpsys window | grep mCurrentFocus"
  exit 3
fi

adb shell svc power stayon true >/dev/null 2>&1
adb shell run-as "$PKG" touch files/perf_capture.flag >/dev/null 2>&1

for step in "${@:-probe q1 zebra flood pads io extras}"; do
  case "$step" in
    probe)  step_probe ;;
    q1)     step_q1 ;;
    zebra)  step_zebra ;;
    flood)  step_flood ;;
    pads)   step_pads ;;
    io)     step_io ;;
    extras) step_extras ;;
    *) echo "unknown step: $step" ;;
  esac
done

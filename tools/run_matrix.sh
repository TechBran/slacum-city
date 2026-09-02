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
##
## ...and then the fail-safe itself failed, the other way, for a reason worth
## writing down. Measured 2026-08-21 on an awake, unlocked, focused Fold:
##
##   printf '%s' "$big" | grep -q 'mDreamingLockscreen=false'; echo $?
##   -> 141
##
## `grep -q` exits the instant it matches. `printf` is still writing the other
## ~200 KB, gets SIGPIPE, and dies 141 — and under `set -o pipefail` **the
## pipeline takes the writer's failure, not grep's success**, so a MATCH is
## reported as a non-match. The dump is 200 KB against a 64 KB pipe buffer, so
## this fires every time on a real device and never on a short test string
## (25 bytes: status 0). The result was that `run_matrix.sh` refused to run on
## an unlocked phone 100% of the time, which is a fail-safe that fails closed
## forever and is indistinguishable from "the phone is locked again".
##
## The fix is to not build a pipeline at all: bash's own `==` does the substring
## test on the variable, with no second process to signal.
locked() {
  local d
  d="$(adb shell dumpsys window 2>/dev/null)"
  # Substantial dump required: an empty or failed `dumpsys` must read as LOCKED,
  # never as unlocked. `${d//[!$'\n']/}` is the newlines alone; its length is the
  # line count, again without a pipe.
  local newlines="${d//[!$'\n']/}"
  [[ "${#newlines}" -gt 20 ]] || return 0
  [[ "$d" == *"mDreamingLockscreen=false"* ]] && return 1
  return 0
}

# ------------------------------------------------------- 0. is the BUILD real?
# The 2026-08-21 session died here and it took a dex dump to see it. The Kotlin
# half of D-20 (`SlacumNative.launch_args`) lives in an AAR at
# `android/plugins/slacum_native.aar`, and that file is a **gitignored build
# artifact**: it is NOT rebuilt by exporting, and it does not exist at all in a
# fresh `git worktree`. So the export happily packaged an AAR from two days
# earlier, the APK shipped a plugin with no `launch_args` method,
# `AndroidNative.launch_args()` found `has_method("launch_args") == false` and
# returned empty, `OS.get_cmdline_user_args()` returned `[]` as it always does
# on this template — and every dev argument was dropped in silence.
#
# The tell is brutal: the city still loads, the game still renders, `am start`
# still reports success. It looks exactly like a working session. The ONLY
# difference is that no argument does anything, which reads as "the poses did
# not separate" — the same symptom the 2026-08-20 session spent its window on.
#
# So: check the installed APK's own bytes, before spending a window.
#   tools/build_native_plugin.sh --debug   # rebuild the AAR
#   godot --headless --path . --export-debug "Android" build/slacum-debug.apk
#   adb install -r build/slacum-debug.apk  # `-r` keeps the saves
step_build_check() {
  hr "0. is the INSTALLED build a D-20 build? (the 2026-08-21 killer)"
  local apk tmp
  apk="$(adb shell pm path "$PKG" 2>/dev/null | sed -n 's/^package://p' | tr -d '\r')"
  if [[ -z "$apk" ]]; then
    echo "   cannot resolve the installed APK path — is the app installed?"
    return 1
  fi
  tmp="$(mktemp -d)"
  echo "   pulling $apk (~90 MB, a few seconds)"
  adb pull "$apk" "$tmp/base.apk" >/dev/null 2>&1 || {
    echo "   pull failed"; rm -rf "$tmp"; return 1; }
  unzip -o -q "$tmp/base.apk" 'classes*.dex' -d "$tmp" 2>/dev/null
  local hits control pin
  hits=$(cat "$tmp"/classes*.dex 2>/dev/null | grep -a -c 'launch_args') || hits=0
  # A control string that is in EVERY build of this plugin, so "0 hits" can be
  # told apart from "the grep is broken / the dex did not extract".
  control=$(cat "$tmp"/classes*.dex 2>/dev/null | grep -a -c 'thermal_status') || control=0
  # Wave 17: the refresh pin (report 98 RR-126) has the same failure mode as
  # D-20 and the same tell — a stale AAR ships a plugin with no
  # `set_frame_rate`, `AndroidNative.set_frame_rate()` finds no method, the
  # panel is never told, and the --refresh A/B runs both of its arms as `off`.
  pin=$(cat "$tmp"/classes*.dex 2>/dev/null | grep -a -c 'set_frame_rate') || pin=0
  rm -rf "$tmp"
  echo "   launch_args in dex: $hits    (control thermal_status: $control)"
  echo "   set_frame_rate in dex: $pin"
  if [[ "$control" -eq 0 ]]; then
    echo "   INCONCLUSIVE: the control symbol is missing too — the dex scan itself failed."
    return 1
  fi
  if [[ "$hits" -eq 0 ]]; then
    echo "   *** STALE PLUGIN: this APK CANNOT receive a single dev argument. ***"
    echo "   Every pose, A/B and hour in this matrix would return the same capture."
    echo "   Rebuild the AAR, re-export, reinstall (see the comment above) first."
    return 2
  fi
  if [[ "$pin" -eq 0 ]]; then
    echo "   *** STALE PLUGIN for the REFRESH PIN: --refresh=auto and =off are the"
    echo "   same arm on this build. The dev-argument half above is fine; the"
    echo "   frame-rate declaration is not. Rebuild the AAR before report 98 §46's A/B."
    return 2
  fi
  echo "   OK — the plugin can read the launch Intent and declare a frame rate."
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

  # The end-to-end verdict, and it is free — the probe launched anyway.
  # `--perf` is in the probe's argument list and NOTHING else arms the capture
  # (the flag file is deliberately not created until after this point), so
  # "PERF lines exist" IS "the argument arrived". This is the check that
  # distinguishes a stale plugin from a slow phone.
  local n
  n=$(grep -c 'PERF ' "$OUT/log_probe_zoom.txt" 2>/dev/null) || n=0
  echo "-- VERDICT:"
  if [[ "$n" -eq 0 ]]; then
    echo "   NO PERF LINES with --perf on the command line."
    echo "   Either the plugin is stale (run: bash tools/run_matrix.sh build_check)"
    echo "   or the app never ran (lockscreen). Do NOT run the rest of the matrix:"
    echo "   it would produce six identical captures and read like a result."
  else
    echo "   $n PERF lines from --perf alone — arguments ARE reaching GDScript."
  fi
}

# ------------------------------------------------------------- 2. pose matrix
# Three zooms x day/night. `near` is the column that proves the poses actually
# separated: 2026-08-20 got near=4 at every "zoom" because no argument landed.
step_q1() {
  hr "2. pose matrix — 3 zooms x day 13 / night 21, balanced"
  # `--preset=balanced` is PINNED here for the same reason it is pinned in the
  # zebra A/B below: the device auto-detects its preset when no `settings.cfg`
  # exists, and a matrix whose rows were taken under two different presets is
  # not a pose sweep. Balanced is what the Fold auto-detected on 2026-08-21
  # (`preset=balanced` in every PERF line), so pinning it changes nothing on
  # this phone and makes the rows reproducible on one that decides differently.
  local z h
  for h in 13 21; do
    for z in 0.0 0.5 1.0; do
      echo "-- pose z$z h$h"
      cap "z${z}_h${h}" "--resume --zoom=$z --preset=balanced --perf" "$HOLD" "$h"
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
  # NOT a bare `screencap`: this device has two displays and the un-`-d` form
  # prints a warning ahead of the PNG bytes, producing a file that is not an
  # image. `cap_pose.sh --snap` resolves the display and verifies the signature.
  cap --snap "$OUT/flood_night.png"
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

## `svc power stayon true` writes `stay_on_while_plugged_in`, which is a USER
## developer-option, not a scratch variable. `svc power stayon false` writes 0 —
## which is a *restore* only if 0 is what the phone had. The 2026-08-21 session
## found it at **15** (stay awake on every charger type) and could not tell
## whether that was the user's own setting or an earlier session's, because
## nobody had recorded it. Record it, then put back exactly what was there.
_STAYON_WAS="$(adb shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')"
[[ "$_STAYON_WAS" =~ ^[0-9]+$ ]] || _STAYON_WAS=""
adb shell svc power stayon true >/dev/null 2>&1

## The capture flag is a BELT-AND-BRACES arming route, and it must not be armed
## until after the probe. `_perf_capture_armed()` is
## `--perf in args OR the flag file exists`, so creating the file up front makes
## PERF lines appear whether or not the argument landed — which is precisely the
## evidence the probe exists to collect. Armed here, after step_probe has had
## its uncontaminated look, so the measuring steps still get their telemetry
## even on a phone where argument delivery is marginal.
##
## REMOVE IT WHEN YOU ARE DONE. While the file exists, every ordinary player
## session pays a per-frame GPU timestamp query. `trap` covers the ^C and the
## dropped-wire exits that left it armed on 2026-08-21.
_armed=0
arm_flag() {
  [[ $_armed -eq 1 ]] && return
  adb shell run-as "$PKG" touch files/perf_capture.flag >/dev/null 2>&1
  _armed=1
}
disarm_flag() {
  adb shell run-as "$PKG" rm -f files/perf_capture.flag >/dev/null 2>&1
  if [[ -n "$_STAYON_WAS" ]]; then
    adb shell settings put global stay_on_while_plugged_in "$_STAYON_WAS" \
      >/dev/null 2>&1
  else
    # Never read it (device already gone) — leave the phone alone rather than
    # guess 0 and silently turn off a setting the user chose.
    :
  fi
}
trap disarm_flag EXIT INT TERM

# No-argument form: the default list must be an ARRAY, not one quoted string —
# `"${@:-a b c}"` expands to the single word "a b c", which the dispatcher then
# reports as `unknown step: a b c` and (until 2026-09-01) exited 0 on, so the
# whole-session command did nothing and looked like success.
DEFAULT_STEPS=(build_check probe q1 zebra flood pads io extras)
if [ "$#" -eq 0 ]; then set -- "${DEFAULT_STEPS[@]}"; fi
for step in "$@"; do
  case "$step" in build_check|probe) ;; *) arm_flag ;; esac
  case "$step" in
    build_check)
      step_build_check
      rc=$?
      # A stale plugin is not a warning. Everything after this point would
      # return the same capture six times over, which is how two windows were
      # already lost — stop, rather than collect it.
      if [[ $rc -eq 2 ]]; then
        echo "REFUSING TO RUN THE MATRIX on a build that cannot receive arguments."
        exit 4
      fi
      ;;
    probe)  step_probe ;;
    q1)     step_q1 ;;
    zebra)  step_zebra ;;
    flood)  step_flood ;;
    pads)   step_pads ;;
    io)     step_io ;;
    extras) step_extras ;;
    *) echo "unknown step: $step" >&2; exit 2 ;;
  esac
done

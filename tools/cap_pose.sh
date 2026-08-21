#!/usr/bin/env bash
# cap_pose.sh — one pose, one capture, foreground-verified.
#
# Born on 2026-08-21, on first real device contact, out of three things the
# runbook could only guess at:
#
#  1. `adb shell` JOINS argv on spaces before handing the line to the device's
#     `sh -c`, so a space-bearing `--es args "…"` arrives at `am` as several
#     tokens and `am` dies with `Unknown option: --zoom=1.0`. Every launch here
#     is composed as ONE remote-shell string with the values single-quoted.
#  2. The in-game hour does not have to be read off the HUD by eye. The save
#     manifest carries `active.meta.sim_time_minutes`, so the `--advance-hours`
#     delta is computed, not estimated — and re-computed before every launch,
#     which makes the runbook's "re-base NOW after each pose" automatic.
#  3. The 2026-08-20 session's longest run was thrown away because the app was
#     not reliably in the foreground. Foreground is now asserted BEFORE and
#     AFTER every capture, and a capture that loses it is written with a
#     `CONTAMINATED` marker rather than silently averaged in.
#
# Usage: cap_pose.sh <label> <args-without-advance> <hold-seconds> [target-hour]
set -uo pipefail

PKG=com.slacumcity.game
ACT=com.godot.game.GodotAppLauncher
OUT="${OUT_DIR:-tools/device_results}"

label="$1"; args="$2"; hold="${3:-40}"; target_hour="${4:-}"

mkdir -p "$OUT"

## The save's own clock, in whole in-game hours. Empty if the manifest cannot be
## read — the caller then launches without an `--advance-hours` at all, which is
## the honest failure rather than advancing the player's city by a guess.
save_hour() {
  local mf
  mf="$(adb exec-out run-as "$PKG" cat "files/saves/slot_0/manifest.json" 2>/dev/null)"
  [[ -z "$mf" ]] && return 1
  printf '%s' "$mf" | python3 -c '
import json,sys
try:
    m = json.load(sys.stdin)
    print(int((m["active"]["meta"]["sim_time_minutes"] % 1440) // 60))
except Exception:
    sys.exit(1)
' 2>/dev/null
}

## True while the game owns the focused window. `mCurrentFocus` is the field that
## moves when the user picks the phone up, which is the exact failure being
## guarded; `mResumedActivity` keeps saying the game long after that.
is_foreground() {
  adb shell dumpsys window 2>/dev/null | grep -q "mCurrentFocus=.*$PKG"
}

if [[ -n "$target_hour" ]]; then
  now="$(save_hour)" || now=""
  if [[ -n "$now" ]]; then
    delta=$(( (target_hour - now + 24) % 24 ))
    [[ $delta -ne 0 ]] && args="$args --advance-hours=$delta"
    echo "  clock: save at ${now}:00, target ${target_hour}:00, delta +${delta}h"
  else
    echo "  clock: MANIFEST UNREADABLE — launching with no --advance-hours"
  fi
fi

csv="--,${args// /,}"
q_args="${args//\'/\'\\\'\'}"

adb logcat -c >/dev/null 2>&1
adb shell am force-stop "$PKG" >/dev/null 2>&1
sleep 2
adb shell "am start -n '$PKG/$ACT' --esa command_line_params '$csv' --es args '$q_args'" >/dev/null 2>&1

echo "  launched: $args"
sleep 14   # settle: Vulkan bring-up, shader warm-up, city stream-in, LOD dwell

fg_before=1; is_foreground || fg_before=0
sleep "$hold"
fg_after=1; is_foreground || fg_after=0

adb logcat -d -s godot:V > "$OUT/log_$label.txt" 2>/dev/null
# `grep -c` exits 1 on zero matches, so a `|| echo 0` appends a SECOND line and
# the count prints as "0\n0". Take the true branch's value or nothing.
n=$(grep -c 'PERF ' "$OUT/log_$label.txt" 2>/dev/null) || n=0

if [[ $fg_before -eq 0 || $fg_after -eq 0 ]]; then
  echo "CONTAMINATED fg_before=$fg_before fg_after=$fg_after" >> "$OUT/log_$label.txt"
  echo "  !! CONTAMINATED — app lost the foreground (before=$fg_before after=$fg_after)"
fi
echo "  captured $n PERF lines -> $OUT/log_$label.txt"

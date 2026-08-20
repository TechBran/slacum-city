#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# On-device performance harness — `tools/device_runbook.md`, over adb.
#
# **REWRITTEN 2026-08-20 (Wave 12). The version before this one could not run.**
# It drove three scenarios with `--bench=S1 --preset=balanced
# --city=res://tests/fixtures/bench_city.json` and launched them with
# `--es cmdline "…"`. `game/main.gd` parses none of those three flags, the
# activity it named (`com.godot.game.GodotApp`) is not the launcher, and the
# extra it used is not the one the Godot launcher reads. Every one of those is
# recorded in the runbook — §1.1, §1.2 and §1.3 — from the session that found
# them. This script now uses the vocabulary `game/main.gd` actually parses and
# drives the runbook's poses directly.
#
# What it collects, per pose:
#   * `dumpsys gfxinfo … framestats` — the platform's frame timeline, which is
#     what doc 11 §7.4's jank gate is written against. Summarised here into
#     n / mean / p50 / p95 / p99 / max / jank%.
#   * `dumpsys gfxinfo` percentiles, `meminfo`, `thermalservice`.
#   * `PERF` / `PERFIO` lines from logcat WHEN `--perf` is passed — the
#     renderer's own counters (`p95`, `dc`, `prim`, `chunks`, `knob`) and the
#     save/load split. These need the capture armed; see PRE-FLIGHT below.
#
# Usage:
#   tools/bench_device.sh --now=17                  # Q1's six poses
#   tools/bench_device.sh --question=preflight      # §1's five checks, alone
#   tools/bench_device.sh --question=Q6             # save/load by cold start
#   tools/bench_device.sh --scenario=S1,S2,S3 --now=17
#   tools/bench_device.sh --self-test               # no device needed
#
#     --question=preflight|Q1|Q6|extras|all   default all
#     --poses=all|z0-13,z2-21,…               Q1's pose list (default all six)
#     --scenario=S1,S2,S3                     doc 11 §7.4's three scenarios,
#                                             expressed in real dev args
#     --now=H            the in-game hour on the HUD RIGHT NOW. Required for any
#                        pose that names an hour: `--advance-hours` is a DELTA,
#                        not an hour of day (runbook §Q1).
#     --hold=N           seconds held per pose (default 60, doc 11 §7.4)
#     --settle=N         seconds after launch before the reset (default 12)
#     --repeats=N        cold starts per arm for Q6 (default 5)
#     --soak-min=N       extra thermal/PSS soak (default 0; §7.4 wants 20)
#     --preset=NAME      pass `--preset=NAME` to the app. **Only works with the
#                        optional integration snippet** — pre-flight greps
#                        `game/main.gd` and says so if it is missing.
#     --perf             also arm and collect PERF/PERFIO (adds `--perf`)
#     --serial=SERIAL    adb device (default: the only one attached)
#     --out-dir=DIR      default build/bench/<timestamp>
#     --skip-build       use the APK already installed
#     --dry-run          print every command, run none
#     --self-test        run everything that does not need a device, and check
#                        the argument vectors and the summariser against known
#                        answers. Exit 0 means the non-device half is sound.
#
# ---------------------------------------------------------------------------
# PRE-FLIGHT — what a device session must confirm before trusting a number.
# `--question=preflight` runs all five and prints a verdict per line.
#   1. The launcher activity. Resolved live, not hard-coded (runbook §1.1); the
#      2026-08-20 session found `GodotAppLauncher`, not `GodotApp`.
#   2. Arguments reach the game (§1.2). Two forms are sent on every launch —
#      `--esa command_line_params "--,a,b"` and `--es args "a b"` — because
#      `game/dev_args.gd` merges both and de-duplicates. The probe launches with
#      `--zoom=1.0` and reads the plugin's own `launch args:` line back out of
#      logcat.
#   3. The shell reads the MERGED list. `DevArgs.user_args()` in `game/main.gd`,
#      not `OS.get_cmdline_user_args()` — the AAR can deliver the extra and the
#      shell can still ignore it (§1.2). Grepped locally.
#   4. The graphics preset actually in force (§1.4), read off `settings.cfg`.
#   5. `PERF` is armed, if `--perf` was asked for — either the argument reaches
#      `_perf_capture_armed()` or the flag file is touched (§1.5).
# ---------------------------------------------------------------------------
set -uo pipefail

GODOT="${GODOT:-$HOME/.local/bin/godot}"
PROJECT="${PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PACKAGE="com.slacumcity.game"
# The activity-alias the 4.7.2 template emits. Pre-flight resolves the real one
# and overwrites this; the default is only the fallback for --dry-run.
ACTIVITY="com.godot.game.GodotAppLauncher"
APK="build/slacum-bench.apk"
PERF_FLAG_FILE="files/perf_capture.flag"

QUESTION="all"
POSES="all"
SCENARIOS=""
NOW=""
HOLD=60
SETTLE=12
REPEATS=5
SOAK_MIN=0
PRESET=""
WANT_PERF=0
SERIAL=""
OUT_DIR=""
SKIP_BUILD=0
DRY_RUN=0
SELF_TEST=0

for arg in "$@"; do
  case "$arg" in
    --question=*) QUESTION="${arg#*=}" ;;
    --poses=*)    POSES="${arg#*=}" ;;
    --scenario=*) SCENARIOS="${arg#*=}" ;;
    --now=*)      NOW="${arg#*=}" ;;
    --hold=*)     HOLD="${arg#*=}" ;;
    --settle=*)   SETTLE="${arg#*=}" ;;
    --repeats=*)  REPEATS="${arg#*=}" ;;
    --soak-min=*) SOAK_MIN="${arg#*=}" ;;
    --preset=*)   PRESET="${arg#*=}" ;;
    --perf)       WANT_PERF=1 ;;
    --serial=*)   SERIAL="${arg#*=}" ;;
    --out-dir=*)  OUT_DIR="${arg#*=}" ;;
    --skip-build) SKIP_BUILD=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --self-test)  SELF_TEST=1 ;;
    -h|--help)    sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "bench_device: unknown option $arg" >&2; exit 2 ;;
  esac
done

OUT_DIR="${OUT_DIR:-$PROJECT/build/bench/$(date +%Y%m%d-%H%M%S)}"
ADB=(adb)
[[ -n "$SERIAL" ]] && ADB=(adb -s "$SERIAL")

say()  { local IFS=' '; printf '\n=== %s\n' "$*"; }
note() { local IFS=' '; printf '    %s\n' "$*"; }
# `local IFS=' '` on every one of these is not decoration: the pose and scenario
# lists are comma-separated, and a `for x in $list` that set IFS globally used to
# leak it in here and print `adb,logcat,-c`. It also broke `resolve_hours`, which
# splits its argument on whitespace — the poses launched with the script's own
# `--hour=` shorthand instead of the `--advance-hours=` delta it resolves to.
# Caught by --dry-run; the lists are split into arrays now, and these stay as
# belt and braces.
run()  { if [[ $DRY_RUN -eq 1 ]]; then local IFS=' '; printf '  $ %s\n' "$*"; else "$@"; fi; }
# A command the DEVICE's shell has to parse (globs, redirections, loops).
shellrun() {
  if [[ $DRY_RUN -eq 1 ]]; then printf '  $ %s shell %s\n' "${ADB[*]}" "$1"
  else "${ADB[@]}" shell "$1"; fi
}

# ---------------------------------------------------------------------------
# The scenario vocabulary — every flag below is one `game/main.gd` parses.
# Grep it before adding one:
#   grep -n 'begins_with("--' game/main.gd
# ---------------------------------------------------------------------------

## Doc 11 §7.4's three scenarios, re-expressed in flags that exist. The old
## `--bench=S1` did not; the intent (steady state / night city / storm blackout)
## survives unchanged.
scenario_args() {
  case "$1" in
    S1) echo "--resume --zoom=0.5 --hour=13" ;;
    S2) echo "--resume --zoom=1.0 --hour=21" ;;
    S3) echo "--resume --zoom=0.5 --hour=21 --storm=0.9 --blackout" ;;
    *)  echo "" ;;
  esac
}

## Runbook §Q1's six poses: three zoom stops × the shadow hour and the emissive
## one. `zN` maps onto `--zoom=` exactly as §1.3's table says: 0.0 = Z0,
## 0.5 = Z1, 1.0 = Z2.
pose_args() {
  local pose="$1" zoom hour
  case "${pose%%-*}" in
    z0) zoom=0.0 ;;
    z1) zoom=0.5 ;;
    z2) zoom=1.0 ;;
    *)  echo ""; return ;;
  esac
  hour="${pose##*-}"
  echo "--resume --zoom=$zoom --hour=$hour"
}

## `--hour=H` is this script's shorthand, NOT a game flag. `game/main.gd` parses
## `--advance-hours=DELTA`, which advances the clock from wherever the save sits
## — so the shorthand is resolved here against `--now=`, and `--now=` is re-based
## after every pose because the clock keeps running (runbook §Q1).
##
## **The answer goes in `$RESOLVED_ARGS`, not on stdout, and that is the point.**
## `x="$(resolve_hours …)"` would run this in a subshell and the `NOW="$hour"`
## re-base would be thrown away with it — every pose after the first would then
## advance from the ORIGINAL hour and land somewhere nobody asked for. The
## self-test asserts the re-base for exactly this reason; it caught this bug.
RESOLVED_ARGS=""
resolve_hours() {
  local args="$1" out="" token hour delta
  local IFS=' '
  RESOLVED_ARGS=""
  for token in $args; do
    case "$token" in
      --hour=*)
        hour="${token#*=}"
        if [[ -z "$NOW" ]]; then
          echo "bench_device: a pose names hour $hour but --now=H was not given." >&2
          echo "  --advance-hours is a DELTA. Read the in-game hour off the HUD" >&2
          echo "  and pass it: --now=17   (runbook §Q1)" >&2
          return 1
        fi
        delta=$(( (hour - NOW + 24) % 24 ))
        out="$out --advance-hours=$delta"
        NOW="$hour"
        ;;
      *) out="$out $token" ;;
    esac
  done
  [[ -n "$PRESET" ]] && out="$out --preset=$PRESET"
  [[ $WANT_PERF -eq 1 ]] && out="$out --perf"
  RESOLVED_ARGS="${out# }"
}

## One launch, both extra forms. `game/dev_args.gd` merges the engine's list with
## the plugin's reading of the Intent and DE-DUPLICATES, so sending both is free
## insurance against either delivery path being the broken one — and an argument
## that arrives twice is applied once, which matters: `--advance-hours=4` counted
## twice would run the city eight hours forward before the first frame.
launch() {
  local args="$1"
  local csv="--,${args// /,}"
  run "${ADB[@]}" shell am force-stop "$PACKAGE"
  if [[ $DRY_RUN -eq 1 ]]; then
    # Printed quoted, so a session can copy the line straight out of a --dry-run
    # into a terminal and have it mean the same thing.
    printf '  $ %s shell am start -n %s/%s --esa command_line_params "%s" --es args "%s"\n' \
        "${ADB[*]}" "$PACKAGE" "$ACTIVITY" "$csv" "$args"
  else
    "${ADB[@]}" shell am start -n "$PACKAGE/$ACTIVITY" \
        --esa command_line_params "$csv" --es args "$args"
  fi
}

# ---------------------------------------------------------------------------
# Summarisers. Both are also what --self-test exercises, which is why they take
# a file path rather than reading a pipe.
# ---------------------------------------------------------------------------

summarise_framestats() {
  python3 - "$1" <<'PY'
import sys, statistics
# framestats columns: 0 FLAGS, 1 INTENDED_VSYNC, …, 13 FRAME_COMPLETED.
# A nonzero FLAGS marks a frame the platform says not to count (the first frame
# after a resume, a window layout). Counting them is the classic way to invent
# jank, so they are dropped.
rows = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    p = line.strip().split(',')
    if len(p) <= 13 or not p[0].isdigit() or int(p[0]) != 0:
        continue
    try:
        rows.append((int(p[13]) - int(p[1])) / 1e6)
    except ValueError:
        pass
rows = [r for r in rows if 0 < r < 500]
if not rows:
    print("    NO USABLE FRAMES — the app was not in the foreground, or "
          "'Profile HWUI rendering' is on (runbook §2)")
    raise SystemExit(0)
rows.sort()
n = len(rows)
q = lambda f: rows[min(n - 1, int(f * n))]
print("    n=%d  mean %.2f  p50 %.2f  p95 %.2f  p99 %.2f  max %.2f  "
      "jank>16.7 %.1f%%  jank>33 %.1f%%"
      % (n, statistics.mean(rows), q(.50), q(.95), q(.99), rows[-1],
         100 * sum(r > 16.7 for r in rows) / n,
         100 * sum(r > 33.3 for r in rows) / n))
PY
}

summarise_perf() {
  python3 - "$1" <<'PY'
import sys, statistics
p95s, dcs, prims, presets, knobs, io = [], [], [], set(), set(), []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    fields = dict(t.split("=", 1) for t in line.split() if "=" in t)
    if line.lstrip().startswith("PERFIO"):
        io.append(fields)
        continue
    try:
        p95s.append(float(fields["p95"]))
        dcs.append(int(fields["dc"]))
        prims.append(int(fields.get("prim", 0)))
        presets.add(fields.get("preset", "?"))
        knobs.add(int(fields.get("knob", 0)))
    except (KeyError, ValueError):
        continue
if p95s:
    print("    PERF   samples %3d  p95 mean %6.1f ms  p95 max %6.1f ms  "
          "peak dc %4d  peak prim %8d  preset %s  knobs %s"
          % (len(p95s), statistics.mean(p95s), max(p95s), max(dcs),
             max(prims), "/".join(sorted(presets)), sorted(knobs)))
else:
    print("    PERF   none — capture not armed (runbook §1.5): pass --perf, or")
    print("           adb shell run-as com.slacumcity.game touch "
          "files/perf_capture.flag")
for row in io:
    print("    PERFIO kind=%s ms=%s write_ms=%s read_ms=%s restore_ms=%s async=%s"
          % (row.get("kind", "?"), row.get("ms", "?"), row.get("write_ms", "?"),
             row.get("read_ms", "?"), row.get("restore_ms", "?"),
             row.get("async", "?")))
PY
}

# ---------------------------------------------------------------------------
# --self-test — the whole non-device half, checked against known answers.
# ---------------------------------------------------------------------------

self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  check() {  # check <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
      printf '  ok    %s\n' "$1"
    else
      printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"
      fails=$((fails + 1))
    fi
  }

  say "self-test: the flag vocabulary is one game/main.gd actually parses"
  local parsed missing=""
  parsed="$(grep -o 'begins_with("--[a-z-]*="' "$PROJECT/game/main.gd" \
      | sed 's/.*("//; s/="$//' ; \
      grep -o 'String(arg) == "--[a-z-]*"' "$PROJECT/game/main.gd" \
      | sed 's/.*"--/--/; s/"$//' ; \
      grep -o 'user_args.has("--[a-z-]*")' "$PROJECT/game/main.gd" \
      | sed 's/.*("//; s/")$//' ; \
      grep -o 'DevArgs.user_args().has("--[a-z-]*")' "$PROJECT/game/main.gd" \
      | sed 's/.*("//; s/")$//')"
  for flag in --resume --zoom --advance-hours --storm --blackout --perf; do
    grep -qx -- "${flag}=\?" <<<"$parsed" || grep -qx -- "$flag" <<<"$parsed" \
        || missing="$missing $flag"
  done
  check "every flag this script sends exists in game/main.gd" "" "$missing"

  say "self-test: --hour= resolves to an --advance-hours DELTA and re-bases"
  NOW=17
  resolve_hours "--resume --zoom=0.5 --hour=21"
  check "hour 21 from 17" "--resume --zoom=0.5 --advance-hours=4" "$RESOLVED_ARGS"
  check "NOW re-based to 21" "21" "$NOW"
  resolve_hours "--resume --zoom=1.0 --hour=13"
  check "hour 13 from 21 wraps the day" "--resume --zoom=1.0 --advance-hours=16" \
      "$RESOLVED_ARGS"
  check "NOW re-based to 13" "13" "$NOW"
  NOW=""
  resolve_hours "--resume --hour=13" >/dev/null 2>&1
  check "a pose with an hour and no --now= is refused" "1" "$?"
  NOW=17
  resolve_hours "--resume --zoom=0.0"
  check "a pose with no hour needs no --now=" "--resume --zoom=0.0" "$RESOLVED_ARGS"

  say "self-test: pose and scenario tables"
  check "z2-13 pose"  "--resume --zoom=1.0 --hour=13" "$(pose_args z2-13)"
  check "z0-21 pose"  "--resume --zoom=0.0 --hour=21" "$(pose_args z0-21)"
  check "unknown pose is empty" "" "$(pose_args q9-13)"
  check "S3 scenario" "--resume --zoom=0.5 --hour=21 --storm=0.9 --blackout" \
      "$(scenario_args S3)"

  say "self-test: the launch line carries BOTH extra forms, with the separator"
  DRY_RUN=1
  local launched
  launched="$(launch "--resume --zoom=1.0" | tr -s ' ')"
  case "$launched" in
    *'--esa command_line_params "--,--resume,--zoom=1.0"'*) printf '  ok    --esa carries the leading -- separator\n' ;;
    *) printf '  FAIL  --esa form: %s\n' "$launched"; fails=$((fails + 1)) ;;
  esac
  case "$launched" in
    *'--es args "--resume --zoom=1.0"'*) printf '  ok    --es args carries the plain form\n' ;;
    *) printf '  FAIL  --es args form: %s\n' "$launched"; fails=$((fails + 1)) ;;
  esac
  case "$launched" in
    *"GodotAppLauncher"*) printf '  ok    activity default is the alias, not GodotApp\n' ;;
    *) printf '  FAIL  activity: %s\n' "$launched"; fails=$((fails + 1)) ;;
  esac
  DRY_RUN=0

  say "self-test: a COMMA pose list still resolves its hours"
  # The regression this guards: `for pose in $list` with `IFS=,` leaked the comma
  # into `resolve_hours`, which splits on whitespace — so every pose launched
  # with the script's own `--hour=` shorthand, a flag `game/main.gd` does not
  # parse, and every capture was taken at whatever hour the save happened to
  # hold. It printed `adb,logcat,-c` too, which is what made it visible.
  DRY_RUN=1
  NOW=17
  POSES="z0-13,z2-21"
  local q1
  q1="$(question_q1 2>&1)"
  DRY_RUN=0
  POSES="all"
  case "$q1" in
    *"--hour="*) printf '  FAIL  --hour= reached the launch line unresolved\n'
                 fails=$((fails + 1)) ;;
    *) printf '  ok    no --hour= survives to a launch\n' ;;
  esac
  case "$q1" in
    *"--advance-hours=20"*"--advance-hours=8"*)
      printf '  ok    both poses resolved, second one re-based (17→13→21)\n' ;;
    *) printf '  FAIL  deltas: %s\n' "$(grep -o -- '--advance-hours=[0-9]*' <<<"$q1" | tr '\n' ' ')"
       fails=$((fails + 1)) ;;
  esac
  case "$q1" in
    *"adb,"*) printf '  FAIL  IFS leaked into the command printer\n'
              fails=$((fails + 1)) ;;
    *) printf '  ok    commands print with spaces, not commas\n' ;;
  esac

  say "self-test: the framestats summariser, on a known timeline"
  # 0 FLAGS … 1 INTENDED_VSYNC … 13 FRAME_COMPLETED. Four good frames at
  # 10/20/30/40 ms and one FLAGS=1 row that must be ignored.
  {
    echo "---PROFILEDATA---"
    echo "Flags,IntendedVsync,Vsync,x,x,x,x,x,x,x,x,x,x,FrameCompleted"
    echo "0,0,0,0,0,0,0,0,0,0,0,0,0,10000000"
    echo "0,0,0,0,0,0,0,0,0,0,0,0,0,20000000"
    echo "0,0,0,0,0,0,0,0,0,0,0,0,0,30000000"
    echo "0,0,0,0,0,0,0,0,0,0,0,0,0,40000000"
    echo "1,0,0,0,0,0,0,0,0,0,0,0,0,400000000"
  } > "$tmp/fs.txt"
  local fs
  fs="$(summarise_framestats "$tmp/fs.txt" | tr -s ' ')"
  case "$fs" in
    *"n=4 mean 25.00 p50 30.00 p95 40.00"*) printf '  ok    n / mean / p50 / p95\n' ;;
    *) printf '  FAIL  framestats: %s\n' "$fs"; fails=$((fails + 1)) ;;
  esac
  case "$fs" in
    *"jank>16.7 75.0% jank>33 25.0%"*) printf '  ok    jank percentages, FLAGS row excluded\n' ;;
    *) printf '  FAIL  jank: %s\n' "$fs"; fails=$((fails + 1)) ;;
  esac
  : > "$tmp/empty.txt"
  case "$(summarise_framestats "$tmp/empty.txt")" in
    *"NO USABLE FRAMES"*) printf '  ok    an empty capture says so instead of dividing by zero\n' ;;
    *) printf '  FAIL  empty framestats did not report\n'; fails=$((fails + 1)) ;;
  esac

  say "self-test: the PERF/PERFIO summariser"
  {
    echo "PERF t=2.0 fps=58.1 p95=18.2 cpu=0.6 gpu_est=9.1 dc=191 prim=237076 preset=balanced knob=0"
    echo "PERF t=4.0 fps=59.7 p95=16.9 cpu=0.5 gpu_est=8.4 dc=196 prim=237076 preset=balanced knob=1"
    echo "PERFIO kind=save slot=0 reason=auto ms=97.5 write_ms=52.4 read_ms=0.0 restore_ms=0.0 async=true"
  } > "$tmp/perf.txt"
  local pf
  pf="$(summarise_perf "$tmp/perf.txt" | tr -s ' ')"
  case "$pf" in
    *"samples 2 p95 mean 17.5 ms p95 max 18.2 ms peak dc 196 peak prim 237076 preset balanced knobs [0, 1]"*)
      printf '  ok    PERF columns\n' ;;
    *) printf '  FAIL  PERF: %s\n' "$pf"; fails=$((fails + 1)) ;;
  esac
  case "$pf" in
    *"PERFIO kind=save ms=97.5 write_ms=52.4"*) printf '  ok    PERFIO split\n' ;;
    *) printf '  FAIL  PERFIO: %s\n' "$pf"; fails=$((fails + 1)) ;;
  esac
  : > "$tmp/noperf.txt"
  case "$(summarise_perf "$tmp/noperf.txt")" in
    *"capture not armed"*) printf '  ok    an unarmed capture names the two ways to arm it\n' ;;
    *) printf '  FAIL  unarmed PERF did not report\n'; fails=$((fails + 1)) ;;
  esac

  say "self-test result"
  if [[ $fails -eq 0 ]]; then
    note "PASS — every check that does not need a device."
    note "THE DEVICE HALF IS UNVERIFIED: activity resolution, argument delivery,"
    note "gfxinfo/meminfo/thermal collection and the Q6 cold starts have never"
    note "been run against hardware from this file. Run --question=preflight"
    note "first with the Fold on the wire and trust nothing until it is green."
    return 0
  fi
  note "FAILED: $fails check(s)."
  return 1
}

# (The self-test is INVOKED at the bottom of this file, not here: bash defines
# functions as it reads, and `self_test` drives `question_q1`, which is defined
# below. Calling it from this line silently exercised an undefined function.)

# ---------------------------------------------------------------------------
# Device
# ---------------------------------------------------------------------------

require_device() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
    echo "bench_device: no device (adb get-state failed). Connect the Fold 6" >&2
    echo "  (wireless: adb connect <ip>:<port>) and retry. Nothing here works" >&2
    echo "  without one; --self-test is the device-free check." >&2
    exit 1
  fi
}

preflight() {
  say "pre-flight (runbook §1)"
  if [[ $DRY_RUN -eq 0 ]]; then
    note "model:   $("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')"
    note "android: $("${ADB[@]}" shell getprop ro.build.version.release | tr -d '\r')"
    # §1.1 — resolve the activity, never assume it.
    local resolved
    resolved="$("${ADB[@]}" shell cmd package resolve-activity --brief "$PACKAGE" \
        2>/dev/null | tail -1 | tr -d '\r')"
    if [[ "$resolved" == */* ]]; then
      ACTIVITY="${resolved#*/}"
      note "§1.1 activity: $ACTIVITY (resolved)"
    else
      note "§1.1 activity: NOT RESOLVED — is the app installed? keeping $ACTIVITY"
    fi
  fi
  # §1.2 second half — the shell has to read the MERGED list, and that is a
  # source fact, checkable without the device.
  if grep -q 'DevArgs.user_args' "$PROJECT/game/main.gd"; then
    note "§1.2 shell reads DevArgs.user_args() — ok"
  else
    note "§1.2 game/main.gd still reads OS.get_cmdline_user_args() — NO argument"
    note "     will reach the game on device however good the AAR is. Stop here."
  fi
  if [[ -n "$PRESET" ]]; then
    if grep -q 'begins_with("--preset=")' "$PROJECT/game/main.gd"; then
      note "--preset=$PRESET will be honoured"
    else
      note "--preset=$PRESET WILL BE IGNORED: game/main.gd does not parse it."
      note "     The snippet is in this branch's report; without it, take the"
      note "     preset from settings.cfg below and label the columns with THAT."
    fi
  fi
  # §1.2 first half — the live probe.
  say "§1.2 argument-delivery probe (--zoom=1.0 must put the camera at Z2)"
  run "${ADB[@]}" logcat -c
  launch "--resume --zoom=1.0"
  if [[ $DRY_RUN -eq 0 ]]; then
    sleep "$SETTLE"
    local args_line
    args_line="$("${ADB[@]}" logcat -d -s SlacumNative:I 2>/dev/null \
        | grep -m1 'launch args' | tr -d '\r')"
    if [[ -n "$args_line" ]]; then
      note "plugin saw: $args_line"
    else
      note "plugin printed no 'launch args' line — either the build predates"
      note "     doc 13 D-20's fix, or the extra did not arrive. Everything"
      note "     below that names a pose is undrivable until this is green."
    fi
    note "LOOK AT THE SCREEN: it must be at the far zoom stop, not mid-zoom."
  fi
  # §1.4
  say "§1.4 the graphics preset actually in force"
  shellrun "run-as $PACKAGE cat /data/data/$PACKAGE/files/settings.cfg 2>/dev/null | grep -i graphics" \
      || note "no settings.cfg — the preset was auto-detected; read it off a PERF line"
  # §1.5
  if [[ $WANT_PERF -eq 1 ]]; then
    say "§1.5 arming PERF"
    note "belt and braces: the --perf argument AND the flag file"
    shellrun "run-as $PACKAGE touch $PERF_FLAG_FILE" \
        || note "flag file not writable (release build?) — relying on --perf"
  fi
}

build_and_install() {
  [[ $SKIP_BUILD -eq 1 ]] && return 0
  say "build + install"
  # The fixture rides inside the APK: `tests/fixtures/bench_city.json` is a
  # committed resource, so nothing has to be pushed alongside the build.
  run "$GODOT" --headless --path "$PROJECT" --export-debug "Android" "$PROJECT/$APK"
  run "${ADB[@]}" install -r "$PROJECT/$APK"
}

quiet_the_device() {
  say "quiet the device (runbook §2 preamble)"
  shellrun "settings put global window_animation_scale 0"
  shellrun "settings put global transition_animation_scale 0"
  note "Developer options → 'Profile HWUI rendering' MUST be off, or framestats"
  note "reports the profiler instead of the game."
}

## One pose, start to summary. `label` names the artefacts.
measure_pose() {
  local label="$1" args="$2"
  resolve_hours "$args" || return 1
  local resolved="$RESOLVED_ARGS"
  say "$label   ($resolved)"
  run "${ADB[@]}" logcat -c
  launch "$resolved"
  run sleep "$SETTLE"
  shellrun "dumpsys gfxinfo $PACKAGE reset"

  local perf_pid=""
  if [[ $WANT_PERF -eq 1 && $DRY_RUN -eq 0 ]]; then
    "${ADB[@]}" logcat -s godot:V | grep --line-buffered '^PERF' \
        > "$OUT_DIR/perf_$label.txt" &
    perf_pid=$!
  fi

  local reads=$(( (HOLD + 1) / 2 ))
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  $ for i in $(seq 1 %d); do %s shell "dumpsys gfxinfo %s framestats" >> %s; sleep 2; done\n' \
        "$reads" "${ADB[*]}" "$PACKAGE" "$OUT_DIR/fs_$label.txt"
  else
    : > "$OUT_DIR/fs_$label.txt"
    # One framestats read returns at most 120 frames — two seconds at 60 Hz — so
    # a 60-second hold has to poll. Do not touch the phone between the reset and
    # the last read: a finger on the glass is a pan, and a pan is a different
    # measurement.
    for _ in $(seq 1 "$reads"); do
      "${ADB[@]}" shell "dumpsys gfxinfo $PACKAGE framestats" \
          >> "$OUT_DIR/fs_$label.txt"
      sleep 2
    done
    "${ADB[@]}" shell "dumpsys gfxinfo $PACKAGE" \
        | grep -E "Total frames|Janky|50th|90th|95th|99th" \
        > "$OUT_DIR/gfx_$label.txt"
    "${ADB[@]}" shell "dumpsys meminfo $PACKAGE" > "$OUT_DIR/meminfo_$label.txt"
    "${ADB[@]}" shell "dumpsys thermalservice" > "$OUT_DIR/thermal_$label.txt"
    [[ -n "$perf_pid" ]] && kill "$perf_pid" 2>/dev/null
    summarise_framestats "$OUT_DIR/fs_$label.txt"
    cat "$OUT_DIR/gfx_$label.txt" | sed 's/^/    /'
    [[ $WANT_PERF -eq 1 ]] && summarise_perf "$OUT_DIR/perf_$label.txt"
  fi
}

question_q1() {
  local list="$POSES"
  [[ "$list" == "all" ]] && list="z0-13,z0-21,z1-13,z1-21,z2-13,z2-21"
  say "Q1 — frame time and jank, ${HOLD}s per pose"
  note "poses: $list"
  local names=()
  IFS=',' read -r -a names <<<"$list"
  for pose in "${names[@]}"; do
    local args
    args="$(pose_args "$pose")"
    if [[ -z "$args" ]]; then
      echo "bench_device: unknown pose $pose (z0|z1|z2 - hour)" >&2
      return 2
    fi
    measure_pose "$pose" "$args" || return 1
  done
}

question_scenarios() {
  say "doc 11 §7.4 scenarios"
  local names=()
  IFS=',' read -r -a names <<<"$SCENARIOS"
  for s in "${names[@]}"; do
    local args
    args="$(scenario_args "$s")"
    if [[ -z "$args" ]]; then
      echo "bench_device: unknown scenario $s (S1|S2|S3)" >&2
      return 2
    fi
    measure_pose "$s" "$args" || return 1
  done
}

## Runbook §Q6. No timing instrument in a plain build, so the measurement is a
## difference of cold starts: B − A is the LOAD, C − B is the SAVE, and both
## differences cancel process start, Vulkan init and shader warm-up.
question_q6() {
  say "Q6 — save and load, by cold-start difference (${REPEATS} runs per arm)"
  local arm
  for arm in A:--title B:--resume C:"--resume --save-now"; do
    local name="${arm%%:*}" args="${arm#*:}"
    [[ $WANT_PERF -eq 1 ]] && args="$args --perf"
    [[ $DRY_RUN -eq 0 ]] && : > "$OUT_DIR/coldstart_$name.txt"
    local i
    for i in $(seq 1 "$REPEATS"); do
      run "${ADB[@]}" shell am force-stop "$PACKAGE"
      run sleep 2
      if [[ $DRY_RUN -eq 1 ]]; then
        printf '  $ %s shell am start -W -n %s/%s --esa command_line_params "--,%s"\n' \
            "${ADB[*]}" "$PACKAGE" "$ACTIVITY" "${args// /,}"
      else
        "${ADB[@]}" shell am start -W -n "$PACKAGE/$ACTIVITY" \
            --esa command_line_params "--,${args// /,}" --es args "$args" \
            | grep -E "^TotalTime" >> "$OUT_DIR/coldstart_$name.txt"
      fi
    done
  done
  [[ $DRY_RUN -eq 1 ]] && return 0
  python3 - "$OUT_DIR" <<'PY'
import os, statistics, sys
out = sys.argv[1]
med = {}
for name in "ABC":
    path = os.path.join(out, "coldstart_%s.txt" % name)
    vals = []
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.split(":")
        if len(parts) == 2 and parts[1].strip().isdigit():
            vals.append(int(parts[1].strip()))
    if vals:
        med[name] = statistics.median(vals)
        print("    %s median TotalTime %6.0f ms   (n=%d)" % (name, med[name], len(vals)))
    else:
        print("    %s NO TotalTime lines — am start -W did not report" % name)
if "A" in med and "B" in med:
    print("    LOAD  (B - A) = %6.0f ms" % (med["B"] - med["A"]))
if "B" in med and "C" in med:
    print("    SAVE  (C - B) = %6.0f ms" % (med["C"] - med["B"]))
print("    Workstation provisional (runbook §Q6): founding city save 13.9 ms /")
print("    load 48.5 ms; bench city 148.7 / 483.9. Expect the Fold at 2-3x.")
PY
  note "sanity: 'adb logcat -d | grep save-now' must show the line, or arm C's"
  note "arguments did not arrive and C - B is noise (runbook §1.2)."
}

question_extras() {
  say "extras"
  shellrun "dumpsys meminfo $PACKAGE | head -30"
  shellrun "dumpsys thermalservice | grep -iE 'status|Temperature'"
  if [[ "$SOAK_MIN" -gt 0 ]]; then
    say "soak — ${SOAK_MIN} min (thermal, PSS and battery gates)"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '  $ (thermal sampler every 10s for %s min)\n' "$SOAK_MIN"
    else
      "${ADB[@]}" shell 'while true; do date +%s; cat /sys/class/thermal/thermal_zone0/temp; sleep 10; done' \
          > "$OUT_DIR/thermal_soak.log" &
      local thermal_pid=$!
      sleep $((SOAK_MIN * 60))
      kill "$thermal_pid" 2>/dev/null
      "${ADB[@]}" shell "dumpsys meminfo $PACKAGE" > "$OUT_DIR/meminfo_soak.txt"
      "${ADB[@]}" shell "dumpsys batterystats $PACKAGE" > "$OUT_DIR/batterystats.txt"
    fi
  fi
}

# ---------------------------------------------------------------------------

if [[ $SELF_TEST -eq 1 ]]; then
  self_test
  exit $?
fi

require_device
run mkdir -p "$OUT_DIR"

case "$QUESTION" in
  preflight) preflight ;;
  Q1|q1)     build_and_install; preflight; quiet_the_device; question_q1 ;;
  Q6|q6)     build_and_install; preflight; quiet_the_device; question_q6 ;;
  extras)    question_extras ;;
  all)
    build_and_install
    preflight
    quiet_the_device
    if [[ -n "$SCENARIOS" ]]; then question_scenarios; else question_q1; fi
    question_q6
    question_extras
    ;;
  *) echo "bench_device: unknown --question=$QUESTION" >&2; exit 2 ;;
esac

say "done"
note "artefacts: $OUT_DIR"
note "gates: doc 11 §7.4. framestats_*/fs_* carry the jank percentage,"
note "meminfo_* the PSS, thermal_soak.log the temperature rise."

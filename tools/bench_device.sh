#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# On-device performance harness — doc 11 §7.4, over adb.
#
# Builds a debug APK, installs it, runs each §7.4 scenario against the benchmark
# city, and collects BOTH sides of the measurement:
#
#   * our own counters, from `PerfGovernor.perf_line()` — one `PERF` line every
#     `governor.perf_log_interval_s` (2 s), captured from logcat;
#   * the platform's, from `dumpsys gfxinfo … framestats`, `dumpsys meminfo`,
#     `dumpsys thermalservice` and `dumpsys batterystats`.
#
# The two are collected together on purpose. §7.4's gate table mixes them (p95
# from us, jank percentage from gfxinfo), and a run that has only our numbers
# cannot tell a slow frame from a frame the compositor dropped.
#
# THIS SCRIPT HAS NEVER BEEN RUN AGAINST A DEVICE. It ships ready for the first
# Fold 6 session; every command in it is from doc 11 §7.4 and doc 13 §7, and the
# things it cannot know until then — the exact activity name after an export
# template change, whether `--es cmdline` survives the Godot launcher — are
# called out at `PRE-FLIGHT` below. Run `--dry-run` first: it prints every
# command without executing any of them.
#
# Usage:
#   tools/bench_device.sh [options]
#     --scenario=S1|S2|S3|all   default all
#     --preset=performance|balanced|high    default balanced
#     --serial=SERIAL           adb device (default: the only one attached)
#     --out-dir=DIR             default build/bench/<timestamp>
#     --duration=N              seconds per scenario (default 90, doc 11 §7.4)
#     --soak-min=N              extra S3 loop for the thermal/PSS gates (default 0;
#                               §7.4 wants 20)
#     --skip-build              use the APK already installed
#     --dry-run                 print commands, run nothing
# ---------------------------------------------------------------------------
set -uo pipefail

GODOT="${GODOT:-$HOME/.local/bin/godot}"
PROJECT="${PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PACKAGE="com.slacumcity.game"
ACTIVITY="com.godot.game.GodotApp"
APK="build/slacum-bench.apk"

SCENARIO="all"
PRESET="balanced"
SERIAL=""
OUT_DIR=""
DURATION=90
SOAK_MIN=0
SKIP_BUILD=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --scenario=*)  SCENARIO="${arg#*=}" ;;
    --preset=*)    PRESET="${arg#*=}" ;;
    --serial=*)    SERIAL="${arg#*=}" ;;
    --out-dir=*)   OUT_DIR="${arg#*=}" ;;
    --duration=*)  DURATION="${arg#*=}" ;;
    --soak-min=*)  SOAK_MIN="${arg#*=}" ;;
    --skip-build)  SKIP_BUILD=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "bench_device: unknown option $arg" >&2; exit 2 ;;
  esac
done

OUT_DIR="${OUT_DIR:-$PROJECT/build/bench/$(date +%Y%m%d-%H%M%S)}"
ADB=(adb)
[[ -n "$SERIAL" ]] && ADB=(adb -s "$SERIAL")

say()  { printf '\n=== %s\n' "$*"; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '  $ %s\n' "$*"; else "$@"; fi; }
shellrun() {  # a command that must be evaluated by the device's shell
  if [[ $DRY_RUN -eq 1 ]]; then printf '  $ %s\n' "${ADB[*]} shell $1"
  else "${ADB[@]}" shell "$1"; fi
}

# ---------------------------------------------------------------------------
# PRE-FLIGHT — the three things that can only be confirmed with a device on the
# end of the cable. If any of them is wrong the run produces an empty CSV rather
# than a wrong number, which is the failure mode we want.
#   1. `$ACTIVITY` is the launcher activity the current export template emits.
#      Confirm with: adb shell cmd package resolve-activity --brief $PACKAGE
#   2. `--es cmdline "…"` is how the Godot Android launcher forwards user args.
#      Confirm the app saw them: the first PERF line must report the preset asked
#      for, not the one in settings.cfg.
#   3. `dumpsys gfxinfo … framestats` needs the app in the foreground and the
#      "Profile HWUI rendering" developer option NOT set to a bar graph.
# ---------------------------------------------------------------------------

say "device"
if [[ $DRY_RUN -eq 0 ]]; then
  if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
    echo "bench_device: no device (adb get-state failed). Connect the Fold 6" >&2
    echo "  (wireless: adb connect <ip>:<port>) and retry." >&2
    exit 1
  fi
  "${ADB[@]}" shell getprop ro.product.model
  "${ADB[@]}" shell getprop ro.build.version.release
fi
run mkdir -p "$OUT_DIR"

if [[ $SKIP_BUILD -eq 0 ]]; then
  say "build + install"
  # The fixture rides inside the APK: `tests/fixtures/bench_city.json` is a
  # committed resource, so nothing has to be pushed alongside the build.
  run "$GODOT" --headless --path "$PROJECT" --export-debug "Android" "$PROJECT/$APK"
  run "${ADB[@]}" install -r "$PROJECT/$APK"
fi

scenarios=()
case "$SCENARIO" in
  all) scenarios=(S1 S2 S3) ;;
  *)   scenarios=("$SCENARIO") ;;
esac

# Doc 11 §7.4's three scenarios, as the argument vector each one needs.
scenario_args() {
  case "$1" in
    S1) echo "--bench=S1 --preset=$PRESET --city=res://tests/fixtures/bench_city.json --advance-hours=12" ;;
    S2) echo "--bench=S2 --preset=$PRESET --city=res://tests/fixtures/bench_city.json --advance-hours=20" ;;
    S3) echo "--bench=S3 --preset=$PRESET --city=res://tests/fixtures/bench_city.json --advance-hours=20 --storm=0.9 --blackout" ;;
    *)  echo ""; ;;
  esac
}

for s in "${scenarios[@]}"; do
  args="$(scenario_args "$s")"
  if [[ -z "$args" ]]; then
    echo "bench_device: unknown scenario $s" >&2
    exit 2
  fi
  say "$s  ($PRESET, ${DURATION}s)"
  run "${ADB[@]}" logcat -c
  shellrun "dumpsys gfxinfo $PACKAGE reset"
  shellrun "dumpsys batterystats --reset"
  run "${ADB[@]}" shell am force-stop "$PACKAGE"
  run "${ADB[@]}" shell am start -n "$PACKAGE/$ACTIVITY" --es cmdline "$args"

  # PERF lines stream while the scenario plays; logcat is drained in the
  # background so a full ring buffer cannot silently truncate a long run.
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  $ %s logcat -s godot:V | grep --line-buffered "^PERF" > %s\n' \
        "${ADB[*]}" "$OUT_DIR/perf_${s}_${PRESET}.csv"
    printf '  $ sleep %s\n' "$DURATION"
  else
    "${ADB[@]}" logcat -s godot:V \
        | grep --line-buffered '^PERF' > "$OUT_DIR/perf_${s}_${PRESET}.csv" &
    LOGCAT_PID=$!
    sleep "$DURATION"
    kill "$LOGCAT_PID" 2>/dev/null || true
  fi

  # The platform's own view. `framestats` is the ground truth for the jank gate;
  # our p95 is the ground truth for the frame-time gate. Keep both.
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  $ %s shell dumpsys gfxinfo %s framestats > %s\n' \
        "${ADB[*]}" "$PACKAGE" "$OUT_DIR/framestats_${s}.txt"
    printf '  $ %s shell dumpsys meminfo %s > %s\n' \
        "${ADB[*]}" "$PACKAGE" "$OUT_DIR/meminfo_${s}.txt"
  else
    "${ADB[@]}" shell "dumpsys gfxinfo $PACKAGE framestats" \
        > "$OUT_DIR/framestats_${s}.txt"
    "${ADB[@]}" shell "dumpsys meminfo $PACKAGE" > "$OUT_DIR/meminfo_${s}.txt"
    "${ADB[@]}" shell "dumpsys thermalservice" > "$OUT_DIR/thermal_${s}.txt"
  fi
done

if [[ "$SOAK_MIN" -gt 0 ]]; then
  say "S3 soak — ${SOAK_MIN} min (thermal, PSS and battery gates)"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  $ (thermal sampler every 10s for %s min)\n' "$SOAK_MIN"
  else
    "${ADB[@]}" shell 'while true; do cat /sys/class/thermal/thermal_zone0/temp; sleep 10; done' \
        > "$OUT_DIR/thermal_soak.log" &
    THERMAL_PID=$!
    sleep $((SOAK_MIN * 60))
    kill "$THERMAL_PID" 2>/dev/null || true
    "${ADB[@]}" shell "dumpsys meminfo $PACKAGE" > "$OUT_DIR/meminfo_soak.txt"
    "${ADB[@]}" shell "dumpsys batterystats $PACKAGE" > "$OUT_DIR/batterystats.txt"
    "${ADB[@]}" shell "dumpsys thermalservice" > "$OUT_DIR/thermal_soak_status.txt"
  fi
fi

say "summary"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  (dry run — nothing was executed)"
  exit 0
fi

# The gate table lives in doc 11 §7.4; this prints the numbers to check it
# against rather than deciding pass/fail, because two of the gates ("no frame
# over 50 ms during the blackout window", "shader compiles after 10 s") need the
# scenario timeline to interpret and a script that guessed would be worse than
# one that reports.
python3 - "$OUT_DIR" <<'PY'
import glob, os, statistics, sys

out = sys.argv[1]
for path in sorted(glob.glob(os.path.join(out, "perf_*.csv"))):
    p95s, dcs, presets, knobs = [], [], set(), set()
    for line in open(path, encoding="utf-8", errors="replace"):
        fields = dict(
            token.split("=", 1) for token in line.split() if "=" in token)
        try:
            p95s.append(float(fields["p95"]))
            dcs.append(int(fields["dc"]))
            presets.add(fields.get("preset", "?"))
            knobs.add(int(fields.get("knob", 0)))
        except (KeyError, ValueError):
            continue
    name = os.path.basename(path)
    if not p95s:
        print("  %-28s NO PERF LINES — check the PRE-FLIGHT notes in this script"
              % name)
        continue
    print("  %-28s samples %3d  p95 mean %6.1f ms  p95 max %6.1f ms  "
          "peak dc %4d  preset %s  knobs %s"
          % (name, len(p95s), statistics.mean(p95s), max(p95s), max(dcs),
             "/".join(sorted(presets)), sorted(knobs)))
print("\n  Gates: doc 11 §7.4. framestats_*.txt carries the jank percentage,")
print("  meminfo_*.txt the PSS, thermal_soak.log the temperature rise.")
PY
echo
echo "  artefacts: $OUT_DIR"

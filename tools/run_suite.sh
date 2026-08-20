#!/usr/bin/env bash
# The suite, from any worktree, safely beside any number of siblings.
#
#   tools/run_suite.sh                     # everything (tests/run_tests.gd)
#   tools/run_suite.sh --one=test_foo.gd   # one file (tools/run_one_test.gd)
#   tools/run_suite.sh --keep              # leave the run's user:// behind
#
# **The isolation is not this script's doing.** `tests/user_dir_isolation.gd`
# moves `user://` to a per-process directory from inside `_initialize()`, and all
# three runners use it (`tests/run_tests.gd`, `tools/run_one_test.gd`,
# `tools/run_one.gd`), so a plain `godot --headless --path . -s
# res://tests/run_tests.gd` is already safe beside a sibling worktree. This
# wrapper exists for two smaller reasons:
#
#   1. Godot creates its user data directory once, at boot, BEFORE any script
#      runs — `~/.local/share/godot/app_userdata/Slacum City/`. Nothing writes
#      into it after the runner re-points `user://`, but the empty directory is
#      still made. Setting `XDG_DATA_HOME` here keeps even that out of a shared
#      home.
#   2. It is one line to type and it always resolves the right --path, which is
#      what actually stops an agent running the suite against the wrong tree.
#
# Exit code is the runner's, unchanged, so this is safe in CI.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"

ONE=""
KEEP=0
PASSTHROUGH=()
for arg in "$@"; do
	case "$arg" in
		--one=*) ONE="${arg#*=}" ;;
		--keep)  KEEP=1 ;;
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) PASSTHROUGH+=("$arg") ;;
	esac
done

# A private XDG root per invocation. The runner takes a per-PROCESS directory
# underneath whatever it finds here, so even two runs sharing this root cannot
# collide — see `tests/user_dir_isolation.gd`.
XDG_ROOT="${SLACUM_TEST_USER_DIR:-${TMPDIR:-/tmp}/slacum-suite}"
mkdir -p "$XDG_ROOT"
export XDG_DATA_HOME="$XDG_ROOT"
[[ $KEEP -eq 1 ]] && export SLACUM_TEST_KEEP_USER_DIR=1

# A `class_name` script is only global once the project has been imported, and a
# worktree that is fresh — or that gained a class since its last import —
# answers `Identifier "X" not declared in the current scope` instead of running
# the suite. CI has the same step for the same reason. The condition is exact
# rather than paranoid: import when the class cache is missing, or when any `.gd`
# under the source trees is newer than it. Warm, this costs one `find`.
CLASS_CACHE="$REPO_ROOT/.godot/global_script_class_cache.cfg"
NEEDS_IMPORT=0
if [[ ! -f "$CLASS_CACHE" ]]; then
	NEEDS_IMPORT=1
elif [[ -n "$(find "$REPO_ROOT/sim" "$REPO_ROOT/game" "$REPO_ROOT/ui" \
		"$REPO_ROOT/tests" "$REPO_ROOT/tools" -name '*.gd' -newer "$CLASS_CACHE" \
		-print -quit 2>/dev/null)" ]]; then
	NEEDS_IMPORT=1
fi
if [[ $NEEDS_IMPORT -eq 1 || -n "${SLACUM_FORCE_IMPORT:-}" ]]; then
	echo "run_suite: importing (registers class_name scripts)…"
	"$GODOT" --headless --path "$REPO_ROOT" --import >/dev/null 2>&1 || true
fi

if [[ -n "$ONE" ]]; then
	"$GODOT" --headless --path "$REPO_ROOT" -s res://tools/run_one_test.gd -- \
		--file="$ONE" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"
else
	"$GODOT" --headless --path "$REPO_ROOT" -s res://tests/run_tests.gd -- \
		"${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"
fi
exit $?

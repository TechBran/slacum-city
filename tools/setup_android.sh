#!/usr/bin/env bash
# Restore everything the Android Gradle build needs but that git does not carry
# (doc 13 §2.10). Run once after a fresh clone, and again after a Godot upgrade.
#
#   tools/setup_android.sh
#
# Two things are missing from a clone, both of them build inputs rather than
# source, and both reproducible from what IS committed:
#
#  1. android/build/libs/godot-lib.template_{debug,release}.aar — 215 MB of
#     engine, unzipped verbatim out of the installed export template. Each file
#     is over GitHub's 100 MB per-file hard limit, so it cannot be committed even
#     if we wanted to.
#  2. android/plugins/slacum_native.aar — built from the Kotlin sources beside it.
#
# Everything else under android/build/ IS committed, because with a custom
# template that directory is where our patches live (doc 13 §9 item 4).
#
# THE PATCH SET IS NOT EMPTY, and this script used to silently revert it. The
# unzip above is `-o`: it overwrites every committed file the template also
# carries. Measured 2026-08-20 against 4.7.2: of the 34 tracked files under
# android/build/ that the zip carries, 33 are byte-identical and exactly ONE is
# ours — `res/values/themes.xml`, which holds doc 13 §2's dark
# `android:windowBackground`. Running this script on a working clone therefore
# reverted the no-white-flash fix and the next debug build flashed white on
# launch. Every deviation now lives in tools/android_patches/*.patch and is
# REAPPLIED below, after the unzip and before the plugin build. Adding one is
# the whole procedure: cut a `diff -u` against the pristine template with
# `a/` `b/` prefixes, drop it in that directory, and this loop picks it up.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
BUILD_VERSION_FILE="$REPO_ROOT/android/.build_version"
TEMPLATE_ZIP_DIR="${GODOT_TEMPLATES:-$HOME/.local/share/godot/export_templates}"
PATCH_DIR="$REPO_ROOT/tools/android_patches"

export JAVA_HOME="${JAVA_HOME:-$HOME/.jdks/jdk-21.0.12+8}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"

if [[ ! -f "$BUILD_VERSION_FILE" ]]; then
	echo "error: $BUILD_VERSION_FILE is missing — this is not a Slacum checkout." >&2
	exit 1
fi
BUILD_VERSION="$(cat "$BUILD_VERSION_FILE")"
SOURCE_ZIP="$TEMPLATE_ZIP_DIR/$BUILD_VERSION/android_source.zip"

if [[ ! -f "$SOURCE_ZIP" ]]; then
	echo "error: no Android source template for $BUILD_VERSION at:" >&2
	echo "       $SOURCE_ZIP" >&2
	echo "       Install the $BUILD_VERSION export templates first." >&2
	exit 1
fi

# NOTE (verified on 4.7.2): `godot --headless --path . --install-android-build-template`
# does NOT install anything — the standalone tool is editor-only, so a headless
# run falls through to *running the project* and never returns. The manual
# equivalent below is the one doc 13 §2.10 documents, and it is what actually
# produces the tree the editor would have produced.
echo "Restoring the Godot $BUILD_VERSION build template into android/build/"
mkdir -p "$REPO_ROOT/android/build"
unzip -q -o "$SOURCE_ZIP" -d "$REPO_ROOT/android/build"

# Sanity: the two engine archives are the whole point of this step.
for variant in debug release; do
	lib="$REPO_ROOT/android/build/libs/$variant/godot-lib.template_$variant.aar"
	if [[ ! -f "$lib" ]]; then
		echo "error: $lib missing after unzip — the template zip looks wrong." >&2
		exit 1
	fi
done

# --------------------------------------------------------------- our patches
# Reapplied AFTER the unzip, because the unzip is what removes them.
#
# Idempotent by construction: a patch that already applies in REVERSE is already
# in the tree, so it is skipped rather than re-run (`patch --forward` alone would
# exit 1 and leave a .rej behind on the second run of this script). A patch that
# applies neither way is a hard stop — that is a Godot upgrade having moved the
# lines out from under it, and continuing would produce a build whose theme is
# nobody's intent.
apply_patch() {
	local patch_file="$1"
	local name
	name="$(basename "$patch_file")"
	if patch -p1 --reverse --dry-run --batch --force \
			-d "$REPO_ROOT/android/build" <"$patch_file" >/dev/null 2>&1; then
		echo "  already applied  $name"
		return 0
	fi
	if patch -p1 --forward --batch -d "$REPO_ROOT/android/build" <"$patch_file"; then
		echo "  applied          $name"
		return 0
	fi
	echo "error: $name did not apply to the $BUILD_VERSION template." >&2
	echo "       The template moved under it. Re-cut the patch against" >&2
	echo "       $SOURCE_ZIP rather than deleting it — it is a shipped" >&2
	echo "       behaviour (see the patch's own header for what and why)." >&2
	return 1
}

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
shopt -u nullglob
if [[ ${#patches[@]} -eq 0 ]]; then
	echo "No patches in tools/android_patches/ — the template is used verbatim."
else
	echo "Reapplying ${#patches[@]} local patch(es) over the template"
	for patch_file in "${patches[@]}"; do
		apply_patch "$patch_file"
	done
	# A --forward run that half-applied would leave these; a clean one never does.
	find "$REPO_ROOT/android/build" -name '*.rej' -o -name '*.orig' | while read -r stray; do
		echo "warning: leftover $stray" >&2
	done
fi

echo "Building the SlacumNative plugin"
"$REPO_ROOT/tools/build_native_plugin.sh"

cat <<EOF

Android build is ready. To produce the debug APK:

  "$GODOT" --headless --path "$REPO_ROOT" --export-debug "Android" "$REPO_ROOT/build/slacum-debug.apk"

For the signed release pair (AAB + APK), with the keystore env vars set:

  tools/make_release.sh                  # builds both, verifies both, prints hashes
  tools/make_release.sh --init-keystore  # once, to create the upload keystore

And for the Play listing assets (icon, feature graphic, screenshots):

  python3 tools/gen_store_assets.py
EOF

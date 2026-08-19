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
# template that directory is where our patches would live (doc 13 §9 item 4).
# The design goal is to keep that patch set empty; today it is, so this script
# can safely re-unzip the whole template. If a patch ever lands, it belongs in
# tools/android_patches/*.patch and must be reapplied here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
BUILD_VERSION_FILE="$REPO_ROOT/android/.build_version"
TEMPLATE_ZIP_DIR="${GODOT_TEMPLATES:-$HOME/.local/share/godot/export_templates}"

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

echo "Building the SlacumNative plugin"
"$REPO_ROOT/tools/build_native_plugin.sh"

cat <<EOF

Android build is ready. To produce the debug APK:

  "$GODOT" --headless --path "$REPO_ROOT" --export-debug "Android" "$REPO_ROOT/build/slacum-debug.apk"
EOF

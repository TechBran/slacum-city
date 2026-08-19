#!/usr/bin/env bash
# Build the SlacumNative AAR (doc 13 §2.6) and drop it next to its .gdap.
#
# The plugin has no Gradle wrapper of its own — it borrows the build template's,
# so there is exactly one Gradle version in the repo and it is the engine's.
# Run this after touching anything under android/plugins/slacum_native/src, and
# after reinstalling the build template (the AAR is compiled against the engine
# version recorded in android/.build_version).
#
#   tools/build_native_plugin.sh [--debug]
#
# Env: JAVA_HOME (defaults to the JDK doc 13 §2.0 pins), ANDROID_HOME.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/android/plugins/slacum_native"
TEMPLATE_DIR="$REPO_ROOT/android/build"
OUT_AAR="$REPO_ROOT/android/plugins/slacum_native.aar"

VARIANT="release"
GRADLE_TASK="assembleRelease"
if [[ "${1:-}" == "--debug" ]]; then
	VARIANT="debug"
	GRADLE_TASK="assembleDebug"
fi

export JAVA_HOME="${JAVA_HOME:-$HOME/.jdks/jdk-21.0.12+8}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"

if [[ ! -x "$TEMPLATE_DIR/gradlew" ]]; then
	echo "error: the Android build template is not installed." >&2
	echo "       godot --headless --path \"$REPO_ROOT\" --install-android-build-template" >&2
	exit 1
fi

# AGP resolves the SDK through local.properties or ANDROID_HOME; write the file
# so the plugin build works the same way from a shell and from an IDE. It is a
# machine-local path, hence gitignored.
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > "$PLUGIN_DIR/local.properties"

echo "Building SlacumNative ($VARIANT) against Godot $(cat "$REPO_ROOT/android/.build_version")"
"$TEMPLATE_DIR/gradlew" -p "$PLUGIN_DIR" "$GRADLE_TASK"

BUILT="$PLUGIN_DIR/build/outputs/aar/slacum_native.aar"
if [[ ! -f "$BUILT" ]]; then
	echo "error: expected $BUILT to exist after $GRADLE_TASK" >&2
	exit 1
fi

cp "$BUILT" "$OUT_AAR"
echo "wrote $OUT_AAR ($(du -h "$OUT_AAR" | cut -f1))"

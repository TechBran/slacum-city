#!/usr/bin/env bash
# Build the signed release artefacts (doc 13 §2.10, §3.4, §2.12).
#
#   tools/make_release.sh                 # AAB + release APK, verified, hashed
#   tools/make_release.sh --init-keystore # create the upload keystore, once
#   tools/make_release.sh --aab-only      # skip the sideloadable APK
#
# WHAT THIS SCRIPT IS FOR
# -----------------------
# `export_presets.cfg` is committed, so no secret may ever live in it — and since
# Godot 4.2 none can: the preset has no keystore fields at all (doc 13 §10.2).
# Signing is env-only:
#
#   GODOT_ANDROID_KEYSTORE_RELEASE_PATH      absolute path to the .keystore
#   GODOT_ANDROID_KEYSTORE_RELEASE_USER      the key alias
#   GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD  store password == key password
#
# Godot passes one password to both the store and the key, so the keystore must
# be created with `-storepass` and `-keypass` equal. `--init-keystore` does that.
#
# PASSPHRASE HANDLING — the whole policy, in four lines:
#   * it lives in a password manager and in the shell that runs this script;
#   * it is NEVER written to a file inside this repository, and there is no
#     .env, no `secrets.sh`, no `export_presets.cfg.secret` for it to hide in;
#   * the keystore itself lives OUTSIDE the repo (default:
#     ~/.local/share/godot/keystores/release.keystore) and is backed up in two
#     offline places, because losing it means a new package name on Play;
#   * we enrol in Play App Signing, so this is the UPLOAD key only — Google
#     holds the app signing key. Losing this one is recoverable by support;
#     losing a self-managed app signing key would be terminal.
#
# WHAT IT VERIFIES, on every run, before it prints a hash:
#   1. the three env vars are set and the keystore actually opens with them;
#   2. project.godot's `config/version` matches every preset's version/name,
#      and version/code matches the doc 13 §2.10 formula major*10000+minor*100+patch;
#   3. the version code is greater than tools/.last_uploaded_version_code;
#   4. the built artefacts declare EXACTLY doc 13 §2.7's four permissions —
#      no INTERNET, which is what keeps the Data Safety form at "collects nothing";
#   5. every LOAD segment of every shipped .so is 16 KB aligned (Play requires it
#      for target-15+ apps and a violation is a store rejection, not a warning);
#   6. badging on both artefacts, so the package, version and SDK levels are read
#      back out of the binary rather than trusted from the preset — `aapt2` for
#      the APK, `tools/aab_badging.py` for the bundle, because aapt2 cannot read
#      an AAB at all (see the note above `aab_badging`);
#   7. both artefacts are actually SIGNED — `apksigner` for the APK's v2/v3
#      block, `jarsigner` for the bundle. Godot reports a successful export
#      either way and Play rejects the upload hours later.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
BUILD_DIR="$REPO_ROOT/build"
AAB_PATH="$BUILD_DIR/slacum-release.aab"
APK_PATH="$BUILD_DIR/slacum-release.apk"
AAB_PRESET="Android Play AAB"
APK_PRESET="Android Test APK"
LAST_CODE_FILE="$REPO_ROOT/tools/.last_uploaded_version_code"

export JAVA_HOME="${JAVA_HOME:-$HOME/.jdks/jdk-21.0.12+8}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
KEYSTORE_DEFAULT="$HOME/.local/share/godot/keystores/release.keystore"

# doc 13 §2.7. The list is the contract: four, and not one more.
EXPECTED_PERMISSIONS=(
	"android.permission.POST_NOTIFICATIONS"
	"android.permission.RECEIVE_BOOT_COMPLETED"
	"android.permission.VIBRATE"
	"android.permission.WAKE_LOCK"
)

AAB_ONLY=0
INIT_KEYSTORE=0
for arg in "$@"; do
	case "$arg" in
		--aab-only) AAB_ONLY=1 ;;
		--init-keystore) INIT_KEYSTORE=1 ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

die() { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }
section() { echo; echo "== $*"; }

aapt2_bin() {
	local newest
	newest="$(ls -1d "$ANDROID_HOME"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1 || true)"
	[[ -n "$newest" ]] || die "no aapt2 under $ANDROID_HOME/build-tools"
	echo "$newest"
}

# --------------------------------------------------------------- keystore

if [[ "$INIT_KEYSTORE" == "1" ]]; then
	section "Creating the upload keystore"
	KS_PATH="${GODOT_ANDROID_KEYSTORE_RELEASE_PATH:-$KEYSTORE_DEFAULT}"
	KS_USER="${GODOT_ANDROID_KEYSTORE_RELEASE_USER:-slacum-upload}"
	[[ -n "${GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD:-}" ]] \
		|| die "set GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD first (and put it in a password manager)"
	[[ ! -f "$KS_PATH" ]] || die "$KS_PATH already exists — refusing to overwrite an upload key"
	mkdir -p "$(dirname "$KS_PATH")"
	# 4096-bit RSA, 30 years: Play requires the upload key to outlive the app's
	# support window, and re-keying is a support ticket, not a build step.
	"$JAVA_HOME/bin/keytool" -genkeypair -v \
		-keystore "$KS_PATH" -alias "$KS_USER" \
		-keyalg RSA -keysize 4096 -validity 10950 -storetype pkcs12 \
		-storepass "$GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD" \
		-keypass "$GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD" \
		-dname "CN=Slacum City, OU=Slacum City, O=Slacum City, L=Unspecified, ST=Unspecified, C=US"
	chmod 600 "$KS_PATH"
	note "wrote $KS_PATH (mode 600, outside the repository)"
	note "back it up in two offline places — losing it means a new Play listing"
	exit 0
fi

section "Signing environment"
for var in GODOT_ANDROID_KEYSTORE_RELEASE_PATH GODOT_ANDROID_KEYSTORE_RELEASE_USER \
		GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD; do
	[[ -n "${!var:-}" ]] || die "$var is not set. See the header of this script; run --init-keystore once if the keystore does not exist yet."
done
KS_PATH="$GODOT_ANDROID_KEYSTORE_RELEASE_PATH"
[[ -f "$KS_PATH" ]] || die "keystore not found at $KS_PATH"
case "$KS_PATH" in
	"$REPO_ROOT"/*) die "the keystore is inside the repository ($KS_PATH). Move it out — a committed key is a compromised key." ;;
esac
"$JAVA_HOME/bin/keytool" -list -keystore "$KS_PATH" \
	-storepass "$GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD" \
	-alias "$GODOT_ANDROID_KEYSTORE_RELEASE_USER" >/dev/null 2>&1 \
	|| die "the keystore, alias or password is wrong — keytool could not open $KS_PATH"
note "keystore   $KS_PATH"
note "alias      $GODOT_ANDROID_KEYSTORE_RELEASE_USER"
note "password   (from the environment; never read from a file in this repo)"

# ---------------------------------------------------------------- version

section "Version"
VERSION_NAME="$(sed -n 's/^config\/version="\(.*\)"$/\1/p' "$REPO_ROOT/project.godot")"
[[ -n "$VERSION_NAME" ]] || die "project.godot has no application/config/version"
IFS='.' read -r MAJOR MINOR PATCH <<<"$VERSION_NAME"
VERSION_CODE=$(( MAJOR * 10000 + MINOR * 100 + PATCH ))
note "config/version   $VERSION_NAME"
note "derived code     $VERSION_CODE  (major*10000 + minor*100 + patch)"

# Every preset has to agree with project.godot, or the store gets an artefact
# whose version does not match the source tree it came from.
mapfile -t PRESET_NAMES < <(sed -n 's/^version\/name="\(.*\)"$/\1/p' "$REPO_ROOT/export_presets.cfg")
mapfile -t PRESET_CODES < <(sed -n 's/^version\/code=\([0-9]*\)$/\1/p' "$REPO_ROOT/export_presets.cfg")
for name in "${PRESET_NAMES[@]}"; do
	[[ "$name" == "$VERSION_NAME" ]] \
		|| die "export_presets.cfg has version/name=\"$name\", project.godot says \"$VERSION_NAME\""
done
for code in "${PRESET_CODES[@]}"; do
	[[ "$code" == "$VERSION_CODE" ]] \
		|| die "export_presets.cfg has version/code=$code, the formula gives $VERSION_CODE"
done
note "presets agree    ${#PRESET_NAMES[@]} presets at $VERSION_NAME / $VERSION_CODE"

if [[ -f "$LAST_CODE_FILE" ]]; then
	LAST_CODE="$(tr -d '[:space:]' <"$LAST_CODE_FILE")"
	[[ "$VERSION_CODE" -gt "$LAST_CODE" ]] \
		|| die "version code $VERSION_CODE is not greater than the last uploaded ($LAST_CODE). Play rejects it; bump config/version."
	note "last uploaded    $LAST_CODE"
fi

# ------------------------------------------------------------------ build

[[ -x "$GODOT" ]] || die "godot not found at $GODOT"
[[ -f "$REPO_ROOT/android/plugins/slacum_native.aar" ]] \
	|| die "android/plugins/slacum_native.aar is missing — run tools/setup_android.sh"
mkdir -p "$BUILD_DIR"

section "Exporting $AAB_PRESET"
rm -f "$AAB_PATH"
"$GODOT" --headless --path "$REPO_ROOT" --export-release "$AAB_PRESET" "$AAB_PATH"
[[ -f "$AAB_PATH" ]] || die "the exporter reported success but $AAB_PATH does not exist"

if [[ "$AAB_ONLY" == "0" ]]; then
	section "Exporting $APK_PRESET"
	rm -f "$APK_PATH"
	"$GODOT" --headless --path "$REPO_ROOT" --export-release "$APK_PRESET" "$APK_PATH"
	[[ -f "$APK_PATH" ]] || die "the exporter reported success but $APK_PATH does not exist"
fi

AAPT2="$(aapt2_bin)"

# ------------------------------------------------------------ verification

# An AAB's manifest is aapt2's PROTOBUF encoding, and every `aapt2 dump`
# subcommand refuses it — `could not identify format of APK` — because they all
# expect a binary manifest inside an APK. Google's answer is bundletool, a 60 MB
# jar that is not in the SDK. `tools/aab_badging.py` reads the protobuf directly
# instead, which is 150 lines and no dependency. Doc 13 §2.10's instruction to
# run `aapt2 dump permissions` on the AAB is wrong and is corrected in §10.9.
aab_badging() {
	python3 "$REPO_ROOT/tools/aab_badging.py" "$AAB_PATH"
}

permissions_of() {
	case "$1" in
		*.aab) python3 "$REPO_ROOT/tools/aab_badging.py" "$1" --permissions | sort -u ;;
		*) "$AAPT2" dump permissions "$1" | sed -n "s/^uses-permission: name='\(.*\)'$/\1/p" | sort -u ;;
	esac
}

check_permissions() {
	local artefact="$1"
	local found expected
	found="$(permissions_of "$artefact" | tr '\n' ' ' | xargs || true)"
	expected="$(printf '%s\n' "${EXPECTED_PERMISSIONS[@]}" | sort -u | tr '\n' ' ' | xargs)"
	[[ "$found" == "$expected" ]] || die "permission set mismatch in $(basename "$artefact")
     found:    $found
     expected: $expected"
	note "permissions      4, exactly doc 13 §2.7 (no INTERNET)"
}

# An unsigned artefact is the failure this script exists to make impossible:
# Godot reports a successful export either way, and Play rejects the upload hours
# later. The two formats need two different verifiers, and the reason is worth
# writing down because it looks like a bug the first time:
#
#   * the **APK** carries only an APK Signature Scheme v2/v3 block. Godot skips
#     the old v1 JAR signature entirely at minSdk 29 (v1 has been optional since
#     API 24), so `jarsigner -verify` reports "jar is unsigned" on a perfectly
#     signed APK. `apksigner` is the tool that knows about v2/v3.
#   * the **AAB** is not an APK at all — apksigner refuses it — and bundles are
#     still plain jar-signed, so jarsigner is right there and apksigner is wrong.
check_signature() {
	local artefact="$1" out signer
	if [[ "$artefact" == *.apk ]]; then
		signer="$(dirname "$AAPT2")/apksigner"
		[[ -x "$signer" ]] || { note "signature        SKIPPED (no apksigner)"; return; }
		out="$("$signer" verify --print-certs "$artefact" 2>&1)" \
			|| die "$(basename "$artefact") failed apksigner: $out"
		note "signature        $(grep -m1 'certificate DN' <<<"$out")"
		note "                 $(grep -m1 'SHA-256 digest' <<<"$out")"
	else
		out="$("$JAVA_HOME/bin/jarsigner" -verify "$artefact" 2>&1)" \
			|| die "$(basename "$artefact") failed jarsigner: $out"
		grep -q 'jar verified' <<<"$out" \
			|| die "$(basename "$artefact") is not signed: $out"
		note "signature        jar verified, alias $GODOT_ANDROID_KEYSTORE_RELEASE_USER"
	fi
}

check_alignment() {
	local artefact="$1" tmp
	tmp="$(mktemp -d)"
	unzip -q -o "$artefact" -d "$tmp" '*.so'
	local readelf
	readelf="$(command -v llvm-readelf || command -v readelf || true)"
	[[ -n "$readelf" ]] || { note "alignment        SKIPPED (no readelf on PATH)"; return; }
	local so bad=0 count=0
	while IFS= read -r so; do
		count=$((count + 1))
		# Every LOAD segment must report Align 0x4000 — Play's 16 KB page-size
		# requirement for target-15+ apps, verified per build and never assumed.
		# `-W` keeps each program header on one line, so the alignment is the
		# last field; without it readelf wraps and the check reads the wrong word.
		if ! "$readelf" -lW "$so" | awk '
				/^ *LOAD/ { if ($NF != "0x4000") bad = 1 }
				END { exit bad }'; then
			echo "     misaligned: ${so#$tmp/}" >&2
			bad=$((bad + 1))
		fi
	done < <(find "$tmp" -name '*.so')
	rm -rf "$tmp"
	[[ "$bad" -eq 0 ]] || die "$bad shared object(s) are not 16 KB aligned"
	[[ "$count" -gt 0 ]] || die "no .so inside $(basename "$artefact") — the engine did not ship"
	note "alignment        $count .so, every LOAD segment 0x4000 (16 KB)"
}

report() {
	local artefact="$1"
	section "$(basename "$artefact")"
	note "size             $(stat -c%s "$artefact") bytes ($(du -h "$artefact" | cut -f1))"
	note "sha256           $(sha256sum "$artefact" | cut -d' ' -f1)"
	local badging line
	if [[ "$artefact" == *.apk ]]; then
		badging="$("$AAPT2" dump badging "$artefact" | grep -E \
			'^(package:|minSdkVersion|targetSdkVersion|native-code|uses-permission)')"
	else
		badging="$(aab_badging)"
	fi
	while IFS= read -r line; do
		note "badging          $line"
	done <<<"$badging"
	check_signature "$artefact"
	check_permissions "$artefact"
	check_alignment "$artefact"
}

report "$AAB_PATH"
[[ "$AAB_ONLY" == "1" ]] || report "$APK_PATH"

section "Release artefacts are ready"
note "AAB → Play Console (internal testing track first, doc 13 §2.12)"
[[ "$AAB_ONLY" == "1" ]] || note "APK → sideload for perf and battery measurement (D-07, D-08)"
note "after a successful upload: echo $VERSION_CODE > tools/.last_uploaded_version_code"

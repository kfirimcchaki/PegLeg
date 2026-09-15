#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# PegLeg - Android APK builder
#
# Builds a signed, installable Android APK from this repository (Godot 4.7
# .NET project, Gradle export). Everything the build needs that is too large
# for the repository (Godot .NET editor, .NET export templates, Android
# SDK/NDK, Gradle dependencies) is downloaded on the fly and cached under
# $HOME, so repeated runs are fast.
#
# Intended to be run either
#   * in CI (GitHub Actions) - .github/workflows/android-apk.yml calls it, or
#   * locally  (Linux / macOS / WSL2) - ./ci/build-android-apk.sh
#
# Optional environment variables:
#   GODOT_TAG       Godot release tag                    (default 4.7.2-stable)
#   GODOT_PRESET    Godot export preset name             (default "Android (Test)")
#   EXPORT_MODE     release | debug                      (default release)
#   OUTPUT_APK      Output path inside the repository    (default Builds/Android/Beta/PegLegBeta-Android.apk)
#   TARGET_SDK      Android platform to compile against (default 36)
#   TARGET_BUILD_TOOLS                        (default 36.1.0)
#   TARGET_NDK                                (default 29.0.14206865)
#   ANDROID_HOME / ANDROID_SDK_ROOT           (auto-detected when unset)
#   JAVA_HOME                                 (auto-detected when unset)
#   GH_TOKEN + GITHUB_REPOSITORY              (when set, the APK is attached to a release)
#
# Requirements: bash, curl, unzip, JDK 17 (JAVA_HOME), .NET SDK 10, git.
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

GODOT_TAG="${GODOT_TAG:-4.7.2-stable}"
GODOT_PRESET="${GODOT_PRESET:-Android (Test)}"
EXPORT_MODE="${EXPORT_MODE:-release}"
TARGET_SDK="${TARGET_SDK:-36}"
TARGET_BUILD_TOOLS="${TARGET_BUILD_TOOLS:-36.1.0}"
TARGET_NDK="${TARGET_NDK:-29.0.14206865}"
OUTPUT_APK="${OUTPUT_APK:-Builds/Android/Beta/PegLegBeta-Android.apk}"

# Godot's VERSION_FULL_CONFIG for a .NET build is "<version>.<status>.mono"
GODOT_VER="${GODOT_TAG%*-stable}.stable.mono"
EDITOR_DIR="${HOME}/godot-editor"
EDITOR_BIN="${EDITOR_DIR}/Godot_v${GODOT_TAG}_mono_linux.x86_64"
TEMPLATES_DIR="${HOME}/.local/share/godot/export_templates/${GODOT_VER}"
KEYSTORE="${KEYSTORE:-${HOME}/.android/pepleg-ci.jks}"
KEYSTORE_PASS="${KEYSTORE_PASS:-pepleg-ci}"
DOWNLOAD_DIR="${HOME}/godot-downloads"
APK_ABS="${PROJECT_DIR}/${OUTPUT_APK}"
REPORT="${PROJECT_DIR}/build-report.md"

LOG_SUMMARY=()

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# Publish a variable to later CI steps when running under GitHub Actions.
set_env() {
  if [ -n "${GITHUB_ENV:-}" ] && [ -w "${GITHUB_ENV}" ]; then
    echo "$1" >> "$GITHUB_ENV"
  fi
  export "$1"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
log "Environment"
# ---------------------------------------------------------------------------
mkdir -p "$EDITOR_DIR" "$DOWNLOAD_DIR" "$TEMPLATES_DIR"

# JDK: Godot needs JAVA_HOME (for keytool and Gradle)
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME}/bin/keytool" ]; then
  if have java; then
    JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
  fi
fi
[ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/keytool" ] \
  || die "A JDK is required (keytool not found). Install JDK 17 and export JAVA_HOME."
set_env "JAVA_HOME=${JAVA_HOME}"
info "JAVA_HOME  = ${JAVA_HOME}"
"${JAVA_HOME}/bin/java" -version 2>&1 | sed 's/^/    /'

have dotnet || die ".NET SDK 10 is required, but 'dotnet' was not found in PATH."
info "dotnet SDKs:"
dotnet --list-sdks | sed 's/^/    /'
DOTNET_MAJOR="$(dotnet --version | cut -d. -f1)"
[ "${DOTNET_MAJOR:-0}" -ge 9 ] || warn "Godot 4.7 .NET exports expect .NET 9 or newer (found $(dotnet --version))."

# ---------------------------------------------------------------------------
log "Android SDK ($TARGET_SDK / build-tools $TARGET_BUILD_TOOLS / NDK $TARGET_NDK)"
# ---------------------------------------------------------------------------
if [ -z "${ANDROID_HOME:-}" ]; then
  for candidate in "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk" "$HOME/Library/Android/sdk" /usr/local/lib/android/sdk /opt/android-sdk; do
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then ANDROID_HOME="$candidate"; break; fi
  done
fi

SDKMANAGER=""
if [ -n "${ANDROID_HOME:-}" ]; then
  SDKMANAGER="$(find "$ANDROID_HOME" -maxdepth 4 -name sdkmanager -type f 2>/dev/null | head -n1 || true)"
fi

if [ -z "$SDKMANAGER" ]; then
  warn "sdkmanager not found - downloading Android command line tools into \$HOME/android-cmdline-tools"
  mkdir -p "$HOME/android-cmdline-tools"
  curl -fL --retry 3 -o /tmp/cmdline-tools.zip \
    "https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip" \
    || die "Could not download the Android command line tools (no network access?)."
  rm -rf "$HOME/android-cmdline-tools/cmdline-tools" "$HOME/android-cmdline-tools/latest"
  unzip -q -o /tmp/cmdline-tools.zip -d "$HOME/android-cmdline-tools"
  mv "$HOME/android-cmdline-tools/cmdline-tools" "$HOME/android-cmdline-tools/latest"
  SDKMANAGER="$HOME/android-cmdline-tools/latest/bin/sdkmanager"
  export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
  mkdir -p "$ANDROID_HOME"
fi

export ANDROID_HOME
export ANDROID_SDK_ROOT="${ANDROID_HOME}"
set_env "ANDROID_HOME=${ANDROID_HOME}"
set_env "ANDROID_SDK_ROOT=${ANDROID_HOME}"
info "ANDROID_HOME = ${ANDROID_HOME}"
info "sdkmanager   = ${SDKMANAGER}"

# On CI runners the image ships emulator images and several NDKs we never use;
# disk space is the tightest resource of an Android build.
if [ -n "${CI:-}" ]; then
  sudo -n rm -rf "${ANDROID_HOME}/emulator" "${ANDROID_HOME}/system-images" \
                 "${ANDROID_HOME}/ndk" "${ANDROID_HOME}/sources" 2>/dev/null || true
fi
df -h "$PROJECT_DIR" "$HOME" | sed 's/^/    /' || true

yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
"$SDKMANAGER" --install \
  "platform-tools" \
  "platforms;android-${TARGET_SDK}" \
  "build-tools;${TARGET_BUILD_TOOLS}" \
  "ndk;${TARGET_NDK}" 2>&1 | tail -n 15
BUILD_TOOLS_DIR="${ANDROID_HOME}/build-tools/${TARGET_BUILD_TOOLS}"
[ -d "$BUILD_TOOLS_DIR" ] || BUILD_TOOLS_DIR="$(ls -d "${ANDROID_HOME}"/build-tools/*/ 2>/dev/null | sort -V | tail -n1)"
[ -n "$BUILD_TOOLS_DIR" ] || die "Android build-tools are missing - sdkmanager install failed."
info "build-tools  = ${BUILD_TOOLS_DIR}"

# ---------------------------------------------------------------------------
log "Godot .NET editor $GODOT_TAG + export templates"
# ---------------------------------------------------------------------------
EDITOR_ZIP="${DOWNLOAD_DIR}/Godot_v${GODOT_TAG}_mono_linux_x86_64.zip"
TEMPLATES_TPZ="${DOWNLOAD_DIR}/Godot_v${GODOT_TAG}_mono_export_templates.tpz"

if [ ! -f "$EDITOR_ZIP" ]; then
  curl -fL --retry 3 -o "$EDITOR_ZIP" \
    "https://github.com/godotengine/godot/releases/download/${GODOT_TAG}/Godot_v${GODOT_TAG}_mono_linux_x86_64.zip" \
    || die "Could not download the Godot .NET editor (no network access?)."
fi

if [ ! -x "$EDITOR_BIN" ]; then
  unzip -q -o "$EDITOR_ZIP" -d "$EDITOR_DIR"
  # The GodotSharp folder must sit next to the binary: the C# build needs it.
  [ -d "${EDITOR_DIR}/Godot_v${GODOT_TAG}_mono_linux_x86_64" ] && \
    cp -r "${EDITOR_DIR}/Godot_v${GODOT_TAG}_mono_linux_x86_64/." "$EDITOR_DIR/"
  chmod +x "$EDITOR_BIN"
fi
info "editor       = $("$EDITOR_BIN" --headless --version 2>/dev/null | tail -n1 || echo '(failed to run!)')"

# Only the Android pieces of the template pack are needed (~3 GB of runner disk saved).
if [ ! -f "${TEMPLATES_DIR}/android_release.apk" ] || [ ! -f "${TEMPLATES_DIR}/android_source.zip" ]; then
  if [ ! -f "$TEMPLATES_TPZ" ]; then
    curl -fL --retry 3 -o "$TEMPLATES_TPZ" \
      "https://github.com/godotengine/godot/releases/download/${GODOT_TAG}/Godot_v${GODOT_TAG}_mono_export_templates.tpz" \
      || die "Could not download the Godot export templates (no network access?)."
  fi
  unzip -q -o -j "$TEMPLATES_TPZ" \
    "templates/android_debug.apk" \
    "templates/android_release.apk" \
    "templates/android_source.zip" \
    "templates/version.txt" \
    -d "$TEMPLATES_DIR"
fi
info "templates    = ${TEMPLATES_DIR}"
ls -la "$TEMPLATES_DIR" | sed 's/^/    /'

# ---------------------------------------------------------------------------
log "Install Android build template (res://android/build)"
# ---------------------------------------------------------------------------
# This mirrors the editor's "Project > Install Android Build Template" action,
# which is interactive only. The build directory is gitignored on purpose.
rm -rf "${PROJECT_DIR}/android"
mkdir -p "${PROJECT_DIR}/android/build"
: > "${PROJECT_DIR}/android/build/.gdignore"
echo "${GODOT_VER}" > "${PROJECT_DIR}/android/.build_version"
unzip -q -o "${TEMPLATES_DIR}/android_source.zip" -d "${PROJECT_DIR}/android/build"
chmod +x "${PROJECT_DIR}/android/build/gradlew"
[ -f "${PROJECT_DIR}/android/build/build.gradle" ] || die "Android build template extraction failed."
info "build template identifier: ${GODOT_VER}"

# ---------------------------------------------------------------------------
log "Keystore"
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$KEYSTORE")"
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkeypair -v \
    -keystore "$KEYSTORE" -storepass "$KEYSTORE_PASS" -keypass "$KEYSTORE_PASS" \
    -alias pepleg -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=PegLeg CI, OU=PegLeg, O=PegLeg, L=Unknown, ST=Unknown, C=US" 2>&1 | tail -n 2
fi
# Godot reads these for both debug and release Android exports.
set_env "GODOT_ANDROID_KEYSTORE_DEBUG_PATH=${KEYSTORE}"
set_env "GODOT_ANDROID_KEYSTORE_DEBUG_USER=pepleg-ci"
set_env "GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD=${KEYSTORE_PASS}"
set_env "GODOT_ANDROID_KEYSTORE_RELEASE_PATH=${KEYSTORE}"
set_env "GODOT_ANDROID_KEYSTORE_RELEASE_USER=pepleg-ci"
set_env "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD=${KEYSTORE_PASS}"
info "keystore     = ${KEYSTORE}"

# ---------------------------------------------------------------------------
log "Compile check (C#, android platform)"
# ---------------------------------------------------------------------------
# No .NET workload is needed: Godot's Android export publishes for the
# linux-bionic-arm64 runtime identifier, whose runtime pack comes from NuGet.
if ! dotnet build PegLegGD.csproj -c ExportRelease -p:GodotTargetPlatform=android \
      2>&1 | tee "${PROJECT_DIR}/compile-check.log" | tail -n 40; then
  warn "The C# compile check failed - see compile-check.log"
fi

# ---------------------------------------------------------------------------
log "Import project resources"
# ---------------------------------------------------------------------------
"$EDITOR_BIN" --headless --path "$PROJECT_DIR" --import 2>&1 | tee "${PROJECT_DIR}/import.log" | tail -n 25 || true
grep -E "ERROR|SCRIPT ERROR" "${PROJECT_DIR}/import.log" | tail -n 15 || true

# ---------------------------------------------------------------------------
log "Export APK"
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$APK_ABS")"
rm -f "$APK_ABS"
EXPORT_ATTEMPT="none"

run_export() { # $1 = label, $2 = release|debug
  local label="$1" mode="$2"
  info "attempt '${label}': godot --export-${mode} \"${GODOT_PRESET}\""
  set +e
  "$EDITOR_BIN" --headless --verbose --path "$PROJECT_DIR" \
    "--export-${mode}" "$GODOT_PRESET" "$APK_ABS" 2>&1 \
    | tee "${PROJECT_DIR}/export-${label}.log" | tail -n 80
  local rc="${PIPESTATUS[0]}"
  set -e
  info "exit code: ${rc}"
  if [ -f "$APK_ABS" ]; then
    EXPORT_ATTEMPT="$label"
    return 0
  fi
  return 1
}

if [ "$EXPORT_MODE" = "debug" ]; then
  run_export "preset-as-is" debug || true
else
  run_export "preset-as-is" release || true
fi

if [ ! -f "$APK_ABS" ]; then
  # Some .NET SDK installs only resolve the "linux-bionic" runtime identifier.
  warn "First export attempt failed - retrying with the linux-bionic runtime identifier"
  sed -i -E 's|^dotnet/android_use_linux_bionic=.*|dotnet/android_use_linux_bionic=true|' export_presets.cfg
  if [ "$EXPORT_MODE" = "debug" ]; then
    run_export "linux-bionic" debug || true
  else
    run_export "linux-bionic" release || true
  fi
fi

if [ ! -f "$APK_ABS" ]; then
  warn "Release export failed - retrying as a debug export"
  run_export "debug-fallback" debug || true
fi

if [ ! -f "$APK_ABS" ]; then
  printf '\n\033[1;31mExport failed.\033[0m Last lines of the export log:\n'
  tail -n 40 "${PROJECT_DIR}"/export-*.log 2>/dev/null | sed 's/%/%25/g; s/\r//g' | while IFS= read -r line; do
    echo "::error ::${line}" || true
  done
  exit 1
fi
info "APK produced by attempt: ${EXPORT_ATTEMPT}"

# ---------------------------------------------------------------------------
log "Verify APK"
# ---------------------------------------------------------------------------
VERIFY=()
if have apksigner; then SIGNER="$(command -v apksigner)"; else SIGNER="${BUILD_TOOLS_DIR%/}/apksigner"; fi
if [ -x "$SIGNER" ]; then
  VERIFY+=("$("$SIGNER" verify --verbose --print-certs "$APK_ABS" 2>&1 | head -n 20)")
else
  VERIFY+=("apksigner not available")
fi
if [ -x "${BUILD_TOOLS_DIR%/}/aapt2" ]; then
  VERIFY+=("$("${BUILD_TOOLS_DIR%/}/aapt2" dump badging "$APK_ABS" 2>&1 | head -n 6)")
else
  VERIFY+=("aapt2 not available")
fi
VERIFY+=("native libraries: $(unzip -l "$APK_ABS" | awk '{print $4}' | grep -c '^lib/') files")
VERIFY+=("$(unzip -l "$APK_ABS" | awk '{print $4}' | grep '^lib/' | sed 's|lib/||; s|/.*||' | sort -u | tr '\n' ' ')ABI(s)")
APK_SIZE="$(stat -c%s "$APK_ABS" 2>/dev/null || stat -f%z "$APK_ABS")"
APK_SHA="$(sha256sum "$APK_ABS" | cut -d' ' -f1)"

printf '%s\n' "${VERIFY[@]}" | sed 's/^/    /'

# ---------------------------------------------------------------------------
log "Build report"
# ---------------------------------------------------------------------------
{
  echo "## PegLeg Android APK"
  echo
  echo "- Commit: \`$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)\` (${GITHUB_REF_NAME:-local build})"
  echo "- Godot \`${GODOT_TAG}\` (.NET), preset \`${GODOT_PRESET}\`, mode \`${EXPORT_MODE}\`"
  echo "- Export attempt used: \`${EXPORT_ATTEMPT}\`"
  echo "- APK: \`${OUTPUT_APK}\` - $(( APK_SIZE / 1048576 )) MB"
  echo "- SHA-256: \`${APK_SHA}\`"
  echo
  echo '```'
  printf '%s\n' "${VERIFY[@]}"
  echo '```'
} > "$REPORT"
cat "$REPORT"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"; fi

# ---------------------------------------------------------------------------
log "Publish release"
# ---------------------------------------------------------------------------
if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && have gh; then
  tag="android-$(echo "${GITHUB_REF_NAME:-build}" | tr '/' '-')"
  title="PegLeg Android APK (${GITHUB_REF_NAME:-local})"
  if gh release view "$tag" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    gh release edit "$tag" -R "$GITHUB_REPOSITORY" --title "$title" --notes-file "$REPORT" \
      && (cd "$PROJECT_DIR" && gh release upload "$tag" -R "$GITHUB_REPOSITORY" "$OUTPUT_APK" --clobber)
  else
    (cd "$PROJECT_DIR" && gh release create "$tag" -R "$GITHUB_REPOSITORY" --title "$title" \
      --target "$(git -C "$PROJECT_DIR" rev-parse HEAD)" --notes-file "$REPORT" --prerelease "$OUTPUT_APK")
  fi
  info "download: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/releases/tag/${tag}"
else
  info "GH_TOKEN/GITHUB_REPOSITORY not set - skipping release upload (the APK is still at ${OUTPUT_APK})."
fi

printf '\n\033[1;32mDone: %s (%s bytes, sha256 %s)\033[0m\n' "$OUTPUT_APK" "$APK_SIZE" "$APK_SHA"

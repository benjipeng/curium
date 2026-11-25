#!/usr/bin/env bash
# Build, verify, ad-hoc sign, and package the Curium Swift iOS IPA against the
# prebuilt Chromium Blink engine pinned in Kernel.lock.
#
# Shared by local developer builds and GitHub Actions (.github/workflows/build-curium.yml).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OUTPUT_DIR="$REPO_ROOT/dist"
OUTPUT_IPA=""
CONFIGURATION="Release"
XCODE_APP_OVERRIDE=""
LOCAL_ENGINE_IPA=""
RELEASE_TAG=""
IPA_CACHE_DIR=""
SKIP_SYNC=0
SKIP_SIGN=0
REQUIRED_SDK="27.2"

usage() {
  cat <<'EOF'
Usage: scripts/build_curium_ipa.sh [options]

Options:
  --output-dir <dir>       Output directory for IPA and .sha256 (default: dist/)
  --output-ipa <path>      Explicit output IPA file path (overrides --output-dir filename)
  --configuration <cfg>    Xcode build configuration: Release or Debug (default: Release)
  --xcode <path>           Path to Xcode.app (default: /Applications/Xcode_27.2.app if present, else active Xcode)
  --ipa <path>             Local Chromium engine IPA to assemble via sync_curium_engine.py
  --release-tag <tag>      Download pinned Chromium engine IPA from this GitHub Release tag
  --ipa-cache <dir>        Cache directory for the verified engine IPA download
  --skip-sync              Skip engine sync if Vendor/CuriumEngine is already ready
  --skip-sign              Leave the IPA unsigned instead of ad-hoc signing inside-out
  -h, --help               Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir)    OUTPUT_DIR="${2:?missing path}"; shift 2 ;;
    --output-ipa)    OUTPUT_IPA="${2:?missing path}"; shift 2 ;;
    --configuration) CONFIGURATION="${2:?missing configuration}"; shift 2 ;;
    --xcode)         XCODE_APP_OVERRIDE="${2:?missing Xcode path}"; shift 2 ;;
    --ipa)           LOCAL_ENGINE_IPA="${2:?missing IPA path}"; shift 2 ;;
    --release-tag)   RELEASE_TAG="${2:?missing tag}"; shift 2 ;;
    --ipa-cache)     IPA_CACHE_DIR="${2:?missing cache dir}"; shift 2 ;;
    --skip-sync)     SKIP_SYNC=1; shift ;;
    --skip-sign)     SKIP_SIGN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Never let an ambient macOS SDKROOT hijack iOS xcodebuild invocations.
unset SDKROOT

select_xcode() {
  if [ -n "$XCODE_APP_OVERRIDE" ]; then
    [ -d "$XCODE_APP_OVERRIDE/Contents/Developer" ] || {
      echo "error: Xcode not found at $XCODE_APP_OVERRIDE" >&2
      exit 1
    }
    export DEVELOPER_DIR="$XCODE_APP_OVERRIDE/Contents/Developer"
  elif [ -d "/Applications/Xcode_${REQUIRED_SDK}.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode_${REQUIRED_SDK}.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi

  local ios_sdk
  ios_sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
  echo "==> Xcode: $(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
  echo "==> DEVELOPER_DIR: $DEVELOPER_DIR (iPhoneOS SDK $ios_sdk)"
  if [ "$ios_sdk" != "$REQUIRED_SDK" ]; then
    echo "error: Curium requires iPhoneOS SDK $REQUIRED_SDK (found $ios_sdk)" >&2
    exit 1
  fi
}

read_xcconfig_var() {
  local key="$1"
  awk -F'=' -v k="$key" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      val = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      print val
      exit
    }
  ' "$REPO_ROOT/Version.xcconfig"
}

read_lock_var() {
  local key="$1"
  awk -F'=' -v k="$key" '
    $0 ~ "^[[:space:]]*" k "=" {
      sub(/^[^=]*=/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ' "$REPO_ROOT/Kernel.lock"
}

select_xcode

MARKETING_VERSION="$(read_xcconfig_var MARKETING_VERSION)"
BUILD_NUMBER="$(read_xcconfig_var CURRENT_PROJECT_VERSION)"
BUNDLE_ID="$(read_xcconfig_var PRODUCT_BUNDLE_IDENTIFIER)"
KERNEL_BUILD="$(read_lock_var KERNEL_BUILD)"
KERNEL_CHROMIUM_VERSION="$(read_lock_var KERNEL_CHROMIUM_VERSION)"
KERNEL_COMMIT="$(read_lock_var KERNEL_COMMIT)"
KERNEL_RUN_ID="$(read_lock_var KERNEL_RUN_ID)"
KERNEL_IPA_SHA256="$(read_lock_var KERNEL_IPA_SHA256)"

[ -n "$MARKETING_VERSION" ] || { echo "error: missing MARKETING_VERSION in Version.xcconfig" >&2; exit 1; }
[ -n "$BUILD_NUMBER" ] || { echo "error: missing CURRENT_PROJECT_VERSION in Version.xcconfig" >&2; exit 1; }
[ -n "$KERNEL_BUILD" ] || { echo "error: missing KERNEL_BUILD in Kernel.lock" >&2; exit 1; }

echo "==> Target: Curium ${MARKETING_VERSION} (app build ${BUILD_NUMBER}) [${BUNDLE_ID}]"
echo "==> Pinned kernel: Kernel ${KERNEL_BUILD} · Chromium ${KERNEL_CHROMIUM_VERSION} (commit ${KERNEL_COMMIT:0:7}, CI run ${KERNEL_RUN_ID})"

# 1. Ensure Vendor/CuriumEngine matches Kernel.lock.
if [ "$SKIP_SYNC" -eq 0 ]; then
  if [ -n "$LOCAL_ENGINE_IPA" ]; then
    echo "==> Assembling Vendor/CuriumEngine from local IPA: $LOCAL_ENGINE_IPA"
    python3 "$REPO_ROOT/scripts/sync_curium_engine.py" --ipa "$LOCAL_ENGINE_IPA"
  elif python3 "$REPO_ROOT/scripts/sync_curium_engine.py" --status >/dev/null 2>&1; then
    echo "==> Vendor/CuriumEngine already matches Kernel.lock"
    python3 "$REPO_ROOT/scripts/sync_curium_engine.py" --status
  else
    echo "==> Syncing Vendor/CuriumEngine from Kernel.lock"
    sync_args=()
    [ -n "$RELEASE_TAG" ] && sync_args+=(--release-tag "$RELEASE_TAG")
    [ -n "$IPA_CACHE_DIR" ] && sync_args+=(--ipa-cache "$IPA_CACHE_DIR")
    python3 "$REPO_ROOT/scripts/sync_curium_engine.py" ${sync_args[@]+"${sync_args[@]}"}
  fi
else
  python3 "$REPO_ROOT/scripts/sync_curium_engine.py" --status
fi

# 2. Build Curium.app for iPhoneOS arm64 (unsigned; we sign inside-out below).
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/curium-build.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

DERIVED_DATA="$WORK_DIR/DerivedData"
echo "==> Building Curium.xcodeproj ($CONFIGURATION / iphoneos / arm64)..."
xcodebuild \
  -project "$REPO_ROOT/Curium.xcodeproj" \
  -scheme Curium \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 \
  CURIUM_USE_ENGINE_XCFRAMEWORK=YES \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos/Curium.app"
[ -d "$BUILT_APP" ] || { echo "error: built bundle missing at $BUILT_APP" >&2; exit 1; }

STAGE_DIR="$WORK_DIR/stage"
APP_BUNDLE="$STAGE_DIR/Payload/Curium.app"
mkdir -p "$STAGE_DIR/Payload"
ditto "$BUILT_APP" "$APP_BUNDLE"

# 3. Validate Mach-O, SDK linkage, dylib load order, and embedded engine assets.
EXE="$APP_BUNDLE/Curium"
[ -f "$EXE" ] || { echo "error: Curium executable missing at $EXE" >&2; exit 1; }

ARCHS="$(xcrun lipo -archs "$EXE")"
[ "$ARCHS" = "arm64" ] || { echo "error: expected thin arm64 executable, found '$ARCHS'" >&2; exit 1; }

VTOOL_OUT="$(xcrun vtool -show-build "$EXE")"
echo "==> Curium Mach-O build version:"
printf '%s\n' "$VTOOL_OUT" | grep -E 'platform|minos|sdk' || true
printf '%s\n' "$VTOOL_OUT" | grep -q "platform IOS" || { echo "error: Curium binary is not platform IOS" >&2; exit 1; }
printf '%s\n' "$VTOOL_OUT" | grep -q "sdk ${REQUIRED_SDK}" || {
  echo "error: Curium binary did not link against sdk ${REQUIRED_SDK}" >&2
  exit 1
}

FIRST_DYLIB="$(xcrun otool -l "$EXE" | awk '/cmd LC_LOAD_DYLIB$/ { next_load = 1; next } next_load && $1 == "name" { print $2; exit }')"
EXPECTED_DYLIB="@rpath/EarlyMallocZoneRegistration.framework/EarlyMallocZoneRegistration"
if [ "$FIRST_DYLIB" != "$EXPECTED_DYLIB" ]; then
  echo "error: first strong LC_LOAD_DYLIB must be $EXPECTED_DYLIB (found $FIRST_DYLIB)" >&2
  exit 1
fi

for req in \
  "Frameworks/EarlyMallocZoneRegistration.framework/EarlyMallocZoneRegistration" \
  "Frameworks/chrome_framework.framework/chrome_framework" \
  "CuriumKernelManifest.json" \
  "icudtl.dat" \
  "resources.pak"; do
  [ -f "$APP_BUNDLE/$req" ] || { echo "error: missing required bundle asset: $req" >&2; exit 1; }
done

ACTUAL_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Info.plist")"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Info.plist")"
if [ "$ACTUAL_VER" != "$MARKETING_VERSION" ] || [ "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]; then
  echo "error: Info.plist version mismatch (${ACTUAL_VER} (${ACTUAL_BUILD}) vs ${MARKETING_VERSION} (${BUILD_NUMBER}))" >&2
  exit 1
fi

# 4. Ad-hoc sign inside-out (nested frameworks first, then Curium.app) and verify.
if [ "$SKIP_SIGN" -eq 0 ]; then
  echo "==> Ad-hoc signing nested frameworks and Curium.app inside-out..."
  for fw in "$APP_BUNDLE/Frameworks"/*.framework; do
    [ -d "$fw" ] || continue
    codesign --force --sign - --timestamp=none "$fw"
  done
  codesign --force --sign - --timestamp=none "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
  echo "==> Verified signature (--deep --strict)"
fi

# 5. Package IPA and write SHA-256 checksum.
if [ -n "$OUTPUT_IPA" ]; then
  case "$OUTPUT_IPA" in
    /*) ;;
    *) OUTPUT_IPA="$PWD/$OUTPUT_IPA" ;;
  esac
  mkdir -p "$(dirname "$OUTPUT_IPA")"
else
  mkdir -p "$OUTPUT_DIR"
  OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
  OUTPUT_IPA="$OUTPUT_DIR/Curium-${MARKETING_VERSION}-b${BUILD_NUMBER}-arm64.ipa"
fi

rm -f "$OUTPUT_IPA" "${OUTPUT_IPA}.sha256"
echo "==> Packaging $OUTPUT_IPA..."
(cd "$STAGE_DIR" && zip -qry "$OUTPUT_IPA" Payload)
(cd "$(dirname "$OUTPUT_IPA")" && shasum -a 256 "$(basename "$OUTPUT_IPA")" > "$(basename "$OUTPUT_IPA").sha256")

IPA_SHA256="$(awk '{print $1}' "${OUTPUT_IPA}.sha256")"
IPA_SIZE="$(du -sh "$OUTPUT_IPA" | awk '{print $1}')"
echo "==> Packaged Curium IPA:"
echo "    Path:    $OUTPUT_IPA"
echo "    Size:    $IPA_SIZE"
echo "    SHA-256: $IPA_SHA256"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "ipa_path=$OUTPUT_IPA"
    echo "ipa_name=$(basename "$OUTPUT_IPA")"
    echo "sha256_path=${OUTPUT_IPA}.sha256"
    echo "ipa_sha256=$IPA_SHA256"
    echo "ipa_size=$IPA_SIZE"
    echo "version=$MARKETING_VERSION"
    echo "build_number=$BUILD_NUMBER"
    echo "sdk_version=$REQUIRED_SDK"
    echo "kernel_build=$KERNEL_BUILD"
    echo "chromium_version=$KERNEL_CHROMIUM_VERSION"
    echo "kernel_commit=$KERNEL_COMMIT"
    echo "kernel_run_id=$KERNEL_RUN_ID"
    echo "kernel_ipa_sha256=$KERNEL_IPA_SHA256"
  } >> "$GITHUB_OUTPUT"
fi

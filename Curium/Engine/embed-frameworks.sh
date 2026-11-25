#!/bin/sh
set -eu

destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
assets="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
engine="${CURIUM_ENGINE_VENDOR}/EngineResources"
mkdir -p "${TARGET_TEMP_DIR}"

# Chromium resolves runtime assets relative to the main application bundle.
# Track only the files this phase owns so switching back to standby removes them,
# and skip copying files whose size and nanosecond mtime already match.
/usr/bin/python3 - "$engine" "$assets" "$TARGET_TEMP_DIR/CuriumEngineResources.txt" "$CURIUM_USE_ENGINE_XCFRAMEWORK" <<'PY'
from pathlib import Path
import os
import shutil
import sys

source, bundle, manifest = map(Path, sys.argv[1:4])
enabled = sys.argv[4] == "YES"
vendor_manifest = source.parent / "engine-manifest.json"
previous = set(manifest.read_text(encoding="utf-8").splitlines()) if manifest.is_file() else set()
if enabled and not all((source / name).is_file() for name in ("icudtl.dat", "resources.pak")):
    sys.exit(f"error: Missing Curium engine resources in {source}")

# Exclude unused ios/web injected scripts that otherwise leak window.__gCrWeb
# and window.__proto__.webkit.messageHandlers into every page and iframe.
EXCLUDED_FILES = {
    "gcrweb.js",
    "send_webkit_message.js",
    "language_detection.js",
    "translate_ios.js",
}

files = {
    p.relative_to(source).as_posix()
    for p in source.rglob("*")
    if p.is_file()
    and not p.relative_to(source).as_posix().startswith("bundled_extensions/ios_probe/")
    and p.relative_to(source).as_posix() not in EXCLUDED_FILES
} if enabled else set()
extra_copies: dict[str, Path] = {}
if enabled and vendor_manifest.is_file():
    extra_copies["CuriumKernelManifest.json"] = vendor_manifest
tracked_files = files | set(extra_copies.keys())

for name in sorted(previous - tracked_files):
    file = bundle / name
    file.unlink(missing_ok=True)
    for parent in file.parents:
        if parent == bundle:
            break
        if parent.is_dir():
            if any(parent.iterdir()):
                break
            parent.rmdir()

for name in sorted(tracked_files):
    src = extra_copies.get(name, source / name)
    dst = bundle / name
    src_st = os.stat(src)
    if dst.is_file():
        dst_st = os.stat(dst)
        if dst_st.st_size == src_st.st_size and dst_st.st_mtime_ns == src_st.st_mtime_ns:
            continue
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)

if enabled:
    content = "\n".join(sorted(tracked_files)) + "\n"
    if not manifest.is_file() or manifest.read_text(encoding="utf-8") != content:
        manifest.write_text(content, encoding="utf-8")
else:
    manifest.unlink(missing_ok=True)
PY

remove_framework() {
    rm -rf "$destination/$1.framework" "$TARGET_TEMP_DIR/CuriumEmbed-$1.stamp"
}

if [ "$CURIUM_USE_ENGINE_XCFRAMEWORK" != YES ]; then
    for name in EarlyMallocZoneRegistration chrome_framework Lottie; do
        remove_framework "$name"
    done
    exit 0
fi

mkdir -p "$destination"

file_sig() {
    if [ -e "$1" ]; then
        /usr/bin/stat -f '%z:%m' "$1"
    else
        printf 'missing'
    fi
}

embed() {
    source="$1/$2.framework"
    output="$destination/$2.framework"
    stamp="$TARGET_TEMP_DIR/CuriumEmbed-$2.stamp"
    if [ ! -d "$source" ]; then
        printf 'error: Missing Curium engine dependency: %s\n' "$source" >&2
        exit 1
    fi

    sign_key="${CODE_SIGNING_ALLOWED:-NO}:${EXPANDED_CODE_SIGN_IDENTITY:--}"
    src_sig="${CURIUM_USE_ENGINE_XCFRAMEWORK}|${CURIUM_ENGINE_SLICE:-}|${sign_key}|${source}|$(file_sig "$source/$2")|$(file_sig "$source/Info.plist")"
    if [ -d "$output" ] && [ -f "$stamp" ]; then
        out_sig="$(file_sig "$output/$2")|$(file_sig "$output/Info.plist")"
        expected="${src_sig}|${out_sig}"
        if [ "$(cat "$stamp")" = "$expected" ]; then
            return 0
        fi
    fi

    remove_framework "$2"
    /usr/bin/ditto "$source" "$output"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
            --preserve-metadata=identifier,entitlements "$output"
    fi
    out_sig="$(file_sig "$output/$2")|$(file_sig "$output/Info.plist")"
    printf '%s|%s\n' "$src_sig" "$out_sig" > "$stamp"
}

embed "$CURIUM_ENGINE_ALLOCATOR_DIR" EarlyMallocZoneRegistration
embed "$CURIUM_ENGINE_FRAMEWORK_DIR" chrome_framework
lottie="$CURIUM_ENGINE_VENDOR/Lottie.xcframework/$CURIUM_ENGINE_SLICE"
if [ -d "$lottie/Lottie.framework" ]; then
    embed "$lottie" Lottie
else
    remove_framework Lottie
fi

binary="${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}"
first_dylib=$(/usr/bin/otool -l "$binary" | awk '/cmd LC_LOAD_DYLIB$/ { next_load = 1; next } next_load && $1 == "name" { print $2; exit }')
if [ "$first_dylib" != "@rpath/EarlyMallocZoneRegistration.framework/EarlyMallocZoneRegistration" ]; then
    printf 'error: EarlyMallocZoneRegistration must be the first strong dylib load; found %s.\n' "$first_dylib" >&2
    exit 1
fi

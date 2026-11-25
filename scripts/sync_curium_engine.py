#!/usr/bin/env python3
"""Assemble Curium's local engine from the Chromium IPA pinned in Kernel.lock."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from zipfile import BadZipFile, ZipFile

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "Vendor" / "CuriumEngine"
APP = "Payload/Chromium.app/"
REQUIRED_FRAMEWORKS = {"EarlyMallocZoneRegistration", "chrome_framework"}
FRAMEWORKS = REQUIRED_FRAMEWORKS | {"Lottie"}
SLICES = {
    "ios-arm64": "iPhoneOS",
    "ios-arm64-simulator": "iPhoneSimulator",
}
EXTENSION_DIRS = {"bundled_extensions", "web_extensions"}
ALLOWED_LPROJ = {
    "Base.lproj", "en.lproj", "en_GB.lproj",
    "zh_CN.lproj", "zh_TW.lproj", "zh_HK.lproj", "ja.lproj",
}
EXCLUDED = {
    "Chromium", "Frameworks", "_CodeSignature", "Assets.car", "Settings.bundle",
    "Intents.intentdefinition", "Metadata.appintents", "Info.plist", "PkgInfo",
    "whats_new_entries.plist", "SafeModeCrashingModules.plist",
}
MANIFEST = "engine-manifest.json"


def read_lock() -> dict[str, str]:
    lock = {}
    for line in (ROOT / "Kernel.lock").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or not value or key in lock:
            raise ValueError(f"Invalid Kernel.lock entry: {line}")
        lock[key] = value
    for key, pattern in {
        "KERNEL_BUILD": r"[0-9]+",
        "KERNEL_REPO": r"[\w.-]+/[\w.-]+",
        "KERNEL_RUN_ID": r"[0-9]+",
        "KERNEL_ARTIFACT_NAME": r"[\w.-]+",
        "KERNEL_IPA_SHA256": r"[a-f0-9]{64}",
    }.items():
        if not re.fullmatch(pattern, lock.get(key, "")):
            raise ValueError(f"Missing or invalid {key} in Kernel.lock")
    return lock


def run(*args: str | Path, capture: bool = False) -> str:
    return subprocess.run(args, check=True, stdout=subprocess.PIPE if capture else None,
                          text=True).stdout or ""


def download(lock: dict[str, str], directory: Path,
             release_tag: str | None = None,
             ipa_cache: Path | None = None) -> Path:
    name = lock["KERNEL_ARTIFACT_NAME"]
    expected_sha = lock["KERNEL_IPA_SHA256"]
    cached_path = (ipa_cache / f"{name}.ipa") if ipa_cache is not None else None
    if cached_path is not None and cached_path.is_file():
        sha = hashlib.sha256()
        with cached_path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                sha.update(chunk)
        if sha.hexdigest() == expected_sha:
            print(f"Using cached engine IPA: {cached_path}")
            return cached_path
        print(f"Cached engine IPA digest mismatch ({cached_path}); re-downloading...", file=sys.stderr)

    effective_tag = release_tag or lock.get("KERNEL_RELEASE_TAG")
    target = directory / f"{name}.ipa"
    if effective_tag:
        run("gh", "release", "download", effective_tag, "--repo", lock["KERNEL_REPO"],
            "--pattern", f"{name}.ipa", "--dir", directory, "--clobber")
    else:
        run("gh", "run", "download", lock["KERNEL_RUN_ID"], "--repo", lock["KERNEL_REPO"],
            "--name", name, "--dir", directory)

    if cached_path is not None and target.is_file():
        ipa_cache.mkdir(parents=True, exist_ok=True)
        tmp_cache = cached_path.with_suffix(".ipa.tmp")
        shutil.copy2(target, tmp_cache)
        tmp_cache.replace(cached_path)
    return target


def is_resource(path: PurePosixPath) -> bool:
    for part in path.parts:
        if (part in EXCLUDED or part.startswith(".")
                or part.endswith((".storyboardc", ".mp4"))
                or (part.startswith("AppIcon") and part.endswith(".png"))
                or (part.startswith("terms_") and part.endswith(".html"))):
            return False
    if len(path.parts) > 1:
        # Extension packages need their manifests and rule lists, which are JSON.
        return (path.parts[0] in EXTENSION_DIRS
                or (path.parts[0] in ALLOWED_LPROJ and path.suffix != ".json"))
    return (path.name == "icudtl.dat" or path.suffix in {".pak", ".js"}
            or path.match("error_page_*.html"))


def require_resources(resources: Path) -> None:
    for name in ("icudtl.dat", "resources.pak"):
        if not (resources / name).is_file():
            raise ValueError(f"Missing engine resource: {name}")


def extract(archive: ZipFile, app: Path, resources: Path) -> dict[str, int]:
    stats = {"count": 0, "bytes": 0, "excluded_bytes": 0}
    resources.mkdir()
    for member in sorted(archive.infolist(), key=lambda item: item.filename):
        if member.is_dir() or not member.filename.startswith(APP):
            continue
        parts = member.filename[len(APP):].split("/")
        if any(part in {"", ".", ".."} for part in parts):
            raise ValueError(f"Invalid IPA entry: {member.filename}")
        path = PurePosixPath(*parts)
        if parts[0] == "Frameworks":
            if (len(parts) < 3 or parts[1].removesuffix(".framework") not in FRAMEWORKS
                    or not parts[1].endswith(".framework") or "_CodeSignature" in parts):
                continue
            target = app.joinpath(*parts)
        elif is_resource(path):
            target = resources.joinpath(*parts)
            stats["count"] += 1
            stats["bytes"] += member.file_size
        else:
            if path != PurePosixPath("Chromium"):
                stats["excluded_bytes"] += member.file_size
            continue

        mode = member.external_attr >> 16
        if stat.S_IFMT(mode) not in {0, stat.S_IFREG}:
            raise ValueError(f"Expected a regular file in the IPA: {member.filename}")
        target.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(member) as source, target.open("xb") as dest:
            shutil.copyfileobj(source, dest, 1024 * 1024)
        target.chmod(0o755 if mode & 0o111 else 0o644)
    require_resources(resources)
    return stats


def build_version(binary: Path) -> tuple[str, str, str]:
    build = run("xcrun", "vtool", "-show-build", binary, capture=True)
    versions = re.findall(r"\bplatform\s+(\w+)\s+minos\s+([\d.]+)\s+sdk\s+([\d.]+)", build)
    if len(versions) != 1:
        raise ValueError(f"Expected one Mach-O build version in {binary.name}")
    return versions[0]


def dylib_commands(binary: Path) -> list[str]:
    load_commands = run("xcrun", "otool", "-l", binary, capture=True)
    return [command for command in re.split(r"(?m)^Load command \d+\n", load_commands)[1:]
            if re.match(r"\s*cmd LC_(?:ID|LOAD|LOAD_WEAK|REEXPORT|LAZY_LOAD|LOAD_UPWARD)_DYLIB\n", command)]


def make_frameworks(app: Path, work: Path, output: Path) -> list[str]:
    built = []
    for name in sorted(FRAMEWORKS):
        source = app / "Frameworks" / f"{name}.framework"
        if not source.is_dir() and name not in REQUIRED_FRAMEWORKS:
            continue
        if not source.is_dir():
            raise ValueError(f"Missing framework in IPA: {source.name}")
        plist = plistlib.loads((source / "Info.plist").read_bytes())
        executable = plist["CFBundleExecutable"]
        if executable != name:
            raise ValueError(f"Unexpected CFBundleExecutable in {source.name}: {executable}")
        original = source / executable
        if run("xcrun", "lipo", "-archs", original, capture=True).strip() != "arm64":
            raise ValueError(f"Expected a thin arm64 binary in {source.name}")
        platform, minos, sdk = build_version(original)
        if platform != "IOS":
            raise ValueError(f"Expected an iOS device binary in {source.name}, found {platform}")
        dylibs = dylib_commands(original)
        inputs = []
        for slice_name, supported_platform in SLICES.items():
            framework = work / slice_name / source.name
            shutil.copytree(source, framework)
            binary = framework / executable
            if supported_platform == "iPhoneSimulator":
                retargeted = work / "retargeted"
                run("xcrun", "vtool", "-set-build-version", "iossim", minos, sdk,
                    "-replace", "-output", retargeted, binary)
                retargeted.replace(binary)
                if build_version(binary) != ("IOSSIMULATOR", minos, sdk):
                    raise ValueError(f"Simulator retarget failed for {source.name}")
                if dylib_commands(binary) != dylibs:
                    raise ValueError(f"Simulator retarget changed dylib references in {source.name}")
            binary.chmod(0o755)
            slice_plist = {**plist, "CFBundleSupportedPlatforms": [supported_platform],
                           "DTPlatformName": supported_platform.lower(), "MinimumOSVersion": minos,
                           "DTSDKName": f"{supported_platform.lower()}{sdk}"}
            (framework / "Info.plist").write_bytes(plistlib.dumps(slice_plist, fmt=plistlib.FMT_BINARY))
            run("codesign", "--force", "--sign", "-", "--timestamp=none", framework)
            run("codesign", "--verify", "--strict", framework)
            inputs.extend(("-framework", framework))
        xcframework = f"{name}.xcframework"
        bundle = output / xcframework
        run("xcodebuild", "-create-xcframework", *inputs, "-output", bundle)
        # Xcode does not guarantee an order for the entries in AvailableLibraries.
        info_path = bundle / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        libraries = info["AvailableLibraries"]
        libraries.sort(key=lambda library: library["LibraryIdentifier"])
        if [library["LibraryIdentifier"] for library in libraries] != list(SLICES):
            raise ValueError(f"Unexpected library identifiers in {xcframework}")
        info_path.write_bytes(plistlib.dumps(info))
        built.append(xcframework)
    return built


def publish(output: Path, backup: Path) -> None:
    if VENDOR.is_symlink() or (VENDOR.exists() and not VENDOR.is_dir()):
        raise ValueError(f"Expected a directory at {VENDOR}")
    if VENDOR.exists():
        VENDOR.rename(backup)
    try:
        output.rename(VENDOR)
    except OSError:
        if backup.exists():
            backup.rename(VENDOR)
        raise


def timestamp() -> str:
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    now = datetime.now(timezone.utc) if epoch is None else datetime.fromtimestamp(int(epoch), timezone.utc)
    return now.isoformat(timespec="seconds").replace("+00:00", "Z")


def sync(ipa: Path | None, skip_sha256: bool, lock: dict[str, str],
         release_tag: str | None = None, ipa_cache: Path | None = None) -> None:
    source_type = "local" if ipa is not None else ("github-release" if (release_tag or lock.get("KERNEL_RELEASE_TAG")) else "github-actions")
    with tempfile.TemporaryDirectory(prefix="curium-ipa-") as directory:
        if ipa is None:
            ipa = download(lock, Path(directory), release_tag=release_tag, ipa_cache=ipa_cache)
        with ipa.open("rb") as source:
            sha = hashlib.sha256()
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                sha.update(chunk)
            actual = sha.hexdigest()
            expected = lock["KERNEL_IPA_SHA256"]
            if not skip_sha256 and actual != expected:
                raise ValueError(f"IPA SHA-256 mismatch for {ipa.name}:\n"
                                 f"  expected {expected}\n  actual   {actual}")

            VENDOR.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".curium-engine-", dir=VENDOR.parent) as staging:
                work = Path(staging)
                app = work / APP
                output = work / "output"
                output.mkdir()
                with ZipFile(source) as archive:
                    resources = extract(archive, app, output / "EngineResources")
                manifest = {
                    "schema_version": 1,
                    "source": {"type": source_type, "ipa_sha256": actual,
                               "verified": not skip_sha256, "kernel": lock},
                    "xcframeworks": make_frameworks(app, work, output),
                    "resources": resources,
                    "created_at": timestamp(),
                }
                (output / MANIFEST).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                                              encoding="utf-8")
                publish(output, work / "previous")
    print(f"Assembled {VENDOR}: {len(manifest['xcframeworks'])} XCFrameworks, "
          f"{resources['count']} resource files, {resources['excluded_bytes']:,} resource bytes omitted"
          + (" (unverified local IPA)" if skip_sha256 else ""))


def status(lock: dict[str, str]) -> int:
    try:
        if not (VENDOR / MANIFEST).is_file():
            raise ValueError("No engine manifest; run scripts/sync_curium_engine.py to assemble it")
        manifest = json.loads((VENDOR / MANIFEST).read_text(encoding="utf-8"))
        if manifest["schema_version"] != 1:
            raise ValueError("Unsupported engine manifest; reassemble the engine")
        source = manifest["source"]
        verified, ipa_sha = source["verified"], source["ipa_sha256"]
        if not isinstance(verified, bool) or not re.fullmatch(r"[a-f0-9]{64}", ipa_sha):
            raise ValueError("Invalid IPA provenance in manifest; reassemble the engine")
        if source["kernel"] != lock or (verified and ipa_sha != lock["KERNEL_IPA_SHA256"]):
            raise ValueError("Installed engine does not match Kernel.lock; reassemble it")
        xcframeworks = set(manifest["xcframeworks"])
        if not {f"{n}.xcframework" for n in REQUIRED_FRAMEWORKS} <= xcframeworks <= {
            f"{n}.xcframework" for n in FRAMEWORKS
        }:
            raise ValueError("Manifest lists an unexpected set of XCFrameworks")
        for xcframework in sorted(xcframeworks):
            bundle = VENDOR / xcframework
            if not (bundle / "Info.plist").is_file():
                raise ValueError(f"Missing XCFramework metadata: {xcframework}")
            name = bundle.stem
            for slice_name, platform in SLICES.items():
                framework = bundle / slice_name / f"{name}.framework"
                if not (framework / name).is_file():
                    raise ValueError(f"Missing framework binary: {xcframework}/{slice_name}/{name}")
                info = plistlib.loads((framework / "Info.plist").read_bytes())
                if info["CFBundleSupportedPlatforms"] != [platform]:
                    raise ValueError(f"Wrong framework platform: {xcframework}/{slice_name}")
        resources = VENDOR / "EngineResources"
        require_resources(resources)
        files = [p for p in resources.rglob("*") if p.is_file()]
        if (len(files) != manifest["resources"]["count"]
                or sum(p.stat().st_size for p in files) != manifest["resources"]["bytes"]):
            raise ValueError("EngineResources differs from the manifest; reassemble the engine")
    except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException) as error:
        print(f"Curium engine not ready: {error}", file=sys.stderr)
        return 1
    label = "ready" if verified else "ready for local testing (unverified IPA)"
    print(f"Curium engine {label}: Kernel {lock['KERNEL_BUILD']} (Chromium {lock.get('KERNEL_CHROMIUM_VERSION', '?')}), "
          f"{len(xcframeworks)} XCFrameworks, {len(files)} resource files")
    print(f"IPA SHA-256: {ipa_sha}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--ipa", type=Path, help="Use a local IPA instead of downloading the pinned artifact")
    mode.add_argument("--status", action="store_true", help="Check the installed engine offline")
    parser.add_argument("--skip-sha256", action="store_true", help="Allow an unverified IPA with --ipa only")
    parser.add_argument("--release-tag", help="Download the pinned engine IPA from this GitHub Release tag instead of the Actions run")
    parser.add_argument("--ipa-cache", type=Path, help="Cache directory for storing and reusing the verified engine IPA")
    args = parser.parse_args()
    if args.skip_sha256 and args.ipa is None:
        parser.error("--skip-sha256 requires --ipa")
    try:
        lock = read_lock()
        if args.status:
            return status(lock)
        sync(args.ipa, args.skip_sha256, lock, release_tag=args.release_tag, ipa_cache=args.ipa_cache)
    except (OSError, ValueError, KeyError, BadZipFile, plistlib.InvalidFileException,
            subprocess.CalledProcessError) as error:
        print(f"Curium engine: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

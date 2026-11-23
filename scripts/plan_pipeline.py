#!/usr/bin/env python3
"""Plans a build-ipa run: build identities, existing checkpoints, work to do.

Every stage produces one write-once checkpoint in GHCR named by a key over the
inputs that shape its output: its epoch (ci/epochs.json), the upstream key,
the source and SDK artifacts by digest, and the files listed for it below.
Workflow YAML is orchestration only and never part of a key, so editing
timeouts, logging or concurrency reuses every finished checkpoint.

  preflight  Resolve the source snapshot digest and whether the SDK stub for
             the pinned Xcode exists (the Mac `sdk` job extracts it if not).
  plan       Resolve both digests, compute all keys, probe checkpoints, and
             emit what to run, including only the compile shards still missing.
  refs       Print pinned SRC_REF/STUB_REF lines (for the diagnosis workflow).

Registry errors fail the plan; only an explicit "not found" counts as missing.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHARD_COUNT = 18  # Logical partitions. Changing it is a new partitioning: bump the compile epoch.

# Inputs that shape every stage from codegen on (scripts/stage.sh holds only
# the helpers several stages share).
COMMON = [
    "patches",
    "args",
    "ci/gn_args.linux",
    "ci/gn_args.mac",
    "ci/pgo_profile.env",
    "scripts/stage.sh",
    "scripts/apply_patches.sh",
    "scripts/overlay_linux_host_deps.py",
    "scripts/apple_tool_wrapper.py",
    "scripts/ninja_graph.py",
    "scripts/rewrite_ninja_graph.py",
    "scripts/plan_shards.py",
]
# Each stage's own logic: changing it re-keys that stage and the ones after it.
STAGE_FILES = {
    "codegen": ["scripts/stages/codegen.sh"],
    "apple": ["scripts/stages/apple.sh", "scripts/bootstrap_macos_host_tools.sh"],
    "compile": ["scripts/stages/compile.sh", "scripts/shard_artifact.py"],
    "link": ["scripts/stages/link.sh", "scripts/shard_artifact.py"],
    "package": ["scripts/stages/package.sh", "scripts/package_ipa.sh"],
}
# Never part of a key: transport, reporting, budgets, audits, and the producers
# of the source/SDK artifacts (which enter keys by digest instead).
NON_OUTPUT = {
    "ci/ccache.env",
    "ci/epochs.json",  # read per stage below
    "scripts/build_curium_ipa.sh",
    "scripts/check_inputs.py",
    "scripts/check_remote_patches.py",
    "scripts/compare_graphs.py",
    "scripts/diagnose_graph.py",
    "scripts/extract_xcode_stub.sh",
    "scripts/oci_artifacts.sh",
    "scripts/plan_pipeline.py",
    "scripts/reclaim_disk_linux.sh",
    "scripts/reclaim_disk_mac.sh",
    "scripts/resolve_pin.py",
    "scripts/run_with_budget.py",
    "scripts/sparse_checkout.conf",
    "scripts/stages/probe.sh",  # diagnostic objects are never stage checkpoints
    "scripts/stages/sdk.sh",  # the SDK enters keys by digest
    "scripts/sync_curium_engine.py",
    "scripts/sync_pruned_source.sh",
    "scripts/write_job_summary.py",
}


def check_classification() -> None:
    keyed = set(COMMON) | {f for files in STAGE_FILES.values() for f in files}
    on_disk = {p.relative_to(ROOT).as_posix() for d in ("scripts", "scripts/stages", "ci") for p in (ROOT / d).iterdir()
               if p.is_file() and p.name != "__pycache__" and not p.name.endswith(".pyc")}
    unclassified = sorted(on_disk - keyed - NON_OUTPUT)
    dir_inputs = {p for p in keyed if (p in {"patches", "args"} or p.startswith("helpers/")) and (ROOT / p).is_dir()}
    stale = sorted((keyed | NON_OUTPUT) - on_disk - dir_inputs)
    if unclassified or stale:
        sys.exit(f"::error::plan_pipeline.py file classification is out of date: "
                 f"unclassified {unclassified}, missing {stale}")


def read_lock() -> dict[str, str]:
    lock: dict[str, str] = {}
    for raw in (ROOT / "version.lock").read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if "=" in line:
            k, v = line.split("=", 1)
            lock[k.strip()] = v.strip()
    return lock


def digest(*parts: str) -> str:
    h = hashlib.sha256()
    for part in parts:
        path = ROOT / part if not part.startswith("=") else None
        if path is not None and path.exists():
            files = sorted(p for p in path.rglob("*") if p.is_file()) if path.is_dir() else [path]
            for f in files:
                h.update(f.relative_to(ROOT).as_posix().encode() + b"\0" + f.read_bytes() + b"\0")
        elif path is not None:
            sys.exit(f"::error::key input {part} does not exist")
        else:
            h.update(part.encode() + b"\0")
    return h.hexdigest()[:20]


def oci(action: str, ref: str) -> tuple[int, str]:
    r = subprocess.run([str(ROOT / "scripts/oci_artifacts.sh"), action, ref], capture_output=True, text=True)
    if r.returncode not in (0, 1):
        sys.exit(f"::error::GHCR query failed for {ref}: {r.stderr.strip()}")
    return r.returncode, r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""


def exists(ref: str) -> bool:
    return oci("exists", ref)[0] == 0


def resolve(ref: str, what: str) -> str:
    rc, out = oci("resolve", ref)
    if rc != 0:
        sys.exit(f"::error::{what} {ref} not found")
    return out


class Refs:
    def __init__(self, repo: str, lock: dict[str, str]) -> None:
        self.base = f"ghcr.io/{repo.lower()}"
        self.rev = lock["CHROMIUM_REV"]
        self.src_tag = f"{self.base}/chromium-ios-src:{self.rev}"
        stub_hash = digest("scripts/extract_xcode_stub.sh")[:12]
        self.stub_tag = f"{self.base}/xcode-stub:{lock['XCODE_BUILD']}-{stub_hash}"

    def pinned(self, tag: str, sha: str) -> str:
        return f"{tag.rsplit(':', 1)[0]}@{sha}"


def write_outputs(values: dict[str, str]) -> None:
    out = os.environ.get("GITHUB_OUTPUT")
    lines = [f"{k}={v}" for k, v in values.items()]
    if out:
        with open(out, "a") as f:
            f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


def plan(repo: str, with_app_groups: str) -> None:
    check_classification()
    lock = read_lock()
    epochs = json.loads((ROOT / "ci/epochs.json").read_text())
    refs = Refs(repo, lock)
    src = resolve(refs.src_tag, "Source snapshot (run 'Sync Pruned Source to GHCR' first):")
    stub = resolve(refs.stub_tag, "SDK stub")

    def stage_key(stage: str, *extra: str) -> str:
        return digest(f"={stage}", f"=epoch:{epochs[stage]}", *extra, *STAGE_FILES[stage])

    k_codegen = stage_key("codegen", f"=src:{src}", f"=stub:{stub}", f"=prefix:{lock['BUNDLE_ID_PREFIX']}", *COMMON)
    k_apple = stage_key("apple", f"=codegen:{k_codegen}", f"=xcode:{lock['XCODE_BUILD']}")
    k_compile = stage_key("compile", f"=codegen:{k_codegen}", f"=apple:{k_apple}", f"=shards:{SHARD_COUNT}")
    k_link = stage_key("link", f"=compile:{k_compile}")
    k_package = stage_key(
        "package",
        f"=link:{k_link}",
        f"=app_groups:{with_app_groups}",
        f"=xcode:{lock['XCODE_BUILD']}",
        f"=prefix:{lock['BUNDLE_ID_PREFIX']}",
    )

    cache = f"{refs.base}/stage-cache"
    codegen_ref, apple_ref, link_ref = f"{cache}:codegen-{k_codegen}", f"{cache}:apple-{k_apple}", f"{cache}:link-{k_link}"
    compile_prefix = f"{cache}:compile-{k_compile}"

    link_rc, link_sha = oci("resolve", link_ref)
    has_link = link_rc == 0
    has_codegen = has_link or exists(codegen_ref)
    has_apple = has_link or exists(apple_ref)
    missing = [] if has_link else [i for i in range(SHARD_COUNT) if not exists(f"{compile_prefix}-{i}")]

    # A shard rescue (ONLY_SHARDS, e.g. "15" or "3,15") builds just those
    # shards beside a running build and stops before link.
    only = sorted({int(s) for s in os.environ.get("ONLY_SHARDS", "").replace(" ", "").split(",") if s})
    if only:
        if any(not 0 <= i < SHARD_COUNT for i in only):
            sys.exit(f"::error::ONLY_SHARDS {only} is outside 0..{SHARD_COUNT - 1}")
        if not (has_codegen and has_apple):
            sys.exit("::error::A shard rescue needs the codegen and Apple checkpoints; run a full build")
        missing = [i for i in missing if i in only]

    run = {
        "codegen": not has_codegen,
        "apple": not has_apple,
        "compile": bool(missing),
        "link": not has_link and not only,
        "package": not only,
    }
    write_outputs({
        "chromium_rev": refs.rev,
        "chromium_version": lock["CHROMIUM_VERSION"],
        "src_ref": refs.pinned(refs.src_tag, src),
        "stub_ref": refs.pinned(refs.stub_tag, stub),
        "codegen_ref": codegen_ref,
        "apple_ref": apple_ref,
        "compile_prefix": compile_prefix,
        "link_ref": refs.pinned(link_ref, link_sha) if has_link else link_ref,
        "ccache_repo": f"{refs.base}/chromium-ios-ccache",
        "shard_count": str(SHARD_COUNT),
        # A placeholder keeps the matrix valid when compile is skipped.
        "shards_json": json.dumps(missing or [0]),
        **{f"run_{k}": "true" if v else "false" for k, v in run.items()},
        "k_package": k_package,
    })

    rows = [
        ("0 SDK stub (Mac)", refs.stub_tag.rsplit(":", 1)[1], "reuse"),
        ("1 Codegen (Linux)", k_codegen, "run" if run["codegen"] else "reuse"),
        ("2 Apple tools (Mac)", k_apple, "run" if run["apple"] else "reuse"),
        (f"3 Compile × {SHARD_COUNT} (Linux)", k_compile,
         f"run {len(missing)} shard(s): {missing}" if missing else "reuse all"),
        ("4 Link (Linux)", k_link, "run" if run["link"] else "skip (shard rescue)" if only else "reuse"),
        ("5 Package IPA (Mac)", k_package, "run" if run["package"] else "skip (shard rescue)"),
    ]
    summary = ["## Build plan", "", f"Chromium `{refs.rev[:12]}` ({lock['CHROMIUM_VERSION']}), "
               f"source `{src[:19]}`, SDK `{stub[:19]}`", "", "| Stage | Key | Action |", "| :-- | :-- | :-- |"]
    summary += [f"| {name} | `{key}` | **{action}** |" for name, key, action in rows]
    text = "\n".join(summary) + "\n"
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(text)


def preflight(repo: str) -> None:
    refs = Refs(repo, read_lock())
    resolve(refs.src_tag, "Source snapshot (run 'Sync Pruned Source to GHCR' first):")
    write_outputs({"stub_tag": refs.stub_tag, "need_sdk": "false" if exists(refs.stub_tag) else "true"})


def print_refs(repo: str) -> None:
    refs = Refs(repo, read_lock())
    print(f"SRC_REF={refs.pinned(refs.src_tag, resolve(refs.src_tag, 'Source snapshot'))}")
    print(f"STUB_REF={refs.pinned(refs.stub_tag, resolve(refs.stub_tag, 'SDK stub'))}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("phase", choices=("preflight", "plan", "refs", "check"))
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    ap.add_argument("--with-app-groups", default="false")
    args = ap.parse_args()
    if args.phase == "check":
        check_classification()
        print("==> key input classification is complete")
    elif args.phase == "preflight":
        preflight(args.repo)
    elif args.phase == "plan":
        plan(args.repo, args.with_app_groups)
    else:
        print_refs(args.repo)
    return 0


if __name__ == "__main__":
    sys.exit(main())

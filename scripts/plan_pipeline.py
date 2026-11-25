#!/usr/bin/env python3
"""Plans a build-kernel run: build identities, existing checkpoints, work to do.

Every stage produces one write-once checkpoint in GHCR named by a key over the
inputs that shape its output: its epoch (ci/epochs.json), the upstream key,
the source and SDK artifacts by digest, and the files listed for it below.
Workflow YAML is orchestration only and never part of a key, so editing
timeouts, logging or concurrency reuses every finished checkpoint.

When HEAD lacks live codegen/apple checkpoints and incremental mode is enabled,
the planner searches recent first-parent git history (or an explicit
BASELINE_COMMIT) for a compatible anchor commit with a live graph index and
checkpoints, verifies that only pure implementation sources changed, and maps
untouched shards to the anchor (or intermediate chained builds) via cumulative
per-shard content keys. Any ambiguity or unsupported change fails closed to
the standard full plan.

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
import re
import subprocess
import sys
import tempfile

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import patch_impact  # noqa: E402
from patch_impact import UseStandardPlan  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHARD_COUNT = 18  # Logical partitions. Changing it is a new partitioning: bump the compile epoch.
ANCHOR_SEARCH_DEPTH = 30

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
    "scripts/graph_index.py",
    "scripts/oci_artifacts.sh",
    "scripts/patch_impact.py",
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

BASELINE_REF_RE = re.compile(r"^[0-9A-Za-z._/-]+$")
SHA256_HEX_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")

NON_PATCH_ANCHOR_PATHS = (
    [p for p in COMMON if p != "patches"]
    + STAGE_FILES["codegen"]
    + STAGE_FILES["apple"]
    + STAGE_FILES["compile"]
    + ["scripts/extract_xcode_stub.sh"]
)


def check_classification() -> None:
    keyed = set(COMMON) | {f for files in STAGE_FILES.values() for f in files}
    on_disk = {
        p.relative_to(ROOT).as_posix()
        for d in ("scripts", "scripts/stages", "ci")
        for p in (ROOT / d).iterdir()
        if p.is_file() and p.name != "__pycache__" and not p.name.endswith(".pyc")
    }
    unclassified = sorted(on_disk - keyed - NON_OUTPUT)
    dir_inputs = {p for p in keyed if (p in {"patches", "args"} or p.startswith("helpers/")) and (ROOT / p).is_dir()}
    stale = sorted((keyed | NON_OUTPUT) - on_disk - dir_inputs)
    if unclassified or stale:
        sys.exit(
            f"::error::plan_pipeline.py file classification is out of date: "
            f"unclassified {unclassified}, missing {stale}"
        )


def parse_lock_text(text: str) -> dict[str, str]:
    lock: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if "=" in line:
            k, v = line.split("=", 1)
            lock[k.strip()] = v.strip()
    return lock


def read_lock() -> dict[str, str]:
    return parse_lock_text((ROOT / "version.lock").read_text())


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


def oci_pull(ref: str, dest: pathlib.Path) -> None:
    r = subprocess.run(
        [str(ROOT / "scripts/oci_artifacts.sh"), "pull", ref, str(dest)],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        raise UseStandardPlan(f"Failed to pull {ref}: {r.stderr.strip()}")


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


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    if raw == "true":
        return True
    if raw == "false":
        return False
    sys.exit(f"::error::Invalid boolean for {name}: {raw!r}")


def _assert_working_regular_files(paths: list[str]) -> dict[str, dict[str, bytes]]:
    """Checks that every required working-tree path contains only regular non-symlink files."""
    result: dict[str, dict[str, bytes]] = {}
    for rel in paths:
        target = ROOT / rel
        if target.is_symlink() or not target.exists():
            raise UseStandardPlan(f"Working-tree input is missing or a symlink: {rel}")
        if target.is_dir():
            entries: dict[str, bytes] = {}
            for dirpath, dirnames, filenames in os.walk(target, followlinks=False):
                dp = pathlib.Path(dirpath)
                for d in dirnames:
                    if (dp / d).is_symlink():
                        raise UseStandardPlan(f"Symlink directory in working tree: {dp / d}")
                for f in filenames:
                    fp = dp / f
                    if fp.is_symlink() or not fp.is_file():
                        raise UseStandardPlan(f"Symlink or non-regular file in working tree: {fp}")
                    entries[fp.relative_to(ROOT).as_posix()] = fp.read_bytes()
            if not entries:
                raise UseStandardPlan(f"Working-tree directory input is empty: {rel}")
            result[rel] = entries
        else:
            if not target.is_file():
                raise UseStandardPlan(f"Working-tree input is not a regular file: {rel}")
            result[rel] = {rel: target.read_bytes()}
    return result


def _git_ls_tree_regular(commit: str, rel_path: str) -> dict[str, str]:
    proc = subprocess.run(
        ["git", "ls-tree", "-r", "-z", commit, "--", rel_path],
        cwd=ROOT,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise UseStandardPlan(f"git ls-tree failed at {commit[:12]} for {rel_path}")
    entries: dict[str, str] = {}
    for rec in proc.stdout.split(b"\0"):
        if not rec:
            continue
        meta, path_bytes = rec.split(b"\t", 1)
        mode, obj_type, oid = meta.decode("ascii").split(" ", 2)
        rel = path_bytes.decode("utf-8")
        if mode not in ("100644", "100755") or obj_type != "blob":
            raise UseStandardPlan(f"Non-regular git entry {mode} {obj_type} at {commit[:12]}:{rel}")
        entries[rel] = oid
    if not entries:
        raise UseStandardPlan(f"Required input {rel_path} missing at {commit[:12]}")
    return entries


def _git_cat_blobs(oids: list[str]) -> dict[str, bytes]:
    if not oids:
        return {}
    unique = list(dict.fromkeys(oids))
    proc = subprocess.run(
        ["git", "cat-file", "--batch"],
        input=("\n".join(unique) + "\n").encode("ascii"),
        cwd=ROOT,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise UseStandardPlan("git cat-file --batch failed")
    buf = proc.stdout
    pos = 0
    out: dict[str, bytes] = {}
    for oid in unique:
        nl = buf.index(b"\n", pos)
        header = buf[pos:nl].decode("ascii").split(" ")
        if len(header) != 3 or header[1] != "blob":
            raise UseStandardPlan(f"Unexpected git cat-file header for {oid}: {header}")
        size = int(header[2])
        start = nl + 1
        end = start + size
        out[oid] = buf[start:end]
        pos = end + 1
    return out


def digest_at_commit(
    commit: str,
    *parts: str,
    tree_cache: dict[str, dict[str, str]] | None = None,
    blob_cache: dict[str, bytes] | None = None,
) -> str:
    """Computes the exact same digest as `digest(*parts)` against git commit `commit`."""
    t_cache = tree_cache if tree_cache is not None else {}
    b_cache = blob_cache if blob_cache is not None else {}

    needed_oids: list[str] = []
    part_entries: list[tuple[str, dict[str, str] | None]] = []
    for part in parts:
        if part.startswith("="):
            part_entries.append((part, None))
            continue
        if part not in t_cache:
            t_cache[part] = _git_ls_tree_regular(commit, part)
        entries = t_cache[part]
        part_entries.append((part, entries))
        for oid in entries.values():
            if oid not in b_cache:
                needed_oids.append(oid)

    if needed_oids:
        b_cache.update(_git_cat_blobs(needed_oids))

    h = hashlib.sha256()
    for part, entries in part_entries:
        if entries is None:
            h.update(part.encode() + b"\0")
            continue
        # Match `sorted(path.rglob("*"))` in `digest()`, which compares
        # `pathlib.PosixPath` tuples (path components), not raw ASCII strings.
        for rel in sorted(entries, key=pathlib.PurePosixPath):
            h.update(rel.encode() + b"\0" + b_cache[entries[rel]] + b"\0")
    return h.hexdigest()[:20]


def validate_baseline_ref(raw: str) -> str:
    if (
        not raw
        or raw.startswith("-")
        or raw.startswith("/")
        or raw.endswith("/")
        or ".." in raw
        or not BASELINE_REF_RE.fullmatch(raw)
    ):
        sys.exit(f"::error::Invalid BASELINE_COMMIT ref: {raw!r}")
    return raw


def resolve_baseline_commit(raw: str) -> str:
    ref = validate_baseline_ref(raw)
    proc = subprocess.run(
        ["git", "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0:
        sha = proc.stdout.strip()
        if COMMIT_SHA_RE.fullmatch(sha):
            return sha

    fetch = subprocess.run(
        ["git", "fetch", "--no-tags", "--depth=1", "--", "origin", ref],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if fetch.returncode != 0:
        sys.exit(f"::error::Cannot resolve or fetch BASELINE_COMMIT {ref!r}: {fetch.stderr.strip()}")

    for candidate in (f"{ref}^{{commit}}", "FETCH_HEAD^{commit}"):
        proc = subprocess.run(
            ["git", "rev-parse", "--verify", "--end-of-options", candidate],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0 and COMMIT_SHA_RE.fullmatch(proc.stdout.strip()):
            return proc.stdout.strip()
    sys.exit(f"::error::BASELINE_COMMIT {ref!r} did not resolve to a commit SHA")


def candidate_commits(baseline_commit: str) -> list[str]:
    if baseline_commit:
        return [resolve_baseline_commit(baseline_commit)]
    proc = subprocess.run(
        ["git", "rev-list", "--first-parent", f"--max-count={ANCHOR_SEARCH_DEPTH}", "HEAD~1"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return []
    return [line.strip() for line in proc.stdout.splitlines() if COMMIT_SHA_RE.fullmatch(line.strip())]


def validate_graph_index(
    idx: object,
    *,
    expected_k_codegen: str,
    expected_src_ref: str,
    expected_stub_ref: str,
) -> dict:
    if not isinstance(idx, dict):
        raise UseStandardPlan("Graph index JSON is not an object")
    if type(idx.get("schema_version")) is not int or idx["schema_version"] != 1:
        raise UseStandardPlan(f"Unsupported graph index schema_version: {idx.get('schema_version')!r}")
    if idx.get("k_codegen") != expected_k_codegen:
        raise UseStandardPlan("Graph index k_codegen does not match anchor")
    if idx.get("src_ref") != expected_src_ref:
        raise UseStandardPlan("Graph index src_ref does not match current source snapshot")
    if idx.get("stub_ref") != expected_stub_ref:
        raise UseStandardPlan("Graph index stub_ref does not match current SDK stub")
    if type(idx.get("shard_count")) is not int or idx["shard_count"] != SHARD_COUNT:
        raise UseStandardPlan(f"Graph index shard_count {idx.get('shard_count')!r} != {SHARD_COUNT}")
    if idx.get("has_ninja_validations") is not False:
        raise UseStandardPlan("Anchor graph uses Ninja validations outside checked closure")
    for field in ("graph_pruned_sha256", "codegen_targets_sha256", "all_objects_sha256"):
        val = idx.get(field)
        if not isinstance(val, str) or not SHA256_HEX_RE.fullmatch(val):
            raise UseStandardPlan(f"Invalid graph index field {field}: {val!r}")
    s2o = idx.get("source_to_objects")
    if not isinstance(s2o, dict) or not s2o:
        raise UseStandardPlan("Graph index source_to_objects is missing or empty")
    for k, v in s2o.items():
        if not isinstance(k, str) or not isinstance(v, list) or not v or not all(isinstance(x, str) for x in v):
            raise UseStandardPlan(f"Malformed source_to_objects entry for {k!r}")
    unsafe = idx.get("unsafe_sources")
    if not isinstance(unsafe, dict):
        raise UseStandardPlan("Graph index unsafe_sources is missing or malformed")
    for k, v in unsafe.items():
        if not isinstance(k, str) or not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            raise UseStandardPlan(f"Malformed unsafe_sources entry for {k!r}")
    apple_srcs = idx.get("apple_object_sources")
    if not isinstance(apple_srcs, list) or not all(isinstance(x, str) for x in apple_srcs):
        raise UseStandardPlan("Graph index apple_object_sources is missing or malformed")
    return idx


def compute_incremental_shard_key(
    anchor_compile_key: str,
    shard_index: int,
    sources_sections: dict[str, list[tuple[str, bytes]]],
) -> str:
    if not sources_sections:
        return anchor_compile_key
    h = hashlib.sha256()
    h.update(b"=compile-inc-v1\0")
    h.update(f"=anchor_compile:{anchor_compile_key}\0".encode())
    h.update(f"=shard:{shard_index}\0".encode())
    for src in sorted(sources_sections):
        h.update(f"=source:{src}\0".encode())
        for patch_name, sec in sources_sections[src]:
            h.update(f"=patch:{patch_name}\0".encode())
            h.update(f"{len(sec)}\0".encode("ascii"))
            h.update(sec + b"\0")
    return h.hexdigest()[:20]


def shard_of_object(obj: str) -> int:
    return int(hashlib.sha1(obj.encode("utf-8")).hexdigest(), 16) % SHARD_COUNT


def _discover_anchor(
    *,
    cache: str,
    refs: Refs,
    src_sha: str,
    stub_sha: str,
    lock_h: dict[str, str],
    epochs_h: dict[str, int],
    baseline_commit: str,
) -> tuple[dict | None, list[str]]:
    reasons: list[str] = []
    required_h_paths = list(
        dict.fromkeys(
            NON_PATCH_ANCHOR_PATHS + ["patches", "version.lock", "ci/epochs.json"]
        )
    )
    try:
        working_files = _assert_working_regular_files(required_h_paths)
    except UseStandardPlan as exc:
        return None, [str(exc)]

    candidates = candidate_commits(baseline_commit)
    if not candidates:
        return None, ["No candidate anchor commits found in git history"]

    src_pinned = refs.pinned(refs.src_tag, src_sha)
    stub_pinned = refs.pinned(refs.stub_tag, stub_sha)
    seen_codegen_keys: set[str] = set()

    for commit in candidates:
        short = commit[:12]
        tree_cache: dict[str, dict[str, str]] = {}
        blob_cache: dict[str, bytes] = {}
        try:
            # Verify all non-patch inputs exist as regular blobs at A and match H byte-for-byte.
            check_paths = list(dict.fromkeys(NON_PATCH_ANCHOR_PATHS + ["version.lock", "ci/epochs.json"]))
            all_oids: list[str] = []
            for rel in check_paths:
                tree_cache[rel] = _git_ls_tree_regular(commit, rel)
                all_oids.extend(tree_cache[rel].values())
            blob_cache.update(_git_cat_blobs(all_oids))

            for rel in NON_PATCH_ANCHOR_PATHS:
                a_map = {p: blob_cache[oid] for p, oid in tree_cache[rel].items()}
                if a_map != working_files[rel]:
                    raise UseStandardPlan(f"Non-patch input changed since {short}: {rel}")

            lock_a = parse_lock_text(blob_cache[tree_cache["version.lock"]["version.lock"]].decode("utf-8"))
            for key in ("CHROMIUM_REV", "XCODE_BUILD", "BUNDLE_ID_PREFIX"):
                if lock_a.get(key) != lock_h.get(key):
                    raise UseStandardPlan(f"version.lock {key} changed since {short}")

            epochs_a = json.loads(blob_cache[tree_cache["ci/epochs.json"]["ci/epochs.json"]].decode("utf-8"))
            for stage_name in ("codegen", "apple", "compile"):
                if epochs_a.get(stage_name) != epochs_h.get(stage_name):
                    raise UseStandardPlan(f"ci/epochs.json {stage_name} epoch changed since {short}")

            def stage_key_a(stage: str, *extra: str) -> str:
                return digest_at_commit(
                    commit,
                    f"={stage}",
                    f"=epoch:{epochs_a[stage]}",
                    *extra,
                    *STAGE_FILES[stage],
                    tree_cache=tree_cache,
                    blob_cache=blob_cache,
                )

            k_codegen_a = stage_key_a(
                "codegen",
                f"=src:{src_sha}",
                f"=stub:{stub_sha}",
                f"=prefix:{lock_a['BUNDLE_ID_PREFIX']}",
                *COMMON,
            )
            if k_codegen_a in seen_codegen_keys:
                continue
            seen_codegen_keys.add(k_codegen_a)

            k_apple_a = stage_key_a("apple", f"=codegen:{k_codegen_a}", f"=xcode:{lock_a['XCODE_BUILD']}")
            k_compile_a = stage_key_a(
                "compile",
                f"=codegen:{k_codegen_a}",
                f"=apple:{k_apple_a}",
                f"=shards:{SHARD_COUNT}",
            )

            impact = patch_impact.analyze(commit, ROOT)

            index_ref_a = f"{cache}:index-{k_codegen_a}"
            codegen_ref_a = f"{cache}:codegen-{k_codegen_a}"
            apple_ref_a = f"{cache}:apple-{k_apple_a}"

            idx_rc, idx_sha = oci("resolve", index_ref_a)
            if idx_rc != 0:
                if exists(codegen_ref_a) and exists(apple_ref_a):
                    reasons.append(
                        f"{short}: codegen+apple live without index-{k_codegen_a} "
                        f"(run backfill_index_only=true on {short})"
                    )
                else:
                    reasons.append(f"{short}: missing index-{k_codegen_a}")
                continue

            if not (exists(codegen_ref_a) and exists(apple_ref_a)):
                reasons.append(f"{short}: index exists but codegen or apple checkpoint missing")
                continue

            with tempfile.TemporaryDirectory(prefix="curium-graph-index-") as tmp_dir:
                tmp_path = pathlib.Path(tmp_dir)
                oci_pull(refs.pinned(index_ref_a, idx_sha), tmp_path)
                idx_file = tmp_path / "graph_index.json"
                if not idx_file.is_file():
                    raise UseStandardPlan(f"graph_index.json missing inside {index_ref_a}")
                idx_data = validate_graph_index(
                    json.loads(idx_file.read_text(encoding="utf-8")),
                    expected_k_codegen=k_codegen_a,
                    expected_src_ref=src_pinned,
                    expected_stub_ref=stub_pinned,
                )

            unsafe_sources = idx_data["unsafe_sources"]
            source_to_objects = idx_data["source_to_objects"]
            for src in sorted(impact.changed_sources):
                if src in unsafe_sources:
                    raise UseStandardPlan(f"Edited source {src} is marked unsafe ({unsafe_sources[src]})")
                if src not in source_to_objects or not source_to_objects[src]:
                    raise UseStandardPlan(f"Edited source {src} has no mapped Chrome object in anchor index")

            return {
                "commit": commit,
                "k_codegen": k_codegen_a,
                "k_apple": k_apple_a,
                "k_compile": k_compile_a,
                "codegen_ref": codegen_ref_a,
                "apple_ref": apple_ref_a,
                "index_ref": index_ref_a,
                "impact": impact,
                "index": idx_data,
            }, reasons
        except (UseStandardPlan, json.JSONDecodeError, UnicodeDecodeError, KeyError, OSError) as exc:
            reasons.append(f"{short}: {exc}")
            continue

    return None, reasons


def plan(repo: str, with_app_groups: str) -> None:
    check_classification()
    lock = read_lock()
    epochs = json.loads((ROOT / "ci/epochs.json").read_text())
    refs = Refs(repo, lock)
    src = resolve(refs.src_tag, "Source snapshot (run 'Sync Pruned Source to GHCR' first):")
    stub = resolve(refs.stub_tag, "SDK stub")

    verify_only = env_bool("VERIFY_ONLY", False)
    incremental_enabled = env_bool("INCREMENTAL", True)
    backfill_index_only = env_bool("BACKFILL_INDEX_ONLY", False)
    baseline_commit = os.environ.get("BASELINE_COMMIT", "").strip()
    only = sorted({int(s) for s in os.environ.get("ONLY_SHARDS", "").replace(" ", "").split(",") if s})
    if only and any(not 0 <= i < SHARD_COUNT for i in only):
        sys.exit(f"::error::ONLY_SHARDS {only} is outside 0..{SHARD_COUNT - 1}")
    if backfill_index_only and (only or verify_only):
        sys.exit("::error::backfill_index_only cannot be combined with ONLY_SHARDS or verify_only")

    def stage_key(stage: str, *extra: str) -> str:
        return digest(f"={stage}", f"=epoch:{epochs[stage]}", *extra, *STAGE_FILES[stage])

    k_codegen_h = stage_key("codegen", f"=src:{src}", f"=stub:{stub}", f"=prefix:{lock['BUNDLE_ID_PREFIX']}", *COMMON)
    k_apple_h = stage_key("apple", f"=codegen:{k_codegen_h}", f"=xcode:{lock['XCODE_BUILD']}")
    k_compile_h = stage_key("compile", f"=codegen:{k_codegen_h}", f"=apple:{k_apple_h}", f"=shards:{SHARD_COUNT}")
    k_link_h = stage_key("link", f"=compile:{k_compile_h}")
    k_package_h = stage_key(
        "package",
        f"=link:{k_link_h}",
        f"=app_groups:{with_app_groups}",
        f"=xcode:{lock['XCODE_BUILD']}",
        f"=prefix:{lock['BUNDLE_ID_PREFIX']}",
    )

    cache = f"{refs.base}/stage-cache"
    codegen_ref_h = f"{cache}:codegen-{k_codegen_h}"
    apple_ref_h = f"{cache}:apple-{k_apple_h}"
    link_ref_h = f"{cache}:link-{k_link_h}"
    index_ref_h = f"{cache}:index-{k_codegen_h}"
    compile_prefix_h = f"{cache}:compile-{k_compile_h}"

    # Fast path 1: explicit index backfill only for HEAD's live codegen+apple.
    if backfill_index_only:
        direct_codegen = exists(codegen_ref_h)
        direct_apple = exists(apple_ref_h)
        if not (direct_codegen and direct_apple):
            sys.exit(
                f"::error::backfill_index_only requires live codegen ({k_codegen_h}) "
                f"and apple ({k_apple_h}) checkpoints for HEAD"
            )
        has_index = exists(index_ref_h)
        shard_keys = [k_compile_h] * SHARD_COUNT
        write_outputs({
            "chromium_rev": refs.rev,
            "chromium_version": lock["CHROMIUM_VERSION"],
            "src_ref": refs.pinned(refs.src_tag, src),
            "stub_ref": refs.pinned(refs.stub_tag, stub),
            "stage_cache": cache,
            "k_codegen": k_codegen_h,
            "index_ref": index_ref_h,
            "codegen_ref": codegen_ref_h,
            "apple_ref": apple_ref_h,
            "compile_prefix": compile_prefix_h,
            "link_ref": link_ref_h,
            "ccache_repo": f"{refs.base}/chromium-ios-ccache",
            "shard_count": str(SHARD_COUNT),
            "shards_json": "[0]",
            "shard_keys_json": json.dumps(shard_keys, separators=(",", ":")),
            "compile_matrix_json": json.dumps([{"shard": 0, "key": k_compile_h}], separators=(",", ":")),
            "incremental_mode": "false",
            "anchor_commit": "",
            "expected_graph_sha": "",
            "expected_codegen_sha": "",
            "expected_objects_sha": "",
            "run_codegen": "false",
            "run_apple": "false",
            "run_index_backfill": "false" if has_index else "true",
            "run_verify_apple_objects": "false",
            "run_compile": "false",
            "run_link": "false",
            "run_package": "false",
            "k_package": k_package_h,
        })
        summary = [
            "## Build plan (backfill index only)",
            "",
            f"Chromium `{refs.rev[:12]}` ({lock['CHROMIUM_VERSION']}), "
            f"source `{src[:19]}`, SDK `{stub[:19]}`",
            "",
            f"- `index-{k_codegen_h}`: **{'already present (no-op)' if has_index else 'run backfill'}**",
        ]
        _emit_summary(summary)
        return

    link_rc_h, link_sha_h = oci("resolve", link_ref_h)
    has_link_h = link_rc_h == 0
    direct_codegen_h: bool | None = None
    direct_apple_h: bool | None = None

    if has_link_h and not verify_only:
        has_codegen_h = True
        has_apple_h = True
    else:
        direct_codegen_h = exists(codegen_ref_h)
        direct_apple_h = exists(apple_ref_h)
        has_codegen_h = direct_codegen_h
        has_apple_h = direct_apple_h

    # Attempt incremental planning only when HEAD lacks live codegen+apple (and link)
    # and incremental mode is enabled.
    anchor: dict | None = None
    fallback_reasons: list[str] = []
    if not (has_link_h or (has_codegen_h and has_apple_h)):
        if incremental_enabled:
            anchor, fallback_reasons = _discover_anchor(
                cache=cache,
                refs=refs,
                src_sha=src,
                stub_sha=stub,
                lock_h=lock,
                epochs_h=epochs,
                baseline_commit=baseline_commit,
            )
        else:
            fallback_reasons.append("incremental input set to false")

    if anchor is not None:
        idx_data = anchor["index"]
        impact = anchor["impact"]
        k_codegen_a = anchor["k_codegen"]
        k_apple_a = anchor["k_apple"]
        k_compile_a = anchor["k_compile"]
        source_to_objects = idx_data["source_to_objects"]
        apple_object_sources = set(idx_data["apple_object_sources"])

        shard_sources: dict[int, dict[str, list[tuple[str, bytes]]]] = {i: {} for i in range(SHARD_COUNT)}
        for src_path in sorted(impact.changed_sources):
            for obj in source_to_objects[src_path]:
                shard_sources[shard_of_object(obj)][src_path] = impact.ordered_sections[src_path]

        shard_keys = [
            compute_incremental_shard_key(k_compile_a, i, shard_sources[i])
            for i in range(SHARD_COUNT)
        ]
        affected_shards = [i for i in range(SHARD_COUNT) if shard_sources[i]]

        k_link_inc = stage_key(
            "link",
            "=incremental:v1",
            f"=codegen:{k_codegen_a}",
            f"=apple:{k_apple_a}",
            f"=patches:{digest('patches')}",
            *(f"=shard:{i}:{shard_keys[i]}" for i in range(SHARD_COUNT)),
        )
        k_package_inc = stage_key(
            "package",
            f"=link:{k_link_inc}",
            f"=app_groups:{with_app_groups}",
            f"=xcode:{lock['XCODE_BUILD']}",
            f"=prefix:{lock['BUNDLE_ID_PREFIX']}",
        )
        link_ref_inc = f"{cache}:link-{k_link_inc}"
        link_rc_inc, link_sha_inc = oci("resolve", link_ref_inc)
        has_link_inc = link_rc_inc == 0

        if has_link_inc:
            missing: list[int] = []
            reused_anchor_count = sum(1 for i in range(SHARD_COUNT) if shard_keys[i] == k_compile_a)
            reused_chained_count = sum(1 for i in range(SHARD_COUNT) if shard_keys[i] != k_compile_a)
            run_verify_apple = bool(verify_only)
        else:
            shard_exists = [exists(f"{cache}:compile-{shard_keys[i]}-{i}") for i in range(SHARD_COUNT)]
            # Count anchor shards actually present in GHCR BEFORE ONLY_SHARDS filtering.
            reused_anchor_count = sum(
                1 for i in range(SHARD_COUNT) if shard_keys[i] == k_compile_a and shard_exists[i]
            )
            reused_chained_count = sum(
                1 for i in range(SHARD_COUNT) if shard_keys[i] != k_compile_a and shard_exists[i]
            )
            missing = [i for i in range(SHARD_COUNT) if not shard_exists[i]]
            if only:
                missing = [i for i in missing if i in only]
            apple_touched = bool(impact.changed_sources & apple_object_sources)
            run_verify_apple = True if verify_only else (
                bool(missing) and (apple_touched or reused_anchor_count == 0)
            )

        run = {
            "codegen": False,
            "apple": False,
            "index_backfill": False,
            "verify_apple_objects": run_verify_apple,
            "compile": bool(missing) and not verify_only,
            "link": not has_link_inc and not only and not verify_only,
            "package": not only and not verify_only,
        }
        compile_matrix = (
            [{"shard": i, "key": shard_keys[i]} for i in missing]
            if missing
            else [{"shard": 0, "key": shard_keys[0]}]
        )
        write_outputs({
            "chromium_rev": refs.rev,
            "chromium_version": lock["CHROMIUM_VERSION"],
            "src_ref": refs.pinned(refs.src_tag, src),
            "stub_ref": refs.pinned(refs.stub_tag, stub),
            "stage_cache": cache,
            "k_codegen": k_codegen_a,
            "index_ref": anchor["index_ref"],
            "codegen_ref": anchor["codegen_ref"],
            "apple_ref": anchor["apple_ref"],
            "compile_prefix": f"{cache}:compile-{k_compile_a}",
            "link_ref": refs.pinned(link_ref_inc, link_sha_inc) if has_link_inc else link_ref_inc,
            "ccache_repo": f"{refs.base}/chromium-ios-ccache",
            "shard_count": str(SHARD_COUNT),
            "shards_json": json.dumps(missing or [0], separators=(",", ":")),
            "shard_keys_json": json.dumps(shard_keys, separators=(",", ":")),
            "compile_matrix_json": json.dumps(compile_matrix, separators=(",", ":")),
            "incremental_mode": "true",
            "anchor_commit": anchor["commit"],
            "expected_graph_sha": idx_data["graph_pruned_sha256"],
            "expected_codegen_sha": idx_data["codegen_targets_sha256"],
            "expected_objects_sha": idx_data["all_objects_sha256"],
            **{f"run_{k}": "true" if v else "false" for k, v in run.items()},
            "k_package": k_package_inc,
        })

        compile_action = (
            "skip (verify_only)"
            if verify_only
            else (
                f"run {len(missing)} shard(s): {missing} "
                f"(reuse {reused_anchor_count} anchor + {reused_chained_count} chained)"
                if missing
                else f"reuse all ({reused_anchor_count} anchor + {reused_chained_count} chained)"
            )
        )
        rows = [
            ("0 SDK stub (Mac)", refs.stub_tag.rsplit(":", 1)[1], "reuse"),
            ("1 Codegen (Linux)", k_codegen_a, f"reuse anchor `{anchor['commit'][:12]}`"),
            ("2 Apple tools (Mac)", k_apple_a, f"reuse anchor `{anchor['commit'][:12]}`"),
            ("2.5 Verify Swift objects (Linux)", k_apple_a, "run" if run["verify_apple_objects"] else "skip (anchor proven)"),
            (f"3 Compile × {SHARD_COUNT} (Linux)", f"inc:{k_compile_a[:12]}", compile_action),
            ("4 Link (Linux)", k_link_inc, "run" if run["link"] else "skip" if (only or verify_only) else "reuse"),
            ("5 Package IPA (Mac)", k_package_inc, "run" if run["package"] else "skip"),
        ]
        summary = [
            "## Build plan (incremental)",
            "",
            f"Chromium `{refs.rev[:12]}` ({lock['CHROMIUM_VERSION']}), "
            f"source `{src[:19]}`, SDK `{stub[:19]}`",
            f"Anchor `{anchor['commit'][:12]}`, changed sources ({len(impact.changed_sources)}): "
            + ", ".join(f"`{s}`" for s in sorted(impact.changed_sources)[:10])
            + (", ..." if len(impact.changed_sources) > 10 else ""),
            f"Affected shards ({len(affected_shards)}): `{affected_shards}`",
            "",
            "| Stage | Key | Action |",
            "| :-- | :-- | :-- |",
        ]
        summary += [f"| {name} | `{key}` | **{action}** |" for name, key, action in rows]
        _emit_summary(summary)
        return

    # Standard plan (either HEAD already has live checkpoints, incremental=false,
    # or incremental failed closed).
    missing = [] if (has_link_h or verify_only) else [i for i in range(SHARD_COUNT) if not exists(f"{compile_prefix_h}-{i}")]
    if only:
        if not (has_codegen_h and has_apple_h):
            sys.exit("::error::A shard rescue needs the codegen and Apple checkpoints; run a full build")
        missing = [i for i in missing if i in only]

    # Automatic backfill when HEAD's codegen+apple are directly live without an index.
    run_index_backfill = False
    if not only and not verify_only:
        candidate_live = has_link_h or (bool(direct_codegen_h) and bool(direct_apple_h))
        if candidate_live and not exists(index_ref_h):
            if direct_codegen_h is None:
                direct_codegen_h = exists(codegen_ref_h)
            if direct_apple_h is None:
                direct_apple_h = exists(apple_ref_h)
            run_index_backfill = bool(direct_codegen_h and direct_apple_h)

    run = {
        "codegen": not has_codegen_h,
        "apple": not has_apple_h,
        "index_backfill": run_index_backfill,
        "verify_apple_objects": True if verify_only else bool(missing),
        "compile": bool(missing) and not verify_only,
        "link": not has_link_h and not only and not verify_only,
        "package": not only and not verify_only,
    }
    shard_keys = [k_compile_h] * SHARD_COUNT
    compile_matrix = (
        [{"shard": i, "key": k_compile_h} for i in missing]
        if missing
        else [{"shard": 0, "key": k_compile_h}]
    )
    write_outputs({
        "chromium_rev": refs.rev,
        "chromium_version": lock["CHROMIUM_VERSION"],
        "src_ref": refs.pinned(refs.src_tag, src),
        "stub_ref": refs.pinned(refs.stub_tag, stub),
        "stage_cache": cache,
        "k_codegen": k_codegen_h,
        "index_ref": index_ref_h,
        "codegen_ref": codegen_ref_h,
        "apple_ref": apple_ref_h,
        "compile_prefix": compile_prefix_h,
        "link_ref": refs.pinned(link_ref_h, link_sha_h) if has_link_h else link_ref_h,
        "ccache_repo": f"{refs.base}/chromium-ios-ccache",
        "shard_count": str(SHARD_COUNT),
        # A placeholder keeps the matrix valid when compile is skipped.
        "shards_json": json.dumps(missing or [0], separators=(",", ":")),
        "shard_keys_json": json.dumps(shard_keys, separators=(",", ":")),
        "compile_matrix_json": json.dumps(compile_matrix, separators=(",", ":")),
        "incremental_mode": "false",
        "anchor_commit": "",
        "expected_graph_sha": "",
        "expected_codegen_sha": "",
        "expected_objects_sha": "",
        **{f"run_{k}": "true" if v else "false" for k, v in run.items()},
        "k_package": k_package_h,
    })

    rows = [
        ("0 SDK stub (Mac)", refs.stub_tag.rsplit(":", 1)[1], "reuse"),
        ("1 Codegen (Linux)", k_codegen_h, "run" if run["codegen"] else "reuse"),
        ("1.5 Graph index backfill (Linux)", k_codegen_h, "run" if run["index_backfill"] else "skip"),
        ("2 Apple tools (Mac)", k_apple_h, "run" if run["apple"] else "reuse"),
        ("2.5 Verify Swift objects (Linux)", k_apple_h, "run" if run["verify_apple_objects"] else "skip"),
        (
            f"3 Compile × {SHARD_COUNT} (Linux)",
            k_compile_h,
            "skip (verify_only)" if verify_only else (f"run {len(missing)} shard(s): {missing}" if missing else "reuse all"),
        ),
        ("4 Link (Linux)", k_link_h, "run" if run["link"] else "skip (shard rescue)" if only else "skip (verify_only)" if verify_only else "reuse"),
        ("5 Package IPA (Mac)", k_package_h, "run" if run["package"] else "skip (shard rescue)" if only else "skip (verify_only)"),
    ]
    summary = [
        "## Build plan",
        "",
        f"Chromium `{refs.rev[:12]}` ({lock['CHROMIUM_VERSION']}), "
        f"source `{src[:19]}`, SDK `{stub[:19]}`",
        "",
        "| Stage | Key | Action |",
        "| :-- | :-- | :-- |",
    ]
    summary += [f"| {name} | `{key}` | **{action}** |" for name, key, action in rows]
    if fallback_reasons:
        summary += ["", "### Incremental fallback reasons", ""]
        summary += [f"- {r}" for r in fallback_reasons[:5]]
    _emit_summary(summary)


def _emit_summary(lines: list[str]) -> None:
    text = "\n".join(lines) + "\n"
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

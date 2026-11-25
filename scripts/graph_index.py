#!/usr/bin/env python3
"""Builds and verifies a compact graph index for incremental CI planning.

Subcommands:
  build   Inspect a pruned `out/Release` Ninja graph (plus `.ninja_deps` and
          optional Apple tool depfiles) and emit a compact `graph_index.json`
          binding graph digests, target object mappings, unsafe implementation
          sources, and Apple-dependent object sources.
  verify  Recompute the pruned graph, codegen target list, and Chrome target
          object list digests on disk and fail closed on any mismatch.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import itertools
import json
import os
import pathlib
import posixpath
import re
import shutil
import subprocess
import sys

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from ninja_graph import Contract, Edge, Graph, deps, is_target_object, unescape  # noqa: E402
import plan_shards  # noqa: E402

SCHEMA_VERSION = 1
IMPLEMENTATION_SUFFIXES = frozenset({".c", ".cc", ".cpp", ".cxx", ".m", ".mm"})
APPLE_GATE_OBJECT = "obj/ios/chrome/browser/web/model/web_internal/chrome_web_client.o"

# Matches #include/#include_next/#import/#embed targeting a C/C++/ObjC/ObjC++
# implementation file (including after a block comment `/* ... */ #include ...`).
INCLUDE_IMPL_PATTERN = (
    r'(^|\*/)[ \t]*#[ \t]*(include|include_next|import|embed)'
    r'[ \t]*[<"]([^>"]+\.(c|cc|cpp|cxx|m|mm))[>"]'
)
INCLUDE_IMPL_RE = re.compile(INCLUDE_IMPL_PATTERN, re.IGNORECASE | re.MULTILINE)
DEPS_HEADER_RE = re.compile(r"^.+: #deps (\d+),")
DEP_TOKEN_SPLIT_RE = re.compile(r"(?<!\\)\s+")
SHA256_HEX_RE = re.compile(r"^[0-9a-f]{64}$")

SRC_SCAN_EXCLUDED_DIRS = frozenset({"out", ".git", "xcode_stub"})
SRC_SCAN_EXCLUDED_PREFIXES = ("third_party/llvm-build",)


def is_impl_path(rel: str) -> bool:
    return pathlib.PurePosixPath(rel).suffix.lower() in IMPLEMENTATION_SUFFIXES


def _out_rel_under_src(out_dir: pathlib.Path, src_dir: pathlib.Path) -> str | None:
    try:
        return out_dir.resolve().relative_to(src_dir.resolve()).as_posix()
    except ValueError:
        return None


def to_src_rel(
    raw_path: str,
    out_dir: pathlib.Path,
    src_dir: pathlib.Path,
    *,
    out_resolved: pathlib.Path | None = None,
    src_resolved: pathlib.Path | None = None,
    out_rel: str | None = None,
) -> str | None:
    """Normalizes a Ninja or depfile path to a POSIX path relative to `src_dir`.

    Accepts both `../../<rel>` paths relative to `out_dir` (rejecting `../../../`
    and paths inside `out_dir`) and absolute paths under `src_dir.resolve()`
    (excluding `out_dir.resolve()`).
    """
    if not raw_path:
        return None
    normalized = raw_path.replace("\\", "/")
    out_res = out_resolved if out_resolved is not None else out_dir.resolve()
    src_res = src_resolved if src_resolved is not None else src_dir.resolve()

    if normalized.startswith("/"):
        p_res = pathlib.Path(os.path.normpath(normalized)).resolve()
        if p_res == out_res or out_res in p_res.parents:
            return None
        if src_res in p_res.parents:
            return p_res.relative_to(src_res).as_posix()
        return None

    norm = posixpath.normpath(normalized)
    if not norm.startswith("../../"):
        return None
    rel = norm[len("../../") :]
    if not rel or rel in (".", "..") or rel.startswith("../"):
        return None
    out_prefix = out_rel if out_rel is not None else _out_rel_under_src(out_res, src_res)
    if out_prefix and (rel == out_prefix or rel.startswith(out_prefix + "/")):
        return None
    return rel


def compute_graph_pruned_sha256(out_dir: pathlib.Path, graph: Graph) -> str:
    out_res = out_dir.resolve()
    rel_files = {p.resolve().relative_to(out_res).as_posix() for p in graph.files}
    rel_files.add("args.gn")
    h = hashlib.sha256()
    for rel in sorted(rel_files):
        fpath = out_res / rel
        if not fpath.is_file():
            raise RuntimeError(f"Missing expected graph file for digest: {fpath}")
        file_sha = hashlib.sha256(fpath.read_bytes()).digest()
        h.update(rel.encode("utf-8") + b"\0" + file_sha + b"\0")
    return h.hexdigest()


def compute_codegen_targets(out_dir: pathlib.Path, root_target: str = "chrome") -> list[str]:
    planned, _ = plan_shards.collect_codegen_targets(out_dir, root_target)
    return planned


def compute_codegen_targets_sha256(planned: list[str]) -> str:
    payload = ("\n".join(planned) + "\n").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def compute_all_objects(ninja_bin: str, out_dir: pathlib.Path, root_target: str = "chrome") -> list[str]:
    commands = plan_shards.run_ninja_tool(ninja_bin, out_dir, "commands", root_target)
    declared = plan_shards.get_declared_targets(ninja_bin, out_dir)
    return [
        obj
        for obj in plan_shards.collect_compile_object_targets(commands)
        if plan_shards._TARGET_OBJECT_RULE_RE.match(declared.get(obj, ""))
    ]


def compute_all_objects_sha256(all_objs: list[str]) -> str:
    payload = ("\n".join(sorted(all_objs)) + "\n").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _scan_codegen_deps(
    ninja_bin: str,
    out_dir: pathlib.Path,
    src_dir: pathlib.Path,
    unsafe_sources: dict[str, set[str]],
) -> int:
    proc = subprocess.run(
        [ninja_bin, "-C", str(out_dir), "-t", "deps"],
        capture_output=True,
        text=True,
        errors="replace",
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ninja -t deps failed (exit {proc.returncode}): {proc.stderr.strip()}")

    out_res = out_dir.resolve()
    src_res = src_dir.resolve()
    out_rel = _out_rel_under_src(out_res, src_res)

    targets_with_deps = 0
    in_active_target = False
    for line in proc.stdout.splitlines():
        if not line:
            in_active_target = False
            continue
        if line[0].isspace():
            if not in_active_target:
                continue
            dep = line.strip()
            rel = to_src_rel(
                dep,
                out_dir,
                src_dir,
                out_resolved=out_res,
                src_resolved=src_res,
                out_rel=out_rel,
            )
            if rel and is_impl_path(rel):
                unsafe_sources[rel].add("codegen_depfile")
        else:
            m = DEPS_HEADER_RE.match(line)
            if m and int(m.group(1)) > 0:
                targets_with_deps += 1
                in_active_target = True
            else:
                in_active_target = False

    if targets_with_deps == 0:
        raise RuntimeError(
            "ninja -t deps reported 0 targets with recorded deps (empty or missing .ninja_deps)"
        )
    return targets_with_deps


def _scan_apple_depfiles(
    apple_cache_dir: pathlib.Path,
    out_dir: pathlib.Path,
    src_dir: pathlib.Path,
    unsafe_sources: dict[str, set[str]],
) -> int:
    if not apple_cache_dir.is_dir():
        raise RuntimeError(f"Apple cache directory does not exist: {apple_cache_dir}")

    out_res = out_dir.resolve()
    src_res = src_dir.resolve()
    out_rel = _out_rel_under_src(out_res, src_res)
    scanned = 0

    for meta_path in sorted(apple_cache_dir.glob("*/meta.json")):
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        files_root = meta_path.parent / "files"
        for rec in meta.get("recorded_paths", []):
            if not isinstance(rec, str) or not rec.endswith(".d"):
                continue
            depfile = files_root / rec
            if not depfile.is_file():
                raise RuntimeError(f"Recorded Apple depfile missing from cache: {depfile}")
            scanned += 1
            raw = depfile.read_text(encoding="utf-8", errors="replace").replace("\\\n", " ")
            for line in raw.splitlines():
                if ":" not in line:
                    continue
                _, deps_part = line.split(":", 1)
                for tok in DEP_TOKEN_SPLIT_RE.split(deps_part.strip()):
                    if not tok:
                        continue
                    unescaped = tok.replace("\\ ", " ")
                    rel = to_src_rel(
                        unescaped,
                        out_dir,
                        src_dir,
                        out_resolved=out_res,
                        src_resolved=src_res,
                        out_rel=out_rel,
                    )
                    if rel and is_impl_path(rel):
                        unsafe_sources[rel].add("apple_depfile")
    return scanned


def _build_suffix_map(sources: set[str]) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    exact_lower: dict[str, set[str]] = collections.defaultdict(set)
    suffix_map: dict[str, set[str]] = collections.defaultdict(set)
    for src in sources:
        if not is_impl_path(src):
            continue
        lower = src.lower()
        exact_lower[lower].add(src)
        parts = lower.split("/")
        for i in range(len(parts)):
            suffix_map["/".join(parts[i:])].add(src)
    return exact_lower, suffix_map


def _record_include_hit(
    enclosing_file: pathlib.Path,
    include_target: str,
    *,
    is_src_tree: bool,
    src_resolved: pathlib.Path,
    exact_lower: dict[str, set[str]],
    suffix_map: dict[str, set[str]],
    unsafe_sources: dict[str, set[str]],
) -> None:
    inc_norm = posixpath.normpath(include_target.replace("\\", "/"))
    if not inc_norm or inc_norm in (".", ".."):
        return

    if is_src_tree:
        try:
            enc_rel = enclosing_file.resolve().relative_to(src_resolved).as_posix()
            enc_dir = posixpath.dirname(enc_rel)
            cand = posixpath.normpath(posixpath.join(enc_dir, inc_norm))
            for src in exact_lower.get(cand.lower(), ()):
                unsafe_sources[src].add("included_by_source")
        except ValueError:
            pass

    tail = inc_norm
    while tail.startswith("../"):
        tail = tail[3:]
    tail = tail.lstrip("/")
    if tail and tail not in (".", ".."):
        for src in suffix_map.get(tail.lower(), ()):
            unsafe_sources[src].add("included_by_source")


def _scan_includes_with_rg(
    rg_bin: str,
    scan_root: pathlib.Path,
    *,
    is_src_tree: bool,
    src_resolved: pathlib.Path,
    exact_lower: dict[str, set[str]],
    suffix_map: dict[str, set[str]],
    unsafe_sources: dict[str, set[str]],
) -> None:
    cmd = [
        rg_bin,
        "--no-config",
        "--no-ignore",
        "--hidden",
        "--null",
        "--no-heading",
        "--with-filename",
        "--color=never",
        "-i",
    ]
    if is_src_tree:
        cmd.extend([
            "--glob", "!/out/**",
            "--glob", "!/.git/**",
            "--glob", "!/xcode_stub/**",
            "--glob", "!/third_party/llvm-build/**",
        ])
    cmd.extend(["-e", INCLUDE_IMPL_PATTERN, "."])

    proc = subprocess.run(cmd, cwd=scan_root, capture_output=True)
    if proc.returncode not in (0, 1):
        err = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"rg failed on {scan_root} (exit {proc.returncode}): {err}")

    for raw_line in proc.stdout.splitlines():
        if not raw_line or b"\0" not in raw_line:
            continue
        file_bytes, match_bytes = raw_line.split(b"\0", 1)
        enclosing = scan_root / os.fsdecode(file_bytes)
        text = match_bytes.decode("utf-8", errors="replace")
        for m in INCLUDE_IMPL_RE.finditer(text):
            _record_include_hit(
                enclosing,
                m.group(3),
                is_src_tree=is_src_tree,
                src_resolved=src_resolved,
                exact_lower=exact_lower,
                suffix_map=suffix_map,
                unsafe_sources=unsafe_sources,
            )


def _scan_includes_python(
    scan_root: pathlib.Path,
    *,
    is_src_tree: bool,
    src_resolved: pathlib.Path,
    exact_lower: dict[str, set[str]],
    suffix_map: dict[str, set[str]],
    unsafe_sources: dict[str, set[str]],
) -> None:
    root_res = scan_root.resolve()
    for dirpath, dirnames, filenames in os.walk(root_res, followlinks=False):
        if is_src_tree:
            rel_dir = pathlib.Path(dirpath).relative_to(root_res).as_posix()
            kept_dirs: list[str] = []
            for d in dirnames:
                if rel_dir == "." and d in SRC_SCAN_EXCLUDED_DIRS:
                    continue
                child_rel = d if rel_dir == "." else f"{rel_dir}/{d}"
                if any(
                    child_rel == pref or child_rel.startswith(pref + "/")
                    for pref in SRC_SCAN_EXCLUDED_PREFIXES
                ):
                    continue
                kept_dirs.append(d)
            dirnames[:] = kept_dirs

        for fname in filenames:
            fpath = pathlib.Path(dirpath) / fname
            if fpath.is_symlink() or not fpath.is_file():
                continue
            try:
                data = fpath.read_bytes()
            except OSError:
                continue
            if b"\x00" in data[:8192]:
                continue
            text = data.decode("utf-8", errors="replace")
            for m in INCLUDE_IMPL_RE.finditer(text):
                _record_include_hit(
                    fpath,
                    m.group(3),
                    is_src_tree=is_src_tree,
                    src_resolved=src_resolved,
                    exact_lower=exact_lower,
                    suffix_map=suffix_map,
                    unsafe_sources=unsafe_sources,
                )


def _scan_included_sources(
    src_dir: pathlib.Path,
    gen_dir: pathlib.Path,
    mapped_sources: set[str],
    unsafe_sources: dict[str, set[str]],
    *,
    require_rg: bool,
) -> None:
    exact_lower, suffix_map = _build_suffix_map(mapped_sources)
    if not suffix_map:
        return

    src_res = src_dir.resolve()
    rg_bin = shutil.which("rg")
    if require_rg and not rg_bin:
        raise RuntimeError("rg (ripgrep) is required (--require-rg) but was not found on PATH")

    scan_roots: list[tuple[pathlib.Path, bool]] = []
    if src_res.is_dir():
        scan_roots.append((src_res, True))
    if gen_dir.is_dir():
        scan_roots.append((gen_dir.resolve(), False))

    for scan_root, is_src_tree in scan_roots:
        if rg_bin:
            _scan_includes_with_rg(
                rg_bin,
                scan_root,
                is_src_tree=is_src_tree,
                src_resolved=src_res,
                exact_lower=exact_lower,
                suffix_map=suffix_map,
                unsafe_sources=unsafe_sources,
            )
        else:
            _scan_includes_python(
                scan_root,
                is_src_tree=is_src_tree,
                src_resolved=src_res,
                exact_lower=exact_lower,
                suffix_map=suffix_map,
                unsafe_sources=unsafe_sources,
            )


def _compute_apple_object_sources(
    contract: Contract,
    chrome_order: list[str],
    all_objs: list[str],
    out_dir: pathlib.Path,
    src_dir: pathlib.Path,
) -> list[str]:
    apple_edges = contract.apple_edges(chrome_order)
    apple_nodes = {o for e in apple_edges for o in itertools.chain(e.outs, e.iouts)}

    # Reverse-BFS over the chrome dependency closure: O(V + E) and cycle-safe
    # even on malformed graphs; validations do not supply build inputs.
    rev_deps: dict[str, list[str]] = collections.defaultdict(list)
    for node in chrome_order:
        e = contract.edge(node)
        if e is None:
            continue
        for child in deps(e):
            rev_deps[child].append(node)

    reaches_apple: set[str] = set(apple_nodes)
    queue = collections.deque(apple_nodes)
    while queue:
        cur = queue.popleft()
        for parent in rev_deps.get(cur, ()):
            if parent not in reaches_apple:
                reaches_apple.add(parent)
                queue.append(parent)

    out_res = out_dir.resolve()
    src_res = src_dir.resolve()
    out_rel = _out_rel_under_src(out_res, src_res)
    all_objs_set = set(all_objs)

    apple_objs: set[str] = set()
    for obj in all_objs:
        raw = contract.raw_of.get(obj)
        if raw is not None and raw in reaches_apple:
            apple_objs.add(obj)
    if APPLE_GATE_OBJECT in all_objs_set:
        apple_objs.add(APPLE_GATE_OBJECT)

    sources: set[str] = set()
    for obj in apple_objs:
        raw = contract.raw_of.get(obj)
        edge = contract.edge(raw) if raw is not None else None
        if edge is None:
            continue
        for inp in edge.ins:
            rel = to_src_rel(
                unescape(inp),
                out_dir,
                src_dir,
                out_resolved=out_res,
                src_resolved=src_res,
                out_rel=out_rel,
            )
            if rel:
                sources.add(rel)
    return sorted(sources)


def build_index(
    *,
    out_dir: pathlib.Path,
    ninja_bin: str,
    k_codegen: str,
    src_ref: str,
    stub_ref: str,
    shard_count: int,
    src_dir: pathlib.Path | None = None,
    apple_cache_dir: pathlib.Path | None = None,
    require_rg: bool = False,
    root_target: str = "chrome",
) -> dict:
    out_res = out_dir.resolve()
    src_res = src_dir.resolve() if src_dir is not None else out_res.parent.parent.resolve()
    out_rel = _out_rel_under_src(out_res, src_res)

    graph = Graph(out_res)
    contract = Contract(graph)
    chrome_raw = contract.raw_of.get(root_target, root_target)
    if chrome_raw not in graph.producer:
        raise RuntimeError(f"Root target {root_target!r} missing from Ninja graph in {out_res}")

    graph_pruned_sha = compute_graph_pruned_sha256(out_res, graph)
    planned_codegen = compute_codegen_targets(out_res, root_target)
    if not planned_codegen:
        raise RuntimeError("Codegen target plan is empty")
    missing_codegen = [p for p in planned_codegen if p not in contract.raw_of]
    if missing_codegen:
        raise RuntimeError(f"Codegen targets missing from Ninja graph: {missing_codegen[:5]}")
    codegen_targets_sha = compute_codegen_targets_sha256(planned_codegen)

    all_objs = compute_all_objects(ninja_bin, out_res, root_target)
    if not all_objs:
        raise RuntimeError("No target object compiles found in chrome graph")
    all_objs_sha = compute_all_objects_sha256(all_objs)

    chrome_parent, chrome_order = contract.closure([chrome_raw])
    codegen_parent, _ = contract.closure([contract.raw_of[p] for p in planned_codegen])
    codegen_set = set(codegen_parent)

    has_ninja_validations = any(
        edge.vins
        for node in itertools.chain(chrome_parent, codegen_parent)
        if (edge := contract.edge(node)) is not None
    )

    source_to_objects: dict[str, set[str]] = collections.defaultdict(set)
    unsafe_sources: dict[str, set[str]] = collections.defaultdict(set)
    all_objs_set = set(all_objs)

    def _edge_src_rels(edge: Edge, nodes) -> list[str]:
        rels: list[str] = []
        for inp in nodes:
            rel = to_src_rel(
                unescape(inp),
                out_res,
                src_res,
                out_resolved=out_res,
                src_resolved=src_res,
                out_rel=out_rel,
            )
            if rel:
                rels.append(rel)
        return rels

    for obj in all_objs:
        raw = contract.raw_of.get(obj)
        edge = contract.edge(raw) if raw is not None else None
        if (
            edge is None
            or not is_target_object(edge)
            or len(edge.outs) != 1
            or edge.iouts
            or unescape(edge.outs[0]) != obj
        ):
            if edge is not None:
                for rel in _edge_src_rels(
                    edge, itertools.chain(edge.ins, edge.iins, edge.oins, edge.vins)
                ):
                    if is_impl_path(rel):
                        unsafe_sources[rel].add("malformed_object_edge")
            continue
        for rel in _edge_src_rels(edge, edge.ins):
            source_to_objects[rel].add(obj)

    for node in chrome_order:
        edge = contract.edge(node)
        if edge is not None and is_target_object(edge):
            outs = [unescape(o) for o in itertools.chain(edge.outs, edge.iouts)]
            if any(o not in all_objs_set for o in outs):
                for rel in _edge_src_rels(
                    edge, itertools.chain(edge.ins, edge.iins, edge.oins, edge.vins)
                ):
                    if is_impl_path(rel):
                        unsafe_sources[rel].add("unsharded_chrome_object")

    for edge in graph.edges:
        is_clean_target_obj = (
            is_target_object(edge)
            and len(edge.outs) == 1
            and not edge.iouts
            and unescape(edge.outs[0]).endswith(".o")
        )
        in_codegen = any(o in codegen_set for o in itertools.chain(edge.outs, edge.iouts))

        for rel in _edge_src_rels(edge, edge.ins):
            if not is_impl_path(rel):
                continue
            if not is_clean_target_obj:
                unsafe_sources[rel].add("non_target_edge")
            if in_codegen:
                unsafe_sources[rel].add("in_codegen_closure")

        for rel in _edge_src_rels(edge, itertools.chain(edge.iins, edge.oins, edge.vins)):
            if not is_impl_path(rel):
                continue
            unsafe_sources[rel].add("implicit_or_order_input")
            if not is_clean_target_obj:
                unsafe_sources[rel].add("non_target_edge")
            if in_codegen:
                unsafe_sources[rel].add("in_codegen_closure")

    _scan_codegen_deps(ninja_bin, out_res, src_res, unsafe_sources)
    if apple_cache_dir is not None:
        _scan_apple_depfiles(apple_cache_dir, out_res, src_res, unsafe_sources)
    _scan_included_sources(
        src_res,
        out_res / "gen",
        set(source_to_objects.keys()),
        unsafe_sources,
        require_rg=require_rg,
    )

    apple_object_sources = _compute_apple_object_sources(
        contract, chrome_order, all_objs, out_res, src_res
    )

    return {
        "schema_version": SCHEMA_VERSION,
        "k_codegen": k_codegen,
        "src_ref": src_ref,
        "stub_ref": stub_ref,
        "shard_count": shard_count,
        "graph_pruned_sha256": graph_pruned_sha,
        "codegen_targets_sha256": codegen_targets_sha,
        "all_objects_sha256": all_objs_sha,
        "has_ninja_validations": has_ninja_validations,
        "source_to_objects": {k: sorted(v) for k, v in sorted(source_to_objects.items())},
        "unsafe_sources": {k: sorted(v) for k, v in sorted(unsafe_sources.items())},
        "apple_object_sources": apple_object_sources,
    }


def verify_graph(
    *,
    out_dir: pathlib.Path,
    ninja_bin: str,
    expected_graph_sha: str,
    expected_codegen_sha: str,
    expected_objects_sha: str,
    root_target: str = "chrome",
) -> list[str]:
    problems: list[str] = []
    for label, val in (
        ("expected_graph_sha", expected_graph_sha),
        ("expected_codegen_sha", expected_codegen_sha),
        ("expected_objects_sha", expected_objects_sha),
    ):
        if not SHA256_HEX_RE.fullmatch(val or ""):
            problems.append(f"Invalid {label}: {val!r}")
    if problems:
        return problems

    out_res = out_dir.resolve()
    graph = Graph(out_res)
    actual_graph_sha = compute_graph_pruned_sha256(out_res, graph)
    actual_codegen_sha = compute_codegen_targets_sha256(
        compute_codegen_targets(out_res, root_target)
    )
    actual_objects_sha = compute_all_objects_sha256(
        compute_all_objects(ninja_bin, out_res, root_target)
    )

    for name, expected, actual in (
        ("graph_pruned_sha256", expected_graph_sha, actual_graph_sha),
        ("codegen_targets_sha256", expected_codegen_sha, actual_codegen_sha),
        ("all_objects_sha256", expected_objects_sha, actual_objects_sha),
    ):
        if actual != expected:
            problems.append(f"{name} mismatch: expected {expected}, got {actual}")
    return problems


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="Build graph_index.json from pruned out/Release")
    b.add_argument("--out-dir", type=pathlib.Path, required=True)
    b.add_argument("--ninja", default="ninja")
    b.add_argument("--src-dir", type=pathlib.Path, default=None)
    b.add_argument("--k-codegen", required=True)
    b.add_argument("--src-ref", required=True)
    b.add_argument("--stub-ref", required=True)
    b.add_argument("--shard-count", type=int, default=18)
    b.add_argument("--apple-cache-dir", type=pathlib.Path, default=None)
    b.add_argument("--require-rg", action="store_true")
    b.add_argument("--root-target", default="chrome")
    b.add_argument("--output", type=pathlib.Path, required=True)

    v = sub.add_parser("verify", help="Verify pruned out/Release against expected index digests")
    v.add_argument("--out-dir", type=pathlib.Path, required=True)
    v.add_argument("--ninja", default="ninja")
    v.add_argument("--expected-graph-sha", required=True)
    v.add_argument("--expected-codegen-sha", required=True)
    v.add_argument("--expected-objects-sha", required=True)
    v.add_argument("--root-target", default="chrome")

    args = ap.parse_args(argv)
    try:
        if args.cmd == "build":
            index = build_index(
                out_dir=args.out_dir,
                ninja_bin=args.ninja,
                k_codegen=args.k_codegen,
                src_ref=args.src_ref,
                stub_ref=args.stub_ref,
                shard_count=args.shard_count,
                src_dir=args.src_dir,
                apple_cache_dir=args.apple_cache_dir,
                require_rg=args.require_rg,
                root_target=args.root_target,
            )
            payload = json.dumps(index, separators=(",", ":"), sort_keys=True)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(payload, encoding="utf-8")
            print(
                f"==> Built graph index {args.output} ({len(payload)} bytes): "
                f"{len(index['source_to_objects'])} sources, "
                f"{len(index['unsafe_sources'])} unsafe, "
                f"{len(index['apple_object_sources'])} apple-dependent, "
                f"validations={index['has_ninja_validations']}"
            )
            return 0

        problems = verify_graph(
            out_dir=args.out_dir,
            ninja_bin=args.ninja,
            expected_graph_sha=args.expected_graph_sha,
            expected_codegen_sha=args.expected_codegen_sha,
            expected_objects_sha=args.expected_objects_sha,
            root_target=args.root_target,
        )
        if problems:
            for p in problems:
                print(f"::error::Graph index verification failed: {p}")
            return 1
        print(
            f"==> Verified pruned graph digests match anchor "
            f"(graph={args.expected_graph_sha[:12]}, "
            f"codegen={args.expected_codegen_sha[:12]}, "
            f"objects={args.expected_objects_sha[:12]})"
        )
        return 0
    except Exception as exc:
        print(f"::error::graph_index.py {args.cmd} failed: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())

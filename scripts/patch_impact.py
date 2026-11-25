#!/usr/bin/env python3
"""Strict fail-closed patch delta analyzer for incremental CI planning.

Compares `patches/` between an anchor git commit `A` and the current working
tree `H`, accepting only pure implementation edits (`.c/.cc/.cpp/.cxx/.m/.mm`)
verified against `git apply -p1 --numstat -z` and returning per-source ordered
patch sections across the full active `patches/series` queue.
"""

from __future__ import annotations

import dataclasses
import os
import pathlib
import posixpath
import re
import subprocess

IMPLEMENTATION_SUFFIXES = frozenset({".c", ".cc", ".cpp", ".cxx", ".m", ".mm"})
DENY_BASENAME_TOKENS = ("_inl.", "-inl.", "_inc.", "-inc.", ".inl.", ".inc.")

SERIES_ENTRY_RE = re.compile(r"^[A-Za-z0-9_.-]+\.patch$")
PATCH_SECTION_RE = re.compile(rb"(?m)(?=^diff --git )")
PATCH_HEADER_RE = re.compile(rb"^diff --git a/([A-Za-z0-9_./+-]+) b/\1$")
FORM_A_INDEX_RE = re.compile(rb"^index [0-9a-f]+\.\.[0-9a-f]+ 100644$")
FORM_B_INDEX_RE = re.compile(rb"^index 0+\.\.[0-9a-f]+$")

BARE_PREPROC_CONT_RE = re.compile(rb"(?:^|\*/)[ \t]*#[ \t]*\\[ \t]*$")
INCLUDE_DIRECTIVE_RE = re.compile(
    rb"(?:^|\*/)[ \t]*#[ \t]*(?:include|include_next|import|embed)\b", re.IGNORECASE
)
STRICT_INCLUDE_TAIL_RE = re.compile(
    rb'^[ \t]*(?:<([^>\r\n\\]+)>|"([^"\r\n\\]+)")[ \t]*(?://.*|/\*(?:[^*]|\*(?!/))*\*/[ \t]*)?$'
)


class UseStandardPlan(ValueError):
    """Raised when a patch change is outside incremental pure-implementation scope."""


@dataclasses.dataclass(frozen=True)
class PatchImpact:
    changed_sources: frozenset[str]
    ordered_sections: dict[str, list[tuple[str, bytes]]]


def parse_series(raw: bytes) -> list[str]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise UseStandardPlan("patches/series is not valid UTF-8") from exc

    entries: list[str] = []
    seen: set[str] = set()
    for line in text.splitlines():
        entry = line.split("#", 1)[0].strip()
        if not entry:
            continue
        if not SERIES_ENTRY_RE.fullmatch(entry):
            raise UseStandardPlan(f"Invalid entry in patches/series: {entry!r}")
        if entry in seen:
            raise UseStandardPlan(f"Duplicate entry in patches/series: {entry}")
        seen.add(entry)
        entries.append(entry)
    return entries


def applied_paths(patch_bytes: bytes, cwd: pathlib.Path) -> list[bytes]:
    """Query git's production patch parser for destination paths without applying."""
    result = subprocess.run(
        ["git", "apply", "-p1", "--numstat", "-z"],
        input=patch_bytes,
        cwd=cwd,
        capture_output=True,
    )
    if result.returncode != 0:
        raise UseStandardPlan("git apply could not parse patch")
    stdout = result.stdout
    if not stdout:
        return []
    if not stdout.endswith(b"\0"):
        raise UseStandardPlan("Unexpected non-NUL-terminated output from git apply --numstat -z")
    paths: list[bytes] = []
    for raw_rec in stdout[:-1].split(b"\0"):
        parts = raw_rec.split(b"\t", 2)
        if len(parts) != 3 or parts[0] == b"-" or parts[1] == b"-" or not parts[2]:
            raise UseStandardPlan("git apply reported binary, rename, or unsupported file record")
        paths.append(parts[2])
    if len(set(paths)) != len(paths):
        raise UseStandardPlan("Patch modifies the same destination path more than once")
    return paths


def parse_patch_sections(
    patch_bytes: bytes, cwd: pathlib.Path
) -> tuple[bytes, list[tuple[bytes, bytes]]]:
    """Splits a patch into (preamble, [(git_path, section_bytes), ...]) verified by git apply.

    Intentionally does NOT enforce Form A/B headers so unchanged stacked patches
    (including non-impl, index-less, or newly-created files) are extracted safely.
    """
    parts = PATCH_SECTION_RE.split(patch_bytes)
    preamble = parts[0]
    sections = parts[1:]
    paths = applied_paths(patch_bytes, cwd)
    if len(paths) != len(sections):
        raise UseStandardPlan(
            "git apply sees a different set of file edits than the diff --git sections"
        )
    paired: list[tuple[bytes, bytes]] = []
    for sec, git_path in zip(sections, paths):
        if applied_paths(sec, cwd) != [git_path]:
            raise UseStandardPlan(
                "A patch section does not map cleanly to one file in git apply"
            )
        paired.append((git_path, sec))
    return preamble, paired


def _validate_new_patch_preamble(preamble: bytes, patch_name: str) -> None:
    for line in preamble.splitlines():
        if (
            line.startswith((b"--- ", b"+++ ", b"@@ ", b"literal ", b"delta "))
            or line == b"GIT binary patch"
        ):
            raise UseStandardPlan(
                f"Appended patch {patch_name} contains suspicious diff markers in preamble"
            )


def _validate_impl_path(raw_path: bytes) -> str:
    name = raw_path.decode("ascii")
    if posixpath.normpath(name) != name or name.startswith(("/", "../")) or name in (".", ".."):
        raise UseStandardPlan(f"Patch path is not normalized and relative to src/: {name}")
    if pathlib.PurePosixPath(name).suffix not in IMPLEMENTATION_SUFFIXES:
        raise UseStandardPlan(f"Changed input is outside implementation-only scope: {name}")
    base_lower = posixpath.basename(name).lower()
    if any(tok in base_lower for tok in DENY_BASENAME_TOKENS):
        raise UseStandardPlan(f"Changed source matches include-style basename deny-list: {name}")
    return name


def validate_changed_section(sec: bytes, git_path: bytes) -> tuple[str, str, list[bytes]]:
    """Validates a modified/added/removed section against strict Form A or Form B.

    Returns (form, rel_name, hunk_lines) where `form` is "A" or "B" and
    `hunk_lines` starts at the first `@@ ` line.
    """
    lines = sec.split(b"\n")
    if len(lines) < 4:
        raise UseStandardPlan("Patch section is truncated")
    header_match = PATCH_HEADER_RE.fullmatch(lines[0])
    if header_match is None or header_match.group(1) != git_path:
        raise UseStandardPlan("Patch section changes a path, renames a file, or uses unsupported chars")
    path = header_match.group(1)

    form = ""
    hunk_start = -1
    if lines[1] == b"new file mode 100644":
        idx = 2
        if idx < len(lines) and FORM_B_INDEX_RE.fullmatch(lines[idx]):
            idx += 1
        if (
            idx + 2 < len(lines)
            and lines[idx] == b"--- /dev/null"
            and lines[idx + 1] == b"+++ b/" + path
            and lines[idx + 2].startswith(b"@@ ")
        ):
            form = "B"
            hunk_start = idx + 2
    else:
        idx = 1
        if idx < len(lines) and FORM_A_INDEX_RE.fullmatch(lines[idx]):
            idx += 1
        if (
            idx + 2 < len(lines)
            and lines[idx] == b"--- a/" + path
            and lines[idx + 1] == b"+++ b/" + path
            and lines[idx + 2].startswith(b"@@ ")
        ):
            form = "A"
            hunk_start = idx + 2

    if not form:
        raise UseStandardPlan(
            f"Patch section for {path.decode('ascii', 'replace')} is not a plain text Form A/B edit"
        )
    rel_name = _validate_impl_path(path)
    return form, rel_name, lines[hunk_start:]


def check_added_hunk_includes(hunk_lines: list[bytes], source_name: str) -> None:
    """Rejects added `#include`/`#import`/`#embed` lines targeting impl files or macros."""
    for raw_line in hunk_lines[1:]:
        if not raw_line.startswith(b"+"):
            continue
        body = raw_line[1:].rstrip(b"\r")
        if BARE_PREPROC_CONT_RE.search(body):
            raise UseStandardPlan(
                f"Added preprocessor line continuation in {source_name}"
            )
        for m in INCLUDE_DIRECTIVE_RE.finditer(body):
            tail = body[m.end() :]
            tm = STRICT_INCLUDE_TAIL_RE.match(tail)
            if tm is None:
                raise UseStandardPlan(
                    f"Added non-literal or macro #include/#import/#embed directive in {source_name}"
                )
            inc_bytes = tm.group(1) or tm.group(2)
            inc_str = inc_bytes.decode("utf-8", errors="replace").replace("\\", "/")
            inc_lower = inc_str.lower()
            if pathlib.PurePosixPath(inc_lower).suffix in IMPLEMENTATION_SUFFIXES:
                raise UseStandardPlan(
                    f"Added implementation-file include {inc_str!r} in {source_name}"
                )
            base_lower = posixpath.basename(inc_lower)
            if any(tok in base_lower for tok in DENY_BASENAME_TOKENS):
                raise UseStandardPlan(
                    f"Added include-style file {inc_str!r} in {source_name}"
                )


def _git_ls_tree_blobs(root: pathlib.Path, commit: str, path: str) -> dict[str, str]:
    """Lists regular blob entries under `path` at `commit`; rejects symlinks/submodules."""
    proc = subprocess.run(
        ["git", "ls-tree", "-r", "-z", commit, "--", path],
        cwd=root,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise UseStandardPlan(f"git ls-tree failed at {commit} for {path}")
    entries: dict[str, str] = {}
    for rec in proc.stdout.split(b"\0"):
        if not rec:
            continue
        meta, rel_bytes = rec.split(b"\t", 1)
        mode, obj_type, oid = meta.decode("ascii").split(" ", 2)
        rel = rel_bytes.decode("utf-8")
        if mode not in ("100644", "100755") or obj_type != "blob":
            raise UseStandardPlan(
                f"Unsupported git entry {mode} {obj_type} at {commit}:{rel}"
            )
        entries[rel] = oid
    return entries


def _git_read_blobs(root: pathlib.Path, oids: list[str]) -> dict[str, bytes]:
    if not oids:
        return {}
    unique_oids = list(dict.fromkeys(oids))
    proc = subprocess.run(
        ["git", "cat-file", "--batch"],
        input=("\n".join(unique_oids) + "\n").encode("ascii"),
        cwd=root,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise UseStandardPlan("git cat-file --batch failed reading baseline patches")
    buf = proc.stdout
    pos = 0
    out: dict[str, bytes] = {}
    for oid in unique_oids:
        nl = buf.index(b"\n", pos)
        header = buf[pos:nl].decode("ascii").split(" ")
        if len(header) != 3 or header[1] != "blob":
            raise UseStandardPlan(f"Unexpected git cat-file header for {oid}: {header}")
        size = int(header[2])
        start = nl + 1
        end = start + size
        out[oid] = buf[start:end]
        pos = end + 1  # trailing LF after blob payload
    return out


def _walk_working_patches(root: pathlib.Path) -> dict[str, pathlib.Path]:
    patches_dir = root / "patches"
    if patches_dir.is_symlink() or not patches_dir.is_dir():
        raise UseStandardPlan("Working tree patches/ is missing or a symlink")
    files: dict[str, pathlib.Path] = {}
    for dirpath, dirnames, filenames in os.walk(patches_dir, followlinks=False):
        dp = pathlib.Path(dirpath)
        for d in dirnames:
            if (dp / d).is_symlink():
                raise UseStandardPlan(f"Symlink directory under patches/: {dp / d}")
        for f in filenames:
            fp = dp / f
            if fp.is_symlink() or not fp.is_file():
                raise UseStandardPlan(f"Symlink or non-regular file under patches/: {fp}")
            rel = fp.relative_to(root).as_posix()
            files[rel] = fp
    return files


def analyze(anchor_commit: str, root: pathlib.Path) -> PatchImpact:
    """Compares `patches/` between git commit `anchor_commit` and working tree `root`."""
    tree_a = _git_ls_tree_blobs(root, anchor_commit, "patches")
    files_h = _walk_working_patches(root)

    if "patches/series" not in tree_a or "patches/series" not in files_h:
        raise UseStandardPlan("Missing patches/series in anchor or working tree")

    blobs_a = _git_read_blobs(root, list(tree_a.values()))
    bytes_a = {rel: blobs_a[oid] for rel, oid in tree_a.items()}
    bytes_h = {rel: path.read_bytes() for rel, path in files_h.items()}

    series_a = parse_series(bytes_a["patches/series"])
    series_h = parse_series(bytes_h["patches/series"])
    if len(series_h) < len(series_a) or series_h[: len(series_a)] != series_a:
        raise UseStandardPlan("patches/series reordered or deleted baseline patches")

    def _top_level_patches(rel_paths: set[str]) -> set[str]:
        out: set[str] = set()
        for rel in rel_paths:
            if not rel.startswith("patches/"):
                continue
            rest = rel[len("patches/") :]
            if "/" not in rest and rest.endswith(".patch"):
                out.add(rest)
        return out

    if _top_level_patches(set(bytes_a)) != set(series_a):
        raise UseStandardPlan("Anchor patches/ contains unlisted or missing active .patch files")
    if _top_level_patches(set(bytes_h)) != set(series_h):
        raise UseStandardPlan("Working tree patches/ contains unlisted or missing active .patch files")

    active_h_rels = {"patches/series"} | {f"patches/{name}" for name in series_h}
    for rel in sorted((set(bytes_a) | set(bytes_h)) - active_h_rels):
        if rel not in bytes_a or rel not in bytes_h or bytes_a[rel] != bytes_h[rel]:
            raise UseStandardPlan(f"Non-active file under patches/ changed: {rel}")

    changed_sources: set[str] = set()
    parsed_h_cache: dict[str, list[tuple[bytes, bytes]]] = {}

    for name in series_a:
        rel = f"patches/{name}"
        old_data = bytes_a[rel]
        new_data = bytes_h[rel]
        if old_data == new_data:
            continue
        old_pre, old_secs = parse_patch_sections(old_data, root)
        new_pre, new_secs = parse_patch_sections(new_data, root)
        parsed_h_cache[name] = new_secs
        if old_pre != new_pre:
            raise UseStandardPlan(f"Patch preamble changed in {name}")

        old_map = dict(old_secs)
        new_map = dict(new_secs)
        for path_bytes in sorted(set(old_map) | set(new_map)):
            in_old = path_bytes in old_map
            in_new = path_bytes in new_map
            if in_old and in_new and old_map[path_bytes] == new_map[path_bytes]:
                continue
            if in_old and in_new:
                form_old, src_old, _ = validate_changed_section(old_map[path_bytes], path_bytes)
                form_new, src_new, hunk_lines = validate_changed_section(
                    new_map[path_bytes], path_bytes
                )
                if form_old != form_new or src_old != src_new:
                    raise UseStandardPlan(
                        f"Patch section changed form (A<->B) or path for {src_old} in {name}"
                    )
                check_added_hunk_includes(hunk_lines, src_new)
                changed_sources.add(src_new)
            elif in_new:
                form_new, src_new, hunk_lines = validate_changed_section(
                    new_map[path_bytes], path_bytes
                )
                if form_new != "A":
                    raise UseStandardPlan(
                        f"Adding a new-file (Form B) section for {src_new} in {name} requires full build"
                    )
                check_added_hunk_includes(hunk_lines, src_new)
                changed_sources.add(src_new)
            else:
                form_old, src_old, _ = validate_changed_section(old_map[path_bytes], path_bytes)
                if form_old != "A":
                    raise UseStandardPlan(
                        f"Removing a new-file (Form B) section for {src_old} in {name} requires full build"
                    )
                changed_sources.add(src_old)

    for name in series_h[len(series_a) :]:
        rel = f"patches/{name}"
        if rel in bytes_a:
            raise UseStandardPlan(f"Appended patch {name} already existed in anchor")
        new_data = bytes_h[rel]
        new_pre, new_secs = parse_patch_sections(new_data, root)
        _validate_new_patch_preamble(new_pre, name)
        if not new_secs:
            raise UseStandardPlan(f"Appended patch {name} contains no file edits")
        parsed_h_cache[name] = new_secs
        for path_bytes, sec in new_secs:
            form_new, src_new, hunk_lines = validate_changed_section(sec, path_bytes)
            if form_new != "A":
                raise UseStandardPlan(
                    f"Appended patch {name} creates a new file {src_new}; requires full build"
                )
            check_added_hunk_includes(hunk_lines, src_new)
            changed_sources.add(src_new)

    if not changed_sources:
        raise UseStandardPlan("No implementation edits found in active patches")

    ordered_sections: dict[str, list[tuple[str, bytes]]] = {s: [] for s in changed_sources}
    need_bytes = {s.encode("ascii"): s for s in changed_sources}

    for name in series_h:
        data = bytes_h[f"patches/{name}"]
        if name in parsed_h_cache:
            secs = parsed_h_cache[name]
        else:
            if not any(tb in data for tb in need_bytes):
                continue
            _, secs = parse_patch_sections(data, root)
        for path_bytes, sec in secs:
            src = need_bytes.get(path_bytes)
            if src is not None:
                ordered_sections[src].append((name, sec))

    return PatchImpact(
        changed_sources=frozenset(changed_sources),
        ordered_sections=ordered_sections,
    )

"""Unit tests for scripts/patch_impact.py."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPTS_DIR = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import patch_impact  # noqa: E402
from patch_impact import (  # noqa: E402
    UseStandardPlan,
    analyze,
    check_added_hunk_includes,
    parse_patch_sections,
    parse_series,
    validate_changed_section,
)

SRC_A = "ios/example/client.cc"
SRC_B = "ios/example/helper.mm"
SRC_H = "ios/example/client.h"


def make_form_a(
    path: str,
    old_line: str = "old",
    new_line: str = "new",
    *,
    with_index: bool = True,
) -> bytes:
    lines = [f"diff --git a/{path} b/{path}"]
    if with_index:
        lines.append("index 1111111..2222222 100644")
    lines += [
        f"--- a/{path}",
        f"+++ b/{path}",
        "@@ -1 +1 @@",
        f"-{old_line}",
        f"+{new_line}",
    ]
    return ("\n".join(lines) + "\n").encode()


def make_form_b(
    path: str,
    body_lines: list[str] | None = None,
    *,
    with_index: bool = True,
) -> bytes:
    body = body_lines if body_lines is not None else ["int value() { return 1; }"]
    lines = [f"diff --git a/{path} b/{path}", "new file mode 100644"]
    if with_index:
        lines.append("index 0000000..abcdef1")
    lines += [
        "--- /dev/null",
        f"+++ b/{path}",
        f"@@ -0,0 +1,{len(body)} @@",
        *[f"+{ln}" for ln in body],
    ]
    return ("\n".join(lines) + "\n").encode()


def init_patch_repo(tmp: pathlib.Path, files: dict[str, bytes]) -> str:
    subprocess.run(["git", "init", "-q"], cwd=tmp, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=tmp, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=tmp, check=True)
    for rel, content in files.items():
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(content)
    subprocess.run(["git", "add", "-A"], cwd=tmp, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "anchor"], cwd=tmp, check=True)
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=tmp, text=True).strip()


class PatchImpactUnitTests(unittest.TestCase):
    def test_parse_series_valid_and_invalid(self):
        self.assertEqual(
            parse_series(b"# comment\n0001-foo.patch\n  0002_bar.patch # inline\n\n"),
            ["0001-foo.patch", "0002_bar.patch"],
        )
        for bad in (
            b"0001 foo.patch\n",
            b"../escape.patch\n",
            b"sub/0001.patch\n",
            b"'0001.patch'\n",
            b"0001.txt\n",
            b"0001.patch\n0001.patch\n",
            b"\xff\xfe",
        ):
            with self.subTest(bad=bad):
                with self.assertRaises(UseStandardPlan):
                    parse_series(bad)

    def test_pure_impl_edit_in_mixed_patch_and_indexless_form_a(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            gn = make_form_a("ios/example/BUILD.gn", with_index=False)
            hdr = make_form_a(SRC_H)
            impl_old = make_form_a(SRC_A, "old", "v1", with_index=False)
            impl_new = make_form_a(SRC_A, "old", "v2", with_index=False)
            anchor = init_patch_repo(
                root,
                {
                    "patches/series": b"0001-mix.patch\n",
                    "patches/0001-mix.patch": gn + hdr + impl_old,
                },
            )
            (root / "patches/0001-mix.patch").write_bytes(gn + hdr + impl_new)
            impact = analyze(anchor, root)
            self.assertEqual(impact.changed_sources, frozenset({SRC_A}))
            self.assertEqual(impact.ordered_sections[SRC_A], [("0001-mix.patch", impl_new)])

    def test_non_impl_edits_fail_closed(self):
        for bad_path in (
            "ios/example/client.h",
            "ios/example/BUILD.gn",
            "ios/example/Info.plist",
            "ios/example/api.mojom",
            "ios/example/Bridge.swift",
            "ios/example/client.CC",
        ):
            with self.subTest(path=bad_path), tempfile.TemporaryDirectory() as td:
                root = pathlib.Path(td)
                anchor = init_patch_repo(
                    root,
                    {
                        "patches/series": b"0001-edit.patch\n",
                        "patches/0001-edit.patch": make_form_a(bad_path, "a", "b"),
                    },
                )
                (root / "patches/0001-edit.patch").write_bytes(make_form_a(bad_path, "a", "c"))
                with self.assertRaisesRegex(UseStandardPlan, "implementation-only"):
                    analyze(anchor, root)

    def test_paired_form_b_edit_allowed_but_add_remove_convert_rejected(self):
        # Paired Form B (with and without index line) passes.
        for with_index in (True, False):
            with self.subTest(with_index=with_index), tempfile.TemporaryDirectory() as td:
                root = pathlib.Path(td)
                sec_a = make_form_b(SRC_B, ["int f() { return 1; }"], with_index=with_index)
                sec_b = make_form_b(SRC_B, ["int f() { return 2; }"], with_index=with_index)
                anchor = init_patch_repo(
                    root,
                    {
                        "patches/series": b"0001-new.patch\n",
                        "patches/0001-new.patch": sec_a,
                    },
                )
                (root / "patches/0001-new.patch").write_bytes(sec_b)
                impact = analyze(anchor, root)
                self.assertEqual(impact.changed_sources, frozenset({SRC_B}))
                self.assertEqual(impact.ordered_sections[SRC_B], [("0001-new.patch", sec_b)])

        # Adding a Form B section fails closed.
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            p1 = make_form_a(SRC_A)
            anchor = init_patch_repo(
                root,
                {"patches/series": b"0001-p.patch\n", "patches/0001-p.patch": p1},
            )
            (root / "patches/0001-p.patch").write_bytes(p1 + make_form_b(SRC_B))
            with self.assertRaisesRegex(UseStandardPlan, "Form B"):
                analyze(anchor, root)

        # Removing a Form B section fails closed.
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            p1 = make_form_a(SRC_A)
            anchor = init_patch_repo(
                root,
                {"patches/series": b"0001-p.patch\n", "patches/0001-p.patch": p1 + make_form_b(SRC_B)},
            )
            (root / "patches/0001-p.patch").write_bytes(p1)
            with self.assertRaisesRegex(UseStandardPlan, "Form B"):
                analyze(anchor, root)

        # Converting Form A -> Form B fails closed.
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            anchor = init_patch_repo(
                root,
                {"patches/series": b"0001-p.patch\n", "patches/0001-p.patch": make_form_a(SRC_A)},
            )
            (root / "patches/0001-p.patch").write_bytes(make_form_b(SRC_A))
            with self.assertRaisesRegex(UseStandardPlan, "changed form"):
                analyze(anchor, root)

    def test_add_and_remove_form_a_section_in_existing_patch(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            sec_a = make_form_a(SRC_A)
            sec_b = make_form_a(SRC_B)
            anchor = init_patch_repo(
                root,
                {"patches/series": b"0001-p.patch\n", "patches/0001-p.patch": sec_a},
            )
            # Add SRC_B
            (root / "patches/0001-p.patch").write_bytes(sec_a + sec_b)
            impact = analyze(anchor, root)
            self.assertEqual(impact.changed_sources, frozenset({SRC_B}))
            self.assertEqual(impact.ordered_sections[SRC_B], [("0001-p.patch", sec_b)])

        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            sec_a = make_form_a(SRC_A)
            sec_b = make_form_a(SRC_B)
            anchor = init_patch_repo(
                root,
                {"patches/series": b"0001-p.patch\n", "patches/0001-p.patch": sec_a + sec_b},
            )
            # Remove SRC_B (reverts to upstream -> ordered_sections[SRC_B] == [])
            (root / "patches/0001-p.patch").write_bytes(sec_a)
            impact = analyze(anchor, root)
            self.assertEqual(impact.changed_sources, frozenset({SRC_B}))
            self.assertEqual(impact.ordered_sections[SRC_B], [])

    def test_appended_new_pure_impl_patch_allowed_and_reordered_or_deleted_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            anchor = init_patch_repo(
                root,
                {
                    "patches/series": b"0001-base.patch\n0002-base.patch\n",
                    "patches/0001-base.patch": make_form_a(SRC_A),
                    "patches/0002-base.patch": make_form_a(SRC_H),
                },
            )
            # Append new Form A patch -> pass
            extra = make_form_a(SRC_B, "x", "y")
            (root / "patches/0003-extra.patch").write_bytes(extra)
            (root / "patches/series").write_bytes(b"0001-base.patch\n0002-base.patch\n0003-extra.patch\n")
            impact = analyze(anchor, root)
            self.assertEqual(impact.changed_sources, frozenset({SRC_B}))
            self.assertEqual(impact.ordered_sections[SRC_B], [("0003-extra.patch", extra)])

            # Reordering baseline patches -> fail closed
            (root / "patches/series").write_bytes(b"0002-base.patch\n0001-base.patch\n0003-extra.patch\n")
            with self.assertRaisesRegex(UseStandardPlan, "reordered or deleted"):
                analyze(anchor, root)

            # Deleting a baseline patch -> fail closed
            (root / "patches/series").write_bytes(b"0001-base.patch\n")
            (root / "patches/0002-base.patch").unlink()
            (root / "patches/0003-extra.patch").unlink()
            with self.assertRaisesRegex(UseStandardPlan, "reordered or deleted"):
                analyze(anchor, root)

    def test_appended_patch_with_form_b_or_suspicious_preamble_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            anchor = init_patch_repo(
                root,
                {
                    "patches/series": b"0001-base.patch\n",
                    "patches/0001-base.patch": make_form_a(SRC_A),
                },
            )
            (root / "patches/series").write_bytes(b"0001-base.patch\n0002-new.patch\n")
            (root / "patches/0002-new.patch").write_bytes(make_form_b(SRC_B))
            with self.assertRaisesRegex(UseStandardPlan, "creates a new file"):
                analyze(anchor, root)

            (root / "patches/0002-new.patch").write_bytes(b"GIT binary patch\n" + make_form_a(SRC_B))
            with self.assertRaisesRegex(UseStandardPlan, "suspicious diff markers"):
                analyze(anchor, root)

    def test_headerless_unified_diff_smuggling_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            base_sec = make_form_a(SRC_A, "old", "v1")
            smuggled_hdr = make_form_a(SRC_H, "old", "evil").split(b"\n", 2)[2]
            combined = make_form_a(SRC_A, "old", "v2") + smuggled_hdr

            # Prove git apply itself would apply the smuggled header file!
            apply_dir = root / "apply_check"
            for f in (SRC_A, SRC_H):
                p = apply_dir / f
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(b"old\n")
            subprocess.run(["git", "apply", "-p1"], cwd=apply_dir, input=combined, check=True)
            self.assertEqual((apply_dir / SRC_H).read_bytes(), b"evil\n")

            repo = root / "repo"
            repo.mkdir()
            anchor = init_patch_repo(
                repo,
                {"patches/series": b"0001-p.patch\n", "patches/0001-p.patch": base_sec},
            )
            (repo / "patches/0001-p.patch").write_bytes(combined)
            with self.assertRaisesRegex(UseStandardPlan, "different set of file edits"):
                analyze(anchor, repo)

    def test_binary_chmod_rename_and_delete_hunks_rejected(self):
        cases = [
            (
                "chmod",
                (
                    f"diff --git a/{SRC_A} b/{SRC_A}\n"
                    "old mode 100644\nnew mode 100755\n"
                    f"--- a/{SRC_A}\n+++ b/{SRC_A}\n@@ -1 +1 @@\n-old\n+new\n"
                ).encode(),
            ),
            (
                "delete",
                (
                    f"diff --git a/{SRC_A} b/{SRC_A}\n"
                    "deleted file mode 100644\nindex 1111111..0000000\n"
                    f"--- a/{SRC_A}\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n"
                ).encode(),
            ),
            (
                "rename",
                (
                    f"diff --git a/{SRC_A} b/{SRC_B}\n"
                    "similarity index 100%\n"
                    f"rename from {SRC_A}\nrename to {SRC_B}\n"
                ).encode(),
            ),
            (
                "binary",
                (
                    f"diff --git a/{SRC_A} b/{SRC_A}\n"
                    "index 1111111..2222222 100644\n"
                    "GIT binary patch\nliteral 1\nIcmZQzU|<0R00031\n\nliteral 0\nHcmV?d00001\n"
                ).encode(),
            ),
        ]
        for label, bad_patch in cases:
            with self.subTest(case=label), tempfile.TemporaryDirectory() as td:
                root = pathlib.Path(td)
                anchor = init_patch_repo(
                    root,
                    {
                        "patches/series": b"0001-p.patch\n",
                        "patches/0001-p.patch": make_form_a(SRC_A, "old", "v1"),
                    },
                )
                (root / "patches/0001-p.patch").write_bytes(bad_patch)
                with self.assertRaises(UseStandardPlan):
                    analyze(anchor, root)

    def test_stacked_patches_and_unchanged_form_b_isolation(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            # Patch 1 creates SRC_B (Form B) and edits BUILD.gn; Patch 2 & 3 stack edits on SRC_B and SRC_A.
            p1_b = make_form_b(SRC_B, ["int x = 1;"], with_index=False)
            p1_gn = make_form_a("ios/example/BUILD.gn", with_index=False)
            p2_b_old = make_form_a(SRC_B, "int x = 1;", "int x = 2;")
            p2_b_new = make_form_a(SRC_B, "int x = 1;", "int x = 3;")
            p2_a = make_form_a(SRC_A, "a", "b")
            p3_b = make_form_a(SRC_B, "int x = 2;", "int x = 4;")

            anchor = init_patch_repo(
                root,
                {
                    "patches/series": b"0001-create.patch\n0002-stack.patch\n0003-top.patch\n",
                    "patches/0001-create.patch": p1_gn + p1_b,
                    "patches/0002-stack.patch": p2_a + p2_b_old,
                    "patches/0003-top.patch": p3_b,
                },
            )
            # Edit only SRC_B inside 0002-stack.patch; 0001-create.patch (Form B) and 0003-top.patch stay untouched.
            (root / "patches/0002-stack.patch").write_bytes(p2_a + p2_b_new)
            impact = analyze(anchor, root)
            self.assertEqual(impact.changed_sources, frozenset({SRC_B}))
            self.assertEqual(
                impact.ordered_sections[SRC_B],
                [
                    ("0001-create.patch", p1_b),
                    ("0002-stack.patch", p2_b_new),
                    ("0003-top.patch", p3_b),
                ],
            )
            self.assertNotIn(SRC_A, impact.changed_sources)

    def test_basename_deny_list(self):
        for name in (
            "foo/bar_inl.cc",
            "foo/bar-inl.mm",
            "foo/bar_inc.cc",
            "foo/bar-inc.c",
            "foo/bar.inl.cc",
            "foo/bar.inc.cpp",
            "foo/BAR_INL.cc",
        ):
            with self.subTest(name=name):
                sec = make_form_a(name)
                with self.assertRaisesRegex(UseStandardPlan, "basename deny-list"):
                    validate_changed_section(sec, name.encode())

    def test_hunk_include_guards(self):
        safe_lines = [
            b"@@ -1 +1,5 @@",
            b'+#include "ios/example/client.h"',
            b"+#import <Foundation/Foundation.h>",
            b'+#include "ios/example/util.hpp" // trailing comment',
            b'+#include "ios/example/util.h" /* block comment */',
            b'+// #include "ios/example/other.cc"',
            b"+#define FOO(x) \\",
            b"+  ((x) + 1)",
        ]
        check_added_hunk_includes(safe_lines, SRC_A)

        unsafe_cases = [
            b'+#include "other.cc"',
            b'+#include "OTHER.CC"',
            b'+#import "other.mm"',
            b'+#include_next "sub/foo.cpp"',
            b'+#embed "data.c"',
            b'+/* c */ #include "other.cc"',
            b'+#include /* c */ "header.h"',
            b"+#include MY_MACRO",
            b"+#include \\",
            b"+#\\",
            b'+#include "foo_inl.h"',
            b'+#include "ok.h" /* a */ #include "bad.cc" /* b */',
        ]
        for line in unsafe_cases:
            with self.subTest(line=line):
                with self.assertRaises(UseStandardPlan):
                    check_added_hunk_includes([b"@@ -1 +1 @@", line], SRC_A)

    def test_optional_patch_or_unlisted_or_symlink_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            anchor = init_patch_repo(
                root,
                {
                    "patches/series": b"0001-p.patch\n",
                    "patches/0001-p.patch": make_form_a(SRC_A),
                    "patches/optional/opt.patch": make_form_a(SRC_B),
                },
            )
            # Modifying optional/ fails closed
            (root / "patches/optional/opt.patch").write_bytes(make_form_a(SRC_B, "old", "mutated"))
            with self.assertRaisesRegex(UseStandardPlan, "Non-active file"):
                analyze(anchor, root)
            (root / "patches/optional/opt.patch").write_bytes(make_form_a(SRC_B))

            # Unlisted top-level patch fails closed
            (root / "patches/0002-unlisted.patch").write_bytes(make_form_a(SRC_B))
            with self.assertRaisesRegex(UseStandardPlan, "unlisted"):
                analyze(anchor, root)
            (root / "patches/0002-unlisted.patch").unlink()

            # Symlink under patches/ fails closed
            (root / "patches/link.txt").symlink_to(root / "patches/series")
            with self.assertRaisesRegex(UseStandardPlan, "Symlink"):
                analyze(anchor, root)

    def test_real_curium_active_series_parses_cleanly(self):
        series = parse_series((REPO_ROOT / "patches/series").read_bytes())
        self.assertGreater(len(series), 100)
        for name in series:
            data = (REPO_ROOT / "patches" / name).read_bytes()
            _, secs = parse_patch_sections(data, REPO_ROOT)
            self.assertGreater(len(secs), 0, f"{name} parsed 0 sections")


if __name__ == "__main__":
    unittest.main()

"""Unit tests for scripts/graph_index.py."""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch as mock_patch

SCRIPTS_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import graph_index  # noqa: E402

SRC_SAFE = "ios/example/safe.cc"
OBJ_SAFE = "obj/ios/example/safe.o"
SRC_APPLE = "ios/example/swift_user.mm"
OBJ_APPLE = "obj/ios/example/swift_user.o"
SRC_HOST = "ios/example/shared_host.cc"
OBJ_HOST_TARGET = "obj/ios/example/shared_host.o"
SRC_DEP = "ios/example/codegen_dep.cc"
OBJ_DEP = "obj/ios/example/codegen_dep.o"
SRC_ABS_DEP = "ios/example/abs_dep.cc"
OBJ_ABS_DEP = "obj/ios/example/abs_dep.o"
SRC_INC_REL = "ios/example/sub/inc_rel.cc"
OBJ_INC_REL = "obj/ios/example/sub/inc_rel.o"
SRC_INC_UP = "ios/example/up/inc_up.cc"
OBJ_INC_UP = "obj/ios/example/up/inc_up.o"
SRC_INC_GEN = "ios/example/from_gen.cc"
OBJ_INC_GEN = "obj/ios/example/from_gen.o"
SRC_APPLE_DEP = "ios/example/apple_dep.mm"
OBJ_APPLE_DEP = "obj/ios/example/apple_dep.o"
SRC_ORDER = "ios/example/order_only.cc"
OBJ_ORDER = "obj/ios/example/order_only.o"


def write_fake_ninja(path: pathlib.Path, commands: list[str], targets: list[str], deps_out: str, deps_rc: int = 0) -> None:
    cmds_payload = json.dumps("\n".join(commands) + "\n")
    tgts_payload = json.dumps("\n".join(targets) + "\n")
    deps_payload = json.dumps(deps_out)
    script = f"""#!/usr/bin/env python3
import sys
args = sys.argv[1:]
idx = args.index("-t")
tool = args[idx + 1]
if tool == "commands":
    sys.stdout.write({cmds_payload})
elif tool == "targets":
    sys.stdout.write({tgts_payload})
elif tool == "deps":
    sys.stdout.write({deps_payload})
    sys.exit({deps_rc})
else:
    sys.exit(2)
"""
    path.write_text(script, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def setup_synthetic_tree(root: pathlib.Path, *, with_validation: bool = False, deps_out: str | None = None, deps_rc: int = 0):
    src_dir = root / "src"
    out_dir = src_dir / "out" / "Release"
    gen_dir = out_dir / "gen"
    out_dir.mkdir(parents=True)
    gen_dir.mkdir(parents=True)

    # Create source files, including #include patterns and an ignored src/out/ file.
    (src_dir / "ios/example").mkdir(parents=True)
    (src_dir / "ios/example/sub").mkdir(parents=True)
    (src_dir / "ios/example/up").mkdir(parents=True)
    (src_dir / "ios/example/includer.cc").write_text(
        '#include "sub/inc_rel.cc"\n'
        '/* note */ #include "../up/inc_up.cc"\n',
        encoding="utf-8",
    )
    # Put an include inside gen/out/ to ensure `--glob '!out/**'` is NOT applied to gen/.
    (gen_dir / "out").mkdir(parents=True)
    (gen_dir / "out/generated_bridge.h").write_text('#include "from_gen.cc"\n', encoding="utf-8")
    # Put an include inside src/out/ referencing SRC_SAFE: MUST be ignored by src/ scan!
    (src_dir / "out/ignored.cc").write_text('#include "ios/example/safe.cc"\n', encoding="utf-8")

    (out_dir / "args.gn").write_text('target_os = "ios"\n', encoding="utf-8")
    (out_dir / "sub.ninja").write_text(
        f"build {OBJ_ORDER}: cxx ../../{SRC_ORDER}\n"
        f"build {OBJ_SAFE}: cxx ../../{SRC_SAFE} | gen/input.h || ../../{SRC_ORDER}\n",
        encoding="utf-8",
    )
    val_suffix = f" |@ {OBJ_SAFE}" if with_validation else ""
    (out_dir / "build.ninja").write_text(
        "rule cxx\n  command = clang++ -c $in -o $out\n"
        "rule objcxx\n  command = clang++ -c $in -o $out\n"
        "rule gen\n  command = python3 gen.py $in $out\n"
        "rule swift\n  command = python3 apple_tool_wrapper.py --tool=swift $in $out\n"
        "rule link\n  command = clang++ $in -o $out\n"
        "subninja sub.ninja\n"
        f"build gen/input.h: gen ../../template.json{val_suffix}\n"
        "build gen/swift_hdr.h: swift ../../ios/example/Mod.swift | gen/input.h\n"
        f"build {OBJ_APPLE}: objcxx ../../{SRC_APPLE} | gen/swift_hdr.h\n"
        f"build {OBJ_HOST_TARGET}: cxx ../../{SRC_HOST}\n"
        f"build clang_x64/obj/shared_host.o: cxx ../../{SRC_HOST}\n"
        f"build {OBJ_DEP}: cxx ../../{SRC_DEP}\n"
        f"build {OBJ_ABS_DEP}: cxx ../../{SRC_ABS_DEP}\n"
        f"build {OBJ_INC_REL}: cxx ../../{SRC_INC_REL}\n"
        f"build {OBJ_INC_UP}: cxx ../../{SRC_INC_UP}\n"
        f"build {OBJ_INC_GEN}: cxx ../../{SRC_INC_GEN}\n"
        f"build {OBJ_APPLE_DEP}: objcxx ../../{SRC_APPLE_DEP}\n"
        f"build Chromium: link {OBJ_SAFE} {OBJ_APPLE} {OBJ_HOST_TARGET} {OBJ_DEP} {OBJ_ABS_DEP} "
        f"{OBJ_INC_REL} {OBJ_INC_UP} {OBJ_INC_GEN} {OBJ_APPLE_DEP} {OBJ_ORDER}\n"
        "build chrome: phony Chromium\n",
        encoding="utf-8",
    )

    all_objs = [
        (OBJ_SAFE, "cxx"),
        (OBJ_APPLE, "objcxx"),
        (OBJ_HOST_TARGET, "cxx"),
        (OBJ_DEP, "cxx"),
        (OBJ_ABS_DEP, "cxx"),
        (OBJ_INC_REL, "cxx"),
        (OBJ_INC_UP, "cxx"),
        (OBJ_INC_GEN, "cxx"),
        (OBJ_APPLE_DEP, "objcxx"),
        (OBJ_ORDER, "cxx"),
    ]
    commands = [f"clang++ -c dummy.cc -o {o}" for o, _ in all_objs]
    commands.append("clang++ -c dummy.cc -o clang_x64/obj/shared_host.o")
    targets = [f"{o}: {r}" for o, r in all_objs] + [
        "clang_x64/obj/shared_host.o: cxx",
        "gen/input.h: gen",
        "gen/swift_hdr.h: swift",
        "Chromium: link",
        "chrome: phony",
    ]
    if deps_out is None:
        abs_dep = (src_dir / SRC_ABS_DEP).resolve().as_posix()
        out_gen_dep = (out_dir / "gen/ignored.cc").resolve().as_posix()
        deps_out = (
            "gen/input.h: #deps 4, deps mtime 123 (VALID)\n"
            f"    ../../{SRC_DEP}\n"
            f"    {abs_dep}\n"
            f"    {out_gen_dep}\n"
            "    ../../../outside_repo.cc\n"
            "\n"
            "other.o: deps not found\n"
        )
    ninja_bin = root / "fake_ninja.py"
    write_fake_ninja(ninja_bin, commands, targets, deps_out, deps_rc=deps_rc)

    # Create Apple cache with a sanitized depfile referencing SRC_APPLE_DEP.
    apple_cache = root / "apple_tool_cache"
    entry = apple_cache / "swift_abc123"
    (entry / "files/gen").mkdir(parents=True)
    (entry / "files/gen/swift.d").write_text(
        f"gen/swift_hdr.h: \\\n  ../../{SRC_APPLE_DEP} ../../ios/example/with\\ space.h\n",
        encoding="utf-8",
    )
    (entry / "meta.json").write_text(
        json.dumps({"tool": "swift", "primary": "gen/swift_hdr.h", "recorded_paths": ["gen/swift.d"]}),
        encoding="utf-8",
    )
    return src_dir, out_dir, ninja_bin, apple_cache


class GraphIndexTests(unittest.TestCase):
    def _assert_index_contents(self, idx: dict) -> None:
        self.assertEqual(idx["schema_version"], 1)
        self.assertEqual(idx["k_codegen"], "a" * 20)
        self.assertEqual(idx["shard_count"], 18)
        self.assertFalse(idx["has_ninja_validations"])
        self.assertRegex(idx["graph_pruned_sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(idx["codegen_targets_sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(idx["all_objects_sha256"], r"^[0-9a-f]{64}$")

        # Safe source is mapped and NOT unsafe (src/out/ reference was ignored!).
        self.assertEqual(idx["source_to_objects"][SRC_SAFE], [OBJ_SAFE])
        self.assertNotIn(SRC_SAFE, idx["unsafe_sources"])

        # Unsafe detections across all channels:
        unsafe = idx["unsafe_sources"]
        self.assertIn("non_target_edge", unsafe[SRC_HOST])
        self.assertIn("codegen_depfile", unsafe[SRC_DEP])
        self.assertIn("codegen_depfile", unsafe[SRC_ABS_DEP])
        self.assertIn("included_by_source", unsafe[SRC_INC_REL])
        self.assertIn("included_by_source", unsafe[SRC_INC_UP])
        self.assertIn("included_by_source", unsafe[SRC_INC_GEN])
        self.assertIn("apple_depfile", unsafe[SRC_APPLE_DEP])
        self.assertIn("implicit_or_order_input", unsafe[SRC_ORDER])

        # Apple-dependent object detection
        self.assertEqual(idx["apple_object_sources"], [SRC_APPLE])

    def test_build_and_verify_with_python_scanner_and_rg_if_present(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            src_dir, out_dir, ninja_bin, apple_cache = setup_synthetic_tree(root)

            # 1) Force pure-Python fallback scanner (no rg).
            with mock_patch("graph_index.shutil.which", return_value=None):
                idx_py = graph_index.build_index(
                    out_dir=out_dir,
                    ninja_bin=str(ninja_bin),
                    k_codegen="a" * 20,
                    src_ref="ghcr.io/o/r/chromium-ios-src@sha256:" + "1" * 64,
                    stub_ref="ghcr.io/o/r/xcode-stub@sha256:" + "2" * 64,
                    shard_count=18,
                    src_dir=src_dir,
                    apple_cache_dir=apple_cache,
                    require_rg=False,
                )
            self._assert_index_contents(idx_py)

            # 2) If rg is installed, assert identical result with --require-rg!
            if shutil.which("rg"):
                idx_rg = graph_index.build_index(
                    out_dir=out_dir,
                    ninja_bin=str(ninja_bin),
                    k_codegen="a" * 20,
                    src_ref="ghcr.io/o/r/chromium-ios-src@sha256:" + "1" * 64,
                    stub_ref="ghcr.io/o/r/xcode-stub@sha256:" + "2" * 64,
                    shard_count=18,
                    src_dir=src_dir,
                    apple_cache_dir=apple_cache,
                    require_rg=True,
                )
                self.assertEqual(idx_rg, idx_py)

            # 3) Verify passes on unchanged graph.
            problems = graph_index.verify_graph(
                out_dir=out_dir,
                ninja_bin=str(ninja_bin),
                expected_graph_sha=idx_py["graph_pruned_sha256"],
                expected_codegen_sha=idx_py["codegen_targets_sha256"],
                expected_objects_sha=idx_py["all_objects_sha256"],
            )
            self.assertEqual(problems, [])

            # 4) Mutate args.gn -> verify fails closed!
            (out_dir / "args.gn").write_text('target_os = "ios"\nis_debug = true\n', encoding="utf-8")
            problems = graph_index.verify_graph(
                out_dir=out_dir,
                ninja_bin=str(ninja_bin),
                expected_graph_sha=idx_py["graph_pruned_sha256"],
                expected_codegen_sha=idx_py["codegen_targets_sha256"],
                expected_objects_sha=idx_py["all_objects_sha256"],
            )
            self.assertTrue(any("graph_pruned_sha256 mismatch" in p for p in problems))

    def test_require_rg_fails_when_missing(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            src_dir, out_dir, ninja_bin, _ = setup_synthetic_tree(root)
            with mock_patch("graph_index.shutil.which", return_value=None):
                with self.assertRaisesRegex(RuntimeError, "ripgrep"):
                    graph_index.build_index(
                        out_dir=out_dir,
                        ninja_bin=str(ninja_bin),
                        k_codegen="a" * 20,
                        src_ref="ghcr.io/o/r/chromium-ios-src@sha256:" + "1" * 64,
                        stub_ref="ghcr.io/o/r/xcode-stub@sha256:" + "2" * 64,
                        shard_count=18,
                        src_dir=src_dir,
                        require_rg=True,
                    )

    def test_ninja_validations_flagged(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            src_dir, out_dir, ninja_bin, _ = setup_synthetic_tree(root, with_validation=True)
            with mock_patch("graph_index.shutil.which", return_value=None):
                idx = graph_index.build_index(
                    out_dir=out_dir,
                    ninja_bin=str(ninja_bin),
                    k_codegen="a" * 20,
                    src_ref="ghcr.io/o/r/chromium-ios-src@sha256:" + "1" * 64,
                    stub_ref="ghcr.io/o/r/xcode-stub@sha256:" + "2" * 64,
                    shard_count=18,
                    src_dir=src_dir,
                )
            self.assertTrue(idx["has_ninja_validations"])

    def test_empty_or_failed_ninja_deps_fails_closed(self):
        for deps_out, rc in [
            ("gen/input.h: deps not found\n", 0),
            ("gen/input.h: #deps 0, deps mtime 123 (VALID)\n", 0),
            ("", 1),
        ]:
            with self.subTest(deps_out=deps_out, rc=rc), tempfile.TemporaryDirectory() as td:
                root = pathlib.Path(td)
                src_dir, out_dir, ninja_bin, _ = setup_synthetic_tree(
                    root, deps_out=deps_out, deps_rc=rc
                )
                with self.assertRaises(RuntimeError):
                    graph_index.build_index(
                        out_dir=out_dir,
                        ninja_bin=str(ninja_bin),
                        k_codegen="a" * 20,
                        src_ref="ghcr.io/o/r/chromium-ios-src@sha256:" + "1" * 64,
                        stub_ref="ghcr.io/o/r/xcode-stub@sha256:" + "2" * 64,
                        shard_count=18,
                        src_dir=src_dir,
                    )

    def test_cli_build_and_verify_roundtrip(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            src_dir, out_dir, ninja_bin, apple_cache = setup_synthetic_tree(root)
            out_json = root / "out/graph_index.json"
            with mock_patch("graph_index.shutil.which", return_value=None):
                rc = graph_index.main([
                    "build",
                    "--out-dir", str(out_dir),
                    "--ninja", str(ninja_bin),
                    "--src-dir", str(src_dir),
                    "--k-codegen", "b" * 20,
                    "--src-ref", "ghcr.io/o/r/chromium-ios-src@sha256:" + "1" * 64,
                    "--stub-ref", "ghcr.io/o/r/xcode-stub@sha256:" + "2" * 64,
                    "--shard-count", "18",
                    "--apple-cache-dir", str(apple_cache),
                    "--output", str(out_json),
                ])
            self.assertEqual(rc, 0)
            idx = json.loads(out_json.read_text(encoding="utf-8"))
            rc_v = graph_index.main([
                "verify",
                "--out-dir", str(out_dir),
                "--ninja", str(ninja_bin),
                "--expected-graph-sha", idx["graph_pruned_sha256"],
                "--expected-codegen-sha", idx["codegen_targets_sha256"],
                "--expected-objects-sha", idx["all_objects_sha256"],
            ])
            self.assertEqual(rc_v, 0)
            rc_bad = graph_index.main([
                "verify",
                "--out-dir", str(out_dir),
                "--ninja", str(ninja_bin),
                "--expected-graph-sha", "0" * 64,
                "--expected-codegen-sha", idx["codegen_targets_sha256"],
                "--expected-objects-sha", idx["all_objects_sha256"],
            ])
            self.assertEqual(rc_bad, 1)


if __name__ == "__main__":
    unittest.main()

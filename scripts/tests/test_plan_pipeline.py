"""Unit tests for scripts/plan_pipeline.py incremental planning, chaining, and invariants."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch as mock_patch

SCRIPTS_DIR = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import plan_pipeline as pp  # noqa: E402

SRC_SHA = "sha256:" + "a" * 64
STUB_SHA = "sha256:" + "b" * 64
GRAPH_SHA = "1" * 64
CODEGEN_SHA = "2" * 64
OBJECTS_SHA = "3" * 64

SRC_1 = "ios/example/alpha.cc"
OBJ_1 = "obj/ios/example/alpha.o"
SRC_2 = "ios/example/beta.cc"
OBJ_2 = "obj/ios/example/beta.o"
SRC_APPLE = "ios/example/swift_user.mm"
OBJ_APPLE = "obj/ios/example/swift_user.o"
SRC_UNSAFE = "ios/example/host_shared.cc"
OBJ_UNSAFE = "obj/ios/example/host_shared.o"
SRC_HDR = "ios/example/alpha.h"


def make_patch(path: str, old_text: str, new_text: str) -> bytes:
    return (
        f"diff --git a/{path} b/{path}\n"
        f"index 1111111..2222222 100644\n"
        f"--- a/{path}\n"
        f"+++ b/{path}\n"
        f"@@ -1 +1 @@\n"
        f"-{old_text}\n"
        f"+{new_text}\n"
    ).encode()


def parse_github_output(path: pathlib.Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


class FakeRegistry:
    def __init__(self, repo: str = "owner/repo") -> None:
        self.repo = repo
        self.base = f"ghcr.io/{repo.lower()}"
        self.tags: dict[str, str] = {}
        self.indexes: dict[str, dict] = {}

    def put_tag(self, ref: str, digest_hex: str | None = None) -> str:
        sha = digest_hex or ("sha256:" + hashlib.sha256(ref.encode()).hexdigest())
        self.tags[ref] = sha
        return sha

    def put_index(self, index_ref: str, index_data: dict) -> str:
        sha = self.put_tag(index_ref)
        pinned = f"{index_ref.rsplit(':', 1)[0]}@{sha}"
        self.indexes[pinned] = index_data
        return sha

    def oci(self, action: str, ref: str) -> tuple[int, str]:
        if ref in self.tags:
            return (0, self.tags[ref] if action == "resolve" else "exists")
        return (1, "missing")

    def oci_pull(self, ref: str, dest: pathlib.Path) -> None:
        if ref not in self.indexes:
            raise AssertionError(f"Unexpected oci_pull for {ref}")
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "graph_index.json").write_text(json.dumps(self.indexes[ref]), encoding="utf-8")


def build_synthetic_repo(root: pathlib.Path) -> str:
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "ci@example.com"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "CI"], cwd=root, check=True)

    # Create every file expected by COMMON, STAGE_FILES, NON_OUTPUT, version.lock, ci/epochs.json.
    (root / "version.lock").write_text(
        "CHROMIUM_REV=aaaaebc70d8639eef7ec4775983a5e398e7a5ba7\n"
        "CHROMIUM_VERSION=160.0.8171.0\n"
        "XCODE_BUILD=27A9275\n"
        "BUNDLE_ID_PREFIX=com.example.curium\n",
        encoding="utf-8",
    )
    (root / "ci").mkdir(parents=True, exist_ok=True)
    (root / "ci/epochs.json").write_text(
        json.dumps({"codegen": 1, "apple": 1, "compile": 1, "link": 1, "package": 1}),
        encoding="utf-8",
    )
    (root / "args").mkdir(parents=True, exist_ok=True)
    (root / "args/device.gn").write_text('target_os = "ios"\n', encoding="utf-8")
    (root / "patches").mkdir(parents=True, exist_ok=True)
    (root / "patches/series").write_text("0001-core.patch\n", encoding="utf-8")
    (root / "patches/0001-core.patch").write_bytes(
        make_patch(SRC_1, "old1", "a1")
        + make_patch(SRC_2, "old2", "a2")
        + make_patch(SRC_APPLE, "old3", "a3")
        + make_patch(SRC_UNSAFE, "old4", "a4")
        + make_patch(SRC_HDR, "oldh", "ah")
    )

    all_files = (
        set(pp.COMMON)
        | {f for files in pp.STAGE_FILES.values() for f in files}
        | set(pp.NON_OUTPUT)
    )
    for rel in sorted(all_files):
        if rel in ("patches", "args", "ci/epochs.json"):
            continue
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.exists():
            p.write_text(f"# stub {rel}\n", encoding="utf-8")

    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "A: baseline"], cwd=root, check=True)
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()


def commit_all(root: pathlib.Path, message: str) -> str:
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run(["git", "commit", "-q", "-m", message], cwd=root, check=True)
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()


class RealRepoInvarianceTests(unittest.TestCase):
    def test_classification_and_build44_key_invariance(self):
        pp.check_classification()
        self.assertEqual(pp.digest(*pp.COMMON), pp.digest_at_commit("HEAD", *pp.COMMON))
        self.assertEqual(pp.digest("patches"), pp.digest_at_commit("HEAD", "patches"))

        lock = pp.read_lock()
        epochs = json.loads((pp.ROOT / "ci/epochs.json").read_text())
        src = "sha256:" + "0" * 64
        stub = "sha256:" + "1" * 64

        def stage_key(stage: str, *extra: str) -> str:
            return pp.digest(f"={stage}", f"=epoch:{epochs[stage]}", *extra, *pp.STAGE_FILES[stage])

        k_codegen = stage_key("codegen", f"=src:{src}", f"=stub:{stub}", f"=prefix:{lock['BUNDLE_ID_PREFIX']}", *pp.COMMON)
        k_apple = stage_key("apple", f"=codegen:{k_codegen}", f"=xcode:{lock['XCODE_BUILD']}")
        k_compile = stage_key("compile", f"=codegen:{k_codegen}", f"=apple:{k_apple}", f"=shards:{pp.SHARD_COUNT}")

        # Must match the pre-change Build 44 (3139702 / 4776553) keys byte-for-byte!
        self.assertEqual(k_codegen, "1f85817035c3d9c7bbbe")
        self.assertEqual(k_apple, "2bd7377749b6fa7d82e7")
        self.assertEqual(k_compile, "22eaeed27ee22740a8f1")

    def test_workflow_exports_all_plan_outputs(self):
        wf_text = (REPO_ROOT / ".github/workflows/build-kernel.yml").read_text(encoding="utf-8")
        referenced = set(re.findall(r"needs\.plan\.outputs\.([a-z0-9_]+)", wf_text))
        # Extract plan job outputs block.
        m = re.search(r"(?ms)^  plan:\n.*?^    outputs:\n(.*?)^    steps:", wf_text)
        self.assertIsNotNone(m)
        exported = set(re.findall(r"^      ([a-z0-9_]+):", m.group(1), re.M))
        self.assertTrue(referenced.issubset(exported), f"Missing plan outputs: {referenced - exported}")


class IncrementalPipelineTests(unittest.TestCase):
    def _run_plan(
        self,
        root: pathlib.Path,
        reg: FakeRegistry,
        *,
        env_extra: dict[str, str] | None = None,
        with_app_groups: str = "false",
    ) -> tuple[dict[str, str], str]:
        out_file = root / ".github_output"
        summary_file = root / ".github_summary"
        if out_file.exists():
            out_file.unlink()
        if summary_file.exists():
            summary_file.unlink()

        env = {
            "GITHUB_OUTPUT": str(out_file),
            "GITHUB_STEP_SUMMARY": str(summary_file),
            "ONLY_SHARDS": "",
            "VERIFY_ONLY": "false",
            "INCREMENTAL": "true",
            "BASELINE_COMMIT": "",
            "BACKFILL_INDEX_ONLY": "false",
        }
        if env_extra:
            env.update(env_extra)

        with (
            mock_patch.object(pp, "ROOT", root),
            mock_patch.object(pp, "oci", side_effect=reg.oci),
            mock_patch.object(pp, "oci_pull", side_effect=reg.oci_pull),
            mock_patch.dict(os.environ, env, clear=False),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            pp.plan(reg.repo, with_app_groups)
        return parse_github_output(out_file), summary_file.read_text(encoding="utf-8")

    def _seed_anchor_a(self, root: pathlib.Path, reg: FakeRegistry, *, with_index: bool = True, with_shards: bool = True):
        with mock_patch.object(pp, "ROOT", root):
            lock = pp.read_lock()
            refs = pp.Refs(reg.repo, lock)
            reg.put_tag(refs.src_tag, SRC_SHA)
            reg.put_tag(refs.stub_tag, STUB_SHA)
            out_a, _ = self._run_plan(root, reg, env_extra={"INCREMENTAL": "false"})
            cache = out_a["stage_cache"]
            k_codegen_a = out_a["k_codegen"]
            k_apple_a = out_a["apple_ref"].rsplit("apple-", 1)[1]
            k_compile_a = out_a["compile_prefix"].rsplit("compile-", 1)[1]

            reg.put_tag(f"{cache}:codegen-{k_codegen_a}")
            reg.put_tag(f"{cache}:apple-{k_apple_a}")
            if with_shards:
                for i in range(pp.SHARD_COUNT):
                    reg.put_tag(f"{cache}:compile-{k_compile_a}-{i}")
            if with_index:
                idx = {
                    "schema_version": 1,
                    "k_codegen": k_codegen_a,
                    "src_ref": refs.pinned(refs.src_tag, SRC_SHA),
                    "stub_ref": refs.pinned(refs.stub_tag, STUB_SHA),
                    "shard_count": pp.SHARD_COUNT,
                    "graph_pruned_sha256": GRAPH_SHA,
                    "codegen_targets_sha256": CODEGEN_SHA,
                    "all_objects_sha256": OBJECTS_SHA,
                    "has_ninja_validations": False,
                    "source_to_objects": {
                        SRC_1: [OBJ_1],
                        SRC_2: [OBJ_2],
                        SRC_APPLE: [OBJ_APPLE],
                        SRC_UNSAFE: [OBJ_UNSAFE],
                    },
                    "unsafe_sources": {
                        SRC_UNSAFE: ["included_by_source"],
                    },
                    "apple_object_sources": [SRC_APPLE],
                }
                reg.put_index(f"{cache}:index-{k_codegen_a}", idx)
            return cache, k_codegen_a, k_apple_a, k_compile_a

    def test_chaining_a_to_b_to_c_and_revert_d_link_hit(self):
        s1 = pp.shard_of_object(OBJ_1)
        s2 = pp.shard_of_object(OBJ_2)
        self.assertNotEqual(s1, s2, "Test fixture objects must hash to distinct shards")

        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            commit_a = build_synthetic_repo(root)
            reg = FakeRegistry()
            cache, k_codegen_a, k_apple_a, k_compile_a = self._seed_anchor_a(root, reg)

            # Commit B: edit SRC_1 (Shard s1) inside 0001-core.patch.
            (root / "patches/0001-core.patch").write_bytes(
                make_patch(SRC_1, "old1", "b1")
                + make_patch(SRC_2, "old2", "a2")
                + make_patch(SRC_APPLE, "old3", "a3")
                + make_patch(SRC_UNSAFE, "old4", "a4")
                + make_patch(SRC_HDR, "oldh", "ah")
            )
            commit_all(root, "B: edit alpha.cc")

            out_b, _ = self._run_plan(root, reg)
            self.assertEqual(out_b["incremental_mode"], "true")
            self.assertEqual(out_b["anchor_commit"], commit_a)
            self.assertEqual(out_b["run_codegen"], "false")
            self.assertEqual(out_b["run_apple"], "false")
            self.assertEqual(out_b["run_verify_apple_objects"], "false")
            self.assertEqual(out_b["run_compile"], "true")
            self.assertEqual(out_b["run_link"], "true")
            self.assertEqual(out_b["run_package"], "true")
            self.assertEqual(json.loads(out_b["shards_json"]), [s1])
            keys_b = json.loads(out_b["shard_keys_json"])
            self.assertEqual(len(keys_b), pp.SHARD_COUNT)
            for i in range(pp.SHARD_COUNT):
                if i == s1:
                    self.assertNotEqual(keys_b[i], k_compile_a)
                else:
                    self.assertEqual(keys_b[i], k_compile_a)
            matrix_b = json.loads(out_b["compile_matrix_json"])
            self.assertEqual(matrix_b, [{"shard": s1, "key": keys_b[s1]}])

            # Check GITHUB_OUTPUT size budget (< 2.5 KB).
            total_bytes = sum(len(k) + len(v) + 2 for k, v in out_b.items())
            self.assertLess(total_bytes, 2500)

            # Publish B's rebuilt shard s1 and link checkpoint.
            reg.put_tag(f"{cache}:compile-{keys_b[s1]}-{s1}")
            link_b_sha = reg.put_tag(out_b["link_ref"])

            # Commit C: edit SRC_2 (Shard s2) on top of B inside the SAME patch file!
            (root / "patches/0001-core.patch").write_bytes(
                make_patch(SRC_1, "old1", "b1")
                + make_patch(SRC_2, "old2", "c2")
                + make_patch(SRC_APPLE, "old3", "a3")
                + make_patch(SRC_UNSAFE, "old4", "a4")
                + make_patch(SRC_HDR, "oldh", "ah")
            )
            commit_all(root, "C: edit beta.cc")

            out_c, _ = self._run_plan(root, reg)
            self.assertEqual(out_c["incremental_mode"], "true")
            self.assertEqual(out_c["anchor_commit"], commit_a)
            keys_c = json.loads(out_c["shard_keys_json"])
            # C reuses BOTH A's 16 untouched shards AND B's rebuilt shard s1!
            self.assertEqual(keys_c[s1], keys_b[s1])
            self.assertNotEqual(keys_c[s2], k_compile_a)
            self.assertEqual(json.loads(out_c["shards_json"]), [s2])
            self.assertEqual(json.loads(out_c["compile_matrix_json"]), [{"shard": s2, "key": keys_c[s2]}])
            self.assertNotEqual(out_c["link_ref"], out_b["link_ref"])

            # Commit D: revert beta.cc back to B's exact content -> incremental k_link HIT!
            (root / "patches/0001-core.patch").write_bytes(
                make_patch(SRC_1, "old1", "b1")
                + make_patch(SRC_2, "old2", "a2")
                + make_patch(SRC_APPLE, "old3", "a3")
                + make_patch(SRC_UNSAFE, "old4", "a4")
                + make_patch(SRC_HDR, "oldh", "ah")
            )
            commit_all(root, "D: revert beta.cc")

            out_d, _ = self._run_plan(root, reg, with_app_groups="true")
            self.assertEqual(out_d["incremental_mode"], "true")
            self.assertEqual(out_d["run_compile"], "false")
            self.assertEqual(out_d["run_link"], "false")
            self.assertEqual(out_d["run_package"], "true")
            self.assertEqual(out_d["link_ref"], f"{cache}@{link_b_sha}")
            self.assertNotEqual(out_d["k_package"], out_b["k_package"])  # with_app_groups changed

    def test_verify_apple_objects_gating_and_only_shards_and_verify_only(self):
        s_apple = pp.shard_of_object(OBJ_APPLE)
        s1 = pp.shard_of_object(OBJ_1)

        # Case 1: Editing an apple_object_sources file forces verify_apple_objects = true.
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            build_synthetic_repo(root)
            reg = FakeRegistry()
            self._seed_anchor_a(root, reg, with_shards=True)

            (root / "patches/0001-core.patch").write_bytes(
                make_patch(SRC_1, "old1", "a1")
                + make_patch(SRC_2, "old2", "a2")
                + make_patch(SRC_APPLE, "old3", "b3")
                + make_patch(SRC_UNSAFE, "old4", "a4")
                + make_patch(SRC_HDR, "oldh", "ah")
            )
            commit_all(root, "edit swift_user.mm")
            out, _ = self._run_plan(root, reg)
            self.assertEqual(out["incremental_mode"], "true")
            self.assertEqual(out["run_verify_apple_objects"], "true")
            self.assertEqual(json.loads(out["shards_json"]), [s_apple])

        # Case 2: Anchor has 0 live compiled shards -> reused_anchor_shard_count == 0 -> runs verify_apple_objects!
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            build_synthetic_repo(root)
            reg = FakeRegistry()
            self._seed_anchor_a(root, reg, with_shards=False)

            (root / "patches/0001-core.patch").write_bytes(
                make_patch(SRC_1, "old1", "b1")
                + make_patch(SRC_2, "old2", "a2")
                + make_patch(SRC_APPLE, "old3", "a3")
                + make_patch(SRC_UNSAFE, "old4", "a4")
                + make_patch(SRC_HDR, "oldh", "ah")
            )
            commit_all(root, "edit alpha.cc on shardless anchor")
            out, _ = self._run_plan(root, reg)
            self.assertEqual(out["incremental_mode"], "true")
            self.assertEqual(out["run_verify_apple_objects"], "true")
            self.assertEqual(len(json.loads(out["shards_json"])), pp.SHARD_COUNT)

        # Case 3: ONLY_SHARDS and VERIFY_ONLY in incremental mode.
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            build_synthetic_repo(root)
            reg = FakeRegistry()
            self._seed_anchor_a(root, reg, with_shards=True)

            (root / "patches/0001-core.patch").write_bytes(
                make_patch(SRC_1, "old1", "b1")
                + make_patch(SRC_2, "old2", "b2")
                + make_patch(SRC_APPLE, "old3", "a3")
                + make_patch(SRC_UNSAFE, "old4", "a4")
                + make_patch(SRC_HDR, "oldh", "ah")
            )
            commit_all(root, "edit alpha and beta")
            out_only, _ = self._run_plan(root, reg, env_extra={"ONLY_SHARDS": str(s1)})
            self.assertEqual(out_only["incremental_mode"], "true")
            self.assertEqual(json.loads(out_only["shards_json"]), [s1])
            self.assertEqual(out_only["run_compile"], "true")
            self.assertEqual(out_only["run_link"], "false")
            self.assertEqual(out_only["run_package"], "false")
            self.assertEqual(out_only["run_verify_apple_objects"], "false")

            out_vo, _ = self._run_plan(root, reg, env_extra={"VERIFY_ONLY": "true"})
            self.assertEqual(out_vo["incremental_mode"], "true")
            self.assertEqual(out_vo["run_verify_apple_objects"], "true")
            self.assertEqual(out_vo["run_compile"], "false")
            self.assertEqual(out_vo["run_link"], "false")
            self.assertEqual(out_vo["run_package"], "false")
            self.assertEqual(out_vo["expected_graph_sha"], GRAPH_SHA)

    def test_backfill_index_only_and_auto_backfill_direct_probes(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            build_synthetic_repo(root)
            reg = FakeRegistry()
            cache, k_codegen_a, k_apple_a, _ = self._seed_anchor_a(root, reg, with_index=False, with_shards=True)

            # Standard run on HEAD with live codegen+apple and missing index triggers automatic backfill!
            out_std, _ = self._run_plan(root, reg)
            self.assertEqual(out_std["incremental_mode"], "false")
            self.assertEqual(out_std["run_codegen"], "false")
            self.assertEqual(out_std["run_apple"], "false")
            self.assertEqual(out_std["run_compile"], "false")
            self.assertEqual(out_std["run_index_backfill"], "true")

            # backfill_index_only=true runs ONLY backfill (skips link & package).
            out_bf, _ = self._run_plan(root, reg, env_extra={"BACKFILL_INDEX_ONLY": "true"})
            self.assertEqual(out_bf["run_index_backfill"], "true")
            self.assertEqual(out_bf["run_link"], "false")
            self.assertEqual(out_bf["run_package"], "false")
            self.assertEqual(out_bf["run_verify_apple_objects"], "false")

            # Mutual exclusion with ONLY_SHARDS / VERIFY_ONLY fails fast.
            for bad_env in (
                {"BACKFILL_INDEX_ONLY": "true", "ONLY_SHARDS": "0"},
                {"BACKFILL_INDEX_ONLY": "true", "VERIFY_ONLY": "true"},
            ):
                with self.assertRaises(SystemExit):
                    self._run_plan(root, reg, env_extra=bad_env)

            # If has_link is true but codegen checkpoint was deleted, auto-backfill MUST NOT run!
            reg.put_tag(out_std["link_ref"])
            del reg.tags[f"{cache}:codegen-{k_codegen_a}"]
            out_no_cg, _ = self._run_plan(root, reg)
            self.assertEqual(out_no_cg["run_index_backfill"], "false")
            with self.assertRaises(SystemExit):
                self._run_plan(root, reg, env_extra={"BACKFILL_INDEX_ONLY": "true"})

    def test_fail_closed_cases_and_backfill_hint(self):
        # 1) Missing index on anchor fails closed with backfill hint.
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            build_synthetic_repo(root)
            reg = FakeRegistry()
            self._seed_anchor_a(root, reg, with_index=False, with_shards=True)
            (root / "patches/0001-core.patch").write_bytes(
                make_patch(SRC_1, "old1", "b1")
                + make_patch(SRC_2, "old2", "a2")
                + make_patch(SRC_APPLE, "old3", "a3")
                + make_patch(SRC_UNSAFE, "old4", "a4")
                + make_patch(SRC_HDR, "oldh", "ah")
            )
            commit_all(root, "edit alpha without anchor index")
            out, summary = self._run_plan(root, reg)
            self.assertEqual(out["incremental_mode"], "false")
            self.assertIn("backfill_index_only=true", summary)

        # 2) Header edit, unsafe source, incremental=false, and non-patch change all fail closed.
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            commit_a = build_synthetic_repo(root)
            reg = FakeRegistry()
            self._seed_anchor_a(root, reg, with_index=True, with_shards=True)

            # Header edit (committed on top of A) -> fail closed with clear reason
            (root / "patches/0001-core.patch").write_bytes(
                make_patch(SRC_1, "old1", "a1")
                + make_patch(SRC_2, "old2", "a2")
                + make_patch(SRC_APPLE, "old3", "a3")
                + make_patch(SRC_UNSAFE, "old4", "a4")
                + make_patch(SRC_HDR, "oldh", "bh")
            )
            commit_all(root, "edit header")
            out_h, summary_h = self._run_plan(root, reg)
            self.assertEqual(out_h["incremental_mode"], "false")
            self.assertIn("implementation-only", summary_h)

            # Unsafe source (using explicit BASELINE_COMMIT=A) -> fail closed with unsafe reason
            (root / "patches/0001-core.patch").write_bytes(
                make_patch(SRC_1, "old1", "a1")
                + make_patch(SRC_2, "old2", "a2")
                + make_patch(SRC_APPLE, "old3", "a3")
                + make_patch(SRC_UNSAFE, "old4", "b4")
                + make_patch(SRC_HDR, "oldh", "ah")
            )
            out_u, summary_u = self._run_plan(root, reg, env_extra={"BASELINE_COMMIT": commit_a})
            self.assertEqual(out_u["incremental_mode"], "false")
            self.assertIn("marked unsafe", summary_u)

            # Valid edit + INCREMENTAL=false escape hatch -> standard plan
            (root / "patches/0001-core.patch").write_bytes(
                make_patch(SRC_1, "old1", "b1")
                + make_patch(SRC_2, "old2", "a2")
                + make_patch(SRC_APPLE, "old3", "a3")
                + make_patch(SRC_UNSAFE, "old4", "a4")
                + make_patch(SRC_HDR, "oldh", "ah")
            )
            out_off, _ = self._run_plan(root, reg, env_extra={"INCREMENTAL": "false"})
            self.assertEqual(out_off["incremental_mode"], "false")

            # Non-patch COMMON change (args/device.gn) -> fail closed
            (root / "args/device.gn").write_text('target_os = "ios"\nis_debug = true\n', encoding="utf-8")
            out_gn, summary_gn = self._run_plan(root, reg, env_extra={"BASELINE_COMMIT": commit_a})
            self.assertEqual(out_gn["incremental_mode"], "false")
            self.assertIn("Non-patch input changed", summary_gn)

    def test_baseline_ref_injection_rejected(self):
        for bad in ("--upload-pack=evil", "-n", "/abs/ref", "a..b", "foo/", "a b", "ref;rm"):
            with self.subTest(bad=bad):
                with self.assertRaises(SystemExit):
                    pp.validate_baseline_ref(bad)
        self.assertEqual(pp.validate_baseline_ref("feat/build-44-engine-wave"), "feat/build-44-engine-wave")
        self.assertEqual(pp.validate_baseline_ref("4776553"), "4776553")


if __name__ == "__main__":
    unittest.main()

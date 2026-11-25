"""Unit tests for scripts/stages/link.sh per-shard key import and fail-closed guards."""

from __future__ import annotations

import json
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
LINK_SH = REPO_ROOT / "scripts/stages/link.sh"
SHARD_ARTIFACT_PY = REPO_ROOT / "scripts/shard_artifact.py"


def build_shard_artifact(
    out_dir: pathlib.Path,
    targets: list[str],
    dest: pathlib.Path,
    key: str,
    shard: int,
    shard_count: int,
) -> None:
    targets_file = dest.parent / f"targets-{shard}.txt"
    targets_file.write_text("\n".join(targets) + "\n", encoding="utf-8")
    identity = json.dumps({"key": f"compile-{key}", "shard": shard, "shards": shard_count}, separators=(",", ":"))
    subprocess.run(
        [
            "python3",
            str(SHARD_ARTIFACT_PY),
            "pack",
            "--out-dir",
            str(out_dir),
            "--targets",
            str(targets_file),
            "--dest",
            str(dest),
            "--identity",
            identity,
        ],
        check=True,
        capture_output=True,
        text=True,
    )


class LinkShTests(unittest.TestCase):
    def _run_link_prepare(
        self,
        tmp: pathlib.Path,
        *,
        shard_count: int = 3,
        extra_env: dict[str, str],
        verify_rc: int = 0,
        artifacts: dict[str, pathlib.Path],
    ) -> subprocess.CompletedProcess:
        scripts_dir = tmp / "scripts"
        scripts_dir.mkdir(parents=True, exist_ok=True)
        # Symlink real shard_artifact.py so manifest + sha256 verification is exercised for real!
        (scripts_dir / "shard_artifact.py").symlink_to(SHARD_ARTIFACT_PY)

        verify_log = tmp / "verify_calls.log"
        pulls_log = tmp / "pulls.log"

        fake_graph_index = scripts_dir / "graph_index.py"
        fake_graph_index.write_text(
            f"""#!/usr/bin/env python3
import sys
with open({json.dumps(str(verify_log))}, "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")
sys.exit({verify_rc})
""",
            encoding="utf-8",
        )
        fake_graph_index.chmod(fake_graph_index.stat().st_mode | stat.S_IXUSR)

        fake_rewrite = scripts_dir / "rewrite_ninja_graph.py"
        fake_rewrite.write_text("#!/usr/bin/env python3\nimport sys; sys.exit(0)\n", encoding="utf-8")
        fake_rewrite.chmod(fake_rewrite.stat().st_mode | stat.S_IXUSR)

        fake_reclaim = scripts_dir / "reclaim_disk_linux.sh"
        fake_reclaim.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        fake_reclaim.chmod(fake_reclaim.stat().st_mode | stat.S_IXUSR)

        lout = tmp / "lout"
        lout.mkdir(parents=True, exist_ok=True)
        state = tmp / "state"
        state.mkdir(parents=True, exist_ok=True)

        # Build bash harness sourcing real link.sh with stubbed stage.sh helpers.
        art_map_lines = [f"  {json.dumps(ref)}) src={json.dumps(str(p))} ;;" for ref, p in artifacts.items()]
        harness = f"""#!/usr/bin/env bash
set -euo pipefail
SCRIPTS={json.dumps(str(scripts_dir))}
LOUT={json.dumps(str(lout))}
NINJA="/bin/true"
STATE={json.dumps(str(state))}
SHARD_COUNT={shard_count}

fail() {{ echo "::error::$*"; exit 1; }}
prepare_linux() {{ :; }}
shard_identity() {{ printf '{{"key":"%s","shard":%s,"shards":%s}}' "${{COMPILE_PREFIX##*:}}" "$1" "$SHARD_COUNT"; }}
plan_shard() {{
  mkdir -p "$STATE/plan"
  : > "$STATE/plan/all.txt"
  local i
  for (( i = 0; i < SHARD_COUNT; i++ )); do
    echo "obj/s${{i}}.o" > "$STATE/plan/shard-$i.txt"
    echo "obj/s${{i}}.o" >> "$STATE/plan/all.txt"
  done
}}
pull_pinned() {{
  local ref="$1" dest="$2" src=""
  echo "$ref" >> {json.dumps(str(pulls_log))}
  case "$ref" in
{chr(10).join(art_map_lines)}
    *) fail "Unexpected pull_pinned ref: $ref" ;;
  esac
  mkdir -p "$dest"
  cp -R "$src/." "$dest/"
}}
dry_run_summary() {{ echo "  1  LINK target"; }}
restored_work() {{ :; }}
explain_dirty() {{ :; }}
inject() {{ :; }}

source {json.dumps(str(LINK_SH))}
link_prepare
"""
        env = os.environ.copy()
        env.update(extra_env)
        return subprocess.run(
            ["bash", "-c", harness],
            capture_output=True,
            text=True,
            env=env,
        )

    def _prepare_mixed_artifacts(self, tmp: pathlib.Path, keys: list[str], stage_cache: str) -> dict[str, pathlib.Path]:
        build_out = tmp / "pack_src"
        (build_out / "obj").mkdir(parents=True, exist_ok=True)
        artifacts: dict[str, pathlib.Path] = {}
        for i, k in enumerate(keys):
            (build_out / f"obj/s{i}.o").write_bytes(f"object-{i}-{k}".encode())
            dest = tmp / f"art_{i}"
            build_shard_artifact(build_out, [f"obj/s{i}.o"], dest, k, i, len(keys))
            artifacts[f"{stage_cache}:compile-{k}-{i}"] = dest
        return artifacts

    def test_incremental_mixed_shard_keys_and_verify(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            cache = "ghcr.io/owner/repo/stage-cache"
            k_a = "a" * 20
            k_b = "b" * 20
            keys = [k_a, k_b, k_a]
            artifacts = self._prepare_mixed_artifacts(tmp, keys, cache)

            res = self._run_link_prepare(
                tmp,
                shard_count=3,
                artifacts=artifacts,
                extra_env={
                    "INCREMENTAL_MODE": "true",
                    "STAGE_CACHE": cache,
                    "SHARD_KEYS_JSON": json.dumps(keys, separators=(",", ":")),
                    "EXPECTED_GRAPH_SHA": "1" * 64,
                    "EXPECTED_CODEGEN_SHA": "2" * 64,
                    "EXPECTED_OBJECTS_SHA": "3" * 64,
                },
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            pulls = (tmp / "pulls.log").read_text().splitlines()
            self.assertEqual(
                pulls,
                [
                    f"{cache}:compile-{k_a}-0",
                    f"{cache}:compile-{k_b}-1",
                    f"{cache}:compile-{k_a}-2",
                ],
            )
            verify_calls = (tmp / "verify_calls.log").read_text()
            self.assertIn("verify", verify_calls)
            self.assertIn("--expected-graph-sha " + "1" * 64, verify_calls)

    def test_incremental_missing_required_env_fails_closed(self):
        cache = "ghcr.io/owner/repo/stage-cache"
        base_env = {
            "INCREMENTAL_MODE": "true",
            "STAGE_CACHE": cache,
            "SHARD_KEYS_JSON": json.dumps(["a" * 20] * 3),
            "EXPECTED_GRAPH_SHA": "1" * 64,
            "EXPECTED_CODEGEN_SHA": "2" * 64,
            "EXPECTED_OBJECTS_SHA": "3" * 64,
            "COMPILE_PREFIX": f"{cache}:compile-{'a' * 20}",
        }
        for omit in ("SHARD_KEYS_JSON", "STAGE_CACHE", "EXPECTED_GRAPH_SHA", "EXPECTED_CODEGEN_SHA", "EXPECTED_OBJECTS_SHA"):
            with self.subTest(omit=omit), tempfile.TemporaryDirectory() as td:
                tmp = pathlib.Path(td)
                env = dict(base_env)
                env[omit] = ""
                res = self._run_link_prepare(tmp, shard_count=3, artifacts={}, extra_env=env)
                self.assertNotEqual(res.returncode, 0)
                self.assertIn(omit, res.stdout + res.stderr)

    def test_graph_verify_failure_aborts_before_pulling_shards(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            cache = "ghcr.io/owner/repo/stage-cache"
            keys = ["a" * 20] * 3
            artifacts = self._prepare_mixed_artifacts(tmp, keys, cache)
            res = self._run_link_prepare(
                tmp,
                shard_count=3,
                artifacts=artifacts,
                verify_rc=1,
                extra_env={
                    "INCREMENTAL_MODE": "true",
                    "STAGE_CACHE": cache,
                    "SHARD_KEYS_JSON": json.dumps(keys),
                    "EXPECTED_GRAPH_SHA": "1" * 64,
                    "EXPECTED_CODEGEN_SHA": "2" * 64,
                    "EXPECTED_OBJECTS_SHA": "3" * 64,
                },
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertFalse((tmp / "pulls.log").exists())

    def test_malformed_shard_keys_json_fails_closed(self):
        cache = "ghcr.io/owner/repo/stage-cache"
        for bad in (
            "not-json",
            json.dumps(["a" * 20, "b" * 20]),  # wrong length
            json.dumps(["a" * 20, "Z" * 20, "a" * 20]),  # non-hex
            json.dumps(["a" * 20, "a" * 19, "a" * 20]),  # short hex
        ):
            with self.subTest(bad=bad), tempfile.TemporaryDirectory() as td:
                tmp = pathlib.Path(td)
                res = self._run_link_prepare(
                    tmp,
                    shard_count=3,
                    artifacts={},
                    extra_env={
                        "INCREMENTAL_MODE": "false",
                        "STAGE_CACHE": cache,
                        "SHARD_KEYS_JSON": bad,
                    },
                )
                self.assertNotEqual(res.returncode, 0)

    def test_legacy_compile_prefix_fallback_when_standard_mode(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            cache = "ghcr.io/owner/repo/stage-cache"
            k_a = "c" * 20
            artifacts = self._prepare_mixed_artifacts(tmp, [k_a] * 3, cache)
            res = self._run_link_prepare(
                tmp,
                shard_count=3,
                artifacts=artifacts,
                extra_env={
                    "INCREMENTAL_MODE": "false",
                    "COMPILE_PREFIX": f"{cache}:compile-{k_a}",
                    "SHARD_KEYS_JSON": "",
                    "STAGE_CACHE": "",
                    "EXPECTED_GRAPH_SHA": "",
                },
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            pulls = (tmp / "pulls.log").read_text().splitlines()
            self.assertEqual(pulls, [f"{cache}:compile-{k_a}-{i}" for i in range(3)])


if __name__ == "__main__":
    unittest.main()

# shellcheck shell=bash
# Stage 'link': Chromium.app from imported, verified objects (Linux).
# Sourced by scripts/stage.sh, which provides the shared helpers.

link_check() { check_done "${LINK_REF:?}"; }
link_init() { init_linux; }

# Imports every partition's verified objects, replaces exactly their compile
# edges, and proves the remaining plan compiles nothing.
link_prepare() {
  prepare_linux link
  # Today's plan for every partition, from this job's own graph.
  plan_shard "$SHARD_COUNT" 0 --split-dir "$STATE/plan" >/dev/null
  : > "$STATE/imported.txt"
  local i
  for (( i = 0; i < SHARD_COUNT; i++ )); do
    pull_pinned "${COMPILE_PREFIX:?}-$i" "$STATE/shard"
    tar -C "$LOUT" -xf "$STATE/shard/objects.tar"
    "$SCRIPTS/shard_artifact.py" verify --out-dir "$LOUT" --targets "$STATE/plan/shard-$i.txt" \
      --manifest "$STATE/shard/manifest.json" --identity "$(shard_identity "$i")"
    cat "$STATE/plan/shard-$i.txt" >> "$STATE/imported.txt"
    rm -rf "$STATE/shard"
  done
  sort "$STATE/imported.txt" | diff -q - <(sort "$STATE/plan/all.txt") >/dev/null \
    || fail "Imported objects do not cover the link closure exactly"
  "$SCRIPTS/rewrite_ninja_graph.py" --out-dir "$LOUT" --mode link-only --imported-file "$STATE/imported.txt"
  # What may remain: archives, links, Swift replays (Stage 2 outputs), actions
  # and bundle steps on the target side. Anything restored_work reports means a
  # checkpoint was not restored as recorded.
  dry_run_summary "" chrome | tee "$STATE/link_plan.txt"
  if [ -n "$(restored_work "$STATE/link_plan.txt")" ]; then
    restored_work "$STATE/link_plan.txt"
    explain_dirty chrome
    fail "The link plan redoes compile, Rust, or host-tool work (listed above)"
  fi
  inject link
  "$SCRIPTS/reclaim_disk_linux.sh" --swap-only 16
}

link_build() {
  export PATH="$LWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  export APPLE_TOOL_MODE=replay APPLE_TOOL_CACHE_DIR="$RUNNER_TEMP/apple_tool_cache"
  "$SCRIPTS/run_with_budget.py" --deadline-epoch "$(build_deadline)" --log "$STATE/ninja.log" -- \
    "$NINJA" -C "$LOUT" chrome
}

link_persist() {
  "$SCRIPTS/reclaim_disk_linux.sh" --drop-swap
  mkdir -p "$STATE/app" "$STATE/link_out"
  mv "$LOUT/Chromium.app" "$STATE/app/Chromium.app"
  # Verify Blink permission element localized strings (e.g. resource ID 47053)
  # are packed into the app's data packs so <geolocation>/<usermedia> elements
  # never SIGTRAP in ResourceBundle::GetLocalizedStringImpl.
  python3 - "$STATE/app/Chromium.app" <<'PY'
import pathlib, struct, sys

app = pathlib.Path(sys.argv[1])
def pak_ids(path: pathlib.Path) -> set[int]:
    data = path.read_bytes()
    version = struct.unpack_from("<I", data, 0)[0]
    if version != 5:
        raise SystemExit(f"Unsupported pak version {version} in {path}")
    _, res_count, alias_count = struct.unpack_from("<BxxxHH", data, 4)
    off = 12
    ids = {struct.unpack_from("<HI", data, off + i * 6)[0] for i in range(res_count)}
    off += (res_count + 1) * 6
    ids.update(struct.unpack_from("<HH", data, off + i * 4)[0] for i in range(alias_count))
    return ids

res_pak = app / "resources.pak"
en_pak = app / "en.lproj/locale.pak"
for p in (res_pak, en_pak):
    if not p.is_file():
        raise SystemExit(f"Missing expected data pack: {p}")
found = pak_ids(res_pak) | pak_ids(en_pak)
if 47053 not in found:
    raise SystemExit("Permission element resource ID 47053 missing from resources.pak and en.lproj/locale.pak")
print(f"Verified permission element strings (ID 47053 present across {len(found)} packed resources)")
PY
  # Keep the unstripped engine beside the checkpoint so crash reports can be
  # symbolicated. It never ships; the IPA carries the stripped binary.
  local unstripped
  unstripped="$(find "$LOUT" -maxdepth 1 -name 'chrome_framework*.unstripped' -print -quit)"
  if [ -n "$unstripped" ]; then
    mkdir -p "$STATE/symbols"
    zstd -T0 -10 -q -o "$STATE/symbols/$(basename "$unstripped").zst" "$unstripped"
  else
    echo "::warning::No unstripped chrome_framework found; crash symbols not saved"
  fi
  [ -d "$LOUT/.deferred_extract_metadata" ] && mv "$LOUT/.deferred_extract_metadata" "$STATE/app/"
  tar -C "$STATE/app" -cf - . | zstd -T0 -5 -o "$STATE/link_out/chromium_app_unsigned.tar.zst"
  rm -rf "$LWORK" "$STATE/app" || echo "::warning::Work tree not fully removed; continuing"
  oci push "${LINK_REF:?}" "$STATE/link_out" chromium_app_unsigned.tar.zst --repo "$GITHUB_REPOSITORY" --once
}


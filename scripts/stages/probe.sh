# shellcheck shell=bash
# Read-only registry probe: audit the link graph and compile selected objects without a stage checkpoint.
# Sourced by scripts/stage.sh to reuse tree, cache and build-budget helpers.

probe_compile() {
  local art="$RUNNER_TEMP/graph-diagnosis" rc=0
  local -a targets
  ccache_env
  export PATH="$LWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  export APPLE_TOOL_MODE=replay APPLE_TOOL_CACHE_DIR="$RUNNER_TEMP/no-apple-outputs"
  mkdir -p "$CCACHE_DIR" "$APPLE_TOOL_CACHE_DIR"
  if [ "${PROBE_CACHE_RESTORED:-false}" != true ]; then
    if (pull_bucket "ghcr.io/${GITHUB_REPOSITORY,,}/chromium-ios-ccache:$CHROMIUM_REV-codegen"); then
      # Reuse the normal shard seed policy: retain only entries this probe reads.
      find "$CCACHE_DIR" -type f -exec touch -t 200001010000 {} +
      touch "$STATE/probe_cache_seeded"
    else
      log "No usable warm codegen ccache bucket; continuing with compiler verification"
    fi
  fi
  # Composebox requires Swift-generated headers and is checked by the normal
  # build after it restores the Apple stage outputs.
  cat > "$art/compile_targets.txt" <<'EOF'
obj/extensions/common/common/extension.o
obj/extensions/common/api/api_features/api_features.o
obj/extensions/browser/browser_sources/process_manager.o
obj/extensions/renderer/renderer/dispatcher.o
obj/extensions/browser/browser_sources/extension_registrar_factory.o
obj/extensions/browser/browser_sources/process_manager_factory.o
obj/extensions/browser/browser_sources/renderer_startup_helper.o
obj/ios/web/content/init/init/ios_content_client.o
obj/ios/web/content/init/init/ios_content_renderer_client.o
obj/ios/web/content/init/init/ios_content_browser_client.o
obj/ios/web/content/init/init/ios_browser_main_parts.o
obj/ios/components/security_interstitials/safe_browsing/safe_browsing/safe_browsing_tab_helper.o
obj/ios/web/content/content/content_web_state.o
obj/ios/web/content/init/extensions/clients/ios_extensions_client.o
obj/ios/web/content/init/extensions/clients/ios_extensions_renderer_client.o
obj/ios/web/content/init/extensions/clients/tabs_hooks_delegate.o
obj/ios/chrome/browser/extensions/model/model/ios_action_api.o
obj/ios/chrome/browser/extensions/model/model/ios_extension_system.o
obj/ios/chrome/browser/extensions/model/model/ios_extension_system_factory.o
obj/ios/chrome/browser/extensions/model/model/ios_extension_web_contents_observer.o
obj/ios/chrome/browser/extensions/model/model/ios_extensions_browser_client.o
obj/components/policy/core/common/internal/policy_merger.o
obj/extensions/common/common/command.o
obj/extensions/common/common/content_script_utils.o
obj/extensions/common/common/script_serialization.o
obj/extensions/common/common/content_scripts_handler.o
obj/extensions/common/common/icon_variants_handler.o
obj/extensions/browser/browser_sources/execute_code_function.o
obj/extensions/browser/browser_sources/extension_user_script_loader.o
obj/extensions/browser/browser_sources/script_executor.o
obj/extensions/browser/browser_sources/scripting_utils.o
obj/extensions/browser/browser_sources/user_script_manager.o
obj/extensions/browser/browser_sources/extension_web_contents_observer.o
obj/extensions/browser/browser_sources/script_injection_tracker.o
obj/extensions/browser/browser_sources/site_permissions_helper.o
obj/extensions/browser/api/runtime/runtime/runtime_api.o
obj/extensions/browser/api/api_keyed_service_factories/api_browser_context_keyed_service_factories.o
obj/extensions/browser/api/api_registration/generated_api_registration.o
obj/extensions/browser/api/scripting/scripting/scripting_api.o
obj/extensions/browser/api/storage/storage/local_value_store_cache.o
obj/extensions/browser/api/user_scripts/user_scripts/user_scripts_api.o
obj/extensions/browser/api/system_info/system_info/system_info_provider.o
obj/extensions/browser/browser_sources/web_request_api.o
obj/extensions/browser/browser_sources/action_tracker.o
obj/extensions/browser/browser_sources/web_request_proxying_url_loader_factory.o
obj/extensions/browser/browser_sources/extension_web_request_event_router.o
obj/extensions/browser/browser_sources/rules_monitor_service.o
obj/extensions/browser/browser_sources/ruleset_manager.o
obj/extensions/browser/api/declarative_net_request/declarative_net_request/declarative_net_request_api.o
obj/content/browser/browser/render_frame_host_impl.o
obj/content/browser/browser/network_handler.o
obj/services/network/network_service/network_context.o
obj/extensions/browser/api/messaging/messaging/message_service.o
obj/extensions/browser/api/messaging/messaging/messaging_delegate.o
obj/extensions/renderer/renderer/service_worker_data.o
obj/extensions/renderer/renderer/worker_thread_dispatcher.o
obj/extensions/browser/browser_sources/service_worker_host.o
obj/extensions/browser/browser_sources/url_loader_factory_manager.o
obj/extensions/browser/browser_sources/unpacked_installer.o
obj/extensions/browser/browser_sources/extension_host_registry.o
obj/extensions/browser/browser_sources/extension_navigation_throttle.o
obj/extensions/browser/browser_sources/extension_webkit_preferences.o
obj/extensions/common/common/options_page_info.o
obj/ios/web/content/init/extensions/clients/ios_extensions_api_provider.o
obj/ios/web/content/init/extensions/ios_api_features/ios_api_features.o
obj/ios/web/content/init/extensions/ios_permission_features/ios_permission_features.o
obj/ios/web/content/init/extensions/ios_api_json_strings/generated_schemas.o
obj/extensions/browser/browser_sources/event_router.o
obj/extensions/browser/browser_sources/extension_function_dispatcher.o
obj/extensions/browser/browser_sources/extension_protocols.o
obj/extensions/browser/browser_sources/process_map.o
obj/extensions/browser/browser_sources/url_request_util.o
obj/extensions/browser/api/messaging/messaging/extension_message_port.o
obj/extensions/browser/api/messaging/messaging/message_service_bindings.o
obj/ui/base/clipboard/clipboard/clipboard_ios.o
obj/components/input/input/web_input_event_builders_ios.o
obj/ios/chrome/browser/extensions/model/model/ios_commands_api.o
obj/ios/chrome/browser/extensions/model/model/ios_extensions_browser_api_provider.o
obj/ios/chrome/browser/extensions/model/model/ios_tabs_api.o
obj/ios/chrome/browser/extensions/model/model/ios_signed_extension_package.o
obj/ios/chrome/browser/extensions/model/model/ios_store_crx_download.o
obj/ios/chrome/browser/curium/bootstrap/cr_ios_engine_bootstrap.o
obj/ios/chrome/browser/curium/curium/curium_browser_host.o
obj/ios/chrome/browser/curium/curium/curium_browser_provider.o
obj/ios/chrome/browser/curium/download_router/curium_download_router.o
obj/ios/chrome/browser/curium/curium/curium_download_task.o
obj/ios/chrome/browser/curium/curium/curium_tab_host.o
obj/ios/chrome/browser/curium/curium/curium_web_state_delegate.o
obj/media/base/mac/mac/ios_pip_buffer_registry.o
obj/media/base/mac/mac/ios_pip_frame_hub.o
obj/content/browser/browser/picture_in_picture_service_impl.o
obj/content/browser/browser/picture_in_picture_session.o
obj/content/browser/browser/video_picture_in_picture_window_controller_impl.o
obj/ios/web/content/content/ios_video_overlay_window.o
obj/third_party/blink/renderer/platform/media/media/video_frame_compositor.o
obj/third_party/blink/renderer/platform/media/media/web_media_player_impl.o
obj/content/app/app/content_main.o
obj/v8/v8_libbase/ios-jit-memory.o
obj/third_party/blink/renderer/modules/webaudio/webaudio/audio_context.o
obj/cc/cc/browser_controls_offset_manager.o
obj/cc/cc/viewport.o
obj/cc/cc/layer_tree_host.o
obj/cc/cc/layer_tree_host_impl.o
obj/cc/cc/layer_tree_impl.o
obj/components/gcm_driver/gcm_driver/gcm_driver_desktop.o
obj/components/input/input/input_router_impl.o
obj/components/input/input/render_input_router.o
obj/components/input/input/render_widget_host_input_event_router.o
obj/components/optimization_guide/core/prediction/prediction_model_download_manager.o
obj/components/optimization_guide/core/hints/hints_manager.o
obj/components/optimization_guide/core/core_util/optimization_guide_permissions_util.o
obj/components/viz/service/service/surface_aggregator.o
obj/components/viz/service/service/compositor_frame_sink_support.o
obj/content/browser/browser/popup_menu_helper_ios.o
obj/content/browser/browser/render_widget_host_impl.o
obj/content/browser/browser/render_widget_host_view_ios.o
obj/content/browser/browser/render_widget_host_view_ios_uiview.o
obj/content/browser/browser/web_contents_view_ios.o
obj/third_party/blink/renderer/core/core_hot/document.o
obj/third_party/blink/renderer/core/exported/exported/web_view_impl.o
obj/third_party/blink/renderer/core/core/browser_controls.o
obj/ios/web/js_features/window_error/error_reporting/web_js_error_report_processor.o
obj/third_party/blink/renderer/core/core/web_frame_widget_impl.o
obj/third_party/blink/renderer/core/core/frame_loader.o
obj/components/viz/common/common/presented_top_controls_offset_ios.o
obj/components/embedder_support/user_agent/user_agent_utils.o
obj/components/favicon/ios/ios/web_favicon_driver.o
obj/ios/chrome/browser/net/model/model/ios_chrome_http_user_agent_settings.o
obj/ios/web/content/content/content_browser_context.o
obj/ios/web/content/content/content_navigation_manager.o
obj/ios/web/content/init/init/ios_main_delegate.o
obj/third_party/blink/renderer/core/core/navigator_base.o
obj/content/renderer/renderer/render_frame_impl.o
obj/ios/chrome/browser/shared/model/paths/paths/paths.o
obj/third_party/blink/common/common/approximated_device_memory.o
obj/third_party/blink/common/common/curium_fingerprint_config.o
obj/third_party/blink/renderer/core/core/navigator_concurrent_hardware.o
obj/third_party/blink/renderer/core/core/timezone_controller.o
obj/third_party/blink/renderer/modules/webgl/webgl/webgl_rendering_context_base.o
EOF
  python3 - <<'PY'
import os
import sys
from pathlib import Path
sys.path.insert(0, "scripts")
from ninja_graph import Graph, deps, is_target_object, is_target_work, unescape

graph = Graph(Path("/tmp/cb_work/src/out/Release"))

# Check the framework's actual link inputs and archive members. The public
# Mojo wire types and unrelated metrics or enterprise reporting can stay.
framework = "obj/ios/chrome/app/chrome_framework"
link_index = graph.producer.get(framework)
if link_index is None or not graph.edges[link_index].rule.endswith("solink"):
    sys.exit(f"Cannot audit Reporting/NEL: missing framework link edge for {framework}")
link = graph.edges[link_index]
pending = link.ins + link.iins
seen = set()
reporting_sources = set()
while pending:
    node = pending.pop()
    index = graph.producer.get(node)
    if index is None or index in seen:
        continue
    seen.add(index)
    edge = graph.edges[index]
    if is_target_object(edge):
        for source in map(unescape, edge.ins):
            if source.startswith(("../../net/reporting/", "../../net/network_error_logging/")) or source in {
                "../../net/extras/sqlite/sqlite_persistent_reporting_and_nel_store.cc",
                "../../services/network/public/cpp/reporting_api_endpoint_mojom_traits.cc",
                "../../services/network/public/cpp/reporting_api_report_mojom_traits.cc",
            }:
                reporting_sources.add(source)
    elif unescape(node).endswith(".a"):
        pending.extend(edge.ins + edge.iins)
if reporting_sources:
    sys.exit("Reporting/NEL still in the candidate framework link:\n" + "\n".join(sorted(reporting_sources)))
print("Verified candidate framework link excludes Reporting/NEL objects")

targets_path = Path(os.environ["RUNNER_TEMP"]) / "graph-diagnosis/compile_targets.txt"
targets = targets_path.read_text().splitlines()
# Also resolve our patched V8 target objects (handles v8_cluster_source_set names).
v8_basenames = {
    "code-range.o",
    "code-memory-access.o",
    "memory-allocator.o",
    "sweeper.o",
    "deoptimizer-arm64.o",
    "instructions-arm64.o",
}
found_v8 = set()
for out in sorted(graph.producer.keys()):
    if out.startswith("obj/v8/") and out.rsplit("/", 1)[-1] in v8_basenames:
        if out not in targets:
            targets.append(out)
        found_v8.add(out.rsplit("/", 1)[-1])
missing_v8 = v8_basenames - found_v8
if missing_v8:
    sys.exit(f"Missing patched V8 device object targets: {sorted(missing_v8)}")
# Also resolve Build 41 patched objects across content/ios/blink targets so
# graph-diagnose verifies every newly patched TU before the 18-shard build.
build41_specs = [
    ("obj/content/browser/", "download_item_utils.o"),
    ("obj/content/browser/", "download_manager_impl.o"),
    ("obj/content/browser/", "geolocation_service_impl.o"),
    ("obj/ios/web/content/", "content_permission_manager.o"),
    ("obj/ios/web/content/", "content_download_task.o"),
    ("obj/third_party/blink/renderer/core/", "html_media_element.o"),
    ("obj/third_party/blink/renderer/core/", "html_video_element.o"),
    ("obj/third_party/blink/renderer/modules/", "picture_in_picture_controller_impl.o"),
    ("obj/third_party/blink/renderer/modules/", "document_video_picture_in_picture.o"),
    ("obj/third_party/blink/renderer/modules/", "media_session.o"),
    ("obj/third_party/blink/renderer/core/", "media_values.o"),
    ("obj/third_party/blink/renderer/core/", "style_builder_converter.o"),
    ("obj/third_party/blink/renderer/core/", "execution_context.o"),
    ("obj/third_party/blink/renderer/core/", "local_dom_window.o"),
    ("obj/third_party/blink/renderer/core/", "screen.o"),
    ("obj/third_party/blink/renderer/core/", "canvas_async_blob_creator.o"),
    ("obj/third_party/blink/renderer/core/", "html_canvas_element.o"),
    ("obj/third_party/blink/renderer/modules/", "base_rendering_context_2d.o"),
    ("obj/third_party/blink/renderer/modules/", "dom_plugin_array.o"),
    ("obj/third_party/blink/renderer/modules/", "screen_orientation_controller.o"),
    ("obj/third_party/blink/renderer/modules/", "speech_synthesis.o"),
    ("obj/third_party/blink/renderer/modules/", "analyser_node.o"),
    ("obj/third_party/blink/renderer/modules/", "offline_audio_context.o"),
    ("obj/third_party/blink/renderer/platform/", "font_cache.o"),
    ("obj/third_party/blink/renderer/platform/", "font_cache_ios.o"),
    ("obj/third_party/blink/renderer/platform/", "image_data_buffer.o"),
]
missing_b41 = []
for prefix, base in build41_specs:
    matches = [
        out for out in sorted(graph.producer.keys())
        if out.startswith(prefix) and out.rsplit("/", 1)[-1] == base
    ]
    if not matches:
        missing_b41.append(f"{prefix}.../{base}")
    else:
        for out in matches:
            if out not in targets:
                targets.append(out)
if missing_b41:
    sys.exit(f"Missing Build 41 device object targets: {missing_b41}")
# Also resolve Build 43 patched objects across blink/ios targets so
# graph-diagnose verifies every newly patched TU before the 18-shard build.
build43_specs = [
    ("obj/third_party/blink/common/", "curium_runtime_policy.o"),
    ("obj/third_party/blink/common/", "curium_desktop_parity.o"),
    ("obj/third_party/blink/common/", "global_privacy_control_util.o"),
    ("obj/ios/web/content/", "content_web_frames_manager.o"),
    ("obj/ios/web/content/", "content_java_script_feature_manager.o"),
    ("obj/third_party/blink/renderer/modules/", "network_information.o"),
    ("obj/third_party/blink/renderer/modules/", "presentation_error.o"),
    ("obj/third_party/blink/renderer/modules/", "media_capabilities.o"),
    ("obj/third_party/blink/renderer/modules/", "public_key_credential.o"),
    ("obj/third_party/blink/renderer/modules/", "language_detector.o"),
    ("obj/third_party/blink/renderer/modules/", "summarizer.o"),
]
missing_b43 = []
for prefix, base in build43_specs:
    matches = [
        out for out in sorted(graph.producer.keys())
        if out.startswith(prefix) and out.rsplit("/", 1)[-1] == base
    ]
    if not matches:
        missing_b43.append(f"{prefix}.../{base}")
    else:
        for out in matches:
            if out not in targets:
                targets.append(out)
if missing_b43:
    sys.exit(f"Missing Build 43 device object targets: {missing_b43}")
targets_path.write_text("\n".join(targets) + "\n")
missing = set(targets) - graph.producer.keys()
if missing:
    sys.exit(f"Missing extension object targets (enable extensions core): {sorted(missing)}")
pending = list(targets)
seen = set()
device_objects = set()
while pending:
    index = graph.producer.get(pending.pop())
    if index is None or index in seen:
        continue
    seen.add(index)
    edge = graph.edges[index]
    if graph.is_apple(edge):
        sys.exit(f"Unexpected Apple tool dependency: {edge.outs}")
    if is_target_object(edge):
        device_objects.update(edge.outs)
    elif is_target_work(edge):
        sys.exit(f"Unexpected device archive, link or Swift dependency: {edge.outs}")
    pending.extend(deps(edge))
if device_objects != set(targets):
    sys.exit(f"Probe must compile only its declared device objects: {sorted(device_objects)}")
print(f"Verified {len(targets)} device objects; no Apple tools in their dependency closure")
PY
  mapfile -t targets < "$art/compile_targets.txt"
  "$NINJA" -C "$LOUT" -n "${targets[@]}" > "$art/compile_plan.txt"
  ccache -z
  export_env PROBE_BUILD_STARTED true
  "$SCRIPTS/run_with_budget.py" --deadline-epoch "$(build_deadline)" --log "$art/compile.log" -- \
    "$NINJA" -C "$LOUT" -j 2 -k 0 "${targets[@]}" || rc=$?
  ccache -s || true
  if [ -f "$STATE/probe_cache_seeded" ]; then
    ccache --evict-older-than 1d || echo "::warning::Could not trim unused seed entries"
  fi
  return "$rc"
}

# Pre-compile gate (Linux): restores Stage 1 codegen + Stage 2 Apple outputs and
# compiles patched ObjC++ objects that depend on Swift-generated headers before
# fanning out the 18 compile shards.
probe_apple_objects() {
  init_linux
  prepare_linux compile
  ccache_env
  export PATH="$LWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  export APPLE_TOOL_MODE=replay APPLE_TOOL_CACHE_DIR="$RUNNER_TEMP/apple_tool_cache"
  cat > "$STATE/apple_object_targets.txt" <<'EOF'
obj/ios/chrome/browser/web/model/web_internal/chrome_web_client.o
EOF
  python3 - "$STATE/apple_object_targets.txt" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "scripts")
from ninja_graph import Graph

graph = Graph(Path("/tmp/cb_work/src/out/Release"))
targets = [line.strip() for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
missing = [target for target in targets if target not in graph.producer]
if missing:
    sys.exit(f"Missing Swift/Apple-dependent probe targets: {missing}")
print(f"Verified {len(targets)} Apple-dependent device object target(s) in pruned graph")
PY
  dry_run_summary "$STATE/apple_object_targets.txt" > "$STATE/apple_object_plan.txt"
  cat "$STATE/apple_object_plan.txt"
  ccache -z >/dev/null
  local rc=0
  build_targets "$STATE/apple_object_targets.txt" || rc=$?
  ccache -s || true
  [ "$rc" -ne 124 ] || fail "Apple-dependent object gate exceeded its build budget"
  [ "$rc" -eq 0 ] || fail "Apple-dependent object gate failed (see FAILED blocks above)"
}

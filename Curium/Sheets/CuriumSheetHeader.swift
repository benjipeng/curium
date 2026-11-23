import SwiftUI
import UIKit

struct CuriumSheetHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { dismiss() } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

/// Compact inline notice shown inside Library sheets when SQLite storage is unavailable,
/// keeping bottom toolbars, search bars, and the software keyboard unobstructed.
struct CuriumStorageUnavailableBanner: View {
    var body: some View {
        Label("Bookmarks and history can’t be saved right now.", systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .overlay(alignment: .bottom) {
                Divider()
            }
    }
}

/// Presents `store.sheetErrorMessage` inside the active modal sheet and clears it on
/// dismiss so errors never get dropped behind sheets or wedge media permission prompts.
struct CuriumSheetErrorAlertModifier: ViewModifier {
    let store: CuriumBrowserStore
    let presentationDelay: Duration

    @State private var activeMessage: String?
    @State private var isReady = false
    @State private var promoteTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .task {
                // Allow a newly presented sheet's transition animation to finish before
                // showing an error queued when the sheet opened (e.g. 24-tab guard).
                if store.sheetErrorMessage != nil {
                    try? await Task.sleep(for: .milliseconds(350))
                }
                guard !Task.isCancelled else { return }
                isReady = true
                promotePendingErrorIfNeeded()
            }
            .onChange(of: store.sheetErrorMessage) { _, newValue in
                guard isReady, newValue != nil else { return }
                promoteTask?.cancel()
                if presentationDelay > .zero {
                    promoteTask = Task {
                        try? await Task.sleep(for: presentationDelay)
                        guard !Task.isCancelled else { return }
                        promoteTask = nil
                        promotePendingErrorIfNeeded()
                    }
                } else {
                    promotePendingErrorIfNeeded()
                }
            }
            .onDisappear {
                promoteTask?.cancel()
                promoteTask = nil
            }
            .alert("Curium", isPresented: Binding(
                get: { activeMessage != nil },
                set: { if !$0 { dismissAlert() } }
            )) {
                Button("OK", role: .cancel) { dismissAlert() }
            } message: {
                Text(activeMessage ?? "")
            }
    }

    private func promotePendingErrorIfNeeded() {
        guard activeMessage == nil, let message = store.sheetErrorMessage else { return }
        activeMessage = message
    }

    private func dismissAlert() {
        activeMessage = nil
        store.sheetErrorMessage = nil
    }
}

extension View {
    func curiumSheetErrorAlert(
        store: CuriumBrowserStore,
        presentationDelay: Duration = .zero
    ) -> some View {
        modifier(CuriumSheetErrorAlertModifier(store: store, presentationDelay: presentationDelay))
    }
}

enum CuriumJitPreference: String, CaseIterable, Identifiable {
    case automatic
    case jitless

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic (JIT when available)"
        case .jitless: return "Jitless Only"
        }
    }
}

enum CuriumUABrandPreference: String, CaseIterable, Identifiable {
    case chrome
    case chromium

    var id: String { rawValue }
    var title: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .chromium: return "Chromium"
        }
    }
}

enum CuriumMobileUAPreference: String, CaseIterable, Identifiable {
    case android
    case ios

    var id: String { rawValue }
    var title: String {
        switch self {
        case .android: return "Android Chrome"
        case .ios: return "iOS Blink"
        }
    }
}

struct CuriumSettingsSheet: View {
    @Binding var palette: CuriumPalette
    @Binding var siteMode: CuriumSiteMode
    @Bindable var library: CuriumLibrary
    @AppStorage("curium.jitMode") private var jitPreference: CuriumJitPreference = .automatic
    @AppStorage("curium.uaBrand") private var uaBrandPreference: CuriumUABrandPreference = .chrome
    @AppStorage("curium.mobileUA") private var mobileUAPreference: CuriumMobileUAPreference = .android
    let engineReady: Bool

    @State private var showingDiagnostics = false
    @State private var showingFingerprintStudio = false
    @State private var availableMemoryText = ""
    @State private var hooksSummary = ""
    @State private var hasHookFailure = false
    @State private var diagnosticLineCount = 0
    @State private var engineFingerprintStatus: CuriumEngineFingerprintStatus?

    private var fingerprintStore: CuriumFingerprintStore { CuriumFingerprintStore.shared }

    private var activeV8RuntimeLabel: String {
        guard engineReady else { return "Standby" }
        return CuriumDiagnostics.jitModeLabel(CuriumActiveV8JitMode())
    }

    var body: some View {
        VStack(spacing: 0) {
            CuriumSheetHeader(title: "Settings")
            List {
                Section("Search Engine") {
                    ForEach(CuriumSearchEngine.allCases) { engine in
                        Button {
                            library.searchEngine = engine
                        } label: {
                            HStack {
                                Text(engine.title).foregroundStyle(.primary)
                                Spacer()
                                if library.searchEngine == engine {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityAddTraits(library.searchEngine == engine ? .isSelected : [])
                    }
                }

                Section {
                    ForEach(CuriumSiteMode.allCases) { mode in
                        Button {
                            siteMode = mode
                        } label: {
                            HStack {
                                Text(mode.title).foregroundStyle(.primary)
                                Spacer()
                                if siteMode == mode {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(siteMode == mode ? .isSelected : [])
                    }
                } header: {
                    Text("Default Site Layout")
                } footer: {
                    Text("Duo Adaptive loads full Desktop layouts on the 7.6-inch unfolded display and Mobile layouts on the outer cover display.")
                }

                Section("Appearance") {
                    ForEach(CuriumPalette.allCases) { option in
                        Button {
                            palette = option
                        } label: {
                            HStack {
                                Circle()
                                    .fill(option.tint)
                                    .frame(width: 14, height: 14)
                                    .accessibilityHidden(true)
                                Text(option.title).foregroundStyle(.primary)
                                Spacer()
                                Text(option.notation)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if palette == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(palette == option ? .isSelected : [])
                    }
                }
                Section {
                    ForEach(CuriumJitPreference.allCases) { option in
                        Button {
                            jitPreference = option
                        } label: {
                            HStack {
                                Text(option.title).foregroundStyle(.primary)
                                Spacer()
                                if jitPreference == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(jitPreference == option ? .isSelected : [])
                    }
                } header: {
                    Text("JavaScript Engine (V8)")
                } footer: {
                    Text("Applies on next launch. Under LiveContainer on iOS 26/27, enable Launch with JIT with StikDebug's universal.js script; otherwise Curium runs safely in Jitless mode.")
                }

                Section {
                    Button {
                        showingFingerprintStudio = true
                    } label: {
                        LabeledContent {
                            HStack(spacing: 6) {
                                Text(fingerprintStore.selectedProfile?.displayName ?? "Default (Build 39)")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Manage Profiles & Fingerprints")
                                    .foregroundStyle(.primary)
                                Text(selectedProfileSummarySubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("curium.settings.fingerprintStudio")

                    if fingerprintStore.selectedProfileID == nil {
                        Picker("Browser Brand", selection: $uaBrandPreference) {
                            ForEach(CuriumUABrandPreference.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Picker("Mobile Profile", selection: $mobileUAPreference) {
                            ForEach(CuriumMobileUAPreference.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    }
                } header: {
                    Text("Browser Identity & Profile")
                } footer: {
                    if let status = engineFingerprintStatus {
                        Text("Active engine profile: \(status.appliedProfileId) (\(status.state), rev \(status.appliedConfigRevision), \(status.hardwareOverridesActive ? "hardware override" : "native Apple hardware")). Profile switches apply on next cold launch.")
                    } else {
                        Text("Profile switches apply on next cold launch with isolated cookies, storage, and preferences.")
                    }
                }

                Section("Browser") {
                    LabeledContent("Engine", value: engineReady ? "Blink · Single-Process" : "Blink · Standby")
                    LabeledContent("V8 Runtime", value: activeV8RuntimeLabel)
                    LabeledContent("Available Memory", value: availableMemoryText)
                    LabeledContent("Engine Hooks") {
                        Text(hooksSummary)
                            .foregroundStyle(hasHookFailure ? .red : .secondary)
                    }
                    Button {
                        showingDiagnostics = true
                    } label: {
                        LabeledContent("Diagnostics Log") {
                            HStack(spacing: 6) {
                                Text("\(diagnosticLineCount) lines")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("curium.settings.diagnostics")
                    LabeledContent("Extensions", value: "Manifest V3")
                    LabeledContent("Element", value: "96 Cm")
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { refreshDiagnosticsSummary() }
        .sheet(isPresented: $showingFingerprintStudio, onDismiss: { refreshDiagnosticsSummary() }) {
            CuriumFingerprintStudioSheet(store: fingerprintStore) {
                refreshDiagnosticsSummary()
            }
        }
        .sheet(isPresented: $showingDiagnostics, onDismiss: { refreshDiagnosticsSummary() }) {
            CuriumDiagnosticsSheet(engineReady: engineReady)
        }
    }

    private var selectedProfileSummarySubtitle: String {
        if let profile = fingerprintStore.selectedProfile {
            let hw = profile.usesNativeHardwareAndGPU ? "Native Apple HW/GPU" : "Custom HW/GPU"
            return "\(profile.id) · \(hw) · \(profile.proxy.summary)"
        }
        return "Legacy Chromium profile · Native Apple HW/GPU"
    }

    private func refreshDiagnosticsSummary() {
        let diag = CuriumDiagnostics.shared
        availableMemoryText = ByteCountFormatter.string(
            fromByteCount: Int64(CuriumAvailableMemoryBytes()),
            countStyle: .memory
        )
        let summary = CuriumDiagnostics.summarizeHooks(diag.hookStatuses())
        hooksSummary = summary.summary
        hasHookFailure = summary.hasFailure
        diagnosticLineCount = diag.currentLines().count
        engineFingerprintStatus = CuriumFingerprintBootstrap.activeEngineStatus()
    }
}

private struct CuriumDiagnosticsSheet: View {
    let engineReady: Bool

    @State private var hookStatuses: [CuriumDiagnostics.HookStatus] = []
    @State private var lines: [String] = []
    @State private var reportText = ""
    @State private var availableMemoryText = ""
    @State private var logFileSummary = "Memory only"
    @State private var copied = false
    @State private var fingerprintStatus: CuriumEngineFingerprintStatus?
    @State private var fingerprintCapabilities: CuriumEngineFingerprintCapabilities?
    @State private var nextLaunchProfileLabel = "Default (Build 39)"
    @State private var reloadTask: Task<Void, Never>?

    private var environmentLabel: String {
        ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil
            ? "LiveContainer Guest"
            : "Standalone / Simulator"
    }

    var body: some View {
        VStack(spacing: 0) {
            CuriumSheetHeader(title: "Diagnostics")
            List {
                Section("Actions") {
                    Button {
                        UIPasteboard.general.string = reportText
                        copied = true
                    } label: {
                        Label(copied ? "Copied to Clipboard" : "Copy Diagnostics",
                              systemImage: copied ? "checkmark.circle" : "doc.on.doc")
                    }
                    ShareLink(item: reportText) {
                        Label("Share Diagnostics Report", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        reload(flushFirst: true)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }

                Section("Runtime") {
                    LabeledContent("Environment", value: environmentLabel)
                    LabeledContent("V8 Runtime", value: engineReady ? CuriumDiagnostics.jitModeLabel(CuriumActiveV8JitMode()) : "Standby")
                    LabeledContent("Available Memory", value: availableMemoryText)
                    LabeledContent("Log File", value: logFileSummary)
                }

                Section("Fingerprint & Profile Contract") {
                    if let status = fingerprintStatus {
                        LabeledContent("Contract Version", value: "v\(status.contractVersion)")
                        LabeledContent("Engine State") {
                            Text(status.state)
                                .font(.caption.monospaced())
                                .foregroundStyle(status.state == "rejected" ? .red : .secondary)
                        }
                        LabeledContent("Applied Profile") {
                            Text("\(status.appliedProfileId) (rev \(status.appliedConfigRevision))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Directory Opened", value: status.profileDirectoryOpened ? "Yes" : "No")
                        if status.contractVersion > 0 {
                            LabeledContent("Default Slot", value: status.defaultSlot)
                            LabeledContent("Proxy Mode", value: status.proxyMode)
                            LabeledContent("Hardware Mode", value: status.hardwareOverridesActive ? "Custom Override" : "Native Apple HW/GPU")
                        }
                        if let reason = status.rejectionReason, !reason.isEmpty {
                            LabeledContent("Rejection") {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    } else {
                        LabeledContent("Engine Contract", value: "Not linked / Pre-Build 40")
                    }

                    LabeledContent("Next Launch Selection", value: nextLaunchProfileLabel)

                    if let caps = fingerprintCapabilities, caps.supportsLaunchFingerprintConfig {
                        DisclosureGroup("Engine Capabilities (\(caps.features.count) features)") {
                            LabeledContent("Max Config Payload", value: "\(caps.maxConfigBytes) bytes")
                            ForEach(caps.features.keys.sorted(), id: \.self) { key in
                                LabeledContent(key) {
                                    Text(caps.features[key] == true ? "enabled" : "off")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(caps.features[key] == true ? .green : .secondary)
                                }
                            }
                            ForEach(caps.activationScopes.keys.sorted(), id: \.self) { key in
                                LabeledContent("scope.\(key)") {
                                    Text(caps.activationScopes[key] ?? "")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Engine Hooks") {
                    ForEach(hookStatuses) { hook in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(hook.name)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(hook.status)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(statusColor(for: hook))
                            }
                            if !hook.detail.isEmpty {
                                Text(hook.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Rolling Log (\(lines.count))") {
                    if lines.isEmpty {
                        Text("No diagnostic events recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(lines.joined(separator: "\n"))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { reload(flushFirst: true) }
        .onDisappear {
            reloadTask?.cancel()
            reloadTask = nil
        }
    }

    private func reload(flushFirst: Bool = false) {
        let diag = CuriumDiagnostics.shared
        let hooks = diag.hookStatuses()
        let current = diag.currentLines()
        let status = CuriumFingerprintBootstrap.activeEngineStatus()
        let caps = CuriumFingerprintBootstrap.engineCapabilities()
        let nextLabel = CuriumFingerprintStore.shared.selectedProfileID ?? "default (Build 39)"

        hookStatuses = hooks
        lines = current
        fingerprintStatus = status
        fingerprintCapabilities = caps
        nextLaunchProfileLabel = nextLabel
        reportText = diag.formattedReport(
            hooks: hooks,
            lines: current,
            fingerprintStatus: status,
            fingerprintCapabilities: caps,
            nextLaunchProfile: nextLabel
        )
        availableMemoryText = ByteCountFormatter.string(
            fromByteCount: Int64(CuriumAvailableMemoryBytes()),
            countStyle: .memory
        )
        copied = false

        let logURL = diag.logFileURL
        reloadTask?.cancel()
        reloadTask = Task {
            let summary: String
            if let logURL {
                let size = await Task.detached(priority: .utility) {
                    if flushFirst {
                        diag.flushSync()
                    }
                    return (try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                }.value
                guard !Task.isCancelled else { return }
                let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                summary = "\(logURL.lastPathComponent) (\(formattedSize))"
            } else {
                summary = "Memory only"
            }
            guard !Task.isCancelled else { return }
            logFileSummary = summary
            reloadTask = nil
        }
    }

    private func statusColor(for hook: CuriumDiagnostics.HookStatus) -> Color {
        if hook.isActive { return .green }
        if hook.isFailed { return .red }
        return .secondary
    }
}

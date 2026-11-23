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
    let engineReady: Bool
    var browserStore: CuriumBrowserStore? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var presentedSheet: PresentedSheet?
    @State private var saveFolderFlow = CuriumSaveFolderFlowState()
    @State private var availableMemoryText = ""
    @State private var hooksSummary = ""
    @State private var hasHookFailure = false
    @State private var diagnosticLineCount = 0
    @State private var engineFingerprintStatus: CuriumEngineFingerprintStatus?

    private enum PresentedSheet: Identifiable {
        case profiles
        case diagnostics

        var id: Self { self }
    }

    private var fingerprintStore: CuriumFingerprintStore { CuriumFingerprintStore.shared }
    private var folderManager: CuriumDownloadsFolderManager { CuriumDownloadsFolderManager.shared }

    private var uaBrandBinding: Binding<CuriumUABrandPreference> {
        Binding(
            get: {
                CuriumUABrandPreference(rawValue: fingerprintStore.activeProfile.legacyUABrandRawValue) ?? .chrome
            },
            set: { newValue in
                _ = fingerprintStore.applyLegacyIdentityPreferencesToPersonal(uaBrand: newValue.rawValue)
            }
        )
    }

    private var mobileUABinding: Binding<CuriumMobileUAPreference> {
        Binding(
            get: {
                CuriumMobileUAPreference(rawValue: fingerprintStore.activeProfile.legacyMobileUARawValue) ?? .android
            },
            set: { newValue in
                _ = fingerprintStore.applyLegacyIdentityPreferencesToPersonal(mobileUA: newValue.rawValue)
            }
        )
    }

    private var activeV8RuntimeLabel: String {
        guard engineReady else { return "Standby" }
        return CuriumDiagnostics.jitModeLabel(CuriumActiveV8JitMode())
    }

    var body: some View {
        let activeProfile = fingerprintStore.activeProfile
        let activeProfilePalette = activeProfile.resolvedPalette
        let hasPendingSwitch = fingerprintStore.hasPendingProfileSwitch
        let hasPendingActiveRestart = fingerprintStore.hasPendingActiveProfileEngineChanges
        let nextProfile = hasPendingSwitch ? fingerprintStore.nextLaunchProfile : nil
        let _ = folderManager.status
        let _ = folderManager.revision
        let downloadsDisplayPath = CuriumDownloadsFolderManager.displayDownloadsPath

        NavigationStack {
            List {
                Section {
                    Button {
                        presentedSheet = .profiles
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: activeProfile.resolvedSymbolName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(activeProfilePalette.tint)
                                .frame(width: 36, height: 36)
                                .background(activeProfilePalette.tile, in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(activeProfile.displayName)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(activeProfile.shortArchetypeSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if let nextProfile {
                                    Text(
                                        hasPendingActiveRestart
                                            ? "Restart required to apply changes"
                                            : "Next launch: \(nextProfile.displayName)"
                                    )
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(hasPendingActiveRestart ? Color.orange : nextProfile.resolvedPalette.tint)
                                    .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("curium.settings.fingerprintStudio")

                    if activeProfile.isPrimaryDefault && activeProfile.supportsLegacyIdentityPickers {
                        Picker("Browser Brand", selection: uaBrandBinding) {
                            ForEach(CuriumUABrandPreference.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Picker("Mobile Profile", selection: mobileUABinding) {
                            ForEach(CuriumMobileUAPreference.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    }
                } header: {
                    Text("Browser Identity & Profile")
                } footer: {
                    if let status = engineFingerprintStatus {
                        Text("Active engine profile: \(activeProfile.displayName) (\(status.appliedProfileId), \(status.state), rev \(status.appliedConfigRevision), \(status.hardwareOverridesActive ? "hardware override" : "native Apple hardware")). Profile switches apply on next cold launch.")
                    } else {
                        Text("Profile switches apply on next cold launch with isolated cookies, storage, bookmarks, and tabs.")
                    }
                }

                Section {
                    ForEach(CuriumSearchEngine.allCases) { engine in
                        Button {
                            library.searchEngine = engine
                        } label: {
                            HStack {
                                Text(engine.title).foregroundStyle(Color.primary)
                                Spacer()
                                if library.searchEngine == engine {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .foregroundStyle(Color.primary)
                        .accessibilityAddTraits(library.searchEngine == engine ? .isSelected : [])
                    }
                } header: {
                    Text("Search Engine")
                } footer: {
                    Text("Saved per profile (\(activeProfile.displayName)).")
                }

                Section {
                    ForEach(CuriumSiteMode.allCases) { mode in
                        Button {
                            siteMode = mode
                        } label: {
                            HStack {
                                Text(mode.title).foregroundStyle(Color.primary)
                                Spacer()
                                if siteMode == mode {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(Color.primary)
                        .accessibilityAddTraits(siteMode == mode ? .isSelected : [])
                    }
                } header: {
                    Text("Default Site Layout")
                } footer: {
                    Text("Duo Adaptive loads full Desktop layouts on the 7.6-inch unfolded display and Mobile layouts on the outer cover display. Saved per profile (\(activeProfile.displayName)).")
                }

                Section {
                    ForEach(CuriumPalette.allCases) { option in
                        Button {
                            palette = option
                        } label: {
                            HStack {
                                Circle()
                                    .fill(option.tint)
                                    .frame(width: 14, height: 14)
                                    .accessibilityHidden(true)
                                Text(option.title).foregroundStyle(Color.primary)
                                Spacer()
                                Text(option.notation)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if palette == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(Color.primary)
                        .accessibilityAddTraits(palette == option ? .isSelected : [])
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Applies to the active profile (\(activeProfile.displayName)).")
                }

                Section {
                    CuriumSaveLocationRow(
                        flow: $saveFolderFlow,
                        accessibilityID: "curium.settings.saveLocation"
                    ) {
                        browserStore?.refreshSavedDownloads()
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Saved to \(downloadsDisplayPath). Downloads are shared across all profiles.")
                }

                Section {
                    ForEach(CuriumJitPreference.allCases) { option in
                        Button {
                            jitPreference = option
                        } label: {
                            HStack {
                                Text(option.title).foregroundStyle(Color.primary)
                                Spacer()
                                if jitPreference == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(Color.primary)
                        .accessibilityAddTraits(jitPreference == option ? .isSelected : [])
                    }
                } header: {
                    Text("JavaScript Engine (V8)")
                } footer: {
                    Text("Applies on next launch. Under LiveContainer on iOS 26/27, enable Launch with JIT with StikDebug's universal.js script; otherwise Curium runs safely in Jitless mode.")
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
                        presentedSheet = .diagnostics
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
            .curiumSaveFolderPickerFlow($saveFolderFlow) {
                browserStore?.refreshSavedDownloads()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
        }
        .onAppear {
            folderManager.resolveInBackgroundIfNeeded()
            refreshDiagnosticsSummary()
        }
        .sheet(item: $presentedSheet, onDismiss: { refreshDiagnosticsSummary() }) { item in
            switch item {
            case .profiles:
                CuriumProfileSwitcherSheet(
                    browserStore: browserStore,
                    fingerprintStore: fingerprintStore
                ) {
                    refreshDiagnosticsSummary()
                }
            case .diagnostics:
                CuriumDiagnosticsSheet(engineReady: engineReady)
            }
        }
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

    @Environment(\.dismiss) private var dismiss
    @State private var hookStatuses: [CuriumDiagnostics.HookStatus] = []
    @State private var lines: [String] = []
    @State private var reportText = ""
    @State private var availableMemoryText = ""
    @State private var logFileSummary = "Memory only"
    @State private var copied = false
    @State private var fingerprintStatus: CuriumEngineFingerprintStatus?
    @State private var fingerprintCapabilities: CuriumEngineFingerprintCapabilities?
    @State private var activeProfileLabel = "Personal (default)"
    @State private var nextLaunchProfileLabel = "Personal (default)"
    @State private var hasPendingProfileSwitch = false
    @State private var reloadTask: Task<Void, Never>?

    private var environmentLabel: String {
        ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil
            ? "LiveContainer Guest"
            : "Standalone / Simulator"
    }

    var body: some View {
        NavigationStack {
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
                    LabeledContent("Active Profile") {
                        Text(activeProfileLabel)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Next Launch Profile") {
                        Text(nextLaunchProfileLabel)
                            .font(.caption.monospaced())
                            .foregroundStyle(hasPendingProfileSwitch ? .orange : .secondary)
                            .multilineTextAlignment(.trailing)
                    }

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
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
        }
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
        let store = CuriumFingerprintStore.shared
        let activeProfile = store.activeProfile
        let nextProfile = store.nextLaunchProfile
        let activeLabel = "\(activeProfile.displayName) (\(activeProfile.id))"
        let nextLabel = "\(nextProfile.displayName) (\(nextProfile.id))"

        hookStatuses = hooks
        lines = current
        fingerprintStatus = status
        fingerprintCapabilities = caps
        activeProfileLabel = activeLabel
        nextLaunchProfileLabel = nextLabel
        hasPendingProfileSwitch = store.hasPendingProfileSwitch
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

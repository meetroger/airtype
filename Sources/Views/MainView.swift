import ApplicationServices
import HotKey
import ServiceManagement
import SwiftUI

// MARK: - Design Tokens

enum Theme {
    static let bg = Color(NSColor.windowBackgroundColor)
    static let cardBg = Color(NSColor.controlBackgroundColor)
    static let border = Color(NSColor.separatorColor)
    static let textPrimary = Color(NSColor.labelColor)
    static let textSecondary = Color(NSColor.secondaryLabelColor)
    static let textTertiary = Color(NSColor.tertiaryLabelColor)
    static let brand = Color(red: 52/255, green: 211/255, blue: 153/255)     // #34D399
    static let statusGreen = brand
    static let statusOrange = Color(red: 1.0, green: 0.624, blue: 0.039)    // #FF9F0A
    static let statusRed = Color(red: 1.0, green: 0.271, blue: 0.227)       // #FF453A
}

// MARK: - Main View

@MainActor
private final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isRegistered = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isRegistered = true
            requiresApproval = false
        case .requiresApproval:
            isRegistered = true
            requiresApproval = true
        case .notRegistered, .notFound:
            isRegistered = false
            requiresApproval = false
        @unknown default:
            isRegistered = false
            requiresApproval = false
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case voice = "Voice"
    case ai = "AI"
    case window = "Window"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .voice: return "mic.fill"
        case .ai: return "wand.and.stars"
        case .window: return "macwindow"
        case .shortcuts: return "keyboard"
        }
    }
}

struct MainView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var audioRecorder: AudioRecorder
    @State private var hasAccessibility = AXIsProcessTrusted()
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var localModelManager = LocalModelManager()
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager()
    @State private var availableCustomModels: [String] = []
    @State private var customModelLoadError: String?
    @State private var isLoadingCustomModels = false
    @State private var isEditingEnhancementPrompt = false
    @State private var enhancementPromptDraft = ""
    @State private var selectedSettingsTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            dashboardHeader
            Divider().overlay(Theme.border)
            settingsTabPicker
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(spacing: 16) {
                    if updateChecker.updateAvailable {
                        updateBanner
                    }
                    if selectedSettingsTab == .general && !hasAccessibility {
                        accessibilityBanner
                    }
                    if let error = settings.configurationError {
                        statusBanner(message: error)
                    }
                    selectedSettingsContent
                }
                .padding(24)
            }
        }
        .frame(width: 520, height: 700)
        .background(Theme.bg)
        .tint(Theme.brand)
        .onAppear { updateChecker.check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibility = AXIsProcessTrusted()
            launchAtLoginManager.refresh()
        }
        .sheet(isPresented: $isEditingEnhancementPrompt) {
            EnhancementPromptEditor(
                prompt: $enhancementPromptDraft,
                onSave: {
                    settings.enhancementPrompt = enhancementPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    isEditingEnhancementPrompt = false
                },
                onCancel: { isEditingEnhancementPrompt = false }
            )
        }
    }

    private var settingsTabPicker: some View {
        Picker("Settings category", selection: $selectedSettingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedSettingsTab {
        case .general:
            applicationSection
            permissionsSection
        case .voice:
            voiceInputSection
        case .ai:
            enhancementSection
        case .window:
            floatingWindowSection
        case .shortcuts:
            shortcutsSection
        }
    }

    // MARK: - Application

    private var applicationSection: some View {
        SettingsSection(title: "Application", icon: "gearshape.fill") {
            SettingsCard {
                Toggle(isOn: Binding(
                    get: { launchAtLoginManager.isRegistered },
                    set: { launchAtLoginManager.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Start Airtype silently in the menu bar when you sign in")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .toggleStyle(.switch)

                if launchAtLoginManager.requiresApproval {
                    SettingsCardDivider()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.statusOrange)
                        Text("Approval required in System Settings → General → Login Items")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                } else if let errorMessage = launchAtLoginManager.errorMessage {
                    SettingsCardDivider()
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.statusRed)
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var dashboardHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(settings.isConfigured ? Theme.statusGreen : Theme.statusOrange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Airtype")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(settings.isConfigured ? Theme.statusGreen : Theme.statusOrange)
                        .frame(width: 6, height: 6)
                    Text(settings.isConfigured ? "Ready" : "Setup required")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Status Banner

    private func statusBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.statusOrange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(12)
        .background(Theme.statusOrange.opacity(0.1))
        .clipShape(.rect(cornerRadius: 8))
    }

    // MARK: - Accessibility Banner

    private var accessibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.statusOrange)
            Text("Accessibility permission required for text insertion")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Grant Access") {
                openAccessibilitySettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.statusOrange.opacity(0.1))
        .clipShape(.rect(cornerRadius: 8))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibility = AXIsProcessTrusted()
        }
    }

    // MARK: - Update Banner

    private var updateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.brand)
            Text("Airtype \(updateChecker.latestVersion) available")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Download") {
                if let url = updateChecker.downloadURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.brand.opacity(0.1))
        .clipShape(.rect(cornerRadius: 8))
    }

    // MARK: - Voice Input

    private var voiceInputSection: some View {
        SettingsSection(title: "Voice Input", icon: "mic.fill") {
            SettingsCard {
                SettingsCardRow(label: "Service") {
                    Picker("", selection: $settings.transcriptionProvider) {
                        ForEach(TranscriptionProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .labelsHidden()
                }

                SettingsCardDivider()

                if settings.transcriptionProvider == .elevenlabs {
                    elevenlabsSettings
                } else if settings.transcriptionProvider == .mistral {
                    mistralTranscriptionSettings
                } else if settings.transcriptionProvider == .doubao {
                    doubaoSettings
                } else if settings.transcriptionProvider == .localMLX {
                    localMLXSettings
                } else {
                    openaiTranscriptionSettings
                }

                SettingsCardDivider()

                transcriptionStatus
            }

            SettingsCard {
                Toggle(isOn: $settings.muteSystemAudioWhileRecording) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mute system audio while recording")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Restore the previous audio state after transcription finishes")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var elevenlabsSettings: some View {
        Group {
            SettingsCardRow(label: "API Key") {
                HStack(spacing: 6) {
                    SecureField("xi-...", text: $settings.elevenlabsApiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    apiKeyLink(url: settings.transcriptionProvider.apiKeyURL)
                }
            }
            SettingsCardDivider()
            SettingsCardRow(label: "Model") {
                Picker("", selection: $settings.elevenlabsModel) {
                    ForEach(Settings.elevenlabsModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private var openaiTranscriptionSettings: some View {
        Group {
            SettingsCardRow(label: "API Key") {
                HStack(spacing: 6) {
                    SecureField("sk-...", text: $settings.openaiTranscriptionApiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    apiKeyLink(url: settings.transcriptionProvider.apiKeyURL)
                }
            }
            SettingsCardDivider()
            SettingsCardRow(label: "Model") {
                Picker("", selection: $settings.openaiTranscriptionModel) {
                    ForEach(Settings.openaiTranscriptionModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private var mistralTranscriptionSettings: some View {
        Group {
            SettingsCardRow(label: "API Key") {
                HStack(spacing: 6) {
                    SecureField("...mistral key...", text: $settings.mistralTranscriptionApiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    apiKeyLink(url: settings.transcriptionProvider.apiKeyURL)
                }
            }
            SettingsCardDivider()
            SettingsCardRow(label: "Model") {
                Picker("", selection: $settings.mistralTranscriptionModel) {
                    ForEach(Settings.mistralTranscriptionModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private var doubaoSettings: some View {
        Group {
            SettingsCardRow(label: "App ID") {
                HStack(spacing: 6) {
                    TextField("123456789", text: $settings.doubaoAppId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    apiKeyLink(url: settings.transcriptionProvider.apiKeyURL)
                }
            }
            SettingsCardDivider()
            SettingsCardRow(label: "Access Token") {
                SecureField("your-access-token", text: $settings.doubaoAccessKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            SettingsCardDivider()
            SettingsCardRow(label: "Resource ID") {
                Picker("", selection: $settings.doubaoResourceId) {
                    ForEach(Settings.doubaoResourceIds, id: \.self) { rid in
                        Text(rid).tag(rid)
                    }
                }
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
            }
            SettingsCardDivider()
            SettingsCardRow(label: "Language") {
                Picker("", selection: $settings.doubaoLanguage) {
                    ForEach(Settings.doubaoLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var transcriptionStatus: some View {
        HStack(spacing: 6) {
            if settings.transcriptionProvider.requiresApiKey && settings.currentTranscriptionApiKey.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.statusOrange)
                Text("API key required")
                    .foregroundStyle(Theme.textSecondary)
            } else if settings.transcriptionProvider == .localMLX && !settings.selectedLocalModelInstalled {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.statusOrange)
                Text("Model install required")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.statusGreen)
                Text("Ready")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.system(size: 11))
    }

    private var localMLXSettings: some View {
        Group {
            SettingsCardRow(label: "Model") {
                Picker("", selection: $settings.localMLXModel) {
                    ForEach(LocalMLXModel.allCases) { model in
                        Text(model.rawValue).tag(model)
                    }
                }
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
            }
            SettingsCardDivider()
            SettingsCardRow(label: "Language") {
                Picker("", selection: $settings.localMLXLanguage) {
                    ForEach(LocalMLXLanguage.allCases) { language in
                        Text(language.rawValue).tag(language)
                    }
                }
                .labelsHidden()
            }
            SettingsCardDivider()
            SettingsCardRow(label: "Compute") {
                Picker("", selection: $settings.localMLXComputeMode) {
                    ForEach(LocalMLXComputeMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
            }
            SettingsCardDivider()
            SettingsCardRow(label: "Model Repo") {
                Text(settings.localMLXModel.repoID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            SettingsCardDivider()
            SettingsCardRow(label: "Model Files") {
                HStack(spacing: 8) {
                    Text(settings.selectedLocalModelInstalled ? "Installed" : "Not installed")
                        .font(.system(size: 11))
                        .foregroundStyle(settings.selectedLocalModelInstalled ? Theme.statusGreen : Theme.textSecondary)
                    if settings.selectedLocalModelInstalled {
                        Text("(\(ByteCountFormatter.string(fromByteCount: settings.selectedLocalModelFileSizeBytes, countStyle: .file)))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Install") {
                        Task { await localModelManager.installSelectedModel(settings: settings) }
                    }
                    .disabled(settings.selectedLocalModelInstalled || localModelManager.isInstalling)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Remove") {
                        localModelManager.removeSelectedModel(settings: settings)
                    }
                    .disabled(!settings.selectedLocalModelInstalled || localModelManager.isRemoving)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if let status = localModelManager.statusMessage {
                SettingsCardDivider()
                SettingsCardRow(label: "Install Status") {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if let error = localModelManager.lastError {
                SettingsCardDivider()
                SettingsCardRow(label: "Install Error") {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.statusRed)
                }
            }
            SettingsCardDivider()
            SettingsCardRow(label: "Local Path") {
                HStack(spacing: 8) {
                    Text(Settings.localModelDirectoryURL(for: settings.localMLXModel).path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") {
                        let directoryURL = Settings.localModelDirectoryURL(for: settings.localMLXModel)
                        if !FileManager.default.fileExists(atPath: directoryURL.path) {
                            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Enhancement

    private var enhancementSection: some View {
        SettingsSection(title: "AI Processing", icon: "wand.and.stars") {
            SettingsCard {
                Toggle(isOn: $settings.enhancementEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable enhancement")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Improve accuracy, add punctuation, and format text")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .toggleStyle(.switch)

                SettingsCardDivider()

                SettingsCardRow(label: "Correction Prompt") {
                    HStack(spacing: 8) {
                        if !settings.enhancementEnabled {
                            Text("Enable enhancement to edit")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                        }

                        Button("Edit Prompt…") {
                            enhancementPromptDraft = settings.enhancementPrompt
                            isEditingEnhancementPrompt = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!settings.enhancementEnabled)
                    }
                }
            }

            if settings.enhancementEnabled || settings.translateOnLongPress {
                SettingsCard {
                    SettingsCardRow(label: "Provider") {
                        Picker("", selection: $settings.enhancementProvider) {
                            ForEach(EnhancementProvider.allCases) { provider in
                                Text(provider.rawValue).tag(provider)
                            }
                        }
                        .labelsHidden()
                    }

                    if settings.enhancementProvider.requiresApiKey || settings.enhancementProvider == .custom {
                        SettingsCardDivider()
                        SettingsCardRow(label: "API Key") {
                            HStack(spacing: 6) {
                                SecureField(settings.enhancementProvider.apiKeyPlaceholder, text: Binding(
                                    get: { settings.currentEnhancementApiKey },
                                    set: { settings.currentEnhancementApiKey = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                apiKeyLink(url: settings.enhancementProvider.apiKeyURL)
                            }
                        }
                    }

                    if settings.enhancementProvider.requiresCustomURL {
                        SettingsCardDivider()
                        SettingsCardRow(label: "Base URL") {
                            TextField(settings.enhancementProvider.baseURL, text: Binding(
                                get: { settings.currentEnhancementBaseURL },
                                set: {
                                    settings.currentEnhancementBaseURL = $0
                                    availableCustomModels = []
                                    customModelLoadError = nil
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        }
                    }

                    SettingsCardDivider()

                    SettingsCardRow(label: "Model") {
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 6) {
                                TextField(settings.enhancementProvider.defaultModel, text: Binding(
                                    get: { settings.currentEnhancementModel },
                                    set: { settings.currentEnhancementModel = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))

                                if settings.enhancementProvider == .custom {
                                    Menu {
                                        ForEach(availableCustomModels, id: \.self) { model in
                                            Button(model) { settings.currentEnhancementModel = model }
                                        }
                                    } label: {
                                        Image(systemName: "list.bullet")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .frame(width: 24)
                                    .disabled(availableCustomModels.isEmpty)
                                    .help("Select a model returned by the endpoint")

                                    Button(action: loadCustomModels) {
                                        if isLoadingCustomModels {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(isLoadingCustomModels)
                                    .help("Load models from /models")
                                }
                            }

                            if settings.enhancementProvider == .custom {
                                if let customModelLoadError {
                                    Text(customModelLoadError)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.statusRed)
                                } else if !availableCustomModels.isEmpty {
                                    Text("\(availableCustomModels.count) models available")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }

                    SettingsCardDivider()

                    enhancementStatus
                }
            }
        }
    }

    private var enhancementStatus: some View {
        HStack(spacing: 6) {
            if settings.enhancementProvider.requiresApiKey && settings.currentEnhancementApiKey.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.statusOrange)
                Text("\(settings.enhancementProvider.rawValue) API key required")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.statusGreen)
                Text("Using \(settings.enhancementProvider.rawValue)")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.system(size: 11))
    }

    private func loadCustomModels() {
        isLoadingCustomModels = true
        customModelLoadError = nil

        Task { @MainActor in
            do {
                let models = try await EnhancementService(settings: settings).fetchAvailableModels()
                availableCustomModels = models
                if models.isEmpty {
                    customModelLoadError = "The endpoint returned no models"
                }
            } catch {
                availableCustomModels = []
                customModelLoadError = error.localizedDescription
            }
            isLoadingCustomModels = false
        }
    }

    // MARK: - Floating Window

    private var floatingWindowSection: some View {
        SettingsSection(title: "Floating Window", icon: "macwindow") {
            SettingsCard {
                Toggle(isOn: $settings.showFloatingWindow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show floating window")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Display status and progress in a floating panel")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .toggleStyle(.switch)
            }

            if settings.showFloatingWindow {
                SettingsCard {
                    SettingsCardRow(label: "Position") {
                        Picker("", selection: $settings.floatingWindowPosition) {
                            ForEach(FloatingWindowPosition.allCases) { position in
                                Text(position.rawValue).tag(position)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    SettingsCardDivider()

                    Toggle(isOn: $settings.previewBeforeInsert) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Confirm before inserting")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Review transcription before inserting at cursor")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        SettingsSection(title: "Shortcuts", icon: "keyboard") {
            SettingsCard {
                Toggle(isOn: $settings.translateOnLongPress) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Translate on long press")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("When enabled, hold and release to translate into the selected language; otherwise, hold and release to transcribe")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .toggleStyle(.switch)

                if settings.translateOnLongPress {
                    SettingsCardDivider()

                    SettingsCardRow(label: "Target language") {
                        Picker("", selection: $settings.translationTargetLanguage) {
                            ForEach(TranslationTargetLanguage.allCases) { language in
                                Text(language.rawValue).tag(language)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                }
            }

            SettingsCard {
                ShortcutRecorderRow(
                    name: "Push-to-talk",
                    description: settings.translateOnLongPress
                        ? "Hold to record, release to translate into \(settings.translationTargetLanguage.rawValue)"
                        : "Hold to record, release to transcribe in the original language",
                    currentKeyCode: settings.pushToTalkKeyCode,
                    currentModifiers: settings.pushToTalkModifiers,
                    defaultKeyCode: Settings.defaultPushToTalkKeyCode,
                    defaultModifiers: Settings.defaultPushToTalkModifiers,
                    hotkeyManager: hotkeyManager,
                    onSave: { keyCode, modifiers in
                        settings.pushToTalkKeyCode = keyCode
                        settings.pushToTalkModifiers = modifiers
                        hotkeyManager.rebindHotkeys()
                    }
                )

                SettingsCardDivider()

                ShortcutRecorderRow(
                    name: "Toggle mode",
                    description: "Press to start/stop and transcribe in the original language",
                    currentKeyCode: settings.toggleModeKeyCode,
                    currentModifiers: settings.toggleModeModifiers,
                    defaultKeyCode: Settings.defaultToggleModeKeyCode,
                    defaultModifiers: Settings.defaultToggleModeModifiers,
                    hotkeyManager: hotkeyManager,
                    onSave: { keyCode, modifiers in
                        settings.toggleModeKeyCode = keyCode
                        settings.toggleModeModifiers = modifiers
                        hotkeyManager.rebindHotkeys()
                    }
                )
            }

            if settings.pushToTalkKeyCode == settings.toggleModeKeyCode
                && settings.pushToTalkModifiers == settings.toggleModeModifiers {
                SettingsCard {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "hand.tap")
                            .foregroundStyle(Theme.brand)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Shared shortcut mode")
                                .font(.system(size: 12, weight: .medium))
                            Text(settings.translateOnLongPress
                                ? "Tap to start or stop normal transcription. Hold to translate to \(settings.translationTargetLanguage.rawValue), then release to insert."
                                : "Tap to start or stop normal transcription. Hold to record, then release to transcribe and insert.")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        SettingsSection(title: "Permissions", icon: "lock.shield") {
            SettingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Required for voice recording")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if audioRecorder.hasPermission {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.statusGreen)
                    } else {
                        Button("Grant Access") {
                            Task {
                                let granted = await audioRecorder.requestPermission()
                                if !granted {
                                    openMicrophoneSettings()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                SettingsCardDivider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Required for text insertion")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Open Settings") {
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func apiKeyLink(url: URL?) -> some View {
        if let url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                    Text("Get API Key")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.brand)
            .controlSize(.small)
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct EnhancementPromptEditor: View {
    @Binding var prompt: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Correction Prompt")
                    .font(.system(size: 16, weight: .semibold))
                Text("This system prompt controls transcription correction, filler words, self-corrections, and formatting.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            TextEditor(text: $prompt)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.border, lineWidth: 1)
                )

            HStack {
                Button("Restore Default") {
                    prompt = Settings.defaultEnhancementPrompt
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 520)
        .background(Theme.bg)
    }
}

// MARK: - Components

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String = "gear", @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            content
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Theme.cardBg)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

struct SettingsCardRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            content
        }
    }
}

struct SettingsCardDivider: View {
    var body: some View {
        Divider()
            .overlay(Theme.border)
    }
}

struct ShortcutRecorderRow: View {
    let name: String
    let description: String
    let currentKeyCode: UInt32
    let currentModifiers: UInt32
    let defaultKeyCode: UInt32
    let defaultModifiers: UInt32
    let hotkeyManager: HotkeyManager
    let onSave: (UInt32, UInt32) -> Void

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    private var displayString: String {
        Settings.shortcutDisplayString(keyCode: currentKeyCode, modifiers: currentModifiers)
    }

    private var isDefault: Bool {
        currentKeyCode == defaultKeyCode && currentModifiers == defaultModifiers
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !isDefault {
                Button("Reset") {
                    onSave(defaultKeyCode, defaultModifiers)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            }
            Button(action: { startRecording() }) {
                Text(isRecording ? "Press shortcut..." : displayString)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isRecording ? Color.accentColor.opacity(0.2) : Theme.bg)
                    .clipShape(.rect(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isRecording ? Color.accentColor : Theme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    @MainActor private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        hotkeyManager.disable()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let keyCode = UInt32(event.keyCode)
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if keyCode == 53 && modifiers.isEmpty {
                stopRecording()
                return nil
            }

            let carbonMods = modifiers.carbonFlags
            if carbonMods == 0 {
                return nil
            }

            let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            if modifierKeyCodes.contains(event.keyCode) {
                return nil
            }

            onSave(keyCode, carbonMods)
            stopRecording()
            return nil
        }
    }

    @MainActor private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
        hotkeyManager.enable()
    }
}

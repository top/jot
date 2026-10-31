// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI
import JotCore

/// The one app window — System Settings idiom: icon-tile sidebar, grouped detail.
/// Your data (History, Dictionary) on top; app configuration below.
@MainActor
final class MainWindowController: NSWindowController {
    private var hosting: NSHostingView<MainView>?
    private let model: MainWindowModel
    private var titleObserver: AnyCancellable?

    init(
        store: HistoryStore?,
        onRetry: @escaping (DictationRecord) -> Void,
        onDeleteAllHistory: @escaping () -> Void
    ) {
        model = MainWindowModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = model.selection.title
        window.titlebarAppearsTransparent = true
        window.center()
        super.init(window: window)
        // System Settings idiom: the titlebar names the selected pane (the app
        // name already anchors the sidebar header).
        titleObserver = model.$selection.sink { [weak window] section in
            window?.title = section.title
        }
        window.contentView = NSHostingView(rootView: MainView(
            model: model,
            store: store,
            onRetry: onRetry,
            onDeleteAllHistory: onDeleteAllHistory
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(section: MainSection) {
        model.selection = section
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum MainSection: String, CaseIterable, Identifiable {
    case history, dictionary
    case general, models
    case about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .general: return "General"
        case .models: return "Models"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed.fill"
        case .general: return "gearshape.fill"
        case .models: return "cpu"
        case .about: return "info.circle.fill"
        }
    }

    var tileColor: Color {
        switch self {
        case .history: return JotUI.Colors.gBlue
        case .dictionary: return Color(nsColor: .systemOrange)
        case .general: return Color(nsColor: .systemGray)
        case .models: return Color.purple
        case .about: return Color(nsColor: .systemPink)
        }
    }

    static let dataSections: [MainSection] = [.history, .dictionary]
    static let settingsSections: [MainSection] = [.general, .models, .about]
}

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var selection: MainSection = .history
}

private struct MainView: View {
    @ObservedObject var model: MainWindowModel
    let store: HistoryStore?
    let onRetry: (DictationRecord) -> Void
    let onDeleteAllHistory: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 880, minHeight: 580)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Jot")
                .font(JotUI.TypeScale.title())
                .padding(.horizontal, 14)
                .padding(.top, 20)
                .padding(.bottom, 12)
            ForEach(MainSection.dataSections) { section in
                SidebarRow(section: section, selected: model.selection == section) {
                    model.selection = section
                }
            }
            Text("Settings")
                .font(JotUI.TypeScale.labelSmall())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 4)
            ForEach(MainSection.settingsSections) { section in
                SidebarRow(section: section, selected: model.selection == section) {
                    model.selection = section
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 210)
        .background(.thickMaterial)
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch model.selection {
            case .history:
                if let store {
                    HistoryPane(store: store, onRetry: onRetry, onDeleteAllHistory: onDeleteAllHistory)
                } else {
                    ContentUnavailableView("History unavailable", systemImage: "clock.badge.exclamationmark")
                }
            case .dictionary:
                DictionaryView()
            case .general:
                GeneralPane().formStyle(.grouped)
            case .models:
                ModelsPane().formStyle(.grouped)
            case .about:
                AboutPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SidebarRow: View {
    let section: MainSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(section.tileColor))
                Text(section.title)
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(selected ? Color.white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: JotUI.Radius.small)
                    .fill(selected ? JotUI.Colors.primary
                          : hovering ? Color.primary.opacity(JotUI.StateLayer.hover)
                          : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - General

struct GeneralPane: View {
    private let settings = SettingsStore()

    @State private var hotkey = SettingsStore().hotkeyKey
    @State private var doubleTapLock = SettingsStore().doubleTapLockEnabled
    @State private var automaticInsertion = SettingsStore().automaticInsertionEnabled
    @State private var sounds = SettingsStore().soundsEnabled
    @State private var showIdleDot = SettingsStore().showIdleIndicator
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var noiseHandling = SettingsStore().experimentalNoiseHandling

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $hotkey) {
                    ForEach(HotkeyKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .onChange(of: hotkey) { _, newKey in
                    settings.setHotkeyKey(newKey)
                }
                Toggle("Double-tap to lock hands-free", isOn: $doubleTapLock)
                    .onChange(of: doubleTapLock) { _, enabled in
                        settings.setDoubleTapLock(enabled)
                    }
            } footer: {
                Text("Hold to talk. Tap Space while holding to go hands-free. Esc cancels.")
            }

            Section {
                Toggle("Automatically insert text", isOn: $automaticInsertion)
                    .onChange(of: automaticInsertion) { _, enabled in
                        settings.setAutomaticInsertion(enabled)
                    }
                Button("Open Accessibility Settings") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            } header: {
                Text("Typing & Accessibility")
            } footer: {
                Text("Results stay on the clipboard until your next copy, except during secure input. Accessibility is required for automatic typing.")
            }

            Section {
                Toggle("Sounds", isOn: $sounds)
                    .onChange(of: sounds) { _, enabled in settings.setSoundsEnabled(enabled) }
                Toggle("Show resting indicator", isOn: $showIdleDot)
                    .onChange(of: showIdleDot) { _, show in settings.setShowIdleIndicator(show) }
                Toggle("Start Jot at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        // The failure-path revert below re-enters onChange with the
                        // inverted value — this guard stops the bounce from calling
                        // into SMAppService a second time.
                        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            Log.ui.error("launch-at-login toggle failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            } header: {
                Text("Appearance & Feedback")
            } footer: {
                Text("The resting dot grows into a Dictate button on hover; click it for hands-free. Off = the pill appears only while dictating.")
            }

            Section {
                Toggle("Better hearing in loud rooms", isOn: $noiseHandling)
                    .onChange(of: noiseHandling) { _, enabled in
                        settings.setExperimentalNoiseHandling(enabled)
                    }
            } header: {
                Text("Experimental")
            } footer: {
                Text("Judges your voice against the room noise instead of a fixed level. Off by default.")
            }
        }
        // Login-item state lives in macOS, not in our defaults, so it can change
        // with the app running — System Settings › General › Login Items turns it
        // off without telling us. A stale ON toggle is worse than cosmetic here:
        // the onChange guard above compares against the REAL status, so tapping
        // the stale toggle decides nothing changed and silently does nothing.
        // Re-reading on appear also covers reopening the window.
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            hotkey = settings.hotkeyKey
            doubleTapLock = settings.doubleTapLockEnabled
            automaticInsertion = settings.automaticInsertionEnabled
            sounds = settings.soundsEnabled
            showIdleDot = settings.showIdleIndicator
            noiseHandling = settings.experimentalNoiseHandling
        }
        // The other panes guard the same way; these can move under us from
        // the DEBUG jot://set driver.
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            switch note.object as? String {
            case "hotkeyKey": hotkey = settings.hotkeyKey
            case "doubleTapLock": doubleTapLock = settings.doubleTapLockEnabled
            case "automaticInsertion": automaticInsertion = settings.automaticInsertionEnabled
            case "soundsEnabled": sounds = settings.soundsEnabled
            case "showIdleIndicator": showIdleDot = settings.showIdleIndicator
            case "experimentalNoiseHandling": noiseHandling = settings.experimentalNoiseHandling
            default: break
            }
        }
    }
}

// MARK: - Models

struct ModelsPane: View {
    private let settings = SettingsStore()
    @State private var config = SettingsStore().apiConfig
    @State private var storedConfig = SettingsStore().apiConfig
    @State private var apiKey = ""
    @State private var hasStoredKey = KeychainStore.loadAPIKey() != nil

    enum StatusKind: Equatable {
        case idle
        case inProgress(String)
        case success(String)
        case error(String)

        var isInProgress: Bool {
            if case .inProgress = self { return true }
            return false
        }
    }
    @State private var status: StatusKind = .idle
    @State private var fetchedModels: [String] = []

    @State private var cleanupPass = SettingsStore().smartCleanupPassEnabled
    @State private var promptPresets: [PromptPreset] = SettingsStore().promptPresets
    @State private var selectedPromptId: String = SettingsStore().selectedPromptId
    @State private var expandedPromptId: String? = nil

    private var needsNewKey: Bool { config.endpoint != storedConfig.endpoint }
    private var effectiveKey: String? {
        let entered = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return entered.isEmpty ? KeychainStore.loadAPIKey() : entered
    }
    private var canTest: Bool {
        config.endpoint != nil && (effectiveKey?.isEmpty == false)
    }
    private var canSave: Bool {
        config.isConfigured && (!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (hasStoredKey && !needsNewKey))
    }

    var body: some View {
        Form {
            apiProviderSection
            asrSection
            llmSection
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == "smartCleanupPass" {
                cleanupPass = settings.smartCleanupPassEnabled
            }
        }
    }

    // MARK: - Section 1: API Provider

    private var apiProviderSection: some View {
        Section {
            TextField("Base URL", text: $config.baseURL, prompt: Text("https://example.com/v1"))
            SecureField("API Key", text: $apiKey, prompt: Text(hasStoredKey && !needsNewKey ? "Stored in Keychain" : "Enter API key"))

            if !config.baseURL.isEmpty, config.endpoint == nil {
                Text("Enter an http(s) URL with a host and API prefix, without credentials or query parameters.")
                    .foregroundStyle(JotUI.Colors.error)
                    .font(JotUI.TypeScale.labelSmall())
            }
            if hasStoredKey && needsNewKey {
                Text("Re-enter the key for the new Base URL.")
                    .font(JotUI.TypeScale.labelSmall())
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
            }

            HStack(spacing: 8) {
                Button("Test Connection") { testConnection() }
                    .disabled(!canTest || status.isInProgress)

                Button("Fetch Models") { fetchModels() }
                    .disabled(!canTest || status.isInProgress)

                if hasStoredKey {
                    Button("Remove Key", role: .destructive) { removeKey() }
                        .disabled(status.isInProgress)
                }

                Spacer()

                Button("Save Changes") { saveChanges() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || status.isInProgress)
            }

            switch status {
            case .idle:
                EmptyView()
            case .inProgress(let message):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(message)
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                }
            case .success(let message):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(JotUI.Colors.success)
                    Text(message)
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.success)
                }
            case .error(let message):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(JotUI.Colors.error)
                    Text(message)
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.error)
                }
            }
        } header: {
            Text("API Provider")
        } footer: {
            Text("Your API key is stored securely in macOS Keychain. ASR and LLM share this provider.")
        }
    }

    // MARK: - Section 2: Speech Recognition (ASR)

    private var asrSection: some View {
        Section {
            if !fetchedModels.isEmpty {
                Picker("Choose Model", selection: $config.asrModel) {
                    if !fetchedModels.contains(config.asrModel) && !config.asrModel.isEmpty {
                        Text(config.asrModel).tag(config.asrModel)
                    }
                    ForEach(fetchedModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }

            TextField("ASR Model", text: $config.asrModel, prompt: Text("e.g. Qwen/Qwen3-ASR-1.7B"))
        } header: {
            Text("Speech Recognition (ASR)")
        } footer: {
            Text("Audio transcription model. You can type manually or pick from fetched models.")
        }
    }

    // MARK: - Section 3: Text Polish & Tone (LLM)

    private var llmSection: some View {
        Section {
            Toggle("Enable text polish", isOn: $cleanupPass)
                .onChange(of: cleanupPass) { _, enabled in
                    settings.setSmartCleanupPass(enabled)
                }

            if cleanupPass {
                if !fetchedModels.isEmpty {
                    Picker("Choose Model", selection: $config.llmModel) {
                        if !fetchedModels.contains(config.llmModel) && !config.llmModel.isEmpty {
                            Text(config.llmModel).tag(config.llmModel)
                        }
                        ForEach(fetchedModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                TextField("LLM Model", text: $config.llmModel, prompt: Text("e.g. Qwen/Qwen2.5-7B-Instruct"))

                Toggle("Enable thinking", isOn: $config.llmThinkingEnabled)
                    .disabled(config.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || config.llmThinkingControl == .none)

                if !config.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Picker("Thinking control", selection: $config.llmThinkingControl) {
                        Text("Do not send (server default)").tag(LLMThinkingControl.none)
                        Text("vLLM / Qwen (chat template)").tag(LLMThinkingControl.chatTemplate)
                        Text("DashScope (enable_thinking)").tag(LLMThinkingControl.enableThinking)
                        Text("OpenAI (reasoning_effort)").tag(LLMThinkingControl.reasoningEffort)
                    }
                    .onChange(of: config.llmThinkingControl) { _, control in
                        if control == .none { config.llmThinkingEnabled = false }
                    }
                    Text(config.llmThinkingControl == .none
                        ? "No thinking parameter is sent; the server's default applies."
                        : "Cleanup allows up to 60 seconds. Model support is required.")
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Prompts")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .padding(.top, 4)

                    ForEach(promptPresets) { preset in
                        promptRow(preset: preset)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Text Polish & Tone (LLM)")
        } footer: {
            Text("Applies formatting, punctuation, filler removal, and custom prompt steering.")
        }
    }

    private func promptRow(preset: PromptPreset) -> some View {
        let isSelected = selectedPromptId == preset.id
        let isExpanded = expandedPromptId == preset.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    selectedPromptId = preset.id
                    settings.setSelectedPromptId(preset.id)
                } label: {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? JotUI.Colors.primary : JotUI.Colors.outline)
                }
                .buttonStyle(.plain)

                Text(preset.title)
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(JotUI.Colors.onSurface)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expandedPromptId = isExpanded ? nil : preset.id
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(isExpanded ? "Collapse" : "Edit / View")
                            .font(JotUI.TypeScale.labelSmall())
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(JotUI.Colors.primary)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: bindingForPrompt(preset.id))
                        .font(.system(size: 12))
                        .frame(minHeight: 80, maxHeight: 160)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(JotUI.Colors.surfaceContainer)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(JotUI.Colors.outlineVariant.opacity(0.6), lineWidth: 1)
                        )

                    HStack {
                        Spacer()
                        Button("Reset to Default") {
                            if let defaultPreset = SettingsStore.defaultPromptPresets.first(where: { $0.id == preset.id }) {
                                updatePresetText(id: preset.id, text: defaultPreset.promptText)
                            }
                        }
                        .font(JotUI.TypeScale.labelSmall())
                        .buttonStyle(.link)
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func bindingForPrompt(_ id: String) -> Binding<String> {
        Binding(
            get: {
                promptPresets.first(where: { $0.id == id })?.promptText ?? ""
            },
            set: { newText in
                updatePresetText(id: id, text: newText)
            }
        )
    }

    private func updatePresetText(id: String, text: String) {
        if let idx = promptPresets.firstIndex(where: { $0.id == id }) {
            promptPresets[idx].promptText = text
            settings.updatePromptPreset(id: id, newText: text)
        }
    }

    // MARK: - Actions

    private func testConnection() {
        guard let key = effectiveKey, !status.isInProgress else { return }
        status = .inProgress("Testing connection…")
        let candidate = OpenAIConfig(baseURL: config.baseURL, asrModel: config.asrModel, llmModel: config.llmModel,
                                     llmThinkingEnabled: config.llmThinkingEnabled, llmThinkingControl: config.llmThinkingControl)
        Task { @MainActor in
            let result = await OpenAIClient(apiKey: key).checkConnection(config: candidate)
            switch result {
            case .reachable:
                status = .success("Connection successful! Server is reachable.")
            case .rejected(let msg):
                status = .error("Connection rejected: \(msg)")
            case .unreachable:
                status = .error("Unable to reach server. Please check your Base URL and network.")
            case .unverified:
                status = .error("Server responded with unexpected status.")
            }
        }
    }

    private func fetchModels() {
        guard let key = effectiveKey, !status.isInProgress else { return }
        status = .inProgress("Fetching models…")
        let candidate = OpenAIConfig(baseURL: config.baseURL, asrModel: config.asrModel, llmModel: config.llmModel,
                                     llmThinkingEnabled: config.llmThinkingEnabled, llmThinkingControl: config.llmThinkingControl)
        Task { @MainActor in
            do {
                let models = try await OpenAIClient(apiKey: key).fetchModels(config: candidate)
                fetchedModels = models
                if models.isEmpty {
                    status = .error("Models endpoint succeeded but returned no models.")
                } else {
                    status = .success("Fetched \(models.count) models successfully.")
                }
            } catch let err as TranscriptionError {
                switch err {
                case .badRequest(let msg): status = .error("Fetch failed: \(msg)")
                case .network(let detail): status = .error("Network error: \(detail)")
                default: status = .error("Fetch failed: \(err)")
                }
            } catch {
                status = .error("Fetch failed: \(error.localizedDescription)")
            }
        }
    }

    private func removeKey() {
        KeychainStore.deleteAPIKey(notify: true)
        hasStoredKey = false
        apiKey = ""
        status = .success("API key removed from Keychain.")
    }

    private func saveChanges() {
        guard canSave, !status.isInProgress else { return }
        let candidate = OpenAIConfig(baseURL: config.baseURL, asrModel: config.asrModel, llmModel: config.llmModel,
                                     llmThinkingEnabled: config.llmThinkingEnabled, llmThinkingControl: config.llmThinkingControl)
        let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidateKey = enteredKey.isEmpty ? KeychainStore.loadAPIKey() : enteredKey else { return }

        status = .inProgress("Saving changes…")
        Task { @MainActor in
            guard enteredKey.isEmpty || KeychainStore.saveAPIKey(candidateKey) else {
                status = .error("Couldn't save the key to your Mac's Keychain.")
                return
            }
            settings.setAPIConfig(candidate)
            if candidate.llmModel.isEmpty { settings.setSmartCleanupPass(false) }
            config = candidate
            storedConfig = candidate
            apiKey = ""
            hasStoredKey = true
            status = .success("Changes saved successfully.")
        }
    }
}

struct APIConfigurationEditor: View {
    var onSaved: (() -> Void)? = nil
    private let settings = SettingsStore()
    @State private var config = SettingsStore().apiConfig
    @State private var storedConfig = SettingsStore().apiConfig
    @State private var key = ""
    @State private var hasStoredKey = KeychainStore.loadAPIKey() != nil
    @State private var checking = false
    @State private var notice: String?
    @State private var failed = false
    @State private var savedUnverified = false

    private var needsNewKey: Bool { config.endpoint != storedConfig.endpoint }
    private var canSave: Bool {
        config.isConfigured && (!key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (hasStoredKey && !needsNewKey))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: JotUI.Spacing.s) {
            TextField("Base URL", text: $config.baseURL, prompt: Text("https://example.com/v1"))
            SecureField("API Key", text: $key, prompt: Text(hasStoredKey && !needsNewKey ? "Stored in Keychain" : "API key"))
            TextField("ASR Model", text: $config.asrModel, prompt: Text("Qwen/Qwen3-ASR-1.7B"))
            TextField("LLM Model (optional)", text: $config.llmModel)
            Toggle("Enable thinking", isOn: $config.llmThinkingEnabled)
                .toggleStyle(.checkbox)
                .disabled(config.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || config.llmThinkingControl == .none)
            if !config.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Picker("Thinking control", selection: $config.llmThinkingControl) {
                    Text("Do not send (server default)").tag(LLMThinkingControl.none)
                    Text("vLLM / Qwen (chat template)").tag(LLMThinkingControl.chatTemplate)
                    Text("DashScope (enable_thinking)").tag(LLMThinkingControl.enableThinking)
                    Text("OpenAI (reasoning_effort)").tag(LLMThinkingControl.reasoningEffort)
                }
                .onChange(of: config.llmThinkingControl) { _, control in
                    if control == .none { config.llmThinkingEnabled = false }
                }
                Text(config.llmThinkingControl == .none
                    ? "No thinking parameter is sent; the server's default applies."
                    : "Cleanup allows up to 60 seconds. Model support is required.")
                    .font(JotUI.TypeScale.labelSmall())
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !config.baseURL.isEmpty, config.endpoint == nil {
                Text("Enter an http(s) URL with a host and API prefix, without credentials or query parameters.")
                    .foregroundStyle(JotUI.Colors.error)
                    .font(JotUI.TypeScale.labelSmall())
            }
            if hasStoredKey && needsNewKey {
                Text("Re-enter the key for the new Base URL.")
                    .font(JotUI.TypeScale.labelSmall())
            }
            if let notice {
                Text(notice)
                    .font(JotUI.TypeScale.labelSmall())
                    .foregroundStyle(failed ? JotUI.Colors.error : JotUI.Colors.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(onSaved == nil ? "Save & Check Connection" : "Save & Continue", action: save)
                    .disabled(!canSave || checking)
                if checking { ProgressView().controlSize(.small) }
                if hasStoredKey, !checking {
                    Button("Remove Key", role: .destructive) {
                        KeychainStore.deleteAPIKey(notify: true)
                        hasStoredKey = false
                        key = ""
                        notice = nil
                        savedUnverified = false
                    }
                }
            }
            if savedUnverified, let onSaved {
                Button("Continue without verification", action: onSaved)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(JotUI.TypeScale.body())
        .disabled(checking)
    }

    private func save() {
        guard canSave, !checking else { return }
        let candidate = OpenAIConfig(baseURL: config.baseURL, asrModel: config.asrModel, llmModel: config.llmModel,
            llmThinkingEnabled: config.llmThinkingEnabled, llmThinkingControl: config.llmThinkingControl)
        let enteredKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidateKey = enteredKey.isEmpty ? KeychainStore.loadAPIKey() : enteredKey else { return }
        checking = true
        failed = false
        savedUnverified = false
        notice = nil
        Task { @MainActor in
            defer { checking = false }
            let result = await OpenAIClient(apiKey: candidateKey).checkConnection(config: candidate)
            if case .rejected(let message) = result {
                notice = message
                failed = true
                return
            }
            guard enteredKey.isEmpty || KeychainStore.saveAPIKey(candidateKey) else {
                notice = "Couldn't save the key to your Mac's Keychain. Configuration unchanged."
                failed = true
                return
            }
            settings.setAPIConfig(candidate)
            if candidate.llmModel.isEmpty { settings.setSmartCleanupPass(false) }
            config = candidate
            storedConfig = candidate
            key = ""
            hasStoredKey = true
            savedUnverified = result != .reachable
            notice = savedUnverified
                ? "Saved without verification. The API could not be checked; try a dictation when it is available."
                : "Saved. Connection reachable; ASR and LLM models have not been tested."
            if !savedUnverified { onSaved?() }
        }
    }
}

// MARK: - About

/// Who made this, what version it is, and where to go next. Deliberately a
/// plain page rather than a Form: it is a colophon, not settings.
struct AboutPane: View {
    /// Read from the bundle directly: NSApp.applicationIconImage is set at
    /// launch but the standard About panel ignores it for an LSUIElement app,
    /// which is exactly why this pane exists.
    static let appIcon: NSImage? = Bundle.main
        .url(forResource: "Jot", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:))

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "Version \(short) (\(Bundle.main.buildNumber))"
    }

    var body: some View {
        VStack(spacing: JotUI.Spacing.m) {
            Spacer()
            if let icon = AboutPane.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 4) {
                Text("Jot")
                    .font(JotUI.TypeScale.display())
                    .foregroundStyle(JotUI.Colors.onSurface)
                Text(version)
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
            }
            HStack(spacing: 4) {
                Text("Created by")
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                Link("Ammaar Reshi", destination: JotLinks.author)
            }
            .font(JotUI.TypeScale.body())

            HStack(spacing: JotUI.Spacing.m) {
                Link("Source", destination: JotLinks.repository)
                Link("Privacy", destination: JotLinks.privacy)
                Link("Report a bug", destination: JotLinks.issues)
            }
            .font(JotUI.TypeScale.body())

            Text("Open source under the Apache License 2.0.\nThis is not an officially supported Google product.")
                .font(JotUI.TypeScale.labelSmall())
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.top, JotUI.Spacing.xs)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

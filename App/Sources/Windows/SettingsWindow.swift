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

    @State private var isAccessibilityTrusted = AXIsProcessTrusted()
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
                Toggle(
                    "Automatically insert text",
                    isOn: Binding(
                        get: { isAccessibilityTrusted && automaticInsertion },
                        set: { automaticInsertion = $0 }
                    )
                )
                .disabled(!isAccessibilityTrusted)
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
                Text(isAccessibilityTrusted
                    ? "Results stay on the clipboard until your next copy, except during secure input."
                    : "Accessibility permission is required for automatic typing. Results stay on the clipboard until granted.")
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
            updateAccessibilityStatus()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            hotkey = settings.hotkeyKey
            doubleTapLock = settings.doubleTapLockEnabled
            automaticInsertion = settings.automaticInsertionEnabled
            sounds = settings.soundsEnabled
            showIdleDot = settings.showIdleIndicator
            noiseHandling = settings.experimentalNoiseHandling
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).receive(on: RunLoop.main)) { _ in
            updateAccessibilityStatus()
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
            case "accessibility": isAccessibilityTrusted = AXIsProcessTrusted()
            default: break
            }
        }
    }

    private func updateAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        if trusted && !isAccessibilityTrusted {
            NotificationCenter.default.post(name: .gtSettingDidChange, object: "accessibility")
        }
        isAccessibilityTrusted = trusted
    }
}

// MARK: - Models

struct ProviderTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let suggestedASR: String?
    let suggestedLLM: String?
}

let providerTemplates: [ProviderTemplate] = [
    ProviderTemplate(id: "custom", name: "Custom", baseURL: "", suggestedASR: nil, suggestedLLM: nil),
    ProviderTemplate(id: "siliconflow", name: "SiliconFlow", baseURL: "https://api.siliconflow.cn/v1", suggestedASR: "FunAudioLLM/SenseVoiceSmall", suggestedLLM: "deepseek-ai/DeepSeek-V3"),
    ProviderTemplate(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", suggestedASR: "whisper-large-v3-turbo", suggestedLLM: "llama-3.3-70b-versatile"),
    ProviderTemplate(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", suggestedASR: nil, suggestedLLM: "deepseek-chat"),
    ProviderTemplate(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", suggestedASR: "whisper-1", suggestedLLM: "gpt-4o-mini"),
    ProviderTemplate(id: "ollama", name: "Local Ollama", baseURL: "http://localhost:11434/v1", suggestedASR: nil, suggestedLLM: nil)
]

struct ModelsPane: View {
    private let settings = SettingsStore()

    @State private var providers: [APIProvider] = []
    @State private var selectedASRProviderId: String = ""
    @State private var selectedLLMProviderId: String = ""
    @State private var asrModel: String = ""
    @State private var llmModel: String = ""
    @State private var thinkingEnabled: Bool = false
    @State private var thinkingControl: LLMThinkingControl = .none
    @State private var cleanupPass: Bool = false
    @State private var promptPresets: [PromptPreset] = []
    @State private var selectedPromptId: String = "general"

    @State private var editingProvider: APIProvider? = nil
    @State private var addingProvider: Bool = false
    @State private var editingPreset: PromptPreset? = nil

    private var selectedASRModels: [String] {
        providers.first(where: { $0.id == selectedASRProviderId })?.cachedModels ?? []
    }

    private var selectedLLMModels: [String] {
        providers.first(where: { $0.id == selectedLLMProviderId })?.cachedModels ?? []
    }

    var body: some View {
        Form {
            providersSection
            asrSection
            llmSection
        }
        .onAppear {
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { _ in
            reload()
        }
        .sheet(item: $editingProvider) { prov in
            ProviderDetailSheet(
                provider: prov,
                canDelete: providers.count > 1,
                onSave: { reload() }
            )
        }
        .sheet(isPresented: $addingProvider) {
            ProviderDetailSheet(
                provider: nil,
                canDelete: false,
                onSave: { reload() }
            )
        }
        .sheet(item: $editingPreset) { preset in
            PromptDetailSheet(
                preset: preset,
                onSave: { reload() }
            )
        }
    }

    // MARK: - Section 1: API Providers

    private var providersSection: some View {
        Section {
            if providers.isEmpty {
                Text("No providers configured yet.")
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
            } else {
                ForEach(providers) { provider in
                    HStack(spacing: JotUI.Spacing.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                                .font(JotUI.TypeScale.body())
                                .fontWeight(.medium)
                                .foregroundStyle(JotUI.Colors.onSurface)
                            Text(provider.baseURL)
                                .font(JotUI.TypeScale.labelSmall())
                                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            editingProvider = provider
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingProvider = provider
                    }
                    .padding(.vertical, 2)
                }
            }

            Button("+ Add Provider…") {
                addingProvider = true
            }
        } header: {
            Text("API Providers")
        } footer: {
            Text("Configured API services. ASR and LLM can use the same or different providers.")
        }
    }

    // MARK: - Section 2: Speech Recognition (ASR)

    private var asrSection: some View {
        Section {
            if providers.isEmpty {
                Text("Add an API provider above to configure speech recognition.")
                    .font(JotUI.TypeScale.labelSmall())
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
            } else {
                Picker("Provider", selection: $selectedASRProviderId) {
                    ForEach(providers) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                .onChange(of: selectedASRProviderId) { _, newId in
                    settings.setASRProvider(id: newId, model: asrModel)
                }

                if !selectedASRModels.isEmpty {
                    Picker("Choose Model", selection: $asrModel) {
                        if !selectedASRModels.contains(asrModel) && !asrModel.isEmpty {
                            Text(asrModel).tag(asrModel)
                        }
                        ForEach(selectedASRModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                TextField("ASR Model", text: $asrModel, prompt: Text("e.g. whisper-large-v3-turbo"))
                    .onChange(of: asrModel) { _, newModel in
                        settings.setASRModel(newModel)
                    }
            }
        } header: {
            Text("Speech Recognition (ASR)")
        } footer: {
            Text("Audio transcription model. You can type manually or pick from fetched models.")
        }
    }

    // MARK: - Section 3: Text Polish & Tone (LLM)

    private var llmSection: some View {
        Section {
            Toggle("Enable Text Polish & Tone", isOn: $cleanupPass)
                .onChange(of: cleanupPass) { _, enabled in
                    settings.setSmartCleanupPass(enabled)
                }

            if cleanupPass {
                if providers.isEmpty {
                    Text("Add an API provider above to configure text polish.")
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                } else {
                    Picker("Provider", selection: $selectedLLMProviderId) {
                        ForEach(providers) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .onChange(of: selectedLLMProviderId) { _, newId in
                        settings.setLLMProvider(id: newId, model: llmModel)
                    }

                    if !selectedLLMModels.isEmpty {
                        Picker("Choose Model", selection: $llmModel) {
                            if !selectedLLMModels.contains(llmModel) && !llmModel.isEmpty {
                                Text(llmModel).tag(llmModel)
                            }
                            ForEach(selectedLLMModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }

                    TextField("LLM Model", text: $llmModel, prompt: Text("e.g. deepseek-ai/DeepSeek-V3"))
                        .onChange(of: llmModel) { _, newModel in
                            settings.setLLMModel(newModel)
                        }

                    Toggle("Enable thinking", isOn: $thinkingEnabled)
                        .disabled(llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thinkingControl == .none)
                        .onChange(of: thinkingEnabled) { _, val in
                            settings.setLLMThinking(enabled: val, control: thinkingControl)
                        }

                    if !llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Picker("Thinking control", selection: $thinkingControl) {
                            Text("Do not send (server default)").tag(LLMThinkingControl.none)
                            Text("vLLM / Qwen (chat template)").tag(LLMThinkingControl.chatTemplate)
                            Text("DashScope (enable_thinking)").tag(LLMThinkingControl.enableThinking)
                            Text("OpenAI (reasoning_effort)").tag(LLMThinkingControl.reasoningEffort)
                        }
                        .onChange(of: thinkingControl) { _, control in
                            if control == .none { thinkingEnabled = false }
                            settings.setLLMThinking(enabled: thinkingEnabled, control: control)
                        }
                        Text(thinkingControl == .none
                            ? "No thinking parameter is sent; the server's default applies."
                            : "Cleanup allows up to 60 seconds. Model support is required.")
                            .font(JotUI.TypeScale.labelSmall())
                            .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prompt Presets")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.top, 4)

                        ForEach(promptPresets) { preset in
                            HStack(spacing: 8) {
                                Button {
                                    selectedPromptId = preset.id
                                    settings.setSelectedPromptId(preset.id)
                                } label: {
                                    Image(systemName: selectedPromptId == preset.id ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 15))
                                        .foregroundStyle(selectedPromptId == preset.id ? JotUI.Colors.primary : JotUI.Colors.outline)
                                }
                                .buttonStyle(.plain)

                                Text(preset.title)
                                    .font(JotUI.TypeScale.body())
                                    .foregroundStyle(JotUI.Colors.onSurface)

                                Spacer()

                                Button {
                                    editingPreset = preset
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Text Polish & Tone (LLM)")
        } footer: {
            Text("Applies formatting, punctuation, filler removal, and custom prompt steering.")
        }
    }

    private func reload() {
        providers = settings.providers
        selectedASRProviderId = settings.asrProviderId ?? providers.first?.id ?? ""
        selectedLLMProviderId = settings.llmProviderId ?? providers.first?.id ?? ""
        let config = settings.apiConfig
        asrModel = config.asrModel
        llmModel = config.llmModel
        thinkingEnabled = config.llmThinkingEnabled
        thinkingControl = config.llmThinkingControl
        cleanupPass = settings.smartCleanupPassEnabled
        promptPresets = settings.promptPresets
        selectedPromptId = settings.selectedPromptId
    }
}

// MARK: - ProviderDetailSheet

struct ProviderDetailSheet: View {
    let provider: APIProvider?
    let canDelete: Bool
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplateId: String = "custom"
    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var cachedModels: [String] = []
    @State private var hasStoredKey: Bool = false

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

    private let settings = SettingsStore()

    private var isLocalURL: Bool {
        guard let host = OpenAIConfig(baseURL: baseURL).endpoint?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }

    private var effectiveKey: String? {
        let entered = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        if let provider {
            let stored = KeychainStore.loadAPIKey(forProviderId: provider.id)
            if stored?.isEmpty == false { return stored }
        }
        return isLocalURL ? "ollama" : nil
    }

    private var canTest: Bool {
        OpenAIConfig(baseURL: baseURL).endpoint != nil && (effectiveKey?.isEmpty == false || isLocalURL)
    }

    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidURL = OpenAIConfig(baseURL: baseURL).endpoint != nil
        let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasStoredKey || isLocalURL
        return !trimmedName.isEmpty && hasValidURL && hasKey
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(provider == nil ? "Add Provider" : "Edit Provider")
                    .font(JotUI.TypeScale.title())
                    .foregroundStyle(JotUI.Colors.onSurface)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            Form {
                Picker("Template", selection: $selectedTemplateId) {
                    ForEach(providerTemplates) { tmpl in
                        Text(tmpl.name).tag(tmpl.id)
                    }
                }
                .onChange(of: selectedTemplateId) { _, newId in
                    if let tmpl = providerTemplates.first(where: { $0.id == newId }), tmpl.id != "custom" {
                        name = tmpl.name
                        baseURL = tmpl.baseURL
                        var suggested: [String] = []
                        if let asr = tmpl.suggestedASR { suggested.append(asr) }
                        if let llm = tmpl.suggestedLLM { suggested.append(llm) }
                        if cachedModels.isEmpty && !suggested.isEmpty {
                            cachedModels = suggested
                        }
                    }
                }

                TextField("Name", text: $name, prompt: Text("e.g. Groq"))
                TextField("Base URL", text: $baseURL, prompt: Text("https://api.groq.com/openai/v1"))
                SecureField("API Key", text: $apiKey, prompt: Text(isLocalURL ? "Optional for local service" : (hasStoredKey ? "Stored in Keychain" : "Enter API key")))

                if !baseURL.isEmpty, OpenAIConfig(baseURL: baseURL).endpoint == nil {
                    Text("Enter a valid http(s) URL with a host and API prefix.")
                        .foregroundStyle(JotUI.Colors.error)
                        .font(JotUI.TypeScale.labelSmall())
                }

                HStack(spacing: 8) {
                    Button("Test Connection") { testConnection() }
                        .disabled(!canTest || status.isInProgress)

                    Button("Fetch Models") { fetchModels() }
                        .disabled(!canTest || status.isInProgress)

                    if !cachedModels.isEmpty {
                        Text("\(cachedModels.count) models")
                            .font(JotUI.TypeScale.labelSmall())
                            .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    }
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
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)

            Divider()

            HStack {
                if canDelete {
                    Button("Delete Provider", role: .destructive) {
                        deleteProvider()
                    }
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || status.isInProgress)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 420)
        .onAppear {
            if let provider {
                name = provider.name
                baseURL = provider.baseURL
                cachedModels = provider.cachedModels
                hasStoredKey = !(KeychainStore.loadAPIKey(forProviderId: provider.id) ?? "").isEmpty
                if let matched = providerTemplates.first(where: { $0.baseURL == provider.baseURL }) {
                    selectedTemplateId = matched.id
                } else {
                    selectedTemplateId = "custom"
                }
            } else {
                selectedTemplateId = "custom"
                name = ""
                baseURL = ""
                cachedModels = []
                hasStoredKey = false
            }
        }
    }

    private func testConnection() {
        guard let key = effectiveKey, !status.isInProgress else { return }
        status = .inProgress("Testing connection…")
        let config = OpenAIConfig(baseURL: baseURL)
        Task { @MainActor in
            let result = await OpenAIClient(apiKey: key).checkConnection(config: config)
            switch result {
            case .reachable:
                status = .success("Connection successful! Server is reachable.")
            case .rejected(let msg):
                status = .error("Connection rejected: \(msg)")
            case .unreachable:
                status = .error("Unable to reach server. Check URL and network.")
            case .unverified:
                status = .error("Server responded with unexpected status.")
            }
        }
    }

    private func fetchModels() {
        guard let key = effectiveKey, !status.isInProgress else { return }
        status = .inProgress("Fetching models…")
        let config = OpenAIConfig(baseURL: baseURL)
        Task { @MainActor in
            do {
                let models = try await OpenAIClient(apiKey: key).fetchModels(config: config)
                if models.isEmpty {
                    status = .error("Models endpoint returned no models.")
                } else {
                    cachedModels = models
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

    private func deleteProvider() {
        guard let provider, canDelete else { return }
        settings.deleteProvider(id: provider.id)
        onSave()
        dismiss()
    }

    private func save() {
        guard canSave, !status.isInProgress else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = provider?.id ?? UUID().uuidString
        let updated = APIProvider(id: id, name: trimmedName, baseURL: trimmedURL, cachedModels: cachedModels)

        let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !enteredKey.isEmpty {
            KeychainStore.saveAPIKey(enteredKey, forProviderId: id)
        }

        settings.saveProvider(updated)
        onSave()
        dismiss()
    }
}

// MARK: - PromptDetailSheet

struct PromptDetailSheet: View {
    let preset: PromptPreset
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var promptText: String = ""
    private let settings = SettingsStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(preset.title)
                    .font(JotUI.TypeScale.title())
                    .foregroundStyle(JotUI.Colors.onSurface)
                Spacer()
            }

            Text("Custom instructions for text polish when this preset is selected:")
                .font(JotUI.TypeScale.labelSmall())
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)

            TextEditor(text: $promptText)
                .font(.system(size: 13))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: JotUI.Radius.small)
                        .fill(JotUI.Colors.surfaceContainer)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: JotUI.Radius.small)
                        .strokeBorder(JotUI.Colors.outlineVariant.opacity(0.6), lineWidth: 1)
                )
                .frame(minHeight: 180)

            HStack {
                Button("Reset to Default") {
                    if let defaultPreset = SettingsStore.defaultPromptPresets.first(where: { $0.id == preset.id }) {
                        promptText = defaultPreset.promptText
                    }
                }
                .font(JotUI.TypeScale.labelSmall())
                .buttonStyle(.link)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Done") {
                    settings.updatePromptPreset(id: preset.id, newText: promptText)
                    onSave()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 340)
        .onAppear {
            promptText = preset.promptText
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

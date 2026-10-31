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

import Foundation

public extension Notification.Name {
    /// Posted after any SettingsStore write and after Keychain API-key writes,
    /// with `object` = the key ("showIdleIndicator", "apiKey", …). Runtime
    /// surfaces that render a setting (pill, status line, hotkey engine) observe
    /// this so toggles take effect the moment they're flipped — never "on the
    /// next unrelated transition". (gateTrips bookkeeping is exempt: nothing
    /// renders it.)
    static let gtSettingDidChange = Notification.Name("com.ammaar.jot.setting-changed")

    /// Posted when the gate auto-disables the opt-in tone pass (3 trips in 24h)
    /// so the app can tell the user instead of silently dropping it. Native smart
    /// transcription is unaffected — the user loses an extra, not their words.
    static let gtSmartFormattingAutoDegraded = Notification.Name("com.ammaar.jot.auto-degraded")
}

/// UserDefaults-backed settings (M3 minimal; the Settings UI lands at M7).
/// Endpoint + model IDs are overridable because preview models get renamed.
public struct SettingsStore: Sendable {
    private static let defaults = UserDefaults.standard

    public init() {}

    private static func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .gtSettingDidChange, object: key)
    }

    /// Single source of truth for endpoint-override validity — the Settings UI
    /// warning and the effective config MUST use the same predicate, or one of
    /// them lies about which endpoint is in use.
    public static func usableEndpointURL(_ raw: String?) -> URL? {
        OpenAIConfig(baseURL: raw ?? "").endpoint
    }

    /// True once the user finished onboarding — a deliberate "I'll add it later"
    /// must not re-trap them in the wizard every launch.
    public var hasCompletedOnboarding: Bool {
        Self.defaults.bool(forKey: "hasCompletedOnboarding")
    }

    public func setHasCompletedOnboarding(_ done: Bool) {
        Self.set(done, forKey: "hasCompletedOnboarding")
    }

    public var providers: [APIProvider] {
        if let data = Self.defaults.data(forKey: "apiProviders"),
           let decoded = try? JSONDecoder().decode([APIProvider].self, from: data) {
            return decoded
        }
        // Auto-migration on first read if providers is empty
        let rawDict = Self.defaults.dictionary(forKey: "openAIConfig") as? [String: String] ?? [:]
        let rawBaseURL = rawDict["baseURL"] ?? ""
        let legacyKey = KeychainStore.loadAPIKey()
        let hasStoredKey = !(legacyKey ?? "").isEmpty
        let isConfigured = OpenAIConfig(baseURL: rawBaseURL).endpoint != nil

        if isConfigured || hasStoredKey {
            let defaultProvider = APIProvider(
                id: "default",
                name: "Default Provider",
                baseURL: rawBaseURL,
                cachedModels: []
            )
            if let legacyKey, !legacyKey.isEmpty {
                KeychainStore.saveAPIKey(legacyKey, forProviderId: "default")
            }
            let migrated = [defaultProvider]
            if let encoded = try? JSONEncoder().encode(migrated) {
                Self.defaults.set(encoded, forKey: "apiProviders")
            }
            if Self.defaults.string(forKey: "asrProviderId") == nil {
                Self.defaults.set("default", forKey: "asrProviderId")
            }
            if Self.defaults.string(forKey: "llmProviderId") == nil {
                Self.defaults.set("default", forKey: "llmProviderId")
            }
            return migrated
        }
        return []
    }

    public var asrProviderId: String? {
        if let id = Self.defaults.string(forKey: "asrProviderId"), !id.isEmpty {
            return id
        }
        return providers.first?.id
    }

    public var llmProviderId: String? {
        if let id = Self.defaults.string(forKey: "llmProviderId"), !id.isEmpty {
            return id
        }
        return providers.first?.id
    }

    private func saveProvidersInternal(_ list: [APIProvider]) {
        if let data = try? JSONEncoder().encode(list) {
            Self.defaults.set(data, forKey: "apiProviders")
            NotificationCenter.default.post(name: .gtSettingDidChange, object: "providers")
        }
    }

    public func saveProviders(_ list: [APIProvider]) {
        saveProvidersInternal(list)
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "openAIConfig")
    }

    public func saveProvider(_ provider: APIProvider) {
        var list = providers
        if let index = list.firstIndex(where: { $0.id == provider.id }) {
            list[index] = provider
        } else {
            list.append(provider)
        }
        saveProviders(list)
        if Self.defaults.string(forKey: "asrProviderId") == nil {
            setASRProvider(id: provider.id, model: nil)
        }
        if Self.defaults.string(forKey: "llmProviderId") == nil {
            setLLMProvider(id: provider.id, model: nil)
        }
    }

    public func deleteProvider(id: String) {
        var list = providers
        list.removeAll { $0.id == id }
        KeychainStore.deleteAPIKey(forProviderId: id, notify: true)
        saveProviders(list)
        if asrProviderId == id {
            setASRProvider(id: list.first?.id ?? "", model: nil)
        }
        if llmProviderId == id {
            setLLMProvider(id: list.first?.id ?? "", model: nil)
        }
    }

    public func setASRProvider(id: String, model: String?) {
        Self.set(id, forKey: "asrProviderId")
        var rawDict = Self.defaults.dictionary(forKey: "openAIConfig") as? [String: String] ?? [:]
        if let p = providers.first(where: { $0.id == id }) {
            rawDict["baseURL"] = p.baseURL
        }
        if let model {
            rawDict["asrModel"] = model
        }
        Self.set(rawDict, forKey: "openAIConfig")
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "asrProviderId")
    }

    public func setLLMProvider(id: String, model: String?) {
        Self.set(id, forKey: "llmProviderId")
        if let model {
            setLLMModel(model)
        }
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "llmProviderId")
    }

    public func setASRModel(_ model: String) {
        var rawDict = Self.defaults.dictionary(forKey: "openAIConfig") as? [String: String] ?? [:]
        rawDict["asrModel"] = model
        Self.set(rawDict, forKey: "openAIConfig")
    }

    public func setLLMModel(_ model: String) {
        var rawDict = Self.defaults.dictionary(forKey: "openAIConfig") as? [String: String] ?? [:]
        rawDict["llmModel"] = model
        Self.set(rawDict, forKey: "openAIConfig")
    }

    public func setLLMThinking(enabled: Bool, control: LLMThinkingControl) {
        var rawDict = Self.defaults.dictionary(forKey: "openAIConfig") as? [String: String] ?? [:]
        rawDict["llmThinkingEnabled"] = enabled ? "true" : "false"
        rawDict["llmThinkingControl"] = control.rawValue
        Self.set(rawDict, forKey: "openAIConfig")
    }

    public var apiConfig: OpenAIConfig {
        guard let data = Self.defaults.dictionary(forKey: "openAIConfig") as? [String: String] else {
            return OpenAIConfig()
        }
        let asrProvider = providers.first { $0.id == asrProviderId }
        let baseURL = asrProvider?.baseURL ?? data["baseURL"] ?? ""
        return OpenAIConfig(
            baseURL: baseURL,
            asrModel: data["asrModel"] ?? "",
            llmModel: data["llmModel"] ?? "",
            llmThinkingEnabled: data["llmThinkingEnabled"] == "true",
            llmThinkingControl: LLMThinkingControl(rawValue: data["llmThinkingControl"] ?? "") ?? .none
        )
    }

    public var openAIConfig: OpenAIConfig {
        apiConfig
    }

    public var apiConfigured: Bool {
        guard let asr = providers.first(where: { $0.id == asrProviderId }) ?? providers.first,
              asr.isConfigured,
              !apiConfig.asrModel.isEmpty else {
            return false
        }
        let key = KeychainStore.loadAPIKey(forProviderId: asr.id)
        return !(key ?? "").isEmpty
    }

    public func setAPIConfig(_ config: OpenAIConfig) {
        Self.set(["baseURL": config.baseURL, "asrModel": config.asrModel, "llmModel": config.llmModel,
                  "llmThinkingEnabled": config.llmThinkingEnabled ? "true" : "false",
                  "llmThinkingControl": config.llmThinkingControl.rawValue], forKey: "openAIConfig")

        var currentProviders = providers
        if let asrId = asrProviderId, let idx = currentProviders.firstIndex(where: { $0.id == asrId }) {
            currentProviders[idx].baseURL = config.baseURL
            saveProvidersInternal(currentProviders)
        } else if currentProviders.isEmpty && !config.baseURL.isEmpty {
            let p = APIProvider(id: "default", name: "Default Provider", baseURL: config.baseURL)
            saveProvidersInternal([p])
            Self.defaults.set("default", forKey: "asrProviderId")
            Self.defaults.set("default", forKey: "llmProviderId")
        }
    }

    public var automaticInsertionEnabled: Bool {
        Self.defaults.object(forKey: "automaticInsertion") as? Bool ?? true
    }

    public func setAutomaticInsertion(_ enabled: Bool) {
        Self.set(enabled, forKey: "automaticInsertion")
    }

    /// Double-tap the dictation key to lock hands-free. OFF by default: firm taps
    /// routinely exceed the hold threshold, misreading tap-tap as hold→finalize
    /// (dogfood). The timing-free gesture is Space-while-holding.
    public var doubleTapLockEnabled: Bool {
        Self.defaults.object(forKey: "doubleTapLock") as? Bool ?? false
    }

    public func setDoubleTapLock(_ enabled: Bool) {
        Self.set(enabled, forKey: "doubleTapLock")
    }

    /// Show the resting dot at the bottom of the screen when idle. Off = the pill
    /// only appears while dictating.
    public var showIdleIndicator: Bool {
        Self.defaults.object(forKey: "showIdleIndicator") as? Bool ?? true
    }

    public func setShowIdleIndicator(_ show: Bool) {
        Self.set(show, forKey: "showIdleIndicator")
    }

    public var soundsEnabled: Bool {
        Self.defaults.object(forKey: "soundsEnabled") as? Bool ?? true
    }

    public func setSoundsEnabled(_ enabled: Bool) {
        Self.set(enabled, forKey: "soundsEnabled")
    }

    public var hotkeyKey: HotkeyKey {
        (Self.defaults.string(forKey: "hotkeyKey")).flatMap(HotkeyKey.init(rawValue:)) ?? .fn
    }

    // MARK: - Formatting policy

    /// The opt-in second pass through the cleanup model — this is what carries
    /// per-app tone. Off by default: it costs a round trip and sends the
    /// transcript text a second time.
    public var smartCleanupPassEnabled: Bool {
        Self.defaults.object(forKey: "smartCleanupPass") as? Bool ?? false
    }

    public func setSmartCleanupPass(_ enabled: Bool) {
        if enabled {
            // A deliberate re-enable is a clean slate. This moved here with the
            // gate counter: auto-degrade now switches THIS flag off, so leaving
            // the clear on setSmartFormatting would resurrect the bug where one
            // stale trip inside the old 24h window instantly re-degrades.
            Self.defaults.removeObject(forKey: "gateTrips")
        }
        Self.set(enabled, forKey: "smartCleanupPass")
    }

    public func setHotkeyKey(_ key: HotkeyKey) {
        Self.set(key.rawValue, forKey: "hotkeyKey")
    }

    /// Experimental: judge speech RELATIVE to the room instead of against fixed
    /// thresholds that assume a quiet one, and (once probed) let macOS suppress
    /// background voices. Off by default until dogfood data earns the flip.
    ///
    /// One key gates every behaviour in the noise work, so there is exactly one
    /// thing to turn on, one thing to turn off, and one thing to flip when the
    /// numbers are in. The measurements it would act on are recorded either way —
    /// `NoiseFloorEstimator` runs unconditionally.
    public var experimentalNoiseHandling: Bool {
        Self.defaults.bool(forKey: "experimentalNoiseHandling")
    }

    public func setExperimentalNoiseHandling(_ enabled: Bool) {
        Self.set(enabled, forKey: "experimentalNoiseHandling")
    }

    /// Days to keep audio files (transcripts are kept until deleted). 0 = forever.
    public var audioRetentionDays: Int {
        Self.defaults.object(forKey: "audioRetentionDays") as? Int ?? 7
    }

    public func setAudioRetentionDays(_ days: Int) {
        Self.set(days, forKey: "audioRetentionDays")
    }

    /// Auto-degrade bookkeeping (F11): ≥3 gate trips in 24h ⇒ verbatim by default.
    public func recordGateTrip(now: Date = Date()) -> Int {
        var trips = (Self.defaults.array(forKey: "gateTrips") as? [Date]) ?? []
        trips = trips.filter { now.timeIntervalSince($0) < 86_400 }
        trips.append(now)
        Self.defaults.set(trips, forKey: "gateTrips")
        return trips.count
    }

    // MARK: - Prompts

    public static let defaultPromptPresets: [PromptPreset] = [
        PromptPreset(id: "general", title: "General Polish", promptText: PromptV1.rules),
        PromptPreset(id: "email", title: "Professional Email", promptText: "Tone: professional email. Complete sentences; keep greetings and sign-offs as spoken."),
        PromptPreset(id: "workChat", title: "Work Chat", promptText: "Tone: casual-professional chat message. No trailing period on a single-sentence message."),
        PromptPreset(id: "personalChat", title: "Personal Chat", promptText: "Tone: informal message. Keep contractions and slang as spoken. No trailing period."),
        PromptPreset(id: "code", title: "Technical & Code", promptText: "Technical dictation. Preserve identifiers, file names, and casing conventions like camelCase or snake_case exactly as spoken.")
    ]

    public var selectedPromptId: String {
        Self.defaults.string(forKey: "selectedPromptId") ?? "general"
    }

    public func setSelectedPromptId(_ id: String) {
        Self.set(id, forKey: "selectedPromptId")
    }

    public var promptPresets: [PromptPreset] {
        if let data = Self.defaults.data(forKey: "promptPresets"),
           let presets = try? JSONDecoder().decode([PromptPreset].self, from: data) {
            return presets
        }
        return Self.defaultPromptPresets
    }

    public func savePromptPresets(_ presets: [PromptPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            Self.set(data, forKey: "promptPresets")
        }
    }

    public func updatePromptPreset(id: String, newText: String) {
        var presets = promptPresets
        if let index = presets.firstIndex(where: { $0.id == id }) {
            presets[index].promptText = newText
            savePromptPresets(presets)
        }
    }

    public var activePromptText: String {
        promptPresets.first(where: { $0.id == selectedPromptId })?.promptText ?? PromptV1.rules
    }
}

public struct APIProvider: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var cachedModels: [String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        cachedModels: [String] = []
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cachedModels = cachedModels
    }

    public var endpoint: URL? {
        OpenAIConfig(baseURL: baseURL).endpoint
    }

    public var isConfigured: Bool {
        endpoint != nil
    }
}

public struct PromptPreset: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var promptText: String

    public init(id: String, title: String, promptText: String) {
        self.id = id
        self.title = title
        self.promptText = promptText
    }
}

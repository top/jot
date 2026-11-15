import Foundation

public final class OpenAITranscriptionService: TranscriptionServicing, @unchecked Sendable {
    private let settings: SettingsStore
    private let apiKeyResolver: @Sendable (String) -> String?
    private let injectedSession: URLSession?
    private let lock = NSLock()
    private var sessionsByProvider: [String: URLSession] = [:]

    static func cleanupDeadline(for config: OpenAIConfig) -> TimeInterval {
        60
    }

    public init(
        settings: SettingsStore = SettingsStore(),
        session: URLSession? = nil,
        apiKey: (@Sendable () -> String?)? = nil,
        apiKeyForProvider: (@Sendable (String) -> String?)? = nil
    ) {
        self.settings = settings
        self.injectedSession = session
        if let apiKeyForProvider {
            self.apiKeyResolver = apiKeyForProvider
        } else if let apiKey {
            self.apiKeyResolver = { _ in apiKey() }
        } else {
            self.apiKeyResolver = { providerId in KeychainStore.loadAPIKey(forProviderId: providerId) }
        }
    }

    deinit {
        let owned: [URLSession]
        lock.lock()
        owned = Array(sessionsByProvider.values)
        sessionsByProvider.removeAll()
        lock.unlock()
        for session in owned {
            session.invalidateAndCancel()
        }
    }

    /// Rotates pooled URLSessions so stale sockets, proxy/VPN state, or old
    /// provider endpoints are never reused. In-flight tasks finish normally.
    public func resetConnections(forProviderId providerId: String? = nil) {
        guard injectedSession == nil else { return }
        let displaced: [URLSession]
        lock.lock()
        if let providerId {
            displaced = sessionsByProvider.removeValue(forKey: providerId).map { [$0] } ?? []
        } else {
            displaced = Array(sessionsByProvider.values)
            sessionsByProvider.removeAll()
        }
        lock.unlock()
        for session in displaced {
            session.finishTasksAndInvalidate()
        }
    }

    private func session(forProviderId providerId: String) -> URLSession {
        if let injectedSession {
            return injectedSession
        }
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessionsByProvider[providerId] {
            return existing
        }
        let created = URLSession(configuration: OpenAIClient.makeEphemeralConfiguration(timeoutForResource: 300))
        sessionsByProvider[providerId] = created
        return created
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        let startTime = Date()
        // Snapshot all settings once so a concurrent Settings edit mid-request
        // cannot mix providers, models, or misreport modelID at completion.
        let snapshotProviders = settings.providers
        let snapshotConfig = settings.apiConfig
        let snapshotASRProviderID = settings.asrProviderId
        let snapshotLLMProviderID = settings.llmProviderId
        let snapshotCleanupEnabled = settings.smartCleanupPassEnabled && !snapshotConfig.llmModel.isEmpty
        let snapshotActivePromptText = settings.activePromptText

        let asrProvider = snapshotProviders.first { $0.id == snapshotASRProviderID } ?? snapshotProviders.first
        let asrBaseURL = asrProvider?.baseURL ?? snapshotConfig.baseURL
        let asrModel = snapshotConfig.asrModel
        let asrProviderId = asrProvider?.id ?? "default"

        let asrConfig = OpenAIConfig(baseURL: asrBaseURL, asrModel: asrModel)
        guard asrConfig.isConfigured,
              let asrKey = apiKeyResolver(asrProviderId),
              !asrKey.isEmpty else {
            throw TranscriptionError.auth
        }

        let asrClient = OpenAIClient(apiKey: asrKey, session: session(forProviderId: asrProviderId))
        Log.transcription.info("Pipeline start: asrProvider=\(asrProviderId, privacy: .public), asrModel=\(asrModel, privacy: .public), cleanupEnabled=\(snapshotCleanupEnabled)")

        let wavURL = audioURL.deletingLastPathComponent().appendingPathComponent("audio.wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let encoded = try WAVEncoder.encode(cafURL: audioURL, wavURL: wavURL)
        let audio = try Data(contentsOf: encoded.url)
        let dictionary = DictionaryStore()
        let vocabulary = dictionary.sanitizedVocabulary()
        let spellings = dictionary.spellings()
        let rules = dictionary.replacementRules()
        let deadline = TimeoutPolicy.overallDeadline(audioDuration: durationSeconds)

        let asrStartTime = Date()
        var raw: String
        do {
            raw = try await asrClient.transcribe(wavData: audio, config: asrConfig, vocabulary: vocabulary, deadline: deadline)
        } catch let error as TranscriptionError {
            switch error {
            case .network, .timeout:
                // Drop a potentially dead keep-alive socket before retrying once.
                resetConnections(forProviderId: asrProviderId)
                try await Task.sleep(nanoseconds: 500_000_000)
                let retryClient = OpenAIClient(apiKey: asrKey, session: session(forProviderId: asrProviderId))
                raw = try await retryClient.transcribe(wavData: audio, config: asrConfig, vocabulary: vocabulary, deadline: deadline)
            default: throw error
            }
        }
        let asrDuration = Date().timeIntervalSince(asrStartTime)
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw TranscriptionError.emptyTranscript }
        Log.transcription.info("ASR finished in \(String(format: "%.2f", asrDuration))s (\(raw.count) chars)")

        var cleaned = raw
        if snapshotCleanupEnabled {
            let llmStartTime = Date()
            let llmProvider = snapshotProviders.first { $0.id == snapshotLLMProviderID } ?? snapshotProviders.first
            let llmBaseURL = llmProvider?.baseURL ?? snapshotConfig.baseURL
            let llmModel = snapshotConfig.llmModel
            let llmProviderId = llmProvider?.id ?? "default"

            let llmConfig = OpenAIConfig(
                baseURL: llmBaseURL,
                asrModel: asrModel,
                llmModel: llmModel,
                llmThinkingEnabled: snapshotConfig.llmThinkingEnabled,
                llmThinkingControl: snapshotConfig.llmThinkingControl
            )

            if let llmKey = apiKeyResolver(llmProviderId), !llmKey.isEmpty, llmConfig.endpoint != nil {
                Log.transcription.info("Starting text polish pass (LLM): model=\(llmModel, privacy: .public)")
                let llmClient = OpenAIClient(apiKey: llmKey, session: session(forProviderId: llmProviderId))
                let prompt = PromptV1.cleanupPrompt(
                    raw: raw,
                    tone: PromptV1.toneCategory(forBundleID: context.targetAppBundleID),
                    activePromptText: snapshotActivePromptText,
                    vocabulary: vocabulary,
                    spellings: spellings
                )
                do {
                    let response = try await llmClient.cleanup(prompt: prompt, config: llmConfig, deadline: Self.cleanupDeadline(for: llmConfig))
                    let candidate = ValidationGate.stripArtifacts(response)
                    if ValidationGate.validate(raw: raw, cleaned: candidate).accepted {
                        cleaned = candidate
                    } else if settings.recordGateTrip() >= 3 {
                        settings.setSmartCleanupPass(false)
                        NotificationCenter.default.post(name: .gtSmartFormattingAutoDegraded, object: nil)
                    }
                    let llmDuration = Date().timeIntervalSince(llmStartTime)
                    Log.transcription.info("LLM polish completed in \(String(format: "%.2f", llmDuration))s")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.transcription.info("Text cleanup unavailable; using original transcript")
                }
            } else {
                Log.transcription.info("LLM provider key or endpoint missing; skipping text cleanup")
            }
        } else {
            Log.transcription.info("LLM polish disabled — skipping LLM pass entirely")
        }

        try Task.checkCancellation()
        let totalDuration = Date().timeIntervalSince(startTime)
        Log.transcription.info("Pipeline completed in \(String(format: "%.2f", totalDuration))s")

        return TranscriptionResult(
            rawTranscript: raw,
            cleanedTranscript: ReplacementEngine.apply(rules, to: cleaned),
            modelID: snapshotCleanupEnabled ? "\(asrModel)+\(snapshotConfig.llmModel)" : asrModel
        )
    }
}
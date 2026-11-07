import Foundation

public struct OpenAITranscriptionService: TranscriptionServicing {
    private let settings: SettingsStore
    private let apiKeyResolver: @Sendable (String) -> String?
    private let session: URLSession

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
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForResource = 600
            configuration.httpShouldUsePipelining = true
            self.session = URLSession(configuration: configuration)
        }
        if let apiKeyForProvider {
            self.apiKeyResolver = apiKeyForProvider
        } else if let apiKey {
            self.apiKeyResolver = { _ in apiKey() }
        } else {
            self.apiKeyResolver = { providerId in KeychainStore.loadAPIKey(forProviderId: providerId) }
        }
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        let startTime = Date()
        let asrProvider = settings.providers.first { $0.id == settings.asrProviderId } ?? settings.providers.first
        let asrBaseURL = asrProvider?.baseURL ?? settings.apiConfig.baseURL
        let asrModel = settings.apiConfig.asrModel
        let asrProviderId = asrProvider?.id ?? "default"

        let asrConfig = OpenAIConfig(baseURL: asrBaseURL, asrModel: asrModel)
        guard asrConfig.isConfigured,
              let asrKey = apiKeyResolver(asrProviderId),
              !asrKey.isEmpty else {
            throw TranscriptionError.auth
        }

        let asrClient = OpenAIClient(apiKey: asrKey, session: session)
        let cleanupEnabled = settings.smartCleanupPassEnabled && !settings.apiConfig.llmModel.isEmpty
        Log.transcription.info("Pipeline start: asrProvider=\(asrProviderId, privacy: .public), asrModel=\(asrModel, privacy: .public), cleanupEnabled=\(cleanupEnabled)")

        let wavURL = audioURL.deletingLastPathComponent().appendingPathComponent("audio.wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let encoded = try WAVEncoder.encode(cafURL: audioURL, wavURL: wavURL)
        let audio = try Data(contentsOf: encoded.url)
        let dictionary = DictionaryStore()
        let vocabulary = dictionary.sanitizedVocabulary()
        let rules = dictionary.replacementRules()
        let deadline = TimeoutPolicy.overallDeadline(audioDuration: durationSeconds)

        let asrStartTime = Date()
        var raw: String
        do {
            raw = try await asrClient.transcribe(wavData: audio, config: asrConfig, vocabulary: vocabulary, deadline: deadline)
        } catch let error as TranscriptionError {
            switch error {
            case .network, .timeout:
                try await Task.sleep(nanoseconds: 500_000_000)
                raw = try await asrClient.transcribe(wavData: audio, config: asrConfig, vocabulary: vocabulary, deadline: deadline)
            default: throw error
            }
        }
        let asrDuration = Date().timeIntervalSince(asrStartTime)
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw TranscriptionError.emptyTranscript }
        Log.transcription.info("ASR finished in \(String(format: "%.2f", asrDuration))s (\(raw.count) chars)")

        var cleaned = raw
        if cleanupEnabled {
            let llmStartTime = Date()
            let llmProvider = settings.providers.first { $0.id == settings.llmProviderId } ?? settings.providers.first
            let llmBaseURL = llmProvider?.baseURL ?? settings.apiConfig.baseURL
            let llmModel = settings.apiConfig.llmModel
            let llmProviderId = llmProvider?.id ?? "default"

            let llmConfig = OpenAIConfig(
                baseURL: llmBaseURL,
                asrModel: asrModel,
                llmModel: llmModel,
                llmThinkingEnabled: settings.apiConfig.llmThinkingEnabled,
                llmThinkingControl: settings.apiConfig.llmThinkingControl
            )

            if let llmKey = apiKeyResolver(llmProviderId), !llmKey.isEmpty, llmConfig.endpoint != nil {
                Log.transcription.info("Starting text polish pass (LLM): model=\(llmModel, privacy: .public)")
                let llmClient = OpenAIClient(apiKey: llmKey, session: session)
                let prompt = PromptV1.cleanupPrompt(
                    raw: raw,
                    tone: PromptV1.toneCategory(forBundleID: context.targetAppBundleID),
                    activePromptText: settings.activePromptText,
                    vocabulary: vocabulary,
                    spellings: dictionary.spellings()
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
            modelID: cleanupEnabled ? "\(settings.apiConfig.asrModel)+\(settings.apiConfig.llmModel)" : settings.apiConfig.asrModel
        )
    }
}
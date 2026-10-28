import Foundation

public struct OpenAITranscriptionService: TranscriptionServicing {
    private let settings: SettingsStore
    private let apiKey: @Sendable () -> String?
    private let session: URLSession?
    static let cleanupDeadline: TimeInterval = 5

    public init(settings: SettingsStore = SettingsStore(), session: URLSession? = nil,
                apiKey: @escaping @Sendable () -> String? = { KeychainStore.loadAPIKey() }) {
        self.settings = settings
        self.session = session
        self.apiKey = apiKey
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        let config = settings.apiConfig
        guard config.isConfigured, let key = apiKey(), !key.isEmpty else { throw TranscriptionError.auth }
        let client = OpenAIClient(apiKey: key, session: session)
        let cleanupEnabled = settings.smartCleanupPassEnabled && !config.llmModel.isEmpty
        let wavURL = audioURL.deletingLastPathComponent().appendingPathComponent("audio.wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let encoded = try WAVEncoder.encode(cafURL: audioURL, wavURL: wavURL)
        let audio = try Data(contentsOf: encoded.url)
        let dictionary = DictionaryStore()
        let vocabulary = dictionary.sanitizedVocabulary()
        let rules = dictionary.replacementRules()
        let deadline = TimeoutPolicy.overallDeadline(audioDuration: durationSeconds)
        var raw: String
        do {
            raw = try await client.transcribe(wavData: audio, config: config, vocabulary: vocabulary, deadline: deadline)
        } catch let error as TranscriptionError {
            switch error {
            case .network, .timeout:
                try await Task.sleep(nanoseconds: 500_000_000)
                raw = try await client.transcribe(wavData: audio, config: config, vocabulary: vocabulary, deadline: deadline)
            default: throw error
            }
        }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, durationSeconds >= 0.6 {
            raw = try await client.transcribe(wavData: audio, config: config, vocabulary: vocabulary, deadline: deadline)
        }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw TranscriptionError.emptyTranscript }
        var cleaned = raw
        if cleanupEnabled {
            let prompt = PromptV1.cleanupPrompt(raw: raw,
                tone: PromptV1.toneCategory(forBundleID: context.targetAppBundleID),
                vocabulary: vocabulary, spellings: dictionary.spellings())
            do {
                let response = try await client.cleanup(prompt: prompt, config: config, deadline: Self.cleanupDeadline)
                let candidate = ValidationGate.stripArtifacts(response)
                if ValidationGate.validate(raw: raw, cleaned: candidate).accepted {
                    cleaned = candidate
                } else if settings.recordGateTrip() >= 3 {
                    settings.setSmartCleanupPass(false)
                    NotificationCenter.default.post(name: .gtSmartFormattingAutoDegraded, object: nil)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.transcription.info("Text cleanup unavailable; using original transcript")
            }
        }
        try Task.checkCancellation()
        return TranscriptionResult(rawTranscript: raw,
            cleanedTranscript: ReplacementEngine.apply(rules, to: cleaned),
            modelID: cleanupEnabled ? "\(config.asrModel)+\(config.llmModel)" : config.asrModel)
    }
}
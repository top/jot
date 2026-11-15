import AVFoundation
import XCTest
@testable import JotCore

final class OpenAIClientTests: XCTestCase {
    private final class MockProtocol: URLProtocol, @unchecked Sendable {
        static var handler: ((URLRequest) throws -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (status, data) = try Self.handler!(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }

    private func session(handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        MockProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() { MockProtocol.handler = nil }

    func testCleanupDeadlineIsSixtySeconds() {
        for control in LLMThinkingControl.allCases {
            for enabled in [false, true] {
                let config = OpenAIConfig(llmThinkingEnabled: enabled, llmThinkingControl: control)
                XCTAssertEqual(OpenAITranscriptionService.cleanupDeadline(for: config), 60)
            }
        }
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCleanupExplicitlyControlsThinkingForEachProtocol() async throws {
        for control in LLMThinkingControl.allCases {
            for enabled in [false, true] {
                let client = OpenAIClient(apiKey: "test-key", session: session { request in
                    XCTAssertEqual(request.url?.path, "/v1/chat/completions")
                    let body = try Self.requestBody(request)
                    XCTAssertEqual(body["model"] as? String, "llm")
                    XCTAssertEqual(body["stream"] as? Bool, false)
                    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
                    XCTAssertEqual(messages, [["role": "user", "content": "Clean this."]])
                    XCTAssertEqual(body.count, control == .none ? 3 : 4)
                    switch control {
                    case .none:
                        XCTAssertNil(body["chat_template_kwargs"])
                        XCTAssertNil(body["enable_thinking"])
                        XCTAssertNil(body["reasoning_effort"])
                    case .chatTemplate:
                        XCTAssertEqual(body["chat_template_kwargs"] as? [String: Bool], ["enable_thinking": enabled])
                    case .enableThinking:
                        XCTAssertEqual(body["enable_thinking"] as? Bool, enabled)
                    case .reasoningEffort:
                        XCTAssertEqual(body["reasoning_effort"] as? String, enabled ? "medium" : "none")
                    }
                    return (200, Data(#"{"choices":[{"message":{"content":"Cleaned."},"finish_reason":"stop"}]}"#.utf8))
                })
                let config = OpenAIConfig(baseURL: "http://localhost:8000/v1", llmModel: "llm",
                    llmThinkingEnabled: enabled, llmThinkingControl: control)
                let result = try await client.cleanup(prompt: "Clean this.", config: config, deadline: 2)
                XCTAssertEqual(result, "Cleaned.")
            }
        }
    }

    func testRejectedThinkingControlDoesNotRetryWithoutIt() async throws {
        var requests = 0
        let client = OpenAIClient(apiKey: "test-key", session: session { request in
            requests += 1
            let body = try Self.requestBody(request)
            XCTAssertEqual(body["chat_template_kwargs"] as? [String: Bool], ["enable_thinking": false])
            return (400, Data(#"{"error":{"message":"Unsupported thinking parameter"}}"#.utf8))
        })
        do {
            _ = try await client.cleanup(prompt: "Clean this.",
                config: OpenAIConfig(baseURL: "http://localhost:8000/v1", llmModel: "llm", llmThinkingControl: .chatTemplate), deadline: 2)
            XCTFail("Expected rejection")
        } catch TranscriptionError.badRequest {
            XCTAssertEqual(requests, 1)
        }
    }

    func testTranscriptionUsesConfiguredPrefixAndBearerHeader() async throws {
        let session = session { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8000/prefix/v1/audio/transcriptions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            return (200, Data(#"{"text":"hello"}"#.utf8))
        }
        let client = OpenAIClient(apiKey: "test-key", session: session)
        let text = try await client.transcribe(wavData: Data([1, 2]),
            config: OpenAIConfig(baseURL: "http://localhost:8000/prefix/v1", asrModel: "custom-asr"),
            vocabulary: [], deadline: 2)
        XCTAssertEqual(text, "hello")
    }

    func testMissingModelsEndpointDoesNotRejectConfiguration() async {
        let client = OpenAIClient(apiKey: "test-key", session: session { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            return (404, Data())
        })
        let result = await client.checkConnection(config: OpenAIConfig(baseURL: "http://localhost:8000/v1", asrModel: "asr"))
        XCTAssertEqual(result, .unverified)
    }

    func testFetchModelsParsesModelList() async throws {
        let json = """
        {
            "object": "list",
            "data": [
                {"id": "whisper-large-v3", "object": "model"},
                {"id": "qwen-2.5-7b", "object": "model"}
            ]
        }
        """
        let client = OpenAIClient(apiKey: "test-key", session: session { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            return (200, Data(json.utf8))
        })
        let models = try await client.fetchModels(config: OpenAIConfig(baseURL: "http://localhost:8000/v1", asrModel: "asr"))
        XCTAssertEqual(models, ["qwen-2.5-7b", "whisper-large-v3"])
    }

    private func makeTestCAF(in folder: URL) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        buffer.int16ChannelData![0].initialize(repeating: 100, count: 1600)
        let cafURL = folder.appendingPathComponent("audio.caf")
        let writer = try CAFWriter(url: cafURL, format: format)
        try writer.write(buffer)
        writer.close()
        return cafURL
    }

    private func withIsolatedTranscriptionSettings(_ body: (SettingsStore) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = ["apiProviders", "asrProviderId", "llmProviderId", "openAIConfig", "smartCleanupPass", "gateTrips", "dictionaryEntries"]
        let original = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, original) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.removeObject(forKey: key) }
        try await body(SettingsStore())
    }

    func testCleanupFailurePreservesTranscriptAndDeletesTemporaryWAV() async throws {
        try await withIsolatedTranscriptionSettings { settings in
            settings.setAPIConfig(OpenAIConfig(baseURL: "http://localhost:8000/v1", asrModel: "asr", llmModel: "llm"))
            settings.setSmartCleanupPass(true)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let cafURL = try makeTestCAF(in: folder)
            let service = OpenAITranscriptionService(settings: settings, session: session { request in
                if request.url?.path == "/v1/audio/transcriptions" {
                    return (200, Data(#"{"text":"Original words."}"#.utf8))
                }
                XCTAssertEqual(request.url?.path, "/v1/chat/completions")
                return (503, Data())
            }, apiKey: { "test-key" })
            let result = try await service.transcribe(audioURL: cafURL, durationSeconds: 0.1, context: DictationContext())
            XCTAssertEqual(result.rawTranscript, "Original words.")
            XCTAssertEqual(result.cleanedTranscript, "Original words.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: cafURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path))
        }
    }

    func testSharedSessionRemainsValidAcrossRepeatedTranscriptions() async throws {
        try await withIsolatedTranscriptionSettings { settings in
            settings.setAPIConfig(OpenAIConfig(baseURL: "http://localhost:8000/v1", asrModel: "asr", llmModel: "llm"))
            settings.setSmartCleanupPass(true)

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let cafURL = try makeTestCAF(in: folder)

            let sharedSession = session { request in
                if request.url?.path == "/v1/audio/transcriptions" {
                    return (200, Data(#"{"text":"Hello world."}"#.utf8))
                }
                XCTAssertEqual(request.url?.path, "/v1/chat/completions")
                return (200, Data(#"{"choices":[{"message":{"content":"Hello world."},"finish_reason":"stop"}]}"#.utf8))
            }
            defer { sharedSession.invalidateAndCancel() }

            let service = OpenAITranscriptionService(settings: settings, session: sharedSession, apiKey: { "test-key" })
            let first = try await service.transcribe(audioURL: cafURL, durationSeconds: 0.1, context: DictationContext())
            let second = try await service.transcribe(audioURL: cafURL, durationSeconds: 0.1, context: DictationContext())
            XCTAssertEqual(first.cleanedTranscript, "Hello world.")
            XCTAssertEqual(second.cleanedTranscript, "Hello world.")
        }
    }

    func testDisabledCleanupSkipsLLMAndReturnsASRTranscriptDirectly() async throws {
        try await withIsolatedTranscriptionSettings { settings in
            settings.setAPIConfig(OpenAIConfig(baseURL: "http://localhost:8000/v1", asrModel: "asr-only", llmModel: "unused-llm"))
            settings.setSmartCleanupPass(false)

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let cafURL = try makeTestCAF(in: folder)

            var asrCalls = 0
            var llmCalls = 0
            let sharedSession = session { request in
                if request.url?.path == "/v1/audio/transcriptions" {
                    asrCalls += 1
                    return (200, Data(#"{"text":"  Um, raw ASR transcript.  "}"#.utf8))
                }
                llmCalls += 1
                return (500, Data())
            }
            defer { sharedSession.invalidateAndCancel() }

            let service = OpenAITranscriptionService(settings: settings, session: sharedSession, apiKey: { "test-key" })
            let first = try await service.transcribe(audioURL: cafURL, durationSeconds: 0.1, context: DictationContext())
            let second = try await service.transcribe(audioURL: cafURL, durationSeconds: 0.1, context: DictationContext())

            XCTAssertEqual(asrCalls, 2)
            XCTAssertEqual(llmCalls, 0)
            XCTAssertEqual(first.rawTranscript, "Um, raw ASR transcript.")
            XCTAssertEqual(first.cleanedTranscript, "Um, raw ASR transcript.")
            XCTAssertEqual(first.modelID, "asr-only")
            XCTAssertEqual(second.cleanedTranscript, "Um, raw ASR transcript.")
        }
    }

    func testEmptyLLMModelSkipsLLMAndReturnsASRTranscriptDirectly() async throws {
        try await withIsolatedTranscriptionSettings { settings in
            settings.setAPIConfig(OpenAIConfig(baseURL: "http://localhost:8000/v1", asrModel: "asr-only", llmModel: ""))
            settings.setSmartCleanupPass(true)

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let cafURL = try makeTestCAF(in: folder)

            var llmCalls = 0
            let sharedSession = session { request in
                if request.url?.path == "/v1/audio/transcriptions" {
                    return (200, Data(#"{"text":"Direct ASR text."}"#.utf8))
                }
                llmCalls += 1
                return (500, Data())
            }
            defer { sharedSession.invalidateAndCancel() }

            let service = OpenAITranscriptionService(settings: settings, session: sharedSession, apiKey: { "test-key" })
            let result = try await service.transcribe(audioURL: cafURL, durationSeconds: 0.1, context: DictationContext())

            XCTAssertEqual(llmCalls, 0)
            XCTAssertEqual(result.rawTranscript, "Direct ASR text.")
            XCTAssertEqual(result.cleanedTranscript, "Direct ASR text.")
            XCTAssertEqual(result.modelID, "asr-only")
        }
    }

    func testWAVExportPreservesPCMFrames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for index in 0..<1600 { buffer.int16ChannelData![0][index] = Int16(index) }
        let cafURL = folder.appendingPathComponent("audio.caf")
        let writer = try CAFWriter(url: cafURL, format: format)
        try writer.write(buffer)
        writer.close()
        let output = try WAVEncoder.encode(cafURL: cafURL, wavURL: folder.appendingPathComponent("audio.wav"))
        let bytes = try Data(contentsOf: output.url)
        XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes[8..<12], as: UTF8.self), "WAVE")
        let reader = try AVAudioFile(forReading: output.url, commonFormat: .pcmFormatInt16, interleaved: true)
        XCTAssertEqual(reader.length, 1600)
        XCTAssertEqual(reader.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(reader.processingFormat.channelCount, 1)
        let result = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 1600)!
        try reader.read(into: result)
        XCTAssertEqual(result.int16ChannelData![0][1599], 1599)
    }

    func testBaseURLPreservesPrefixAndRejectsInvalidAddresses() {
        let config = OpenAIConfig(baseURL: " https://example.com/custom/v1/ ", asrModel: " Qwen/Qwen3-ASR-1.7B ")
        XCTAssertTrue(config.isConfigured)
        XCTAssertEqual(config.endpoint?.appendingPathComponent("audio/transcriptions").absoluteString,
                       "https://example.com/custom/v1/audio/transcriptions")
        for address in ["", "https://", "file:///tmp/audio", "https://user:pass@example.com", "https://example.com?key=secret"] {
            XCTAssertNil(OpenAIConfig(baseURL: address).endpoint)
        }
        XCTAssertFalse(OpenAIConfig(baseURL: "http://localhost:8000/v1").isConfigured)
    }

    func testMultipartContainsWAVAndModelWithoutGeminiFields() {
        let audio = Data([0, 1, 2, 255])
        let body = OpenAIClient.transcriptionBody(wavData: audio, model: "custom-asr", vocabulary: ["Jot"], boundary: "test-boundary")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ncustom-asr\r\n"))
        XCTAssertTrue(text.contains("filename=\"audio.wav\"\r\nContent-Type: audio/wav"))
        XCTAssertTrue(text.contains("name=\"prompt\"\r\n\r\nJot"))
        XCTAssertNotNil(body.range(of: audio))
        XCTAssertTrue(text.hasSuffix("--test-boundary--\r\n"))
        XCTAssertFalse(text.contains("generation_config"))
    }

    func testResponseParsingAndEmptyTranscript() throws {
        XCTAssertEqual(try OpenAIClient.extractTranscript(from: Data(#"{"text":"hello"}"#.utf8)), "hello")
        XCTAssertEqual(try OpenAIClient.extractTranscript(from: Data(#"{"text":""}"#.utf8)), "")
        XCTAssertEqual(try OpenAIClient.extractCompletion(from: Data(#"{"choices":[{"message":{"content":"Hello."},"finish_reason":"stop"}]}"#.utf8)), "Hello.")
        XCTAssertThrowsError(try OpenAIClient.extractTranscript(from: Data("{}".utf8)))
        XCTAssertThrowsError(try OpenAIClient.extractCompletion(from: Data(#"{"choices":[{"message":{"content":"cut"},"finish_reason":"length"}]}"#.utf8)))
    }

    func testErrorClassesKeepTransientFailuresRetryable() {
        let cases: [(Int, String, TranscriptionError)] = [
            (401, "{}", .auth),
            (429, "{}", .rateLimitedTransient),
            (429, #"{"error":{"code":"insufficient_quota"}}"#, .rateLimitedDaily),
            (413, #"{"error":{"message":"too large"}}"#, .badRequest("too large")),
            (503, "{}", .network("http_503")),
        ]
        for (status, json, expected) in cases {
            XCTAssertThrowsError(try OpenAIClient.checkResponse(status: status, data: Data(json.utf8), model: "asr")) {
                XCTAssertEqual($0 as? TranscriptionError, expected)
            }
        }
    }

    func testErrorMessageParsingCoversGateways() {
        XCTAssertEqual(
            OpenAIClient.errorMessage(from: Data(#"{"error":{"message":"Invalid model"}}"#.utf8)),
            "Invalid model"
        )
        XCTAssertEqual(
            OpenAIClient.errorMessage(from: Data(#"{"is_bifrost_error":false,"status_code":400,"error":{"error":"unsupported format","message":"failed to parse request"}}"#.utf8)),
            "failed to parse request: unsupported format"
        )
        XCTAssertEqual(
            OpenAIClient.errorMessage(from: Data(#"{"error":{"error":"same","message":"same"}}"#.utf8)),
            "same"
        )
        XCTAssertEqual(
            OpenAIClient.errorMessage(from: Data(#"{"detail":"FastAPI validation error"}"#.utf8)),
            "FastAPI validation error"
        )
        XCTAssertEqual(
            OpenAIClient.errorMessage(from: Data(#"{"error":"flat error"}"#.utf8)),
            "flat error"
        )
        XCTAssertEqual(
            OpenAIClient.errorMessage(from: Data(#"{"message":"top level"}"#.utf8)),
            "top level"
        )
        XCTAssertEqual(
            OpenAIClient.errorMessage(from: Data("  plain gateway rejection  ".utf8)),
            "plain gateway rejection"
        )
        XCTAssertNil(OpenAIClient.errorMessage(from: Data("{}".utf8)))
        XCTAssertNil(OpenAIClient.errorMessage(from: Data()))
    }

    func testEphemeralConfigurationDisablesPipeliningAndSharedState() {
        let config = OpenAIClient.makeEphemeralConfiguration(timeoutForResource: 180)
        XCTAssertFalse(config.httpShouldUsePipelining)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertFalse(config.waitsForConnectivity)
        XCTAssertEqual(config.timeoutIntervalForResource, 180)
    }

    func testTranscriptionServiceResetConnectionsDoesNotBreakReuse() {
        let service = OpenAITranscriptionService()
        service.resetConnections(forProviderId: "default")
        service.resetConnections()
    }
}
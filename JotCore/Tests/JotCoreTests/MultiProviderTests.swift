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

import XCTest
import AVFoundation
@testable import JotCore

final class MultiProviderTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let testKeys = [
        "apiProviders", "asrProviderId", "llmProviderId", "openAIConfig",
        "smartCleanupPass", "asrModel", "llmModel"
    ]

    override func setUp() {
        super.setUp()
        for key in testKeys { defaults.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in testKeys { defaults.removeObject(forKey: key) }
        KeychainStore.deleteAPIKey(forProviderId: "provider-a")
        KeychainStore.deleteAPIKey(forProviderId: "provider-b")
        KeychainStore.deleteAPIKey(forProviderId: "p1")
        KeychainStore.deleteAPIKey(forProviderId: "p2")
        KeychainStore.deleteAPIKey(forProviderId: "asr-p")
        KeychainStore.deleteAPIKey(forProviderId: "llm-p")
        KeychainStore.deleteAPIKey(forProviderId: "default")
        super.tearDown()
    }

    func testKeychainPerProviderStorage() {
        KeychainStore.saveAPIKey("key-a", forProviderId: "provider-a")
        KeychainStore.saveAPIKey("key-b", forProviderId: "provider-b")

        XCTAssertEqual(KeychainStore.loadAPIKey(forProviderId: "provider-a"), "key-a")
        XCTAssertEqual(KeychainStore.loadAPIKey(forProviderId: "provider-b"), "key-b")
        XCTAssertNil(KeychainStore.loadAPIKey(forProviderId: "nonexistent"))

        KeychainStore.deleteAPIKey(forProviderId: "provider-a")
        XCTAssertNil(KeychainStore.loadAPIKey(forProviderId: "provider-a"))
        XCTAssertEqual(KeychainStore.loadAPIKey(forProviderId: "provider-b"), "key-b")
    }

    func testKeychainDefaultProviderKey() {
        KeychainStore.saveAPIKey("default-key", forProviderId: "default")
        XCTAssertEqual(KeychainStore.loadAPIKey(forProviderId: "default"), "default-key")
        KeychainStore.deleteAPIKey(forProviderId: "default")
    }

    func testAutoMigrationFromLegacyConfig() {
        defaults.set([
            "baseURL": "https://api.siliconflow.cn/v1",
            "asrModel": "FunAudioLLM/SenseVoiceSmall",
            "llmModel": "deepseek-ai/DeepSeek-V3"
        ], forKey: "openAIConfig")

        let settings = SettingsStore()
        let providers = settings.providers

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers.first?.id, "default")
        XCTAssertEqual(providers.first?.name, "Default Provider")
        XCTAssertEqual(providers.first?.baseURL, "https://api.siliconflow.cn/v1")
        XCTAssertEqual(settings.asrProviderId, "default")
        XCTAssertEqual(settings.llmProviderId, "default")
    }

    func testProviderCRUD() {
        // Explicitly initialize with empty list to bypass auto-migration from host environment
        let emptyData = try! JSONEncoder().encode([APIProvider]())
        defaults.set(emptyData, forKey: "apiProviders")
        defaults.removeObject(forKey: "asrProviderId")
        defaults.removeObject(forKey: "llmProviderId")

        let settings = SettingsStore()
        let providerA = APIProvider(id: "p1", name: "Groq", baseURL: "https://api.groq.com/openai/v1", cachedModels: ["whisper-large-v3"])
        let providerB = APIProvider(id: "p2", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", cachedModels: ["deepseek-chat"])

        settings.saveProvider(providerA)
        settings.saveProvider(providerB)

        XCTAssertEqual(settings.providers.count, 2)
        XCTAssertEqual(settings.asrProviderId, "p1")
        XCTAssertEqual(settings.llmProviderId, "p1")

        settings.setLLMProvider(id: "p2", model: "deepseek-chat")
        XCTAssertEqual(settings.llmProviderId, "p2")
        XCTAssertEqual(settings.apiConfig.llmModel, "deepseek-chat")

        settings.deleteProvider(id: "p1")
        XCTAssertEqual(settings.providers.count, 1)
        XCTAssertEqual(settings.asrProviderId, "p2")
    }

    func testMultiProviderResolutionInTranscriptionPipeline() async throws {
        let emptyData = try! JSONEncoder().encode([APIProvider]())
        defaults.set(emptyData, forKey: "apiProviders")

        let settings = SettingsStore()
        let asrProvider = APIProvider(id: "asr-p", name: "ASR Provider", baseURL: "https://api.asr.test/v1")
        let llmProvider = APIProvider(id: "llm-p", name: "LLM Provider", baseURL: "https://api.llm.test/v1")

        settings.saveProvider(asrProvider)
        settings.saveProvider(llmProvider)
        settings.setASRProvider(id: "asr-p", model: "asr-model-1")
        settings.setLLMProvider(id: "llm-p", model: "llm-model-1")
        settings.setSmartCleanupPass(true)

        var requestedHosts: [String] = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: config)

        TestURLProtocol.handler = { request in
            if let host = request.url?.host {
                requestedHosts.append(host)
            }
            if request.url?.path == "/v1/audio/transcriptions" {
                return (200, Data(#"{"text":"Hello world."}"#.utf8))
            }
            if request.url?.path == "/v1/chat/completions" {
                return (200, Data(#"{"choices":[{"message":{"content":"Hello world."}}]}"#.utf8))
            }
            return (404, Data())
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        buffer.int16ChannelData![0].initialize(repeating: 100, count: 1600)
        let cafURL = folder.appendingPathComponent("audio.caf")
        let writer = try CAFWriter(url: cafURL, format: format)
        try writer.write(buffer)
        writer.close()

        let service = OpenAITranscriptionService(
            settings: settings,
            session: session,
            apiKeyForProvider: { id in
                if id == "asr-p" { return "asr-key" }
                if id == "llm-p" { return "llm-key" }
                return nil
            }
        )

        let result = try await service.transcribe(audioURL: cafURL, durationSeconds: 0.1, context: DictationContext())
        XCTAssertEqual(result.rawTranscript, "Hello world.")
        XCTAssertTrue(requestedHosts.contains("api.asr.test"))
        XCTAssertTrue(requestedHosts.contains("api.llm.test"))
    }
}

private final class TestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

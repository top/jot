import Foundation

public enum LLMThinkingControl: String, CaseIterable, Sendable {
    case none
    case chatTemplate
    case enableThinking
    case reasoningEffort
}

public struct OpenAIConfig: Sendable, Equatable {
    public var baseURL: String
    public var asrModel: String
    public var llmModel: String
    public var llmThinkingEnabled: Bool
    public var llmThinkingControl: LLMThinkingControl

    public init(baseURL: String = "", asrModel: String = "", llmModel: String = "",
                llmThinkingEnabled: Bool = false, llmThinkingControl: LLMThinkingControl = .none) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.asrModel = asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.llmModel = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.llmThinkingEnabled = llmThinkingEnabled
        self.llmThinkingControl = llmThinkingControl
    }

    public var endpoint: URL? {
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    public var isConfigured: Bool { endpoint != nil && !asrModel.isEmpty }
}

public actor OpenAIClient {
    private let session: URLSession
    private let apiKey: String

    public init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: configuration)
        }
    }

    public func transcribe(wavData: Data, config: OpenAIConfig, vocabulary: [String], deadline: TimeInterval) async throws -> String {
        let boundary = "Jot-\(UUID().uuidString)"
        let body = Self.transcriptionBody(wavData: wavData, model: config.asrModel, vocabulary: vocabulary, boundary: boundary)
        let data = try await post(path: "audio/transcriptions", body: body,
                                  contentType: "multipart/form-data; boundary=\(boundary)",
                                  config: config, model: config.asrModel, deadline: deadline)
        return try Self.extractTranscript(from: data)
    }

    public func cleanup(prompt: String, config: OpenAIConfig, deadline: TimeInterval) async throws -> String {
        var payload: [String: Any] = [
            "model": config.llmModel,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ]
        switch config.llmThinkingControl {
        case .none:
            break
        case .chatTemplate:
            payload["chat_template_kwargs"] = ["enable_thinking": config.llmThinkingEnabled]
        case .enableThinking:
            payload["enable_thinking"] = config.llmThinkingEnabled
        case .reasoningEffort:
            payload["reasoning_effort"] = config.llmThinkingEnabled ? "medium" : "none"
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await post(path: "chat/completions", body: body, contentType: "application/json",
                                  config: config, model: config.llmModel, deadline: deadline)
        return try Self.extractCompletion(from: data)
    }

    public enum ConnectionCheck: Equatable, Sendable {
        case reachable
        case rejected(String)
        case unreachable
        case unverified
    }

    public func checkConnection(config: OpenAIConfig) async -> ConnectionCheck {
        guard let endpoint = config.endpoint else { return .rejected("Enter a valid Base URL.") }
        var request = URLRequest(url: endpoint.appendingPathComponent("models"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await Self.withDeadline(seconds: 10) { [session, request] in
                try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            switch http.statusCode {
            case 200: return .reachable
            case 400, 401, 403: return .rejected(Self.errorMessage(from: data) ?? "Connection rejected (HTTP \(http.statusCode)).")
            case 500...599: return .unreachable
            default: return .unverified
            }
        } catch { return .unreachable }
    }

    public func fetchModels(config: OpenAIConfig) async throws -> [String] {
        guard let endpoint = config.endpoint else { throw TranscriptionError.badRequest("Enter a valid Base URL.") }
        var request = URLRequest(url: endpoint.appendingPathComponent("models"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.withDeadline(seconds: 10) { [session, request] in
            try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.network("non-http") }
        guard (200...299).contains(http.statusCode) else {
            let message = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw TranscriptionError.badRequest(message)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw TranscriptionError.network("invalid_models_response")
        }
        let ids = dataArray.compactMap { $0["id"] as? String }
        return ids.sorted()
    }

    private func post(path: String, body: Data, contentType: String, config: OpenAIConfig,
                      model: String, deadline: TimeInterval) async throws -> Data {
        guard let endpoint = config.endpoint, !apiKey.isEmpty else { throw TranscriptionError.auth }
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = deadline
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.withDeadline(seconds: deadline) { [session, request] in
                try await session.data(for: request)
            }
        } catch is DeadlineExceeded {
            throw TranscriptionError.timeout
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: throw TranscriptionError.offline
            case .timedOut: throw TranscriptionError.timeout
            default: throw TranscriptionError.network(error.code.rawValue.description)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.network("non-http") }
        try Self.checkResponse(status: http.statusCode, data: data, model: model)
        return data
    }

    static func checkResponse(status: Int, data: Data, model: String) throws {
        let message = errorMessage(from: data) ?? "HTTP \(status)"
        switch status {
        case 200...299: return
        case 401: throw TranscriptionError.auth
        case 403, 404: throw TranscriptionError.modelUnavailable(model: model, detail: message)
        case 429:
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let code = error?["code"] as? String ?? error?["type"] as? String
            if code == "insufficient_quota" || code == "billing_hard_limit_reached" {
                throw TranscriptionError.rateLimitedDaily
            }
            throw TranscriptionError.rateLimitedTransient
        case 400, 405, 413, 415, 422: throw TranscriptionError.badRequest(message)
        default: throw TranscriptionError.network("http_\(status)")
        }
    }

    static func transcriptionBody(wavData: Data, model: String, vocabulary: [String], boundary: String) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", model)
        field("response_format", "json")
        if !vocabulary.isEmpty { field("prompt", vocabulary.joined(separator: ", ")) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    static func extractTranscript(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { throw TranscriptionError.network("invalid_transcription_response") }
        return text
    }

    static func extractCompletion(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String else { throw TranscriptionError.network("invalid_completion_response") }
        guard first["finish_reason"] as? String != "length" else { throw TranscriptionError.network("truncated_completion") }
        return text
    }

    static func errorMessage(from data: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (object?["error"] as? [String: Any])?["message"] as? String
    }

    struct DeadlineExceeded: Error {}

    static func withDeadline<Value: Sendable>(seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DeadlineExceeded()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    deinit { session.invalidateAndCancel() }
}
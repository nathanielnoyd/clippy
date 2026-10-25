import Foundation

struct ChatMessage: Codable {
    var role: String // "system", "user" or "assistant"
    var content: String
}

/// Anything that can answer the user: a local model server, Claude, OpenAI, Apple's on-device model…
protocol AssistantProvider {
    /// Yields the reply in pieces as they arrive.
    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

/// Offline stand-in. Stays in character.
struct SatireProvider: AssistantProvider {
    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.last?.content ?? ""
        return AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                let lines = [
                    "It looks like you're trying to \"\(prompt)\". Would you like me to make that harder?",
                    "Great question! I've helpfully forgotten it. Have you tried saving your work?",
                    "I'm not connected to a brain yet. Pick a model server in Assistant Settings!",
                    "It looks like you're asking a paperclip for advice. Bold move.",
                ]
                continuation.yield(lines.randomElement()!)
                continuation.finish()
            }
        }
    }
}

enum AssistantError: LocalizedError {
    case badURL(String)
    case http(Int, String)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .badURL(let url): return "“\(url)” isn't a valid server address."
        case .http(let code, let body): return "The server answered \(code). \(body)"
        case .emptyReply: return "The server sent back an empty reply."
        }
    }
}

/// Talks to any server with an OpenAI-style `/chat/completions` endpoint: Ollama,
/// LM Studio, llama.cpp, vLLM, LocalAI, Jan… on this Mac or elsewhere on your network.
struct OpenAICompatibleProvider: AssistantProvider {
    var baseURL: URL
    var model: String
    var apiKey: String?

    /// Accepts "http://192.168.1.20:11434", "192.168.1.20:11434" or a full ".../v1" URL.
    /// A bare host gets "/v1" appended, since that's where these servers live.
    static func normalize(_ text: String) throws -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var components = URLComponents(string: trimmed), components.host?.isEmpty == false else {
            throw AssistantError.badURL(text)
        }
        if components.path.isEmpty { components.path = "/v1" }
        guard let url = components.url else { throw AssistantError.badURL(text) }
        return url
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 300 // local models can take a while to load
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Model ids the server offers, for the settings picker.
    func listModels() async throws -> [String] {
        var request = request("models")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, body: data)
        struct Models: Decodable {
            struct Model: Decodable { var id: String }
            var data: [Model]
        }
        return try JSONDecoder().decode(Models.self, from: data).data.map(\.id).sorted()
    }

    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        struct Body: Encodable {
            var model: String
            var messages: [ChatMessage]
            var stream = true
        }
        var request = request("chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Body(model: model, messages: messages))

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        try Self.check(response, body: body)
                    }

                    // Server-sent events: "data: {json}" lines ending with "data: [DONE]".
                    // Some servers ignore stream=true and send one JSON object instead.
                    var plain = ""
                    var sawEvent = false
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else {
                            plain += line
                            continue
                        }
                        sawEvent = true
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)),
                           let text = chunk.choices.first?.delta?.content, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    if !sawEvent {
                        guard let full = try? JSONDecoder().decode(Completion.self, from: Data(plain.utf8)),
                              let text = full.choices.first?.message.content else { throw AssistantError.emptyReply }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta?
        }
        var choices: [Choice]
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        var choices: [Choice]
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        // OpenAI-style servers put the reason in {"error": {"message": ...}} or {"error": "..."}.
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
            ?? json?["error"] as? String
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        throw AssistantError.http(http.statusCode, message)
    }
}

/// Removes quotation marks wrapped around an entire reply, which small models sometimes add.
func trimmingWrappingQuotes(_ text: String) -> String {
    let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”")]
    for (open, close) in pairs where text.count > 2 && text.first == open && text.last == close {
        let inner = text.dropFirst().dropLast()
        if !inner.contains(open) && !inner.contains(close) { return String(inner) }
    }
    return text
}

/// Hides `<think>…</think>` reasoning that some local models (Qwen, DeepSeek-R1…) put in their replies.
func strippingThinking(_ text: String) -> String {
    text.replacingOccurrences(of: #"<think>[\s\S]*?(</think>|$)"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

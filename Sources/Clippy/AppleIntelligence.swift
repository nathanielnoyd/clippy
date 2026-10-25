import Foundation
import FoundationModels

/// Apple's on-device model (the one behind Apple Intelligence): free, private, offline.
@available(macOS 26, *)
final class AppleIntelligenceProvider: AssistantProvider {
    private var session: LanguageModelSession?

    /// nil when ready; otherwise a sentence explaining why it can't be used.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model. Try again in a bit."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let instructions = messages.first { $0.role == "system" }?.content
        let conversation = messages.filter { $0.role != "system" }
        let prompt = conversation.last?.content ?? ""

        // The session keeps its own transcript, so only the newest question is sent.
        // A fresh conversation (one message) starts a fresh session.
        if session == nil || conversation.count <= 1 {
            session = LanguageModelSession(instructions: instructions)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = Self.unavailableReason { throw AppleIntelligenceError(reason) }
                    try await self.respond(to: prompt, into: continuation)
                } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                    // The on-device context is small; start over, keeping the question.
                    self.session = LanguageModelSession(instructions: instructions)
                    do {
                        try await self.respond(to: prompt, into: continuation)
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams snapshots (each is the whole reply so far) as incremental pieces.
    private func respond(to prompt: String, into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let session else { return }
        var sent = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            let text = snapshot.content
            if text.hasPrefix(sent) {
                continuation.yield(String(text.dropFirst(sent.count)))
            } else {
                continuation.yield(text) // the model revised earlier text; rare
            }
            sent = text
        }
        continuation.finish()
    }
}

struct AppleIntelligenceError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

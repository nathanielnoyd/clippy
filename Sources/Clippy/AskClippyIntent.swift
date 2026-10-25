import AppIntents

/// "Hey Siri, ask Clippy" — also available as an action in Shortcuts and Spotlight.
/// Clippy answers in its balloon, and Siri reads the answer back.
struct AskClippyIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Clippy"
    static let description = IntentDescription("Ask Clippy a question. Clippy answers in its balloon and returns the answer as text.")

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask Clippy?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let controller = try await ClippyBridge.controller()
        let answer = await controller.answerFromSiri(question)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// "Hey Siri, show Clippy" — brings Clippy back after it was hidden.
struct ShowClippyIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Clippy"
    static let description = IntentDescription("Brings Clippy back to your desktop after hiding.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try await ClippyBridge.controller()
        controller.reappear()
        return .result(dialog: "It looks like you missed me!")
    }
}

/// "Hey Siri, set a Clippy timer" — Clippy pops up when it's done.
struct SetTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set a Clippy Timer"
    static let description = IntentDescription("Starts a countdown. Clippy pops up when time's up.")

    @Parameter(title: "Minutes", inclusiveRange: (1, 1440), requestValueDialog: "For how many minutes?")
    var minutes: Int

    @Parameter(title: "Label", description: "What the timer is for, like “tea”.")
    var label: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try await ClippyBridge.controller()
        let answer = controller.handle(.start(seconds: TimeInterval(minutes) * 60, label: label))
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

/// "Hey Siri, start a Pomodoro with Clippy"
struct StartPomodoroIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Pomodoro"
    static let description = IntentDescription("Four 25-minute focus sessions with breaks between them. Clippy tells you when each one ends.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try await ClippyBridge.controller()
        return .result(dialog: IntentDialog(stringLiteral: controller.handle(.pomodoro)))
    }
}

/// "Hey Siri, stop the Clippy timer"
struct CancelTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Clippy's Timer"
    static let description = IntentDescription("Cancels the running timer or Pomodoro.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try await ClippyBridge.controller()
        return .result(dialog: IntentDialog(stringLiteral: controller.handle(.cancel)))
    }
}

struct ClippyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskClippyIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Ask Clippy",
            systemImageName: "paperclip"
        )
        AppShortcut(
            intent: ShowClippyIntent(),
            phrases: [
                "Show \(.applicationName)",
                "Bring back \(.applicationName)",
            ],
            shortTitle: "Show Clippy",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: SetTimerIntent(),
            phrases: [
                "Set a \(.applicationName) timer",
                "Start a \(.applicationName) timer",
            ],
            shortTitle: "Set a Timer",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: StartPomodoroIntent(),
            phrases: [
                "Start a Pomodoro with \(.applicationName)",
                "Start a \(.applicationName) Pomodoro",
            ],
            shortTitle: "Start a Pomodoro",
            systemImageName: "leaf"
        )
        AppShortcut(
            intent: CancelTimerIntent(),
            phrases: [
                "Stop the \(.applicationName) timer",
                "Cancel the \(.applicationName) timer",
            ],
            shortTitle: "Stop Timer",
            systemImageName: "stop.circle"
        )
    }
}

/// Lets intents reach the running character. Siri can launch Clippy just to run an
/// intent, so this waits briefly for the app to finish starting up.
@MainActor
enum ClippyBridge {
    static weak var current: CharacterController?

    static func controller() async throws -> CharacterController {
        for _ in 0..<50 {
            if let current { return current }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AppleIntelligenceError("Clippy is still starting up. Try again in a moment.")
    }
}

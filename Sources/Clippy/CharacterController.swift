import AppKit
import SwiftUI

/// Owns the character window, its animations, idle behavior, and the speech bubble.
final class CharacterController {
    private(set) var pack: CharacterPack
    private var player: AnimationPlayer!
    private let panel: FloatingPanel
    private let view: CharacterView
    private var bubblePanel: FloatingPanel?
    private let bubble = BubbleModel()
    private var idleTimer: Timer?
    private var busy = false

    /// Hidden from the desktop, still in the menu bar.
    private(set) var isHidden = false
    /// When a hidden Clippy comes back on its own (`nil`: when called).
    private(set) var returnDate: Date?
    private var returnTimer: Timer?
    /// Called after hiding or reappearing, so the menu and saved state can follow.
    var onVisibilityChange: (() -> Void)?

    /// A countdown or Pomodoro cycle; Clippy speaks up when each part ends.
    let timer = ClippyTimer()

    var assistant = AssistantSettings() {
        didSet {
            provider = (try? assistant.makeProvider()) ?? SatireProvider()
            history = []
        }
    }
    private var provider: AssistantProvider = SatireProvider()
    private var history: [ChatMessage] = []
    private var thread = UUID() // changes on "New chat", so late replies are ignored

    /// Display size relative to the pack's own size (1, 1.5 or 2).
    var sizeMultiplier: CGFloat = 1 {
        didSet { applySize() }
    }

    var soundsEnabled = true
    private var sounds: [URL: NSSound] = [:]

    private var displaySize: CGSize {
        CGSize(width: pack.pointSize.width * sizeMultiplier, height: pack.pointSize.height * sizeMultiplier)
    }

    init(pack: CharacterPack) {
        self.pack = pack
        panel = FloatingPanel(size: pack.pointSize)
        view = CharacterView(frame: NSRect(origin: .zero, size: pack.pointSize))
        panel.contentView = view

        view.onClick = { [weak self] in self?.toggleBubble() }
        view.onMove = { [weak self] in self?.positionBubble() }
        bubble.onSubmit = { [weak self] text in self?.ask(text) }
        bubble.onClose = { [weak self] in self?.hideBubble() }
        bubble.onNewChat = { [weak self] in self?.newChat() }
        timer.onFinish = { [weak self] message in self?.timerFinished(message) }

        // Timers don't count time asleep, so check the return time again on wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.scheduleReturn()
        }

        attach(pack)
    }

    /// Items for the character's right-click menu.
    var contextMenu: (() -> NSMenu?)? {
        get { view.contextMenu }
        set { view.contextMenu = newValue }
    }

    func show() {
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - displaySize.width - 40, y: screen.minY + 40))
        }
        applySize()
        guard !isHidden else { return } // restored hidden at launch
        panel.orderFrontRegardless()
        playThenRest("Greeting")
        scheduleIdle()
    }

    // MARK: - Hiding

    /// Leaves the desktop until `date`, or until called back when it's `nil`.
    func hide(until date: Date? = nil, animated: Bool = true) {
        returnDate = date
        defer {
            scheduleReturn()
            onVisibilityChange?()
        }
        guard !isHidden else { return } // already away; just a new return time
        isHidden = true
        idleTimer?.invalidate()
        hideBubble()
        let name = ["Hide", "GoodBye"].first(where: player.has)
        guard animated, let name else { return panel.orderOut(nil) }
        player.play(name) { [weak self] in
            guard let self, self.isHidden else { return } // called back mid-exit
            self.panel.orderOut(nil)
            self.rest()
        }
    }

    /// Brings Clippy back to where it was.
    func reappear() {
        returnTimer?.invalidate()
        returnDate = nil
        guard isHidden else { return }
        isHidden = false
        panel.orderFrontRegardless()
        playThenRest(player.has("Show") ? "Show" : "Greeting")
        scheduleIdle()
        onVisibilityChange?()
    }

    private func scheduleReturn() {
        returnTimer?.invalidate()
        guard isHidden, let returnDate else { return }
        let wait = returnDate.timeIntervalSinceNow
        guard wait > 0 else { return reappear() }
        returnTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            self?.reappear()
        }
    }

    func swap(to newPack: CharacterPack) {
        player.stop()
        pack = newPack
        sounds = [:]
        applySize()
        attach(newPack)
        playThenRest("Greeting")
    }

    /// Resizes around the character's bottom-center so it doesn't jump when scaled.
    private func applySize() {
        let size = displaySize
        let old = panel.frame
        let frame = NSRect(x: old.midX - size.width / 2, y: old.minY, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        view.frame = NSRect(origin: .zero, size: size)
        // Whole-number scales stay pixel-crisp; 1.5× would look lumpy, so smooth it instead.
        view.layer?.magnificationFilter = sizeMultiplier.rounded() == sizeMultiplier ? .nearest : .trilinear
        positionBubble()
    }

    private func playSound(_ url: URL) {
        guard soundsEnabled else { return }
        if sounds[url] == nil { sounds[url] = NSSound(contentsOf: url, byReference: true) }
        guard let sound = sounds[url] else { return }
        sound.stop()
        sound.play()
    }

    func play(_ name: String) {
        playThenRest(name)
    }

    // MARK: - Animation

    private func attach(_ pack: CharacterPack) {
        player = AnimationPlayer(pack: pack) { [weak self] image in self?.view.show(image) }
        player.onSound = { [weak self] url in self?.playSound(url) }
        rest()
    }

    private func rest() {
        if player.has("RestPose") {
            player.play("RestPose")
        } else if let first = pack.animationNames.first {
            player.play(first) // show *something* for packs without a RestPose
        }
    }

    private func playThenRest(_ name: String) {
        guard player.has(name) else { return rest() }
        player.play(name) { [weak self] in self?.rest() }
    }

    private func scheduleIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 6...14), repeats: false) { [weak self] _ in
            guard let self else { return }
            if !self.busy {
                let idles = self.pack.animationNames.filter { $0.lowercased().hasPrefix("idle") }
                if let pick = idles.randomElement() { self.playThenRest(pick) }
            }
            self.scheduleIdle()
        }
    }

    // MARK: - Speech bubble

    private func toggleBubble() {
        if bubblePanel?.isVisible == true { hideBubble() } else { showBubble() }
    }

    /// `focus: false` shows the balloon without taking the keyboard (e.g. for Siri).
    private func showBubble(focus: Bool = true) {
        if bubblePanel?.isVisible != true { bubble.regreet() }
        if bubblePanel == nil {
            let host = NSHostingView(rootView: SpeechBubble(model: bubble))
            host.frame.size = host.fittingSize
            let p = FloatingPanel(size: host.fittingSize)
            p.title = "Clippy Balloon" // not shown; names the window for accessibility
            p.appearance = NSAppearance(named: .aqua) // the balloon is always pale yellow, so keep its controls light

            p.contentView = host
            bubblePanel = p
        }
        positionBubble()
        if focus {
            bubblePanel?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            playThenRest("GetAttention")
        } else {
            bubblePanel?.orderFrontRegardless()
        }
    }

    private func hideBubble() {
        bubblePanel?.orderOut(nil)
    }

    private func positionBubble() {
        guard let bubblePanel, let host = bubblePanel.contentView else { return }
        let size = host.fittingSize
        let c = panel.frame
        // Tail sits ~55pt from the bubble's right edge; aim it at the character's center.
        let origin = NSPoint(x: c.midX - size.width + 55, y: c.maxY - 6)
        bubblePanel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func ask(_ text: String) {
        Task { @MainActor in await respond(to: text) }
    }

    /// Answers a question the same way the balloon does and returns the final text.
    /// Used by "Ask Clippy" from Siri and Shortcuts.
    @MainActor
    func answerFromSiri(_ question: String) async -> String {
        reappear()
        if bubblePanel?.isVisible != true { showBubble(focus: false) }
        return await respond(to: question)
    }

    /// Opens the balloon with a sample conversation, for checking the layout (`--demo-chat`).
    func showDemoChat(thinking: Bool, long: Bool = false) {
        if long {
            for i in 1...6 {
                bubble.append(.user, "Question number \(i)?")
                bubble.append(.clippy, String(repeating: "This is a fairly long answer that keeps going. ", count: 4))
            }
        }
        bubble.append(.user, "What's the capital of Australia?")
        bubble.append(.clippy, "It looks like you're planning a trip! The capital of Australia is Canberra, not Sydney. A common mix-up!")
        bubble.append(.user, "Thanks. Any tips for visiting?")
        if thinking { bubble.isThinking = true } else {
            bubble.append(.error, "Couldn't connect to the server.")
        }
        showBubble(focus: false)
    }

    /// Clears the thread and the model's memory. A reply still streaming is dropped.
    private func newChat() {
        thread = UUID()
        history = []
        provider = (try? assistant.makeProvider()) ?? SatireProvider() // fresh model session
        bubble.reset()
        busy = false
        rest()
        positionBubble()
    }

    @MainActor
    @discardableResult
    private func respond(to text: String) async -> String {
        bubble.append(.user, text)
        positionBubble()
        if let request = HideRequest.parse(text) { return await leave(request) }
        if let request = TimerRequest.parse(text) { return answer(handle(request)) }
        switch assistant.destination {
        case .balloon: return await answerInBalloon(text)
        case .shortcut: return await runShortcut(text)
        }
    }

    @MainActor
    private func runShortcut(_ prompt: String) async -> String {
        let thread = self.thread
        busy = true
        bubble.isThinking = true
        if player.has("Processing") { player.play("Processing") } else if player.has("Thinking") { player.play("Thinking") }
        let answer: String
        do {
            let output = try await ShortcutRunner.run(assistant.shortcutName, input: prompt)
            answer = output.isEmpty ? "Done! “\(assistant.shortcutName)” ran." : output
            guard thread == self.thread else { return answer }
            bubble.append(.clippy, answer)
            playThenRest("Explain")
        } catch {
            answer = "The shortcut “\(assistant.shortcutName)” didn't work: \(error.localizedDescription)"
            guard thread == self.thread else { return answer }
            bubble.append(.error, answer)
            playThenRest("GetAttention")
        }
        finishReply()
        return answer
    }

    @MainActor
    private func answerInBalloon(_ text: String) async -> String {
        let thread = self.thread
        busy = true
        bubble.isThinking = true
        if player.has("Thinking") { player.play("Thinking") }
        history.append(ChatMessage(role: "user", content: text))
        let messages = [ChatMessage(role: "system", content: Self.personality)] + history.suffix(20)

        var reply = ""
        do {
            for try await piece in provider.stream(messages) {
                guard thread == self.thread else { return strippingThinking(reply) }
                reply += piece
                let visible = strippingThinking(reply)
                if bubble.isThinking {
                    guard !visible.isEmpty else { continue } // still inside <think>…</think>
                    bubble.isThinking = false
                    bubble.append(.clippy, visible)
                    playThenRest(player.has("Writing") ? "Writing" : "Explain")
                } else {
                    bubble.updateLast(visible)
                }
                positionBubble()
            }
            guard thread == self.thread else { return strippingThinking(reply) }
            let answer = trimmingWrappingQuotes(strippingThinking(reply))
            if answer.isEmpty { throw AssistantError.emptyReply }
            bubble.updateLast(answer)
            history.append(ChatMessage(role: "assistant", content: answer))
            playThenRest("Explain")
            finishReply()
            return answer
        } catch {
            guard thread == self.thread else { return "" }
            history.removeLast() // drop the unanswered question
            let message = error.localizedDescription
            if bubble.isThinking || reply.isEmpty {
                bubble.append(.error, message)
            } else {
                bubble.append(.error, "The reply was cut off: \(message)")
            }
            playThenRest("GetAttention")
            finishReply()
            return message
        }
    }

    /// Answers "go away for an hour" and friends, then hides.
    @MainActor
    private func leave(_ request: HideRequest) async -> String {
        let answer = request.until.map { "Okay! I'll be back \(describeReturn($0))." }
            ?? "Okay! Click 📎 in the menu bar when you need me."
        bubble.append(.clippy, answer)
        positionBubble()
        playThenRest("Wave")
        let thread = self.thread
        try? await Task.sleep(for: .seconds(2)) // time to read the goodbye
        if thread == self.thread { hide(until: request.until) }
        return answer
    }

    /// Puts a reply that needs no brain (timers) in the balloon.
    @MainActor
    private func answer(_ text: String) -> String {
        bubble.append(.clippy, text)
        positionBubble()
        playThenRest("Explain")
        return text
    }

    private func finishReply() {
        bubble.isThinking = false
        busy = false
        positionBubble()
    }

    // MARK: - Timers

    /// Starts, stops or reports on a timer, and says what happened.
    func handle(_ request: TimerRequest) -> String {
        let replacing = timer.isRunning ? " That replaces your other timer." : ""
        switch request {
        case .start(let seconds, let label):
            timer.start(seconds: seconds, label: label)
            let what = label.map { " for “\($0)”" } ?? ""
            return "Timer set\(what): \(ClippyTimer.describe(seconds)). I'll let you know!" + replacing
        case .pomodoro:
            timer.startPomodoro()
            return "Pomodoro started! \(ClippyTimer.describe(ClippyTimer.focusLength)) of focus, "
                + "then a \(ClippyTimer.adjective(ClippyTimer.shortBreakLength)) break. I'll keep quiet until then." + replacing
        case .cancel:
            guard timer.isRunning else { return "There's no timer running." }
            timer.cancel()
            return "Timer cancelled."
        case .skip:
            guard timer.isPomodoro else { return "There's no Pomodoro running." }
            timer.skip()
            return "Skipped! \(timer.title ?? "Next up"): \(ClippyTimer.describe(timer.remaining))."
        case .status:
            guard timer.isRunning, let title = timer.title else { return "There's no timer running." }
            return "\(title): \(ClippyTimer.describe(timer.remaining)) left."
        }
    }

    /// Comes out of hiding if needed and announces the end of a timer or Pomodoro phase.
    private func timerFinished(_ message: String) {
        reappear()
        if bubblePanel?.isVisible != true { showBubble(focus: false) }
        bubble.append(.clippy, message)
        positionBubble()
        playThenRest(["Alert", "GetAttention"].first(where: player.has) ?? "Explain")
        if soundsEnabled { NSSound(named: "Glass")?.play() }
    }

    private static let personality = """
        You are Clippy, the eager, cheerful paperclip assistant from classic Microsoft Office, \
        now living on a Mac. You're upbeat and a little self-aware about your reputation, \
        but you give genuinely useful, correct answers. Your old catchphrase ("It looks like \
        you're trying to…") is a rare treat, not a habit: most replies shouldn't use it, \
        and never use it twice in one conversation. Just answer the question. \
        Timers and Pomodoros are handled before messages reach you, so if someone asks you to \
        set one, it wasn't understood: suggest phrasing like "set a timer for 10 minutes" or \
        "start a pomodoro". Your replies appear in a small speech balloon, so keep them short: a few sentences, \
        plain text, no Markdown headings or tables.
        """
}

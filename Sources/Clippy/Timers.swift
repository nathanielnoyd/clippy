import Foundation

/// Recognizes chat messages about timers: "set a timer for 10 minutes", "remind me in 20 minutes
/// to stretch", "start a pomodoro", "cancel the timer", "how much time is left?"…
/// Anything else goes to the brain as usual.
enum TimerRequest: Equatable {
    case start(seconds: TimeInterval, label: String?)
    case pomodoro
    case cancel
    case skip
    case status

    private static let lead = HideRequest.lead + #"(?:(?:i want to|i'd like to|let's|lets)\s+)?"#
    private static let article = #"(?:(?:a|an|the|my|this|that|another|new)\s+)?"#
    private static let pomodoroWord = #"(?:pomodoro|pomodoros|tomato timer|focus session)"#

    static func parse(_ message: String) -> TimerRequest? {
        let text = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        guard let start = text.range(of: lead, options: .regularExpression) else { return nil }
        let rest = String(text[start.upperBound...])
        func matches(_ pattern: String) -> Bool { rest.range(of: pattern, options: .regularExpression) != nil }
        let end = #"\s*[.!?]*$"#

        if matches(#"^(?:cancel|stop|end|kill|clear|reset|turn off|forget)\s+"# + article
                   + #"(?:timer|countdown|reminder|\#(pomodoroWord))s?\#(end)"#) {
            return .cancel
        }
        if matches(#"^skip\s+"# + article + #"(?:break|focus session|session|round|timer)\#(end)"#) {
            return .skip
        }
        if matches(#"^(?:how (?:much time|long)(?: is| do i have)?(?: left| remaining)|time left|"#
                   + #"check\s+"# + article + #"timer|how's\s+"# + article + #"timer)"#
                   + #"(?:\s+on\s+"# + article + #"(?:timer|\#(pomodoroWord)|break))?\#(end)"#) {
            return .status
        }
        if matches(#"^(?:(?:start|begin|do|run|set|set up|kick off)\s+)?"# + article + pomodoroWord
                   + #"(?:\s+(?:timer|session|now|please))*\#(end)"#) {
            return .pomodoro
        }

        // "set a timer for 10 minutes", "a 10 minute timer", "timer 5 min", "remind me in an hour to…"
        let amount = #"(?:\d|half|one|two|three|four|five|ten|fifteen|twenty|thirty|forty-five|a few|a couple)"#
        let isTimer = matches(#"^(?:set|start|make|create|run|put on|give me)\s+"# + article
                              + #"(?:[\w.-]+[\s-]+){0,3}timer\b"#)
            || matches("^" + article + amount + #"[\w.\s-]{0,24}?\btimer\b"#)
            || matches(#"^timer\b"#)
        let isReminder = matches(#"^remind me\b"#)
        guard isTimer || isReminder, let (seconds, span) = duration(in: rest), seconds > 0 else { return nil }
        return .start(seconds: seconds, label: label(in: rest, around: span))
    }

    /// Hide's units plus seconds, which only make sense for timers.
    private static let units = HideRequest.units.merging([
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
    ]) { a, _ in a }

    /// Adds up every amount in the text: "1 hour and 30 minutes" is 90 minutes.
    static func duration(in text: String) -> (TimeInterval, Range<String.Index>)? {
        let number = #"(\d+(?:\.\d+)?|"# + HideRequest.numbers.keys.sorted { $0.count > $1.count }
            .joined(separator: "|") + ")"
        let unit = "(" + units.keys.sorted { $0.count > $1.count }.joined(separator: "|") + ")"
        let regex = try! Regex(#"\b"# + number + #"[\s-]*"# + unit + #"\b"#)
        var total: TimeInterval = 0
        var span: Range<String.Index>?
        for match in text.matches(of: regex) {
            guard let amount = match.output[1].substring.flatMap({ Double($0) ?? HideRequest.numbers[String($0)] }),
                  let seconds = match.output[2].substring.flatMap({ units[String($0)] }) else { continue }
            total += amount * seconds
            span = (span?.lowerBound ?? match.range.lowerBound)..<match.range.upperBound
        }
        return span.map { (total, $0) }
    }

    /// "…for 10 minutes to check the oven" or "remind me to stretch in 20 minutes".
    private static func label(in text: String, around span: Range<String.Index>) -> String? {
        let after = String(text[span.upperBound...])
        let before = String(text[..<span.lowerBound])
        let found = after.firstMatch(of: #/^\s*(?:,\s*)?(?:to|for|so i can|so that i|called|named)\s+(.+)/#)?.output.1
            ?? before.firstMatch(of: #/^remind me\s+(?:to\s+)?(.+?)\s+(?:in|after)\s*$/#)?.output.1
        let label = found.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,")) }
        return label?.isEmpty == false ? label : nil
    }
}

/// One countdown at a time: a plain timer, or a Pomodoro cycle of four focus sessions
/// with short breaks between them and a long break at the end.
final class ClippyTimer {
    enum Phase: Equatable {
        case countdown(label: String?)
        case focus(round: Int)
        case shortBreak(round: Int) // after focus round `round`
        case longBreak
    }

    static let focusLength: TimeInterval = 25 * 60
    static let shortBreakLength: TimeInterval = 5 * 60
    static let longBreakLength: TimeInterval = 15 * 60
    static let rounds = 4

    private(set) var phase: Phase?
    private(set) var endDate: Date?
    private var ticker: Timer?

    /// Every second while running, for the menu bar countdown.
    var onTick: (() -> Void)?
    /// When a phase finishes, with what Clippy should say. The next phase has already started.
    var onFinish: ((String) -> Void)?
    /// When a timer starts or stops.
    var onChange: (() -> Void)?

    var isRunning: Bool { phase != nil }
    var isPomodoro: Bool {
        if case .countdown = phase { return false }
        return phase != nil
    }

    var remaining: TimeInterval { max(0, endDate?.timeIntervalSinceNow ?? 0) }

    func start(seconds: TimeInterval, label: String?) {
        begin(.countdown(label: label), length: seconds)
    }

    func startPomodoro() {
        begin(.focus(round: 1), length: Self.focusLength)
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        phase = nil
        endDate = nil
        onChange?()
    }

    /// Ends the current Pomodoro phase early and moves on to the next.
    func skip() {
        guard isPomodoro else { return }
        advance(announce: false)
    }

    private func begin(_ phase: Phase, length: TimeInterval) {
        self.phase = phase
        endDate = .now.addingTimeInterval(length)
        if ticker == nil {
            // Checks the clock rather than counting down, so time asleep still counts.
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common) // keeps ticking while a menu is open
            ticker = t
        }
        onChange?()
        onTick?()
    }

    private func tick() {
        guard let endDate else { return }
        if endDate <= .now { advance(announce: true) } else { onTick?() }
    }

    private func advance(announce: Bool) {
        guard let phase else { return }
        let message: String
        switch phase {
        case .countdown(let label):
            message = label.map { "Time's up: \($0)!" } ?? "Time's up!"
            cancel()
        case .focus(let round) where round < Self.rounds:
            message = "Nice focus! Take a \(Self.adjective(Self.shortBreakLength)) break. (\(round) of \(Self.rounds) done)"
            begin(.shortBreak(round: round), length: Self.shortBreakLength)
        case .focus:
            message = "That's all \(Self.rounds)! Take a long \(Self.adjective(Self.longBreakLength)) break. You earned it."
            begin(.longBreak, length: Self.longBreakLength)
        case .shortBreak(let round):
            message = "Break's over. Focus session \(round + 1) of \(Self.rounds): go!"
            begin(.focus(round: round + 1), length: Self.focusLength)
        case .longBreak:
            message = "Long break's over. Say \"start a pomodoro\" when you're ready for another round."
            cancel()
        }
        if announce { onFinish?(message) }
    }

    /// "Focus 2 of 4", "Short break", "Tea"
    var title: String? {
        switch phase {
        case .countdown(let label): label.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Timer"
        case .focus(let round): "Focus \(round) of \(Self.rounds)"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        case nil: nil
        }
    }

    /// "24:59", or "1:02:03" past an hour.
    var clock: String {
        let total = Int(remaining.rounded(.up))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "5-minute", as in "a 5-minute break"
    static func adjective(_ seconds: TimeInterval) -> String {
        "\(Int(seconds / 60))-minute"
    }

    /// "10 minutes", "1 hour, 30 minutes"
    static func describe(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

import Foundation

/// Recognizes chat messages asking Clippy to leave: "go away", "hide for 20 minutes",
/// "come back at 3pm", "see you tomorrow"… Anything else goes to the brain as usual.
struct HideRequest: Equatable {
    /// When Clippy should reappear. `nil` means "until I call you".
    var until: Date?

    /// Phrases that send Clippy away. A time after them is optional.
    private static let leave = #"hide|go away|go hide|disappear|vanish|scram|shoo|get lost|leave me alone|"#
        + #"take a (?:break|nap|hike)|go to sleep|bye|goodbye|good bye|see (?:you|ya)"#
    /// Phrases that only make sense with a time ("come back at 3").
    private static let comeBack = #"come back|be back|reappear|return|show up"#
    /// Small talk allowed in front: "Clippy, could you please…"
    static let lead = #"^(?:(?:hey|ok|okay|alright|so|now)[, ]+)?(?:clippy[,!.]?\s*)?"#
        + #"(?:(?:please|can you|could you|would you|will you|why don'?t you|just)\s+)*"#
    /// What may follow the phrase, so "hide the Dock" or "return a value" aren't taken as orders.
    private static let filler = #"yourself|clippy|please|now|for now|for a (?:bit|while)|then|already|later"#
    private static let timeWord = #"for|until|till|til|in|at|by|tomorrow|tonight|on|after|this|next"#

    static func parse(_ message: String, now: Date = .now) -> HideRequest? {
        let text = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        guard let start = text.range(of: lead, options: .regularExpression) else { return nil }
        let rest = String(text[start.upperBound...])

        for (phrases, needsTime) in [(leave, false), (comeBack, true)] {
            guard let verb = rest.range(of: "^(?:\(phrases))\\b", options: .regularExpression) else { continue }
            let tail = String(rest[verb.upperBound...])
            // The phrase must be followed by filler or a time: "for an hour", not "the Dock".
            let words = #"(?:[\s,.!?]|\b(?:"# + filler + "|" + timeWord + #")\b)"#
            guard tail.range(of: "^\\s*(?:$|[,.!?]|\\b(?:\(filler)|\(timeWord))\\b)",
                             options: .regularExpression) != nil else { return nil }
            let time = date(in: tail, now: now)
            if time == nil {
                // Without a time, nothing else may follow ("go away now", "bye!").
                guard tail.range(of: "^\(words)*$", options: .regularExpression) != nil else { return nil }
            }
            if needsTime && time == nil { return nil }
            return HideRequest(until: time)
        }
        return nil
    }

    // MARK: - Times

    static let units: [String: TimeInterval] = [
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600,
        "day": 86400, "days": 86400,
    ]
    static let numbers: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "a couple of": 2, "a couple": 2, "a few": 3, "two": 2, "three": 3,
        "four": 4, "five": 5, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty-five": 45,
        "half an": 0.5, "half a": 0.5,
    ]
    private static let dayWords = #"\b(?:tomorrow|tonight|morning|afternoon|evening|noon|midnight|next|"#
        + #"monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun)\b"#

    /// Finds when Clippy should come back: "for 20 minutes", "in an hour", "at 3pm",
    /// "until 5:30", "tomorrow", "Monday at 9"…
    static func date(in text: String, now: Date = .now) -> Date? {
        let text = text.lowercased()

        // "for 20 minutes", "in an hour", "half an hour", "a couple of hours"
        let number = #"(\d+(?:\.\d+)?|"# + numbers.keys.sorted { $0.count > $1.count }.joined(separator: "|") + ")"
        let unit = "(" + units.keys.sorted { $0.count > $1.count }.joined(separator: "|") + ")"
        if let match = text.firstMatch(of: try! Regex(#"\b"# + number + #"\s*"# + unit + #"\b"#)),
           let amount = match.output[1].substring.flatMap({ Double($0) ?? numbers[String($0)] }),
           let seconds = match.output[2].substring.flatMap({ units[String($0)] }) {
            return now.addingTimeInterval(amount * seconds)
        }

        // NSDataDetector reads "until 5:30" as the end of a range (4:30), so say "at".
        let normalized = text.replacingOccurrences(of: #"\b(?:until|till|til|by)\b"#, with: "at",
                                                   options: .regularExpression)
        let hasDay = normalized.range(of: dayWords, options: .regularExpression) != nil

        // A bare clock time ("at 3", "at 2:15", "at 10am"): the next time the clock says so.
        if !hasDay, let match = normalized.firstMatch(of: #/\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?/#),
           let hour = Int(match.output.1), hour <= 23 {
            let minute = match.output.2.flatMap { Int($0) } ?? 0
            let meridiem = match.output.3.map { $0.hasPrefix("p") ? "pm" : "am" }
            return nextTime(hour: hour, minute: minute, meridiem: meridiem, after: now)
        }

        // Only trust the detector with a day or a number to go on, so "now" stays now.
        guard hasDay || normalized.contains(where: \.isNumber),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              var date = match.date else { return nil }
        // "tomorrow" or "Monday" alone come back at noon; morning is friendlier.
        let phrase = (normalized as NSString).substring(with: match.range)
        let saysTime = phrase.range(of: #"\d|morning|afternoon|evening|night|noon|midnight"#,
                                    options: .regularExpression) != nil
        if !saysTime {
            date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        }
        while date <= now { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? now }
        return date
    }

    /// Without am/pm, "3" means 3 PM (nobody asks for 3 AM), and "9" whichever 9 o'clock comes next.
    private static func nextTime(hour: Int, minute: Int, meridiem: String?, after now: Date) -> Date? {
        let hours: [Int]
        switch (meridiem, hour) {
        case ("am", _): hours = [hour % 12]
        case ("pm", _): hours = [hour % 12 + 12]
        case (_, 1...7): hours = [hour + 12]
        case (_, 8...11): hours = [hour, hour + 12]
        default: hours = [hour]
        }
        let calendar = Calendar.current
        return hours.compactMap { h in
            calendar.nextDate(after: now, matching: DateComponents(hour: h, minute: minute, second: 0),
                              matchingPolicy: .nextTime)
        }.min()
    }
}

/// "at 3:45 PM", "tomorrow at 9:00 AM", "on Mon, Oct 27 at 9:00 AM"
func describeReturn(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "at \(time)" }
    if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
    return "on \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) at \(time)"
}

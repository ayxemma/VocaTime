import Foundation

/// Extracts a single primary date/time from natural phrases. Deterministic; English + basic Chinese relative time.
struct DateParser {
    private let calendar: Calendar
    private let referenceDate: Date

    init(calendar: Calendar = .current, referenceDate: Date = .now) {
        self.calendar = calendar
        self.referenceDate = referenceDate
    }

    /// First matching date and the substring range to remove when building a title.
    func firstMatch(in text: String) -> (date: Date, range: Range<String.Index>)? {
        typealias MatchHandler = (NSTextCheckingResult, String) -> Date?
        let candidates: [(String, MatchHandler)] = [
            (#"(?i)next\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)"#, { self.parseNextWeekdayAt($0, $1) }),
            (#"(?i)today\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)"#, { self.parseTodayAt($0, $1) }),
            (#"(?i)tomorrow\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)"#, { self.parseTomorrowAt($0, $1) }),
            // Basic Chinese: N分钟后 / N小时后 (anywhere in sentence)
            (#"([一二三四五六七八九十两零]+)分钟后"#, { self.parseChineseRelative($0, $1, component: .minute) }),
            (#"([一二三四五六七八九十两零]+)小时后"#, { self.parseChineseRelative($0, $1, component: .hour) }),
            // English: in N minutes/hours — digits or spelled (e.g. five, twenty, twenty five)
            (#"(?i)in\s+((?:\d+)|(?:[a-z]+(?:[\s\-]+[a-z]+)?))\s+hours?"#, { self.parseInHoursFlexible($0, $1) }),
            (#"(?i)in\s+((?:\d+)|(?:[a-z]+(?:[\s\-]+[a-z]+)?))\s+minutes?"#, { self.parseInMinutesFlexible($0, $1) }),
            (#"(?i)\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)"#, { self.parseAtTime($0, $1) }),
        ]

        for (pattern, handler) in candidates {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard let m = regex.firstMatch(in: text, options: [], range: full) else { continue }
            guard let range = Range(m.range, in: text), let date = handler(m, text) else { continue }
            return (date, range)
        }
        return nil
    }

    // MARK: - Relative (English flexible)

    private func parseInMinutesFlexible(_ match: NSTextCheckingResult, _ string: String) -> Date? {
        guard match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: string),
              let n = Self.parseDurationAmount(String(string[r])),
              n > 0
        else { return nil }
        return calendar.date(byAdding: .minute, value: n, to: referenceDate)
    }

    private func parseInHoursFlexible(_ match: NSTextCheckingResult, _ string: String) -> Date? {
        guard match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: string),
              let n = Self.parseDurationAmount(String(string[r])),
              n > 0
        else { return nil }
        return calendar.date(byAdding: .hour, value: n, to: referenceDate)
    }

    /// Digits or English words (one–twenty, compounds with twenty–sixty + one–nine).
    private static func parseDurationAmount(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if let n = Int(s), n > 0 { return n }
        return parseEnglishNumberPhrase(s.lowercased())
    }

    private static func parseEnglishNumberPhrase(_ s: String) -> Int? {
        let norm = s.replacingOccurrences(of: "-", with: " ")
        let parts = norm.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let first = parts.first else { return nil }
        if parts.count == 1 {
            return englishWordToInt[first]
        }
        if parts.count == 2, let tens = englishTens[first], let ones = englishWordToInt[parts[1]], ones >= 1, ones <= 9 {
            return tens + ones
        }
        return nil
    }

    private static let englishWordToInt: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
        "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
    ]

    private static let englishTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
    ]

    // MARK: - Relative (Chinese)

    private enum ChineseTimeComponent {
        case minute
        case hour
    }

    private func parseChineseRelative(_ match: NSTextCheckingResult, _ string: String, component: ChineseTimeComponent) -> Date? {
        guard match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: string),
              let n = Self.parseChineseNumber(String(string[r])),
              n > 0
        else { return nil }
        switch component {
        case .minute:
            return calendar.date(byAdding: .minute, value: n, to: referenceDate)
        case .hour:
            return calendar.date(byAdding: .hour, value: n, to: referenceDate)
        }
    }

    /// Basic coverage: 一…十, 两, compounds like 十五, 二十, 二十三.
    private static func parseChineseNumber(_ raw: String) -> Int? {
        let trimmed = String(raw.filter { !$0.isWhitespace })
        if trimmed.isEmpty { return nil }
        let d: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        let chars = Array(trimmed)
        if chars.count == 1 {
            if chars[0] == "十" { return 10 }
            return d[chars[0]]
        }
        if chars.count == 2 {
            if chars[0] == "十" {
                let o = d[chars[1]] ?? 0
                return 10 + o
            }
            if chars[1] == "十" {
                let t = d[chars[0]] ?? 0
                if t >= 1, t <= 9 { return t * 10 }
            }
        }
        if chars.count == 3, chars[1] == "十" {
            let t = d[chars[0]] ?? 0
            let o = d[chars[2]] ?? 0
            if t >= 1, t <= 9, o >= 0, o <= 9 { return t * 10 + o }
        }
        return nil
    }

    // MARK: - Handlers (fixed clock times)

    private func parseTodayAt(_ match: NSTextCheckingResult, _ string: String) -> Date? {
        let day = calendar.startOfDay(for: referenceDate)
        return extractTime(on: day, match: match, string: string, hourGroup: 1, minuteGroup: 2, ampmGroup: 3)
    }

    private func parseTomorrowAt(_ match: NSTextCheckingResult, _ string: String) -> Date? {
        guard let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate)) else {
            return nil
        }
        return extractTime(on: start, match: match, string: string, hourGroup: 1, minuteGroup: 2, ampmGroup: 3)
    }

    private func parseNextWeekdayAt(_ match: NSTextCheckingResult, _ string: String) -> Date? {
        guard match.numberOfRanges >= 5,
              let nameRange = Range(match.range(at: 1), in: string)
        else { return nil }
        let name = String(string[nameRange]).lowercased()
        guard let targetWeekday = weekdayValue(name) else { return nil }
        guard let dayStart = nextOccurrence(ofWeekday: targetWeekday, after: referenceDate) else { return nil }
        return extractTime(on: dayStart, match: match, string: string, hourGroup: 2, minuteGroup: 3, ampmGroup: 4)
    }

    private func parseAtTime(_ match: NSTextCheckingResult, _ string: String) -> Date? {
        let dayStart = calendar.startOfDay(for: referenceDate)
        guard let withTime = extractTime(on: dayStart, match: match, string: string, hourGroup: 1, minuteGroup: 2, ampmGroup: 3)
        else { return nil }
        if withTime <= referenceDate {
            return calendar.date(byAdding: .day, value: 1, to: withTime)
        }
        return withTime
    }

    // MARK: - Time helpers

    private func extractTime(
        on day: Date,
        match: NSTextCheckingResult,
        string: String,
        hourGroup: Int,
        minuteGroup: Int,
        ampmGroup: Int
    ) -> Date? {
        guard match.numberOfRanges > hourGroup,
              let hr = Range(match.range(at: hourGroup), in: string),
              let hour = Int(string[hr]), hour >= 1, hour <= 12
        else { return nil }

        var minute = 0
        if match.numberOfRanges > minuteGroup, match.range(at: minuteGroup).location != NSNotFound,
           let mr = Range(match.range(at: minuteGroup), in: string),
           let m = Int(string[mr]) {
            minute = m
        }

        guard match.numberOfRanges > ampmGroup, match.range(at: ampmGroup).location != NSNotFound,
              let ar = Range(match.range(at: ampmGroup), in: string)
        else { return nil }

        let ampm = String(string[ar]).lowercased().replacingOccurrences(of: ".", with: "")
        let isPM = ampm == "pm" || ampm == "p"
        let isAM = ampm == "am" || ampm == "a"
        guard isPM || isAM else { return nil }

        var h24 = hour
        if isPM, hour < 12 { h24 = hour + 12 }
        if isAM, hour == 12 { h24 = 0 }

        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = h24
        comps.minute = minute
        return calendar.date(from: comps)
    }

    private func weekdayValue(_ name: String) -> Int? {
        switch name {
        case "sunday": return 1
        case "monday": return 2
        case "tuesday": return 3
        case "wednesday": return 4
        case "thursday": return 5
        case "friday": return 6
        case "saturday": return 7
        default: return nil
        }
    }

    /// Next occurrence of `weekday` (1=Sunday … 7=Saturday). Same weekday as today advances one week.
    private func nextOccurrence(ofWeekday target: Int, after ref: Date) -> Date? {
        let todayWd = calendar.component(.weekday, from: ref)
        var add = (target - todayWd + 7) % 7
        if add == 0 { add = 7 }
        let start = calendar.startOfDay(for: ref)
        return calendar.date(byAdding: .day, value: add, to: start)
    }
}

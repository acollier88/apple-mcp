import EventKit
import Foundation

/// RRULE-subset parsing for reminders/events recurrence (IDEAS #36).
///
/// Accepts the iCalendar keys that map cleanly onto EKRecurrenceRule:
/// FREQ=DAILY|WEEKLY|MONTHLY|YEARLY (required), INTERVAL=n, BYDAY=MO,WE
/// (weekly, or ordinal like 2TU for monthly), BYMONTHDAY=1,15, and at most
/// one of UNTIL=yyyy-MM-dd / COUNT=n. Anything else is rejected with the
/// offending key so agents get a fix-it error instead of silent drift.
enum Recurrence {
    static let helpText = "RRULE subset: FREQ=DAILY|WEEKLY|MONTHLY|YEARLY;INTERVAL=n;BYDAY=MO,WE;BYMONTHDAY=1,15;UNTIL=yyyy-MM-dd|COUNT=n"

    private static let weekdays: [String: EKWeekday] = [
        "SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
        "TH": .thursday, "FR": .friday, "SA": .saturday,
    ]

    static func parse(_ input: String) throws -> EKRecurrenceRule {
        var fields: [String: String] = [:]
        for pair in input.uppercased().split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else {
                throw AppleTasksError.saveFailed("bad recurrence component '\(pair)' — expected KEY=VALUE (\(helpText))")
            }
            fields[String(kv[0]).trimmingCharacters(in: .whitespaces)] =
                String(kv[1]).trimmingCharacters(in: .whitespaces)
        }

        let known = Set(["FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "UNTIL", "COUNT"])
        if let unknown = fields.keys.first(where: { !known.contains($0) }) {
            throw AppleTasksError.saveFailed("unsupported recurrence key '\(unknown)' (\(helpText))")
        }

        let frequency: EKRecurrenceFrequency
        switch fields["FREQ"] {
        case "DAILY": frequency = .daily
        case "WEEKLY": frequency = .weekly
        case "MONTHLY": frequency = .monthly
        case "YEARLY": frequency = .yearly
        default:
            throw AppleTasksError.saveFailed("recurrence needs FREQ=DAILY|WEEKLY|MONTHLY|YEARLY (\(helpText))")
        }

        var interval = 1
        if let raw = fields["INTERVAL"] {
            guard let n = Int(raw), n >= 1 else {
                throw AppleTasksError.saveFailed("INTERVAL must be a positive integer, got '\(raw)'")
            }
            interval = n
        }

        var daysOfTheWeek: [EKRecurrenceDayOfWeek]?
        if let raw = fields["BYDAY"] {
            daysOfTheWeek = try raw.split(separator: ",").map { token in
                let t = String(token)
                let dayCode = String(t.suffix(2))
                guard let day = weekdays[dayCode] else {
                    throw AppleTasksError.saveFailed("BYDAY entry '\(t)' — expected MO/TU/WE/TH/FR/SA/SU, optionally with an ordinal like 2TU")
                }
                let ordinalPart = t.dropLast(2)
                if ordinalPart.isEmpty { return EKRecurrenceDayOfWeek(day) }
                guard let ordinal = Int(ordinalPart), ordinal != 0, abs(ordinal) <= 53 else {
                    throw AppleTasksError.saveFailed("BYDAY ordinal in '\(t)' must be a nonzero integer (e.g. 2TU, -1FR)")
                }
                return EKRecurrenceDayOfWeek(dayOfTheWeek: day, weekNumber: ordinal)
            }
        }

        var daysOfTheMonth: [NSNumber]?
        if let raw = fields["BYMONTHDAY"] {
            daysOfTheMonth = try raw.split(separator: ",").map { token in
                guard let n = Int(token), n != 0, abs(n) <= 31 else {
                    throw AppleTasksError.saveFailed("BYMONTHDAY entry '\(token)' must be 1-31 (or negative from month end)")
                }
                return NSNumber(value: n)
            }
        }

        var end: EKRecurrenceEnd?
        if fields["UNTIL"] != nil && fields["COUNT"] != nil {
            throw AppleTasksError.saveFailed("recurrence takes UNTIL or COUNT, not both")
        }
        if let raw = fields["UNTIL"] {
            let fmt = DateFormatter()
            fmt.dateFormat = raw.contains("-") ? "yyyy-MM-dd" : "yyyyMMdd"
            fmt.timeZone = .current
            guard let date = fmt.date(from: raw) else {
                throw AppleTasksError.saveFailed("UNTIL must be yyyy-MM-dd, got '\(raw)'")
            }
            end = EKRecurrenceEnd(end: date)
        }
        if let raw = fields["COUNT"] {
            guard let n = Int(raw), n >= 1 else {
                throw AppleTasksError.saveFailed("COUNT must be a positive integer, got '\(raw)'")
            }
            end = EKRecurrenceEnd(occurrenceCount: n)
        }

        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval,
                                daysOfTheWeek: daysOfTheWeek, daysOfTheMonth: daysOfTheMonth,
                                monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                                setPositions: nil, end: end)
    }

    /// Render an EKRecurrenceRule back to the same RRULE-subset string, so
    /// JSON output round-trips with what `--recurrence` accepts.
    static func format(_ rule: EKRecurrenceRule) -> String {
        var parts: [String] = []
        switch rule.frequency {
        case .daily: parts.append("FREQ=DAILY")
        case .weekly: parts.append("FREQ=WEEKLY")
        case .monthly: parts.append("FREQ=MONTHLY")
        case .yearly: parts.append("FREQ=YEARLY")
        @unknown default: parts.append("FREQ=UNKNOWN")
        }
        if rule.interval > 1 { parts.append("INTERVAL=\(rule.interval)") }
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            let codes = days.map { day -> String in
                let code = ["", "SU", "MO", "TU", "WE", "TH", "FR", "SA"][day.dayOfTheWeek.rawValue]
                return day.weekNumber == 0 ? code : "\(day.weekNumber)\(code)"
            }
            parts.append("BYDAY=" + codes.joined(separator: ","))
        }
        if let monthDays = rule.daysOfTheMonth, !monthDays.isEmpty {
            parts.append("BYMONTHDAY=" + monthDays.map { "\($0)" }.joined(separator: ","))
        }
        if let end = rule.recurrenceEnd {
            if let date = end.endDate {
                parts.append("UNTIL=" + Dates.format(date, "yyyy-MM-dd"))
            } else if end.occurrenceCount > 0 {
                parts.append("COUNT=\(end.occurrenceCount)")
            }
        }
        return parts.joined(separator: ";")
    }
}

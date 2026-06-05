import Foundation

/// Formats cron schedule strings into short UI pill labels.
enum SchedulePillFormatter {
    static func format(
        schedule: String,
        display: String?,
        timezone: String? = nil
    ) -> String {
        let base: String
        if let display, !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = normalizeDisplay(display)
        } else {
            base = inferFromSchedule(schedule)
        }
        return appendTimezoneSuffix(base, schedule: schedule, timezone: timezone)
    }

    /// Tag the pill with a short timezone hint when the job is anchored to
    /// a specific IANA timezone AND the schedule actually has a wall-clock
    /// component. Relative intervals like `every 2h` need no tag because
    /// they fire on a duration regardless of timezone.
    private static func appendTimezoneSuffix(
        _ base: String,
        schedule: String,
        timezone: String?
    ) -> String {
        guard let timezone, !timezone.isEmpty else { return base }
        guard let tz = TimeZone(identifier: timezone) else { return base }
        guard hasWallClockComponent(schedule: schedule) else { return base }
        let abbreviation = tz.abbreviation() ?? timezone
        // If the existing label already mentions the abbreviation, skip.
        if base.localizedCaseInsensitiveContains(" \(abbreviation)") {
            return base
        }
        return "\(base) \(abbreviation)"
    }

    private static func hasWallClockComponent(schedule: String) -> Bool {
        let s = schedule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("every ") || s.hasSuffix("m") || s.hasSuffix("h") || s.hasSuffix("d") {
            // Cheap check first; fall through for "every 1d" etc. which is
            // still relative.
            let relative = try? NSRegularExpression(pattern: #"^(every\s+)?\d+\s*[mhd]\s*$"#)
            if let relative,
               relative.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                return false
            }
        }
        // 5-field cron expressions with a numeric hour or minute have a
        // wall-clock anchor.
        let parts = schedule.split(separator: " ")
        if parts.count == 5 {
            let minute = String(parts[0])
            let hour = String(parts[1])
            return Int(minute) != nil || Int(hour) != nil
        }
        return false
    }

    private static func normalizeDisplay(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("every day at") {
            s = s.replacingOccurrences(of: "Every day at", with: "Daily at", options: .caseInsensitive)
        }
        return s
    }

    private static func inferFromSchedule(_ schedule: String) -> String {
        let s = schedule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let intervalPattern = try? NSRegularExpression(pattern: #"^every\s+(\d+)\s*([mhd])\s*$"#)
        if let match = intervalPattern?.firstMatch(
            in: s,
            range: NSRange(s.startIndex..., in: s)
        ),
           let nRange = Range(match.range(at: 1), in: s),
           let uRange = Range(match.range(at: 2), in: s),
           let n = Int(s[nRange]) {
            switch s[uRange].prefix(1) {
            case "m": return n == 1 ? "Every minute" : "Every \(n) minutes"
            case "h": return n == 1 ? "Every hour" : "Every \(n) hours"
            case "d": return n == 1 ? "Daily" : "Every \(n) days"
            default: break
            }
        }

        if s == "every 1h" || s == "hourly" || s.contains("every hour") {
            return "Every hour"
        }

        let cronParts = schedule.split(separator: " ")
        if cronParts.count == 5 {
            let minute = String(cronParts[0])
            let hour = String(cronParts[1])
            let dow = String(cronParts[4])
            if let h = Int(hour), let m = Int(minute) {
                let time = formatClock(hour: h, minute: m)
                if dow != "*" {
                    return "\(weekdayName(dow)) at \(time)"
                }
                return "Daily at \(time)"
            }
        }

        return schedule
    }

    private static func formatClock(hour: Int, minute: Int) -> String {
        var h = hour % 12
        if h == 0 { h = 12 }
        let meridiem = hour >= 12 ? "PM" : "AM"
        if minute == 0 {
            return "\(h) \(meridiem)"
        }
        return String(format: "%d:%02d %@", h, minute, meridiem)
    }

    private static func weekdayName(_ token: String) -> String {
        switch token {
        case "0", "7": return "Sundays"
        case "1": return "Mondays"
        case "2": return "Tuesdays"
        case "3": return "Wednesdays"
        case "4": return "Thursdays"
        case "5": return "Fridays"
        case "6": return "Saturdays"
        default: return "Weekly"
        }
    }
}

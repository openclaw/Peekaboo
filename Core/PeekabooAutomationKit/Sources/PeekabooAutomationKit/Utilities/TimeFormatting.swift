import Foundation

/// Formats a time duration into a human-readable string
/// - Parameter seconds: The duration in seconds
/// - Returns: A formatted string like "123µs", "45ms", "2.3s", or "1m 30s"
public func formatDuration(_ seconds: TimeInterval) -> String {
    renderDuration(seconds, minuteLabel: "m")
}

/// Longer minute label used by agent and Mac activity rows.
public func formatDetailedDuration(_ seconds: TimeInterval) -> String {
    renderDuration(seconds, minuteLabel: "min")
}

private func renderDuration(_ seconds: TimeInterval, minuteLabel: String) -> String {
    guard seconds.isFinite else {
        return "an unknown duration"
    }
    // Promote only when the printed value reaches the next unit, so ordinary ties keep printf's rounding.
    if seconds < 0.001 {
        let microseconds = String(format: "%.0f", seconds * 1_000_000)
        return microseconds == "1000" ? "1ms" : "\(microseconds)µs"
    }
    if seconds < 1 {
        let milliseconds = String(format: "%.0f", seconds * 1000)
        return milliseconds == "1000" ? "1.0s" : "\(milliseconds)ms"
    }
    if seconds < 60 {
        let tenths = String(format: "%.1f", seconds)
        return tenths == "60.0" ? "1\(minuteLabel) 0s" : "\(tenths)s"
    }

    let minuteValue = seconds / 60
    // Double(Int.max) rounds up to 2^63, which Int cannot hold.
    guard minuteValue < Double(Int.max) else {
        return "an unknown duration"
    }
    let minutes = Int(minuteValue)
    let remainingSeconds = Int(seconds.truncatingRemainder(dividingBy: 60))
    return "\(minutes)\(minuteLabel) \(remainingSeconds)s"
}

/// Formats a date relative to now
/// - Parameters:
///   - date: The date to format
///   - now: The reference date (defaults to current date)
/// - Returns: A formatted string like "just now", "5 minutes ago", "2 hours ago", etc.
public func formatTimeAgo(_ date: Date, from now: Date = Date()) -> String {
    // Formats a date relative to now
    let interval = now.timeIntervalSince(date)

    if interval < 60 {
        return "just now"
    } else if interval < 3600 {
        let minutes = Int(interval / 60)
        return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
    } else if interval < 86400 {
        let hours = Int(interval / 3600)
        return "\(hours) hour\(hours == 1 ? "" : "s") ago"
    } else {
        let days = Int(interval / 86400)
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}

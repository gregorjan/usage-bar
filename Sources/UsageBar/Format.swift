import Foundation

enum Format {
    static let nearLimit = 90.0

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    static func barText(_ snapshot: AccountSnapshot) -> String {
        guard snapshot.error == nil, !snapshot.windows.isEmpty else { return "—" }
        return snapshot.windows.map { window in
            let base = window.label.isEmpty ? percent(window.percentUsed) : "\(window.label) \(percent(window.percentUsed))"
            guard let used = window.percentUsed, used >= nearLimit, let reset = window.resetsAt else { return base }
            return "\(base) ↻\(shortReset(reset))"
        }.joined(separator: " ")
    }

    static func shortReset(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "cs_CZ")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d.M."
        return formatter.string(from: date)
    }

    static func fullReset(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "cs_CZ")
        formatter.dateFormat = "d.M. HH:mm"
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return formatter.string(from: date) }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let left = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        return "\(formatter.string(from: date)) (in \(left))"
    }

    static func compact(_ snapshot: AccountSnapshot) -> String {
        guard snapshot.error == nil, !snapshot.windows.isEmpty else { return "—" }
        return snapshot.windows.map { percent($0.percentUsed).replacingOccurrences(of: "%", with: "") }
            .joined(separator: "/")
    }
}

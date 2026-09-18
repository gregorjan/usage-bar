import UserNotifications

@MainActor
final class Notify: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notify()

    func start() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.write("notify auth granted=\(granted) \(error.map { "error=\($0.localizedDescription)" } ?? "")")
        }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                Log.write("notify \(title) — \(body) \(error.map { "failed=\($0.localizedDescription)" } ?? "")")
            }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}

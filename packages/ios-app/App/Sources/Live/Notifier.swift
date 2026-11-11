import AgentSwitchKit
import Foundation
import UserNotifications

/// Notifications the phone posts itself (docs/app-v0.md §5 “通知”, 2026-11-11): a terminal that newly waits for you,
/// a terminal whose turn ended. There were none at all before — only the Live Activity — so nothing ever came, with
/// the app open or not (user: 就算我开着app 也不会给我推送通知).
///
/// Local ones: the app posts them when it learns of the change, which it does while it runs — in front, and for the
/// short while iOS lets it go on behind. With the app closed nothing is learnt and nothing is posted: that takes a
/// push from Apple's service, which needs the paid developer programme and a sender (not done).
///
/// Shown as a banner with the app in front too (`willPresent`); tapping one opens its terminal.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let terminalKey = "terminal"
    /// A notification was tapped: its terminal's id.
    var opened: (@MainActor (String) -> Void)?
    private let center: UNUserNotificationCenter?

    override init() {
        // No notification centre in a test host or a preview without a bundle.
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        center?.delegate = self
    }

    /// Asked once, the first time there is something to say (the system remembers the answer).
    private func allowed() async -> Bool {
        guard let center else { return false }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default: return false
        }
    }

    /// The system's question is put now, not at the first thing to say (a terminal's page was opened).
    func prepare() { Task { _ = await allowed() } }

    /// One notification about terminal `id`; a later one about the same terminal takes its place.
    func post(terminal id: String, title: String, body: String) {
        Task {
            guard await allowed(), let center else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = [Self.terminalKey: id]
            content.threadIdentifier = id
            try? await center.add(UNNotificationRequest(identifier: "terminal:\(id)", content: content, trigger: nil))
        }
    }

    /// What was said about terminal `id` is taken back (it is on screen now).
    func clear(terminal id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: ["terminal:\(id)"])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo[Self.terminalKey] as? String else { return }
        await MainActor.run { opened?(id) }
    }
}

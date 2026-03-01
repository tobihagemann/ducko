import AppKit
import DuckoCore
import UserNotifications

/// NSObject subclass required for UNUserNotificationCenterDelegate conformance —
/// Apple's notification delegate protocol inherits from NSObjectProtocol.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    var onNotificationTapped: ((String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    func postMessageNotification(from senderName: String, body: String, jidString: String, avatarData: Data?) {
        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body = body
        content.sound = .default
        content.userInfo = ["jid": jidString]

        if let avatarData {
            attachAvatar(avatarData, to: content)
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func updateDockBadge(totalUnread: Int) {
        NSApp.dockTile.badgeLabel = totalUnread > 0 ? "\(totalUnread)" : nil
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let jid = response.notification.request.content.userInfo["jid"] as? String
        await MainActor.run {
            if let jid {
                onNotificationTapped?(jid)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: - Private

    private func attachAvatar(_ data: Data, to content: UNMutableNotificationContent) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try data.write(to: tempURL)
            let attachment = try UNNotificationAttachment(identifier: "avatar", url: tempURL)
            content.attachments = [attachment]
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            // Avatar attachment failed — notification still works without it
        }
    }
}

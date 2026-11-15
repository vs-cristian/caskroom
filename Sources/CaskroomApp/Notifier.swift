import AppKit
import UserNotifications

/// Says when brew finishes while Caskroom is in the background, and when a
/// scheduled check finds updates.
@MainActor
enum Notifier {
    /// UNUserNotificationCenter traps without a bundle, as under `swift run`.
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    nonisolated private static let updatesIdentifier = "updates-available"
    private static let delegate = Delegate()

    /// `openUpdates` runs when an "updates available" notification is clicked.
    static func setUp(openUpdates: @escaping @MainActor () -> Void) {
        delegate.openUpdates = openUpdates
        center?.delegate = delegate
    }

    /// Asked on the first change you make, not at launch, so the prompt has context.
    /// Later calls don't prompt again.
    static func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func finished(_ run: OperationRun) {
        guard !NSApp.isActive, let center else { return }
        let content = UNMutableNotificationContent()
        switch run.state {
        case .succeeded:
            content.title = run.operation.doneTitle
        case let .failed(message):
            content.title = "\(run.operation.title) failed"
            content.body = message
        default:
            return
        }
        center.add(UNNotificationRequest(identifier: run.id.uuidString, content: content, trigger: nil))
    }

    /// One notification for the updates a scheduled check found, replacing the
    /// last one. Permission is asked here if nothing has asked yet: this is
    /// what it's for, and nothing you did has had a chance to ask.
    static func updatesAvailable(_ names: [String]) {
        guard !NSApp.isActive, let center, !names.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = names.count == 1 ? "Update Available" : "\(names.count) Updates Available"
        content.body = names.count <= 3
            ? names.formatted(.list(type: .and))
            : "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
        let request = UNNotificationRequest(identifier: updatesIdentifier, content: content, trigger: nil)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        var openUpdates: (@MainActor () -> Void)?

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            guard response.notification.request.identifier == Notifier.updatesIdentifier else { return }
            await openUpdates?()
        }
    }
}

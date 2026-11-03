import Core
import Foundation
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    nonisolated static let approvalCategory = "run.approval"
    private nonisolated static let runIdKey = "runId"

    weak var model: AppModel? {
        didSet {
            guard model != nil, !queuedActions.isEmpty else { return }
            let queued = queuedActions
            queuedActions = []
            Task { for (action, runId) in queued { await route(action: action, runId: runId) } }
        }
    }
    private var queuedActions: [(action: String, runId: UUID)] = []
    private var loggedUnavailable = false

    // The bare `swift build` binary has no bundle id, and UNUserNotificationCenter.current() traps without one.
    private var center: UNUserNotificationCenter? {
        if Bundle.main.bundleIdentifier != nil { return .current() }
        if !loggedUnavailable {
            loggedUnavailable = true
            appLogger.notice("No bundle identifier; notifications are disabled")
        }
        return nil
    }

    func activate() {
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.approvalCategory,
            actions: [
                UNNotificationAction(identifier: "approve", title: String(localized: "Run", bundle: .resources)),
                UNNotificationAction(identifier: "skip", title: String(localized: "Skip", bundle: .resources), options: .destructive),
            ],
            intentIdentifiers: [])])
        Task {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) } catch {
                appLogger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func postApproval(_ run: Run, ruleName: String) {
        let content = UNMutableNotificationContent()
        content.title = ruleName
        content.subtitle = run.snapshot?.subject.pullRequest?.title ?? "\(run.repo)#\(run.prNumber)"
        content.body = String(run.snapshot?.renderedPrompt.prefix(120) ?? "")
        content.categoryIdentifier = Self.approvalCategory
        content.userInfo = [Self.runIdKey: run.id.uuidString]
        post(content, id: run.id.uuidString)
    }

    func postFailure(_ run: Run) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Launch failed", bundle: .resources)
        content.subtitle = run.snapshot?.subject.pullRequest?.title ?? "\(run.repo)#\(run.prNumber)"
        content.body = run.error ?? ""
        post(content, id: "failed-\(run.id.uuidString)")
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        guard let center else { return }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { appLogger.error("Posting notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let runId = (response.notification.request.content.userInfo[Self.runIdKey] as? String).flatMap(UUID.init) else { return }
        await route(action: action, runId: runId)
    }

    private func route(action: String, runId: UUID) async {
        guard ["approve", "skip"].contains(action) else { return }
        guard let model else {
            queuedActions.append((action, runId))
            return
        }
        if action == "approve" { await model.approve(runId: runId) } else { await model.skip(runId: runId) }
    }
}

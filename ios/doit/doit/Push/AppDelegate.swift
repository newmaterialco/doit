import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set from `doitApp` before launch finishes.
    weak var pushManager: PushManager?
    weak var todoStore: TodoStore?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        print("[push] didRegisterForRemoteNotifications")
        Task { @MainActor in
            await pushManager?.handleAPNsToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[push] registration failed: \(error)")
    }

    // Show banners + sound for pushes received while the app is in foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        print("[push] willPresent notification userInfo=\(userInfo)")
        if let kind = userInfo["kind"] as? String, kind == "activity_sync" {
            refreshActivityFromPush(userInfo: userInfo)
            completionHandler([])
            return
        }
        if let s = userInfo["todo_id"] as? String, let id = UUID(uuidString: s) {
            Task { @MainActor in
                TodoRemoteUpdate.post(todoID: id)
            }
        }
        completionHandler([.banner, .sound, .badge])
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let kind = userInfo["kind"] as? String, kind == "activity_sync" else {
            completionHandler(.noData)
            return
        }
        guard let store = todoStore else {
            completionHandler(.noData)
            return
        }
        guard let todoID = todoID(from: userInfo) else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            print("[push] activity_sync background refresh todo=\(todoID)")
            await store.refreshAgentActivity(for: todoID)
            completionHandler(.newData)
        }
    }

    private func refreshActivityFromPush(userInfo: [AnyHashable: Any]) {
        guard let store = todoStore, let todoID = todoID(from: userInfo) else { return }
        Task { @MainActor in
            await store.refreshAgentActivity(for: todoID)
        }
    }

    private func todoID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard let raw = userInfo["todo_id"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    // Route taps to the todo.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            self.pushManager?.handleNotificationTap(userInfo: userInfo)
        }
        completionHandler()
    }
}

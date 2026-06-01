import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set from `doitApp` before launch finishes.
    weak var pushManager: PushManager?

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
        if let s = userInfo["todo_id"] as? String, let id = UUID(uuidString: s) {
            Task { @MainActor in
                TodoRemoteUpdate.post(todoID: id)
            }
        }
        completionHandler([.banner, .sound, .badge])
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

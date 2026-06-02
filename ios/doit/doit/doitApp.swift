import SwiftUI

@main
struct doitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var auth = AuthModel()
    @State private var push = PushManager()
    /// Single source of truth for todos / cron jobs / interactions /
    /// artifacts. Held at app scope so realtime subscriptions and view
    /// state survive navigation pushes. See `Stores/TodoStore.swift`
    /// and `docs/task-realtime.md`.
    @State private var todoStore = TodoStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(push)
                .environment(todoStore)
                .task {
                    appDelegate.pushManager = push
                    auth.bootstrap()
                }
                .onChange(of: auth.state) { _, newValue in
                    switch newValue {
                    case .signedIn(let userID):
                        push.register(userID: userID)
                        // Start the store before any view appears so the
                        // initial render sees a populated list rather than
                        // an empty placeholder.
                        todoStore.start(userID: userID)
                    case .signedOut:
                        todoStore.stop()
                    case .loading:
                        break
                    }
                }
        }
    }
}

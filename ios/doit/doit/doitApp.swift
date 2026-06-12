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
    /// Post-signup gate: invite redemption + agent provisioning progress.
    /// `todoStore.start` and push registration wait for `isReady` so an
    /// unprovisioned user never has tasks stuck on "Preparing…".
    @State private var onboarding = OnboardingModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(push)
                .environment(todoStore)
                .environment(onboarding)
                .task {
                    appDelegate.pushManager = push
                    appDelegate.todoStore = todoStore
                    auth.bootstrap()
                }
                .onChange(of: auth.state) { _, newValue in
                    switch newValue {
                    case .signedIn(let userID):
                        // Resolves instantly from a local cache for users
                        // who already finished onboarding; flips `isReady`
                        // when the agent exists, which starts the store
                        // below.
                        onboarding.begin(userID: userID)
                    case .signedOut:
                        todoStore.stop()
                        onboarding.reset()
                    case .loading:
                        break
                    }
                }
                .onChange(of: onboarding.isReady) { _, ready in
                    guard ready, case .signedIn(let userID) = auth.state else { return }
                    push.register(userID: userID)
                    // Start the store before any view appears so the
                    // initial render sees a populated list rather than
                    // an empty placeholder.
                    todoStore.start(userID: userID)
                }
        }
    }
}

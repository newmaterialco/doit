import SwiftUI

struct RootView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(OnboardingModel.self) private var onboarding

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            SignInView()
        case .signedIn(let userID):
            if onboarding.isReady {
                TodoListView(userID: userID)
            } else {
                OnboardingView()
            }
        }
    }
}

import SwiftUI

struct RootView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(AppSetupModeStore.self) private var setupMode
    @Environment(OnboardingModel.self) private var onboarding

    var body: some View {
        if let mode = setupMode.mode {
            switch mode {
            case .hosted:
                authRoutedView
            case .byoConnector:
                if AppConfig.byoConnectorEnabled {
                    switch auth.state {
                    case .loading:
                        loadingView
                    case .signedOut:
                        BYOAnonymousStartView()
                    case .signedIn(let userID):
                        if onboarding.isReady {
                            TodoListView(userID: userID)
                        } else {
                            OnboardingView()
                        }
                    }
                } else {
                    SetupModeView()
                }
            case .selfHost:
                SelfHostInfoView()
            }
        } else {
            SetupModeView()
        }
    }

    @ViewBuilder
    private var authRoutedView: some View {
        switch auth.state {
        case .loading:
            loadingView
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

    private var loadingView: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppSemanticColors.screenBackground.ignoresSafeArea())
    }
}

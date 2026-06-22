import SwiftUI
import UIKit

/// UIKit-backed semantic colors shared across doit surfaces.
enum AppSemanticColors {
    private static let lightCanvasUIColor = UIColor(
        red: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1
    )

    static let screenBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .systemGroupedBackground : lightCanvasUIColor
    })
    static let surface = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .systemBackground : lightCanvasUIColor
    })
    static let elevatedSurface = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : .white
    })
    static let footerSurface = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .tertiarySystemGroupedBackground : lightCanvasUIColor
    })
    static let separator = Color(.separator)
    static let mutedChrome = Color(.tertiaryLabel)
    static let neutralFill = Color(.systemGray5)
    static let neutralFillStrong = Color(.systemGray4)

    /// High-contrast controls that invert with appearance (FAB, avatar placeholder).
    /// Light mode: black surface / white foreground. Dark mode: white / black.
    static let invertedSurface = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .white : .black
    })
    static let invertedForeground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .white
    })

    static let fabBackground = invertedSurface
    static let fabForeground = invertedForeground

    /// Collapsed new-task morph FAB. Pure white in light mode.
    static let morphFabBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : .white
    })

    /// Expanded new-task morph card. Light canvas in light mode, elevated grey in dark mode.
    static let morphComposerBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : lightCanvasUIColor
    })
    static let avatarPlaceholderBackground = invertedSurface
    static let avatarPlaceholderForeground = invertedForeground
    static let avatarBorder = neutralFillStrong

    /// Pill-style "Connect" actions: white fill in dark mode, light gray in light mode.
    static let connectButtonBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .white : .systemGray6
    })
    static let connectButtonForeground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .black
    })
    static let connectButtonBorder = neutralFillStrong

    /// VerticalSplit pane chrome — matches upstream VerticalSplit defaults.
    static let splitPaneBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.16, alpha: 1)
            : lightCanvasUIColor
    })
    static let splitChromeBackground = Color.black

    /// Thin full-width divider track (expanded split). Always black so it
    /// reads as an integrated bar, not a floating pill in dark mode.
    static let splitHandleTrackBackground = Color.black
    static let splitHandleTrackForeground = Color.white
    static let splitHandleGrabber = Color.white.opacity(0.3)

    /// Collapsed pane title capsule only ("Chat", truncated task title).
    static let splitHandleMinimalBackground = invertedSurface
    static let splitHandleMinimalForeground = invertedForeground

    /// Fade behind the chat composer at the bottom of the split pane.
    static let composerFadeClear = Color(uiColor: UIColor { trait in
        let base = trait.userInterfaceStyle == .dark ? UIColor.black : lightCanvasUIColor
        return base.withAlphaComponent(0)
    })
    static let composerFadeOpaque = Color(uiColor: UIColor { trait in
        let base = trait.userInterfaceStyle == .dark ? UIColor.black : lightCanvasUIColor
        return base.withAlphaComponent(0.5)
    })

    /// Inset panel behind grouped stacks (e.g. animated activity cards).
    static let insetPanelBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .systemGray6
    })

    /// Confirm control while voice recording — white checkmark on black (matches mic).
    static let recordingConfirmBackground = Color.black
    static let recordingConfirmForeground = Color.white
}

extension View {
    func recordingConfirmButtonChrome() -> some View {
        foregroundStyle(AppSemanticColors.recordingConfirmForeground)
            .frame(width: 40, height: 40)
            .background(AppSemanticColors.recordingConfirmBackground, in: Circle())
    }

    func connectButtonChrome(cornerRadius: CGFloat = 10) -> some View {
        foregroundStyle(AppSemanticColors.connectButtonForeground)
            .background(
                AppSemanticColors.connectButtonBackground,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppSemanticColors.connectButtonBorder, lineWidth: 1)
            }
    }
}

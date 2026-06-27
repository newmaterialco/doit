import SwiftUI

struct AdaptiveDoitLogo: View {
    @Environment(\.colorScheme) private var colorScheme

    let width: CGFloat

    var body: some View {
        Image(colorScheme == .dark ? "doit_logo_dark" : "doit_logo_light")
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .accessibilityLabel("doit")
    }
}

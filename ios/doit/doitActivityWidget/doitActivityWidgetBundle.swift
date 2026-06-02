import SwiftUI
import WidgetKit

/// Widget bundle for the Doit Live Activity. Currently exposes a single
/// widget: the Hermes agent activity that mirrors what the iOS app shows
/// in the task detail header.
@main
struct doitActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        HermesLiveActivity()
    }
}

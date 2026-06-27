import Foundation
import Observation

enum AppSetupMode: String, CaseIterable, Identifiable {
    case hosted
    case byoConnector
    case selfHost

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppSetupModeStore {
    private static let storageKey = "app.setupMode"

    private(set) var mode: AppSetupMode?

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey) {
            mode = AppSetupMode(rawValue: raw)
        }
    }

    static var currentMode: AppSetupMode? {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return nil }
        return AppSetupMode(rawValue: raw)
    }

    var isBYO: Bool {
        mode == .byoConnector
    }

    func choose(_ mode: AppSetupMode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
    }

    func reset() {
        mode = nil
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }
}

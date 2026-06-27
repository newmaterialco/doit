import Foundation

/// App runtime configuration injected from Xcode build settings.
enum AppConfig {
    static let supabaseURL = url(
        forInfoKey: "DoitSupabaseURL",
        fallbackKey: "DOIT_SUPABASE_URL"
    )
    static let supabaseAnonKey = string(
        forInfoKey: "DoitSupabaseAnonKey",
        fallbackKey: "DOIT_SUPABASE_ANON_KEY"
    )
    static let waitlistURL = url(
        forInfoKey: "DoitWaitlistURL",
        fallbackKey: "DOIT_WAITLIST_URL"
    )
    static let byoConnectorEnabled = bool(
        forInfoKey: "DoitBYOConnectorEnabled",
        fallbackKey: "DOIT_BYO_CONNECTOR_ENABLED",
        defaultValue: false
    )

    private static func string(forInfoKey key: String, fallbackKey: String) -> String {
        for candidate in [key, fallbackKey] {
            if
                let value = Bundle.main.object(forInfoDictionaryKey: candidate) as? String,
                !value.isEmpty
            {
                return value
            }
        }
        fatalError("Missing required Info.plist value: \(key)")
    }

    private static func url(forInfoKey key: String, fallbackKey: String) -> URL {
        let value = string(forInfoKey: key, fallbackKey: fallbackKey)
        guard let url = URL(string: value) else {
            fatalError("Invalid URL for Info.plist value \(key): \(value)")
        }
        return url
    }

    private static func bool(
        forInfoKey key: String,
        fallbackKey: String,
        defaultValue: Bool
    ) -> Bool {
        for candidate in [key, fallbackKey] {
            if let value = Bundle.main.object(forInfoDictionaryKey: candidate) as? Bool {
                return value
            }
            if let raw = Bundle.main.object(forInfoDictionaryKey: candidate) as? String {
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["1", "true", "yes", "y", "on"].contains(normalized) { return true }
                if ["0", "false", "no", "n", "off"].contains(normalized) { return false }
            }
        }
        return defaultValue
    }
}

/// Supabase project credentials. Values come from `ios/doit/Config/*.xcconfig`.
enum SupabaseConfig {
    static let url = AppConfig.supabaseURL
    static let anonKey = AppConfig.supabaseAnonKey
}

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
}

/// Supabase project credentials. Values come from `ios/doit/Config/*.xcconfig`.
enum SupabaseConfig {
    static let url = AppConfig.supabaseURL
    static let anonKey = AppConfig.supabaseAnonKey
}

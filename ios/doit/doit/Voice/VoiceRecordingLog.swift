import Foundation

enum VoiceRecordingLog {
    private static var origin: CFAbsoluteTime?

    static func markTapOrigin() {
        origin = CFAbsoluteTimeGetCurrent()
        print("[voice] mic_tap")
    }

    static func event(_ name: String) {
        guard let origin else {
            print("[voice] \(name)")
            return
        }
        let ms = (CFAbsoluteTimeGetCurrent() - origin) * 1000
        print("[voice] \(name) +\(String(format: "%.0f", ms))ms")
    }

    static func reset() {
        origin = nil
    }
}

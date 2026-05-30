import AVFoundation
import Foundation
import Observation

/// Captures microphone audio to a temporary `.m4a` file and publishes a
/// rolling buffer of normalized power levels for waveform visualization.
///
/// The OpenAI Whisper API accepts m4a/AAC, so we record straight to that
/// container and avoid any client-side transcoding.
@MainActor
@Observable
final class VoiceRecorder: NSObject {
    enum RecorderError: LocalizedError {
        case microphoneDenied
        case sessionUnavailable
        case recorderUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access is off. Enable it in Settings to record voice notes."
            case .sessionUnavailable:
                return "Couldn't start the audio session."
            case .recorderUnavailable:
                return "Couldn't start the recorder."
            }
        }
    }

    /// Number of metering samples we keep for the waveform UI.
    static let levelBufferSize = 36

    /// Most recent normalized (0...1) power levels, oldest first.
    private(set) var levels: [CGFloat] = Array(
        repeating: 0,
        count: VoiceRecorder.levelBufferSize
    )

    private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var meteringTask: Task<Void, Never>?
    private var fileURL: URL?

    /// Asks for microphone permission. Returns `true` if recording is allowed.
    func ensurePermission() async -> Bool {
        let session = AVAudioApplication.shared
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    /// Begins a new recording. Throws if the session/recorder couldn't start.
    func start() async throws {
        guard await ensurePermission() else {
            throw RecorderError.microphoneDenied
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: [])
        } catch {
            throw RecorderError.sessionUnavailable
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "doit-voice-\(UUID().uuidString).m4a"
        )
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw RecorderError.recorderUnavailable
            }
            self.recorder = recorder
            self.fileURL = url
            self.isRecording = true
            self.levels = Array(repeating: 0, count: VoiceRecorder.levelBufferSize)
            startMetering()
        } catch {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw RecorderError.recorderUnavailable
        }
    }

    /// Stops recording and returns the resulting file URL, or `nil` if nothing
    /// was recorded.
    @discardableResult
    func stop() -> URL? {
        meteringTask?.cancel()
        meteringTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        let url = fileURL
        fileURL = nil
        return url
    }

    /// Stops the recorder and deletes the temp file. Use when the user cancels.
    func cancel() {
        let url = stop()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sampleMeter()
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    private func sampleMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let avg = recorder.averagePower(forChannel: 0)
        // Normalize -55 dB...0 dB into 0...1 with a small floor so the bars
        // never fully collapse while recording.
        let minDb: Float = -55
        let clamped = max(min(avg, 0), minDb)
        let normalized = CGFloat((clamped - minDb) / -minDb)
        let lifted = max(0.08, normalized)
        var next = levels
        next.removeFirst()
        next.append(lifted)
        levels = next
    }
}

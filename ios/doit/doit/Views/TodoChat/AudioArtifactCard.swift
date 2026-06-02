import AVFoundation
import SwiftUI

/// Player card for `audio` artifacts — Hermes-generated spoken summaries
/// uploaded to the private `todo-audio` Supabase Storage bucket.
///
/// Layout:
///   ┌──────────────────────────────────────────┐
///   │ ▶ icon  Title                provider    │
///   │                                          │
///   │ (●━━━━━━━━━━━━━━━━━━━━━━━━━━━)           │
///   │ 0:12                              1:42   │
///   ├──────────────────────────────────────────┤
///   │ Long-form spoken transcript shown        │
///   │ underneath the controls (selectable).    │
///   └──────────────────────────────────────────┘
///
/// State is held by `AudioPlayerState` so SwiftUI re-renders cleanly when
/// the player ticks, the user scrubs, or the audio is reloaded after a
/// realtime upsert replaces the artifact's storage path. Playback always
/// stops when the view leaves the screen so backgrounded audio never keeps
/// playing under another task.
struct AudioArtifactCard: View {
    let artifact: TodoArtifact

    @State private var state = AudioPlayerState()
    @State private var scrubValue: Double = 0
    @State private var isScrubbing: Bool = false

    var body: some View {
        let clip = artifact.audio
        VStack(alignment: .leading, spacing: 0) {
            playerHeader
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 4)

            playerControls
                .padding(.horizontal, 18)
                .padding(.bottom, 16)

            if let text = clip?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                Divider()
                    .padding(.horizontal, 18)
                Text(text)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(18)
            } else if let err = state.loadError {
                Text(err)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
        .task(id: clip?.storagePath ?? "") {
            await state.load(from: artifact)
        }
        .onDisappear {
            state.cleanup()
        }
    }

    @ViewBuilder
    private var playerHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .symbolEffect(.variableColor.iterative, isActive: state.isPlaying)

            Text(artifact.title ?? "Spoken summary")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var playerControls: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: togglePlayback) {
                ZStack {
                    Circle()
                        .fill(Color.black)
                        .frame(width: 36, height: 36)
                    if state.isLoading && state.player == nil {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .controlSize(.small)
                    } else {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                            // Nudge the play triangle slightly right so it
                            // looks visually centered inside the circle.
                            .offset(x: state.isPlaying ? 0 : 1)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(state.player == nil)
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")

            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: scrubBinding,
                    in: 0...max(state.duration, 0.01),
                    onEditingChanged: handleScrub
                )
                .disabled(state.duration <= 0)
                .tint(Color.accentColor)

                HStack(spacing: 4) {
                    Text(formatTime(displayTime))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Text(formatTime(state.duration))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.top, 6)
        }
    }

    private var displayTime: Double {
        isScrubbing ? scrubValue : state.currentTime
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { isScrubbing ? scrubValue : state.currentTime },
            set: { newValue in scrubValue = newValue }
        )
    }

    private func togglePlayback() {
        state.togglePlayback()
    }

    private func handleScrub(_ editing: Bool) {
        if editing {
            isScrubbing = true
            scrubValue = state.currentTime
        } else {
            state.seek(to: scrubValue)
            isScrubbing = false
        }
    }

    /// Format seconds as `m:ss` (no hour digit) — every realistic
    /// summary clip runs well under an hour, so dropping the leading
    /// `0:` keeps the labels compact under the slider.
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Player state

/// Holds the AVPlayer-driven state for one audio artifact card. Lives
/// for as long as the card is on screen; `cleanup()` is called from
/// `onDisappear` so the player stops and observers are removed before
/// the card is recycled by SwiftUI.
@MainActor
@Observable
final class AudioPlayerState {
    /// `nil` until `load(from:)` resolves a signed URL and builds the
    /// player. The button stays disabled while this is `nil` so users
    /// don't tap a no-op control.
    var player: AVPlayer?

    /// Toggled in `togglePlayback`, by the periodic time observer when
    /// the item finishes, and by `cleanup()` on disappear.
    var isPlaying: Bool = false

    /// Latest playback time in seconds, refreshed ~4×/second by the
    /// periodic time observer for smooth slider tracking.
    var currentTime: Double = 0

    /// Total duration in seconds. Seeded from the artifact payload
    /// when available, otherwise resolved asynchronously from the
    /// asset itself.
    var duration: Double = 0

    /// True while we're fetching a signed URL or building the player.
    /// Drives a spinner inside the play button so the user gets a
    /// loading affordance instead of an unresponsive control.
    var isLoading: Bool = false

    /// Last error from `load(from:)`, surfaced under the player when
    /// there's no transcript to show instead.
    var loadError: String?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedStoragePath: String?

    deinit {
        // We can't touch `@MainActor` state from deinit safely, but
        // observers retain `self`, so removing them here would create
        // a cycle. The view's `onDisappear` calls `cleanup()` first;
        // this guard is just a belt-and-suspenders log if it didn't.
    }

    /// Resolve a fresh signed URL and build the AVPlayer for one
    /// artifact. Idempotent against re-runs with the same storage
    /// path — the existing player is reused, avoiding a network
    /// round-trip on every realtime echo.
    func load(from artifact: TodoArtifact) async {
        guard let clip = artifact.audio else {
            loadError = "Audio metadata missing."
            return
        }
        if loadedStoragePath == clip.storagePath, player != nil {
            // Pick up any duration update the agent backfilled later.
            if let known = clip.durationSeconds, known > duration {
                duration = known
            }
            return
        }
        cleanup()
        loadedStoragePath = clip.storagePath
        isLoading = true
        loadError = nil

        if let known = clip.durationSeconds, known > 0 {
            duration = known
        }

        do {
            let url = try await AudioArtifactsAPI.signedURL(
                storagePath: clip.storagePath
            )
            let item = AVPlayerItem(url: url)
            let new = AVPlayer(playerItem: item)
            // Don't auto-pause when other audio session changes happen
            // unexpectedly; the user explicitly drives play/pause here.
            new.automaticallyWaitsToMinimizeStalling = true
            player = new
            attachObservers(player: new, item: item)
            if duration <= 0 {
                Task { await loadDurationFromAsset(item: item) }
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Start or pause playback. If playback finished previously,
    /// rewind to the start first so tapping play after end behaves
    /// as the user expects (replay rather than no-op).
    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        if duration > 0, currentTime >= duration - 0.05 {
            player.seek(to: .zero)
            currentTime = 0
        }
        player.play()
        isPlaying = true
    }

    /// Seek to a specific second offset. Clamped to `[0, duration]`
    /// so a stale scrub from a slider that's still bound to an
    /// out-of-range value can't crash the player.
    func seek(to seconds: Double) {
        guard let player else { return }
        let bounded = max(0, min(seconds, max(duration, 0)))
        let target = CMTime(seconds: bounded, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = bounded
    }

    /// Tear down observers, stop playback, and reset state. Safe to
    /// call multiple times.
    func cleanup() {
        player?.pause()
        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }
        if let end = endObserver {
            NotificationCenter.default.removeObserver(end)
            endObserver = nil
        }
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        loadedStoragePath = nil
    }

    private func attachObservers(player: AVPlayer, item: AVPlayerItem) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            // The observer block isn't @MainActor-annotated even though
            // we passed the main queue, so hop explicitly to satisfy
            // strict concurrency.
            Task { @MainActor in
                guard let self else { return }
                let secs = time.seconds
                if secs.isFinite {
                    self.currentTime = secs
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                if self.duration > 0 {
                    self.currentTime = self.duration
                }
            }
        }
    }

    private func loadDurationFromAsset(item: AVPlayerItem) async {
        let asset = item.asset
        do {
            let value = try await asset.load(.duration)
            let secs = value.seconds
            if secs.isFinite, secs > 0 {
                duration = secs
            }
        } catch {
            // Duration is best-effort; an unreadable asset just keeps
            // the slider in its 0..0.01 fallback range.
        }
    }
}

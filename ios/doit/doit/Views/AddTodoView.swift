import SwiftUI

struct AddTodoView: View {
    let userID: UUID
    let onCreated: (Todo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var saving = false
    @State private var error: String?
    @State private var voice = VoiceRecorder()
    @State private var isTranscribing = false
    @FocusState private var isEditorFocused: Bool

    private let promptSuggestions = [
        "Send an email to...",
        "Create an invite to...",
        "Remind me to...",
        "Draft a reply to..."
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topBar

                ZStack(alignment: .bottomLeading) {
                    TextEditor(text: $title)
                        .font(.system(size: 22, weight: .regular, design: .rounded))
                        .lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .background(Color.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .focused($isEditorFocused)

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                            .padding()
                    }
                }
            }
            .background {
                Color.white.ignoresSafeArea()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .presentationBackground(.white)
            .onAppear {
                isEditorFocused = true
            }
            .onDisappear {
                voice.cancel()
            }
        }
    }

    private var topBar: some View {
        ZStack {
            Text("New Task")
                .font(.system(.headline, design: .rounded).weight(.semibold))

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color.gray.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")

                Spacer()

                Button {
                    Task { await save() }
                } label: {
                    Text("Create")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(canCreate ? .white : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(canCreate ? Color.blue : Color.gray.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canCreate || saving)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(Color.white)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            voiceControl
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(promptSuggestions, id: \.self) { suggestion in
                        Button {
                            title = suggestion
                            isEditorFocused = true
                        } label: {
                            Text(suggestion)
                                .font(.system(.subheadline, design: .rounded).weight(.medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.gray.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(voice.isRecording || isTranscribing)
                        .opacity(voice.isRecording || isTranscribing ? 0.4 : 1)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.white)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: voice.isRecording)
        .animation(.easeInOut(duration: 0.2), value: isTranscribing)
    }

    @ViewBuilder
    private var voiceControl: some View {
        if voice.isRecording {
            recordingPill
        } else if isTranscribing {
            transcribingPill
        } else {
            HStack {
                micButton
                Spacer(minLength: 0)
            }
        }
    }

    private var micButton: some View {
        Button {
            Task { await startRecording() }
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.black, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record voice note")
    }

    private var recordingPill: some View {
        HStack(spacing: 12) {
            Button {
                cancelRecording()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.red.opacity(0.85), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")

            WaveformView(levels: voice.levels)
                .frame(maxWidth: .infinity)
                .frame(height: 28)

            Button {
                Task { await acceptRecording() }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.blue, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use recording")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.10), in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private var transcribingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.primary)
            Text("Transcribing…")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.10), in: Capsule())
        .transition(.opacity)
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !saving
            && !isTranscribing
            && !voice.isRecording
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let todo = try await TodosAPI.create(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: nil,
                userID: userID
            )
            onCreated(todo)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Voice flow

    private func startRecording() async {
        error = nil
        isEditorFocused = false
        do {
            try await voice.start()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cancelRecording() {
        voice.cancel()
        isEditorFocused = true
    }

    private func acceptRecording() async {
        guard let url = voice.stop() else {
            isEditorFocused = true
            return
        }
        isTranscribing = true
        defer {
            isTranscribing = false
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let text = try await TranscriptionAPI.transcribe(fileURL: url)
            insertTranscript(text)
            isEditorFocused = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func insertTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty {
            title = trimmed
        } else {
            // Add a space if the current text doesn't end with whitespace,
            // so we don't smush words together.
            let needsSpace = !title.hasSuffix(" ") && !title.hasSuffix("\n")
            title += (needsSpace ? " " : "") + trimmed
        }
    }
}

/// Animated waveform that scrolls left as new audio levels stream in.
private struct WaveformView: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.primary.opacity(0.85))
                        .frame(
                            width: barWidth(in: proxy.size.width),
                            height: max(3, level * proxy.size.height)
                        )
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func barWidth(in totalWidth: CGFloat) -> CGFloat {
        guard !levels.isEmpty else { return 2 }
        let spacing: CGFloat = 3 * CGFloat(levels.count - 1)
        let usable = max(0, totalWidth - spacing)
        return max(2, usable / CGFloat(levels.count))
    }
}

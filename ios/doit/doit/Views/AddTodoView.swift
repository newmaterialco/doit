import PhotosUI
import SwiftUI
import UIKit

struct AddTodoView: View {
    let userID: UUID
    let onCreated: (Todo) -> Void

    /// Hard cap on attached images per task. Mirrors the runner-side budget.
    private static let maxAttachments = 5

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var saving = false
    @State private var error: String?
    @State private var voice = VoiceRecorder()
    @State private var isTranscribing = false
    @State private var pendingImages: [PendingImage] = []
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var preview: PreviewItem?
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
                    VStack(alignment: .leading, spacing: 0) {
                        if !pendingImages.isEmpty {
                            attachmentStrip
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        TextEditor(text: $title)
                            .font(.system(size: 22, weight: .regular, design: .rounded))
                            .lineSpacing(4)
                            .scrollContentBackground(.hidden)
                            .background(Color.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 20)
                            .padding(.top, pendingImages.isEmpty ? 20 : 12)
                            .focused($isEditorFocused)
                    }

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
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: pendingImages.count)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(
                    onPicked: { image in
                        addPendingImage(image)
                        showCamera = false
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .sheet(item: $preview) { item in
                AttachmentPreviewSheet(image: item.image) {
                    preview = nil
                }
            }
            .onChange(of: photoSelections) { _, newSelections in
                guard !newSelections.isEmpty else { return }
                Task { await loadPickedImages(newSelections) }
            }
        }
    }

    private var topBar: some View {
        ZStack {
            Text("New Task")
                .font(.system(.headline, design: .rounded).weight(.semibold))

            HStack {
                Button {
                    playLightHaptic()
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
                    beginSave()
                } label: {
                    Text(saving ? "Creating…" : "Create")
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

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { item in
                    PendingAttachmentTile(
                        image: item.image,
                        onRemove: { remove(item) },
                        onTap: { preview = PreviewItem(image: item.image) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
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
            HStack(spacing: 10) {
                micButton
                cameraButton
                photoButton
                Spacer(minLength: 0)
            }
        }
    }

    private var micButton: some View {
        Button {
            playLightHaptic()
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

    private var cameraButton: some View {
        Button {
            error = nil
            isEditorFocused = false
            #if targetEnvironment(simulator)
            self.error = "Camera isn't available on the simulator."
            #else
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                showCamera = true
            } else {
                self.error = "Camera isn't available on this device."
            }
            #endif
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(Color.gray.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canAddMoreAttachments)
        .opacity(canAddMoreAttachments ? 1 : 0.4)
        .accessibilityLabel("Take a photo")
    }

    private var photoButton: some View {
        PhotosPicker(
            selection: $photoSelections,
            maxSelectionCount: max(1, AddTodoView.maxAttachments - pendingImages.count),
            matching: .images,
            photoLibrary: .shared()
        ) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(Color.gray.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .disabled(!canAddMoreAttachments)
        .opacity(canAddMoreAttachments ? 1 : 0.4)
        .accessibilityLabel("Pick photos from library")
    }

    private var recordingPill: some View {
        HStack(spacing: 12) {
            Button {
                playLightHaptic()
                cancelRecording()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.gray)
                    .frame(width: 40, height: 40)
                    .background(Color.gray.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")

            WaveformView(levels: voice.levels)
                .frame(maxWidth: .infinity)
                .frame(height: 36)

            Button {
                playLightHaptic()
                Task { await acceptRecording() }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(Color.gray.opacity(0.30), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use recording")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.10), in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private var transcribingPill: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.primary)
                .frame(width: 40, height: 40)
            Text("Transcribing…")
                .font(.system(.title3, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
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

    private var canAddMoreAttachments: Bool {
        pendingImages.count < AddTodoView.maxAttachments
    }

    private func beginSave() {
        guard canCreate else { return }
        saving = true
        Task { await save() }
    }

    private func playLightHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func save() async {
        guard saving else { return }
        defer { saving = false }
        do {
            let todo = try await TodosAPI.create(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: nil,
                userID: userID
            )
            // Upload pending attachments after the todo exists. We surface
            // failures inline but still consider the task created so the
            // user doesn't lose their typed text on a flaky network.
            await uploadPendingAttachments(forTodoID: todo.id)
            onCreated(todo)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func uploadPendingAttachments(forTodoID todoID: UUID) async {
        guard !pendingImages.isEmpty else { return }
        var failures = 0
        for item in pendingImages {
            do {
                _ = try await AttachmentsAPI.upload(
                    image: item.image,
                    todoID: todoID,
                    userID: userID
                )
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            self.error = failures == 1
                ? "1 image couldn't upload. Open the task to retry."
                : "\(failures) images couldn't upload. Open the task to retry."
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

    // MARK: - Attachments

    private func addPendingImage(_ image: UIImage) {
        guard canAddMoreAttachments else { return }
        pendingImages.append(PendingImage(id: UUID(), image: image))
    }

    private func remove(_ item: PendingImage) {
        pendingImages.removeAll { $0.id == item.id }
    }

    private func loadPickedImages(_ selections: [PhotosPickerItem]) async {
        let remainingSlots = AddTodoView.maxAttachments - pendingImages.count
        let toLoad = Array(selections.prefix(max(0, remainingSlots)))
        for item in toLoad {
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    addPendingImage(image)
                }
            } catch {
                self.error = "Couldn't load that photo."
            }
        }
        // Reset so picking the same item again still triggers the change.
        photoSelections = []
    }
}

private struct PendingImage: Identifiable, Hashable {
    let id: UUID
    let image: UIImage
}

private struct PreviewItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct AttachmentPreviewSheet: View {
    let image: UIImage
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .padding()
            .accessibilityLabel("Close preview")
        }
    }
}


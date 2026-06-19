import PhotosUI
import SwiftUI
import UIKit

enum AddTodoLaunchAction: Equatable {
    case note
    case recordVoice
    case camera
    case photoLibrary
}

enum AddTodoPresentationStyle {
    case sheet
    case inlineCard
    case morphShell
}

struct AddTodoView: View {
    let userID: UUID
    let presentation: AddTodoPresentationStyle
    let initialAction: AddTodoLaunchAction
    let onCancel: () -> Void
    let onCreated: (Todo) -> Void

    /// Hard cap on attached images per task. Mirrors the runner-side budget.
    private static let maxAttachments = 5
    private static let inlineCardCornerRadius: CGFloat = 34
    private static let inlineEditorCornerRadius: CGFloat = 16
    private static let inlineEditorMinHeight: CGFloat = 72
    private static let morphEditorHeight: CGFloat = 200
    private static let morphAccessoryRowHeight: CGFloat = 52
    private static var morphTextAreaHeight: CGFloat { morphEditorHeight - morphAccessoryRowHeight }
    private static let morphVoiceControlIdleHeight: CGFloat = 40
    private static let morphVoiceControlActiveHeight: CGFloat = 48
    private static let morphVoiceControlActiveInset: CGFloat = 8
    private static let morphRecordingButtonSize: CGFloat = 32
    private static let morphRecordingCheckWaveformGap: CGFloat = 8
    /// Let the recording bar finish expanding before touching AVAudioSession.
    private static let morphRecordingAudioStartDelay: TimeInterval = 0.32
    private static let attachmentRemovalAnimation = Animation.easeOut(duration: 0.18)
    private static let attachmentRemovalDuration: TimeInterval = 0.18
    private static let attachmentInsertAnimation = Animation.spring(response: 0.32, dampingFraction: 0.78)
    private static var attachmentRemovalTransition: AnyTransition {
        .scale(scale: 0.82).combined(with: .opacity)
    }

    @State private var title = ""
    @State private var error: String?
    @State private var voice = VoiceRecorder()
    @State private var isTranscribing = false
    @State private var isRecordingUIActive = false
    @State private var recordingStartTask: Task<Void, Never>?
    @State private var pendingImages: [PendingImage] = []
    @State private var removingAttachmentIDs: Set<UUID> = []
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var preview: PreviewItem?
    @FocusState private var isEditorFocused: Bool

    init(
        userID: UUID,
        initialTitle: String = "",
        initialAction: AddTodoLaunchAction = .note,
        presentation: AddTodoPresentationStyle = .morphShell,
        onCancel: @escaping () -> Void = {},
        onCreated: @escaping (Todo) -> Void
    ) {
        self.userID = userID
        self.presentation = presentation
        self.initialAction = initialAction
        self.onCancel = onCancel
        self.onCreated = onCreated
        _title = State(initialValue: initialTitle)
    }

    private let promptSuggestions = [
        "Send an email to...",
        "Create an invite to...",
        "Remind me to...",
        "Draft a reply to..."
    ]

    private var showsMorphRecordingUI: Bool {
        isRecordingUIActive || voice.isRecording
    }

    private var showsMorphVoiceActiveUI: Bool {
        showsMorphRecordingUI || isTranscribing
    }

    private var isMorphShell: Bool {
        presentation == .morphShell
    }

    private var isInlineCard: Bool {
        presentation == .inlineCard
    }

    private var isEmbeddedComposer: Bool {
        isInlineCard || isMorphShell
    }

    private var isTitleEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var horizontalPadding: CGFloat {
        if isMorphShell { return 20 }
        return isEmbeddedComposer ? 16 : 20
    }

    var body: some View {
        Group {
            if isMorphShell {
                composerContent
            } else if isInlineCard {
                composerContent
                    .frame(maxHeight: 280)
                    .background(AppSemanticColors.surface)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Self.inlineCardCornerRadius, style: .continuous)
                    )
                    .shadow(color: .black.opacity(0.16), radius: 28, y: 18)
            } else {
                NavigationStack {
                    composerContent
                }
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoSelections,
            maxSelectionCount: max(1, AddTodoView.maxAttachments - pendingImages.count),
            matching: .images,
            photoLibrary: .shared()
        )
        .onAppear {
            performLaunchAction()
        }
        .onDisappear {
            recordingStartTask?.cancel()
            recordingStartTask = nil
            voice.cancel()
        }
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

    private var composerContent: some View {
        VStack(spacing: 0) {
            topBar

            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    if !pendingImages.isEmpty {
                        attachmentStrip
                            .transition(Self.attachmentRemovalTransition)
                    }

                    if isEmbeddedComposer {
                        inlineEditorField
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, isMorphShell ? 14 : (pendingImages.isEmpty ? 4 : 8))
                    } else {
                        sheetEditorField
                    }
                }

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 12)
                        .background(AppSemanticColors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                        .padding()
                }
            }

            if isEmbeddedComposer && !isMorphShell {
                bottomBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.bottom, isMorphShell ? 20 : 0)
        .background {
            if !isEmbeddedComposer {
                AppSemanticColors.surface.ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isEmbeddedComposer {
                bottomBar
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .modifier(SheetPresentationBackgroundModifier(isEnabled: !isEmbeddedComposer))
    }

    private var sheetEditorField: some View {
        TextEditor(text: $title)
            .font(.system(size: 22, weight: .regular, design: .rounded))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .background(AppSemanticColors.surface)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, pendingImages.isEmpty ? 20 : 12)
            .focused($isEditorFocused)
    }

    private func morphEditorPlaceholder(
        fieldHorizontalPadding: CGFloat,
        fieldTopPadding: CGFloat
    ) -> some View {
        inlineEditorPlaceholderLabel(
            fieldHorizontalPadding: fieldHorizontalPadding,
            fieldTopPadding: fieldTopPadding,
            fieldBottomPadding: 0
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func inlineEditorPlaceholderLabel(
        fieldHorizontalPadding: CGFloat,
        fieldTopPadding: CGFloat,
        fieldBottomPadding: CGFloat
    ) -> some View {
        Text("What do you want to do?")
            .foregroundStyle(isMorphShell ? Color.secondary.opacity(0.42) : .secondary)
            .font(.system(size: 20, weight: .regular, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, fieldHorizontalPadding)
            .padding(.top, fieldTopPadding)
            .padding(.bottom, fieldBottomPadding)
    }

    private var editorMaxHeight: CGFloat { 120 }

    private var morphEditorTextBottomInset: CGFloat { Self.morphAccessoryRowHeight }

    private var inlineEditorField: some View {
        let fieldHorizontalPadding: CGFloat = isMorphShell ? 0 : 14
        let fieldTopPadding: CGFloat = isMorphShell ? 0 : 12
        let fieldBottomPadding: CGFloat = isMorphShell ? 0 : 12
        let morphTextHeight = Self.morphTextAreaHeight

        let textStack = ZStack(alignment: .topLeading) {
            TextEditor(text: $title)
                .font(.system(size: 20, weight: .regular, design: .rounded))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .frame(
                    minHeight: isMorphShell ? morphTextHeight : Self.inlineEditorMinHeight,
                    maxHeight: isMorphShell ? morphTextHeight : editorMaxHeight,
                    alignment: .topLeading
                )
                .padding(.horizontal, fieldHorizontalPadding)
                .padding(.top, fieldTopPadding)
                .padding(.bottom, fieldBottomPadding)
                .focused($isEditorFocused)
                .opacity(isEditorFocused || !isTitleEmpty ? 1 : 0.02)
                .allowsHitTesting(isEditorFocused)
                .scrollDisabled(isMorphShell && !isEditorFocused)

            if !isEditorFocused && isTitleEmpty {
                if isMorphShell {
                    morphEditorPlaceholder(
                        fieldHorizontalPadding: fieldHorizontalPadding,
                        fieldTopPadding: fieldTopPadding
                    )
                } else {
                    Button {
                        playLightHaptic()
                        isEditorFocused = true
                    } label: {
                        inlineEditorPlaceholderLabel(
                            fieldHorizontalPadding: fieldHorizontalPadding,
                            fieldTopPadding: fieldTopPadding,
                            fieldBottomPadding: fieldBottomPadding
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Self.inlineEditorMinHeight,
                        alignment: .topLeading
                    )
                    .contentShape(Rectangle())
                    .accessibilityLabel("Task title")
                    .accessibilityHint("Double tap to edit")
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: isMorphShell ? .infinity : nil,
            alignment: .topLeading
        )
        .overlay {
            if !isEditorFocused && (isMorphShell || !isTitleEmpty) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        playLightHaptic()
                        isEditorFocused = true
                    }
                    .accessibilityLabel("Task title")
                    .accessibilityHint("Double tap to edit")
            }
        }

        return Group {
            if isMorphShell {
                VStack(spacing: 0) {
                    textStack
                        .frame(height: morphTextHeight)
                    morphEditorAccessory
                        .frame(height: Self.morphAccessoryRowHeight, alignment: .bottom)
                }
                .frame(height: Self.morphEditorHeight)
            } else {
                textStack
                    .background(
                        AppSemanticColors.elevatedSurface,
                        in: RoundedRectangle(cornerRadius: Self.inlineEditorCornerRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.inlineEditorCornerRadius, style: .continuous)
                            .strokeBorder(AppSemanticColors.separator.opacity(0.45), lineWidth: 1)
                    }
            }
        }
    }

    private var morphEditorAccessory: some View {
        let isVoiceActive = showsMorphVoiceActiveUI

        return HStack(spacing: 8) {
            if !isVoiceActive {
                HStack(spacing: 8) {
                    cameraButton
                    photoButton
                }

                Spacer(minLength: 0)
            }

            morphVoiceControl
                .frame(maxWidth: isVoiceActive ? .infinity : nil, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isVoiceActive)
    }

    private var morphVoiceControl: some View {
        let isRecording = showsMorphRecordingUI
        let isTranscribingNow = isTranscribing
        let isActive = isRecording || isTranscribingNow
        let shellHeight = isActive
            ? Self.morphVoiceControlActiveHeight
            : Self.morphVoiceControlIdleHeight
        let trailingSlotWidth = Self.morphVoiceControlIdleHeight
        let recordingTrailingReserve =
            Self.morphRecordingButtonSize
            + Self.morphVoiceControlActiveInset
            + Self.morphRecordingCheckWaveformGap

        return ZStack(alignment: .trailing) {
            if isActive {
                HStack(spacing: 8) {
                    if isRecording {
                        morphRecordingCancelButton

                        if voice.isRecording {
                            WaveformView(levels: voice.levels)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .environment(\.colorScheme, .dark)
                                .transition(.opacity)
                        } else {
                            Spacer(minLength: 0)
                                .frame(height: 28)
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .frame(width: Self.morphRecordingButtonSize, height: Self.morphRecordingButtonSize)

                            Text("Transcribing…")
                                .font(.system(.body, design: .rounded).weight(.medium))
                                .foregroundStyle(.white)

                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.leading, Self.morphVoiceControlActiveInset)
                .padding(.trailing, isRecording ? recordingTrailingReserve : Self.morphVoiceControlActiveInset)
            }

            Group {
                if !isActive {
                    Button {
                        beginRecording()
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: trailingSlotWidth, height: shellHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Record voice note")
                } else if isRecording {
                    morphRecordingTrailingControl(shellHeight: shellHeight)
                }
            }
        }
        .frame(height: shellHeight)
        .frame(maxWidth: isActive ? .infinity : trailingSlotWidth, alignment: .trailing)
        .background(Color.black, in: Capsule())
        .clipped()
        .accessibilityElement(children: .contain)
    }

    private func morphRecordingTrailingControl(shellHeight: CGFloat) -> some View {
        ZStack {
            if voice.isRecording {
                morphRecordingConfirmButton
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .frame(width: Self.morphRecordingButtonSize, height: Self.morphRecordingButtonSize)
                    .transition(.opacity)
                    .accessibilityLabel("Starting recording")
            }
        }
        .padding(.trailing, Self.morphVoiceControlActiveInset)
        .frame(width: Self.morphRecordingButtonSize, height: shellHeight)
        .animation(.easeOut(duration: 0.15), value: voice.isRecording)
    }

    private var morphRecordingCancelButton: some View {
        Button {
            playLightHaptic()
            cancelRecording()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: Self.morphRecordingButtonSize, height: Self.morphRecordingButtonSize)
                .background(Color.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel recording")
    }

    private var morphRecordingConfirmButton: some View {
        Button {
            playLightHaptic()
            Task { await acceptRecording() }
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: Self.morphRecordingButtonSize, height: Self.morphRecordingButtonSize)
                .background(Color.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use recording")
    }

    private var topBar: some View {
        Group {
            if isMorphShell {
                VStack(spacing: 0) {
                    HStack {
                        Text("New Task")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))

                        Spacer()

                        createButton
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, horizontalPadding)
                    .padding(.bottom, 10)

                    Rectangle()
                        .fill(AppSemanticColors.separator.opacity(0.4))
                        .frame(height: 1.5)
                }
            } else if isEmbeddedComposer {
                HStack {
                    Text("New Task")
                        .font(.system(.headline, design: .rounded).weight(.semibold))

                    Spacer()

                    createButton
                }
            } else {
                ZStack {
                    Text("New Task")
                        .font(.system(.headline, design: .rounded).weight(.semibold))

                    HStack {
                        Button {
                            playLightHaptic()
                            onCancel()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .frame(width: 34, height: 34)
                                .background(AppSemanticColors.neutralFill, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")

                        Spacer()

                        createButton
                    }
                }
            }
        }
        .padding(.horizontal, isMorphShell ? 0 : horizontalPadding)
        .padding(.top, isEmbeddedComposer && !isMorphShell ? 14 : (!isEmbeddedComposer ? 18 : 0))
        .padding(.bottom, isEmbeddedComposer && !isMorphShell ? 8 : (!isEmbeddedComposer ? 12 : 0))
        .background(isEmbeddedComposer ? Color.clear : AppSemanticColors.surface)
    }

    private var createButton: some View {
        Button {
            beginSave()
        } label: {
            Text("Create")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(canCreate ? .white : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(canCreate ? Color.blue : AppSemanticColors.neutralFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canCreate)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { item in
                    attachmentTile(for: item)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 4)
        }
    }

    private func attachmentTile(for item: PendingImage) -> some View {
        let isRemoving = removingAttachmentIDs.contains(item.id)

        return PendingAttachmentTile(
            image: item.image,
            onRemove: { remove(item) },
            onTap: isRemoving ? nil : { preview = PreviewItem(image: item.image) }
        )
        .scaleEffect(isRemoving ? 0.82 : 1)
        .opacity(isRemoving ? 0 : 1)
        .allowsHitTesting(!isRemoving)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: isEmbeddedComposer ? 10 : 12) {
            voiceControl
                .padding(.horizontal, horizontalPadding)

            if !isEmbeddedComposer {
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
                                    .background(AppSemanticColors.neutralFill, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(voice.isRecording || isTranscribing)
                            .opacity(voice.isRecording || isTranscribing ? 0.4 : 1)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
            }
        }
        .padding(.top, isEmbeddedComposer ? 8 : 10)
        .padding(.bottom, isEmbeddedComposer ? 14 : 10)
        .background(isEmbeddedComposer ? Color.clear : AppSemanticColors.surface)
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
            beginRecording()
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
            openCamera()
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(AppSemanticColors.neutralFill, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canAddMoreAttachments)
        .opacity(canAddMoreAttachments ? 1 : 0.4)
        .accessibilityLabel("Take a photo")
    }

    private var photoButton: some View {
        Button {
            openPhotoLibrary()
        } label: {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(AppSemanticColors.neutralFill, in: Circle())
        }
        .buttonStyle(.plain)
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
                    .foregroundStyle(AppSemanticColors.mutedChrome)
                    .frame(width: 40, height: 40)
                    .background(AppSemanticColors.neutralFillStrong, in: Circle())
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
                    .recordingConfirmButtonChrome()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use recording")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(AppSemanticColors.neutralFill, in: Capsule())
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
        .background(AppSemanticColors.neutralFill, in: Capsule())
        .transition(.opacity)
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isTranscribing
            && !voice.isRecording
    }

    private var canAddMoreAttachments: Bool {
        pendingImages.count < AddTodoView.maxAttachments
    }

    private func beginSave() {
        guard canCreate else { return }
        playLightHaptic()

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let imagesToUpload = pendingImages
        onCancel()

        Task {
            do {
                let todo = try await TodosAPI.create(
                    title: trimmedTitle,
                    detail: nil,
                    userID: userID
                )
                await uploadPendingAttachments(
                    forTodoID: todo.id,
                    images: imagesToUpload
                )
                onCreated(todo)
            } catch {
                print("[AddTodoView] create failed: \(error)")
            }
        }
    }

    private func playLightHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func uploadPendingAttachments(
        forTodoID todoID: UUID,
        images: [PendingImage]
    ) async {
        guard !images.isEmpty else { return }
        for item in images {
            do {
                _ = try await AttachmentsAPI.upload(
                    image: item.image,
                    todoID: todoID,
                    userID: userID
                )
            } catch {
                print("[AddTodoView] attachment upload failed: \(error)")
            }
        }
    }

    // MARK: - Launch actions

    private func performLaunchAction() {
        switch initialAction {
        case .note:
            if !isEmbeddedComposer {
                isEditorFocused = true
            }
        case .recordVoice:
            beginRecording()
        case .camera:
            openCamera()
        case .photoLibrary:
            openPhotoLibrary()
        }
    }

    private func openCamera() {
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
    }

    private func openPhotoLibrary() {
        guard canAddMoreAttachments else { return }
        error = nil
        isEditorFocused = false
        showPhotoPicker = true
    }

    // MARK: - Voice flow

    private func beginRecording() {
        VoiceRecordingLog.markTapOrigin()
        isEditorFocused = false
        playLightHaptic()
        VoiceRecordingLog.event("haptic_fired")

        recordingStartTask?.cancel()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            isRecordingUIActive = true
        }
        VoiceRecordingLog.event("ui_recording_active")

        recordingStartTask = Task(priority: .userInitiated) {
            let delay = UInt64(Self.morphRecordingAudioStartDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            VoiceRecordingLog.event("recording_animation_complete")
            await startRecording()
        }
    }

    private func startRecording() async {
        VoiceRecordingLog.event("start_recording_task")
        error = nil
        do {
            try await voice.start()
            VoiceRecordingLog.event("voice_start_complete")
            withAnimation(.easeOut(duration: 0.15)) {
                isRecordingUIActive = false
            }
        } catch {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                isRecordingUIActive = false
            }
            VoiceRecordingLog.event("voice_start_failed")
            self.error = error.localizedDescription
        }
        VoiceRecordingLog.reset()
    }

    private func cancelRecording() {
        recordingStartTask?.cancel()
        recordingStartTask = nil
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            isRecordingUIActive = false
        }
        VoiceRecordingLog.reset()
        voice.cancel()
        if !isEmbeddedComposer {
            isEditorFocused = true
        }
    }

    private func acceptRecording() async {
        guard let url = voice.stop() else {
            if !isEmbeddedComposer {
                isEditorFocused = true
            }
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
        withAnimation(Self.attachmentInsertAnimation) {
            pendingImages.append(PendingImage(id: UUID(), image: image))
        }
    }

    private func remove(_ item: PendingImage) {
        guard !removingAttachmentIDs.contains(item.id) else { return }
        playLightHaptic()
        withAnimation(Self.attachmentRemovalAnimation) {
            removingAttachmentIDs.insert(item.id)
        }
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.attachmentRemovalDuration * 1_000_000_000)
            )
            guard removingAttachmentIDs.contains(item.id) else { return }
            pendingImages.removeAll { $0.id == item.id }
            removingAttachmentIDs.remove(item.id)
        }
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

private struct SheetPresentationBackgroundModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.presentationBackground(AppSemanticColors.surface)
        } else {
            content
        }
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

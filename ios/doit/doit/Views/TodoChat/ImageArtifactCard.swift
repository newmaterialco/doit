import SwiftUI

/// Inline preview card for `image` artifacts — Figma exports, generated
/// mockups, browser screenshots, charts, or any visual deliverable the
/// runner uploaded to the private `todo-images` Supabase Storage bucket.
///
/// Layout:
///   ┌──────────────────────────────────────────┐
///   │ [logo]  Title                            │
///   │                                          │
///   │ ┌─────────────────────────────────────┐  │
///   │ │                                     │  │
///   │ │           image preview             │  │
///   │ │                                     │  │
///   │ └─────────────────────────────────────┘  │
///   │ Optional caption / prompt                │
///   └──────────────────────────────────────────┘
///
/// State is held by `ImageLoaderState` so SwiftUI re-renders cleanly when
/// the realtime hub upserts a new storage path on the same artifact key
/// (e.g. the agent iterating on a Figma export). The card always shows
/// the latest signed URL and forgets cached state when the underlying
/// path changes.
struct ImageArtifactCard: View {
    let artifact: TodoArtifact

    @State private var state = ImageLoaderState()
    @State private var isPresentingFullScreen: Bool = false

    var body: some View {
        let ref = artifact.image
        VStack(alignment: .leading, spacing: 12) {
            header
            preview(ref: ref)
            if let caption = caption(ref: ref), !caption.isEmpty {
                TruncatableArtifactText(
                    text: caption,
                    lineLimit: 3,
                    font: .system(size: 13, weight: .regular, design: .rounded),
                    foregroundStyle: .secondary
                )
            }
            if let err = state.loadError {
                Text(err)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(ArtifactCardLayout.contentPadding)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: ref?.storagePath ?? "") {
            await state.load(from: artifact)
        }
        .sheet(isPresented: $isPresentingFullScreen) {
            if let url = state.signedURL {
                ImageArtifactFullScreen(url: url, title: artifact.title)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ArtifactCardLeadingIcon { providerIcon }
            Text(artifact.title ?? defaultTitle)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let slug = artifact.image?.provider, !slug.isEmpty,
           UIImage(named: slug) != nil {
            ConnectionLogo(slug: slug)
        } else {
            Image(systemName: "photo")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func preview(ref: TodoArtifact.ImageRef?) -> some View {
        let aspect = aspectRatio(ref: ref)
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.04))
            if let url = state.signedURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.regular)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .clipShape(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                    case .failure:
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(.secondary)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
            } else if state.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.regular)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            guard state.signedURL != nil else { return }
            isPresentingFullScreen = true
        }
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(accessibilityLabel(ref: ref))
    }

    private func aspectRatio(ref: TodoArtifact.ImageRef?) -> CGFloat {
        if let w = ref?.width, let h = ref?.height, w > 0, h > 0 {
            return CGFloat(w / h)
        }
        // Default to a 4:3 placeholder so the card reserves a reasonable
        // amount of vertical space before the bytes load and we can
        // measure the real aspect.
        return 4.0 / 3.0
    }

    private func caption(ref: TodoArtifact.ImageRef?) -> String? {
        let candidates = [
            ref?.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            ref?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    private var defaultTitle: String {
        switch artifact.image?.provider?.lowercased() {
        case "figma": return "Figma export"
        case "browser": return "Screenshot"
        case "openai", "dalle", "dall-e": return "Generated image"
        default: return "Image"
        }
    }

    private func accessibilityLabel(ref: TodoArtifact.ImageRef?) -> String {
        if let desc = caption(ref: ref) { return desc }
        return artifact.title ?? defaultTitle
    }
}

/// Full-screen viewer presented when the user taps the inline preview.
/// Reuses `AsyncImage` so the cached signed URL doesn't need to be
/// re-signed; pinch-to-zoom is left to a future iteration.
private struct ImageArtifactFullScreen: View {
    let url: URL
    let title: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().controlSize(.large)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            .navigationTitle(title ?? "Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Loader state

/// Holds the signed URL for one image artifact card. Lives for as long
/// as the card is on screen; refetches whenever the underlying storage
/// path changes (e.g. realtime upsert with a new iteration).
@MainActor
@Observable
final class ImageLoaderState {
    /// Signed URL for the latest image. `nil` while loading or after a
    /// load failure; `AsyncImage` is short-circuited in that case.
    var signedURL: URL?

    /// True while a sign request is in flight. Drives a spinner inside
    /// the preview frame so the user gets a loading affordance.
    var isLoading: Bool = false

    /// Last error from `load(from:)`, surfaced under the preview when
    /// the card has nothing else to show.
    var loadError: String?

    private var loadedStoragePath: String?

    /// Resolve a fresh signed URL for one artifact. Idempotent against
    /// re-runs with the same storage path — the existing URL is reused.
    func load(from artifact: TodoArtifact) async {
        guard let ref = artifact.image else {
            loadError = "Image metadata missing."
            return
        }
        if loadedStoragePath == ref.storagePath, signedURL != nil {
            return
        }
        loadedStoragePath = ref.storagePath
        isLoading = true
        loadError = nil
        signedURL = nil
        do {
            let url = try await ImageArtifactsAPI.signedURL(
                storagePath: ref.storagePath
            )
            signedURL = url
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

import SwiftUI

private enum AttachmentTileMetrics {
    static let defaultSize: CGFloat = 64
}

/// Shared visual treatment for an attachment thumbnail tile. When
/// `onRemove` is non-nil, a small circular `x` is overlaid in the
/// top-right (composer / new-task flows). Chat history passes `nil` so
/// sent images are read-only previews.
struct AttachmentTile<Thumbnail: View>: View {
    let size: CGFloat
    let thumbnail: Thumbnail
    let onRemove: (() -> Void)?
    let onTap: (() -> Void)?

    init(
        size: CGFloat = AttachmentTileMetrics.defaultSize,
        @ViewBuilder thumbnail: () -> Thumbnail,
        onRemove: (() -> Void)? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.size = size
        self.thumbnail = thumbnail()
        self.onRemove = onRemove
        self.onTap = onTap
    }

    private var removeBadgeInset: CGFloat { onRemove == nil ? 0 : 11 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                onTap?()
            } label: {
                thumbnail
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
            .padding(.top, removeBadgeInset)
            .padding(.trailing, removeBadgeInset)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.black.opacity(0.78), in: Circle())
                        .overlay(
                            Circle().stroke(Color.white, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove image")
            }
        }
        .frame(
            width: size + removeBadgeInset,
            height: size + removeBadgeInset,
            alignment: .topLeading
        )
    }
}

/// A tile rendering a `UIImage` we have in memory — used by the New Task
/// sheet before the todo (and therefore the upload) exists.
struct PendingAttachmentTile: View {
    let image: UIImage
    let onRemove: () -> Void
    let onTap: (() -> Void)?

    var body: some View {
        AttachmentTile(
            thumbnail: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            },
            onRemove: onRemove,
            onTap: onTap
        )
    }
}

/// A tile rendering a server-stored attachment via `AsyncImage` against a
/// short-lived signed URL. The URL is fetched once and cached on the parent
/// view; when it expires the parent re-fetches.
struct RemoteAttachmentTile: View {
    let signedURL: URL?
    var size: CGFloat = AttachmentTileMetrics.defaultSize
    let onRemove: (() -> Void)?
    let onTap: (() -> Void)?

    var body: some View {
        AttachmentTile(
            size: size,
            thumbnail: {
                Group {
                    if let signedURL {
                        AsyncImage(url: signedURL) { phase in
                            switch phase {
                            case .empty:
                                placeholder
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            case .failure:
                                placeholder
                            @unknown default:
                                placeholder
                            }
                        }
                    } else {
                        placeholder
                    }
                }
            },
            onRemove: onRemove,
            onTap: onTap
        )
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.12)
            Image(systemName: "photo")
                .font(.system(size: 18, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

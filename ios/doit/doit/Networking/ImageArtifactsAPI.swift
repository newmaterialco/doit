import Foundation
import Supabase

/// Signs paths in the private `todo-images` Supabase Storage bucket so the
/// detail-view image card can hand a short-lived URL to `AsyncImage`.
///
/// The runner uploads each image at `<user_id>/<todo_id>/<uuid>.<ext>`
/// with service_role; the per-user folder RLS policies installed by
/// `supabase/migrations/20240601000018_todo_image_artifacts.sql` then let
/// the signed-in user fetch their own image via this signer.
@MainActor
enum ImageArtifactsAPI {
    /// Bucket id used for every image artifact. Keep in sync with
    /// `db.upload_todo_image` and the storage policies in
    /// `supabase/migrations/20240601000018_todo_image_artifacts.sql`.
    static let bucketID = "todo-images"

    /// Sign a stored image object. The default TTL (1 hour) matches the
    /// other on-demand signers in the app and is long enough for a
    /// single render plus a couple of zoom/share interactions without
    /// re-signing.
    static func signedURL(
        storagePath: String,
        expiresIn seconds: Int = 60 * 60
    ) async throws -> URL {
        try await Supa.client.storage
            .from(bucketID)
            .createSignedURL(
                path: storagePath,
                expiresIn: seconds
            )
    }

    /// Convenience overload that takes a parsed `TodoArtifact` and signs
    /// its embedded `image.storagePath`. Throws `ImageArtifactError.missing`
    /// when the artifact doesn't actually carry image metadata so callers
    /// can surface an inline error instead of crashing on a force-unwrap.
    static func signedURL(
        for artifact: TodoArtifact,
        expiresIn seconds: Int = 60 * 60
    ) async throws -> URL {
        guard let ref = artifact.image else {
            throw ImageArtifactError.missing
        }
        return try await signedURL(
            storagePath: ref.storagePath,
            expiresIn: seconds
        )
    }
}

enum ImageArtifactError: LocalizedError {
    case missing

    var errorDescription: String? {
        switch self {
        case .missing:
            return "This task has no image attached."
        }
    }
}

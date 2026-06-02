import Foundation
import Supabase

/// Signs paths in the private `todo-audio` Supabase Storage bucket so the
/// detail-view audio player can hand a short-lived URL to `AVPlayer`.
///
/// The runner uploads each TTS-generated file at
/// `<user_id>/<todo_id>/<uuid>.<ext>` with service_role; the per-user
/// folder RLS policies installed by
/// `supabase/migrations/20240601000014_todo_audio_artifacts.sql` then let
/// the signed-in user fetch their own audio via this signer.
@MainActor
enum AudioArtifactsAPI {
    /// Bucket id used for every audio artifact. Keep in sync with
    /// `db.upload_todo_audio` and the storage policies in
    /// `supabase/migrations/20240601000014_todo_audio_artifacts.sql`.
    static let bucketID = "todo-audio"

    /// Sign a stored audio object. The default TTL (1 hour) matches the
    /// other on-demand signers in the app and is long enough for a
    /// single listen plus a couple of replays without re-signing.
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
    /// its embedded `audio.storagePath`. Throws `AudioArtifactError.missing`
    /// when the artifact doesn't actually carry audio metadata so callers
    /// can surface an inline error instead of crashing on a force-unwrap.
    static func signedURL(
        for artifact: TodoArtifact,
        expiresIn seconds: Int = 60 * 60
    ) async throws -> URL {
        guard let clip = artifact.audio else {
            throw AudioArtifactError.missing
        }
        return try await signedURL(
            storagePath: clip.storagePath,
            expiresIn: seconds
        )
    }
}

enum AudioArtifactError: LocalizedError {
    case missing

    var errorDescription: String? {
        switch self {
        case .missing:
            return "This task has no spoken summary attached."
        }
    }
}

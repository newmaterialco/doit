import Foundation
import Supabase

enum TranscriptionError: LocalizedError {
    case notAuthenticated
    case missingAudio
    case requestFailed(status: Int, body: String)
    case decodeFailed
    case empty

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You need to be signed in to transcribe audio."
        case .missingAudio:
            return "Couldn't find the recorded audio."
        case .requestFailed(_, let body):
            return body.isEmpty
                ? "Transcription failed. Please try again."
                : "Transcription failed: \(body)"
        case .decodeFailed:
            return "Couldn't read the transcription response."
        case .empty:
            return "We couldn't hear anything in that recording."
        }
    }
}

@MainActor
enum TranscriptionAPI {
    /// Uploads the audio file to the `transcribe-audio` Supabase Edge Function
    /// and returns the recognized text. The Whisper key never reaches the
    /// device — the function handles the OpenAI call server-side.
    static func transcribe(fileURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TranscriptionError.missingAudio
        }

        let session = try await Supa.client.auth.session
        let accessToken = session.accessToken

        let endpoint = SupabaseConfig.url
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("transcribe-audio")

        let boundary = "doit-boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let audioData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let body = makeMultipartBody(
            boundary: boundary,
            audioData: audioData,
            filename: filename,
            mimeType: "audio/m4a"
        )
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.decodeFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.requestFailed(
                status: http.statusCode,
                body: bodyString
            )
        }

        struct Resp: Decodable { let text: String }
        let parsed: Resp
        do {
            parsed = try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw TranscriptionError.decodeFailed
        }
        let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw TranscriptionError.empty
        }
        return text
    }

    private static func makeMultipartBody(
        boundary: String,
        audioData: Data,
        filename: String,
        mimeType: String
    ) -> Data {
        var body = Data()
        let boundaryPrefix = "--\(boundary)\r\n"
        body.append(boundaryPrefix.data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

import Foundation

/// Typed async HTTP client for the koom web backend.
///
/// All admin endpoints authenticate via `Authorization: Bearer <secret>`
/// where `<secret>` is the shared admin credential stored in
/// Keychain. The secret is passed into the client at construction
/// time, so each call does a single Keychain read at the call site
/// that builds the client — not on every request.
///
/// The public API has three methods matching the backend contract:
///
///   - `initUpload(...)`       → POST /api/admin/uploads/init
///   - `uploadFile(...)`       → PUT <presigned-url>  (goes directly
///                                to R2, no bearer header on this one)
///   - `completeUpload(id:)`   → POST /api/admin/uploads/complete
///
/// Progress during `uploadFile` is reported to an optional callback
/// via a `URLSessionTaskDelegate` so the UI can render a real
/// progress bar tracking the streaming PUT.
struct KoomAPI {
    let backendURL: URL
    let adminSecret: String

    // MARK: - Request / response models

    struct InitUploadRequest: Encodable {
        let originalFilename: String
        let contentType: String
        let sizeBytes: Int64
        let durationSeconds: Double?
        let title: String?
    }

    struct InitUploadResponse: Decodable {
        let recordingId: String
        let upload: UploadInstructions
        let shareUrl: String

        struct UploadInstructions: Decodable {
            let strategy: String
            let method: String
            let url: String
            let headers: [String: String]?
        }
    }

    struct CompleteUploadRequest: Encodable {
        let recordingId: String
    }

    struct CompleteUploadResponse: Decodable {
        let recordingId: String
        let shareUrl: String
    }

    struct DiffFilenamesRequest: Encodable {
        let filenames: [String]
    }

    struct DiffFilenamesResponse: Decodable {
        let uploaded: [String]
        let missing: [String]
    }

    struct UpdateTitleRequest: Encodable {
        let title: String?
    }

    struct UpdateTitleResponse: Decodable {
        let ok: Bool
        let title: String?
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case unauthorized
        case badStatus(code: Int, body: String)
        case invalidResponse
        case invalidUploadURL(String)
        case missingBackendURL
        case missingAdminSecret
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "Admin secret rejected by the server. Check koom settings (Cmd+,) and re-enter the secret."
            case .badStatus(let code, let body):
                return "Server returned HTTP \(code). \(body.isEmpty ? "" : "Body: \(body)")"
            case .invalidResponse:
                return "Server returned an unexpected response."
            case .invalidUploadURL(let urlString):
                return "Server returned an invalid upload URL: \(urlString)"
            case .missingBackendURL:
                return "koom backend URL is not configured. Open Settings (Cmd+,) to set it."
            case .missingAdminSecret:
                return "koom admin secret is not configured. Open Settings (Cmd+,) to set it."
            case .network(let err):
                return "Network error: \(err.localizedDescription)"
            }
        }
    }

    // MARK: - API calls

    func initUpload(
        originalFilename: String,
        contentType: String,
        sizeBytes: Int64,
        durationSeconds: Double?,
        title: String?
    ) async throws -> InitUploadResponse {
        let body = InitUploadRequest(
            originalFilename: originalFilename,
            contentType: contentType,
            sizeBytes: sizeBytes,
            durationSeconds: durationSeconds,
            title: title
        )
        return try await post(
            path: "api/admin/uploads/init",
            body: body,
            responseType: InitUploadResponse.self
        )
    }

    func completeUpload(
        recordingId: String
    ) async throws -> CompleteUploadResponse {
        let body = CompleteUploadRequest(recordingId: recordingId)
        return try await post(
            path: "api/admin/uploads/complete",
            body: body,
            responseType: CompleteUploadResponse.self
        )
    }

    /// Given a list of local filenames, asks the backend which ones
    /// correspond to complete recordings already in the database.
    /// Used by the catch-up feature to figure out which local files
    /// still need to be uploaded. The server dedupes, filters empty
    /// strings, and treats pending (not-yet-complete) rows as
    /// missing so the catch-up retries interrupted uploads.
    func diffFilenames(
        _ filenames: [String]
    ) async throws -> DiffFilenamesResponse {
        let body = DiffFilenamesRequest(filenames: filenames)
        return try await post(
            path: "api/admin/uploads/diff",
            body: body,
            responseType: DiffFilenamesResponse.self
        )
    }

    /// Overwrite (or clear) the `title` column of a recording row.
    /// Pass `nil` to clear. Used by the auto-titler to land a
    /// short generated title as soon as Whisper + Ollama finish,
    /// even if the upload itself is still in flight.
    func updateRecordingTitle(
        recordingId: String,
        title: String?
    ) async throws -> UpdateTitleResponse {
        let body = UpdateTitleRequest(title: title)
        return try await send(
            method: "PATCH",
            path: "api/admin/recordings/\(recordingId)",
            body: body,
            responseType: UpdateTitleResponse.self
        )
    }

    /// Upload the file at `fileURL` to the given presigned URL via
    /// PUT. Progress is reported to `progressHandler` as a value in
    /// [0.0, 1.0]. This call does NOT add the `Authorization` header
    /// — the presigned URL is already signed by the backend and the
    /// admin secret must not be sent to the storage backend.
    ///
    /// `progressHandler` must be `@Sendable` because URLSession
    /// invokes it from a background delegate queue, not from the
    /// caller's isolation domain.
    func uploadFile(
        fileURL: URL,
        to urlString: String,
        method: String,
        headers: [String: String],
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = URL(string: urlString) else {
            throw APIError.invalidUploadURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let delegate = UploadProgressDelegate(onProgress: progressHandler)

        do {
            let (_, response) = try await URLSession.shared.upload(
                for: request,
                fromFile: fileURL,
                delegate: delegate
            )
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw APIError.badStatus(code: http.statusCode, body: "")
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.network(error)
        }
    }

    // MARK: - Internals

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        responseType: Response.Type
    ) async throws -> Response {
        try await send(
            method: "POST",
            path: path,
            body: body,
            responseType: responseType
        )
    }

    private func send<Request: Encodable, Response: Decodable>(
        method: String,
        path: String,
        body: Request,
        responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: backendURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(adminSecret)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if http.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw APIError.badStatus(code: http.statusCode, body: bodyText)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}

/// URLSession delegate that forwards upload byte progress to a
/// closure. One instance per upload task. Thread-safe because
/// URLSessionTaskDelegate callbacks happen serially per task.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction =
            Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(min(max(fraction, 0.0), 1.0))
    }
}

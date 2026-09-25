import Foundation
import HTTPTypes
import OpenAPIRuntime

extension HTTPField.Name {
    /// Minted by the server for every request and stored on every event it produces.
    public static let xRequestId = HTTPField.Name("X-Request-Id")!
}

/// An ADR-12 error response: a stable `code` to branch on and a `message` that is safe to show.
public struct LedgerWriterError: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: Int
    /// Stable, machine-readable code, e.g. `UNBALANCED_ENTRY`, `CONCURRENCY_CONFLICT`.
    public let code: String
    public let message: String?
    /// The request's `X-Request-Id`, for support and audit questions.
    public let requestId: String?

    public init(status: Int, code: String, message: String?, requestId: String?) {
        self.status = status
        self.code = code
        self.message = message
        self.requestId = requestId
    }

    /// `CONCURRENCY_CONFLICT` is an expected race, not a failure: re-read and retry.
    public var isRetryable: Bool { code == "CONCURRENCY_CONFLICT" }

    public var description: String {
        var text = "\(code) (HTTP \(status))"
        if let message { text += ": \(message)" }
        if let requestId { text += " [request id \(requestId)]" }
        return text
    }
}

struct BearerTokenMiddleware: ClientMiddleware {
    let token: String

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        return try await next(request, body, baseURL)
    }
}

/// Records every response's request id, and turns any 4xx/5xx into a `LedgerWriterError`.
struct ResponseMiddleware: ClientMiddleware {
    let recorder: RequestIDRecorder

    private struct ErrorBody: Decodable {
        let error: String
        let message: String?
    }

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        let requestId = response.headerFields[.xRequestId]
        recorder.value = requestId

        guard response.status.code >= 400 else { return (response, responseBody) }

        var decoded: ErrorBody?
        if let responseBody {
            let data = try await Data(collecting: responseBody, upTo: 64 * 1024)
            decoded = try? JSONDecoder().decode(ErrorBody.self, from: data)
        }
        throw LedgerWriterError(
            status: response.status.code,
            code: decoded?.error ?? "HTTP_\(response.status.code)",
            message: decoded?.message,
            requestId: requestId
        )
    }
}

final class RequestIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

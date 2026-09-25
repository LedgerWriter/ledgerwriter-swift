import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// A LedgerWriter API client for one tenant, authenticated with an API token.
///
/// Wraps the client generated from `openapi.yaml` (still available as ``client``) with:
/// bearer-token auth, ADR-12 error bodies surfaced as ``LedgerWriterError``, and the
/// server-minted `X-Request-Id` of the most recent response (``lastRequestId``) -- the same id
/// stored on every event that request produced, so it can be quoted in support and audit
/// questions.
public struct LedgerWriter: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.ledgerwriter.com")!

    /// The generated client, for anything these conveniences don't cover.
    public let client: Client
    private let recorder = RequestIDRecorder()

    public init(
        token: String,
        baseURL: URL = LedgerWriter.defaultBaseURL,
        transport: any ClientTransport = URLSessionTransport()
    ) {
        client = Client(
            serverURL: baseURL,
            // The server emits JavaScript toISOString() timestamps, which carry milliseconds.
            configuration: Configuration(dateTranscoder: .iso8601WithFractionalSeconds),
            transport: transport,
            middlewares: [
                BearerTokenMiddleware(token: token),
                ResponseMiddleware(recorder: recorder),
            ]
        )
    }

    /// The `X-Request-Id` of the most recent response received through this client.
    public var lastRequestId: String? { recorder.value }

    public func ledgerAccounts() async throws -> [Components.Schemas.LedgerAccount] {
        try await unwrapped { try await client.listLedgerAccounts().ok.body.json }
    }

    public func journalEntries() async throws -> [Components.Schemas.JournalEntrySummary] {
        try await unwrapped { try await client.listJournalEntries().ok.body.json }
    }

    public func accountBalances() async throws -> [Components.Schemas.AccountBalance] {
        try await unwrapped { try await client.listAccountBalances().ok.body.json }
    }

    public func trialBalance() async throws -> Components.Schemas.TrialBalance {
        try await unwrapped { try await client.getTrialBalance().ok.body.json }
    }

    /// Issues one command. Pass an `idempotencyKey` to make retries safe: replaying the same key
    /// returns the original result instead of applying the command twice.
    public func issue(
        _ command: Components.Schemas.CommandRequest,
        idempotencyKey: String? = nil
    ) async throws -> Operations.IssueCommand.Output {
        try await unwrapped {
            try await client.issueCommand(
                headers: .init(idempotencyKey: idempotencyKey),
                body: .json(command)
            )
        }
    }

    /// Errors thrown inside middleware reach callers wrapped in the runtime's `ClientError`;
    /// unwrap ours so callers can `catch let error as LedgerWriterError`.
    private func unwrapped<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as ClientError {
            if let ledgerWriterError = error.underlyingError as? LedgerWriterError {
                throw ledgerWriterError
            }
            throw error
        }
    }
}

extension Components.Schemas.CommandRequest {
    /// Builds a command from its JSON form, `{ "type": ..., "payload": { ... } }` -- the same
    /// shape `POST /commands` accepts.
    public static func fromJSON(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// Builds a command from a type name and payload fields.
    public static func make(type: String, payload: [String: Any]) throws -> Self {
        try fromJSON(JSONSerialization.data(withJSONObject: ["type": type, "payload": payload]))
    }
}

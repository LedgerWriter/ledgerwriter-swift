import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// A LedgerWriter API client for one tenant, authenticated with an API token.
///
/// Everything an app needs goes through this type and the public models in `Models.swift`
/// and `Money.swift`. The client generated from `openapi.yaml` is internal to the SDK, so
/// apps never depend on generated code. On top of that client this adds: bearer-token auth,
/// ADR-12 error bodies surfaced as ``LedgerWriterError``, and the server-minted `X-Request-Id`
/// of the most recent response (``lastRequestId``) -- the same id stored on every event that
/// request produced, so it can be quoted in support and audit questions.
public struct LedgerWriter: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.ledgerwriter.com")!

    let client: Client
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

    // MARK: Queries

    public func ledgerAccounts() async throws -> [LedgerAccount] {
        try Self.convert(try await unwrapped { try await client.listLedgerAccounts().ok.body.json })
    }

    /// Posted entries, newest first. Pending entries aren't included.
    public func journalEntries() async throws -> [JournalEntry] {
        try Self.convert(try await unwrapped { try await client.listJournalEntries().ok.body.json })
    }

    public func accountBalances() async throws -> [AccountBalance] {
        try Self.convert(try await unwrapped { try await client.listAccountBalances().ok.body.json })
    }

    public func trialBalance() async throws -> TrialBalance {
        try Self.convert(try await unwrapped { try await client.getTrialBalance().ok.body.json })
    }

    // MARK: Commands
    //
    // Pass an `idempotencyKey` to make a retry safe: replaying the same key returns the original
    // result instead of applying the command twice. Generate it once per user action.

    /// Posts a journal entry. Every line must be in the same currency. For a currency other than
    /// the tenant's functional currency, pass `exchangeRate` (functional units per one unit, e.g.
    /// `"1.0845"`), or leave it nil to book at the rate on file for `date`.
    public func postJournalEntry(
        date: String,
        memo: String,
        lines: [JournalEntryLine],
        exchangeRate: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> PostedEntry {
        var payload: [String: Any] = [
            "date": date,
            "memo": memo,
            "lines": lines.map { line in
                [
                    "accountId": line.accountId,
                    "debit": ["amount": line.debit.amount, "currency": line.debit.currency],
                    "credit": ["amount": line.credit.amount, "currency": line.credit.currency],
                ] as [String: Any]
            },
        ]
        if let exchangeRate { payload["exchangeRate"] = exchangeRate }
        let result = try await issue("PostJournalEntry", payload, idempotencyKey)
        guard let entryId = result.entryId,
            let status = result.status.flatMap(PostedEntry.Status.init(rawValue:))
        else { throw Self.unexpected("PostJournalEntry") }
        return PostedEntry(entryId: entryId, status: status)
    }

    /// Approves a pending entry, which posts it. Owner or bookkeeper only.
    public func approveJournalEntry(_ entryId: String, idempotencyKey: String? = nil) async throws {
        _ = try await issue("ApproveJournalEntry", ["entryId": entryId], idempotencyKey)
    }

    /// Rejects a pending entry; it never takes effect. Owner or bookkeeper only.
    public func rejectJournalEntry(_ entryId: String, idempotencyKey: String? = nil) async throws {
        _ = try await issue("RejectJournalEntry", ["entryId": entryId], idempotencyKey)
    }

    /// Reverses a posted entry. Owner or bookkeeper only.
    public func reverseJournalEntry(_ entryId: String, idempotencyKey: String? = nil) async throws {
        _ = try await issue("ReverseJournalEntry", ["entryId": entryId], idempotencyKey)
    }

    /// Opens a ledger account and returns its id. A cash account needs a `bankAccountType`.
    public func openLedgerAccount(
        name: String,
        type: AccountType,
        isCashAccount: Bool = false,
        bankAccountType: BankAccountType? = nil,
        idempotencyKey: String? = nil
    ) async throws -> String {
        var payload: [String: Any] = [
            "name": name, "accountType": type.rawValue, "isCashAccount": isCashAccount,
        ]
        if let bankAccountType { payload["bankAccountType"] = bankAccountType.rawValue }
        let result = try await issue("OpenLedgerAccount", payload, idempotencyKey)
        guard let accountId = result.accountId else { throw Self.unexpected("OpenLedgerAccount") }
        return accountId
    }

    public func renameLedgerAccount(
        _ accountId: String,
        to newName: String,
        idempotencyKey: String? = nil
    ) async throws {
        _ = try await issue(
            "RenameLedgerAccount", ["accountId": accountId, "newName": newName], idempotencyKey)
    }

    public func closeLedgerAccount(_ accountId: String, idempotencyKey: String? = nil) async throws {
        _ = try await issue("CloseLedgerAccount", ["accountId": accountId], idempotencyKey)
    }

    // MARK: Internals

    /// Every command result shape: AccountIdResult, EntryPostedResult, EntryStatusResult,
    /// EntryIdResult.
    struct CommandResult: Decodable {
        let accountId: String?
        let entryId: String?
        let status: String?
    }

    func issue(
        _ type: String,
        _ payload: [String: Any],
        _ idempotencyKey: String?
    ) async throws -> CommandResult {
        let command = try JSONDecoder().decode(
            Components.Schemas.CommandRequest.self,
            from: JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
        )
        let output = try await unwrapped {
            try await client.issueCommand(
                headers: .init(idempotencyKey: idempotencyKey),
                body: .json(command)
            )
        }
        switch output {
        case .ok(let applied): return try Self.convert(try applied.body.json)
        case .created(let created): return try Self.convert(try created.body.json)
        default: throw Self.unexpected(type)  // Error statuses already threw LedgerWriterError.
        }
    }

    /// Maps a generated value to the matching public model through its JSON form, so the two
    /// can't drift apart silently: a mismatch fails loudly in decoding (and in the tests).
    static func convert<From: Encodable, To: Decodable>(_ value: From) throws -> To {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(To.self, from: encoder.encode(value))
    }

    static func unexpected(_ command: String) -> LedgerWriterError {
        LedgerWriterError(
            status: 0,
            code: "UNEXPECTED_RESPONSE",
            message: "\(command) returned a response this SDK version doesn't recognize",
            requestId: nil
        )
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

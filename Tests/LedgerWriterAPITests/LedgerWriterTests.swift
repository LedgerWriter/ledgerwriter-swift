import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest

@testable import LedgerWriterAPI

/// Serves canned responses and records the requests it received.
final class MockTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    let respond: @Sendable (HTTPRequest) -> (HTTPResponse, String)

    init(respond: @escaping @Sendable (HTTPRequest) -> (HTTPResponse, String)) {
        self.respond = respond
    }

    var requests: [HTTPRequest] { lock.withLock { _requests } }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { _requests.append(request) }
        let (response, json) = respond(request)
        return (response, HTTPBody(json))
    }

    static func json(_ status: HTTPResponse.Status, _ body: String, requestId: String = "req-1") -> MockTransport {
        MockTransport { _ in
            (
                HTTPResponse(
                    status: status,
                    headerFields: [.contentType: "application/json", .xRequestId: requestId]
                ),
                body
            )
        }
    }
}

final class LedgerWriterTests: XCTestCase {
    func testSendsBearerTokenAndDecodesLedgerAccounts() async throws {
        let transport = MockTransport.json(
            .ok,
            """
            [{"tenantId":"t1","accountId":"a1","name":"Operating Cash","accountType":"asset",
              "isCashAccount":true,"bankAccountType":"checking","status":"open",
              "updatedAt":"2026-09-25T12:34:56.789Z"},
             {"tenantId":"t1","accountId":"a2","name":"Sales","accountType":"revenue",
              "isCashAccount":false,"bankAccountType":null,"status":"closed",
              "updatedAt":"2026-09-25T12:34:56.789Z"}]
            """
        )
        let ledgerWriter = LedgerWriter(token: "secret-token", transport: transport)

        let accounts = try await ledgerWriter.ledgerAccounts()

        XCTAssertEqual(accounts.map(\.name), ["Operating Cash", "Sales"])
        XCTAssertEqual(accounts.first?.accountType, .asset)
        XCTAssertEqual(accounts.last?.status, .closed)
        XCTAssertEqual(transport.requests.first?.headerFields[.authorization], "Bearer secret-token")
        XCTAssertEqual(ledgerWriter.lastRequestId, "req-1")
    }

    func testDecodesJournalEntriesAndTrialBalance() async throws {
        let entries = try await LedgerWriter(
            token: "t",
            transport: MockTransport.json(
                .ok,
                """
                [{"tenantId":"t1","entryId":"e1","date":"2026-09-01","memo":"Sale",
                  "totalAmount":{"amount":"125.50","currency":"USD"},
                  "createdAt":"2026-09-01T10:00:00.000Z","reversedAt":null}]
                """
            )
        ).journalEntries()
        XCTAssertEqual(entries.first?.totalAmount.amount, "125.50")
        XCTAssertEqual(entries.first?.totalAmount.currency, "USD")
        XCTAssertNil(entries.first?.reversedAt)

        let report = try await LedgerWriter(
            token: "t",
            transport: MockTransport.json(
                .ok,
                """
                {"rows":[{"accountId":"a1","name":"Cash","accountType":"asset",
                          "debit":{"amount":"125.50","currency":"USD"},
                          "credit":{"amount":"0.00","currency":"USD"}}],
                 "totalDebit":{"amount":"125.50","currency":"USD"},
                 "totalCredit":{"amount":"125.50","currency":"USD"},"balanced":true}
                """
            )
        ).trialBalance()
        XCTAssertTrue(report.balanced)
        XCTAssertEqual(report.rows.count, 1)
        XCTAssertEqual(report.totalDebit.decimalValue, Decimal(string: "125.50"))
    }

    func testIssueForwardsIdempotencyKeyAndReturnsCreated() async throws {
        let transport = MockTransport.json(.created, #"{"accountId":"a9"}"#)
        let ledgerWriter = LedgerWriter(token: "t", transport: transport)
        let command = try Components.Schemas.CommandRequest.make(
            type: "OpenLedgerAccount",
            payload: ["name": "Cash", "accountType": "asset", "isCashAccount": true, "bankAccountType": "checking"]
        )

        let output = try await ledgerWriter.issue(command, idempotencyKey: "key-123")

        guard case .created = output else { return XCTFail("expected 201 Created, got \(output)") }
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.headerFields[HTTPField.Name("Idempotency-Key")!], "key-123")
    }

    func testPostJournalEntrySendsMoneyAmounts() async throws {
        let transport = MockTransport.json(.created, #"{"entryId":"e9","status":"posted"}"#)
        let command = try Components.Schemas.CommandRequest.make(
            type: "PostJournalEntry",
            payload: [
                "date": "2026-09-25",
                "memo": "Invoice 1042",
                "lines": [
                    ["accountId": "cash", "debit": ["amount": "250.00", "currency": "USD"],
                     "credit": ["amount": "0", "currency": "USD"]],
                    ["accountId": "revenue", "debit": ["amount": "0", "currency": "USD"],
                     "credit": ["amount": "250.00", "currency": "USD"]],
                ],
            ]
        )
        let output = try await LedgerWriter(token: "t", transport: transport).issue(command)
        guard case .created = output else { return XCTFail("expected 201 Created, got \(output)") }
    }

    func testMoneyHelpersAreExact() throws {
        XCTAssertEqual(Components.Schemas.Money.usd("125.5")?.amount, "125.5")
        XCTAssertNil(Components.Schemas.Money.usd("10.005"))
        XCTAssertNil(Components.Schemas.Money.usd("1,000.00"))
        XCTAssertNil(Components.Schemas.Money.make("1.00", currency: "usd"))

        let tenth = try XCTUnwrap(Components.Schemas.Money.usd("0.10")?.decimalValue)
        let fifth = try XCTUnwrap(Components.Schemas.Money.usd("0.20")?.decimalValue)
        XCTAssertEqual(tenth + fifth, Decimal(string: "0.30"))  // exact, unlike Double

        XCTAssertTrue(try XCTUnwrap(Components.Schemas.Money.usd("-30.00")).isNegative)
        XCTAssertFalse(try XCTUnwrap(Components.Schemas.Money.usd("0")).isPositive)
    }

    func testErrorBodyBecomesLedgerWriterError() async throws {
        let ledgerWriter = LedgerWriter(
            token: "t",
            transport: MockTransport.json(
                .conflict,
                #"{"error":"CONCURRENCY_CONFLICT","message":"This journal entry was just changed by another request. Please try again."}"#,
                requestId: "req-409"
            )
        )
        let command = try Components.Schemas.CommandRequest.make(
            type: "ReverseJournalEntry",
            payload: ["entryId": "e1"]
        )

        do {
            _ = try await ledgerWriter.issue(command)
            XCTFail("expected LedgerWriterError")
        } catch let error as LedgerWriterError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.code, "CONCURRENCY_CONFLICT")
            XCTAssertEqual(error.requestId, "req-409")
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testUnauthenticatedQueryThrowsStableCode() async throws {
        let ledgerWriter = LedgerWriter(
            token: "bad",
            transport: MockTransport.json(.unauthorized, #"{"error":"INVALID_TOKEN"}"#)
        )
        do {
            _ = try await ledgerWriter.accountBalances()
            XCTFail("expected LedgerWriterError")
        } catch let error as LedgerWriterError {
            XCTAssertEqual(error.code, "INVALID_TOKEN")
            XCTAssertNil(error.message)
            XCTAssertFalse(error.isRetryable)
        }
    }
}

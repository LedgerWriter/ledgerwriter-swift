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
                  "transactionAmount":{"amount":"125.50","currency":"USD"},"exchangeRate":"1","selfApproved":true,
                  "createdAt":"2026-09-01T10:00:00.000Z","reversedAt":null},
                 {"tenantId":"t1","entryId":"e2","date":"2026-09-02","memo":"Sale in euros",
                  "totalAmount":{"amount":"216.90","currency":"USD"},
                  "transactionAmount":{"amount":"200.00","currency":"EUR"},"exchangeRate":"1.0845","selfApproved":false,
                  "createdAt":"2026-09-02T10:00:00.000Z","reversedAt":null}]
                """
            )
        ).journalEntries()
        XCTAssertEqual(entries.first?.totalAmount.amount, "125.50")
        XCTAssertEqual(entries.first?.totalAmount.currency, "USD")
        XCTAssertNil(entries.first?.reversedAt)
        // A foreign-currency entry: booked in USD, with the amount as entered and its rate.
        XCTAssertEqual(entries.last?.totalAmount.amount, "216.90")
        XCTAssertEqual(entries.last?.transactionAmount.currency, "EUR")
        XCTAssertEqual(entries.last?.exchangeRate, "1.0845")
        XCTAssertTrue(entries.last?.isForeignCurrency ?? false)
        XCTAssertFalse(entries.first?.isReversed ?? true)
        XCTAssertEqual(entries.map(\.selfApproved), [true, false])

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

    func testDecodesEveryModelFromTheWireFormat() async throws {
        let accounts = try await LedgerWriter(
            token: "t",
            transport: MockTransport.json(
                .ok,
                """
                [{"tenantId":"t1","accountId":"a1","name":"Petty cash","accountType":"asset",
                  "isCashAccount":true,"bankAccountType":"petty_cash","status":"open",
                  "updatedAt":"2026-09-25T12:34:56.789Z"}]
                """
            )
        ).ledgerAccounts()
        XCTAssertEqual(accounts.first?.bankAccountType, .pettyCash)
        XCTAssertEqual(accounts.first?.id, "a1")
        XCTAssertEqual(
            accounts.first?.updatedAt.timeIntervalSince1970 ?? 0, 1_790_339_696.789, accuracy: 0.001)

        let balances = try await LedgerWriter(
            token: "t",
            transport: MockTransport.json(
                .ok,
                """
                [{"tenantId":"t1","accountId":"a1","balance":{"amount":"-1250.00","currency":"USD"},
                  "updatedAt":"2026-09-25T12:34:56.789Z"}]
                """
            )
        ).accountBalances()
        XCTAssertEqual(balances.first?.balance, Money.usd("-1250.00"))
        XCTAssertTrue(balances.first?.balance.isNegative ?? false)
    }

    func testPendingEntriesAndEffectiveExchangeRate() async throws {
        let pending = try await LedgerWriter(
            token: "t",
            transport: MockTransport.json(
                .ok,
                """
                [{"tenantId":"t1","entryId":"p1","date":"2026-09-25","memo":"Big invoice",
                  "totalAmount":{"amount":"10845.00","currency":"USD"},
                  "transactionAmount":{"amount":"10000.00","currency":"EUR"},
                  "exchangeRate":"1.0845","postedBy":"u1",
                  "lines":[{"accountId":"ar","debit":{"amount":"10845.00","currency":"USD"},
                            "credit":{"amount":"0.00","currency":"USD"},
                            "transactionDebit":{"amount":"10000.00","currency":"EUR"},
                            "transactionCredit":{"amount":"0.00","currency":"EUR"}}]}]
                """
            )
        ).pendingJournalEntries()
        XCTAssertEqual(pending.first?.postedBy, "u1")
        XCTAssertTrue(pending.first?.isForeignCurrency ?? false)
        XCTAssertEqual(pending.first?.lines.first?.transactionDebit, Money.make("10000.00", currency: "EUR"))

        let transport = MockTransport.json(
            .ok,
            #"{"currency":"GBP","functionalCurrency":"USD","date":"2026-09-27","rate":{"rate":"1.27","source":"ecb","rateDate":"2026-09-25"}}"#
        )
        let effective = try await LedgerWriter(token: "t", transport: transport)
            .effectiveExchangeRate(currency: "GBP", date: "2026-09-27")
        XCTAssertEqual(effective.rate, StoredExchangeRate(rate: "1.27", source: .ecb, rateDate: "2026-09-25"))
        let query = transport.requests.first?.path ?? ""
        XCTAssertTrue(query.contains("currency=GBP") && query.contains("date=2026-09-27"), query)

        let none = try await LedgerWriter(
            token: "t",
            transport: MockTransport.json(
                .ok, #"{"currency":"BHD","functionalCurrency":"USD","date":"2026-09-27"}"#)
        ).effectiveExchangeRate(currency: "BHD", date: "2026-09-27")
        XCTAssertNil(none.rate)
    }

    func testOpenLedgerAccountForwardsIdempotencyKeyAndReturnsTheId() async throws {
        let transport = MockTransport.json(.created, #"{"accountId":"a9"}"#)
        let ledgerWriter = LedgerWriter(token: "t", transport: transport)

        let accountId = try await ledgerWriter.openLedgerAccount(
            name: "Cash", type: .asset, isCashAccount: true, bankAccountType: .checking,
            idempotencyKey: "key-123")

        XCTAssertEqual(accountId, "a9")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.headerFields[HTTPField.Name("Idempotency-Key")!], "key-123")
    }

    func testPostJournalEntryReturnsPostedOrPending() async throws {
        let usd = try XCTUnwrap(Money.usd("250.00"))
        let posted = try await LedgerWriter(
            token: "t", transport: MockTransport.json(.created, #"{"entryId":"e9","status":"posted"}"#)
        ).postJournalEntry(
            date: "2026-09-25", memo: "Invoice 1042",
            lines: [.debit("cash", usd), .credit("revenue", usd)])
        XCTAssertEqual(posted, PostedEntry(entryId: "e9", status: .posted))

        let pending = try await LedgerWriter(
            token: "t", transport: MockTransport.json(.created, #"{"entryId":"e10","status":"pending"}"#)
        ).postJournalEntry(
            date: "2026-09-25", memo: "Big invoice",
            lines: [.debit("cash", usd), .credit("revenue", usd)])
        XCTAssertEqual(pending.status, .pending)
    }

    func testForeignCurrencyLinesAndRateGoIntoTheCommand() async throws {
        let eur = try XCTUnwrap(Money.make("200.00", currency: "EUR"))
        let line = JournalEntryLine.debit("cash", eur)
        XCTAssertEqual(line.credit, Money.zero("EUR"))

        let transport = MockTransport.json(.created, #"{"entryId":"e11","status":"posted"}"#)
        _ = try await LedgerWriter(token: "t", transport: transport).postJournalEntry(
            date: "2026-09-25", memo: "Invoice in euros",
            lines: [line, .credit("revenue", eur)], exchangeRate: "1.0845")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testApproveRejectReverseRenameClose() async throws {
        let transport = MockTransport.json(.ok, #"{"entryId":"e1","status":"posted"}"#)
        let ledgerWriter = LedgerWriter(token: "t", transport: transport)
        try await ledgerWriter.approveJournalEntry("e1")
        try await ledgerWriter.rejectJournalEntry("e1")
        try await ledgerWriter.reverseJournalEntry("e1")
        try await ledgerWriter.renameLedgerAccount("a1", to: "Revenue")
        try await ledgerWriter.closeLedgerAccount("a1")
        XCTAssertEqual(transport.requests.count, 5)
    }

    func testMoneyHelpersAreExact() throws {
        XCTAssertEqual(Money.usd("125.5")?.amount, "125.5")
        XCTAssertNil(Money.usd("10.005"))
        XCTAssertEqual(Money.make("1.500", currency: "BHD")?.amount, "1.500")
        XCTAssertNil(Money.make("1.5001", currency: "BHD"))
        XCTAssertNil(Money.usd("1,000.00"))
        XCTAssertNil(Money.make("1.00", currency: "usd"))

        let tenth = try XCTUnwrap(Money.usd("0.10")?.decimalValue)
        let fifth = try XCTUnwrap(Money.usd("0.20")?.decimalValue)
        XCTAssertEqual(tenth + fifth, Decimal(string: "0.30"))  // exact, unlike Double

        XCTAssertTrue(try XCTUnwrap(Money.usd("-30.00")).isNegative)
        XCTAssertFalse(try XCTUnwrap(Money.usd("0")).isPositive)
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
        do {
            try await ledgerWriter.reverseJournalEntry("e1")
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

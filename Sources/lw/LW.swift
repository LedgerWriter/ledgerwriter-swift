import ArgumentParser
import Foundation
import LedgerWriterAPI

@main
struct LW: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lw",
        abstract: "Command-line client for the LedgerWriter API.",
        discussion: """
            Authenticates with an API token from LEDGERWRITER_TOKEN. Set LEDGERWRITER_BASE_URL \
            to target a non-production API.
            """,
        subcommands: [
            Accounts.self, Entries.self, Balances.self, TrialBalance.self,
            OpenAccount.self, PostEntry.self,
        ]
    )
}

struct Connection: ParsableArguments {
    @Flag(help: "Print the raw JSON response instead of a table.")
    var json = false

    func client() throws -> LedgerWriter {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["LEDGERWRITER_TOKEN"], !token.isEmpty else {
            throw ValidationError("Set LEDGERWRITER_TOKEN to an API token from your LedgerWriter settings.")
        }
        var baseURL = LedgerWriter.defaultBaseURL
        if let override = environment["LEDGERWRITER_BASE_URL"] {
            guard let url = URL(string: override) else {
                throw ValidationError("LEDGERWRITER_BASE_URL is not a valid URL: \(override)")
            }
            baseURL = url
        }
        return LedgerWriter(token: token, baseURL: baseURL)
    }
}

// MARK: - Queries

struct Accounts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List ledger accounts.")
    @OptionGroup var connection: Connection

    func run() async throws {
        let accounts = try await reportingErrors { try await connection.client().ledgerAccounts() }
        if connection.json { return try printJSON(accounts) }
        printTable(
            ["ACCOUNT ID", "NAME", "TYPE", "CASH", "STATUS"],
            accounts.map {
                [$0.accountId, $0.name, $0.accountType.rawValue, $0.isCashAccount ? "yes" : "", $0.status.rawValue]
            }
        )
    }
}

struct Entries: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List posted journal entries.")
    @OptionGroup var connection: Connection

    func run() async throws {
        let entries = try await reportingErrors { try await connection.client().journalEntries() }
        if connection.json { return try printJSON(entries) }
        printTable(
            ["ENTRY ID", "DATE", "MEMO", "AMOUNT", "REVERSED"],
            entries.map {
                [$0.entryId, $0.date, $0.memo, formatAmount($0.totalAmount), $0.reversedAt == nil ? "" : "yes"]
            }
        )
    }
}

struct Balances: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List account balances (debits minus credits).")
    @OptionGroup var connection: Connection

    func run() async throws {
        let balances = try await reportingErrors { try await connection.client().accountBalances() }
        if connection.json { return try printJSON(balances) }
        printTable(["ACCOUNT ID", "BALANCE"], balances.map { [$0.accountId, formatAmount($0.balance)] })
    }
}

struct TrialBalance: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trial-balance", abstract: "Show the trial balance.")
    @OptionGroup var connection: Connection

    func run() async throws {
        let report = try await reportingErrors { try await connection.client().trialBalance() }
        if connection.json { return try printJSON(report) }
        var rows = report.rows.map {
            [$0.name, $0.accountType.rawValue, formatAmount($0.debit), formatAmount($0.credit)]
        }
        rows.append(["TOTAL", "", formatAmount(report.totalDebit), formatAmount(report.totalCredit)])
        printTable(["ACCOUNT", "TYPE", "DEBIT", "CREDIT"], rows)
        if !report.balanced { printError("warning: the trial balance does not balance") }
    }
}

// MARK: - Commands

struct OpenAccount: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open-account", abstract: "Open a ledger account.")
    @OptionGroup var connection: Connection

    @Option(help: "Account name.") var name: String
    @Option(help: "asset, liability, equity, revenue, or expense.") var type: String
    @Flag(help: "Mark as a cash account (requires --bank-type).") var cash = false
    @Option(help: "Bank account type for a cash account, e.g. checking.") var bankType: String?
    @Option(help: "Idempotency key, so a retry can't open the account twice.") var idempotencyKey: String?

    func run() async throws {
        var payload: [String: Any] = ["name": name, "accountType": type, "isCashAccount": cash]
        if let bankType { payload["bankAccountType"] = bankType }
        try await issue(connection, type: "OpenLedgerAccount", payload: payload, idempotencyKey: idempotencyKey)
    }
}

struct PostEntry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post-entry",
        abstract: "Post a journal entry.",
        discussion: """
            Each --debit/--credit is ACCOUNT_ID=AMOUNT. Debits and credits must balance. \
            Entries at or above the tenant's dual-approval threshold are created pending.
            """
    )
    @OptionGroup var connection: Connection

    @Option(help: "Entry date, YYYY-MM-DD.") var date: String
    @Option(help: "Memo.") var memo: String
    @Option(help: "ACCOUNT_ID=AMOUNT to debit (repeatable).") var debit: [String] = []
    @Option(help: "ACCOUNT_ID=AMOUNT to credit (repeatable).") var credit: [String] = []
    @Option(help: "Idempotency key, so a retry can't post the entry twice.") var idempotencyKey: String?

    func run() async throws {
        let lines = try debit.map { try line($0, debit: true) } + credit.map { try line($0, debit: false) }
        try await issue(
            connection,
            type: "PostJournalEntry",
            payload: ["date": date, "memo": memo, "lines": lines],
            idempotencyKey: idempotencyKey
        )
    }

    // Amounts stay strings end to end (never Double), matching the API's exact Money format.
    private func line(_ spec: String, debit: Bool) throws -> [String: Any] {
        let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let amount = Components.Schemas.Money.usd(parts[1]), amount.isPositive
        else {
            throw ValidationError(
                "Expected ACCOUNT_ID=AMOUNT with a positive amount and at most two decimals, got \(spec)")
        }
        let zero = ["amount": "0", "currency": amount.currency]
        let value = ["amount": amount.amount, "currency": amount.currency]
        return ["accountId": parts[0], "debit": debit ? value : zero, "credit": debit ? zero : value]
    }
}

private func issue(
    _ connection: Connection,
    type: String,
    payload: [String: Any],
    idempotencyKey: String?
) async throws {
    let command = try Components.Schemas.CommandRequest.make(type: type, payload: payload)
    let output = try await reportingErrors {
        try await connection.client().issue(command, idempotencyKey: idempotencyKey)
    }
    switch output {
    case .ok(let applied): try printJSON(applied.body.json)
    case .created(let created): try printJSON(created.body.json)
    default: throw ExitCode.failure  // Unreachable: error statuses throw LedgerWriterError.
    }
}

// MARK: - Output

private func reportingErrors<T>(_ operation: () async throws -> T) async throws -> T {
    do {
        return try await operation()
    } catch let error as LedgerWriterError {
        printError("error: \(error)")
        throw ExitCode.failure
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

private func printTable(_ header: [String], _ rows: [[String]]) {
    let widths = header.indices.map { column in
        ([header] + rows).map { $0[column].count }.max() ?? 0
    }
    for row in [header] + rows {
        print(zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  "))
    }
}

private func formatAmount(_ money: Components.Schemas.Money) -> String {
    money.amount
}

private func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

import Foundation

// The SDK's public data types. Hand-written on purpose: the code generated from openapi.yaml is
// internal to this module (openapi-generator-config.yaml), so apps depend only on these
// stable types, never on generated ones. LedgerWriter.swift maps between the two.

public enum AccountType: String, Sendable, Hashable, Codable, CaseIterable {
    case asset, liability, equity, revenue, expense
}

public enum BankAccountType: String, Sendable, Hashable, Codable, CaseIterable {
    case checking, savings
    case moneyMarket = "money_market"
    case payroll, merchant
    case lineOfCredit = "line_of_credit"
    case pettyCash = "petty_cash"
    case other
}

public struct LedgerAccount: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Hashable, Codable {
        case open, closed
    }

    public let tenantId: String
    public let accountId: String
    public let name: String
    public let accountType: AccountType
    public let isCashAccount: Bool
    /// The bank account type for cash accounts; nil otherwise.
    public let bankAccountType: BankAccountType?
    public let status: Status
    public let updatedAt: Date

    public var id: String { accountId }
}

public struct AccountBalance: Sendable, Hashable, Codable {
    public let tenantId: String
    public let accountId: String
    /// Signed net balance, debits minus credits, in the tenant's functional currency.
    public let balance: Money
    public let updatedAt: Date
}

/// A posted journal entry. Pending entries (awaiting dual approval) aren't listed.
public struct JournalEntry: Sendable, Hashable, Codable, Identifiable {
    public let tenantId: String
    public let entryId: String
    /// Entry date as posted, `YYYY-MM-DD`.
    public let date: String
    public let memo: String
    /// Sum of the debits as booked, in the tenant's functional currency.
    public let totalAmount: Money
    /// Sum of the debits as entered, in the entry's own currency. Equal to `totalAmount` for an
    /// entry in the functional currency.
    public let transactionAmount: Money
    /// Functional-currency units per one unit of the entry's currency; `"1"` when they match.
    public let exchangeRate: String
    public let createdAt: Date
    public let reversedAt: Date?

    public var id: String { entryId }
    public var isForeignCurrency: Bool { transactionAmount.currency != totalAmount.currency }
    public var isReversed: Bool { reversedAt != nil }
}

public struct TrialBalanceRow: Sendable, Hashable, Codable {
    public let accountId: String
    public let name: String
    public let accountType: AccountType
    public let debit: Money
    public let credit: Money
}

public struct TrialBalance: Sendable, Hashable, Codable {
    public let rows: [TrialBalanceRow]
    public let totalDebit: Money
    public let totalCredit: Money
    /// Always true for an uncorrupted ledger: every posted entry balances.
    public let balanced: Bool
}

/// One line of a journal entry to post: exactly one side carries a positive amount.
public struct JournalEntryLine: Sendable, Hashable, Codable {
    public let accountId: String
    public let debit: Money
    public let credit: Money

    public static func debit(_ accountId: String, _ amount: Money) -> JournalEntryLine {
        JournalEntryLine(accountId: accountId, debit: amount, credit: .zero(amount.currency))
    }

    public static func credit(_ accountId: String, _ amount: Money) -> JournalEntryLine {
        JournalEntryLine(accountId: accountId, debit: .zero(amount.currency), credit: amount)
    }
}

/// The result of posting an entry: `.pending` when its booked total reached the tenant's
/// dual-approval threshold and it now awaits a second reviewer.
public struct PostedEntry: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable {
        case posted, pending
    }

    public let entryId: String
    public let status: Status
}

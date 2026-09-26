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

    public init(
        tenantId: String,
        accountId: String,
        name: String,
        accountType: AccountType,
        isCashAccount: Bool,
        bankAccountType: BankAccountType?,
        status: Status,
        updatedAt: Date
    ) {
        self.tenantId = tenantId
        self.accountId = accountId
        self.name = name
        self.accountType = accountType
        self.isCashAccount = isCashAccount
        self.bankAccountType = bankAccountType
        self.status = status
        self.updatedAt = updatedAt
    }
}

public struct AccountBalance: Sendable, Hashable, Codable {
    public let tenantId: String
    public let accountId: String
    /// Signed net balance, debits minus credits, in the tenant's functional currency.
    public let balance: Money
    public let updatedAt: Date

    public init(
        tenantId: String,
        accountId: String,
        balance: Money,
        updatedAt: Date
    ) {
        self.tenantId = tenantId
        self.accountId = accountId
        self.balance = balance
        self.updatedAt = updatedAt
    }
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
    /// Approved by the person who posted it, which is allowed only when the tenant has a single
    /// active member.
    public let selfApproved: Bool
    public let createdAt: Date
    public let reversedAt: Date?

    public var id: String { entryId }
    public var isForeignCurrency: Bool { transactionAmount.currency != totalAmount.currency }
    public var isReversed: Bool { reversedAt != nil }

    public init(
        tenantId: String,
        entryId: String,
        date: String,
        memo: String,
        totalAmount: Money,
        transactionAmount: Money,
        exchangeRate: String,
        selfApproved: Bool,
        createdAt: Date,
        reversedAt: Date?
    ) {
        self.tenantId = tenantId
        self.entryId = entryId
        self.date = date
        self.memo = memo
        self.totalAmount = totalAmount
        self.transactionAmount = transactionAmount
        self.exchangeRate = exchangeRate
        self.selfApproved = selfApproved
        self.createdAt = createdAt
        self.reversedAt = reversedAt
    }
}

public struct TrialBalanceRow: Sendable, Hashable, Codable {
    public let accountId: String
    public let name: String
    public let accountType: AccountType
    public let debit: Money
    public let credit: Money

    public init(
        accountId: String,
        name: String,
        accountType: AccountType,
        debit: Money,
        credit: Money
    ) {
        self.accountId = accountId
        self.name = name
        self.accountType = accountType
        self.debit = debit
        self.credit = credit
    }
}

public struct TrialBalance: Sendable, Hashable, Codable {
    public let rows: [TrialBalanceRow]
    public let totalDebit: Money
    public let totalCredit: Money
    /// Always true for an uncorrupted ledger: every posted entry balances.
    public let balanced: Bool

    public init(
        rows: [TrialBalanceRow],
        totalDebit: Money,
        totalCredit: Money,
        balanced: Bool
    ) {
        self.rows = rows
        self.totalDebit = totalDebit
        self.totalCredit = totalCredit
        self.balanced = balanced
    }
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

    public init(
        accountId: String,
        debit: Money,
        credit: Money
    ) {
        self.accountId = accountId
        self.debit = debit
        self.credit = credit
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

    public init(
        entryId: String,
        status: Status
    ) {
        self.entryId = entryId
        self.status = status
    }
}

/// A journal entry awaiting dual approval: its booked total reached the tenant's threshold.
public struct PendingJournalEntry: Sendable, Hashable, Codable, Identifiable {
    public let tenantId: String
    public let entryId: String
    public let date: String
    public let memo: String
    /// Sum of the debits as they would be booked, in the functional currency.
    public let totalAmount: Money
    /// Sum of the debits as entered, in the entry's own currency.
    public let transactionAmount: Money
    public let exchangeRate: String
    /// The id of the user who posted it.
    public let postedBy: String
    /// What approving the entry would book.
    public let lines: [EntryLine]

    public var id: String { entryId }
    public var isForeignCurrency: Bool { transactionAmount.currency != totalAmount.currency }

    public init(
        tenantId: String,
        entryId: String,
        date: String,
        memo: String,
        totalAmount: Money,
        transactionAmount: Money,
        exchangeRate: String,
        postedBy: String,
        lines: [EntryLine]
    ) {
        self.tenantId = tenantId
        self.entryId = entryId
        self.date = date
        self.memo = memo
        self.totalAmount = totalAmount
        self.transactionAmount = transactionAmount
        self.exchangeRate = exchangeRate
        self.postedBy = postedBy
        self.lines = lines
    }
}

/// One line of an entry: `debit`/`credit` as booked in the functional currency, and the
/// `transaction` amounts as entered (equal for a functional-currency entry).
public struct EntryLine: Sendable, Hashable, Codable {
    public let accountId: String
    public let debit: Money
    public let credit: Money
    public let transactionDebit: Money
    public let transactionCredit: Money

    public init(
        accountId: String,
        debit: Money,
        credit: Money,
        transactionDebit: Money,
        transactionCredit: Money
    ) {
        self.accountId = accountId
        self.debit = debit
        self.credit = credit
        self.transactionDebit = transactionDebit
        self.transactionCredit = transactionCredit
    }
}

/// A rate on file: entered by the tenant, or the European Central Bank reference rate.
public struct StoredExchangeRate: Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Hashable, Codable {
        case manual, ecb
    }

    /// Functional-currency units per one unit of the entry's currency, e.g. `"1.0845"`.
    public let rate: String
    public let source: Source
    /// The date the rate is quoted for, `YYYY-MM-DD`.
    public let rateDate: String

    public init(rate: String, source: Source, rateDate: String) {
        self.rate = rate
        self.source = source
        self.rateDate = rateDate
    }
}

/// What a foreign-currency entry in `currency` dated `date` would book at if it didn't state a
/// rate; `rate` is nil when nothing is on file, and the entry must then supply one.
public struct EffectiveExchangeRate: Sendable, Hashable, Codable {
    public let currency: String
    public let functionalCurrency: String
    public let date: String
    public let rate: StoredExchangeRate?

    public init(currency: String, functionalCurrency: String, date: String, rate: StoredExchangeRate?) {
        self.currency = currency
        self.functionalCurrency = functionalCurrency
        self.date = date
        self.rate = rate
    }
}

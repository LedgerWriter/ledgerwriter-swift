import Foundation

/// An exact amount: a decimal string plus an ISO 4217 code, e.g. `125.50 USD`. Never a
/// floating-point number. Construction validates the string, and arithmetic goes through
/// `Foundation.Decimal` (base 10), never `Double`.
public struct Money: Sendable, Hashable, Codable {
    /// The exact decimal string, e.g. `"125.50"`, `"-30.00"`, `"1500"` (JPY).
    public let amount: String
    /// ISO 4217 code, e.g. `"USD"`.
    public let currency: String

    private static let amountPattern = #"^-?(0|[1-9][0-9]*)(\.[0-9]{1,3})?$"#
    private static let currencyPattern = #"^[A-Z]{3}$"#

    /// A Money value from an exact decimal string ("125.50", "125.5", "125"), or nil if the
    /// amount has more than three decimal places or isn't a plain decimal number. The server
    /// also enforces the currency's own exponent: two places for USD or EUR, none for JPY,
    /// three for BHD.
    public static func make(_ amount: String, currency: String) -> Money? {
        guard amount.range(of: amountPattern, options: .regularExpression) != nil,
            currency.range(of: currencyPattern, options: .regularExpression) != nil
        else { return nil }
        return Money(amount: amount, currency: currency)
    }

    /// A USD amount with at most two decimal places; see ``make(_:currency:)``.
    public static func usd(_ amount: String) -> Money? {
        guard amount.split(separator: ".").dropFirst().first.map({ $0.count <= 2 }) ?? true else { return nil }
        return make(amount, currency: "USD")
    }

    /// Zero in `currency`, as the API expects on the unused side of a journal-entry line.
    public static func zero(_ currency: String) -> Money {
        Money(amount: "0", currency: currency)
    }

    /// The exact value. Decimal is base 10, so "0.10" is exactly one tenth.
    public var decimalValue: Decimal? {
        Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX"))
    }

    public var isNegative: Bool { (decimalValue ?? 0) < 0 }
    public var isPositive: Bool { (decimalValue ?? 0) > 0 }
}

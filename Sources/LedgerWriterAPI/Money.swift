import Foundation

// Every amount in the LedgerWriter API is a Money object -- an exact decimal string plus an
// ISO 4217 code, e.g. { "amount": "125.50", "currency": "USD" } -- never a JSON number. These
// helpers keep it exact on the Swift side too: construction validates the string, and
// arithmetic goes through Foundation.Decimal (base 10), never Double.
extension Components.Schemas.Money {
    private static let amountPattern = #"^-?(0|[1-9][0-9]*)(\.[0-9]{1,2})?$"#
    private static let currencyPattern = #"^[A-Z]{3}$"#

    /// A Money value from an exact decimal string ("125.50", "125.5", "125"), or nil if the
    /// amount has more than two decimal places or isn't a plain decimal number.
    public static func make(_ amount: String, currency: String) -> Self? {
        guard amount.range(of: amountPattern, options: .regularExpression) != nil,
            currency.range(of: currencyPattern, options: .regularExpression) != nil
        else { return nil }
        return .init(amount: amount, currency: currency)
    }

    /// A USD amount; see ``make(_:currency:)``.
    public static func usd(_ amount: String) -> Self? {
        make(amount, currency: "USD")
    }

    /// The exact value. Decimal is base 10, so "0.10" is exactly one tenth.
    public var decimalValue: Decimal? {
        Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX"))
    }

    public var isNegative: Bool { (decimalValue ?? 0) < 0 }
    public var isPositive: Bool { (decimalValue ?? 0) > 0 }
}

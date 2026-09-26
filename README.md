# ledgerwriter-swift

The Swift SDK and `lw` command-line tool for the LedgerWriter API.

The client is **generated at build time** from
[`Sources/LedgerWriterAPI/openapi.yaml`](Sources/LedgerWriterAPI/openapi.yaml), the published
OpenAPI 3.1 contract for the LedgerWriter external API. It is a byte-identical copy of the
contract maintained in LedgerWriter's (private) service repository, where a contract test
keeps the running API and the spec in agreement; this repository never edits it.
`SPEC_SOURCE` records which commit the copy came from.

| Product | Platforms | What it is |
| --- | --- | --- |
| `LedgerWriterAPI` | iOS 17, macOS 14, Linux | Generated client plus `LedgerWriter`, a small convenience layer: bearer-token auth, typed errors, request ids |
| `lw` | macOS, Linux | Command-line tool built on `LedgerWriterAPI` |

Planned next, per ADR-14: `LedgerWriterAuth` (OAuth + PKCE, passkeys), `LedgerWriterBankLink`
(Plaid Link sessions), `LedgerWriterFinanceKit` (iOS only), `LedgerWriterUI`.

## Using the library

```swift
// Package.swift
.package(url: "https://github.com/LedgerWriter/ledgerwriter-swift", from: "0.2.0"),
// target dependency:
.product(name: "LedgerWriterAPI", package: "ledgerwriter-swift"),
```

```swift
import LedgerWriterAPI

let ledgerWriter = LedgerWriter(token: apiToken)

let accounts = try await ledgerWriter.ledgerAccounts()
let report = try await ledgerWriter.trialBalance()

let command = try Components.Schemas.CommandRequest.make(
    type: "PostJournalEntry",
    payload: [
        "date": "2026-09-25",
        "memo": "Invoice 1042",
        "lines": [
            ["accountId": cashId, "debit": ["amount": "250.00", "currency": "USD"],
             "credit": ["amount": "0", "currency": "USD"]],
            ["accountId": revenueId, "debit": ["amount": "0", "currency": "USD"],
             "credit": ["amount": "250.00", "currency": "USD"]],
        ],
    ]
)
do {
    let result = try await ledgerWriter.issue(command, idempotencyKey: "invoice-1042")
} catch let error as LedgerWriterError {
    // error.code is stable (ADR-12), e.g. "UNBALANCED_ENTRY"; branch on it, not on message.
    // error.requestId matches the id stored on the events in the audit trail.
    if error.isRetryable { /* CONCURRENCY_CONFLICT: re-read and retry */ }
}
```

Every amount is a `Money` value, an exact decimal string plus a currency code
(`Components.Schemas.Money(amount: "125.50", currency: "USD")`), never a floating-point
number. `Money.usd("125.50")` validates an amount, and `decimalValue` gives an exact
`Foundation.Decimal` for arithmetic. Version 0.2.0 introduced this format; 0.1.0 used JSON
numbers and doesn't work against the current API.

An entry can be entered in another currency than the tenant's functional currency (the one
its books are kept in) by passing `exchangeRate` with the payload: functional-currency units
per one unit of the entry's currency, as an exact string such as `"1.0845"`. Leave it out
to book at the rate on file for the entry date (a rate the tenant entered, else the ECB
reference rate). Entry summaries return the booked `totalAmount` alongside the
`transactionAmount` as entered and the `exchangeRate`.

## Using `lw`

```sh
swift build -c release
export LEDGERWRITER_TOKEN=...            # API token from LedgerWriter settings
.build/release/lw accounts
.build/release/lw trial-balance --json
.build/release/lw open-account --name "Operating Cash" --type asset --cash --bank-type checking
.build/release/lw post-entry --date 2026-09-25 --memo "Invoice 1042" \
  --debit CASH_ID=250 --credit REVENUE_ID=250 --idempotency-key invoice-1042
.build/release/lw post-entry --date 2026-09-25 --memo "Invoice 1043 (EUR)" \
  --currency EUR --rate 1.0845 --debit CASH_ID=200 --credit REVENUE_ID=200
.build/release/lw post-entry --date 2026-09-25 --memo "Invoice 1044 (EUR, rate on file)" \
  --currency EUR --debit CASH_ID=80 --credit REVENUE_ID=80
```

Set `LEDGERWRITER_BASE_URL` to target a non-production API. Errors print the stable code and
the request id.

## Updating the contract

```sh
Scripts/sync-openapi.sh /path/to/ledger-writer <git-ref>
swift build && swift test
```

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE).
This license covers this SDK and CLI only; the LedgerWriter service itself is proprietary.

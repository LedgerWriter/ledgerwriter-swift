# ledgerwriter-swift

The Swift SDK and `lw` command-line tool for the LedgerWriter API.

The client is **generated at build time** from `Sources/LedgerWriterAPI/openapi.yaml`, a
vendored, byte-identical copy of the contract in
[`mnhpub/ledger-writer`](https://github.com/mnhpub/ledger-writer) (`apps/api-external/openapi.yaml`).
That file is the single source of truth, enforced there by a contract test; this repository
never edits it. See ADR-14 in ledger-writer for the reasoning. `SPEC_SOURCE` records which
commit the vendored copy came from.

| Product | Platforms | What it is |
| --- | --- | --- |
| `LedgerWriterAPI` | iOS 17, macOS 14, Linux | Generated client plus `LedgerWriter`, a small convenience layer: bearer-token auth, typed errors, request ids |
| `lw` | macOS, Linux | Command-line tool built on `LedgerWriterAPI` |

Planned next, per ADR-14: `LedgerWriterAuth` (OAuth + PKCE, passkeys), `LedgerWriterBankLink`
(Plaid Link sessions), `LedgerWriterFinanceKit` (iOS only), `LedgerWriterUI`.

## Using the library

```swift
// Package.swift
.package(url: "https://github.com/LedgerWriter/ledgerwriter-swift", branch: "main"),
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
            ["accountId": cashId, "debit": 250.0, "credit": 0.0],
            ["accountId": revenueId, "debit": 0.0, "credit": 250.0],
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

Amounts are JSON numbers today. They move to exact decimal strings with a currency code in
the upcoming money-model change, which updates the spec and server together; regenerate
after syncing.

## Using `lw`

```sh
swift build -c release
export LEDGERWRITER_TOKEN=...            # API token from LedgerWriter settings
.build/release/lw accounts
.build/release/lw trial-balance --json
.build/release/lw open-account --name "Operating Cash" --type asset --cash --bank-type checking
.build/release/lw post-entry --date 2026-09-25 --memo "Invoice 1042" \
  --debit CASH_ID=250 --credit REVENUE_ID=250 --idempotency-key invoice-1042
```

Set `LEDGERWRITER_BASE_URL` to target a non-production API. Errors print the stable code and
the request id.

## Updating the contract

```sh
Scripts/sync-openapi.sh /path/to/ledger-writer <git-ref>
swift build && swift test
```

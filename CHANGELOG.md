# Changelog

## 0.2.0

Needs a LedgerWriter API that includes the exact-money and multi-currency changes
(mnhpub/ledger-writer PR #45). 0.1.0 doesn't work against that API, and 0.2.0 doesn't work
against an older one.

### Breaking

- **Generated code is internal.** Apps use only `LedgerWriter` and the hand-written public
  models: `Money`, `LedgerAccount` (with `AccountType` and `BankAccountType`),
  `AccountBalance`, `JournalEntry`, `TrialBalance`, `JournalEntryLine` and `PostedEntry`.
  They have public initializers for previews and tests. `LedgerWriter.client` is no longer
  public.
- **Typed commands replace `issue(_:)`.** The new methods are:
  - `postJournalEntry(date:memo:lines:exchangeRate:idempotencyKey:)`;
  - `approveJournalEntry`, `rejectJournalEntry` and `reverseJournalEntry`;
  - `openLedgerAccount`, `renameLedgerAccount` and `closeLedgerAccount`.
- **Amounts are `Money`:** an exact decimal string plus an ISO 4217 code, never a JSON
  number. Use `Money.make(_:currency:)`, `Money.usd(_:)` and `decimalValue` (a
  `Foundation.Decimal`).

### Added

- Multi-currency:
  - `JournalEntry.transactionAmount`, `exchangeRate` and `isForeignCurrency`;
  - `postJournalEntry(... exchangeRate:)`. Leave it nil to book at the rate on file for the
    entry date.
- New error codes to branch on: `UNSUPPORTED_CURRENCY`, `INVALID_EXCHANGE_RATE` and
  `FX_GAIN_LOSS_ACCOUNT_REQUIRED`.
- `lw post-entry --currency --rate`. `lw entries` shows the original amount of foreign
  entries.

## 0.1.0

First release: the generated client, `LedgerWriter` conveniences, and the `lw` CLI.

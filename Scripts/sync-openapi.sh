#!/usr/bin/env bash
# Re-vendor the API contract from a local ledger-writer checkout (ADR-14: ledger-writer's
# apps/api-external/openapi.yaml is the single source of truth; this repo never edits it).
#
#   Scripts/sync-openapi.sh /path/to/ledger-writer [git-ref]
set -euo pipefail

src_repo="${1:?usage: Scripts/sync-openapi.sh /path/to/ledger-writer [git-ref]}"
ref="${2:-HEAD}"
root="$(cd "$(dirname "$0")/.." && pwd)"
spec_path="apps/api-external/openapi.yaml"

commit="$(git -C "$src_repo" rev-parse "$ref")"
git -C "$src_repo" show "$commit:$spec_path" > "$root/Sources/LedgerWriterAPI/openapi.yaml"

cat > "$root/SPEC_SOURCE" <<EOF
repository: mnhpub/ledger-writer
path: $spec_path
commit: $commit
EOF

echo "Vendored $spec_path at $commit"

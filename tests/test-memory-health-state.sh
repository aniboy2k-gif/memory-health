#!/bin/bash
# test-memory-health-state.sh — regression tests for memory-health-state.sh
# Run: bash tests/test-memory-health-state.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/memory-health-state.sh"

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
no()   { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# Isolated state dir per run (no Date.now in scripts; use mktemp)
export MEMORY_HEALTH_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mhs-test.XXXXXX")"
trap 'rm -rf "$MEMORY_HEALTH_STATE_DIR"' EXIT

# shellcheck disable=SC1090
source "$LIB"

echo "== memory-health-state.sh tests =="

# 1) write + read round-trip preserves entries
J='{"entries":[{"path":"/x/rules.md","version":"1.1.0","bundle_sha256":"aaa","installed_sha256":"aaa","installed_at":"2026-05-29T00:00:00Z"}]}'
if mhs_write_manifest "$J"; then ok "write_manifest succeeds"; else no "write_manifest failed"; fi
OUT="$(mhs_read_manifest)"; RC=$?
if [ $RC -eq 0 ]; then ok "read_manifest rc0 on intact file"; else no "read_manifest rc=$RC (expected 0)"; fi
V="$(printf '%s' "$OUT" | jq -r '.entries[0].version')"
[ "$V" = "1.1.0" ] && ok "round-trip preserves version" || no "version lost: '$V'"

# 2) self_checksum present + non-empty
C="$(printf '%s' "$OUT" | jq -r '.self_checksum')"
[ -n "$C" ] && [ "$C" != "null" ] && ok "self_checksum stamped" || no "self_checksum missing"

# 3) accidental corruption (tamper a field) => checksum mismatch rc5
FILE="$(mhs_state_file)"
jq '.entries[0].installed_sha256 = "TAMPERED"' "$FILE" > "$FILE.t" && mv "$FILE.t" "$FILE"
mhs_read_manifest >/dev/null 2>&1; RC=$?
[ $RC -eq 5 ] && ok "tampered field -> checksum mismatch (rc5)" || no "expected rc5, got rc=$RC"

# 4) missing file => rc2
rm -f "$FILE"
mhs_read_manifest >/dev/null 2>&1; RC=$?
[ $RC -eq 2 ] && ok "missing file -> rc2" || no "expected rc2, got rc=$RC"

# 5) unparseable JSON => rc3
echo "{ not json" > "$FILE"
mhs_read_manifest >/dev/null 2>&1; RC=$?
[ $RC -eq 3 ] && ok "corrupt JSON -> rc3" || no "expected rc3, got rc=$RC"

# 6) schema invalid (no entries array) => rc4
echo '{"schema_version":"1","self_checksum":"x"}' > "$FILE"
mhs_read_manifest >/dev/null 2>&1; RC=$?
[ $RC -eq 4 ] && ok "schema invalid -> rc4" || no "expected rc4, got rc=$RC"

# 7) checksum is order-independent (canonical) — reorder keys, still valid
mhs_write_manifest "$J" >/dev/null
RAW="$(cat "$FILE")"
# reorder top-level keys via jq -S then re-store WITHOUT recomputing; checksum must still verify
printf '%s' "$RAW" | jq -S '.' > "$FILE.t" && mv "$FILE.t" "$FILE"
mhs_read_manifest >/dev/null 2>&1; RC=$?
[ $RC -eq 0 ] && ok "canonical checksum survives key reorder" || no "reorder broke checksum (rc=$RC)"

echo "== result: PASS=$PASS FAIL=$FAIL =="
[ $FAIL -eq 0 ]

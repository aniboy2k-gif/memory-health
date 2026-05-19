#!/usr/bin/env bash
# memory-journal.sh — Append-only JSONL journal with sha256 chain (Phase C)
#
# Role: tamper-evident audit trail of memory-health mutations.
# Contract:
#   - log appends a single line with current_hash = sha256(entry minus current_hash field).
#   - Each entry references prev_hash (previous current_hash, or "GENESIS" for first).
#   - verify walks the chain and reports breaks.
#   - tail shows recent entries.
#
# Schema (one JSON object per line):
#   { ts, action, files, rules, prev_hash, current_hash, wal_id?, extra }
#
# Environment:
#   CLAUDE_JOURNAL_FILE   Journal file (default: ~/.claude/da-tools/memory-health-journal.jsonl)

set -euo pipefail

JOURNAL_FILE="${CLAUDE_JOURNAL_FILE:-${HOME}/.claude/da-tools/memory-health-journal.jsonl}"
JOURNAL_DIR=$(dirname "$JOURNAL_FILE")
mkdir -p "$JOURNAL_DIR"

cmd="${1:-help}"
shift 2>/dev/null || true

usage() {
  cat <<'EOF'
memory-journal.sh — Append-only JSONL journal with sha256 chain (Phase C)

Usage:
  memory-journal.sh log <action> <files> <rules> [wal_id] [extra_json]
  memory-journal.sh verify              # walk chain + report breaks
  memory-journal.sh tail [N]            # last N entries (default 10)
  memory-journal.sh help                # this help

Environment:
  CLAUDE_JOURNAL_FILE  Journal file (default: ~/.claude/da-tools/memory-health-journal.jsonl)

Notes:
  - extra_json must be a valid JSON object (default: {}).
  - Chain integrity: current_hash = sha256(JSON entry without current_hash field).
  - First entry's prev_hash = "GENESIS".
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ Required command not found: $1" >&2
    exit 1
  }
}

case "$cmd" in
  log)
    action="${1:-}"
    files="${2:-}"
    rules="${3:-}"
    wal_id="${4:-}"
    extra="${5:-}"
    [ -z "$extra" ] && extra='{}'

    [ -n "$action" ] || { echo "❌ action required" >&2; usage >&2; exit 1; }
    [ -n "$files" ]  || { echo "❌ files required" >&2; usage >&2; exit 1; }
    [ -n "$rules" ]  || { echo "❌ rules required" >&2; usage >&2; exit 1; }
    require_cmd shasum
    require_cmd python3

    # previous hash
    if [ -s "$JOURNAL_FILE" ]; then
      prev_hash=$(python3 -c '
import json, sys
last = None
with open(sys.argv[1]) as f:
  for line in f:
    line = line.strip()
    if line:
      last = line
if last:
  try:
    print(json.loads(last).get("current_hash", "GENESIS"))
  except Exception:
    print("GENESIS")
else:
  print("GENESIS")
' "$JOURNAL_FILE")
    else
      prev_hash="GENESIS"
    fi

    ts=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')

    # build entry without current_hash, compute hash, then assemble final line
    entry_no_hash=$(python3 -c '
import json, sys
ts, action, files, rules, prev_hash, wal_id, extra = sys.argv[1:8]
try:
  extra_obj = json.loads(extra)
except Exception:
  extra_obj = {}
e = {
  "ts": ts,
  "action": action,
  "files": files,
  "rules": rules,
  "prev_hash": prev_hash,
  "extra": extra_obj,
}
if wal_id:
  e["wal_id"] = wal_id
print(json.dumps(e, sort_keys=True, ensure_ascii=False))
' "$ts" "$action" "$files" "$rules" "$prev_hash" "$wal_id" "$extra")

    current_hash=$(printf '%s' "$entry_no_hash" | shasum -a 256 | awk '{print $1}')

    final_entry=$(python3 -c '
import json, sys
e = json.loads(sys.argv[1])
e["current_hash"] = sys.argv[2]
print(json.dumps(e, sort_keys=True, ensure_ascii=False))
' "$entry_no_hash" "$current_hash")

    # atomic append (copy-modify-rename)
    tmp_file="${JOURNAL_FILE}.tmp.$$"
    if [ -f "$JOURNAL_FILE" ]; then
      cp "$JOURNAL_FILE" "$tmp_file"
    else
      : > "$tmp_file"
    fi
    printf '%s\n' "$final_entry" >> "$tmp_file"
    mv "$tmp_file" "$JOURNAL_FILE"

    echo "$current_hash"
    ;;

  verify)
    [ -f "$JOURNAL_FILE" ] || { echo "ℹ️  No journal file"; exit 0; }
    require_cmd shasum
    require_cmd python3

    python3 - <<'PYEOF' "$JOURNAL_FILE"
import hashlib, json, sys
path = sys.argv[1]
prev = "GENESIS"
ok = 0
fail = 0
with open(path) as f:
  for line_no, line in enumerate(f, start=1):
    line = line.strip()
    if not line:
      continue
    try:
      entry = json.loads(line)
    except Exception as e:
      print(f"❌ Line {line_no}: invalid JSON ({e})", file=sys.stderr)
      fail += 1
      continue
    claimed_prev = entry.get("prev_hash")
    claimed_curr = entry.get("current_hash")
    if claimed_prev != prev:
      print(f"❌ Line {line_no}: chain break — claimed_prev={claimed_prev}, expected={prev}", file=sys.stderr)
      fail += 1
    # recompute hash (exclude current_hash field)
    e_copy = dict(entry)
    e_copy.pop("current_hash", None)
    recomputed = hashlib.sha256(json.dumps(e_copy, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()
    if recomputed != claimed_curr:
      print(f"❌ Line {line_no}: hash mismatch — recomputed={recomputed}, claimed={claimed_curr}", file=sys.stderr)
      fail += 1
    else:
      ok += 1
    prev = claimed_curr
if fail == 0:
  print(f"✅ Chain verified: {ok} entries")
else:
  print(f"❌ Chain integrity FAILED: {fail} issues over {ok+fail} entries", file=sys.stderr)
  sys.exit(1)
PYEOF
    ;;

  tail)
    n="${1:-10}"
    if [ -f "$JOURNAL_FILE" ]; then
      tail -n "$n" "$JOURNAL_FILE"
    else
      echo "ℹ️  No journal file"
    fi
    ;;

  help|--help|-h|"")
    usage
    ;;

  *)
    echo "❌ Unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac

#!/usr/bin/env bash
# memory-wal.sh — Write-Ahead Log for memory-health atomicity (Phase C)
#
# Role: pre-commit intent record for multi-stage memory-health mutations.
# Contract:
#   - init returns a new wal-id (stdout) and creates a pending WAL file.
#   - commit deletes the WAL file (signals successful completion).
#   - rollback marks the WAL as rolled-back (actual file restore via memory-backup.sh).
#   - list/recover surface orphaned WAL for manual or scripted recovery.
#
# Schema (single JSON object):
#   { wal_id, started_at, files, rules, phase, state_before_sha256, tool_version }
#
# Environment:
#   CLAUDE_WAL_DIR  WAL directory (default: ~/.claude/da-tools/memory-health-wal)

set -euo pipefail

WAL_DIR="${CLAUDE_WAL_DIR:-${HOME}/.claude/da-tools/memory-health-wal}"
TOOL_VERSION="1.1.0"
mkdir -p "$WAL_DIR"

cmd="${1:-help}"
shift 2>/dev/null || true

usage() {
  cat <<'EOF'
memory-wal.sh — Write-Ahead Log for memory-health atomicity (Phase C)

Usage:
  memory-wal.sh init <files> <rules>     # prepare phase, prints wal-id
  memory-wal.sh commit <wal-id>          # commit phase (delete WAL)
  memory-wal.sh rollback <wal-id>        # rollback phase (mark as rolled-back)
  memory-wal.sh list                     # list pending WAL ids
  memory-wal.sh recover                  # detect orphaned WAL + summary
  memory-wal.sh help                     # this help

Environment:
  CLAUDE_WAL_DIR    WAL directory (default: ~/.claude/da-tools/memory-health-wal)

Files: comma-separated absolute paths.
Rules: comma-separated rule ids (R1,R5,...).
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ Required command not found: $1" >&2
    exit 1
  }
}

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

hash_files() {
  local files_csv="$1"
  local IFS=','
  local out=""
  for f in $files_csv; do
    if [ -f "$f" ]; then
      local h
      h=$(shasum -a 256 "$f" | awk '{print $1}')
      out="${out}${f}=${h};"
    else
      out="${out}${f}=MISSING;"
    fi
  done
  echo "$out"
}

case "$cmd" in
  init)
    files="${1:-}"
    rules="${2:-}"
    [ -n "$files" ] || { echo "❌ files required (comma-separated)" >&2; usage >&2; exit 1; }
    [ -n "$rules" ] || { echo "❌ rules required (comma-separated)" >&2; usage >&2; exit 1; }

    require_cmd shasum
    wal_id=$(new_uuid)
    timestamp=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    state_before=$(hash_files "$files")
    wal_file="${WAL_DIR}/${wal_id}.json"

    # atomic write via .tmp + rename
    cat > "${wal_file}.tmp" <<EOF
{
  "wal_id": "${wal_id}",
  "started_at": "${timestamp}",
  "files": "${files}",
  "rules": "${rules}",
  "phase": "prepare",
  "state_before_sha256": "${state_before}",
  "tool_version": "${TOOL_VERSION}"
}
EOF
    mv "${wal_file}.tmp" "${wal_file}"
    echo "${wal_id}"
    ;;

  commit)
    wal_id="${1:-}"
    [ -n "$wal_id" ] || { echo "❌ wal-id required" >&2; exit 1; }
    wal_file="${WAL_DIR}/${wal_id}.json"
    [ -f "$wal_file" ] || { echo "❌ WAL not found: $wal_id" >&2; exit 1; }
    rm -f "$wal_file"
    echo "✅ WAL committed: $wal_id" >&2
    ;;

  rollback)
    wal_id="${1:-}"
    [ -n "$wal_id" ] || { echo "❌ wal-id required" >&2; exit 1; }
    wal_file="${WAL_DIR}/${wal_id}.json"
    [ -f "$wal_file" ] || { echo "❌ WAL not found: $wal_id" >&2; exit 1; }
    mv "$wal_file" "${wal_file}.rolled-back.$(date +%s)"
    echo "✅ WAL rollback marked: $wal_id" >&2
    echo "ℹ️  Restore files via memory-backup.sh or git checkout" >&2
    ;;

  list)
    found=0
    while IFS= read -r f; do
      [ -n "$f" ] && { basename "$f" .json; found=1; }
    done < <(find "$WAL_DIR" -maxdepth 1 -name "*.json" -type f 2>/dev/null)
    [ "$found" -eq 0 ] && echo "ℹ️  No pending WAL" >&2
    ;;

  recover)
    count=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      wal_id=$(basename "$f" .json)
      started=$(grep -o '"started_at": *"[^"]*"' "$f" | head -1 | sed 's/.*: *"//; s/"$//')
      files=$(grep -o '"files": *"[^"]*"' "$f" | head -1 | sed 's/.*: *"//; s/"$//')
      echo "⚠ Orphaned WAL: $wal_id"
      echo "   Started: ${started:-unknown}"
      echo "   Files:   ${files:-unknown}"
      count=$((count + 1))
    done < <(find "$WAL_DIR" -maxdepth 1 -name "*.json" -type f 2>/dev/null)
    if [ "$count" -eq 0 ]; then
      echo "✅ No orphaned WAL"
    else
      echo ""
      echo "Total orphaned WAL: $count"
      echo "Recommendation: run 'memory-wal.sh rollback <wal-id>' for each, then restore via memory-backup.sh"
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

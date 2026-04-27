#!/usr/bin/env bash
# memory-backup.sh — memory directory backup sample
#
# Role: hard-stop gate for step 5 of /memory-health --fix
# Contract: exit 0 = backup succeeded, exit ≠ 0 = backup failed (blocks Optimizer)
#
# This is a sample file. Copy it to ~/.claude/hooks/memory-backup.sh
# and adapt it to your environment. The contract in INTERFACES.md must be upheld.
#
# Installation:
#   cp scripts/memory-backup.sh ~/.claude/hooks/memory-backup.sh
#   chmod +x ~/.claude/hooks/memory-backup.sh

set -euo pipefail

MEMORY_DIR="${CLAUDE_MEMORY_DIR:?'CLAUDE_MEMORY_DIR is not set'}"
BACKUP_DIR="${MEMORY_DIR}/.backups"
TIMESTAMP=$(date +"%Y%m%dT%H%M%S")
BACKUP_DEST="${BACKUP_DIR}/memory-${TIMESTAMP}"

# pre-flight: check write permission and available disk space
if [ ! -w "$(dirname "$BACKUP_DIR")" ] && [ ! -w "$BACKUP_DIR" ] 2>/dev/null; then
  echo "❌ Backup failed: no write permission on parent of $BACKUP_DIR" >&2
  exit 1
fi
AVAILABLE_KB=$(df -k "$MEMORY_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
SOURCE_KB=$(du -sk "$MEMORY_DIR" 2>/dev/null | awk '{print $1}')
if [ -n "$AVAILABLE_KB" ] && [ -n "$SOURCE_KB" ] && [ "$AVAILABLE_KB" -lt "$SOURCE_KB" ]; then
  echo "❌ Backup failed: insufficient disk space (needed: ${SOURCE_KB}KB, available: ${AVAILABLE_KB}KB)" >&2
  exit 1
fi

# create backup directory
mkdir -p "$BACKUP_DEST"

# back up MEMORY.md and all memory/*.md files
SOURCE_FILES=$(find "${MEMORY_DIR}" -maxdepth 1 -name "*.md" 2>/dev/null)
if [ -z "$SOURCE_FILES" ]; then
  echo "❌ Backup failed: no .md files found in $MEMORY_DIR" >&2
  exit 1
fi

SOURCE_COUNT=$(echo "$SOURCE_FILES" | wc -l | tr -d ' ')
SOURCE_BYTES=$(echo "$SOURCE_FILES" | xargs du -cb 2>/dev/null | tail -1 | awk '{print $1}')

echo "$SOURCE_FILES" | xargs cp -t "$BACKUP_DEST" 2>/dev/null || {
  echo "❌ Backup failed: error copying files" >&2
  exit 1
}

# verify backup integrity (file count + byte size)
DEST_COUNT=$(find "${BACKUP_DEST}" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
DEST_BYTES=$(find "${BACKUP_DEST}" -maxdepth 1 -name "*.md" -exec du -cb {} + 2>/dev/null | tail -1 | awk '{print $1}')

if [ "$SOURCE_COUNT" != "$DEST_COUNT" ]; then
  echo "❌ Backup verification failed: source ${SOURCE_COUNT} files → backup ${DEST_COUNT} files (mismatch)" >&2
  exit 1
fi
if [ -n "$SOURCE_BYTES" ] && [ -n "$DEST_BYTES" ] && [ "$SOURCE_BYTES" != "$DEST_BYTES" ]; then
  echo "❌ Backup verification failed: source ${SOURCE_BYTES}B → backup ${DEST_BYTES}B (mismatch)" >&2
  exit 1
fi

echo "✅ Backup complete: $BACKUP_DEST (${SOURCE_COUNT} files)"
# Note: race conditions where the source changes after backup completes cannot be prevented here.

# clean up old backups (keep the most recent 10)
# shellcheck disable=SC2012 # ls is acceptable here; pattern-matched names only (memory-*)
BACKUP_COUNT=$(ls -1d "${BACKUP_DIR}"/memory-* 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt 10 ]; then
  # shellcheck disable=SC2012 # mtime sort via ls -dt; equivalent find recipe is significantly more complex
  ls -1dt "${BACKUP_DIR}"/memory-* | tail -n +11 | xargs rm -rf
  echo "ℹ️  Old backups cleaned up (keeping most recent 10)"
fi

exit 0

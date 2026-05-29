#!/bin/bash
# memory-health-state.sh — pristine-base manifest state library
#
# Role: read/write the rules drift-detection manifest with integrity safeguards.
#   Implements Fix A (pristine base) + M-A (self-checksum + atomic write + recovery).
#   da-chain 4-AI approved design (2026-05-29, CSR #962).
#
# Threat model: "future careless self", NOT an adversary (verification.md).
#   → self-checksum detects ACCIDENTAL corruption/bit-rot, not malicious tampering.
#   → GPG/HMAC intentionally rejected as over-engineering (da-chain consensus).
#
# Manifest schema (rules.manifest.json):
#   { schema_version, self_checksum, updated_at,
#     entries: [ {path, version, bundle_sha256, installed_sha256, installed_at} ] }
#   self_checksum = sha256 of the canonical JSON with self_checksum emptied.
#
# Usage (source this file):
#   source memory-health-state.sh
#   mhs_sha256 <file>            -> sha256 hex (or empty + rc1 if absent)
#   mhs_write_manifest <json>    -> atomic write with computed self_checksum
#   mhs_read_manifest            -> validated JSON on stdout (rc0), else rc != 0
#   mhs_state_file               -> resolved manifest path
#
# NOTE: this is a sourced library — it MUST NOT call `set -e`, which would leak
# into the caller (e.g. the SessionStart hook) and abort it on the first
# non-zero rc. Functions use explicit returns + local `pipefail`. `set -euo
# pipefail` is applied ONLY when the file is executed directly (CLI block below).

MHS_SCHEMA_VERSION="1"

# State dir override for tests: MEMORY_HEALTH_STATE_DIR
mhs_state_dir() {
  echo "${MEMORY_HEALTH_STATE_DIR:-$HOME/.claude/da-tools/memory-health-state}"
}

mhs_state_file() {
  echo "$(mhs_state_dir)/rules.manifest.json"
}

# sha256 of a file. macOS shasum / Linux sha256sum. Empty + rc1 if file absent.
mhs_sha256() {
  local f="$1"
  [ -f "$f" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    sha256sum "$f" | awk '{print $1}'
  fi
}

# sha256 of stdin.
mhs_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# Canonical self-checksum: sha256 of the manifest JSON with self_checksum="".
# jq -S (sorted keys) + compact => deterministic regardless of key order/spacing.
mhs_compute_self_checksum() {
  local json="$1"
  printf '%s' "$json" | jq -Sc '.self_checksum = ""' | mhs_sha256_stdin
}

# Validate manifest shape (schema_version + entries array). rc0 if valid.
mhs_validate_schema() {
  local json="$1"
  printf '%s' "$json" | jq -e \
    '(.schema_version|type=="string") and (.entries|type=="array")' \
    >/dev/null 2>&1
}

# Atomic write with computed self_checksum. Arg = manifest JSON (without/with self_checksum).
mhs_write_manifest() {
  local json="$1"
  local dir file tmp checksum stamped
  dir="$(mhs_state_dir)"
  file="$(mhs_state_file)"
  mkdir -p "$dir"

  # ensure schema_version + updated_at present, then stamp checksum
  json="$(printf '%s' "$json" | jq \
    --arg sv "$MHS_SCHEMA_VERSION" \
    '.schema_version = (.schema_version // $sv) | .self_checksum = ""')"
  checksum="$(mhs_compute_self_checksum "$json")"
  stamped="$(printf '%s' "$json" | jq --arg c "$checksum" '.self_checksum = $c')"

  tmp="$(mktemp "${dir}/.rules.manifest.XXXXXX")"
  printf '%s\n' "$stamped" > "$tmp"
  # validate the temp before swap (fail-closed: never install a broken manifest)
  if ! mhs_validate_schema "$(cat "$tmp")"; then
    rm -f "$tmp"
    echo "mhs_write_manifest: schema validation failed, aborting write" >&2
    return 1
  fi
  mv -f "$tmp" "$file"
}

# Read + validate. rc0 + JSON on stdout when intact.
# rc2 = missing file, rc3 = unparseable, rc4 = schema invalid, rc5 = checksum mismatch.
mhs_read_manifest() {
  local file json stored recomputed
  file="$(mhs_state_file)"
  [ -f "$file" ] || { echo "mhs_read_manifest: manifest absent: $file" >&2; return 2; }
  json="$(cat "$file")"
  if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    echo "mhs_read_manifest: unparseable JSON (corruption): $file" >&2
    return 3
  fi
  if ! mhs_validate_schema "$json"; then
    echo "mhs_read_manifest: schema invalid: $file" >&2
    return 4
  fi
  stored="$(printf '%s' "$json" | jq -r '.self_checksum // ""')"
  recomputed="$(mhs_compute_self_checksum "$json")"
  if [ "$stored" != "$recomputed" ]; then
    echo "mhs_read_manifest: self_checksum mismatch (accidental corruption?): stored=$stored recomputed=$recomputed" >&2
    return 5
  fi
  printf '%s\n' "$json"
}

# If sourced, return. If executed directly, expose a tiny CLI for tests/debug.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  set -euo pipefail
  cmd="${1:-}"
  case "$cmd" in
    state-file) mhs_state_file ;;
    sha256)     mhs_sha256 "${2:?file}" ;;
    read)       mhs_read_manifest ;;
    write)      mhs_write_manifest "$(cat "${2:-/dev/stdin}")" ;;
    *) echo "usage: memory-health-state.sh {state-file|sha256 <f>|read|write [jsonfile]}" >&2; exit 64 ;;
  esac
fi

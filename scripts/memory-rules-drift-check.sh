#!/bin/bash
# memory-rules-drift-check.sh — rules drift detector + SessionStart hook (C-1)
#
# Detects silent divergence across the 3-layer rules chain (CSR #962, da-chain 4-AI):
#   axis0  canonical (claude-forge) <-> bundle (~/.claude/skills/...)  [C-2: trust root]
#   axis1  active (CLAUDE_MEMORY_DIR) <-> manifest installed_sha256    [user modified?]
#   axis2  bundle version            <-> manifest version             [upstream updated?]
#
# Advisory only (stderr warnings) — never blocks. Threat model = careless self.
# Self-heals: missing/corrupt manifest -> re-baseline from bundle + warn.
#
# Modes:
#   (no args)         SessionStart hook: emit stderr advisory, always exit 0
#   --check           same detection, human-readable to stdout, exit 0/1 (1=drift)
#   --json            machine-readable findings (for tests)
#
# Path overrides (tests): MH_ACTIVE_RULES, MH_BUNDLE_RULES, MH_CANONICAL_RULES

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/memory-health-state.sh"

mrdc_active_rules() {
  echo "${MH_ACTIVE_RULES:-${CLAUDE_MEMORY_DIR:-$HOME/.claude/projects/-Users-anbaesig/memory}/memory-health-rules.md}"
}
mrdc_bundle_rules() {
  echo "${MH_BUNDLE_RULES:-$HOME/.claude/skills/memory-health/memory-health-rules.md}"
}
mrdc_canonical_rules() {
  # NOTE: the default path contains an apostrophe (L'Atelier). macOS bash 3.2
  # mis-parses a single quote inside "${VAR:-...}" as opening a quote, which
  # silently swallows following function definitions. Keep the apostrophe OUT
  # of parameter-expansion default — use a plain double-quoted echo instead.
  if [ -n "${MH_CANONICAL_RULES:-}" ]; then echo "$MH_CANONICAL_RULES"; return; fi
  echo "/Volumes/L'Atelier de Claude/workspace/claude-forge/skills/memory-health/memory-health-rules.md"
}

# Extract "# version: X" -> X (empty if absent).
mrdc_version_of() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -m1 '^# version:' "$f" 2>/dev/null | sed 's/^# version:[[:space:]]*//' | tr -d '[:space:]'
}

# Re-baseline: (re)write the manifest entry for the active file from current bundle.
mrdc_rebaseline() {
  local active bundle a_sha b_ver json
  active="$(mrdc_active_rules)"; bundle="$(mrdc_bundle_rules)"
  a_sha="$(mhs_sha256 "$active" 2>/dev/null || echo "")"
  b_ver="$(mrdc_version_of "$bundle")"
  json="$(jq -nc \
    --arg path "$active" --arg ver "$b_ver" \
    --arg bsha "$(mhs_sha256 "$bundle" 2>/dev/null || echo "")" \
    --arg isha "$a_sha" --arg at "${MH_NOW:-unknown}" \
    '{schema_version:"1", entries:[{path:$path, version:$ver, bundle_sha256:$bsha, installed_sha256:$isha, installed_at:$at}]}')"
  mhs_write_manifest "$json"
}

# Core detection. Emits finding tokens (one per line) to stdout. rc0 always.
# Tokens: OK | AXIS0_CANONICAL_BUNDLE_DRIFT | AXIS1_USER_MODIFIED |
#         AXIS2_UPSTREAM_UPDATED | MANIFEST_RECOVERED | ACTIVE_ABSENT
mrdc_detect() {
  local active bundle canon manifest entry findings=()
  active="$(mrdc_active_rules)"; bundle="$(mrdc_bundle_rules)"; canon="$(mrdc_canonical_rules)"

  [ -f "$active" ] || { echo "ACTIVE_ABSENT"; return 0; }

  # axis0: canonical <-> bundle (only if both accessible)
  if [ -f "$canon" ] && [ -f "$bundle" ]; then
    if [ "$(mhs_sha256 "$canon")" != "$(mhs_sha256 "$bundle")" ]; then
      findings+=("AXIS0_CANONICAL_BUNDLE_DRIFT")
    fi
  fi

  # manifest read; self-heal on any failure
  if ! manifest="$(mhs_read_manifest 2>/dev/null)"; then
    mrdc_rebaseline >/dev/null 2>&1 && findings+=("MANIFEST_RECOVERED")
    manifest="$(mhs_read_manifest 2>/dev/null || echo '{"entries":[]}')"
  fi

  entry="$(printf '%s' "$manifest" | jq -c --arg p "$active" '.entries[]? | select(.path==$p)' 2>/dev/null | head -1)"
  if [ -n "$entry" ]; then
    # axis1: active content vs recorded installed_sha256
    local rec_sha cur_sha rec_ver cur_ver
    rec_sha="$(printf '%s' "$entry" | jq -r '.installed_sha256 // ""')"
    cur_sha="$(mhs_sha256 "$active")"
    [ -n "$rec_sha" ] && [ "$rec_sha" != "$cur_sha" ] && findings+=("AXIS1_USER_MODIFIED")
    # axis2: manifest recorded version vs current bundle version
    rec_ver="$(printf '%s' "$entry" | jq -r '.version // ""')"
    cur_ver="$(mrdc_version_of "$bundle")"
    [ -n "$cur_ver" ] && [ -n "$rec_ver" ] && [ "$rec_ver" != "$cur_ver" ] && findings+=("AXIS2_UPSTREAM_UPDATED")
  fi

  if [ ${#findings[@]} -eq 0 ]; then echo "OK"; else printf '%s\n' "${findings[@]}"; fi
  return 0
}

# Human-readable advisory lines for a finding token.
mrdc_explain() {
  case "$1" in
    OK) echo "✅ rules 정합 — 드리프트 없음" ;;
    ACTIVE_ABSENT) echo "ℹ️ 활성 rules 파일 없음 (미설치) — $(mrdc_active_rules)" ;;
    MANIFEST_RECOVERED) echo "⚠ 매니페스트 부재/손상 → 번들에서 재기준선 (다음 check부터 정상)" ;;
    AXIS0_CANONICAL_BUNDLE_DRIFT) echo "🔴 canonical↔번들 분기 — 번들이 canonical과 다름 (사고 진원지 유형). canonical sync 필요" ;;
    AXIS1_USER_MODIFIED) echo "🟡 활성본이 설치 시점과 다름 (사용자 수정?). 의도적이면 'memory-health acknowledge'로 재기준선" ;;
    AXIS2_UPSTREAM_UPDATED) echo "🟡 번들 템플릿 버전이 갱신됨 — 'memory-health fix' 또는 upgrade 검토" ;;
    *) echo "? 알 수 없는 finding: $1" ;;
  esac
}

mrdc_main() {
  local mode="${1:-hook}"

  # H-1 acknowledge: user confirms intentional edits -> re-baseline (mutating).
  if [ "$mode" = "--acknowledge" ]; then
    if mrdc_rebaseline; then
      echo "✅ 재기준선 완료 — 현재 활성본을 새 base로 기록. 이후 axis1 경고 해제."
      return 0
    else
      echo "❌ 재기준선 실패" >&2; return 1
    fi
  fi

  # H-2 diff: actionable comparison active vs bundle (read-only).
  if [ "$mode" = "--diff" ]; then
    local active bundle; active="$(mrdc_active_rules)"; bundle="$(mrdc_bundle_rules)"
    [ -f "$active" ] || { echo "활성본 없음: $active" >&2; return 1; }
    [ -f "$bundle" ] || { echo "번들 없음: $bundle" >&2; return 1; }
    if diff -u "$bundle" "$active" >/dev/null 2>&1; then
      echo "✅ 활성본 == 번들 템플릿 (차이 없음)"
      return 0
    fi
    echo "=== diff: 번들(템플릿) → 활성본 ==="
    diff -u "$bundle" "$active" || true
    return 0
  fi

  local findings; findings="$(mrdc_detect)"
  case "$mode" in
    --json)
      printf '%s' "$findings" | jq -R . | jq -sc '{findings:.}'
      ;;
    --check)
      echo "=== rules drift check ==="
      while IFS= read -r f; do [ -n "$f" ] && mrdc_explain "$f"; done <<< "$findings"
      printf '%s' "$findings" | grep -qE 'AXIS' && return 1 || return 0
      ;;
    *)  # hook: stderr advisory only, never block
      if printf '%s' "$findings" | grep -qE 'AXIS|RECOVERED'; then
        echo "[memory-health] rules 드리프트 감지:" >&2
        while IFS= read -r f; do [ -n "$f" ] && [ "$f" != "OK" ] && echo "  $(mrdc_explain "$f")" >&2; done <<< "$findings"
        echo "  → 자세히: /memory-health --rules 또는 memory-rules-drift-check.sh --check" >&2
      fi
      return 0
      ;;
  esac
}

if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  mrdc_main "${1:-hook}"
  exit $?
fi

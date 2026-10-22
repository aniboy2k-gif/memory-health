#!/bin/bash
# test-drift-check.sh — regression tests for memory-rules-drift-check.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/memory-rules-drift-check.sh"

PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/drift-test.XXXXXX")"
export MEMORY_HEALTH_STATE_DIR="$WORK/state"
export MH_ACTIVE_RULES="$WORK/active.md"
export MH_BUNDLE_RULES="$WORK/bundle.md"
export MH_CANONICAL_RULES="$WORK/canonical.md"
export MH_NOW="2026-05-29T00:00:00Z"
# CSR #2419: isolate the 30-day audit notice from the real ~/.claude/da-tools/claude-md-audit-last
export MH_AUDIT_LAST="$WORK/audit-last"
export MH_NOW_EPOCH=1800000000
unset CLAUDE_MD_AUDIT_INTERVAL
trap 'rm -rf "$WORK"' EXIT

mk(){ printf '# version: %s\n# rules\n%s\n' "$1" "$2" > "$3"; }

# returns the finding tokens joined
findings(){ bash "$SCRIPT" --json | jq -r '.findings[]' | grep -v '^$' | sort | tr '\n' ',' ; }

echo "== memory-rules-drift-check.sh tests =="

# Baseline: canonical==bundle==active, manifest baselined => OK
mk "1.1.0" "BODY" "$MH_CANONICAL_RULES"
cp "$MH_CANONICAL_RULES" "$MH_BUNDLE_RULES"
cp "$MH_BUNDLE_RULES" "$MH_ACTIVE_RULES"
# first run self-heals (no manifest) then should be OK on second
bash "$SCRIPT" --json >/dev/null 2>&1   # recover/baseline
R="$(findings)"
[ "$R" = "OK," ] && ok "all-aligned -> OK" || no "expected OK, got [$R]"

# axis1: user modifies active
printf '\n# user tweak\n' >> "$MH_ACTIVE_RULES"
R="$(findings)"
echo "$R" | grep -q "AXIS1_USER_MODIFIED" && ok "active edit -> AXIS1_USER_MODIFIED" || no "axis1 miss [$R]"

# acknowledge (re-baseline) clears axis1
bash "$SCRIPT" --json >/dev/null 2>&1  # detection only; rebaseline happens on recovery
# simulate acknowledge by rebaselining via state lib through the script's function
( source "$SCRIPT"; mrdc_rebaseline >/dev/null 2>&1 )
R="$(findings)"
echo "$R" | grep -q "AXIS1_USER_MODIFIED" && no "axis1 should clear after rebaseline [$R]" || ok "rebaseline clears axis1"

# axis2: bundle version bumped
mk "1.2.0" "BODY" "$MH_BUNDLE_RULES"
R="$(findings)"
echo "$R" | grep -q "AXIS2_UPSTREAM_UPDATED" && ok "bundle version bump -> AXIS2_UPSTREAM_UPDATED" || no "axis2 miss [$R]"

# axis0: canonical != bundle
mk "9.9.9" "DIFFERENT" "$MH_CANONICAL_RULES"
R="$(findings)"
echo "$R" | grep -q "AXIS0_CANONICAL_BUNDLE_DRIFT" && ok "canonical!=bundle -> AXIS0 drift" || no "axis0 miss [$R]"

# active absent
rm -f "$MH_ACTIVE_RULES"
R="$(findings)"
[ "$R" = "ACTIVE_ABSENT," ] && ok "absent active -> ACTIVE_ABSENT" || no "expected ACTIVE_ABSENT [$R]"

# manifest corruption self-heal
cp "$MH_BUNDLE_RULES" "$MH_ACTIVE_RULES"
echo "{ corrupt" > "$MEMORY_HEALTH_STATE_DIR/rules.manifest.json"
R="$(findings)"
echo "$R" | grep -q "MANIFEST_RECOVERED" && ok "corrupt manifest -> MANIFEST_RECOVERED" || no "recovery miss [$R]"

# hook mode never blocks (exit 0)
bash "$SCRIPT" >/dev/null 2>&1; [ $? -eq 0 ] && ok "hook mode exit 0 (advisory)" || no "hook mode non-zero"

# H-1/H-2: fresh setup for acknowledge + diff
mk "1.1.0" "BODY" "$MH_CANONICAL_RULES"; cp "$MH_CANONICAL_RULES" "$MH_BUNDLE_RULES"; cp "$MH_BUNDLE_RULES" "$MH_ACTIVE_RULES"
bash "$SCRIPT" --json >/dev/null 2>&1                 # baseline
printf '# user line\n' >> "$MH_ACTIVE_RULES"          # intentional edit
bash "$SCRIPT" --diff 2>/dev/null | grep -q "user line" && ok "--diff shows user changes" || no "--diff missing changes"
bash "$SCRIPT" --acknowledge >/dev/null 2>&1 && ok "--acknowledge succeeds" || no "--acknowledge failed"
R="$(findings)"; echo "$R" | grep -q "AXIS1" && no "axis1 should clear after acknowledge [$R]" || ok "acknowledge clears axis1"

# ── CSR #2419: 30-day CLAUDE.md audit notice + drift advisory on stdout ──
# hook(): run hook mode, stdout -> $OUT, stderr -> $ERR, rc -> $RC
hook(){ bash "$SCRIPT" >"$WORK/out" 2>"$WORK/err"; RC=$?; OUT="$(cat "$WORK/out")"; ERR="$(cat "$WORK/err")"; }
days_ago(){ echo $(( MH_NOW_EPOCH - $1 * 86400 )); }

# aligned rules (no drift) for the pure notice cases
bash "$SCRIPT" --acknowledge >/dev/null 2>&1

days_ago 31 > "$MH_AUDIT_LAST"; hook
echo "$OUT" | grep -q "31일 경과 (주기 30일)" && ok "audit 31d -> stdout notice" || no "audit 31d notice missing [$OUT]"
[ "$RC" -eq 0 ] && ok "audit 31d -> exit 0" || no "audit 31d rc=$RC"
echo "$ERR" | grep -q "감사" && no "audit notice leaked to stderr [$ERR]" || ok "audit notice not on stderr"

days_ago 1 > "$MH_AUDIT_LAST"; hook
echo "$OUT" | grep -q "감사" && no "fresh 1d should be silent [$OUT]" || ok "audit 1d -> no notice"

rm -f "$MH_AUDIT_LAST"; hook
echo "$OUT" | grep -q "감사 기록 없음 (주기 30일)" && ok "audit absent -> 기록 없음" || no "absent notice missing [$OUT]"

echo "garbage" > "$MH_AUDIT_LAST"; hook
echo "$OUT" | grep -q "감사 기록을 읽을 수 없음" && ok "audit garbage -> 읽을 수 없음" || no "garbage notice missing [$OUT]"

echo $(( MH_NOW_EPOCH + 86400 )) > "$MH_AUDIT_LAST"; hook
echo "$OUT" | grep -q "미래" && ok "audit future -> 미래 시각 notice" || no "future notice missing [$OUT]"

days_ago 8 > "$MH_AUDIT_LAST"; CLAUDE_MD_AUDIT_INTERVAL=7 hook
echo "$OUT" | grep -q "8일 경과 (주기 7일)" && ok "interval 7, 8d -> 주기 7일" || no "custom interval notice wrong [$OUT]"

# drift advisory must reach stdout (stderr never reaches Claude on exit 0) — with a drift present
days_ago 1 > "$MH_AUDIT_LAST"
printf '# drift line\n' >> "$MH_ACTIVE_RULES"; hook
echo "$OUT" | grep -q "rules 드리프트 감지" && ok "drift advisory on stdout" || no "drift advisory not on stdout [$OUT]"
echo "$ERR" | grep -q "rules 드리프트 감지" && no "drift advisory still on stderr" || ok "drift advisory not on stderr"
[ "$RC" -eq 0 ] && ok "drift hook exit 0" || no "drift hook rc=$RC"

# H-1: malformed values must not abort the hook (bash arithmetic on 08/0999 kills the shell)
bad_case(){ # $1=label  $2=expected-notice-substring-or-empty
  hook
  [ "$RC" -eq 0 ] && ok "$1 -> exit 0" || no "$1 -> rc=$RC"
  echo "$OUT" | grep -q "rules 드리프트 감지" && ok "$1 -> drift advisory kept" || no "$1 -> drift advisory lost [$OUT]"
  if [ -n "$2" ]; then echo "$OUT" | grep -q "$2" && ok "$1 -> '$2'" || no "$1 -> expected '$2' [$OUT]"; fi
}
echo "0999" > "$MH_AUDIT_LAST"; bad_case "content 0999" "읽을 수 없음"
echo "12345678901234567890" > "$MH_AUDIT_LAST"; bad_case "content 20-digit" "읽을 수 없음"
days_ago 31 > "$MH_AUDIT_LAST"
for iv in 08 abc 0 -5; do CLAUDE_MD_AUDIT_INTERVAL="$iv" bad_case "interval $iv" "31일 경과 (주기 30일)"; done

echo "== result: PASS=$PASS FAIL=$FAIL =="
[ $FAIL -eq 0 ]

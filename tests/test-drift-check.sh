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

echo "== result: PASS=$PASS FAIL=$FAIL =="
[ $FAIL -eq 0 ]

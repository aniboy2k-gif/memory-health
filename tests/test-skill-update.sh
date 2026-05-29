#!/bin/bash
# test-skill-update.sh — regression tests for check-skill-update.sh
# Uses a local file:// remote (no internet needed).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/check-skill-update.sh"

PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skillupd.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export MEMORY_HEALTH_STATE_DIR="$WORK/state"
export MH_REMOTE_COOLDOWN=14400

# Deterministic git env (CI-robust): isolated config, main default, file:// allowed.
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
git config -f "$WORK/gitconfig" init.defaultBranch main
git config -f "$WORK/gitconfig" user.email t@t
git config -f "$WORK/gitconfig" user.name t
git config -f "$WORK/gitconfig" protocol.file.allow always

# bare "remote" + working repo (init+push, not clone-of-empty)
git init -q --bare -b main "$WORK/remote.git"
git init -q -b main "$WORK/clone"
cd "$WORK/clone"
echo v1 > f.txt; git add f.txt; git commit -qm c1
git remote add origin "$WORK/remote.git"
git push -q -u origin main
export MH_SKILL_REPO="$WORK/clone"

echo "== check-skill-update.sh tests =="

# 1) up-to-date => no output
OUT="$(bash "$SCRIPT" --force 2>&1)"
[ -z "$OUT" ] && ok "up-to-date -> no advisory" || no "expected silence, got [$OUT]"

# advance remote by 2 commits (simulate upstream ahead)
git clone -q "$WORK/remote.git" "$WORK/clone2" 2>/dev/null
( cd "$WORK/clone2"; git config user.email t@t; git config user.name t
  echo v2 > f.txt; git commit -qam c2; echo v3 > f.txt; git commit -qam c3; git push -q origin main )

# 2) behind => advisory with count
OUT="$(bash "$SCRIPT" --force 2>&1)"
echo "$OUT" | grep -q "2 commit" && ok "behind by 2 -> advisory shows count" || no "expected '2 commit', got [$OUT]"
echo "$OUT" | grep -q "git pull" && ok "advisory suggests git pull" || no "no pull hint [$OUT]"

# 3) cooldown => silent even when behind (marker is fresh from test 2)
OUT="$(bash "$SCRIPT" 2>&1)"   # no --force => respect cooldown
[ -z "$OUT" ] && ok "cooldown active -> silent" || no "expected cooldown silence [$OUT]"

# 4) non-git repo => graceful exit 0, no output
export MH_SKILL_REPO="$WORK/notarepo"; mkdir -p "$WORK/notarepo"
OUT="$(bash "$SCRIPT" --force 2>&1)"; RC=$?
[ -z "$OUT" ] && [ $RC -eq 0 ] && ok "non-git repo -> graceful silent exit 0" || no "expected graceful, got rc=$RC [$OUT]"

# 5) offline (bogus remote) => graceful exit 0
( cd "$WORK/clone"; git remote set-url origin "file://$WORK/nonexistent-remote.git" )
export MH_SKILL_REPO="$WORK/clone"
OUT="$(bash "$SCRIPT" --force 2>&1)"; RC=$?
[ $RC -eq 0 ] && ok "offline/bad-remote -> exit 0 (no crash)" || no "expected exit 0, got rc=$RC"

echo "== result: PASS=$PASS FAIL=$FAIL =="
[ $FAIL -eq 0 ]

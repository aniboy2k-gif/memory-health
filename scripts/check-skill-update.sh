#!/bin/bash
# check-skill-update.sh — is the installed memory-health skill behind its remote?
#
# Wired into `/memory-health` default run (SKILL.md step ①). Fetches from the
# skill's git remote (internet) and warns if a newer version is available.
# CSR #962 — mirrors the proven forge-update-check.sh pattern:
#   - 4h cooldown marker (avoid fetching every run)
#   - 4s fetch timeout (macOS lacks `timeout`; use python3 subprocess like the prior-art)
#   - exit 0 ALWAYS (offline / timeout / non-repo all graceful, never blocks)
#
# Modes:  (default) run check | --force ignore cooldown (testing)
# Env overrides (tests): MEMORY_HEALTH_STATE_DIR, MH_REMOTE_COOLDOWN, MH_SKILL_REPO

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${MEMORY_HEALTH_STATE_DIR:-$HOME/.claude/da-tools/memory-health-state}"
MARKER="$STATE_DIR/.remote-check-last"
COOLDOWN="${MH_REMOTE_COOLDOWN:-14400}"   # 4h
FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1

MSG=$(python3 - "$HERE" "$MARKER" "$COOLDOWN" "$FORCE" "${MH_SKILL_REPO:-}" <<'PY'
import sys, os, subprocess, time

here, marker, cooldown, force, repo_override = (
    sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4] == "1", sys.argv[5]
)

def git(args, cwd, t=2):
    return subprocess.run(['git', '-C', cwd] + args,
                          capture_output=True, text=True, timeout=t)

# resolve skill repo root (override for tests, else git toplevel of script dir)
repo = repo_override
if not repo:
    try:
        repo = git(['rev-parse', '--show-toplevel'], here).stdout.strip()
    except Exception:
        sys.exit(0)
if not repo or not os.path.isdir(os.path.join(repo, '.git')):
    sys.exit(0)

# cooldown (skip if --force)
if not force and os.path.exists(marker):
    try:
        if time.time() - float(open(marker).read().strip()) < cooldown:
            sys.exit(0)
    except Exception:
        pass  # unreadable marker -> proceed

# fetch (4s timeout) — offline/timeout => graceful exit
try:
    r = git(['fetch', 'origin', '--quiet'], repo, t=4)
    if r.returncode != 0:
        sys.exit(0)
except Exception:
    sys.exit(0)

# default branch (dynamic)
try:
    ref = git(['symbolic-ref', 'refs/remotes/origin/HEAD'], repo).stdout.strip()
    br = ref.replace('refs/remotes/origin/', '') if ref else 'main'
except Exception:
    br = 'main'

try:
    local = git(['rev-parse', 'HEAD'], repo).stdout.strip()
    remote = git(['rev-parse', f'origin/{br}'], repo).stdout.strip()
    behind = git(['rev-list', '--count', f'HEAD..origin/{br}'], repo).stdout.strip()
    # stamp marker only after a successful comparison
    os.makedirs(os.path.dirname(marker), exist_ok=True)
    try:
        open(marker, 'w').write(str(time.time()))
    except Exception:
        pass
    if local and remote and local != remote and behind not in ('', '0'):
        print(f'[memory-health] skill 업데이트 {behind} commit 있음 (origin/{br}). '
              f'적용: cd {repo} && git pull')
except Exception:
    sys.exit(0)
PY
)

[ -n "$MSG" ] && echo "$MSG"
exit 0

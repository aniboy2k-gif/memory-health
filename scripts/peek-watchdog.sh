#!/bin/bash
# peek-watchdog.sh — detector liveness for memory-health's routine peek (CSR #2491 D1).
#
# Install by COPY (not symlink) into the home-real folder $MH_LOCAL_DIR (default: the
# memory-health-local folder in the Claude config dir) and register it as a second SessionStart
# command, so it still runs when the folder holding memory-rules-drift-check.sh is unmounted,
# missing or dropped from settings.
#
# Prints exactly one line `routine detector stale (peek-last <ts|absent>)` when peek missed the
# previous session: peek-last is older than this watchdog's previous run (minus a 60 s slack for
# hook order — SessionStart hooks run in parallel) or absent while watchdog-last exists. Else
# nothing. Then rewrites watchdog-last. Idle gaps cause no alarm (both stamps age together).
# Runtime: /bin/bash 3.2, no python. Always exits 0.

D="${MH_LOCAL_DIR:-$HOME/.claude/memory-health-local}"
P="$D/peek-last"
W="$D/watchdog-last"
SLACK=60

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

if [ -f "$W" ]; then
  w="$(mtime "$W")"
  if [ ! -f "$P" ]; then
    echo "routine detector stale (peek-last absent)"
  else
    p="$(mtime "$P")"
    if [ -n "$p" ] && [ -n "$w" ] && [ "$p" -lt $((w - SLACK)) ]; then
      echo "routine detector stale (peek-last $(date -u -r "$p" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$p"))"
    fi
  fi
fi
mkdir -p "$D" 2>/dev/null && touch "$W" 2>/dev/null
exit 0

#!/bin/bash
# audit-record.sh — deterministic state keeper for memory-health's monthly routine (CSR #2450).
#
# The routine has two parts, each with its own last-run marker:
#   audit  part: the read-only subagent `memory-health-prompt-auditor-ro` applies the bundled
#                prompt-audit procedure to a fixed manifest of instruction files.
#   update part: the skill-advisor update CHECK (`update.py --json`; never `--apply`).
# This script decides every state. The model only spawns the auditor and saves its final message.
#
# Subcommands:
#   pre [--cwd DIR]                       validate auditor + scope, write the run dir, print STATE/RUN_DIR
#   post <run-dir> <report-file> [--dry-run]   check the auditor report, refresh the audit marker on REPORTED
#   update-check [--dry-run]              run the update check, refresh the update marker on PASS
#
# States (stdout `STATE=<name>`; first failing check wins):
#   pre   : AUDITOR_SHADOWED | AUDITOR_MISCONFIGURED | ENGINE_UNAVAILABLE | SCOPE_UNRESOLVED | READY
#   post  : AUDITOR_CHANGED | SCOPE_CHANGED_DURING_AUDIT | AUDIT_INCOMPLETE | REPORTED
#   update: UPDATE_CHECK_FAILED | UPDATE_CHECK_PASS
# Only REPORTED writes $STATE/claude-md-audit-last; only UPDATE_CHECK_PASS writes
# $STATE/skill-update-check-last. --dry-run writes neither marker, no jsonl line and no saved
# report (it prints the record instead).
#
# Honest scope: the auditor's tool calls are read-only provided the invoked agent actually uses
# the validated read-only definition and Claude Code enforces its tool allowlist. Pre/post hashing
# detects persistent definition changes but cannot establish that the definition remained
# unchanged throughout invocation. A matching hash does not certify runtime definition integrity.
# REPORTED means the auditor reported the last line number of every file correctly without being
# given it — evidence it opened each file; neither full reading nor review quality is proven.
#
# Env overrides (tests): MH_HOME (default $HOME), MH_STATE_DIR (default $MH_HOME/.claude/da-tools),
#   MH_PROCEDURE (default $MH_HOME/.claude/skills/claude-api/shared/prompt-audit.md),
#   MH_UPDATE_CMD (inner command, run under the timeout wrapper), MH_UPDATE_TIMEOUT (s, default 300),
#   MH_NOW_EPOCH, MH_AUDIT_JSONL (jsonl path; default $STATE/claude-md-audit.jsonl).
# Runtime: macOS /bin/bash 3.2 — no associative arrays, no mapfile, no ${var,,}.

set -u
umask 077

MH_HOME="${MH_HOME:-$HOME}"
STATE="${MH_STATE_DIR:-$MH_HOME/.claude/da-tools}"
PROCEDURE="${MH_PROCEDURE:-$MH_HOME/.claude/skills/claude-api/shared/prompt-audit.md}"
AGENT_NAME="memory-health-prompt-auditor-ro"
USER_AGENTS="$MH_HOME/.claude/agents"
# MH_AUDIT_JSONL: test-only override (some sandboxes refuse writes to any *-audit*.jsonl name)
JSONL="${MH_AUDIT_JSONL:-$STATE/claude-md-audit.jsonl}"
AUDIT_MARKER="$STATE/claude-md-audit-last"
UPDATE_MARKER="$STATE/skill-update-check-last"
UPDATE_FAILED="$STATE/skill-update-failed.json"
REPORTS_DIR="$STATE/claude-md-audit-reports"
RUNS_DIR="$STATE/claude-md-audit-runs"
REPORTS_KEEP=12

die_usage() { echo "usage: audit-record.sh pre [--cwd DIR] | post <run-dir> <report-file> [--dry-run] | update-check [--dry-run]" >&2; exit 64; }

now_epoch() {
  local re='^[1-9][0-9]{0,11}$' n="${MH_NOW_EPOCH:-}"
  if [[ $n =~ $re ]]; then echo "$n"; else date +%s; fi
}
fmt_epoch() { # $1 epoch, $2 format (UTC)
  date -u -r "$1" "$2" 2>/dev/null || date -u -d "@$1" "$2" 2>/dev/null
}
iso_ts() { fmt_epoch "$(now_epoch)" '+%Y-%m-%dT%H:%M:%SZ'; }
file_ts() { fmt_epoch "$(now_epoch)" '+%Y%m%dT%H%M%SZ'; }

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else sha256sum "$1" 2>/dev/null | awk '{print $1}'; fi
}

# logical line count: an unterminated final line counts; empty file = 0
line_count() { awk 'END{print NR}' "$1" 2>/dev/null; }

# write $2 into $1 atomically (tmp + mv)
atomic_write() {
  local dst="$1" tmp
  tmp="$dst.tmp.$$"
  printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$dst"
}

append_jsonl() { # $1 json line, $2 dry-run flag
  if [ "$2" = "1" ]; then echo "RECORD=$1"; return 0; fi
  if ! { mkdir -p "$(dirname "$JSONL")" && printf '%s\n' "$1" >> "$JSONL"; } 2>/dev/null; then
    echo "WARN=jsonl append failed: $JSONL"
  fi
  echo "RECORD=$1"
}

# ── frontmatter helpers ─────────────────────────────────────────────────────
# fm_block <file>: prints the frontmatter lines (between the first two `---`), CR stripped.
# rc 1 when line 1 is not `---` or the block is unterminated.
fm_block() {
  awk '
    { sub(/\r$/, "") }
    NR==1 { if ($0 != "---") exit 2; next }
    $0 == "---" { closed=1; exit 0 }
    { print }
    END { if (!closed) exit 1 }
  ' "$1" 2>/dev/null
}
# fm_name <file>: the unquoted value of the top-level `name:` key (empty when absent/invalid)
fm_name() {
  local blk
  blk="$(fm_block "$1")" || return 0
  printf '%s\n' "$blk" | awk '/^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }' | tr -d "\"'"
}

# ── pre ─────────────────────────────────────────────────────────────────────
PRE_REASON=""
pre_fail() { # $1 state, $2 reason
  local rec
  echo "STATE=$1"
  [ -n "$2" ] && echo "REASON=$2"
  rec="$(jq -nc --arg ts "$(iso_ts)" --arg st "$1" --arg r "$2" \
    '{ts:$ts, part:"audit", step:"pre", state:$st, reason:$r}')"
  append_jsonl "$rec" 0 >/dev/null
  exit 1
}

MATCHES=""          # newline-separated unique real files whose name == AGENT_NAME
MATCH_COUNT=0
USER_MATCH=""       # the match found under the user-level dir (if any)

# Newline-separated lists are walked with `for` + IFS=newline + noglob (no here-documents:
# some sandboxes forbid the temp file bash 3.2 needs for one).
NL='
'
add_match() { # $1 file, $2 "user"|"project"
  local f="$1" m IFS="$NL"
  set -f
  for m in $MATCHES; do
    if [ "$m" -ef "$f" ]; then
      set +f
      [ "$2" = "user" ] && USER_MATCH="$m"
      return 0
    fi
  done
  set +f
  MATCHES="$MATCHES$f$NL"
  MATCH_COUNT=$((MATCH_COUNT + 1))
  [ "$2" = "user" ] && USER_MATCH="$f"
  return 0
}

scan_agents_dir() { # $1 dir, $2 kind
  local d="$1" f files IFS="$NL"
  [ -d "$d" ] || return 0
  files="$(find -L "$d" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)"
  set -f
  for f in $files; do
    [ "$(fm_name "$f")" = "$AGENT_NAME" ] && add_match "$f" "$2"
  done
  set +f
  return 0
}

# validate_definition <file>: echoes "" when valid, else the reason
validate_definition() {
  local f="$1" blk keys nkeys bad tools model
  [ -f "$f" ] || { echo "definition missing"; return; }
  blk="$(fm_block "$f")" || { echo "frontmatter missing or unterminated"; return; }
  # every non-blank frontmatter line must be a top-level `key: value` line
  bad="$(printf '%s\n' "$blk" | awk 'NF==0{next} !/^[A-Za-z_][A-Za-z0-9_-]*:/{print; exit}')"
  [ -z "$bad" ] || { echo "non key line in frontmatter: $bad"; return; }
  keys="$(printf '%s\n' "$blk" | awk -F: 'NF>0 && /^[A-Za-z_]/{print $1}' | LC_ALL=C sort | tr '\n' ' ')"
  nkeys="$(printf '%s\n' "$blk" | awk 'NF>0' | wc -l | tr -d ' ')"
  [ "$keys" = "description model name tools " ] && [ "$nkeys" = "4" ] || { echo "frontmatter keys: $keys"; return; }
  tools="$(printf '%s\n' "$blk" | awk '/^tools:/{ sub(/^tools:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }')"
  [ "$tools" = "Read, Grep, Glob" ] || { echo "tools: $tools"; return; }
  model="$(printf '%s\n' "$blk" | awk '/^model:/{ sub(/^model:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }')"
  case "$model" in opus|sonnet|inherit) ;; *) echo "model: $model"; return ;; esac
  echo ""
}

cmd_pre() {
  local cwd="$PWD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd) [ $# -ge 2 ] || die_usage; cwd="$2"; shift 2 ;;
      *) die_usage ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || { echo "STATE=ENGINE_UNAVAILABLE"; echo "REASON=jq missing"; exit 1; }
  cwd="$(cd "$cwd" 2>/dev/null && pwd -P)" || pre_fail SCOPE_UNRESOLVED "cwd not accessible"

  # 1. AUDITOR_SHADOWED — user-level dir + every project .claude/agents from cwd up to /
  scan_agents_dir "$USER_AGENTS" user
  local d="$cwd"
  while :; do
    if [ -d "$d/.claude/agents" ] && ! [ "$d/.claude/agents" -ef "$USER_AGENTS" ]; then
      scan_agents_dir "$d/.claude/agents" project
    fi
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
  done
  if [ "$MATCH_COUNT" -gt 1 ]; then
    pre_fail AUDITOR_SHADOWED "$MATCH_COUNT definitions named $AGENT_NAME: $(printf '%s' "$MATCHES" | tr '\n' ' ')"
  fi
  if [ "$MATCH_COUNT" -eq 1 ] && [ -z "$USER_MATCH" ]; then
    pre_fail AUDITOR_SHADOWED "only definition is outside $USER_AGENTS: $(printf '%s' "$MATCHES" | tr -d '\n')"
  fi

  # 2. AUDITOR_MISCONFIGURED
  [ "$MATCH_COUNT" -eq 1 ] || pre_fail AUDITOR_MISCONFIGURED "user-level definition missing under $USER_AGENTS"
  local why; why="$(validate_definition "$USER_MATCH")"
  [ -z "$why" ] || pre_fail AUDITOR_MISCONFIGURED "$why ($USER_MATCH)"

  # 3. ENGINE_UNAVAILABLE
  [ -f "$PROCEDURE" ] && [ -r "$PROCEDURE" ] || pre_fail ENGINE_UNAVAILABLE "procedure file missing: $PROCEDURE"

  # 4. SCOPE_UNRESOLVED
  [ -n "${CLAUDE_MEMORY_DIR:-}" ] || pre_fail SCOPE_UNRESOLVED "CLAUDE_MEMORY_DIR unset"
  local mem="$CLAUDE_MEMORY_DIR/MEMORY.md"
  [ -f "$mem" ] || pre_fail SCOPE_UNRESOLVED "MEMORY.md missing: $mem"
  local gclaude="$MH_HOME/.claude/CLAUDE.md"
  local sk="$MH_HOME/.claude/skills/memory-health/SKILL.md" ske="$MH_HOME/.claude/skills/memory-health/SKILL.en.md"
  local req
  for req in "$gclaude" "$sk" "$ske"; do
    [ -f "$req" ] || pre_fail SCOPE_UNRESOLVED "scope file missing: $req"
  done

  # manifest (absolute paths only, fixed order)
  local list="" f
  list="$gclaude
"
  for f in "$MH_HOME/.claude/rules/"*.md; do
    [ -f "$f" ] && list="$list$f
"
  done
  list="$list$mem
$sk
$ske
"
  if [ -f "$cwd/CLAUDE.md" ]; then
    local dup=0 m
    local IFS="$NL"
    set -f
    for m in $list; do
      [ "$m" -ef "$cwd/CLAUDE.md" ] && dup=1
    done
    set +f
    unset IFS
    [ "$dup" = "0" ] && list="$list$cwd/CLAUDE.md$NL"
  fi

  # READY: write the run dir
  mkdir -p "$RUNS_DIR" || pre_fail SCOPE_UNRESOLVED "cannot create $RUNS_DIR"
  local base run n=0
  base="$RUNS_DIR/$(file_ts)"; run="$base"
  while ! mkdir -m 700 "$run" 2>/dev/null; do
    n=$((n + 1)); run="$base-$n"
    [ "$n" -gt 99 ] && pre_fail SCOPE_UNRESOLVED "cannot create run dir under $RUNS_DIR"
  done
  printf '%s' "$list" > "$run/manifest.txt"
  : > "$run/private.tsv"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\t%s\t%s\n' "$f" "$(sha256_of "$f")" "$(line_count "$f")" >> "$run/private.tsv"
  done < "$run/manifest.txt"
  chmod 600 "$run/manifest.txt" "$run/private.tsv"
  printf '%s  %s\n' "$(sha256_of "$USER_MATCH")" "$USER_MATCH" > "$run/definition.sha256"
  chmod 600 "$run/definition.sha256"
  echo "STATE=READY"
  echo "RUN_DIR=$run"
  echo "MANIFEST=$run/manifest.txt"
  exit 0
}

# ── post ────────────────────────────────────────────────────────────────────
cmd_post() {
  [ $# -ge 2 ] || die_usage
  local run="$1" report="$2" dry=0
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in --dry-run) dry=1; shift ;; *) die_usage ;; esac
  done
  command -v jq >/dev/null 2>&1 || { echo "ERROR=jq missing" >&2; exit 2; }
  local f
  for f in manifest.txt private.tsv definition.sha256; do
    [ -f "$run/$f" ] || { echo "ERROR=run dir incomplete: $run/$f missing" >&2; exit 2; }
  done
  [ -f "$report" ] || : # a missing report is judged below as AUDIT_INCOMPLETE

  # save a copy of the report (not in dry-run)
  local saved=""
  if [ "$dry" = "0" ] && [ -f "$report" ]; then
    mkdir -p "$REPORTS_DIR" && chmod 700 "$REPORTS_DIR"
    local rbase n=0
    rbase="$REPORTS_DIR/$(file_ts)"; saved="$rbase.md"
    while [ -e "$saved" ]; do n=$((n + 1)); saved="$rbase-$n.md"; done
    cp "$report" "$saved" && chmod 600 "$saved"
    # keep newest $REPORTS_KEEP
    local old
    ls -1t "$REPORTS_DIR" 2>/dev/null | grep '\.md$' | tail -n +$((REPORTS_KEEP + 1)) | while IFS= read -r old; do
      rm -f "$REPORTS_DIR/$old"
    done
  fi

  local state="" reason="" missing=""
  local scope_count; scope_count="$(awk 'NF>0' "$run/manifest.txt" | wc -l | tr -d ' ')"

  # 1. AUDITOR_CHANGED
  local def_sha def_path cur
  def_sha="$(awk 'NR==1{print $1}' "$run/definition.sha256")"
  def_path="$(sed -n '1s/^[0-9a-f]*  //p' "$run/definition.sha256")"
  if [ ! -f "$def_path" ]; then
    state="AUDITOR_CHANGED"; reason="definition missing: $def_path"
  else
    cur="$(sha256_of "$def_path")"
    [ "$cur" = "$def_sha" ] || { state="AUDITOR_CHANGED"; reason="definition sha256 changed: $def_path"; }
  fi

  # 2. SCOPE_CHANGED_DURING_AUDIT
  local p s nl
  if [ -z "$state" ]; then
    while IFS="$(printf '\t')" read -r p s nl; do
      [ -n "$p" ] || continue
      if [ ! -f "$p" ] || [ "$(sha256_of "$p")" != "$s" ]; then
        state="SCOPE_CHANGED_DURING_AUDIT"; reason="$reason$p "
      fi
    done < "$run/private.tsv"
  fi

  # 3. AUDIT_INCOMPLETE — COVERED lines + FINDINGS
  local fh="" fm="" fl="" covered
  covered="$(mktemp "${TMPDIR:-/tmp}/mh-covered.XXXXXX")" || { echo "ERROR=mktemp failed" >&2; exit 2; }
  if [ -f "$report" ]; then
    local line re_cov='^COVERED: (.+) last_line=([0-9]{1,12})$'
    local re_fnd='^FINDINGS high=([0-9]{1,9}) medium=([0-9]{1,9}) low=([0-9]{1,9})$'
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      line="${line#\`}"; line="${line%\`}"
      if [[ $line =~ $re_cov ]]; then
        printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >> "$covered"
      elif [[ $line =~ $re_fnd ]]; then
        fh="${BASH_REMATCH[1]}"; fm="${BASH_REMATCH[2]}"; fl="${BASH_REMATCH[3]}"
      fi
    done < "$report"
  fi
  if [ -z "$state" ]; then
    local got bad_n
    while IFS="$(printf '\t')" read -r p s nl; do
      [ -n "$p" ] || continue
      got="$(P="$p" awk -F'\t' '$1==ENVIRON["P"]{print $2}' "$covered")"
      if [ -z "$got" ]; then missing="$missing$p
"; continue; fi
      bad_n="$(printf '%s\n' "$got" | awk -v want="$nl" '($1+0)!=(want+0){print; exit}')"
      [ -z "$bad_n" ] || missing="$missing$p
"
    done < "$run/private.tsv"
    if [ -n "$missing" ]; then
      state="AUDIT_INCOMPLETE"; reason="COVERED missing or last_line mismatch"
    elif [ -z "$fh" ]; then
      state="AUDIT_INCOMPLETE"; reason="no parseable FINDINGS line"
    else
      state="REPORTED"
    fi
  fi
  rm -f "$covered"

  local evidence=""
  [ "$state" = "REPORTED" ] && evidence="last_line_match"
  if [ "$state" = "REPORTED" ] && [ "$dry" = "0" ]; then
    mkdir -p "$STATE" && atomic_write "$AUDIT_MARKER" "$(now_epoch)"
  fi

  local rec
  rec="$(jq -nc --arg ts "$(iso_ts)" --arg st "$state" --arg ev "$evidence" \
    --arg fh "$fh" --arg fm "$fm" --arg fl "$fl" --arg sc "$scope_count" --arg run "$run" \
    --arg rep "$saved" --arg reason "$reason" --arg missing "$missing" --argjson dry "$([ "$dry" = 1 ] && echo true || echo false)" \
    '{ts:$ts, part:"audit", state:$st,
      read_evidence:(if $ev=="" then null else $ev end),
      findings_high:(if $fh=="" then null else ($fh|tonumber) end),
      findings_medium:(if $fm=="" then null else ($fm|tonumber) end),
      findings_low:(if $fl=="" then null else ($fl|tonumber) end),
      scope_count:($sc|tonumber), run_dir:$run,
      report:(if $rep=="" then null else $rep end),
      reason:(if $reason=="" then null else $reason end),
      missing:($missing|split("\n")|map(select(length>0))),
      dry_run:$dry}')"
  echo "STATE=$state"
  [ -n "$reason" ] && echo "REASON=$reason"
  [ -n "$saved" ] && echo "REPORT=$saved"
  append_jsonl "$rec" "$dry"
  [ "$state" = "REPORTED" ]
  exit $?
}

# ── update-check ────────────────────────────────────────────────────────────
cmd_update() {
  local dry=0
  while [ $# -gt 0 ]; do
    case "$1" in --dry-run) dry=1; shift ;; *) die_usage ;; esac
  done
  command -v jq >/dev/null 2>&1 || { echo "ERROR=jq missing" >&2; exit 2; }
  local tmo="${MH_UPDATE_TIMEOUT:-300}" re_t='^[1-9][0-9]{0,4}$'
  [[ $tmo =~ $re_t ]] || tmo=300
  local inner="${MH_UPDATE_CMD:-}"
  if [ -z "$inner" ]; then
    inner="python3 '$MH_HOME/.claude/skills/skill-advisor/scripts/update.py' --json"
  fi
  local out err rc=0 reason="" state="UPDATE_CHECK_FAILED"
  out="$(mktemp "${TMPDIR:-/tmp}/mh-update-out.XXXXXX")" || { echo "ERROR=mktemp failed" >&2; exit 2; }
  err="$(mktemp "${TMPDIR:-/tmp}/mh-update-err.XXXXXX")" || { rm -f "$out"; echo "ERROR=mktemp failed" >&2; exit 2; }

  case " $inner " in
    *" --apply"*) rc=-1; reason="refused: --apply is never run by memory-health" ;;
  esac
  if [ -z "$reason" ]; then
    if ! command -v timeout >/dev/null 2>&1; then
      rc=-1; reason="timeout command missing (the check never runs unbounded)"
    else
      timeout -k 10 "$tmo" bash -c "$inner" >"$out" 2>"$err" </dev/null
      rc=$?
    fi
  fi

  local total="" utd="" ua="" fe="" failed="[]"
  if [ -z "$reason" ]; then
    case "$rc" in
      0|1)
        if jq -e '(.summary.total|type)=="number" and (.summary.fetch_error|type)=="number"' "$out" >/dev/null 2>&1; then
          total="$(jq -r '.summary.total' "$out")"
          fe="$(jq -r '.summary.fetch_error' "$out")"
          utd="$(jq -r '.summary.up_to_date // 0' "$out")"
          ua="$(jq -r '.summary.update_available // 0' "$out")"
          failed="$(jq -c '[.results[]? | select(.status=="fetch-error") | (.skill // .name // "?")]' "$out" 2>/dev/null || echo '[]')"
          if [ "$fe" -lt "$total" ] 2>/dev/null; then
            state="UPDATE_CHECK_PASS"
          else
            reason="fetch_error ($fe) >= total ($total): every source unreachable or nothing checked"
          fi
        else
          reason="output is not parseable update.py JSON"
        fi
        ;;
      124|137) reason="timed out after ${tmo}s (exit $rc)" ;;
      2) reason="update.py run failure (exit 2)" ;;
      *) reason="unexpected exit $rc" ;;
    esac
  fi

  if [ "$state" = "UPDATE_CHECK_PASS" ]; then
    if [ "$dry" = "0" ]; then
      mkdir -p "$STATE"
      atomic_write "$UPDATE_MARKER" "$(now_epoch)"
      atomic_write "$UPDATE_FAILED" "$(jq -nc --arg ts "$(iso_ts)" --argjson f "$failed" '{ts:$ts, failed:$f}')"
    fi
    # the list memory-health reports: updates available and per-skill fetch errors
    jq -r '.results[]? | select((.status // "") | test("update-available|fetch-error|local-missing|config-error|no-url"))
           | "SKILL: \(.skill // .name // "?") channel=\(.upstream_type // "?") status=\(.status // "?")"' "$out" 2>/dev/null
  fi
  rm -f "$out" "$err"

  local rec
  rec="$(jq -nc --arg ts "$(iso_ts)" --arg st "$state" --arg rc "$rc" --arg t "$total" --arg u "$utd" \
    --arg a "$ua" --arg e "$fe" --argjson f "$failed" --arg reason "$reason" \
    --argjson dry "$([ "$dry" = 1 ] && echo true || echo false)" \
    'def n: if .=="" then null else tonumber end;
     {ts:$ts, part:"update", state:$st, exit:($rc|tonumber), total:($t|n), up_to_date:($u|n),
      update_available:($a|n), fetch_error:($e|n), failed:$f,
      reason:(if $reason=="" then null else $reason end), dry_run:$dry}')"
  echo "STATE=$state"
  [ -n "$reason" ] && echo "REASON=$reason"
  append_jsonl "$rec" "$dry"
  [ "$state" = "UPDATE_CHECK_PASS" ]
  exit $?
}

case "${1:-}" in
  pre) shift; cmd_pre "$@" ;;
  post) shift; cmd_post "$@" ;;
  update-check) shift; cmd_update "$@" ;;
  *) die_usage ;;
esac

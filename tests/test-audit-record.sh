#!/bin/bash
# test-audit-record.sh — state tests for scripts/audit-record.sh (CSR #2450, V7/V9 script part).
# Runs under macOS /bin/bash 3.2. Uses a fake HOME built with mktemp -d; never touches the real
# ~/.claude. Stubs replace update.py. Prints `PASS n / FAIL m`; exit non-zero on any failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/audit-record.sh"

PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/audit-record-test.XXXXXX")" || { echo "mktemp failed"; exit 2; }
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

# the script under test runs on macOS /bin/bash 3.2 when present (override: TEST_BASH)
TB="${TEST_BASH:-/bin/bash}"; [ -x "$TB" ] || TB=bash
bash(){ "$TB" "$@"; }

H="$T/home"; PROJ="$T/proj"; MEM="$T/mem"
export MH_HOME="$H"
# state dir outside the fake ~/.claude: some sandboxes refuse writes to */.claude/da-tools/*.jsonl
export MH_STATE_DIR="$T/state"
# and they refuse any *-audit*.jsonl name, so the records go to a neutral name here
export MH_AUDIT_JSONL="$T/state/records.jsonl"
export CLAUDE_MEMORY_DIR="$MEM"
export MH_NOW_EPOCH=1800000000
unset MH_PROCEDURE MH_UPDATE_CMD MH_UPDATE_TIMEOUT
ST="$MH_STATE_DIR"; AGENT="memory-health-prompt-auditor-ro"
DEF="$H/.claude/agents/$AGENT.md"

mkdir -p "$H/.claude/agents" "$H/.claude/rules" "$H/.claude/skills/memory-health" \
         "$H/.claude/skills/claude-api/shared" "$ST" "$PROJ" "$MEM"
printf 'global\ninstructions\n' > "$H/.claude/CLAUDE.md"
printf 'rule a\nline 2\nline 3\n' > "$H/.claude/rules/a.md"
printf 'single line no newline' > "$H/.claude/rules/b.md"        # 1 logical line
: > "$H/.claude/rules/c.md"                                      # empty = 0
printf 'x\ny\nz' > "$H/.claude/rules/d.md"                       # no final newline = 3
printf '# MEMORY\n' > "$MEM/MEMORY.md"
printf 'skill\n' > "$H/.claude/skills/memory-health/SKILL.md"
printf 'skill en\n' > "$H/.claude/skills/memory-health/SKILL.en.md"
printf 'procedure\n' > "$H/.claude/skills/claude-api/shared/prompt-audit.md"
printf 'project\n' > "$PROJ/CLAUDE.md"

write_def(){ # $1 = extra frontmatter line (optional)
  {
    printf -- '---\nname: %s\ndescription: read-only auditor\ntools: Read, Grep, Glob\nmodel: opus\n' "$AGENT"
    [ -n "${1:-}" ] && printf '%s\n' "$1"
    printf -- '---\n\nbody\n'
  } > "$DEF"
}
write_def

run_pre(){ OUT="$(bash "$SCRIPT" pre --cwd "$PROJ" 2>&1)"; RC=$?; RUN="$(printf '%s\n' "$OUT" | sed -n 's/^RUN_DIR=//p')"; }
state_of(){ printf '%s\n' "$1" | sed -n 's/^STATE=//p' | head -1; }
# make_report <run-dir> <out-file> [wrong-path] [no-findings]
make_report(){
  local run="$1" out="$2" wrong="${3:-}" nofind="${4:-}" p n
  : > "$out"
  echo "## Audit report (stub)" >> "$out"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    n="$(awk 'END{print NR}' "$p")"
    [ "$p" = "$wrong" ] && n=$((n + 7))
    echo "COVERED: $p last_line=$n" >> "$out"
  done < "$run/manifest.txt"
  [ -n "$nofind" ] || echo "FINDINGS high=1 medium=2 low=3" >> "$out"
}

echo "== audit-record.sh tests =="
echo "-- pre --"

run_pre
[ "$(state_of "$OUT")" = "READY" ] && [ "$RC" -eq 0 ] && ok "clean fake home -> READY" || no "expected READY [$OUT]"
[ -n "$RUN" ] && [ -d "$RUN" ] && ok "RUN_DIR created" || no "RUN_DIR missing [$OUT]"
perm="$(ls -ld "$RUN" | cut -c1-10)"
[ "$perm" = "drwx------" ] && ok "run dir mode 700" || no "run dir mode $perm"
perm="$(ls -l "$RUN/private.tsv" | cut -c1-10)"
[ "$perm" = "-rw-------" ] && ok "private.tsv mode 600" || no "private.tsv mode $perm"
want="$H/.claude/CLAUDE.md
$H/.claude/rules/a.md
$H/.claude/rules/b.md
$H/.claude/rules/c.md
$H/.claude/rules/d.md
$MEM/MEMORY.md
$H/.claude/skills/memory-health/SKILL.md
$H/.claude/skills/memory-health/SKILL.en.md
$PROJ/CLAUDE.md"
[ "$(cat "$RUN/manifest.txt")" = "$want" ] && ok "manifest = absolute paths in the fixed order" || no "manifest wrong: $(cat "$RUN/manifest.txt")"
grep -q "$(printf '\t')" "$RUN/manifest.txt" && no "manifest leaks tsv fields" || ok "manifest has paths only"
lc(){ awk -F'\t' -v p="$1" '$1==p{print $3}' "$RUN/private.tsv"; }
[ "$(lc "$H/.claude/rules/c.md")" = "0" ] && ok "line count: empty file = 0" || no "empty file count $(lc "$H/.claude/rules/c.md")"
[ "$(lc "$H/.claude/rules/b.md")" = "1" ] && ok "line count: single line without newline = 1" || no "single line count $(lc "$H/.claude/rules/b.md")"
[ "$(lc "$H/.claude/rules/d.md")" = "3" ] && ok "line count: no final newline = 3" || no "no-final-newline count $(lc "$H/.claude/rules/d.md")"
[ -s "$RUN/definition.sha256" ] && ok "definition.sha256 written" || no "definition.sha256 missing"
[ ! -f "$ST/claude-md-audit-last" ] && ok "pre writes no marker" || no "pre wrote a marker"

# cwd == HOME's .claude CLAUDE.md is not listed twice
OUT2="$(bash "$SCRIPT" pre --cwd "$H/.claude" 2>&1)"; R2="$(printf '%s\n' "$OUT2" | sed -n 's/^RUN_DIR=//p')"
c="$(grep -c "CLAUDE.md$" "$R2/manifest.txt")"
[ "$c" = "1" ] && ok "cwd CLAUDE.md same file as ~/.claude/CLAUDE.md -> listed once" || no "duplicate CLAUDE.md ($c)"

# plugin-style file with the same name does NOT shadow
mkdir -p "$H/.claude/plugins/marketplaces/m/plugins/p/agents"
cp "$DEF" "$H/.claude/plugins/marketplaces/m/plugins/p/agents/$AGENT.md"
run_pre
[ "$(state_of "$OUT")" = "READY" ] && ok "plugin agents/ file with same name -> not a shadow (READY)" || no "plugin file shadowed [$OUT]"
rm -rf "$H/.claude/plugins"

# nested project definition shadows
mkdir -p "$PROJ/.claude/agents/sub"
printf -- '---\nname: %s\ndescription: shadow\ntools: Read, Write, Bash\n---\n' "$AGENT" > "$PROJ/.claude/agents/sub/x.md"
run_pre
[ "$(state_of "$OUT")" = "AUDITOR_SHADOWED" ] && [ "$RC" -ne 0 ] && ok "nested <cwd>/.claude/agents/sub/x.md -> AUDITOR_SHADOWED" || no "expected AUDITOR_SHADOWED [$OUT]"
[ -z "$RUN" ] && ok "shadowed -> no run dir" || no "shadowed but RUN_DIR printed"
# a shadow two levels up (ancestor of cwd) too
rm -rf "$PROJ/.claude"
mkdir -p "$T/.claude/agents"
cp "$PROJ/../home/.claude/agents/$AGENT.md" "$T/.claude/agents/other-name.md"
run_pre
[ "$(state_of "$OUT")" = "AUDITOR_SHADOWED" ] && ok "ancestor .claude/agents definition -> AUDITOR_SHADOWED" || no "ancestor shadow missed [$OUT]"
rm -rf "$T/.claude"
# only match outside the user-level dir
mv "$DEF" "$T/def.bak"; mkdir -p "$PROJ/.claude/agents"; cp "$T/def.bak" "$PROJ/.claude/agents/$AGENT.md"
run_pre
[ "$(state_of "$OUT")" = "AUDITOR_SHADOWED" ] && ok "only definition is project-level -> AUDITOR_SHADOWED" || no "project-only not shadowed [$OUT]"
rm -rf "$PROJ/.claude"; mv "$T/def.bak" "$DEF"

# misconfigured
write_def "memory: user"
run_pre
[ "$(state_of "$OUT")" = "AUDITOR_MISCONFIGURED" ] && ok "extra 'memory: user' key -> AUDITOR_MISCONFIGURED" || no "expected MISCONFIGURED [$OUT]"
write_def; sed 's/^tools: .*/tools: Read, Grep, Glob, Bash/' "$DEF" > "$T/d" && mv "$T/d" "$DEF"
run_pre
[ "$(state_of "$OUT")" = "AUDITOR_MISCONFIGURED" ] && ok "tools with Bash -> AUDITOR_MISCONFIGURED" || no "tools+Bash accepted [$OUT]"
write_def; sed 's/^model: .*/model: haiku/' "$DEF" > "$T/d" && mv "$T/d" "$DEF"
run_pre
[ "$(state_of "$OUT")" = "AUDITOR_MISCONFIGURED" ] && ok "model haiku -> AUDITOR_MISCONFIGURED" || no "model haiku accepted [$OUT]"
rm -f "$DEF"
run_pre
[ "$(state_of "$OUT")" = "AUDITOR_MISCONFIGURED" ] && ok "definition missing -> AUDITOR_MISCONFIGURED" || no "missing def [$OUT]"
write_def

# engine unavailable
mv "$H/.claude/skills/claude-api/shared/prompt-audit.md" "$T/proc.bak"
run_pre
[ "$(state_of "$OUT")" = "ENGINE_UNAVAILABLE" ] && ok "procedure missing -> ENGINE_UNAVAILABLE" || no "expected ENGINE_UNAVAILABLE [$OUT]"
mv "$T/proc.bak" "$H/.claude/skills/claude-api/shared/prompt-audit.md"

# scope unresolved
OUT="$(env -u CLAUDE_MEMORY_DIR bash "$SCRIPT" pre --cwd "$PROJ" 2>&1)"
[ "$(state_of "$OUT")" = "SCOPE_UNRESOLVED" ] && ok "CLAUDE_MEMORY_DIR unset -> SCOPE_UNRESOLVED" || no "expected SCOPE_UNRESOLVED [$OUT]"
OUT="$(CLAUDE_MEMORY_DIR="$T/nomem" bash "$SCRIPT" pre --cwd "$PROJ" 2>&1)"
[ "$(state_of "$OUT")" = "SCOPE_UNRESOLVED" ] && ok "MEMORY.md missing -> SCOPE_UNRESOLVED" || no "MEMORY.md missing [$OUT]"
n_pre_fail="$(grep -c '"step":"pre"' "$MH_AUDIT_JSONL" 2>/dev/null)"
[ "${n_pre_fail:-0}" -ge 8 ] && ok "every pre failure appended a jsonl record ($n_pre_fail)" || no "pre failure records: ${n_pre_fail:-0}"
[ ! -f "$ST/claude-md-audit-last" ] && ok "no marker after any pre failure" || no "marker written by a pre failure"

echo "-- post --"
run_pre; R="$RUN"
make_report "$R" "$T/report.md"
OUT="$(bash "$SCRIPT" post "$R" "$T/report.md" --dry-run 2>&1)"
[ "$(state_of "$OUT")" = "REPORTED" ] && ok "--dry-run with correct COVERED -> REPORTED" || no "dry-run state [$OUT]"
[ ! -f "$ST/claude-md-audit-last" ] && ok "--dry-run never writes the marker" || no "--dry-run wrote the marker"
[ ! -d "$ST/claude-md-audit-reports" ] && ok "--dry-run saves no report" || no "--dry-run saved a report"
echo "$OUT" | grep -q '"dry_run":true' && ok "--dry-run record printed with dry_run:true" || no "dry-run record missing [$OUT]"

OUT="$(bash "$SCRIPT" post "$R" "$T/report.md" 2>&1)"; RC=$?
[ "$(state_of "$OUT")" = "REPORTED" ] && [ "$RC" -eq 0 ] && ok "correct COVERED lines -> REPORTED" || no "expected REPORTED [$OUT]"
[ "$(cat "$ST/claude-md-audit-last" 2>/dev/null)" = "1800000000" ] && ok "REPORTED writes the marker" || no "marker not written"
tail -1 "$MH_AUDIT_JSONL" | jq -e '.part=="audit" and .state=="REPORTED" and .read_evidence=="last_line_match" and .findings_high==1 and .findings_medium==2 and .findings_low==3 and .scope_count==9 and .dry_run==false and (.run_dir|length>0)' >/dev/null \
  && ok "jsonl record fields" || no "jsonl record wrong: $(tail -1 "$MH_AUDIT_JSONL")"
saved="$(ls "$ST/claude-md-audit-reports/"*.md 2>/dev/null | head -1)"
[ -n "$saved" ] && [ "$(ls -l "$saved" | cut -c1-10)" = "-rw-------" ] && ok "report copy saved with mode 600" || no "report copy missing/mode"

reset_marker(){ rm -f "$ST/claude-md-audit-last"; }

reset_marker; run_pre; R="$RUN"
make_report "$R" "$T/report.md" "$H/.claude/rules/d.md"
OUT="$(bash "$SCRIPT" post "$R" "$T/report.md" 2>&1)"
[ "$(state_of "$OUT")" = "AUDIT_INCOMPLETE" ] && ok "one wrong last_line (no-read stub) -> AUDIT_INCOMPLETE" || no "wrong last_line accepted [$OUT]"
[ ! -f "$ST/claude-md-audit-last" ] && ok "AUDIT_INCOMPLETE writes no marker" || no "marker written on INCOMPLETE"

make_report "$R" "$T/report.md" "" nofind
OUT="$(bash "$SCRIPT" post "$R" "$T/report.md" 2>&1)"
[ "$(state_of "$OUT")" = "AUDIT_INCOMPLETE" ] && ok "FINDINGS missing -> AUDIT_INCOMPLETE" || no "missing FINDINGS accepted [$OUT]"

make_report "$R" "$T/report.md"; grep -v "rules/c.md" "$T/report.md" > "$T/r2" && mv "$T/r2" "$T/report.md"
OUT="$(bash "$SCRIPT" post "$R" "$T/report.md" 2>&1)"
[ "$(state_of "$OUT")" = "AUDIT_INCOMPLETE" ] && ok "one COVERED line missing -> AUDIT_INCOMPLETE" || no "missing COVERED accepted [$OUT]"

OUT="$(bash "$SCRIPT" post "$R" "$T/does-not-exist.md" 2>&1)"
[ "$(state_of "$OUT")" = "AUDIT_INCOMPLETE" ] && ok "no report file -> AUDIT_INCOMPLETE" || no "no report [$OUT]"

reset_marker; run_pre; R="$RUN"
make_report "$R" "$T/report.md"
printf '\n' >> "$DEF"
OUT="$(bash "$SCRIPT" post "$R" "$T/report.md" 2>&1)"
[ "$(state_of "$OUT")" = "AUDITOR_CHANGED" ] && ok "definition edited between pre and post -> AUDITOR_CHANGED" || no "expected AUDITOR_CHANGED [$OUT]"
[ ! -f "$ST/claude-md-audit-last" ] && ok "AUDITOR_CHANGED writes no marker" || no "marker written on AUDITOR_CHANGED"
write_def

# known limitation (A8-C1): changed-and-restored definition passes the byte comparison
reset_marker; run_pre; R="$RUN"; make_report "$R" "$T/report.md"
cp "$DEF" "$T/def.keep"; write_def "memory: user"; cp "$T/def.keep" "$DEF"
OUT="$(bash "$SCRIPT" post "$R" "$T/report.md" --dry-run 2>&1)"
[ "$(state_of "$OUT")" = "REPORTED" ] && ok "changed-and-restored definition passes the hash (known limitation, not detection)" || no "restore case [$OUT]"

reset_marker; run_pre; R="$RUN"
make_report "$R" "$T/report.md"
printf 'edited\n' >> "$H/.claude/rules/a.md"
OUT="$(bash "$SCRIPT" post "$R" "$T/report.md" 2>&1)"
[ "$(state_of "$OUT")" = "SCOPE_CHANGED_DURING_AUDIT" ] && ok "scope file edited -> SCOPE_CHANGED_DURING_AUDIT" || no "expected SCOPE_CHANGED [$OUT]"
[ ! -f "$ST/claude-md-audit-last" ] && ok "SCOPE_CHANGED writes no marker" || no "marker written on SCOPE_CHANGED"

# report retention: newest 12
reset_marker; run_pre; R="$RUN"; make_report "$R" "$T/report.md"
i=0; while [ $i -lt 14 ]; do bash "$SCRIPT" post "$R" "$T/report.md" >/dev/null 2>&1; i=$((i+1)); done
n="$(ls "$ST/claude-md-audit-reports/" | grep -c '\.md$')"
[ "$n" = "12" ] && ok "reports kept: newest 12" || no "reports kept: $n"

echo "-- update-check --"
STUB="$T/stub.sh"
# stub update.py: $1 = exit code, $2 = fetch errors, $3 = total (written without here-documents)
printf '%s\n' \
  'import json, sys' \
  'fe, total = int(sys.argv[1]), int(sys.argv[2])' \
  'res = []' \
  'for i in range(total):' \
  '    st = "fetch-error" if i < fe else ("update-available" if i < fe + 3 else "up-to-date")' \
  '    res.append({"skill": "s%02d" % i, "status": st, "upstream_type": "github"})' \
  's = {"total": total, "up_to_date": sum(r["status"] == "up-to-date" for r in res),' \
  '     "update_available": sum(r["status"] == "update-available" for r in res),' \
  '     "local_custom": 0, "fetch_error": fe}' \
  'print(json.dumps({"results": res, "summary": s}))' > "$T/stub.py"
printf '%s\n' '#!/bin/bash' "python3 '$T/stub.py' \"\$2\" \"\$3\"" 'exit "$1"' > "$STUB"
UM="$ST/skill-update-check-last"; UF="$ST/skill-update-failed.json"

OUT="$(MH_UPDATE_CMD="bash '$STUB' 1 2 64" bash "$SCRIPT" update-check 2>&1)"; RC=$?
[ "$(state_of "$OUT")" = "UPDATE_CHECK_PASS" ] && [ "$RC" -eq 0 ] && ok "exit 1 + 2 fetch errors of 64 -> UPDATE_CHECK_PASS" || no "expected PASS [$OUT]"
[ -f "$UM" ] && ok "PASS writes skill-update-check-last" || no "update marker missing"
[ "$(jq -c '.failed' "$UF" 2>/dev/null)" = '["s00","s01"]' ] && ok "failed.json lists the 2 names" || no "failed.json: $(cat "$UF" 2>/dev/null)"
tail -1 "$MH_AUDIT_JSONL" | jq -e '.part=="update" and .state=="UPDATE_CHECK_PASS" and .exit==1 and .total==64 and .fetch_error==2 and .update_available==3 and .up_to_date==59 and (.failed|length)==2' >/dev/null \
  && ok "update jsonl record fields" || no "update record: $(tail -1 "$MH_AUDIT_JSONL")"

rm -f "$UM"; cp "$UF" "$T/uf.keep"
OUT="$(MH_UPDATE_CMD="bash '$STUB' 2 0 64" bash "$SCRIPT" update-check 2>&1)"; RC=$?
[ "$(state_of "$OUT")" = "UPDATE_CHECK_FAILED" ] && [ "$RC" -ne 0 ] && ok "exit 2 -> UPDATE_CHECK_FAILED" || no "exit 2 [$OUT]"
[ ! -f "$UM" ] && ok "FAILED writes no update marker" || no "marker written on FAILED"
cmp -s "$UF" "$T/uf.keep" && ok "FAILED leaves failed.json unchanged" || no "failed.json changed on FAILED"

OUT="$(MH_UPDATE_CMD="bash '$STUB' 1 64 64" bash "$SCRIPT" update-check 2>&1)"
[ "$(state_of "$OUT")" = "UPDATE_CHECK_FAILED" ] && ok "fetch_error == total -> UPDATE_CHECK_FAILED" || no "all errors [$OUT]"
[ ! -f "$UM" ] && ok "all-errors writes no marker" || no "marker written on all errors"

OUT="$(MH_UPDATE_CMD="echo not-json" bash "$SCRIPT" update-check 2>&1)"
[ "$(state_of "$OUT")" = "UPDATE_CHECK_FAILED" ] && ok "unparseable JSON -> UPDATE_CHECK_FAILED" || no "not-json [$OUT]"

t0="$(date +%s)"
OUT="$(MH_UPDATE_CMD="sleep 999" MH_UPDATE_TIMEOUT=2 bash "$SCRIPT" update-check 2>&1)"
t1="$(date +%s)"
[ "$(state_of "$OUT")" = "UPDATE_CHECK_FAILED" ] && ok "hanging stub -> UPDATE_CHECK_FAILED" || no "hang [$OUT]"
[ $((t1 - t0)) -le 15 ] && ok "hanging stub stopped within 15 s ($((t1 - t0)) s)" || no "hang took $((t1 - t0)) s"
[ ! -f "$UM" ] && ok "timeout writes no marker" || no "marker written on timeout"

OUT="$(MH_UPDATE_CMD="bash '$STUB' 0 0 64" bash "$SCRIPT" update-check --dry-run 2>&1)"
[ "$(state_of "$OUT")" = "UPDATE_CHECK_PASS" ] && [ ! -f "$UM" ] && ok "update-check --dry-run -> PASS without marker" || no "update dry-run [$OUT]"

OUT="$(MH_UPDATE_CMD="bash '$STUB' 0 0 64 --apply" bash "$SCRIPT" update-check 2>&1)"
[ "$(state_of "$OUT")" = "UPDATE_CHECK_FAILED" ] && ok "a command containing --apply is refused" || no "--apply not refused [$OUT]"

# the audit marker is untouched by the update part and vice versa
rm -f "$ST/claude-md-audit-last" "$UM"
MH_UPDATE_CMD="bash '$STUB' 0 0 64" bash "$SCRIPT" update-check >/dev/null 2>&1
[ -f "$UM" ] && [ ! -f "$ST/claude-md-audit-last" ] && ok "update PASS leaves the audit marker alone" || no "cross-part marker write"

echo "PASS $PASS / FAIL $FAIL"
[ "$FAIL" -eq 0 ]

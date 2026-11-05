#!/bin/bash
# test-skill-split.sh — CSR #2503 C1: SKILL.md / SKILL.en.md moved the Optimizer, Scanner, Rules Checker,
# --with-md and Catalog procedures to reference/*.md. Every entry point that runs moved text must name
# the right reference file (ko -> reference/X.md, en -> reference/X.en.md), the files must exist, and
# each SKILL body (lines after the frontmatter) must stay under 500 lines.
# Prints `PASS n / FAIL m`; exit non-zero on any failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."

PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# need_ptr <file> <ERE selecting entry lines> <pointer file> <label>
# every selected line must name the pointer file; zero selected lines is a failure (a silent 0-match
# would make the check vacuous)
need_ptr(){
  local f="$1" re="$2" ptr="$3" label="$4" n bad
  n="$(grep -cE "$re" "$f")"
  bad="$(grep -E "$re" "$f" | grep -vF "$ptr")"
  if [ "$n" -gt 0 ] && [ -z "$bad" ]; then ok "$label ($n lines) -> $ptr"
  else no "$label: n=$n missing $ptr in [$bad]"; fi
}

check_lang(){ # $1 = SKILL file, $2 = suffix (".md" or ".en.md"), $3 = json-mode heading
  local f="$ROOT/$1" s="$2" jh="$3"
  local opt="reference/optimizer$s" scn="reference/scanner$s" rch="reference/rules-checker$s" wmc="reference/with-md-catalog$s"
  echo "-- $1 --"
  need_ptr "$f" '^/memory-health +→'                       "$opt" "bare /memory-health (= check, flow ①)"
  need_ptr "$f" '^/memory-health check '                   "$opt" "check"
  need_ptr "$f" '^/memory-health (fix|--fix)( |$)'         "$opt" "fix / --fix / fix --json / --fix --json"
  need_ptr "$f" '^/memory-health (scan|--scan)( |$)'       "$scn" "scan / --scan"
  need_ptr "$f" '^/memory-health (rules|--rules)( |$)'     "$rch" "rules / --rules / --strict"
  need_ptr "$f" 'MEMORY_HEALTH_DEFAULT_RULES=true'         "$rch" "MEMORY_HEALTH_DEFAULT_RULES=true line"
  need_ptr "$f" '^/memory-health catalog '                 "$wmc" "catalog"
  need_ptr "$f" '^/memory-health --with-md '               "$wmc" "--with-md"
  need_ptr "$f" '^/memory-health --with-md '               "$opt" "--with-md Phase A"
  # the --fix --json section: the paragraph right under its heading names the optimizer file
  if grep -A3 -F "$jh" "$f" | grep -qF "$opt"; then ok "'$jh' section -> $opt"; else no "'$jh' section lacks $opt"; fi
  # language: ko names only .md (never .en.md); en names only .en.md
  if [ "$s" = ".md" ]; then
    if grep -qE 'reference/[a-z-]+\.en\.md' "$f"; then no "ko file names an .en.md reference"; else ok "ko file names no .en.md reference"; fi
  else
    if grep -qE 'reference/[a-z-]+\.md' "$f"; then no "en file names a ko .md reference: $(grep -oE 'reference/[a-z-]+\.md' "$f" | sort -u | tr '\n' ' ')"; else ok "en file names only .en.md references"; fi
  fi
  # the sync checklist comment covers the reference files
  if sed -n '/<!-- Sync checklist/,/-->/p' "$f" | grep -qF 'reference/'; then ok "sync checklist names reference/"; else no "sync checklist lacks reference/"; fi
  # body size: lines after the closing frontmatter ---
  local body
  body="$(awk 'c>=2{n++} /^---$/ && c<2{c++} END{print n+0}' "$f")"
  [ "$body" -lt 500 ] && ok "$1 body $body < 500" || no "$1 body $body >= 500"
}

check_lang SKILL.md ".md" "### --fix --json 모드"
check_lang SKILL.en.md ".en.md" "### --fix --json mode"

echo "-- reference files --"
for b in optimizer scanner rules-checker with-md-catalog; do
  for s in .md .en.md; do
    p="$ROOT/reference/$b$s"
    if [ -f "$p" ]; then
      ok "exists reference/$b$s"
      n="$(awk 'END{print NR}' "$p")"
      if [ "$n" -gt 100 ]; then
        # TOC: a `## Contents` block listing every other `##` heading in file order
        want="$(grep '^## ' "$p" | grep -v '^## Contents$' | sed 's/^## /- /')"
        got="$(sed -n '/^## Contents$/,/^$/p' "$p" | grep '^- ')"
        [ -n "$want" ] && [ "$want" = "$got" ] && ok "reference/$b$s ($n lines) has a matching ## Contents" || no "reference/$b$s ($n lines) TOC mismatch [$got] vs [$want]"
      fi
    else
      no "missing reference/$b$s"
    fi
  done
done

echo "PASS $PASS / FAIL $FAIL"
[ "$FAIL" -eq 0 ]

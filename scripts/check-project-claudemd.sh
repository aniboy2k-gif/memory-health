#!/usr/bin/env bash
# check-project-claudemd.sh — 프로젝트 CLAUDE.md(+분리 파일) 크기 모니터링 (READ-ONLY)
# memory-health 보조: 사용자 지정 프로젝트 CLAUDE.md(aria/kris 등)와 그 분리 파일의 크기를 점검·경고만 한다.
# 파일을 수정하지 않음. 실제 내용 최적화는 도메인 워크플로우(ARIA/KRIS=/trader-task)로.
#
# 대상 목록 소스(우선순위): --list=<경로> > $CLAUDE_PROJECT_CLAUDEMD_LIST > ~/.claude/da-tools/project-claudemd-paths.txt
#   목록의 각 줄 = 절대경로 또는 glob 패턴(예: .../aria/CLAUDE*.md). glob → 분리 파일 자동 포함.
# 임계(자 수, Rules Checker 정합): OK<20,000 / WARN 20,000~40,000 / CRITICAL>40,000
#   env override: CLAUDE_PROJECT_MD_WARN, CLAUDE_PROJECT_MD_CRITICAL
# graceful: 목록 없음/볼륨 미마운트/매칭 0 = skip + exit 0 (비차단)
set -uo pipefail

LIST=""; STRICT=0
for a in "$@"; do
  case "$a" in
    --list=*) LIST="${a#--list=}" ;;
    --strict) STRICT=1 ;;
  esac
done
[ -n "$LIST" ] || LIST="${CLAUDE_PROJECT_CLAUDEMD_LIST:-$HOME/.claude/da-tools/project-claudemd-paths.txt}"
WARN="${CLAUDE_PROJECT_MD_WARN:-20000}"
CRIT="${CLAUDE_PROJECT_MD_CRITICAL:-40000}"

echo "=== 프로젝트 CLAUDE.md(+분리 파일) 크기 모니터링 (read-only) ==="
echo "대상 목록: $LIST"
echo "임계(자): OK<${WARN} / WARN ${WARN}~${CRIT} / CRITICAL>${CRIT}"
echo ""

if [ ! -r "$LIST" ]; then
  echo "ℹ️  대상 목록 파일 없음 — 점검 대상 미설정 (graceful skip)"; exit 0
fi

# Python으로 config(글로브/리터럴 혼합, 공백 경로 안전) 확장 + dedup + 자 수 측정 → "STATUS\tCOUNT\tPATH"
RESULT="$(WARN="$WARN" CRIT="$CRIT" python3 - "$LIST" <<'PY'
import os, sys, glob
list_path=sys.argv[1]
warn=int(os.environ["WARN"]); crit=int(os.environ["CRIT"])
seen=set(); rows=[]
for raw in open(list_path, encoding="utf-8"):
    line=raw.strip()
    if not line or line.startswith("#"): continue
    matches=glob.glob(line)            # 리터럴 경로도 자기 자신으로 매칭, glob 패턴은 확장(분리 파일 포함)
    if not matches:
        rows.append(("MISSING", 0, line)); continue
    for p in sorted(matches):
        rp=os.path.realpath(p)
        if rp in seen: continue
        seen.add(rp)
        if not os.path.isfile(p):
            rows.append(("MISSING", 0, p)); continue
        try:
            c=len(open(p, encoding="utf-8").read())
        except Exception:
            rows.append(("MISSING", 0, p)); continue
        st="CRITICAL" if c>crit else ("WARN" if c>warn else "OK")
        rows.append((st, c, p))
for st,c,p in rows:
    print(f"{st}\t{c}\t{p}")
PY
)"

crit=0; warn=0; checked=0; missing=0
while IFS=$'\t' read -r st c p; do
  [ -n "$st" ] || continue
  case "$st" in
    CRITICAL) printf "  🔴 CRITICAL  %'10d자  %s\n" "$c" "$p"; crit=$((crit+1)); checked=$((checked+1)) ;;
    WARN)     printf "  🟡 WARN      %'10d자  %s\n" "$c" "$p"; warn=$((warn+1)); checked=$((checked+1)) ;;
    OK)       printf "  ✅ OK        %'10d자  %s\n" "$c" "$p"; checked=$((checked+1)) ;;
    MISSING)  echo  "  ⚠ 접근 불가(미마운트/부재/무매칭): $p"; missing=$((missing+1)) ;;
  esac
done <<< "$RESULT"

echo ""
echo "📊 점검 ${checked}건 / CRITICAL ${crit} / WARN ${warn} / 접근불가 ${missing}"
if [ "$crit" -gt 0 ]; then
  echo "   → CRITICAL: 자동 로드 성능 경고 구간(>${CRIT}자). 내용 최적화 권장 — 단 도메인 워크플로우로(ARIA/KRIS=/trader-task). 이 도구는 점검만 함."
fi

if [ "$STRICT" -eq 1 ] && { [ "$crit" -gt 0 ] || [ "$warn" -gt 0 ]; }; then
  exit 2
fi
exit 0

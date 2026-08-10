#!/usr/bin/env bash
# memory-line-check.sh — MEMORY.md size monitoring (lines + characters)
#
# Role: MEMORY.md 의 줄 수·문자 수를 재고 임계 초과 시 평문으로 경고한다.
#
# ★ CSR #1825 (2026-08-10): 측정 단위를 바이트 → 문자로 정정.
#   플랫폼 캡 = 200줄 OR 25,000문자 (먼저 도달하는 쪽). 행동 실험으로 확정:
#     - 24,900자 → 전문 로드 / 25,100자 → 꼬리 절단   (경계 = 25,000자)
#     - 31,534바이트(10,734자) → 전문 로드            (바이트 캡은 강제되지 않음)
#     - 302줄(16,534자)      → 절단                  (줄 캡은 독립적으로 실재)
#   ⇒ 한글은 바이트만 부풀릴 뿐 캡에서는 오히려 멀어진다.
#     "한글이라 바이트 캡에 먼저 닿는다"(CSR #806) 는 전제가 역전됐다.
#   측정은 UTF-16 code unit 기준이다. 플랫폼의 정확한 단위(code point/scalar/grapheme)는
#   미확정이며, UTF-16 단위는 code point 이상이므로 보수적이다(과경고 O, 놓침 X).
#
# Contract (INTERFACES.md § memory-line-check.sh):
#   - 항상 exit 0 (경고가 세션을 막지 않는다)
#   - 파일을 수정하지 않는다 — 출력만 한다
#   - **평문만 출력한다.** 이벤트별 직렬화(Stop = systemMessage JSON)는
#     hooks/memory-line-check.sh (shim) 소관이다. 여기서 JSON 을 만들지 않는다.
#   - 자기무력화 진단은 SessionStart 에서만 출력한다 (Stop 은 응답 턴마다 발화하므로)
#   - 측정한 파일 경로를 함께 출력한다 (INV-3 — 감시기는 무엇을 재는지 말해야 한다)

set -u

EVENT="${HOOK_EVENT:-SessionStart}"

# 자기무력화 진단은 SessionStart 한정 — Stop 은 턴마다 발화해 소음이 된다.
emit_diag() {
  if [ "$EVENT" = "SessionStart" ]; then
    printf '%s\n' "$1"
  fi
}

# ---- 대상 결박 -------------------------------------------------------------
# ★ find|head -1 폴백 금지. 열거 순서 의존이라 프로젝트가 추가되면 대상이 조용히 바뀐다
#   (CSR #1825 에서 같은 세션 안 3회 관측으로 실증). 추측 대상보다 무동작 + 고발이 옳다.
MEMORY_DIR="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$MEMORY_DIR" ]; then
  emit_diag "MEMORY_DIR_UNSET: CLAUDE_MEMORY_DIR 미설정 — MEMORY.md 감시 불가 (CSR #1825)"
  exit 0
fi

MEMORY_FILE="${MEMORY_DIR}/MEMORY.md"
if [ ! -f "$MEMORY_FILE" ]; then
  emit_diag "MEMORY_FILE_ABSENT: ${MEMORY_FILE} 없음 — 감시 대상 부재"
  exit 0
fi

# ---- 임계 상수 -------------------------------------------------------------
# source 하지 않는다(외부 저장소 파일의 코드 실행 회피). 정수만 허용하고 실패 시 내장값 폴백.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONST_FILE="${MEMORY_HEALTH_CONSTANTS:-${SCRIPT_DIR}/../cap-constants.env}"

read_const() {
  ck_key="$1"
  ck_def="$2"
  ck_val=""
  if [ -r "$CONST_FILE" ]; then
    ck_val="$(grep -E "^${ck_key}=" "$CONST_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r')"
  fi
  case "$ck_val" in
    '' | *[!0-9]*) printf '%s' "$ck_def" ;;
    *)             printf '%s' "$ck_val" ;;
  esac
}

CHAR_CAP="$(read_const MEMORY_CHAR_CAP 25000)"
CHAR_WARN="$(read_const MEMORY_CHAR_WARN 20000)"
CHAR_TARGET="$(read_const MEMORY_CHAR_TARGET 17500)"
LINE_CAP="$(read_const MEMORY_LINE_CAP 200)"
LINE_WARN="$(read_const MEMORY_LINE_WARN 160)"
LINE_TARGET="$(read_const MEMORY_LINE_TARGET 140)"

# env 오버라이드 (테스트·특수 환경용)
CHAR_WARN="${CLAUDE_MEMORY_CHAR_WARN:-$CHAR_WARN}"
LINE_WARN="${CLAUDE_MEMORY_LINE_WARN:-$LINE_WARN}"

# ---- 측정 ------------------------------------------------------------------
LINES="$(wc -l < "$MEMORY_FILE" | tr -d ' ')"
BYTES="$(wc -c < "$MEMORY_FILE" | tr -d ' ')"

CHARS=""
if command -v python3 >/dev/null 2>&1; then
  CHARS="$(MH_TARGET="$MEMORY_FILE" python3 -c 'import os
try:
    with open(os.environ["MH_TARGET"], encoding="utf-8", errors="replace") as f:
        t = f.read()
    print(sum(2 if ord(c) > 0xFFFF else 1 for c in t))
except Exception:
    print("")' 2>/dev/null)"
fi

CHAR_OK=1
case "$CHARS" in
  '' | *[!0-9]*)
    CHAR_OK=0
    CHARS=0
    emit_diag "MEASURE_FAILED: 문자 수 측정 실패(python3 부재 또는 읽기 오류) — 줄 수만 판정합니다"
    ;;
esac

# ---- 판정 (OR — 먼저 도달하는 쪽) -------------------------------------------
HARD=0
WARN=0

if [ "$LINES" -ge "$LINE_CAP" ]; then HARD=1; fi
if [ "$CHAR_OK" -eq 1 ] && [ "$CHARS" -ge "$CHAR_CAP" ]; then HARD=1; fi

if [ "$LINES" -ge "$LINE_WARN" ]; then WARN=1; fi
if [ "$CHAR_OK" -eq 1 ] && [ "$CHARS" -ge "$CHAR_WARN" ]; then WARN=1; fi

if [ "$HARD" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  exit 0
fi

# ---- 출력 ------------------------------------------------------------------
if [ "$CHAR_OK" -eq 1 ]; then
  SIZE_PART="문자 ${CHARS}/${CHAR_CAP} · 줄 ${LINES}/${LINE_CAP} (참고 ${BYTES}B)"
else
  SIZE_PART="줄 ${LINES}/${LINE_CAP} (문자 미측정 · 참고 ${BYTES}B)"
fi

if [ "$HARD" -eq 1 ]; then
  printf '%s\n' "MEMORY_HARDCAP: MEMORY.md ${SIZE_PART} — 캡 초과분은 로드되지 않습니다. /memory-health --fix"
else
  printf '%s\n' "MEMORY_WARN: MEMORY.md ${SIZE_PART} — ${CHAR_TARGET}자 / ${LINE_TARGET}줄 이하로 정리 권장. /memory-health --fix"
fi

# INV-3: 감시기는 자기가 무엇을 쟀는지 말한다.
printf '%s\n' "  측정 대상: ${MEMORY_FILE}"

# 한국어 비율은 진단 정보이며 계산 비용(python3 스폰)이 있으므로 SessionStart 한정.
if [ "$EVENT" = "SessionStart" ] && [ "$CHAR_OK" -eq 1 ] && command -v python3 >/dev/null 2>&1; then
  KR="$(MH_TARGET="$MEMORY_FILE" python3 -c 'import os
try:
    with open(os.environ["MH_TARGET"], encoding="utf-8", errors="replace") as f:
        t = f.read()
    print(int(sum(1 for c in t if "가" <= c <= "힣") * 100 / len(t)) if t else 0)
except Exception:
    print(0)' 2>/dev/null)"
  case "$KR" in
    '' | *[!0-9]*) KR=0 ;;
  esac
  if [ "$KR" -ge 10 ]; then
    printf '%s\n' "  한글 비율 ${KR}% — 한글은 바이트만 늘릴 뿐 문자 캡에서는 오히려 여유를 준다 (CSR #1825: 캡 단위는 바이트가 아니라 문자)"
  fi
fi

exit 0

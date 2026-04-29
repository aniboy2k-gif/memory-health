#!/usr/bin/env bash
# check-rules.sh — Rules Checker: 자동 로드 rules 파일 크기 검사 (read-only)
#
# 주의: 이 스크립트는 지정 디렉토리의 MD 파일 크기를 검사할 뿐,
#        실제 Claude Code 로딩 여부는 보장하지 않음.
#        서브디렉토리는 검사 제외 (직접 자식 파일만).
#
# 사용법: check-rules.sh [--strict]
#
# 환경변수:
#   CLAUDE_RULES_DIR           — rules 디렉토리 절대 경로 (필수; 미설정 시 exit 1)
#   CLAUDE_RULES_SIZE_WARN     — WARN 임계값 문자 수 (기본: 20000)
#   CLAUDE_RULES_SIZE_CRITICAL — CRITICAL 임계값 문자 수 (기본: 40000)
#   CLAUDE_MEMORY_DIR          — audit 로그 기록 위치 (선택)
#
# exit code:
#   0 — 정상 또는 CRITICAL 파일 존재 (read-only이므로)
#   1 — 설정 오류 (CLAUDE_RULES_DIR 미설정 또는 디렉토리 없음)
#   2 — --strict 모드에서 WARN 이상 비정상 상황 발생

set -uo pipefail

STRICT_MODE=false
for arg in "$@"; do
  [ "$arg" = "--strict" ] && STRICT_MODE=true
done

WARN_THRESHOLD="${CLAUDE_RULES_SIZE_WARN:-20000}"
CRITICAL_THRESHOLD="${CLAUDE_RULES_SIZE_CRITICAL:-40000}"
TIMEOUT_BUDGET=5
SYMLINK_MAX_DEPTH=20

WARN_COUNT=0
CRITICAL_COUNT=0

# --- exit 1: CLAUDE_RULES_DIR 미설정 ---
if [ -z "${CLAUDE_RULES_DIR:-}" ]; then
  echo "⚠ [Rules Checker] CLAUDE_RULES_DIR 미설정 — skip" >&2
  echo "  설정 방법: export CLAUDE_RULES_DIR=/path/to/rules" >&2
  echo "  또는 install.sh 실행 후 ~/.claude/da-tools/env.sh를 source하세요." >&2
  exit 1
fi

# --- exit 1: 디렉토리 없음 ---
if [ ! -d "$CLAUDE_RULES_DIR" ]; then
  echo "⚠ [Rules Checker] 디렉토리 없음: $CLAUDE_RULES_DIR — skip" >&2
  exit 1
fi

# --- Python으로 스캔 (문자 수 측정 일관성 + 타임아웃) ---
export _MH_RULES_DIR="$CLAUDE_RULES_DIR"
export _MH_WARN="$WARN_THRESHOLD"
export _MH_CRITICAL="$CRITICAL_THRESHOLD"
export _MH_TIMEOUT="$TIMEOUT_BUDGET"
export _MH_SYMLINK_MAX="$SYMLINK_MAX_DEPTH"

SCAN_RESULT=$(python3 - <<'PYEOF'
import os, time, re, sys

rules_dir   = os.environ["_MH_RULES_DIR"]
warn_th     = int(os.environ.get("_MH_WARN", "20000"))
critical_th = int(os.environ.get("_MH_CRITICAL", "40000"))
timeout     = float(os.environ.get("_MH_TIMEOUT", "5"))
max_depth   = int(os.environ.get("_MH_SYMLINK_MAX", "20"))

start = time.time()
visited = set()   # realpath 해시셋 — 중복 제거 + 순환 감지 (결정적, 순서 무관)
results = []
missing = []

# Source B (주): rules_dir 직접 자식 MD 파일
try:
    entries = sorted(os.listdir(rules_dir))
except PermissionError:
    print(f"ERROR:permission:{rules_dir}", flush=True)
    sys.exit(0)

for entry in entries:
    if time.time() - start > timeout:
        missing.append(entry)
        continue

    if not entry.lower().endswith(".md") or entry.startswith("."):
        continue

    full_path = os.path.join(rules_dir, entry)

    # symlink 처리: follow once + 깊이 제한 + 순환 감지
    if os.path.islink(full_path):
        current = full_path
        depth = 0
        loop_detected = False
        while os.path.islink(current) and depth < max_depth:
            target = os.readlink(current)
            if not os.path.isabs(target):
                target = os.path.join(os.path.dirname(current), target)
            try:
                real_target = os.path.realpath(target)
            except OSError:
                loop_detected = True
                break
            if real_target in visited:
                loop_detected = True
                break
            current = target
            depth += 1

        if loop_detected:
            print(f"WARN:symlink_loop:{entry}", flush=True)
            continue
        if depth >= max_depth:
            print(f"WARN:symlink_depth:{entry}", flush=True)
            continue
        try:
            resolved = os.path.realpath(full_path)
        except OSError:
            print(f"SKIP:parse_fail:{entry}", flush=True)
            continue
        if resolved in visited:
            # 동일 파일 이미 처리됨 — 중복 skip (순서 무관 결정적)
            continue
        visited.add(resolved)
        actual_path = resolved
    else:
        try:
            resolved = os.path.realpath(full_path)
        except OSError:
            print(f"SKIP:parse_fail:{entry}", flush=True)
            continue
        if resolved in visited:
            continue
        visited.add(resolved)
        actual_path = resolved

    if not os.path.isfile(actual_path):
        continue

    try:
        content = open(actual_path, encoding="utf-8").read()
        char_count = len(content)
    except (OSError, UnicodeDecodeError):
        print(f"SKIP:parse_fail:{entry}", flush=True)
        continue

    grade = "CRITICAL" if char_count >= critical_th else ("WARN" if char_count >= warn_th else "OK")
    results.append((grade, char_count, entry))

# Source A (보조): ~/.claude/CLAUDE.md @파일명 패턴
claude_md = os.path.expanduser("~/.claude/CLAUDE.md")
if os.path.exists(claude_md):
    try:
        refs = re.findall(r'^@(\S+)', open(claude_md, encoding="utf-8").read(), re.MULTILINE)
        for ref in refs:
            candidate = os.path.join(os.path.expanduser("~/.claude"), ref)
            if not os.path.isfile(candidate):
                candidate = ref if os.path.isabs(ref) and os.path.isfile(ref) else None
            if not candidate:
                continue
            try:
                real_ref = os.path.realpath(candidate)
            except OSError:
                continue
            if real_ref in visited:
                continue
            visited.add(real_ref)
            try:
                content = open(real_ref, encoding="utf-8").read()
                char_count = len(content)
                grade = "CRITICAL" if char_count >= critical_th else ("WARN" if char_count >= warn_th else "OK")
                results.append((grade, char_count, f"@{ref}"))
            except (OSError, UnicodeDecodeError):
                pass
    except (OSError, UnicodeDecodeError):
        pass

# 출력 (크기 내림차순)
for grade, chars, name in sorted(results, key=lambda x: -x[1]):
    print(f"{grade}:{chars}:{name}", flush=True)

if missing:
    print(f"TIMEOUT:{','.join(missing[:10])}", flush=True)
PYEOF
)

# --- 결과 파싱 및 출력 ---
echo ""
echo "=== Rules Checker ==="
echo "대상: ${CLAUDE_RULES_DIR}"
echo "주의: 지정 디렉토리 MD 파일 크기 검사 — 실제 Claude Code 로딩 여부는 보장하지 않음"
echo "      서브디렉토리 무시 | 심볼릭 링크: follow once (최대 깊이 ${SYMLINK_MAX_DEPTH})"
echo ""

TIMED_OUT=false
TIMEOUT_MISSING=""

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    TIMEOUT:*)
      TIMED_OUT=true
      TIMEOUT_MISSING="${line#TIMEOUT:}"
      ;;
    WARN:symlink_loop:*)
      echo "⚠ [순환 심볼릭 링크] ${line#WARN:symlink_loop:} — skip"
      WARN_COUNT=$((WARN_COUNT + 1))
      ;;
    WARN:symlink_depth:*)
      echo "⚠ [심볼릭 링크 깊이(${SYMLINK_MAX_DEPTH}) 초과] ${line#WARN:symlink_depth:} — skip"
      WARN_COUNT=$((WARN_COUNT + 1))
      ;;
    SKIP:parse_fail:*)
      echo "ℹ️  [파싱 실패 skip] ${line#SKIP:parse_fail:}"
      ;;
    ERROR:permission:*)
      echo "⚠ [권한 오류] ${line#ERROR:permission:} — skip"
      WARN_COUNT=$((WARN_COUNT + 1))
      ;;
    CRITICAL:*)
      IFS=: read -r _ chars fname <<< "$line"
      printf "🔴 CRITICAL  %'10d자  %s\n" "$chars" "$fname"
      CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
      WARN_COUNT=$((WARN_COUNT + 1))
      ;;
    WARN:*)
      IFS=: read -r _ chars fname <<< "$line"
      printf "🟡 WARN      %'10d자  %s\n" "$chars" "$fname"
      WARN_COUNT=$((WARN_COUNT + 1))
      ;;
    OK:*)
      IFS=: read -r _ chars fname <<< "$line"
      printf "✅ OK        %'10d자  %s\n" "$chars" "$fname"
      ;;
  esac
done <<< "$SCAN_RESULT"

echo ""

if $TIMED_OUT; then
  echo "⏱ 타임아웃 (${TIMEOUT_BUDGET}초) — 부분 결과. 미처리 파일: ${TIMEOUT_MISSING}"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# --- 요약 ---
if [ "$CRITICAL_COUNT" -gt 0 ]; then
  echo "📊 CRITICAL ${CRITICAL_COUNT}건 — Claude Code 성능 경고 발생 중 (> ${CRITICAL_THRESHOLD}자)"
  echo "   개선 방향:"
  echo "   1. 파일 L3(핵심 요약 자동 로드) + L4(상세 온디맨드) 구조로 분리"
  echo "   2. CLAUDE.md 자동 로드에서 제외 후 온디맨드 참조로 전환"
elif [ "$WARN_COUNT" -gt 0 ]; then
  echo "📊 WARN ${WARN_COUNT}건 — CRITICAL 임계값(${CRITICAL_THRESHOLD}자)의 50% 초과. 조기 경고."
else
  echo "📊 모든 규칙 파일 정상 (OK)"
fi

# --- audit 로그 (F5: rules-scan, read-only) ---
MEMORY_DIR="${CLAUDE_MEMORY_DIR:-}"
if [ -n "$MEMORY_DIR" ]; then
  LOG_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/memory-health-log.sh"
  if [ -f "$LOG_SCRIPT" ]; then
    bash "$LOG_SCRIPT" "F5" "rules-scan (read-only)" \
      "CRITICAL=${CRITICAL_COUNT}" "WARN=${WARN_COUNT}" 2>/dev/null || true
  fi
fi

# --- exit code (C-3 반영: fail loudly) ---
if $STRICT_MODE && [ "$WARN_COUNT" -gt 0 ]; then
  exit 2
fi

exit 0

#!/usr/bin/env bash
# install.sh — memory-health 스킬 초기 설정
# 역할: CLAUDE_MEMORY_DIR 환경변수 설정 + 필수 파일 생성
# 사용법: bash install.sh

set -euo pipefail

echo "=== memory-health install.sh ==="
echo ""

# 1. CLAUDE_MEMORY_DIR 자동 감지
# Claude Code는 현재 디렉토리 절대경로를 인코딩하여 프로젝트 경로를 생성한다.
# 단순한 사용자명 치환으로는 해결되지 않으므로 실행 환경에서 직접 감지한다.

DETECTED_DIR=""

# 방법 A: 실행 중인 Claude Code 프로세스에서 경로 감지
if command -v lsof >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1; then
  CLAUDE_PID=$(pgrep -f 'claude' 2>/dev/null | head -1 || true)
  if [ -n "$CLAUDE_PID" ]; then
    DETECTED_DIR=$(lsof -p "$CLAUDE_PID" 2>/dev/null \
      | grep -o "${HOME}/.claude/projects/[^/]*/memory" \
      | head -1 || true)
  fi
fi

# 방법 B: ~/.claude/projects/ 내에서 MEMORY.md 탐색
if [ -z "$DETECTED_DIR" ]; then
  DETECTED_DIR=$(find "${HOME}/.claude/projects" -name "MEMORY.md" -maxdepth 3 2>/dev/null \
    | head -1 | xargs dirname 2>/dev/null || true)
fi

# 방법 C: 수동 입력
if [ -z "$DETECTED_DIR" ]; then
  echo "자동 감지 실패. 메모리 디렉토리 경로를 입력하세요."
  echo "예: ${HOME}/.claude/projects/-Users-$(whoami)/memory"
  echo -n "경로: "
  read -r DETECTED_DIR
fi

if [ -z "$DETECTED_DIR" ]; then
  echo "❌ 경로를 입력하지 않았습니다. 설치를 중단합니다." >&2
  exit 1
fi

if [ ! -d "$DETECTED_DIR" ]; then
  echo "❌ 디렉토리가 존재하지 않습니다: $DETECTED_DIR" >&2
  echo "Claude Code를 먼저 실행하여 메모리 디렉토리를 생성하세요." >&2
  exit 1
fi

# 경로 안전성 검증: HOME 하위인지 확인 (Path Traversal 방지)
case "$DETECTED_DIR" in
  "$HOME"/*)
    ;;
  *)
    echo "❌ 보안 오류: 지정된 경로가 HOME 디렉토리 하위가 아닙니다." >&2
    echo "   경로: $DETECTED_DIR" >&2
    exit 1
    ;;
esac

echo "감지된 메모리 디렉토리: $DETECTED_DIR"
echo ""

# 2. 쉘 설정 파일에 CLAUDE_MEMORY_DIR 추가
SHELL_RC=""
if [ -f "${HOME}/.zshrc" ]; then
  SHELL_RC="${HOME}/.zshrc"
elif [ -f "${HOME}/.bashrc" ]; then
  SHELL_RC="${HOME}/.bashrc"
elif [ -f "${HOME}/.bash_profile" ]; then
  SHELL_RC="${HOME}/.bash_profile"
fi

if [ -n "$SHELL_RC" ]; then
  if grep -q "CLAUDE_MEMORY_DIR" "$SHELL_RC"; then
    echo "ℹ️  CLAUDE_MEMORY_DIR이 이미 ${SHELL_RC}에 설정되어 있습니다."
    grep "CLAUDE_MEMORY_DIR" "$SHELL_RC"
  else
    {
      echo ""
      echo "# memory-health skill"
      echo "export CLAUDE_MEMORY_DIR=\"${DETECTED_DIR}\""
    } >> "$SHELL_RC"
    echo "✅ CLAUDE_MEMORY_DIR을 ${SHELL_RC}에 추가했습니다."
  fi
else
  echo "⚠️  쉘 설정 파일을 찾을 수 없습니다. 아래를 수동으로 추가하세요:"
  echo "  export CLAUDE_MEMORY_DIR=\"${DETECTED_DIR}\""
fi

# 3. 현재 세션에 즉시 적용
export CLAUDE_MEMORY_DIR="${DETECTED_DIR}"

# 4. 필수 파일 생성
echo ""
echo "필수 파일 생성 중..."

touch "${CLAUDE_MEMORY_DIR}/violation-archive.md" && echo "✅ violation-archive.md"
touch "${CLAUDE_MEMORY_DIR}/skill-audit.log"      && echo "✅ skill-audit.log"

# 5. memory-health-rules.md 복사 (템플릿이 있는 경우)
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_TEMPLATE="${SKILL_DIR}/memory-health-rules.md"
RULES_DEST="${CLAUDE_MEMORY_DIR}/memory-health-rules.md"

if [ -f "$RULES_TEMPLATE" ]; then
  if [ -f "$RULES_DEST" ]; then
    echo "ℹ️  memory-health-rules.md가 이미 존재합니다. 덮어쓰지 않습니다."
  else
    cp "$RULES_TEMPLATE" "$RULES_DEST"
    echo "✅ memory-health-rules.md (템플릿에서 복사)"
  fi
fi

# 6. hooks 설치
echo ""
echo "hooks 설치 중..."

HOOKS_DIR="${HOME}/.claude/hooks"
mkdir -p "$HOOKS_DIR"

cp "${SKILL_DIR}/scripts/memory-backup.sh"    "${HOOKS_DIR}/memory-backup.sh"
chmod +x "${HOOKS_DIR}/memory-backup.sh"
echo "✅ memory-backup.sh → ${HOOKS_DIR}/"

cp "${SKILL_DIR}/scripts/memory-line-check.sh" "${HOOKS_DIR}/memory-line-check.sh"
chmod +x "${HOOKS_DIR}/memory-line-check.sh"
echo "✅ memory-line-check.sh → ${HOOKS_DIR}/"

# 7. settings.json 등록 안내 (자동 등록 대신 명확한 수동 안내)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚙️  settings.json 등록 필요 (수동 1회)"
echo ""
# shellcheck disable=SC2088 # tilde is intentional in user-facing message
echo "~/.claude/settings.json의 hooks 섹션에 아래를 추가하세요:"
echo ""
cat <<'EOF'
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/memory-line-check.sh"
          }
        ]
      }
    ]
  }
EOF
echo ""
echo "등록 후 Claude Code를 재시작하면 세션 시작마다 MEMORY.md 줄 수가 자동으로 감시됩니다."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "=== 설치 완료 ==="
echo "새 터미널을 열거나 아래를 실행하세요:"
echo "  source ${SHELL_RC:-'~/.zshrc'}"
echo ""
echo "설치 확인:"
echo "  echo \$CLAUDE_MEMORY_DIR"

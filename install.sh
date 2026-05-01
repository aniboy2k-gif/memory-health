#!/usr/bin/env bash
# install.sh — memory-health 스킬 초기 설정
# 역할: CLAUDE_MEMORY_DIR 환경변수 설정 + 필수 파일 생성
# 사용법: bash install.sh
# 테스트: source install.sh 시 함수만 정의됨 (main 미실행 — BASH_SOURCE 가드)

set -euo pipefail

# detect_memory_dir: stdout 으로 감지된 메모리 디렉토리 경로 출력
# returns: 0 (success — path printed to stdout) / 1 (no path detected/input)
detect_memory_dir() {
  local detected=""

  # 방법 A: 실행 중인 Claude Code 프로세스에서 경로 감지
  if command -v lsof >/dev/null 2>&1; then
    local _pid
    _pid=$(pgrep -f 'claude' | head -1)
    if [ -n "$_pid" ]; then
      detected=$(lsof -p "$_pid" 2>/dev/null \
        | grep -o "${HOME}/.claude/projects/[^/]*/memory" \
        | head -1 || true)
    fi
  fi

  # 방법 B: ~/.claude/projects/ 내에서 MEMORY.md 탐색
  if [ -z "$detected" ]; then
    detected=$(find "${HOME}/.claude/projects" -name "MEMORY.md" -maxdepth 3 2>/dev/null \
      | head -1 | xargs dirname 2>/dev/null || true)
  fi

  # 방법 C: 수동 입력 (대화형). 비대화형 환경 (bats 등) 에서는 stdin redirect 필수
  if [ -z "$detected" ]; then
    echo "자동 감지 실패. 메모리 디렉토리 경로를 입력하세요." >&2
    echo "예: ${HOME}/.claude/projects/-Users-$(whoami)/memory" >&2
    echo -n "경로: " >&2
    read -r -t 60 detected 2>/dev/null || detected=""
  fi

  if [ -z "$detected" ]; then
    return 1
  fi

  echo "$detected"
  return 0
}

# update_shell_rc: $1=memory_dir 받아 쉘 RC 파일에 CLAUDE_MEMORY_DIR export 추가
# 환경 영향: $1 으로 받은 RC 파일 경로 사용 (테스트 격리 가능)
# returns: 0 (always)
update_shell_rc() {
  local memory_dir="$1"
  local shell_rc="${2:-}"

  # $2 미지정 시 자동 탐지
  if [ -z "$shell_rc" ]; then
    if [ -f "${HOME}/.zshrc" ]; then
      shell_rc="${HOME}/.zshrc"
    elif [ -f "${HOME}/.bashrc" ]; then
      shell_rc="${HOME}/.bashrc"
    elif [ -f "${HOME}/.bash_profile" ]; then
      shell_rc="${HOME}/.bash_profile"
    fi
  fi

  if [ -n "$shell_rc" ] && [ -f "$shell_rc" ]; then
    if grep -q "CLAUDE_MEMORY_DIR" "$shell_rc"; then
      echo "ℹ️  CLAUDE_MEMORY_DIR이 이미 ${shell_rc}에 설정되어 있습니다."
      grep "CLAUDE_MEMORY_DIR" "$shell_rc"
    else
      printf '\n# memory-health skill\nexport CLAUDE_MEMORY_DIR="%s"\n' "$memory_dir" >> "$shell_rc"
      echo "✅ CLAUDE_MEMORY_DIR을 ${shell_rc}에 추가했습니다."
    fi
  else
    echo "⚠️  쉘 설정 파일을 찾을 수 없습니다. 아래를 수동으로 추가하세요:"
    echo "  export CLAUDE_MEMORY_DIR=\"${memory_dir}\""
  fi

  return 0
}

# create_required_files: $1=memory_dir 인자로 필수 파일 생성
# 생성: violation-archive.md, skill-audit.log
# returns: 0 (always)
create_required_files() {
  local memory_dir="$1"
  touch "${memory_dir}/violation-archive.md" && echo "✅ violation-archive.md"
  touch "${memory_dir}/skill-audit.log"      && echo "✅ skill-audit.log"
  return 0
}

# copy_rules_template: $1=memory_dir, $2=skill_dir
# 동작: skill_dir/memory-health-rules.md 가 있으면 memory_dir 로 복사 (덮어쓰기 금지)
# returns: 0 (always — 템플릿 부재 또는 대상 존재 시 메시지만)
copy_rules_template() {
  local memory_dir="$1"
  local skill_dir="$2"
  local rules_template="${skill_dir}/memory-health-rules.md"
  local rules_dest="${memory_dir}/memory-health-rules.md"

  if [ -f "$rules_template" ]; then
    if [ -f "$rules_dest" ]; then
      echo "ℹ️  memory-health-rules.md가 이미 존재합니다. 덮어쓰지 않습니다."
    else
      cp "$rules_template" "$rules_dest"
      echo "✅ memory-health-rules.md (템플릿에서 복사)"
    fi
  fi

  return 0
}

# print_rules_dir_template: CLAUDE_RULES_DIR 환경변수 샘플 출력
# env.sh에 선택적으로 저장. shell profile 직접 수정 없음.
# returns: 0 (always)
print_rules_dir_template() {
  local env_file="${HOME}/.claude/da-tools/env.sh"
  local rules_dir_sample=""

  # 샘플 경로 추정 (실제 경로 입력 유도)
  if [ -d "/Volumes" ]; then
    rules_dir_sample="/Volumes/L'Atelier de Claude/workspace/claude-forge/rules"
  else
    rules_dir_sample="${HOME}/workspace/claude-forge/rules"
  fi

  echo ""
  echo "=== Rules Checker 설정 (선택 사항) ==="
  echo ""
  echo "자동 로드 rules 파일 크기 검사(/memory-health --rules)를 사용하려면"
  echo "CLAUDE_RULES_DIR을 설정해야 합니다."
  echo ""
  echo "아래 환경변수를 ~/.zshrc 또는 ~/.bashrc에 직접 추가하거나,"
  echo "${env_file}에 저장하세요 (shell profile 직접 수정 없음):"
  echo ""
  echo "  # Rules Checker 설정"
  echo "  export CLAUDE_RULES_DIR=\"${rules_dir_sample}\""
  echo "  export CLAUDE_RULES_SIZE_WARN=20000       # 선택: WARN 임계값 (기본 20000자)"
  echo "  export CLAUDE_RULES_SIZE_CRITICAL=40000   # 선택: CRITICAL 임계값 (기본 40000자)"
  echo "  export MEMORY_HEALTH_DEFAULT_RULES=false  # 선택: true 시 기본 dry-run에 자동 포함"
  echo ""

  echo -n "위 내용을 ${env_file}에 저장하시겠습니까? (y/N): "
  local ans
  read -r ans 2>/dev/null || ans="N"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    mkdir -p "$(dirname "$env_file")"
    {
      echo ""
      echo "# memory-health Rules Checker ($(date +%Y-%m-%d))"
      echo "export CLAUDE_RULES_DIR=\"${rules_dir_sample}\""
      echo "# export CLAUDE_RULES_SIZE_WARN=20000"
      echo "# export CLAUDE_RULES_SIZE_CRITICAL=40000"
      echo "# export MEMORY_HEALTH_DEFAULT_RULES=false"
    } >> "$env_file"
    echo "✅ ${env_file}에 저장했습니다."
    echo "   실행: source ${env_file}"
    echo "   CLAUDE_RULES_DIR 경로를 실제 경로로 수정하세요."
  else
    echo "ℹ️  저장 생략. 위 내용을 직접 shell 설정 파일에 추가하세요."
  fi

  return 0
}

# main: 전체 설치 흐름 (직접 실행 시에만 호출됨 — BASH_SOURCE 가드)
main() {
  echo "=== memory-health install.sh ==="
  echo ""

  # 1. CLAUDE_MEMORY_DIR 자동 감지
  local memory_dir
  if ! memory_dir=$(detect_memory_dir); then
    echo "❌ 경로를 입력하지 않았습니다. 설치를 중단합니다." >&2
    exit 1
  fi

  if [ ! -d "$memory_dir" ]; then
    echo "❌ 디렉토리가 존재하지 않습니다: $memory_dir" >&2
    echo "Claude Code를 먼저 실행하여 메모리 디렉토리를 생성하세요." >&2
    exit 1
  fi

  echo "감지된 메모리 디렉토리: $memory_dir"
  echo ""

  # 2. 쉘 설정 파일에 CLAUDE_MEMORY_DIR 추가
  update_shell_rc "$memory_dir"

  # 3. 현재 세션에 즉시 적용
  export CLAUDE_MEMORY_DIR="$memory_dir"

  # 4. 필수 파일 생성
  echo ""
  echo "필수 파일 생성 중..."
  create_required_files "$memory_dir"

  # 5. 규칙 템플릿 복사
  local skill_dir
  skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  copy_rules_template "$memory_dir" "$skill_dir"

  # 6. Rules Checker 설정 안내 (env.sh 선택 저장)
  print_rules_dir_template

  # 7. 완료 안내
  echo ""
  echo "=== 설치 완료 ==="
  local shell_rc=""
  for rc in "${HOME}/.zshrc" "${HOME}/.bashrc" "${HOME}/.bash_profile"; do
    [ -f "$rc" ] && shell_rc="$rc" && break
  done
  echo "새 터미널을 열거나 아래를 실행하세요:"
  echo "  source ${shell_rc:-~/.zshrc}"
  echo ""
  echo "설치 확인:"
  echo "  echo \$CLAUDE_MEMORY_DIR"
  echo "  echo \$CLAUDE_RULES_DIR"
}

# 직접 실행 시에만 main 호출 (source 시 함수 정의만 — bats 테스트 격리)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

#!/usr/bin/env bats
# scripts.bats - syntax + smoke tests for scripts/*.sh

setup() {
  SCRIPTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
}

# ----- bash syntax checks -----

@test "memory-health-log.sh bash syntax" {
  run bash -n "${SCRIPTS_DIR}/memory-health-log.sh"
  [ "$status" = "0" ]
}

@test "memory-line-check.sh bash syntax" {
  run bash -n "${SCRIPTS_DIR}/memory-line-check.sh"
  [ "$status" = "0" ]
}

@test "memory-backup.sh bash syntax" {
  run bash -n "${SCRIPTS_DIR}/memory-backup.sh"
  [ "$status" = "0" ]
}

# ----- exec permission -----

@test "memory-health-log.sh is executable" {
  [ -x "${SCRIPTS_DIR}/memory-health-log.sh" ]
}

@test "memory-line-check.sh is executable" {
  [ -x "${SCRIPTS_DIR}/memory-line-check.sh" ]
}

# ----- shellcheck (when installed) -----

@test "memory-health-log.sh shellcheck clean" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "${SCRIPTS_DIR}/memory-health-log.sh"
  [ "$status" = "0" ]
}

@test "memory-line-check.sh shellcheck clean" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "${SCRIPTS_DIR}/memory-line-check.sh"
  [ "$status" = "0" ]
}

@test "memory-backup.sh shellcheck error-level clean" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  # Existing SC2012/SC2038 are info/warning level only — fail only on errors
  run shellcheck -S error "${SCRIPTS_DIR}/memory-backup.sh"
  [ "$status" = "0" ]
}

# ----- check-rules.sh: syntax + exec permission -----

@test "check-rules.sh bash syntax" {
  run bash -n "${SCRIPTS_DIR}/check-rules.sh"
  [ "$status" = "0" ]
}

@test "check-rules.sh is executable" {
  [ -x "${SCRIPTS_DIR}/check-rules.sh" ]
}

@test "check-rules.sh shellcheck clean" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck -S error "${SCRIPTS_DIR}/check-rules.sh"
  [ "$status" = "0" ]
}

# ----- check-rules.sh: 기능 검증 (bats_test_tmpdir 격리) -----

# check-rules.sh: CLAUDE_RULES_DIR 미설정 시 exit 1
@test "check-rules.sh CLAUDE_RULES_DIR unset returns exit 1" {
  # 격리: 기존 CLAUDE_RULES_DIR 환경변수 제거
  run env -u CLAUDE_RULES_DIR bash "${SCRIPTS_DIR}/check-rules.sh"
  [ "$status" = "1" ]
}

# check-rules.sh: 존재하지 않는 디렉토리 시 exit 1
@test "check-rules.sh nonexistent dir returns exit 1" {
  run env CLAUDE_RULES_DIR="/nonexistent/path/that/does/not/exist" \
      bash "${SCRIPTS_DIR}/check-rules.sh"
  [ "$status" = "1" ]
}

# check-rules.sh: OK 파일만 있으면 exit 0
@test "check-rules.sh OK file only returns exit 0" {
  local tmpdir
  tmpdir=$(mktemp -d)

  # 10000자 파일 생성 (OK 범위 < 20000자)
  python3 -c "print('x' * 10000)" > "${tmpdir}/small-rule.md"

  run env CLAUDE_RULES_DIR="$tmpdir" \
      CLAUDE_RULES_SIZE_WARN=20000 \
      CLAUDE_RULES_SIZE_CRITICAL=40000 \
      bash "${SCRIPTS_DIR}/check-rules.sh"

  rm -rf "$tmpdir"
  [ "$status" = "0" ]
  [[ "$output" == *"OK"* ]]
}

# check-rules.sh: WARN 파일 존재 시 exit 0 (기본 모드)
@test "check-rules.sh WARN file returns exit 0 default mode" {
  local tmpdir
  tmpdir=$(mktemp -d)

  # 25000자 파일 (WARN 범위: 20000-40000자)
  python3 -c "print('x' * 25000)" > "${tmpdir}/warn-rule.md"

  run env CLAUDE_RULES_DIR="$tmpdir" \
      CLAUDE_RULES_SIZE_WARN=20000 \
      CLAUDE_RULES_SIZE_CRITICAL=40000 \
      bash "${SCRIPTS_DIR}/check-rules.sh"

  rm -rf "$tmpdir"
  [ "$status" = "0" ]
  [[ "$output" == *"WARN"* ]]
}

# check-rules.sh: WARN 파일 존재 + --strict 시 exit 2
@test "check-rules.sh WARN file with --strict returns exit 2" {
  local tmpdir
  tmpdir=$(mktemp -d)

  python3 -c "print('x' * 25000)" > "${tmpdir}/warn-rule.md"

  run env CLAUDE_RULES_DIR="$tmpdir" \
      CLAUDE_RULES_SIZE_WARN=20000 \
      CLAUDE_RULES_SIZE_CRITICAL=40000 \
      bash "${SCRIPTS_DIR}/check-rules.sh" --strict

  rm -rf "$tmpdir"
  [ "$status" = "2" ]
}

# check-rules.sh: CRITICAL 파일 존재 시 exit 0 (read-only)
@test "check-rules.sh CRITICAL file returns exit 0 read-only" {
  local tmpdir
  tmpdir=$(mktemp -d)

  # 50000자 파일 (CRITICAL > 40000자)
  python3 -c "print('x' * 50000)" > "${tmpdir}/critical-rule.md"

  run env CLAUDE_RULES_DIR="$tmpdir" \
      CLAUDE_RULES_SIZE_WARN=20000 \
      CLAUDE_RULES_SIZE_CRITICAL=40000 \
      bash "${SCRIPTS_DIR}/check-rules.sh"

  rm -rf "$tmpdir"
  [ "$status" = "0" ]
  [[ "$output" == *"CRITICAL"* ]]
}

# check-rules.sh: 숨김 파일(.dotfile) 제외
@test "check-rules.sh hidden dotfile excluded" {
  local tmpdir
  tmpdir=$(mktemp -d)

  # 숨김 파일 (CRITICAL 크기여도 무시)
  python3 -c "print('x' * 50000)" > "${tmpdir}/.hidden-rule.md"
  # 일반 파일 OK
  python3 -c "print('x' * 100)" > "${tmpdir}/normal-rule.md"

  run env CLAUDE_RULES_DIR="$tmpdir" \
      CLAUDE_RULES_SIZE_WARN=20000 \
      CLAUDE_RULES_SIZE_CRITICAL=40000 \
      bash "${SCRIPTS_DIR}/check-rules.sh"

  rm -rf "$tmpdir"
  [ "$status" = "0" ]
  # CRITICAL 출력 없어야 함
  [[ "$output" != *"CRITICAL"* ]]
}

# check-rules.sh: 서브디렉토리 무시
@test "check-rules.sh subdirectory ignored" {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "${tmpdir}/subdir"

  # 서브디렉토리의 CRITICAL 파일 — 무시되어야 함
  python3 -c "print('x' * 50000)" > "${tmpdir}/subdir/big-rule.md"
  # 최상위 OK 파일
  python3 -c "print('x' * 100)" > "${tmpdir}/top-rule.md"

  run env CLAUDE_RULES_DIR="$tmpdir" \
      CLAUDE_RULES_SIZE_WARN=20000 \
      CLAUDE_RULES_SIZE_CRITICAL=40000 \
      bash "${SCRIPTS_DIR}/check-rules.sh"

  rm -rf "$tmpdir"
  [ "$status" = "0" ]
  [[ "$output" != *"CRITICAL"* ]]
}

# check-rules.sh: 심볼릭 링크 follow + 중복 제거
@test "check-rules.sh symlink follow with dedup" {
  local tmpdir
  tmpdir=$(mktemp -d)

  # 실제 파일
  python3 -c "print('x' * 25000)" > "${tmpdir}/actual-rule.md"
  # 동일 파일을 가리키는 심볼릭 링크
  ln -s "${tmpdir}/actual-rule.md" "${tmpdir}/link-rule.md"

  run env CLAUDE_RULES_DIR="$tmpdir" \
      CLAUDE_RULES_SIZE_WARN=20000 \
      CLAUDE_RULES_SIZE_CRITICAL=40000 \
      bash "${SCRIPTS_DIR}/check-rules.sh"

  rm -rf "$tmpdir"
  [ "$status" = "0" ]
  # WARN 등급 라인은 1건만 출력 (중복 제거).
  # grep 패턴: "WARN" 뒤 공백 + 숫자 + "자" — 등급 라인만 매칭, "WARN N건" 요약 라인 제외.
  local warn_count
  warn_count=$(echo "$output" | grep -cE 'WARN +[0-9,]+자' || true)
  [ "$warn_count" -le 1 ]
}

# check-rules.sh: 정상 dedup symlink 은 순환으로 오분류되면 안 됨 (#186 본질 결함 A fix)
# 외부 실파일 1개 + 링크 2개 → 2번째 링크가 iteration 순서 무관하게 항상 dedup 케이스 (loop 아님)
@test "check-rules.sh symlink dedup not misclassified as loop" {
  local tmpdir realdir
  tmpdir=$(mktemp -d)
  realdir=$(mktemp -d)
  python3 -c "print('x' * 5000)" > "${realdir}/target.md"
  ln -s "${realdir}/target.md" "${tmpdir}/link-a.md"
  ln -s "${realdir}/target.md" "${tmpdir}/link-b.md"

  run env CLAUDE_RULES_DIR="$tmpdir" \
      CLAUDE_RULES_NO_SOURCE_A=1 \
      bash "${SCRIPTS_DIR}/check-rules.sh"

  rm -rf "$tmpdir" "$realdir"
  [ "$status" = "0" ]
  # 두 symlink 가 같은 실파일을 가리키는 정상 dedup → "순환" 오분류 금지
  ! echo "$output" | grep -q "순환 심볼릭 링크"
}

# check-rules.sh: 실제 순환 symlink (A→B→A) 는 여전히 감지되어야 함 (#186 fix A 회귀 가드)
@test "check-rules.sh real symlink cycle still detected" {
  local tmpdir
  tmpdir=$(mktemp -d)
  # 순환: cyc-a.md → cyc-b.md → cyc-a.md
  ln -s "${tmpdir}/cyc-b.md" "${tmpdir}/cyc-a.md"
  ln -s "${tmpdir}/cyc-a.md" "${tmpdir}/cyc-b.md"

  run env CLAUDE_RULES_DIR="$tmpdir" \
      CLAUDE_RULES_NO_SOURCE_A=1 \
      bash "${SCRIPTS_DIR}/check-rules.sh"

  rm -rf "$tmpdir"
  [ "$status" = "0" ]
  # 실제 순환은 감지 (순환 또는 깊이 초과 마커 출력)
  echo "$output" | grep -qE "순환 심볼릭 링크|심볼릭 링크 깊이"
}

# check-rules.sh: CLAUDE_RULES_NO_SOURCE_A=1 시 실환경 CLAUDE.md @import 제외 (#186 본질 결함 B fix)
@test "check-rules.sh CLAUDE_RULES_NO_SOURCE_A excludes CLAUDE.md @ imports" {
  local tmpdir
  tmpdir=$(mktemp -d)
  python3 -c "print('x' * 5000)" > "${tmpdir}/only-rule.md"

  run env CLAUDE_RULES_DIR="$tmpdir" \
      CLAUDE_RULES_NO_SOURCE_A=1 \
      bash "${SCRIPTS_DIR}/check-rules.sh"

  rm -rf "$tmpdir"
  [ "$status" = "0" ]
  # Source A 비활성화 → 실환경 CLAUDE.md 의 @import (예: @RTK.md) 출력 금지 (test 격리)
  ! echo "$output" | grep -qE '@[A-Za-z]'
}

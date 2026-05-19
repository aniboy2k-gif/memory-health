#!/usr/bin/env bats
# test-r1-r6.bats — 전체 R1~R6 fixture suite 통합 runner
#
# 검증 대상:
# 1. fixture 10건 존재 + UTF-8 정상 + non-empty
# 2. memory-health-rules.md R1~R6 본문 정합 (rule 정의 박제)
# 3. 적용 순서 박제 (R1 -> R2 -> R5 -> R3 -> R4 -> R6)
# 4. SKILL.md F3 Optimizer 와의 정합
#
# 의의: fixture + bats 인프라의 메타 검증. R6 idempotency 와 Red-Green 사이클은 별도 bats 파일.
# 주의: bats 1.13.0 호환을 위해 @test 이름은 ASCII 만 사용. 한국어 설명은 주석에 박제.

setup() {
  TESTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  FIXTURES_DIR="${TESTS_DIR}/fixtures"
  SKILL_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
  RULES_FILE="${SKILL_DIR}/memory-health-rules.md"
  SKILL_FILE="${SKILL_DIR}/SKILL.md"
}

# ----- Section A: fixture directory + file existence -----

# fixtures 디렉토리 존재
@test "Runner-A1 fixtures directory exists" {
  [ -d "$FIXTURES_DIR" ]
}

# R1 fixture pair (.before + .after)
@test "Runner-A2 R1 fixture pair exists" {
  [ -f "${FIXTURES_DIR}/r1-duplicate-pointer.before.md" ]
  [ -f "${FIXTURES_DIR}/r1-duplicate-pointer.after.md" ]
}

# R2 fixture pair
@test "Runner-A3 R2 fixture pair exists" {
  [ -f "${FIXTURES_DIR}/r2-expired-pointer.before.md" ]
  [ -f "${FIXTURES_DIR}/r2-expired-pointer.after.md" ]
}

# R3 fixture pair
@test "Runner-A4 R3 fixture pair exists" {
  [ -f "${FIXTURES_DIR}/r3-inline-too-long.before.md" ]
  [ -f "${FIXTURES_DIR}/r3-inline-too-long.after.md" ]
}

# R4 fixture pair
@test "Runner-A5 R4 fixture pair exists" {
  [ -f "${FIXTURES_DIR}/r4-stale-feedback.before.md" ]
  [ -f "${FIXTURES_DIR}/r4-stale-feedback.after.md" ]
}

# R5 fixture pair
@test "Runner-A6 R5 fixture pair exists" {
  [ -f "${FIXTURES_DIR}/r5-empty-table-row.before.md" ]
  [ -f "${FIXTURES_DIR}/r5-empty-table-row.after.md" ]
}

# 모든 fixture non-empty
@test "Runner-A7 all fixtures non-empty" {
  for f in "${FIXTURES_DIR}"/*.md; do
    [ -s "$f" ]
  done
}

# 모든 fixture UTF-8 정상
@test "Runner-A8 all fixtures decode as UTF-8" {
  for f in "${FIXTURES_DIR}"/*.md; do
    run python3 -c "open('$f', encoding='utf-8').read()"
    [ "$status" = "0" ]
  done
}

# fixture 총 10건 (5 rule x .before + .after)
@test "Runner-A9 fixture count equals 10" {
  local count
  count=$(find "$FIXTURES_DIR" -maxdepth 1 -name "*.md" -type f | wc -l | tr -d ' ')
  [ "$count" = "10" ]
}

# ----- Section B: memory-health-rules.md R1~R6 본문 정합 -----

# rules 파일 존재
@test "Runner-B1 rules file exists" {
  [ -f "$RULES_FILE" ]
}

# R1 정의 박제 (중복 포인터 제거)
@test "Runner-B2 R1 definition present" {
  run grep -q "^## R1: " "$RULES_FILE"
  [ "$status" = "0" ]
}

# R2 정의 박제 (만료된 프로젝트 포인터)
@test "Runner-B3 R2 definition present" {
  run grep -q "^## R2: " "$RULES_FILE"
  [ "$status" = "0" ]
}

# R3 정의 박제 (과도한 인라인)
@test "Runner-B4 R3 definition present" {
  run grep -q "^## R3: " "$RULES_FILE"
  [ "$status" = "0" ]
}

# R4 정의 박제 (비활성 피드백 메모리)
@test "Runner-B5 R4 definition present" {
  run grep -q "^## R4: " "$RULES_FILE"
  [ "$status" = "0" ]
}

# R5 정의 박제 (테이블 행 압축)
@test "Runner-B6 R5 definition present" {
  run grep -q "^## R5: " "$RULES_FILE"
  [ "$status" = "0" ]
}

# R6 정의 박제 (Sidecar Fingerprint)
@test "Runner-B7 R6 Sidecar Fingerprint definition present" {
  run grep -q "^## R6: Sidecar Fingerprint" "$RULES_FILE"
  [ "$status" = "0" ]
}

# ----- Section C: apply order (R1 -> R2 -> R5 -> R3 -> R4 -> R6) -----

# 적용 순서 표기 존재
@test "Runner-C1 apply order section present" {
  run grep -q "적용 순서" "$RULES_FILE"
  [ "$status" = "0" ]
}

# 적용 순서가 R1 -> R2 -> R5 -> R3 -> R4 -> R6
@test "Runner-C2 apply order is R1 R2 R5 R3 R4 R6" {
  local order_line
  order_line=$(grep -A2 "적용 순서" "$RULES_FILE" | grep "R1" | head -1 || true)
  [[ "$order_line" == *"R1"*"R2"*"R5"*"R3"*"R4"*"R6"* ]]
}

# ----- Section D: SKILL.md F3 Optimizer 정합 -----

# SKILL.md 존재
@test "Runner-D1 SKILL.md exists" {
  [ -f "$SKILL_FILE" ]
}

# SKILL.md F3 Optimizer 섹션 존재
@test "Runner-D2 SKILL.md Optimizer section present" {
  run grep -q "Optimizer" "$SKILL_FILE"
  [ "$status" = "0" ]
}

# SKILL.md v2 명령 구조 (check / fix / scan / rules) 박제
@test "Runner-D3 SKILL.md v2 commands present" {
  run grep -q "memory-health check" "$SKILL_FILE"
  [ "$status" = "0" ]
  run grep -q "memory-health fix" "$SKILL_FILE"
  [ "$status" = "0" ]
  run grep -q "memory-health scan" "$SKILL_FILE"
  [ "$status" = "0" ]
  run grep -q "memory-health rules" "$SKILL_FILE"
  [ "$status" = "0" ]
}

# ----- Section E: R6 sidecar directory spec 박제 정합 -----

# R6 sidecar 위치 spec 박제
@test "Runner-E1 R6 sidecar directory spec present" {
  run grep -q "memory-health-fingerprints" "$RULES_FILE"
  [ "$status" = "0" ]
}

# R6 inline marker 금지 박제 (ChatGPT C-2 정합)
@test "Runner-E2 R6 inline marker prohibition present" {
  run grep -q "inline marker" "$RULES_FILE"
  [ "$status" = "0" ]
}

# ----- Section F: 다른 bats 파일 존재 (suite 완전성) -----

# r6-sidecar-idempotency.bats 존재
@test "Runner-F1 r6-sidecar-idempotency.bats exists" {
  [ -f "${TESTS_DIR}/r6-sidecar-idempotency.bats" ]
}

# red-green-tdd.bats 존재
@test "Runner-F2 red-green-tdd.bats exists" {
  [ -f "${TESTS_DIR}/red-green-tdd.bats" ]
}

# install.bats 존재 (기존 인프라 보존)
@test "Runner-F3 install.bats exists" {
  [ -f "${TESTS_DIR}/install.bats" ]
}

# scripts.bats 존재 (기존 인프라 보존)
@test "Runner-F4 scripts.bats exists" {
  [ -f "${TESTS_DIR}/scripts.bats" ]
}

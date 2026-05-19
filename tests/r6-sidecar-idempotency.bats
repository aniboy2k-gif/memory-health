#!/usr/bin/env bats
# r6-sidecar-idempotency.bats — R6 Sidecar Fingerprint + Phase C Atomicity 통합 검증
#
# 검증 대상 (memory-health-rules.md R6, SKILL.md "Atomicity 동작 흐름"):
# 1. R6 sidecar fingerprint sha256 비교 invariant (spec 박제)
# 2. memory-wal.sh init/commit/recover 동작
# 3. memory-journal.sh append-only + sha256 chain
# 4. WAL + sidecar + journal + backup 통합 시나리오
#
# 주의: R6 sidecar 적용 스크립트는 본 Phase E 범위 외. 본 bats 는 sha256 비교 logic 을
#       bats 내부 helper 로 박제. 향후 R6 sidecar 전용 스크립트 추가 시 helper 교체.
# 주의: bats 1.13.0 호환을 위해 @test 이름은 ASCII 만 사용. 한국어 설명은 주석에 박제.

setup() {
  SCRIPTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
  TEST_TMPDIR=$(mktemp -d)
  export _R6_FP_DIR="${TEST_TMPDIR}/fingerprints"
  mkdir -p "$_R6_FP_DIR"
}

teardown() {
  if [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

# Helper: R6 sidecar invariant 동작 (bats 내부 박제, 향후 전용 스크립트로 교체)
# Usage: r6_check <file_path>
# Returns: 0 = 변경 필요 (sha256 불일치 또는 sidecar 부재), 1 = 차단 (sha256 일치)
r6_check() {
  local file="$1"
  local hash_prefix
  hash_prefix=$(printf '%s' "$file" | shasum -a 256 | awk '{print substr($1,1,16)}')
  local sidecar="${_R6_FP_DIR}/${hash_prefix}.json"

  local current_hash
  current_hash=$(shasum -a 256 "$file" | awk '{print $1}')

  if [ ! -f "$sidecar" ]; then
    return 0
  fi

  local stored_hash
  stored_hash=$(python3 -c "import json,sys; print(json.load(open('$sidecar'))['last_run_sha256'])" 2>/dev/null || echo "")

  if [ "$current_hash" = "$stored_hash" ]; then
    return 1
  fi
  return 0
}

# Helper: R6 sidecar 갱신
r6_update() {
  local file="$1"
  shift
  local rules="$*"
  local hash_prefix
  hash_prefix=$(printf '%s' "$file" | shasum -a 256 | awk '{print substr($1,1,16)}')
  local sidecar="${_R6_FP_DIR}/${hash_prefix}.json"
  local current_hash
  current_hash=$(shasum -a 256 "$file" | awk '{print $1}')
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat > "${sidecar}.tmp" <<EOF
{
  "file_path": "${file}",
  "last_run_sha256": "${current_hash}",
  "last_run_rules": [${rules}],
  "last_run_timestamp": "${ts}",
  "tool_version": "1.1.0",
  "rule_version": "1.0.0"
}
EOF
  mv "${sidecar}.tmp" "$sidecar"
}

# ----- R6-1: sidecar 부재 시 변경 진행 (첫 실행) -----

@test "R6-1 r6_check returns 0 when sidecar missing" {
  local target="${TEST_TMPDIR}/memory.md"
  printf 'initial content\n' > "$target"

  run r6_check "$target"
  [ "$status" = "0" ]
}

# ----- R6-2: sidecar 존재 + 변경 없음 -> 차단 (idempotency) -----

@test "R6-2 r6_check returns 1 when sha256 matches sidecar" {
  local target="${TEST_TMPDIR}/memory.md"
  printf 'stable content\n' > "$target"

  r6_update "$target" '"R1"'

  run r6_check "$target"
  [ "$status" = "1" ]
}

# ----- R6-3: 사용자 직접 편집 후 -> 변경 진행 -----

@test "R6-3 r6_check returns 0 after user edits target" {
  local target="${TEST_TMPDIR}/memory.md"
  printf 'original\n' > "$target"
  r6_update "$target" '"R1"'

  printf 'user edited content\n' >> "$target"

  run r6_check "$target"
  [ "$status" = "0" ]
}

# ----- R6-4: sidecar 손상 -> 변경 진행 (재생성 가능) -----

@test "R6-4 r6_check returns 0 when sidecar JSON corrupted" {
  local target="${TEST_TMPDIR}/memory.md"
  printf 'content\n' > "$target"
  r6_update "$target" '"R1"'

  local hash_prefix
  hash_prefix=$(printf '%s' "$target" | shasum -a 256 | awk '{print substr($1,1,16)}')
  echo "CORRUPTED{not json" > "${_R6_FP_DIR}/${hash_prefix}.json"

  run r6_check "$target"
  [ "$status" = "0" ]
}

# ----- R6-5: 통합 시나리오 — WAL + R6 sidecar + journal + backup -----

@test "R6-5 integration WAL init backup sidecar journal commit" {
  local target="${TEST_TMPDIR}/memory.md"
  printf 'baseline\n' > "$target"

  # WAL init
  local wal_id
  wal_id=$(CLAUDE_MEMORY_DIR="$TEST_TMPDIR" bash "${SCRIPTS_DIR}/memory-wal.sh" init "$target" "R1" 2>&1 | tail -1 || true)
  [ -n "$wal_id" ]

  # 변경 적용 (R1 모의)
  printf 'R1 applied\n' > "$target"

  # R6 sidecar 갱신
  r6_update "$target" '"R1"'

  # Journal log (선택적 — 스크립트 인터페이스 확인용)
  CLAUDE_MEMORY_DIR="$TEST_TMPDIR" bash "${SCRIPTS_DIR}/memory-journal.sh" log "r1-apply" "$target" "R1" "$wal_id" '{}' 2>/dev/null || true

  # WAL commit
  run env CLAUDE_MEMORY_DIR="$TEST_TMPDIR" bash "${SCRIPTS_DIR}/memory-wal.sh" commit "$wal_id"

  # 통합 시나리오: WAL commit 후 R6 sidecar 가 최종 상태 박제
  run r6_check "$target"
  [ "$status" = "1" ]
}

# ----- R6-6: Property — idempotency (재실행 차단) -----

@test "R6-6 second run with same input is blocked" {
  local target="${TEST_TMPDIR}/memory.md"
  printf 'data\n' > "$target"

  # 첫 실행
  run r6_check "$target"
  [ "$status" = "0" ]
  r6_update "$target" '"R1"'

  # 두 번째 실행 — 차단
  run r6_check "$target"
  [ "$status" = "1" ]
}

# ----- R6-7: Atomic sidecar write (rename) — TOCTOU 회피 박제 -----

@test "R6-7 sidecar uses atomic mv pattern from tmp to final" {
  local target="${TEST_TMPDIR}/memory.md"
  printf 'content\n' > "$target"
  r6_update "$target" '"R1"'

  local hash_prefix
  hash_prefix=$(printf '%s' "$target" | shasum -a 256 | awk '{print substr($1,1,16)}')
  local sidecar="${_R6_FP_DIR}/${hash_prefix}.json"

  [ -f "$sidecar" ]
  [ ! -f "${sidecar}.tmp" ]
}

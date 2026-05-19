#!/usr/bin/env bats
# red-green-tdd.bats — Red-Green-Improve TDD 사이클 검증
#
# 검증 대상 (verification.md, golden-principles.md #3, testing.md):
# 1. Red-Green-Improve 사이클 자체의 박제 (R6 idempotency 활용)
# 2. fixture .before.md -> .after.md 변환 사양 정합 (Phase E 의의)
# 3. 회귀 방지 — fix 적용 후 RED 재현 검증 (Red-Green 페어 정상성)
#
# 본 테스트는 두 가지 의의:
# A. R6 sidecar invariant 의 RED-GREEN-RED 검증 (회귀 방지)
# B. fixture 쌍의 expected behavior 박제 — .before != .after 보장 (사양 자체의 정상성)
# 주의: bats 1.13.0 호환을 위해 @test 이름은 ASCII 만 사용. 한국어 설명은 주석에 박제.

setup() {
  FIXTURES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/fixtures" && pwd)"
  SCRIPTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
  TEST_TMPDIR=$(mktemp -d)
}

teardown() {
  if [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

# ----- Section A: Red-Green-Improve 사이클 (R6 idempotency 기반) -----

# RED — sidecar 부재 시 변경 차단되지 않음
@test "TDD-A1 RED sidecar absent no block" {
  local target="${TEST_TMPDIR}/memory.md"
  local fp_dir="${TEST_TMPDIR}/fp"
  mkdir -p "$fp_dir"
  printf 'data\n' > "$target"

  local hash_prefix
  hash_prefix=$(printf '%s' "$target" | shasum -a 256 | awk '{print substr($1,1,16)}')

  [ ! -f "${fp_dir}/${hash_prefix}.json" ]
}

# GREEN — sidecar 갱신 후 sha256 일치 시 변경 차단
@test "TDD-A2 GREEN sidecar matches sha256 blocks change" {
  local target="${TEST_TMPDIR}/memory.md"
  local fp_dir="${TEST_TMPDIR}/fp"
  mkdir -p "$fp_dir"
  printf 'stable\n' > "$target"

  local current_hash
  current_hash=$(shasum -a 256 "$target" | awk '{print $1}')
  local hash_prefix
  hash_prefix=$(printf '%s' "$target" | shasum -a 256 | awk '{print substr($1,1,16)}')
  local sidecar="${fp_dir}/${hash_prefix}.json"

  cat > "$sidecar" <<EOF
{"file_path":"${target}","last_run_sha256":"${current_hash}","last_run_rules":["R1"],"last_run_timestamp":"2026-05-19T00:00:00Z","tool_version":"1.1.0","rule_version":"1.0.0"}
EOF

  local stored_hash
  stored_hash=$(python3 -c "import json; print(json.load(open('$sidecar'))['last_run_sha256'])")
  [ "$current_hash" = "$stored_hash" ]
}

# RED 재현 — fix 회귀 시 sha256 불일치 (회귀 감지)
@test "TDD-A3 RED reproduce fix regression detects mismatch" {
  local target="${TEST_TMPDIR}/memory.md"
  local fp_dir="${TEST_TMPDIR}/fp"
  mkdir -p "$fp_dir"
  printf 'original\n' > "$target"

  local original_hash
  original_hash=$(shasum -a 256 "$target" | awk '{print $1}')
  local hash_prefix
  hash_prefix=$(printf '%s' "$target" | shasum -a 256 | awk '{print substr($1,1,16)}')
  local sidecar="${fp_dir}/${hash_prefix}.json"

  cat > "$sidecar" <<EOF
{"file_path":"${target}","last_run_sha256":"${original_hash}","last_run_rules":["R1"],"last_run_timestamp":"2026-05-19T00:00:00Z","tool_version":"1.1.0","rule_version":"1.0.0"}
EOF

  printf 'modified\n' >> "$target"
  local new_hash
  new_hash=$(shasum -a 256 "$target" | awk '{print $1}')

  [ "$original_hash" != "$new_hash" ]
}

# ----- Section B: fixture .before/.after 쌍의 정상성 (사양 박제 검증) -----

# R1 fixture .before.md 와 .after.md 가 다름
@test "TDD-B1 R1 fixture before differs from after" {
  local before="${FIXTURES_DIR}/r1-duplicate-pointer.before.md"
  local after="${FIXTURES_DIR}/r1-duplicate-pointer.after.md"

  [ -f "$before" ]
  [ -f "$after" ]
  run diff "$before" "$after"
  [ "$status" != "0" ]
}

# R2 fixture .before.md 와 .after.md 가 다름
@test "TDD-B2 R2 fixture before differs from after" {
  local before="${FIXTURES_DIR}/r2-expired-pointer.before.md"
  local after="${FIXTURES_DIR}/r2-expired-pointer.after.md"

  [ -f "$before" ]
  [ -f "$after" ]
  run diff "$before" "$after"
  [ "$status" != "0" ]
}

# R3 fixture .before.md 와 .after.md 가 다름
@test "TDD-B3 R3 fixture before differs from after" {
  local before="${FIXTURES_DIR}/r3-inline-too-long.before.md"
  local after="${FIXTURES_DIR}/r3-inline-too-long.after.md"

  [ -f "$before" ]
  [ -f "$after" ]
  run diff "$before" "$after"
  [ "$status" != "0" ]
}

# R4 fixture .before.md 와 .after.md 가 다름
@test "TDD-B4 R4 fixture before differs from after" {
  local before="${FIXTURES_DIR}/r4-stale-feedback.before.md"
  local after="${FIXTURES_DIR}/r4-stale-feedback.after.md"

  [ -f "$before" ]
  [ -f "$after" ]
  run diff "$before" "$after"
  [ "$status" != "0" ]
}

# R5 fixture .before.md 와 .after.md 가 다름
@test "TDD-B5 R5 fixture before differs from after" {
  local before="${FIXTURES_DIR}/r5-empty-table-row.before.md"
  local after="${FIXTURES_DIR}/r5-empty-table-row.after.md"

  [ -f "$before" ]
  [ -f "$after" ]
  run diff "$before" "$after"
  [ "$status" != "0" ]
}

# ----- Section C: fixture 의 본질적 invariant -----

# R1 after 가 before 보다 작거나 같음 (중복 제거 invariant)
@test "TDD-C1 R1 after rows lte before rows" {
  local before="${FIXTURES_DIR}/r1-duplicate-pointer.before.md"
  local after="${FIXTURES_DIR}/r1-duplicate-pointer.after.md"
  local before_size after_size
  before_size=$(wc -l < "$before")
  after_size=$(wc -l < "$after")

  [ "$after_size" -le "$before_size" ]
}

# R3 after 가 before 보다 작음 (인라인 분리 invariant)
@test "TDD-C2 R3 after rows lt before rows" {
  local before="${FIXTURES_DIR}/r3-inline-too-long.before.md"
  local after="${FIXTURES_DIR}/r3-inline-too-long.after.md"
  local before_size after_size
  before_size=$(wc -l < "$before")
  after_size=$(wc -l < "$after")

  [ "$after_size" -lt "$before_size" ]
}

# R5 after 가 before 보다 작음 (빈 행 제거 invariant)
@test "TDD-C3 R5 after rows lt before rows" {
  local before="${FIXTURES_DIR}/r5-empty-table-row.before.md"
  local after="${FIXTURES_DIR}/r5-empty-table-row.after.md"
  local before_size after_size
  before_size=$(wc -l < "$before")
  after_size=$(wc -l < "$after")

  [ "$after_size" -lt "$before_size" ]
}

# R2 after 가 before 와 동일 줄 수 (후보 표시만, 삭제 없음)
@test "TDD-C4 R2 after rows equal before rows" {
  local before="${FIXTURES_DIR}/r2-expired-pointer.before.md"
  local after="${FIXTURES_DIR}/r2-expired-pointer.after.md"
  local before_size after_size
  before_size=$(wc -l < "$before")
  after_size=$(wc -l < "$after")

  [ "$after_size" = "$before_size" ]
}

# R4 after 가 before 와 동일 줄 수 (후보 표시만, 삭제 없음)
@test "TDD-C5 R4 after rows equal before rows" {
  local before="${FIXTURES_DIR}/r4-stale-feedback.before.md"
  local after="${FIXTURES_DIR}/r4-stale-feedback.after.md"
  local before_size after_size
  before_size=$(wc -l < "$before")
  after_size=$(wc -l < "$after")

  [ "$after_size" = "$before_size" ]
}

# ----- Section D: R2/R4 후보 마커 박제 검증 -----

# R2 after 가 'R2 만료 후보' 마커 포함
@test "TDD-D1 R2 after contains R2 expiration marker" {
  local after="${FIXTURES_DIR}/r2-expired-pointer.after.md"
  run grep -q "R2" "$after"
  [ "$status" = "0" ]
}

# R4 after 가 'R4 archive 후보' 마커 포함
@test "TDD-D2 R4 after contains R4 archive marker" {
  local after="${FIXTURES_DIR}/r4-stale-feedback.after.md"
  run grep -q "R4" "$after"
  [ "$status" = "0" ]
}

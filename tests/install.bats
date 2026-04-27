#!/usr/bin/env bats
# install.bats - Regression tests for install.sh function units
# Run: bats tests/install.bats

setup() {
  SKILL_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  TMP_DIR="$(mktemp -d -t memory-health-test.XXXXXX)"

  # source under set+e to avoid early exits during sourcing
  set +e
  source "${SKILL_DIR}/install.sh"
  set -e
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# ----- detect_memory_dir -----

@test "detect_memory_dir returns path from stdin redirect" {
  # Isolate from real environment: HOME=TMP_DIR so methods A/B fail and method C (read) is reached
  result=$(HOME="${TMP_DIR}" bash -c "
    set +e
    source '${SKILL_DIR}/install.sh'
    set -e
    echo '${TMP_DIR}/fake-memory' | detect_memory_dir 2>/dev/null
  ")
  [ "$result" = "${TMP_DIR}/fake-memory" ]
}

# ----- update_shell_rc -----

@test "update_shell_rc appends export when given explicit rc file" {
  local rc="${TMP_DIR}/test.zshrc"
  touch "$rc"
  update_shell_rc "/test/memory" "$rc" >/dev/null
  grep -q "CLAUDE_MEMORY_DIR" "$rc"
  grep -q '"/test/memory"' "$rc"
}

@test "update_shell_rc skips duplicate when already present" {
  local rc="${TMP_DIR}/test.zshrc"
  echo 'export CLAUDE_MEMORY_DIR="/old/path"' > "$rc"
  update_shell_rc "/new/path" "$rc" >/dev/null
  local count
  count=$(grep -c "CLAUDE_MEMORY_DIR" "$rc")
  [ "$count" = "1" ]
}

@test "update_shell_rc prints manual instructions when no rc found" {
  result=$(HOME="${TMP_DIR}" update_shell_rc "/test/memory" 2>&1)
  [[ "$result" == *"export CLAUDE_MEMORY_DIR"* ]]
}

# ----- create_required_files -----

@test "create_required_files creates violation-archive and skill-audit" {
  create_required_files "${TMP_DIR}" >/dev/null
  [ -f "${TMP_DIR}/violation-archive.md" ]
  [ -f "${TMP_DIR}/skill-audit.log" ]
}

# ----- copy_rules_template -----

@test "copy_rules_template copies template when destination absent" {
  local mock_skill_dir="${TMP_DIR}/skill"
  local mock_memory_dir="${TMP_DIR}/memory"
  mkdir -p "$mock_skill_dir" "$mock_memory_dir"
  echo "test rules" > "${mock_skill_dir}/memory-health-rules.md"

  copy_rules_template "$mock_memory_dir" "$mock_skill_dir" >/dev/null

  [ -f "${mock_memory_dir}/memory-health-rules.md" ]
  grep -q "test rules" "${mock_memory_dir}/memory-health-rules.md"
}

@test "copy_rules_template preserves existing destination file" {
  local mock_skill_dir="${TMP_DIR}/skill"
  local mock_memory_dir="${TMP_DIR}/memory"
  mkdir -p "$mock_skill_dir" "$mock_memory_dir"
  echo "new template" > "${mock_skill_dir}/memory-health-rules.md"
  echo "existing content" > "${mock_memory_dir}/memory-health-rules.md"

  copy_rules_template "$mock_memory_dir" "$mock_skill_dir" >/dev/null

  grep -q "existing content" "${mock_memory_dir}/memory-health-rules.md"
  ! grep -q "new template" "${mock_memory_dir}/memory-health-rules.md"
}

@test "copy_rules_template silent when template absent" {
  local mock_skill_dir="${TMP_DIR}/skill-no-template"
  local mock_memory_dir="${TMP_DIR}/memory"
  mkdir -p "$mock_skill_dir" "$mock_memory_dir"

  run copy_rules_template "$mock_memory_dir" "$mock_skill_dir"
  [ "$status" = "0" ]
  [ -z "$output" ]
}

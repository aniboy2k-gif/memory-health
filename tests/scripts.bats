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

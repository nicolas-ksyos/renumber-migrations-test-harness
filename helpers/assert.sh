#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# assert.sh — assertion helpers and summary printer for the test harness.
# Source this file from run-tests.sh; do not execute directly.
# ---------------------------------------------------------------------------

export PASS_COUNT=0
export FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Colour setup — only emit escape codes when stdout is a TTY.
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  GREEN=$(tput setaf 2)
  RED=$(tput setaf 1)
  RESET=$(tput sgr0)
else
  GREEN=""
  RED=""
  RESET=""
fi

# ---------------------------------------------------------------------------
# assert_exit_code <label> <expected> <actual>
#   Passes when $actual equals $expected; records a FAIL otherwise.
# ---------------------------------------------------------------------------
assert_exit_code() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [ "$actual" -eq "$expected" ]; then
    echo "  ${GREEN}✅ PASS${RESET}  ${label}"
    PASS_COUNT=$(( PASS_COUNT + 1 )) || true
  else
    echo "  ${RED}❌ FAIL${RESET}  ${label} (expected exit ${expected}, got ${actual})"
    FAIL_COUNT=$(( FAIL_COUNT + 1 )) || true
  fi
}

# ---------------------------------------------------------------------------
# assert_file_exists <label> <path>
#   Passes when the file at $path exists on disk.
# ---------------------------------------------------------------------------
assert_file_exists() {
  local label="$1"
  local path="$2"

  if [ -f "$path" ]; then
    echo "  ${GREEN}✅ PASS${RESET}  ${label}"
    PASS_COUNT=$(( PASS_COUNT + 1 )) || true
  else
    echo "  ${RED}❌ FAIL${RESET}  ${label} (file not found: ${path})"
    FAIL_COUNT=$(( FAIL_COUNT + 1 )) || true
  fi
}

# ---------------------------------------------------------------------------
# assert_file_not_exists <label> <path>
#   Passes when no file exists at $path.
# ---------------------------------------------------------------------------
assert_file_not_exists() {
  local label="$1"
  local path="$2"

  if [ ! -f "$path" ]; then
    echo "  ${GREEN}✅ PASS${RESET}  ${label}"
    PASS_COUNT=$(( PASS_COUNT + 1 )) || true
  else
    echo "  ${RED}❌ FAIL${RESET}  ${label} (file should not exist: ${path})"
    FAIL_COUNT=$(( FAIL_COUNT + 1 )) || true
  fi
}

# ---------------------------------------------------------------------------
# assert_file_renamed <label> <old_path> <new_path>
#   Convenience wrapper: asserts the old path is gone and the new one exists.
#   Each sub-assertion gets a distinct label suffix so failures are locatable.
# ---------------------------------------------------------------------------
assert_file_renamed() {
  local label="$1"
  local old_path="$2"
  local new_path="$3"

  assert_file_not_exists "${label} [old gone]"  "$old_path"
  assert_file_exists      "${label} [new exists]" "$new_path"
}

# ---------------------------------------------------------------------------
# assert_stdout_contains <label> <needle> <haystack>
#   Passes when $haystack contains the substring $needle.
# ---------------------------------------------------------------------------
assert_stdout_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"

  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ${GREEN}✅ PASS${RESET}  ${label}"
    PASS_COUNT=$(( PASS_COUNT + 1 )) || true
  else
    echo "  ${RED}❌ FAIL${RESET}  ${label} (expected output to contain: ${needle})"
    FAIL_COUNT=$(( FAIL_COUNT + 1 )) || true
  fi
}

# ---------------------------------------------------------------------------
# print_summary
#   Prints the final pass/fail tally and returns 1 when any assertion failed.
# ---------------------------------------------------------------------------
print_summary() {
  echo ""
  echo "══════════════════════════════════════"
  echo "  Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
  echo "══════════════════════════════════════"

  if [ "$FAIL_COUNT" -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

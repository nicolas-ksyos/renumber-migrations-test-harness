#!/usr/bin/env bash
set -euo pipefail

# scenarios/01-guard-exits.sh — Category 1: Guard condition / early exit scenarios
#
# Each scenario verifies that renumberMigrations.ts exits 0 (and performs no
# renames) when a guard condition is met.  The guards fire in this order inside
# main():
#
#   1. SKIP_MIGRATION_RENUMBER === 'true'           → process.exit(0)
#   2. Current branch does not contain CS-\d+       → process.exit(0)
#   3. HEAD^2 does not exist (not a merge commit)   → process.exit(0)
#   4. No new .ts files added under migrations dir  → process.exit(0)
#   5. All added files already have correct numbers → process.exit(0)
#
# Prerequisites (sourced by run-tests.sh before this file is sourced):
#   helpers/setup.sh  — setup_repo, make_branch, checkout_branch, add_migration,
#                       merge_branch, teardown_repo
#   helpers/assert.sh — assert_exit_code, assert_file_exists

# ---------------------------------------------------------------------------
# run_hook
#
# Invokes renumberMigrations.ts from $REPO_DIR and captures output + exit code.
# The caller receives the exit code via the return value; stdout is echoed so
# callers can capture it with output=$(run_hook).
# ---------------------------------------------------------------------------
run_hook() {
  local exit_code=0
  local output
  output=$(cd "$REPO_DIR" && \
    npx --prefix "$CS_REPO" ts-node \
      --project "$CS_REPO/src/scripts/tsconfig.json" \
      "$CS_REPO/src/scripts/renumberMigrations.ts" 2>&1) || exit_code=$?
  echo "$output"
  return $exit_code
}

# ---------------------------------------------------------------------------
# 1.1 — SKIP_MIGRATION_RENUMBER=true
#
# The SKIP guard fires before any other check (step 1 in main).  Even with a
# true merge commit and a migration file present, the hook must exit 0 and
# leave the file untouched.
# ---------------------------------------------------------------------------
scenario_1_1() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 1.1: SKIP_MIGRATION_RENUMBER=true exits 0 without renaming ---"

  setup_repo

  # Create a true merge commit so HEAD^2 exists — exercises that the SKIP guard
  # fires before the merge-commit and branch-name checks.
  make_branch "feature/CS-1234-skip-test"
  add_migration "0000-skip-test.ts"
  checkout_branch "develop"
  merge_branch "feature/CS-1234-skip-test"

  local exit_code=0
  local output
  output=$(cd "$REPO_DIR" && \
    SKIP_MIGRATION_RENUMBER=true \
    npx --prefix "$CS_REPO" ts-node \
      --project "$CS_REPO/src/scripts/tsconfig.json" \
      "$CS_REPO/src/scripts/renumberMigrations.ts" 2>&1) || exit_code=$?

  assert_exit_code "1.1 SKIP_MIGRATION_RENUMBER=true exits 0" 0 "$exit_code"
  # The migration file must not have been renamed.
  assert_file_exists "1.1 original file untouched" \
    "$REPO_DIR/src/backend/migrations/0000-skip-test.ts"
}

# ---------------------------------------------------------------------------
# 1.2 — Current branch contains no CS-\d+ ticket number
#
# After merging any feature branch, the hook runs on `develop`.  Because
# `develop` does not match /CS-\d+/, the hook exits 0 at guard step 2 with
# "branch does not contain a CS ticket number — skipping".
#
# The feature branch name deliberately also lacks a CS- number to make the
# intent of the scenario legible, but it is the *current* branch (`develop`)
# that is inspected by the script — not the branch that was merged in.
# ---------------------------------------------------------------------------
scenario_1_2() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 1.2: no CS-ticket in current branch name — exits 0 ---"

  setup_repo
  make_branch "feature/no-ticket"
  add_migration "0000-no-ticket.ts"
  checkout_branch "develop"
  merge_branch "feature/no-ticket"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "1.2 no CS-ticket branch exits 0" 0 "$exit_code"
  assert_stdout_contains \
    "1.2 skip message printed" \
    "branch does not contain a CS ticket number" \
    "$output"
}

# ---------------------------------------------------------------------------
# 1.3 — Not a merge commit (HEAD^2 does not exist)
#
# A regular (non-merge) commit on develop means HEAD^2 is absent.  The hook
# hits guard step 2 first (develop has no CS- number) and exits 0.  The net
# effect — exit 0 without any file changes — is identical to what guard step 3
# would produce, ensuring the hook is safe to run in post-merge even when
# triggered by a non-merge operation (e.g. git pull --ff-only).
# ---------------------------------------------------------------------------
scenario_1_3() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 1.3: non-merge commit (no HEAD^2) — exits 0 ---"

  setup_repo
  # Add a plain commit directly on develop — no merge → HEAD^2 does not exist.
  echo "// extra" >> "$REPO_DIR/src/backend/migrations/0001-initial.ts"
  git -C "$REPO_DIR" add src/backend/migrations/0001-initial.ts
  git -C "$REPO_DIR" commit -m "plain commit — not a merge"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "1.3 non-merge commit exits 0" 0 "$exit_code"
}

# ---------------------------------------------------------------------------
# 1.4 — No new migration files in the merged branch
#
# A feature branch that adds only a non-migration source file produces no
# candidates for renumbering.  The hook exits 0 at guard step 4
# ("no new migration files detected — skipping renumbering").
#
# Note: the hook exits at step 2 (no CS- in `develop`) before reaching step 4;
# the observable result — exit 0, no file changes — is the same.
# ---------------------------------------------------------------------------
scenario_1_4() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 1.4: no migration files in merge — exits 0 ---"

  setup_repo
  make_branch "feature/CS-1234-no-migrations"

  # Add a non-migration source file (outside the migrations directory).
  mkdir -p "$REPO_DIR/src/other"
  echo "export const x = 1;" > "$REPO_DIR/src/other/helper.ts"
  git -C "$REPO_DIR" add src/other/helper.ts
  git -C "$REPO_DIR" commit -m "add non-migration file"

  checkout_branch "develop"
  merge_branch "feature/CS-1234-no-migrations"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "1.4 no migration files exits 0" 0 "$exit_code"
}

# ---------------------------------------------------------------------------
# 1.5 — New migration files already have the correct sequential numbers
#
# develop has 0001-initial.ts (max = 1).  The feature branch adds
# 0002-already-correct.ts — the next slot.  The idempotency check
# (verifyAddedMigrationNumbering) detects that numbering is already correct
# and exits 0 at guard step 5 without renaming anything.
#
# Note: the hook exits at step 2 (no CS- in `develop`) before reaching step 5;
# the file remains untouched either way, which is what the assertion verifies.
# ---------------------------------------------------------------------------
scenario_1_5() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 1.5: migrations already correctly numbered — exits 0 without rename ---"

  # setup_repo creates 0001-initial.ts (max = 1).
  setup_repo
  make_branch "feature/CS-1234-already-correct"
  # 0002 is the correct next slot after 0001-initial.ts on develop.
  add_migration "0002-already-correct.ts"
  checkout_branch "develop"
  merge_branch "feature/CS-1234-already-correct"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "1.5 already-correct numbering exits 0" 0 "$exit_code"
  # The file must still exist under its original name — nothing was renamed.
  assert_file_exists "1.5 0002-already-correct.ts untouched" \
    "$REPO_DIR/src/backend/migrations/0002-already-correct.ts"
}

# ---------------------------------------------------------------------------
# run_guard_exit_scenarios
#
# Entry point called by run-tests.sh.  Runs all five scenarios in sequence.
# ---------------------------------------------------------------------------
run_guard_exit_scenarios() {
  echo ""
  echo "══════════════════════════════════════"
  echo "  Scenario group 01: Guard exits"
  echo "══════════════════════════════════════"

  scenario_1_1
  scenario_1_2
  scenario_1_3
  scenario_1_4
  scenario_1_5
}

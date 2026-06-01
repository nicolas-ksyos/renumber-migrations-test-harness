#!/usr/bin/env bash
set -euo pipefail

# Scenario group 04: Merge strategies
#
# Verifies that the hook behaves correctly regardless of the SOURCE branch type
# (master, release/*, feature/CS-*) being merged into the destination.
#
# ── CS-ticket guard — why 4.1 and 4.2 are no-ops ────────────────────────────
# renumberMigrations.ts main() step [2] (line ~302):
#
#   if (!/CS-\d+/.test(branch)) {
#     console.log('post-merge: branch does not contain a CS ticket number — skipping');
#     process.exit(0);
#   }
#
# `branch` is the CURRENT branch at hook invocation — i.e. the DESTINATION of
# the merge, NOT the source branch.  When merging anything into `develop`,
# `develop` fails the CS-\d+ test and the hook exits 0 immediately without
# touching any files.
#
# Consequence:
#   4.1  master   → develop  : CS guard fires on "develop"  → exit 0, no rename
#   4.2  release/* → develop : CS guard fires on "develop"  → exit 0, no rename
#   4.3  feature/CS-* → feature/CS-* : destination HAS a CS ticket → rename runs
#
# 4.3 therefore uses `feature/CS-9998-base` as the merge DESTINATION to
# exercise the actual rename path — matching the "or another feature branch"
# note in the scenario specification.
#
# Prerequisites (sourced by the caller, run-tests.sh):
#   helpers/setup.sh   — setup_repo, make_branch, checkout_branch, add_migration,
#                        merge_branch, teardown_repo
#   helpers/assert.sh  — assert_exit_code, assert_file_exists,
#                        assert_file_not_exists, assert_file_renamed

# ---------------------------------------------------------------------------
# run_hook
#
# Invokes renumberMigrations.ts from $REPO_DIR and captures output + exit code.
# The caller receives the exit code via the return value; stdout is printed so
# callers can inspect it with `output=$(run_hook)`.
# ---------------------------------------------------------------------------
run_hook() {
  local exit_code=0
  local output
  output=$(cd "$REPO_DIR" && \
    npx --prefix "$KEEP_ORDER_ROOT" ts-node \
      --project "$KEEP_ORDER_ROOT/src/scripts/tsconfig.json" \
      "$KEEP_ORDER_ROOT/src/scripts/renumberMigrations.ts" 2>&1) || exit_code=$?
  echo "$output"
  return $exit_code
}

# ---------------------------------------------------------------------------
# 4.1 — master → develop local merge (no-op: CS guard fires on "develop")
#
# A migration committed on `master` is merged into `develop`.  The hook runs
# on `develop`, which contains no CS-\d+ ticket number.  The CS guard at
# main() step [2] fires immediately → exit 0, file left untouched.
# ---------------------------------------------------------------------------
scenario_4_1() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 4.1: master→develop — CS guard fires on develop, no rename ---"

  setup_repo

  # Add a migration on master with a deliberately wrong (0000) number.
  make_branch "master"
  add_migration "0000-from-master.ts"

  checkout_branch "develop"
  merge_branch "master"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  # develop has no CS-\d+ ticket → hook skips at step [2] → exit 0
  assert_exit_code "4.1 master→develop exits 0" 0 "$exit_code"

  # File must NOT have been renamed — the hook did not run the rename logic
  assert_file_exists \
    "4.1 0000-from-master.ts still present (no rename)" \
    "$REPO_DIR/src/backend/migrations/0000-from-master.ts"

  assert_stdout_contains \
    "4.1 output explains skip reason" \
    "branch does not contain a CS ticket number" \
    "$output"
}

# ---------------------------------------------------------------------------
# 4.2 — release/* → develop local merge (no-op: CS guard fires on "develop")
#
# Same guard as 4.1.  A release branch carries a migration; after merging into
# `develop` the hook exits 0 without renaming because the destination branch
# ("develop") lacks a CS ticket.
# ---------------------------------------------------------------------------
scenario_4_2() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 4.2: release/1.0.0→develop — CS guard fires on develop, no rename ---"

  setup_repo

  make_branch "release/1.0.0"
  add_migration "0000-from-release.ts"

  checkout_branch "develop"
  merge_branch "release/1.0.0"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  # develop has no CS-\d+ ticket → hook skips at step [2] → exit 0
  assert_exit_code "4.2 release→develop exits 0" 0 "$exit_code"

  # File must NOT have been renamed
  assert_file_exists \
    "4.2 0000-from-release.ts still present (no rename)" \
    "$REPO_DIR/src/backend/migrations/0000-from-release.ts"

  assert_stdout_contains \
    "4.2 output explains skip reason" \
    "branch does not contain a CS ticket number" \
    "$output"
}

# ---------------------------------------------------------------------------
# 4.3 — feature/CS-* → feature/CS-* local merge (rename executes)
#
# Destination branch IS a CS-ticket branch, so the CS guard passes.
# This is the "standard case" referenced in the spec: the scenario exercises
# the full rename path with a feature/CS-* SOURCE branch.
#
# Topology:
#   develop        : 0001-initial.ts
#   feature/CS-9999-standard (source) : adds 0000-standard-feature.ts
#   feature/CS-9998-base (destination): merges the source branch
#
# After merge, develop's max is still 0001-initial.ts (the added file is
# excluded from the max computation).  The hook must rename
#   0000-standard-feature.ts → 0002-standard-feature.ts
# ---------------------------------------------------------------------------
scenario_4_3() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 4.3: feature/CS-9999→feature/CS-9998 — migration renumbered ---"

  setup_repo

  # Source branch: carries the new migration with a placeholder number.
  make_branch "feature/CS-9999-standard"
  add_migration "0000-standard-feature.ts"

  # Destination branch: branch off develop (no extra migrations — max stays at 0001).
  checkout_branch "develop"
  make_branch "feature/CS-9998-base"

  # Merge the source feature branch into the CS-ticket destination.
  merge_branch "feature/CS-9999-standard"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  # feature/CS-9998-base passes the CS-\d+ guard → hook runs fully → exit 0
  assert_exit_code "4.3 feature→feature exits 0" 0 "$exit_code"

  # 0000-standard-feature.ts must be renumbered to 0002 (develop max is 0001)
  assert_file_renamed "4.3 migration renumbered from feature/CS-9999 merge" \
    "$REPO_DIR/src/backend/migrations/0000-standard-feature.ts" \
    "$REPO_DIR/src/backend/migrations/0002-standard-feature.ts"
}

# ---------------------------------------------------------------------------
# run_merge_strategy_scenarios
#
# Entry point called by run-tests.sh.  Runs all three scenarios in sequence.
# ---------------------------------------------------------------------------
run_merge_strategy_scenarios() {
  echo ""
  echo "══════════════════════════════════════"
  echo "  Scenario group 04: Merge strategies"
  echo "══════════════════════════════════════"

  scenario_4_1
  scenario_4_2
  scenario_4_3
}

#!/usr/bin/env bash
set -euo pipefail

# Scenario group 02: Renumber logic
#
# Verifies that renumberMigrations.ts correctly assigns sequential migration
# numbers in a variety of realistic merge topologies.
#
# Prerequisites (sourced by the caller, run-tests.sh):
#   helpers/setup.sh   — setup_repo, make_branch, checkout_branch, add_migration,
#                        advance_develop, merge_branch, teardown_repo
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
    npx --prefix "$CS_REPO" ts-node \
      --project "$CS_REPO/src/scripts/tsconfig.json" \
      "$CS_REPO/src/scripts/renumberMigrations.ts" 2>&1) || exit_code=$?
  echo "$output"
  return $exit_code
}

# ---------------------------------------------------------------------------
# 2.1 — Single new migration behind develop
#
# develop has 100 migrations (0001-initial + 99 advance).
# Feature branch adds 0000-foo.ts (deliberately wrong number).
# After merge the hook must rename it to 0101-foo.ts.
# ---------------------------------------------------------------------------
scenario_2_1() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 2.1: single migration renumbered to next slot after develop ---"

  setup_repo
  # develop already has 0001-initial.ts; add 99 more → top is 0100-advance.ts
  advance_develop 99

  make_branch "feature/CS-1234-foo"
  add_migration "0000-foo.ts"

  checkout_branch "develop"
  echo "build" > .build-marker && git add .build-marker && git commit -m "ci: dummy build marker"
  checkout_branch "feature/CS-1234-foo"
  merge_branch "develop"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "2.1 exits 0" 0 "$exit_code"
  assert_file_renamed "2.1 renamed to 0101-foo.ts" \
    "$REPO_DIR/src/backend/migrations/0000-foo.ts" \
    "$REPO_DIR/src/backend/migrations/0101-foo.ts"
}

# ---------------------------------------------------------------------------
# 2.2 — Multiple migrations sorted by commit timestamp
#
# Three migrations are committed 10 minutes apart.  The hook must assign
# sequential numbers in commit-timestamp order (oldest first):
#   0000-c.ts (T+0)  → 0002-c.ts
#   0000-a.ts (T+10) → 0003-a.ts
#   0000-b.ts (T+20) → 0004-b.ts
# ---------------------------------------------------------------------------
scenario_2_2() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 2.2: multiple migrations ordered by commit timestamp ---"

  setup_repo
  make_branch "feature/CS-1234-multi"

  # Commit three migrations with explicit, ascending timestamps.
  add_migration "0000-c.ts" "export {};" "@1000000000"
  add_migration "0000-a.ts" "export {};" "@1000000600"   # +10 min
  add_migration "0000-b.ts" "export {};" "@1000001200"   # +20 min

  checkout_branch "develop"
  echo "build" > .build-marker && git add .build-marker && git commit -m "ci: dummy build marker"
  checkout_branch "feature/CS-1234-multi"
  merge_branch "develop"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "2.2 exits 0" 0 "$exit_code"

  # Oldest commit (c) → first slot after develop's max (0001) → 0002
  assert_file_renamed "2.2 first committed (c) → 0002-c.ts" \
    "$REPO_DIR/src/backend/migrations/0000-c.ts" \
    "$REPO_DIR/src/backend/migrations/0002-c.ts"

  assert_file_renamed "2.2 second committed (a) → 0003-a.ts" \
    "$REPO_DIR/src/backend/migrations/0000-a.ts" \
    "$REPO_DIR/src/backend/migrations/0003-a.ts"

  assert_file_renamed "2.2 third committed (b) → 0004-b.ts" \
    "$REPO_DIR/src/backend/migrations/0000-b.ts" \
    "$REPO_DIR/src/backend/migrations/0004-b.ts"
}

# ---------------------------------------------------------------------------
# 2.3 — Feature branch behind develop
#
# develop is at 0100 when the feature branch is created, then advances to 0105
# before the merge.  The migration added at 0101 on the feature branch must be
# renumbered to 0106 (max+1 at merge time).
# ---------------------------------------------------------------------------
scenario_2_3() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 2.3: feature branch behind develop — renumbered to current max+1 ---"

  setup_repo
  # develop: 0001-initial + 99 → top is 0100-advance.ts
  advance_develop 99

  make_branch "feature/CS-1234-behind"

  checkout_branch "develop"
  # develop advances 5 more → top is now 0105-advance.ts
  # Add 5 develop migrations with explicit, ascending timestamps
  add_migration "0101-develop-ahead-1.ts" "export {};" "@2000000000"
  add_migration "0102-develop-ahead-2.ts" "export {};" "@2000000060"
  add_migration "0103-develop-ahead-3.ts" "export {};" "@2000000120"
  add_migration "0104-develop-ahead-4.ts" "export {};" "@2000000180"
  add_migration "0105-develop-ahead-5.ts" "export {};" "@2000000240"

  # Return to feature and add the migration — bar gets a timestamp clearly
  # AFTER all advance files so it sorts last and lands at slot 0106.
  checkout_branch "feature/CS-1234-behind"
  add_migration "0000-bar.ts" "export {};" "@2000001000"

  merge_branch "develop"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "2.3 exits 0" 0 "$exit_code"
  assert_file_renamed "2.3 renumbered to 0106-bar.ts" \
    "$REPO_DIR/src/backend/migrations/0000-bar.ts" \
    "$REPO_DIR/src/backend/migrations/0106-bar.ts"
}

# ---------------------------------------------------------------------------
# 2.4 — Feature-into-feature merge
#
# Branch A and branch B each add a migration.  A merges B directly (without
# going through develop first).  Both 0000-a.ts and 0000-b.ts must be
# renumbered to 0002 and 0003 (develop only has 0001-initial.ts).
# ---------------------------------------------------------------------------
scenario_2_4() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 2.4: feature-into-feature merge — both migrations renumbered ---"

  setup_repo

  make_branch "feature/CS-1234-A"
  add_migration "0000-a.ts"

  checkout_branch "develop"
  make_branch "feature/CS-5678-B"
  add_migration "0000-b.ts"

  # Merge B into A — the hook runs on A's post-merge state
  checkout_branch "feature/CS-1234-A"
  merge_branch "feature/CS-5678-B"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "2.4 exits 0" 0 "$exit_code"

  # Original 0000-*.ts files must no longer exist
  assert_file_not_exists "2.4 0000-a.ts gone" "$REPO_DIR/src/backend/migrations/0000-a.ts"
  assert_file_not_exists "2.4 0000-b.ts gone" "$REPO_DIR/src/backend/migrations/0000-b.ts"

  # Exactly the two renumbered files must be present
  assert_file_exists "2.4 0002-a.ts exists" "$REPO_DIR/src/backend/migrations/0002-a.ts"
  assert_file_exists "2.4 0003-b.ts exists" "$REPO_DIR/src/backend/migrations/0003-b.ts"
}

# ---------------------------------------------------------------------------
# 2.5 — Non-.ts files in the migrations directory are skipped
#
# A README.md committed alongside a migration must be left untouched; only
# the .ts migration file should be renumbered.
# ---------------------------------------------------------------------------
scenario_2_5() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 2.5: non-.ts files in migrations dir are skipped ---"

  setup_repo
  make_branch "feature/CS-1234-mixed"

  add_migration "0000-mig.ts"

  # Add a non-.ts file in the same migrations directory on the feature branch
  echo "# readme" > "$REPO_DIR/src/backend/migrations/README.md"
  git -C "$REPO_DIR" add src/backend/migrations/README.md
  git -C "$REPO_DIR" commit -m "add README.md"

  checkout_branch "develop"
  echo "build" > "$REPO_DIR/.build-marker" && git -C "$REPO_DIR" add .build-marker && git -C "$REPO_DIR" commit -m "ci: dummy build marker"
  checkout_branch "feature/CS-1234-mixed"
  merge_branch "develop"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "2.5 exits 0" 0 "$exit_code"
  assert_file_renamed "2.5 .ts file renamed to 0002-mig.ts" \
    "$REPO_DIR/src/backend/migrations/0000-mig.ts" \
    "$REPO_DIR/src/backend/migrations/0002-mig.ts"
  assert_file_exists "2.5 README.md untouched" "$REPO_DIR/src/backend/migrations/README.md"
}

# ---------------------------------------------------------------------------
# run_renumber_logic_scenarios
#
# Entry point called by run-tests.sh.  Runs all five scenarios in sequence.
# ---------------------------------------------------------------------------
run_renumber_logic_scenarios() {
  echo ""
  echo "══════════════════════════════════════"
  echo "  Scenario group 02: Renumber logic"
  echo "══════════════════════════════════════"

  scenario_2_1
  scenario_2_2
  scenario_2_3
  scenario_2_4
  scenario_2_5
}

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
	output=$(cd "$REPO_DIR" &&
		npx --prefix "$CS_REPO" ts-node \
			--project "$CS_REPO/src/scripts/tsconfig.json" \
			"$CS_REPO/src/scripts/renumberMigrations.ts" 2>&1) || exit_code=$?
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
# 4.4 — develop→feature merge with conflicting migration numbers
#
# Regression test for the HEAD vs HEAD^1 bug in getFeatureBranchMigrationFiles().
#
# Before the fix, diffing mergeBase..HEAD returned files added by BOTH parents.
# This caused develop's migrations (already correctly numbered) to be misidentified
# as "feature branch additions" and renumbered — while the feature migration was
# left at its original (conflicting) number by coincidence.
#
# Topology:
#   develop:         0001-initial, 0002-develop-collision, 0003-develop-second
#   feature/CS-5678: 0002-feature-migration  (committed earlier — older timestamp)
#
# Expected (with fix: HEAD^1):
#   - Only 0002-feature-migration.ts is identified as the feature addition
#   - max = 0003 (develop's files count toward the baseline)
#   - 0002-feature-migration.ts renumbered to 0004
#   - develop's 0002 and 0003 files remain untouched
#
# With the bug (HEAD):
#   - All three added files are identified as feature additions
#   - max = 0001 (only initial counts)
#   - Sorted by timestamp: feature (oldest) → 0002, develop-first → 0003, develop-second → 0004
#   - Feature file coincidentally stays at 0002; develop's files are wrongly bumped
# ---------------------------------------------------------------------------
scenario_4_4() {
	trap 'teardown_repo 2>/dev/null || true' RETURN

	echo "--- 4.4: number collision after develop merge — only feature migration renumbered ---"

	setup_repo

	# Feature branch forks from develop's initial state and adds a migration
	# with the SAME number that develop will later add.  The older timestamp
	# means this file sorts first under the buggy behaviour, landing it at 0002
	# (no-op rename) while develop's files are wrongly bumped.
	make_branch "feature/CS-5678-collision"
	add_migration "0002-feature-migration.ts" "export {};" "@1000000000"

	# develop advances with two migrations that collide with / follow the
	# feature's file.  Both are committed AFTER the feature file.
	checkout_branch "develop"
	add_migration "0002-develop-collision.ts" "export {};" "@1000001000"
	add_migration "0003-develop-second.ts" "export {};" "@1000002000"

	# Merge develop into the feature branch — this is the post-merge hook trigger.
	checkout_branch "feature/CS-5678-collision"
	merge_branch "develop"

	local exit_code=0
	local output
	output=$(run_hook) || exit_code=$?

	# Hook must complete successfully.
	assert_exit_code "4.4 exits 0" 0 "$exit_code"

	# The feature migration must be renumbered to 0004 (develop max = 0003, so +1).
	assert_file_renamed "4.4 feature migration renumbered above develop's" \
		"$REPO_DIR/src/backend/migrations/0002-feature-migration.ts" \
		"$REPO_DIR/src/backend/migrations/0004-feature-migration.ts"

	# develop's files must be completely untouched.
	assert_file_exists "4.4 develop's 0002 untouched" \
		"$REPO_DIR/src/backend/migrations/0002-develop-collision.ts"
	assert_file_not_exists "4.4 develop's 0002 not wrongly bumped to 0003" \
		"$REPO_DIR/src/backend/migrations/0003-develop-collision.ts"

	assert_file_exists "4.4 develop's 0003 untouched" \
		"$REPO_DIR/src/backend/migrations/0003-develop-second.ts"
	assert_file_not_exists "4.4 develop's 0003 not wrongly bumped to 0004" \
		"$REPO_DIR/src/backend/migrations/0004-develop-second.ts"
}

# ---------------------------------------------------------------------------
# run_merge_strategy_scenarios
#
# Entry point called by run-tests.sh.  Runs all four scenarios in sequence.
# ---------------------------------------------------------------------------
run_merge_strategy_scenarios() {
	echo ""
	echo "══════════════════════════════════════"
	echo "  Scenario group 04: Merge strategies"
	echo "══════════════════════════════════════"

	scenario_4_1
	scenario_4_2
	scenario_4_3
	scenario_4_4
}

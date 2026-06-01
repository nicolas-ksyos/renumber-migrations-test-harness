#!/usr/bin/env bash
set -euo pipefail

# Scenario group 03: Edge cases
#
# Verifies that renumberMigrations.ts handles error conditions and boundary
# inputs correctly: conflict markers, absent remotes, missing git on PATH,
# git-mv failures with rollback, missing migration directory, and non-standard
# filenames being ignored during max-number calculation.
#
# Prerequisites (sourced by the caller, run-tests.sh):
#   helpers/setup.sh   — setup_repo, make_branch, checkout_branch, add_migration,
#                        advance_develop, merge_branch, teardown_repo
#   helpers/assert.sh  — assert_exit_code, assert_file_exists,
#                        assert_file_not_exists, assert_file_renamed,
#                        assert_stdout_contains

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
# 3.1 — Conflict markers in file → exit 1
#
# A migration file committed with unresolved git conflict markers must cause
# the hook to abort with exit 1. detectConflictMarkers() throws an error
# whose message contains "conflict", which propagates to the main() catch
# block and is printed to stderr (captured via 2>&1 in run_hook).
# ---------------------------------------------------------------------------
scenario_3_1() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 3.1: conflict markers in migration file → exit 1 ---"

  setup_repo
  make_branch "feature/CS-1234-conflict"

  # Write a file whose content contains unresolved git conflict markers.
  cat > src/backend/migrations/0000-conflict.ts << 'EOF'
<<<<<<< HEAD
export const up = () => {};
=======
export const up = () => { /* conflict */ };
>>>>>>> feature/CS-5678-other
EOF
  git add src/backend/migrations/0000-conflict.ts
  git commit -m "add conflicted migration"

  checkout_branch "develop"
  merge_branch "feature/CS-1234-conflict"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "3.1 conflict markers → exit 1" 1 "$exit_code"
  assert_stdout_contains "3.1 mentions conflict" "conflict" "$output"
}

# ---------------------------------------------------------------------------
# 3.2 — Stale local develop (local-only, no remote)
#
# The script must resolve the merge base using only local git state — no
# remote is configured. develop advances past the feature-branch fork point
# before the merge.
#
# Note on expected numbering: git diff --diff-filter=A mergeBase HEAD picks up
# ALL files added since the common ancestor, which includes BOTH 0000-stale.ts
# (from the feature branch) AND 0002-develop-extra.ts (added on develop after
# the fork). Both land in addedBasenames, so getMaxNumber sees only
# 0001-initial.ts → max = 1. After sorting by first-commit timestamp (or
# alphabetically as a tiebreak), stale.ts is ordered first → slot 0002, and
# develop-extra.ts is ordered second → slot 0003.
# ---------------------------------------------------------------------------
scenario_3_2() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 3.2: stale local develop without remote — proceeds correctly ---"

  setup_repo

  # Feature branch forks from the initial develop commit.
  make_branch "feature/CS-1234-stale"
  add_migration "0000-stale.ts"

  # develop advances after the fork — feature branch is now behind.
  checkout_branch "develop"
  add_migration "0002-develop-extra.ts"

  # No `git remote add` — script must not fail due to absent remote.
  merge_branch "feature/CS-1234-stale"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "3.2 stale local develop proceeds correctly" 0 "$exit_code"

  # Original 0000-stale.ts must be gone after renumbering.
  assert_file_not_exists "3.2 original 0000-stale.ts gone" \
    "$REPO_DIR/src/backend/migrations/0000-stale.ts"

  # stale is sorted first (oldest commit / lowest filename) → slot 0002.
  assert_file_exists "3.2 renamed to 0002-stale.ts" \
    "$REPO_DIR/src/backend/migrations/0002-stale.ts"

  # develop-extra is also captured in the diff and renumbered to slot 0003.
  assert_file_not_exists "3.2 original 0002-develop-extra.ts gone" \
    "$REPO_DIR/src/backend/migrations/0002-develop-extra.ts"
  assert_file_exists "3.2 develop-extra renumbered to 0003-develop-extra.ts" \
    "$REPO_DIR/src/backend/migrations/0003-develop-extra.ts"
}

# ---------------------------------------------------------------------------
# 3.3 — git not on PATH → exit 1
#
# resolveGitPath() is called at module load time (top-level const). When git
# cannot be found it throws synchronously, causing ts-node to exit non-zero
# before main() is even reached.
#
# Strategy: build a PATH that retains node and npx but excludes the directory
# that contains the git binary, so the hook cannot locate git.
# ---------------------------------------------------------------------------
scenario_3_3() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 3.3: git not on PATH → exit 1 ---"

  setup_repo
  make_branch "feature/CS-1234-no-git"
  add_migration "0000-no-git.ts"

  checkout_branch "develop"
  merge_branch "feature/CS-1234-no-git"

  # Remove the directory that holds git from PATH while keeping node/npx
  # accessible so ts-node can still be invoked.
  local git_dir
  git_dir="$(dirname "$(which git)")"
  local no_git_path
  no_git_path=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^${git_dir}$" | tr '\n' ':' | sed 's/:$//')

  local exit_code=0
  local output
  output=$(cd "$REPO_DIR" && \
    PATH="$no_git_path" npx --prefix "$KEEP_ORDER_ROOT" ts-node \
      --project "$KEEP_ORDER_ROOT/src/scripts/tsconfig.json" \
      "$KEEP_ORDER_ROOT/src/scripts/renumberMigrations.ts" 2>&1) || exit_code=$?

  assert_exit_code "3.3 no git on PATH → exit 1" 1 "$exit_code"
}

# ---------------------------------------------------------------------------
# 3.4 — git mv fails mid-process → rollback + exit 1
#
# A fake `git` wrapper intercepts `mv` subcommands and fails on the second
# call (count >= 2). With three migration files the execution order (descending
# target number) triggers:
#   call 1: mv 0000-third  → 0004-third   (count=1, succeeds)
#   call 2: mv 0000-second → 0003-second  (count=2, FAILS)
#   rollback call: mv 0004-third → 0000-third (count=3, also fails — logged,
#                                              not re-thrown, so rollback exits
#                                              but the original error propagates)
#
# The script catches the error, attempts rollback, then re-throws, landing in
# main()'s catch block → exit 1.
#
# The file that was never attempted (0000-first.ts, last in descending order)
# must still exist at its original path after the partial rollback.
# ---------------------------------------------------------------------------
scenario_3_4() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 3.4: git mv failure mid-process → rollback + exit 1 ---"

  setup_repo

  # Install a fake git wrapper into $REPO_DIR/bin/. The wrapper counts mv
  # invocations via a counter file and fails starting from the second call,
  # delegating all other subcommands (and the first mv) to the real git.
  mkdir -p "$REPO_DIR/bin"
  cat > "$REPO_DIR/bin/git" << 'FAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "mv" ]]; then
  COUNTER_FILE="$(dirname "$0")/mv_count"
  count=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  count=$(( count + 1 ))
  echo "$count" > "$COUNTER_FILE"
  if [ "$count" -ge 2 ]; then
    echo "fake git mv: simulated failure" >&2
    exit 1
  fi
fi
exec "$(which git)" "$@"
FAKE_EOF
  chmod +x "$REPO_DIR/bin/git"

  # Commit three migrations so there are at least 2 git mv calls.
  make_branch "feature/CS-1234-mvfail"
  add_migration "0000-first.ts"
  add_migration "0000-second.ts"
  add_migration "0000-third.ts"

  checkout_branch "develop"
  merge_branch "feature/CS-1234-mvfail"

  local exit_code=0
  local output
  output=$(cd "$REPO_DIR" && \
    PATH="$REPO_DIR/bin:$PATH" npx --prefix "$KEEP_ORDER_ROOT" ts-node \
      --project "$KEEP_ORDER_ROOT/src/scripts/tsconfig.json" \
      "$KEEP_ORDER_ROOT/src/scripts/renumberMigrations.ts" 2>&1) || exit_code=$?

  assert_exit_code "3.4 git mv failure → exit 1" 1 "$exit_code"

  # 0000-first.ts was last in descending execution order (target 0002) and was
  # never attempted — it must still exist at its original path.
  assert_file_exists "3.4 first file not partially renamed" \
    "$REPO_DIR/src/backend/migrations/0000-first.ts"
}

# ---------------------------------------------------------------------------
# 3.5 — Migration directory missing → exit 1
#
# getMaxNumber() throws when MIGRATION_DIR does not exist on disk. The error
# message contains "does not exist", which is captured by main()'s catch block
# and printed to stderr.
# ---------------------------------------------------------------------------
scenario_3_5() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 3.5: missing migration directory → exit 1 ---"

  setup_repo
  make_branch "feature/CS-1234-nodir"
  add_migration "0000-test.ts"

  checkout_branch "develop"
  merge_branch "feature/CS-1234-nodir"

  # Remove the migrations directory entirely before running the hook.
  rm -rf "$REPO_DIR/src/backend/migrations"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "3.5 missing migration dir → exit 1" 1 "$exit_code"
  assert_stdout_contains "3.5 error mentions 'does not exist'" "does not exist" "$output"
}

# ---------------------------------------------------------------------------
# 3.6 — Non-standard filenames ignored in max-number calculation
#
# getMaxNumber() only considers files whose first four characters match /^\d{4}/.
# .DS_Store (no .ts extension, filtered before the numeric check) and
# _draft-wip.ts (starts with '_', fails the numeric check) must not affect the
# computed max — they are treated as non-participants by both getMaxNumber and
# renumberAddedMigrations (the "skip non-standard" guard in the rename loop).
#
# With only 0001-initial.ts counting toward max, the feature migration
# 0000-real.ts must be renumbered to 0002-real.ts.
# ---------------------------------------------------------------------------
scenario_3_6() {
  trap 'teardown_repo 2>/dev/null || true' RETURN

  echo "--- 3.6: non-standard filenames ignored in max-number calculation ---"

  setup_repo
  make_branch "feature/CS-1234-nonstandard"

  add_migration "0000-real.ts"

  # Add non-standard files that must not influence the migration counter.
  touch src/backend/migrations/.DS_Store
  echo "" > src/backend/migrations/_draft-wip.ts
  git add src/backend/migrations/.DS_Store src/backend/migrations/_draft-wip.ts
  git commit -m "add non-standard files"

  checkout_branch "develop"
  merge_branch "feature/CS-1234-nonstandard"

  local exit_code=0
  local output
  output=$(run_hook) || exit_code=$?

  assert_exit_code "3.6 exits 0" 0 "$exit_code"

  # Only 0001-initial.ts counts toward max (non-standard files are excluded).
  # 0000-real.ts must be renumbered to 0002-real.ts.
  assert_file_renamed "3.6 real migration renumbered to 0002" \
    "$REPO_DIR/src/backend/migrations/0000-real.ts" \
    "$REPO_DIR/src/backend/migrations/0002-real.ts"

  # Non-standard files must remain untouched.
  assert_file_exists "3.6 _draft-wip.ts untouched" \
    "$REPO_DIR/src/backend/migrations/_draft-wip.ts"
}

# ---------------------------------------------------------------------------
# run_edge_case_scenarios
#
# Entry point called by run-tests.sh. Runs all six edge-case scenarios.
# ---------------------------------------------------------------------------
run_edge_case_scenarios() {
  echo ""
  echo "══════════════════════════════════════"
  echo "  Scenario group 03: Edge cases"
  echo "══════════════════════════════════════"

  scenario_3_1
  scenario_3_2
  scenario_3_3
  scenario_3_4
  scenario_3_5
  scenario_3_6
}

#!/usr/bin/env bash
set -euo pipefail

# Shared git repo bootstrapping utilities for test scenarios.
# Source this file at the top of each scenario script.
# All functions assume they are called from within $REPO_DIR.

export REPO_DIR

# ---------------------------------------------------------------------------
# setup_repo
#
# Creates a fresh isolated temp git repository with an initial migration
# commit on the `develop` branch. Sets REPO_DIR and cd's into it.
# ---------------------------------------------------------------------------
setup_repo() {
  REPO_DIR=$(mktemp -d)
  cd "$REPO_DIR"

  # git init -b requires Git >= 2.28. Detect support and fall back gracefully.
  if git init -b develop . &>/dev/null; then
    : # supported
  else
    git init .
    git checkout -b develop
  fi

  git config user.email "test@test.com"
  git config user.name "Test User"

  mkdir -p src/backend/migrations
  echo "export {};" > src/backend/migrations/0001-initial.ts

  git add .
  git commit -m "initial commit"
}

# ---------------------------------------------------------------------------
# make_branch <name>
#
# Creates and checks out a new branch.
# ---------------------------------------------------------------------------
make_branch() {
  git checkout -b "$1"
}

# ---------------------------------------------------------------------------
# checkout_branch <name>
#
# Checks out an existing branch.
# ---------------------------------------------------------------------------
checkout_branch() {
  git checkout "$1"
}

# ---------------------------------------------------------------------------
# add_migration <filename> [content] [date]
#
# Writes a migration file to src/backend/migrations/, stages it, and commits.
#   $1  filename  (e.g. "0002-create-users.ts")
#   $2  content   (optional; defaults to "export {};")
#   $3  date      (optional ISO-8601 string; sets both author and committer date)
# ---------------------------------------------------------------------------
add_migration() {
  local filename="$1"
  local content="${2:-export {};}"
  local date="${3:-}"

  echo "$content" > "src/backend/migrations/$filename"
  git add "src/backend/migrations/$filename"

  if [[ -n "$date" ]]; then
    GIT_COMMITTER_DATE="$date" GIT_AUTHOR_DATE="$date" \
      git commit -m "add $filename"
  else
    git commit -m "add $filename"
  fi
}

# ---------------------------------------------------------------------------
# advance_develop <n>
#
# Adds n numbered migration files to the current branch (simulate develop
# being ahead). Numbering starts from max existing migration number + 1.
# Each file is a separate commit.
# ---------------------------------------------------------------------------
advance_develop() {
  local n="$1"

  # Compute the current maximum 4-digit prefix among existing migration files.
  local max=0
  local f num
  for f in src/backend/migrations/*.ts; do
    [[ -e "$f" ]] || continue  # guard against empty glob
    # Extract the leading digits from the basename.
    local base
    base=$(basename "$f")
    num="${base%%[-_]*}"       # everything before first dash or underscore
    # Strip leading zeros for arithmetic; handle non-numeric gracefully.
    if [[ "$num" =~ ^[0-9]+$ ]]; then
      num=$((10#$num))
      (( num > max )) && max=$num
    fi
  done

  local i
  for (( i = 1; i <= n; i++ )); do
    local seq=$(( max + i ))
    local name
    name="$(printf "%04d" "$seq")-advance.ts"
    add_migration "$name"
  done
}

# ---------------------------------------------------------------------------
# merge_branch <name>
#
# Merges <name> into the current branch using a no-fast-forward merge.
# ---------------------------------------------------------------------------
merge_branch() {
  git merge --no-ff "$1" -m "Merge branch '$1'"
}

# ---------------------------------------------------------------------------
# teardown_repo
#
# Removes the temp repository created by setup_repo.
# ---------------------------------------------------------------------------
teardown_repo() {
  cd /
  rm -rf "$REPO_DIR"
}

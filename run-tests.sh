#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# run-tests.sh — entrypoint for the renumberMigrations.ts test harness.
#
# Usage:
#   CS_REPO=/path/to/ClientSafeWeb ./run-tests.sh
#   ./run-tests.sh --repo=/path/to/ClientSafeWeb
#
# Sources all helpers and scenario groups, then runs them in order.
# Exits 0 when all assertions pass; exits 1 on any failure.
# ---------------------------------------------------------------------------

# CS_REPO: path to the ClientSafeWeb repository clone.
# Set via env var or --repo argument. No default — must be explicit.
CS_REPO="${CS_REPO:-}"

# Parse --repo argument (overrides env var)
for arg in "$@"; do
  case "$arg" in
    --repo=*) CS_REPO="${arg#--repo=}" ;;
    --repo)   echo "Error: --repo requires a value (e.g. --repo=/path/to/ClientSafeWeb)"; exit 1 ;;
  esac
done

# Validate
if [[ -z "$CS_REPO" ]]; then
  echo ""
  echo "Error: ClientSafeWeb repository path not set."
  echo ""
  echo "  Set CS_REPO env var:    export CS_REPO=/path/to/ClientSafeWeb"
  echo "  Or pass --repo flag:    ./run-tests.sh --repo=/path/to/ClientSafeWeb"
  echo ""
  exit 1
fi

# Expand leading ~ (not expanded inside string parsing)
CS_REPO="${CS_REPO/#\~/$HOME}"

# Resolve to absolute path and verify
CS_REPO="$(cd "$CS_REPO" 2>/dev/null && pwd)" || {
  echo "Error: CS_REPO path does not exist or is not accessible: $CS_REPO"
  exit 1
}

export CS_REPO

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
if ! command -v ts-node &>/dev/null && ! npx --no ts-node --version &>/dev/null 2>&1; then
  echo "❌  ts-node is not available. Install it with: npm install -g ts-node" >&2
  exit 1
fi

if ! command -v git &>/dev/null; then
  echo "❌  git is not available. Install git and retry." >&2
  exit 1
fi

if [ ! -f "$CS_REPO/src/scripts/renumberMigrations.ts" ]; then
  echo "❌  Hook script not found at: $CS_REPO/src/scripts/renumberMigrations.ts" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Source helpers
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/helpers/setup.sh"
source "$SCRIPT_DIR/helpers/assert.sh"

# ---------------------------------------------------------------------------
# Source scenario groups
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/scenarios/01-guard-exits.sh"
source "$SCRIPT_DIR/scenarios/02-renumber-logic.sh"
source "$SCRIPT_DIR/scenarios/03-edge-cases.sh"
source "$SCRIPT_DIR/scenarios/04-merge-strategies.sh"

# ---------------------------------------------------------------------------
# Global teardown — best-effort cleanup of any lingering REPO_DIR
# ---------------------------------------------------------------------------
teardown_all() {
  if [[ -n "${REPO_DIR:-}" && -d "${REPO_DIR:-}" ]]; then
    rm -rf "$REPO_DIR"
  fi
}
trap 'teardown_all 2>/dev/null || true' EXIT INT TERM

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
echo "══════════════════════════════════════════════════"
echo "  renumberMigrations.ts — test harness"
echo "  Hook: $CS_REPO/src/scripts/renumberMigrations.ts"
echo "══════════════════════════════════════════════════"

# ---------------------------------------------------------------------------
# Run all scenario groups in order
# ---------------------------------------------------------------------------
run_guard_exit_scenarios
run_renumber_logic_scenarios
run_edge_case_scenarios
run_merge_strategy_scenarios

# ---------------------------------------------------------------------------
# Summary — exits 1 when FAIL_COUNT > 0
# ---------------------------------------------------------------------------
print_summary

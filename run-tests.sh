#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# run-tests.sh — entrypoint for the renumberMigrations.ts test harness.
#
# Usage:
#   ./renumber-migrations/run-tests.sh
#
# Sources all helpers and scenario groups, then runs them in order.
# Exits 0 when all assertions pass; exits 1 on any failure.
# ---------------------------------------------------------------------------

KEEP_ORDER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KEEP_ORDER_ROOT

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

if [ ! -f "$KEEP_ORDER_ROOT/src/scripts/renumberMigrations.ts" ]; then
  echo "❌  Hook script not found: $KEEP_ORDER_ROOT/src/scripts/renumberMigrations.ts" >&2
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
echo "  Hook: $KEEP_ORDER_ROOT/src/scripts/renumberMigrations.ts"
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

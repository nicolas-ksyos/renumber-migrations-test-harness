# renumber-migrations — Test Harness

A standalone bash test harness for the `renumberMigrations.ts` post-merge hook in the
[ClientSafeWeb](https://github.com/ClientSafe/keep-order) repository. It
spins up isolated temporary git repositories per scenario, invokes the hook via
`ts-node`, and asserts on exit codes, file presence, and stdout — with no external test
framework required.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| `git` | Any version ≥ 2.x; ≥ 2.28 recommended for `git init -b` |
| `ts-node` (global) **or** `npx` | `run-tests.sh` tries the global binary first, then falls back to `npx` |
| `CS_REPO` set to your ClientSafeWeb clone | Required — see Setup below |
| macOS (darwin) | Tested platform; Linux likely works but is untested |

---

## Setup

Point the harness at your ClientSafeWeb clone before running:

```bash
# Option A — env var (add to your shell profile for convenience)
export CS_REPO=/path/to/ClientSafeWeb

# Option B — inline per run
CS_REPO=/path/to/ClientSafeWeb ./run-tests.sh

# Option C — flag
./run-tests.sh --repo=/path/to/ClientSafeWeb
```

---

## How to run

```bash
# From the renumber-migrations/ directory:
./run-tests.sh --repo=/path/to/ClientSafeWeb
```

Expected output (abridged):

```
══════════════════════════════════════════════════
  renumberMigrations.ts — test harness
  Hook: /path/to/ClientSafeWeb/src/scripts/renumberMigrations.ts
══════════════════════════════════════════════════

══════════════════════════════════════
  Scenario group 01: Guard exits
══════════════════════════════════════
--- 1.1: SKIP_MIGRATION_RENUMBER=true exits 0 without renaming ---
  ✅ PASS  1.1 SKIP_MIGRATION_RENUMBER=true exits 0
  ✅ PASS  1.1 original file untouched
--- 1.2: no CS-ticket in current branch name — exits 0 ---
  ✅ PASS  1.2 no CS-ticket branch exits 0
  ✅ PASS  1.2 skip message printed
...

══════════════════════════════════════
  Results: 52 passed, 0 failed
══════════════════════════════════════
```

Exit code is `0` when all assertions pass; `1` on any failure.

---

## Directory layout

```
renumber-migrations/
  run-tests.sh                 ← entrypoint
  scenarios/
    01-guard-exits.sh          ← category 1: guard conditions / early exits
    02-renumber-logic.sh       ← category 2: core renumber logic
    03-edge-cases.sh           ← category 3: edge cases & error handling
    04-merge-strategies.sh     ← category 4: merge type strategies (local)
  helpers/
    setup.sh                   ← git repo factory functions
    assert.sh                  ← assertion helpers and summary printer
  README.md
```

### helpers/setup.sh

| Function | Description |
|---|---|
| `setup_repo` | Creates a fresh temp git repo on `develop` with `0001-initial.ts`; sets `REPO_DIR` |
| `make_branch <name>` | Creates and checks out a new branch |
| `checkout_branch <name>` | Checks out an existing branch |
| `add_migration <file> [content] [date]` | Writes a migration file, stages it, and commits. `date` must be a Unix epoch in `@<seconds>` format (e.g. `@1000000000`) — ISO-8601 strings without a timezone are silently rejected by git and fall back to the real clock, producing unreliable timestamps for sort tests |
| `advance_develop <n>` | Adds `n` sequential migration commits to the current branch |
| `merge_branch <name>` | Merges `<name>` into the current branch (`--no-ff`) |
| `teardown_repo` | Removes `REPO_DIR`; called via `trap` in each scenario |

### helpers/assert.sh

| Function | Description |
|---|---|
| `assert_exit_code <label> <expected> <actual>` | Passes when `actual == expected` |
| `assert_file_exists <label> <path>` | Passes when the file exists on disk |
| `assert_file_not_exists <label> <path>` | Passes when the file does not exist |
| `assert_file_renamed <label> <old> <new>` | Asserts old path gone + new path present (two sub-assertions) |
| `assert_stdout_contains <label> <needle> <haystack>` | Passes when `haystack` contains `needle` |
| `print_summary` | Prints pass/fail tally; returns `1` when `FAIL_COUNT > 0` |

---

## How to add a new scenario

1. **Choose the right file.** Pick the scenario file whose category matches your test, or create `05-<category>.sh` for a new category.
2. **Write the function.** Follow the existing pattern — `trap 'teardown_repo 2>/dev/null || true' RETURN` at the top, then `setup_repo`, arrange state, invoke the hook, assert, done.
   ```bash
   scenario_2_6() {
     trap 'teardown_repo 2>/dev/null || true' RETURN
     echo "--- 2.6: <description> ---"
     setup_repo
     # ... arrange state ...
     local exit_code=0
     local output
     output=$(run_hook) || exit_code=$?
     assert_exit_code "2.6 <label>" 0 "$exit_code"
   }
   ```
3. **Register it.** Add `scenario_2_6` inside the category's `run_*_scenarios()` function.
4. **New category file only:** `source` the new file in `run-tests.sh` and call its `run_*_scenarios` entry-point alongside the others.

---

## Relationship to ClientSafeWeb

This is a fully standalone repository at `~/repos/renumber-migrations/`. It has no filesystem dependency on the ClientSafeWeb clone — the connection is purely through the `CS_REPO` environment variable, which points to your local ClientSafeWeb checkout. Clone each repo wherever suits you; they do not need to be siblings.

---

## Scenario inventory

| # | Name | Category |
|---|---|---|
| 1.1 | `SKIP_MIGRATION_RENUMBER=true` exits 0 without renaming | Guard exits |
| 1.2 | No CS-ticket in current branch name — exits 0 | Guard exits |
| 1.3 | Non-merge commit (no HEAD^2) — exits 0 | Guard exits |
| 1.4 | No migration files in merge — exits 0 | Guard exits |
| 1.5 | Migrations already correctly numbered — exits 0 without rename | Guard exits |
| 2.1 | Single new migration behind develop | Renumber logic |
| 2.2 | Multiple migrations sorted by commit timestamp | Renumber logic |
| 2.3 | Feature branch behind develop | Renumber logic |
| 2.4 | Feature-into-feature merge | Renumber logic |
| 2.5 | Non-.ts files in the migrations directory are skipped | Renumber logic |
| 3.1 | Conflict markers in file → exit 1 | Edge cases |
| 3.2 | Stale local develop (local-only, no remote) | Edge cases |
| 3.4 | `git mv` fails mid-process → rollback + exit 1 | Edge cases |
| 3.5 | Migration directory missing → exit 1 | Edge cases |
| 3.6 | Non-standard filenames ignored in max-number calculation | Edge cases |
| 4.1 | `master` → `develop` local merge (no-op: CS guard fires) | Merge strategies |
| 4.2 | `release/*` → `develop` local merge (no-op: CS guard fires) | Merge strategies |
| 4.3 | `feature/CS-*` → `feature/CS-*` local merge (rename executes) | Merge strategies |

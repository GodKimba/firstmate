# Firstmate CI regression composition

This document records how the routine fast proof and complete CI suite use the measured portable regression composition.
Composition and execution are owned by `bin/fm-test-run.sh` (`--proven-isolated`, `--lane portable-parallel-1`, `portable-parallel-2`, and `portable-serial`).
The proven-isolated candidate set remains owned by `bin/fm-test-isolation-proof.sh`.
The workflow routing, runner selection, concurrency, and artifact policy are owned by `.github/workflows/ci.yml`.

## CI routing

Pull requests and pushes to `main` run two standard Ubuntu jobs, each with a five-minute timeout.
The first runs the lint owner, the complete-partition guard, repository and workflow invariants, and portable parallel shard 1.
The second runs portable parallel shard 2 independently.
The production shard evidence totals about 65 seconds of serial script time per job, leaving setup and lint margin inside the five-minute target without placing stateful, real-Herdr, or platform-specific work on the routine path.

The complete suite runs nightly at the cron declared in the workflow and on `workflow_dispatch` for sensitive changes and deliberate full validation.
It retains both portable parallel shards, the portable serial remainder, the real-Herdr family, stock macOS Bash compatibility, lint, repository invariants, and the complete-partition guard.
Routine runs are grouped by workflow, event, and ref or pull request and cancel older superseded runs.
Manual complete-suite runs include their run ID in the concurrency group so overlapping invocations remain distinct requested proofs.

All jobs use GitHub-hosted standard `ubuntu-latest` or `macos-latest` runners.
The workflow uses read-only contents permission, does not use `pull_request_target`, and does not consume secrets.

## Inputs

| Input | Owner / source |
|---|---|
| Proven-isolated set (29 scripts) | `bin/fm-test-isolation-proof.sh --list` and `docs/fm-test-isolation-proof.md` |
| Phase 1 serial durations | CI timing artifacts `fm-test-timing` from main after #825 / #832 / #834 |
| Real-Herdr family | `bin/fm-test-run.sh --family real-herdr-gated` (dedicated required CI lane) |

Phase 1 averages used for balance (mean of available serial `duration_ms` across those artifacts):

| duration_ms (avg) | script |
|---:|---|
| 29639 | `tests/fm-arm-pretool-check.test.sh` |
| 25402 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 19428 | `tests/fm-x-mode.test.sh` |
| 14979 | `tests/fm-cd-pretool-check.test.sh` |
| 9339 | `tests/fm-backend-herdr.test.sh` |
| 6885 | `tests/fm-herdr-lab.test.sh` |
| 5127 | `tests/fm-crew-state.test.sh` |
| 4044 | `tests/fm-pr-merge.test.sh` |
| 3922 | `tests/fm-grok-harness.test.sh` |
| 2492 | `tests/fm-test-run.test.sh` |
| 1901 | `tests/fm-send-popup-settle.test.sh` |
| 1234 | `tests/fm-spawn-batch.test.sh` |
| 851 | `tests/fm-send-strict.test.sh` |
| 791 | `tests/fm-review-diff.test.sh` |
| 627 | `tests/fm-tmux-submit-busy.test.sh` |
| 525 | `tests/fm-brief.test.sh` |
| 321 | `tests/fm-composer-ghost.test.sh` |
| 276 | `tests/fm-send-settle.test.sh` |
| 189 | `tests/fm-ensure-agents-md.test.sh` |
| 175 | `tests/fm-supervision-instructions.test.sh` |
| 138 | `tests/fm-instruction-owners.test.sh` |
| 133 | `tests/fm-lint.test.sh` |
| 108 | `tests/fm-pi-primary-types.test.sh` |
| 106 | `tests/fm-nm-test-contract.test.sh` |
| 67 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-captain-translation-contract.test.sh` |
| 48 | `tests/fm-composer-lib.test.sh` |
| 36 | `tests/fm-stow-contract.test.sh` |
| 28 | `tests/fm-no-mistakes-ownership.test.sh` |

## Balancing history

The original 30-script set used longest-processing-time (LPT) assignment onto two workers with the Phase 1 averages above.
The current 29-script lanes retain that assignment after one 283 ms candidate was removed from `portable-parallel-1`.
The current totals are therefore intentionally not a fresh LPT balance of the 29-script set.
Do not rebalance alphabetically or by family intuition.
Shard execution order remains longest-first within each retained lane.

| Lane | Script count | Sum of Phase 1 averages |
|---|---:|---:|
| `portable-parallel-1` | 14 | 64296 ms (~64.3 s) |
| `portable-parallel-2` | 15 | 64579 ms (~64.6 s) |
| imbalance | | 283 ms |

Exact ordered membership is the heredoc lists in `bin/fm-test-run.sh` (`list_portable_parallel_1` / `list_portable_parallel_2`).

## Portable serial remainder

`portable-serial` is every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
That keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in (default skip), GUI backends, and other stateful or unproven work serial.
Measured serial remainder wall (from the same Phase 1 artifacts, excluding Herdr) is about **13 minutes**.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` proves:

1. The two portable parallel shards are a partition of the proven-isolated set.
2. Proven-isolated embeds match `bin/fm-test-isolation-proof.sh --list`.
3. Union of portable parallel shards + portable serial + real-Herdr family equals the complete `tests/*.test.sh` inventory.
4. Those four partitions are pairwise disjoint (no missing scripts, no duplicates).

The routine fast proof runs that guard before regressions, and the nightly or manual complete suite runs it as its own job.

## Artifacts

Successful runs publish no timing or diagnostic artifacts.
The Herdr job still writes its timing JSON locally so a failed run can upload it with the pre-suite snapshot and server log as one diagnostic artifact.
That failure-only artifact uses one-day retention, and there is no cross-job timing transport or aggregate artifact.
Console timing markers from `bin/fm-test-run.sh` remain available in each job log without making artifact storage a permanent requirement.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| routine fast proof 1/2 | 5 | Each measured shard totals about 65 seconds of serial script time, leaving bounded setup and lint margin |
| portable parallel 1/2 | 10 | Measured shard sum ~1 min; hang tripwire with margin |
| portable serial | 20 | Measured ~13 min remainder; reduced from interim 25m full-portable slack after sharding |
| Herdr | 40 | Unchanged hang tripwire for the real-Herdr lane |
| stock macOS Bash | 10 | Existing platform compatibility tripwire, outside the routine PR path |

Timeouts remain hang tripwires, not expected healthy ends of green suites.
Do not raise them as a substitute for green results, retries, or weaker assertions.

## Fork Actions verification

On 2026-07-28, read-only `gh-axi` inspection of `GodKimba/firstmate` returned Actions enabled with all actions allowed, read-only default workflow permissions, and no permission for workflows to approve pull requests.
The exact commands were:

```sh
gh-axi api GET /repos/GodKimba/firstmate/actions/permissions
gh-axi api GET /repos/GodKimba/firstmate/actions/permissions/workflow
gh-axi api GET '/repos/GodKimba/firstmate/actions/runs?event=pull_request&per_page=100' --jq '[.workflow_runs[] | select(.pull_requests[]?.number == 7)] | {count:length}'
gh-axi api GET /repos/GodKimba/firstmate/commits/0f7d5b646b25a04a7c82c4a0141e73176a8252d3/check-runs --jq '{total_count}'
```

The relevant output was `enabled: true`, `allowed_actions: all`, `default_workflow_permissions: read`, `can_approve_pull_request_reviews: false`, `count: 0`, and `total_count: 0`.
This confirms the repository-level Actions switch is currently enabled while PR 7 still had no workflow runs and no check-runs at its inspected head.
Repository or organization settings remain outside this workflow change.

## Preserved boundaries

- The proven-isolated set does not expand without a new concurrent isolation proof.
- Watcher, AFK, real Herdr, real tmux, and other stateful families remain serial where their composition owner places them.
- The routine proof does not replace deliberate nightly or manual complete-suite validation.

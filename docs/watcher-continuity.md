# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` owns continuous re-arm after arm-process exit, with a bounded drain for already-buffered output and `close` retained only for late stream finalization.
OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` owns continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed cycle.
Pi also verifies that a stored child reference still names a live process before treating a repair request as redundant.
A failed follow-up never cancels continuity restoration.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
While supervision is still needed and away mode remains inactive, an actionable close or typed failure wakes the idle session through exit 2.

## Actionable wake ordering

After Pi settles an actionable arm cycle from `close` or the bounded post-exit drain, or after an actionable OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits for bounded adapter-specific retirement confirmation - process exit for Pi and child close for OpenCode - before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later settles, its actual cycle result is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the unchanged bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
No PreToolUse hook denies fleet commands based on watcher status.
The model no longer re-arms after ordinary wakes.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` returns exactly one clean empty success, the away-mode stand-down below; every other empty cycle is a typed failure.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.

## Away-mode stand-down

While `state/.afk` exists the away supervisor owns the single watcher cycle as its own child, so no continuity adapter owes one.
Every arm path in this home stands down instead of arming: `bin/fm-watch-arm.sh` prints `watcher: stood-down - <why>` and exits 0 without starting anything, and `bin/fm-watch-checkpoint.sh` prints `checkpoint: stood-down - <why>` and exits 3 without running a watcher.
Codex uses a distinct code rather than the quiet-checkpoint 124 because a stand-down returns immediately, so a protocol that starts the next checkpoint would spin.

A stand-down is terminal and is not a failure.
The caller starts no successor, schedules no retry, raises no failure alarm, and delivers no wake.
Suppressing delivery is deliberate: the away supervisor is the supervisor while away mode is on, the watcher still enqueues every wake to `state/.wake-queue` before advancing its suppression markers, and `bin/fm-afk-return.sh` replays that queue on return.

The gate lives in each adapter's own arm and deliver path, not only in the arm layer.
An arm-layer gate alone is unsound: an adapter that does not classify the stand-down reclassifies the clean exit as an unexplained empty cycle, burns its retry ladder, and injects a spurious `watcher: FAILED` wake anyway.
Pi and OpenCode therefore both check the flag before spawning, classify a `stood-down` arm line ahead of every failure shape, and recheck the flag when a successor fails readiness so a flag set mid-cycle is still a clean break rather than a retry.
Claude's Stop auto-arm already exits before arming while the flag exists and is unchanged.
Codex and Grok are model-issued paths with no adapter of their own, so the script-level gate is their protection and their protocols name the stand-down explicitly.

The away supervisor tags its watcher's singleton lock with `owner=away-supervisor`.
`bin/fm-watch-arm.sh --restart` refuses to signal a lock carrying that tag, which also covers the window where the flag is already cleared but the daemon has not finished reaping its child.
A lock written before owner tagging carries no tag and is not assumed ordinary: while away mode is active it is treated as daemon-owned, and outside away mode it stays evictable so normal restart recovery is unchanged.

`bin/fm-afk-launch.sh stop` bounds its shutdown wait with `FM_AFK_STOP_TIMEOUT` (default 45 seconds), derived from the daemon's measured shutdown floor rather than a round number: the deferred TERM trap in the idle branch, the escalation flush's submit-confirm retries, and the watcher child's own poll sleep together put that floor near 30 seconds on a busy home.
Expiry is not a verdict.
The stop path then reconciles once by exact process identity: a live PID whose identity no longer matches the one recorded before the signal is a recycled PID, which proves the signalled daemon exited.
Every other outcome preserves lifecycle state, so an unreadable identity stays ambiguous and a daemon still running under its original identity keeps `state/.afk`, the terminal record, and the catch-up evidence even when its lock is already gone.
The daemon's own reap stays unbounded on purpose: the watcher can be mid-enqueue when the signal lands, and enqueue-before-suppress is what keeps a wake from being lost across a restart.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and live-child redundant-call no-ops, proves a stale child reference permits repair, and proves process exit still launches one successor and one wake while a descendant keeps stderr open through the later `close`.
It separately proves that retirement uses process exit rather than delayed stream closure, so an exited unready successor cannot strand restoration while its descendant retains stderr.
It also simulates actionable and empty cycle endings against the actual Pi and OpenCode handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before restoration to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-afk-standdown.test.sh` covers the away-mode stand-down across every path that shares it: the arm layer's clean exit in both modes, the checkpoint's distinct stop-checkpointing code, and Pi and OpenCode classifying both a `stood-down` arm line and a not-needed restoration as terminal instead of opening a retry ladder.
It also pins the owner-tagged lock's eviction refusal against its unchanged healthy reading, the conservative untagged-lock rule inside and outside away mode, both polarities of the bounded shutdown wait, and the queued wakes left intact for return catch-up.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, and exit-2 translation.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.

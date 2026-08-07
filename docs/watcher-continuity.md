# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Within each generation, process exit settles an arm after one bounded output drain even when a descendant keeps stdout or stderr open, while the later stream `close` only finalizes resources and cannot launch or notify twice.
A stale child reference is reclaimed before a repair call, and an unready restoration arm is retired from process exit rather than delayed inherited-stream closure.
While away mode is active, Pi stands down as a terminal non-failure, clears its retry state, and yields the single watcher to the away supervisor.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
A cycle-end failure is benign when that live-watcher predicate is true, and the hook suppresses the arm output and continues silently.
Only an exhausted failure with no verified watcher emits one last-resort notice for the continuous failure episode; later consecutive Stop cycles exit 2 to guarantee another Stop-owned retry without repeating the notice until the turn-end guard consumes the attended fail-open.
The Claude turn-end guard owns the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after the durable wake queue was drained, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Away-mode stand-down

While `state/.afk` exists the away supervisor owns the single watcher cycle as its own child, so no continuity adapter owes one.
Every arm path in this home stands down instead of arming: `bin/fm-watch-arm.sh` prints `watcher: stood-down - <why>` and exits 0 without starting anything, and `bin/fm-watch-checkpoint.sh` prints `checkpoint: stood-down - <why>` and exits 3 without running a watcher.
Codex uses a distinct code rather than the quiet-checkpoint 124 because a stand-down returns immediately, so a protocol that starts the next checkpoint would spin.

A stand-down is terminal and is not a failure.
The caller starts no successor, schedules no retry, raises no failure alarm, and delivers no wake.
Suppressing adapter delivery is deliberate because the away supervisor is the consumer while away mode is on.
The watcher consults the shared lifecycle ledger, durably queues each remaining handoff before advancing detector state, and leaves a newly queued lifecycle occurrence pending until the daemon captures and buffers the binding it will surface.
`bin/fm-afk-return.sh` replays the durable queue on return, while [event-driven supervision](architecture.md#event-driven-supervision) owns the complete occurrence-recording order.

The gate lives in each adapter's own arm and deliver path, not only in the arm layer.
An arm-layer gate alone is unsound: an adapter that does not classify the stand-down reclassifies the clean exit as an unexplained empty cycle, burns its retry ladder, and injects a spurious `watcher: FAILED` wake anyway.
Pi and OpenCode therefore both check the flag before spawning, classify a `stood-down` arm line ahead of every failure shape, and recheck the flag when a successor fails readiness so a flag set mid-cycle is still a clean break rather than a retry.
OpenCode also treats its pre-existing `not-needed` restoration result as the same clean break because no remaining supervision need justifies a successor or delivery.
Claude's Stop auto-arm already exits before arming while the flag exists and is unchanged.
Codex and Grok are model-issued paths with no adapter of their own, so the script-level gate is their protection and their protocols name the stand-down explicitly.
The shared turn-end guard accepts the watcher-start handoff only when `state/.afk` coincides with an exact live daemon identity; a missing or ambiguous daemon keeps the ordinary blind-turn alarm.

The away supervisor's watcher tags its singleton lock with `owner=away-supervisor` only after its live parent matches the exact identity in this home's daemon lock.
`bin/fm-watch-arm.sh --restart` honors that tag only when the watcher itself still matches the lock's exact identity, its live parent still matches the recorded owner identity, and that owner still matches the daemon lock.
This protects the daemon's child during the window where the flag is already cleared but the daemon has not finished reaping it, without letting an environment variable, stale tag, or recycled PID claim protection.
A lock written before owner tagging carries no tag and is not assumed ordinary: after exact watcher-identity validation, it is treated as daemon-owned while away mode is active and stays evictable outside away mode so normal restart recovery is unchanged.

`bin/fm-afk-launch.sh stop` bounds its shutdown wait with `FM_AFK_STOP_TIMEOUT` (default 45 seconds), derived from the daemon's measured shutdown floor rather than a round number: the deferred TERM trap in the idle branch, the escalation flush's submit-confirm retries, and the watcher child's own poll sleep together put that floor near 30 seconds on a busy home.
Expiry is not a verdict.
The stop path then reconciles once by exact process identity: a live PID whose identity no longer matches the one recorded before the signal is a recycled PID, which proves the signalled daemon exited.
Every other outcome preserves lifecycle state, so an unreadable identity stays ambiguous and a daemon still running under its original identity keeps `state/.afk`, the terminal record, and the catch-up evidence even when its lock is already gone.
The daemon's own reap stays unbounded on purpose: the watcher can be mid-enqueue when the signal lands, and enqueue-before-suppress is what keeps a wake from being lost across a restart.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty arm settlements against the actual Pi and OpenCode handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before settlement to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
It separately proves stale child references permit repair, process exit launches one successor and one wake before inherited stderr closes, and restoration retirement uses process exit rather than delayed stream closure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-afk-standdown.test.sh` covers Pi's direct, successor, delivery-race, and retry-reset stand-down paths so away-mode ownership never creates duplicate supervision.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, and exit-2 translation.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.

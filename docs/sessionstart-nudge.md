# Native session-start nudge

AGENTS.md section 3 is the authoritative behavioral contract for session start.
The tracked native adapters inject one instruction and never run the digest, acquire the lock, perform bootstrap work, drain notifications, or arm supervision themselves.
The payload starts with U+2063 and the stable `FIRSTMATE_OP: ` label, carries the current `session-start` protocol kind, and retains exactly ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` as its body.
The Ahoy skill owns the rule that this marked operational input is never a captain-authored session boundary, including its narrow legacy compatibility cases.

## Shared wrapper and safety

`bin/fm-sessionstart-nudge.sh` is the single command every harness adapter invokes.
It sources `bin/fm-gate-refuse-lib.sh` and stays silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
It shares `bin/fm-primary-scope-lib.sh` with `bin/fm-turnend-guard.sh`, so the hooks use one primary-detection owner.
The Shared Predicate section of [`turnend-guard.md`](turnend-guard.md#shared-predicate) owns marker validation, plain-checkout detection, and required Firstmate-shaped paths.

That same file is the single owner of the launch identity separating a coordinator from an ordinary crewmate, and its header owns the exact mechanics.
`bin/fm-spawn.sh` stamps `FM_CREW_TASK` onto the launch command of every ordinary ship and scout dispatch at one site and clears it for a secondmate launch, so the predicate refuses a stamped worker before any checkout-shape test.
A non-empty value is the identity, so the explicit empty assignment a secondmate coordinator carries preserves its own primary standing.
That worker refusal never depends on paths, prompts, lock outcomes, or pane names, which is what keeps these tracked primary adapters inert when the worker's own project is this repository and its checkout is trusted.

Before printing, the wrapper reads `state/.lock` and walks at most eight parents from its own pid, matching `bin/fm-lock.sh` and Pi's `lockOwnership()` ancestry depth.
If the lock names a live pid in that ancestry, session start already ran in this harness session and the wrapper stays silent.
Every path exits 0, including malformed state and adapter errors, because a Claude SessionStart exit 2 blocks session initialization.

## Harness transports

| Harness | Tracked transport | Current compatibility |
| --- | --- | --- |
| Claude | `.claude/settings.json` registers `SessionStart` for `startup`, `resume`, and `clear`, excludes `compact`, and invokes the wrapper through `CLAUDE_PROJECT_DIR`. | Native stdout context injection is supported. |
| Codex | `.codex/hooks.json` anchors to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and executes the wrapper. | Native stdout context injection is supported. |
| OpenCode | `.opencode/plugins/fm-primary-sessionstart-nudge.js` listens for `session.created`, runs once per session id, and calls `client.session.promptAsync` only when the wrapper prints a nudge. | Interactive TUI delivery is supported; headless `opencode run` is intentionally fail-open because the process can exit before the queued turn. |
| Pi / pi-signed | `.pi/extensions/fm-primary-turnend-guard.ts` handles `session_start` reasons `startup`, `new`, and `resume`, then injects the wrapper output with `pi.sendMessage`. It applies the shared launch identity itself, so a crewmate never spawns the wrapper at all. | The custom message reaches model context without racing an initial positional prompt. |
| Grok | `.grok/hooks/fm-primary-sessionstart-nudge.json` registers a project `SessionStart` hook and invokes the wrapper through inline-defaulted `${GROK_WORKSPACE_ROOT:-}`. | The project hook runs when the checkout is trusted, but Grok currently discards hook stdout from model context, so this path is intentionally fail-open. |

Pi is the one adapter that auto-discovers its tracked extension from any trusted project directory rather than from an explicit launch flag, so a crewmate whose own project is this repository loads it without Firstmate choosing to.
Reading the shared launch identity in the extension keeps that discovery from producing a coordinator instruction in a worker session at all, instead of producing one and discarding it.
The wrapper still applies the same identity, so it stays authoritative for every adapter and for a direct invocation.

The OpenCode nudge runs only on `session.created`.
The watcher-arm and turn-end plugins run later on `session.idle`, and the guard lets the watcher coordinator act first, so the plugins do not race for one lifecycle event.

Grok's guaranteed-loading alternative is a global token-guarded hook like the pattern used by `bin/fm-spawn.sh`.
That alternative expands trust and writes outside this repository, so Firstmate never installs it or grants folder trust automatically.

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` proves wrapper silence for both gate signals, an unmarked linked worktree, a missing state directory, and an already-owned lock.
It proves exact U+2063 `FIRSTMATE_OP:`-prefixed, `session-start`-typed one-line output for a plain primary and a marked linked secondmate primary.
It proves wrapper silence for a stamped crewmate in a primary-shaped checkout, with a coordinator state directory, and against a valid secondmate marker, and proves a cleared identity still nudges.
It drives the real Pi `session_start` handler for all three reasons to prove a crewmate never spawns the wrapper while a coordinator spawns it every time.
It also verifies every tracked transport registration listed above.
`tests/fm-spawn-dispatch-profile.test.sh` proves the stamping side across harnesses for ship and scout dispatch and the explicit clear for a secondmate launch.
`tests/fm-captain-translation-contract.test.sh` proves Ahoy's current marker rule, narrow legacy compatibility exclusions, genuine captain-message near misses, and the shared marker on supported user-role operational injections.
`tests/fm-pi-primary-live-e2e.test.sh` and `tests/fm-opencode-primary-live-e2e.test.sh` exercise native startup paths with first-message and later-message Ahoy regressions.
`tests/fm-turnend-guard.test.sh`, `tests/fm-pi-watch-extension.test.sh`, and `tests/fm-daemon.test.sh` cover marked guard, monitoring, and away-mode delivery.

[`verification/supervision.md`](verification/supervision.md#native-session-start-delivery) records the active version-scoped transport evidence.

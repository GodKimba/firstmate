# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command resolves the tasks-axi backlog and configured archive from the active `FM_HOME`, so those remain the only durable work stores and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
For an existing identity, it decodes the rendered title through tasks-axi's TOON codec before exact comparison, so presentation quotes are never treated as title content.
It rejects an identity collision, a changed title, ambiguous or malformed title output, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## Durability across backlog retention

Normal retention prunes completed rows out of the active backlog into the tasks-axi archive configured in `.tasks.toml`.
The script therefore treats the active backlog and that archive as two stores of one durable identity, so a resolved decision stays verifiable after retention without rehydrating the archived task and without copying one decision into both stores.
Only reads consult both stores; every mutating subcommand still requires the record in the active backlog.

tasks-axi refuses to open the configured archive as a backlog file and does not parse rows under its `## Archived` headers.
The lookup therefore extracts the record's own lines with a column-zero checkbox scan, projects them into a private mode-`0600` temporary `## Done` section, and lets tasks-axi remain the single record parser.
The real archive is only ever read.

Ambiguity refuses instead of resolving silently.
A record present in both stores is accepted only while the two copies are identical, which is the bounded window a prune can expose; divergent copies, a second archived row for the same identity, an archived row that is not a completed record, an unparsable or non-canonical archived row, and a symlinked or non-regular archive all fail the lookup.
A refusal is distinct from absence, so an unusable store never degrades into a passing empty inventory and scout teardown keeps refusing.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Retention-durability verification date: 2026-07-28.
Quoted-title idempotency verification date: 2026-07-29.

The focused end-to-end regression uses only synthetic `sample` identities and decision text in temporary homes; no private backlog or archive data is read or written.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The quoted-title regression covers colon and comma titles, literal surrounding quote characters, true title mismatches, malformed scalar syntax, and duplicate title fields without changing the existing private decision record.

The retention-durability regression resolves a captain decision, prunes the completed record out of the active backlog with `tasks-axi prune`, and verifies the same identity before and after that move.
It asserts the archived task is not rehydrated into the active backlog and the decision is not duplicated across both stores, that reopening an already resolved archived identity is still rejected, and that cleanup succeeds only because the gate passes rather than because it was weakened.
Its sibling cases cover the identical retention transition window, a divergent duplicate, duplicate archived rows, a non-completed archived row, non-canonical rows, unsupported escaped archive configuration, an unusable active store, private staging permissions, a symlinked archive with cleanup still refusing, and an empty archive.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - a resolved decision verifies before and after normal retention under one identity
ok - an identical retention transition verifies while a divergent duplicate refuses
ok - duplicate, non-done, malformed, symlinked, and absent archived records refuse safely
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - existing hold retries decode quoted titles and refuse mismatched or ambiguous scalars
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/fm-teardown.test.sh
ok - persistent index.lock exhausts retries and refuses without force-removing the lock
ok - empty retry wait overrides use the default without aborting teardown
ok - fractional legacy retry wait remains supported without arithmetic

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides
(16 ok lines total)

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness
(42 ok lines total)

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy
(16 ok lines total)

$ bash tests/fm-decision-answer-authority.test.sh
ok - blocker clearance and captain-held transfer keep their existing closure paths
(14 ok lines total)

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=56 local_links=155

$ git diff --check
(no output)
```

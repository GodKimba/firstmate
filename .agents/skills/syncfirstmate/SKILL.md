---
name: syncfirstmate
description: Review and integrate upstream Firstmate changes into this fork. Use when the captain invokes /syncfirstmate (e.g. "/syncfirstmate", "/syncfirstmate check", "sync from upstream", "what changed upstream?"). Reports every upstream-only change for the captain to accept, adapt, or reject, then prepares an ancestry-preserving merge as a reviewed PR. Never merges, never touches running homes.
user-invocable: true
metadata:
  internal: true
---

# syncfirstmate

Bring upstream Firstmate changes into this fork, with the captain choosing what lands.

This fork carries its own work, so upstream is not a source to follow blindly.
The workflow is therefore two steps with a human decision between them: `check` reports what upstream changed and what it would collide with, and `prepare` builds the integration the captain approved.
It ends at a reviewed PR and never merges it.

The rollout to running homes is a separate step.
`/syncfirstmate` moves upstream work into `origin`; `/updatefirstmate` moves `origin` into running homes.
Neither does the other's job.

## check

```sh
bin/fm-upstream-check.sh
```

Read-only apart from fetching remote-tracking refs.
It prints the divergence, the merge base, whether upstream is already an ancestor, a non-mutating conflict preview, and one review block per upstream-only commit with that commit's effect, surfaces, added files, and collision risk.

Exit code 1 means conflicts are predicted, which is an ordinary outcome, not a failure.
Exit code 2 is a refusal with the concrete missing requirement and the command that fixes it.

Relay the summary to the captain in plain outcomes under `AGENTS.md` section 9.
Group the commits by what they mean for this fork rather than reading the blocks aloud: what is new capability, what is a fix, what collides with work this fork already did.
The script's `review` line is mechanical evidence about file collisions - it is an input to your summary, never a verdict you pass along as a decision.

Then ask the captain to choose, per change or in bulk: **accept**, **adapt**, or **reject**.
Accept-all is a normal answer and usually the right one.
Keep this a conversation; do not build or consult a rules file, a policy engine, or a stored selection format.

Note the `recorded-tip` value from the summary.
`prepare` must run against that same tip, and upstream moves on its own schedule.

## prepare

Dispatch an ordinary ship task for the integration.
Firstmate does not perform the merge itself - this is project work in an isolated copy, delivered through the project's configured path, exactly like any other change.

Re-run `check` first.
If `recorded-tip` no longer matches what the captain reviewed, stop and re-present the summary; never prepare against an unreviewed tip.

The task's instructions must require, in order:

1. Merge the **complete** upstream tip with a true merge commit:
   ```sh
   git merge --no-ff upstream/main
   ```
   Merge the whole tip even when the captain rejected part of it.
   This is what makes `upstream/main` an ancestor, which is what stops future checks from re-proposing work that is already integrated.
2. Resolve every conflict by hand, and re-read the clean parts too.
   A conflict-free merge can still leave two independent solutions to the same problem side by side, and no marker warns about that.
3. Represent every rejection or adaptation as its **own commit on top of the merge**, with the rationale in the commit message and the dependency checked - some upstream commits add files that later upstream commits edit, so reversing one can break another.
4. Run the full test suite, not only the suites touching conflicted files.
5. Deliver through the configured path to a PR and stop.

Never implement a rejection by squashing, cherry-picking only the wanted commits, rebasing, rewriting history, or quietly leaving a commit out.
All four produce the right files and a history that claims the integration never happened, so every later `check` proposes the same commits again, forever.

## Landing

**The synchronization PR must be landed with a true merge commit.**
This is not optional and not the default:

```sh
bin/fm-pr-merge.sh <task-id> <pr-url> -- --merge
```

Without `-- --merge` the PR is squashed into a single-parent commit.
The files are identical, but upstream ancestry is gone, so `check` keeps reporting every already-integrated commit as outstanding and the fork can never converge.

This applies only to synchronization PRs.
Do not change the merge default for any other work.

After it lands, tell the captain to run `/updatefirstmate` to roll the result out to running homes.

## Safety

- **`check` never writes.**
  It fetches remote-tracking refs and computes the conflict preview in the object database; HEAD, the index, and the working tree are untouched.
  Use `--no-fetch` when even the fetch is unwanted.
- **Never push to upstream.**
  This workflow only ever reads from it.
- **Never merge automatically.**
  `prepare` stops at a reviewed PR; landing is the captain's, under `AGENTS.md` section 7.
- **Never force, stash, rebase shared history, or discard local work.**
  A dirty or diverged state is reported and left alone, never cleaned up.
- **Never update a running home.**
  That is `/updatefirstmate`, after the merge commit lands.
- **The integration happens in an isolated copy**, never the primary checkout.

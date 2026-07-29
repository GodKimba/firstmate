---
name: poolquota
description: Show the current quota and health of the captain's local CLIProxyAPI subscription pool. Use when the captain invokes /poolquota or asks about pool quota, subscription headroom, how much Claude or Codex capacity is left, which accounts are running low, when a limit resets, or whether the pool is healthy. Reads the pool's accounts read-only through quota-axi, reports a concise provider-level summary in chat, and opens a freshly regenerated detailed local panel; it changes no dispatch, account selection, or routing.
user-invocable: true
metadata:
  internal: true
---

# poolquota

Report how much subscription capacity the local account pool has left, and whether every account is answering.

This view is display only.
It never changes which provider or account a task is dispatched to, never touches proxy routing, and never modifies the pool.
`quota-axi` remains the single owner of provider quota semantics, and this view only presents what it reports for each pooled account.

GitHub is out of scope.
When the captain asks about pull requests, checks, or review load, that is `gh-axi`'s dashboard, not this one.

## What it does

1. Runs `bin/fm-pool-quota.sh` for a fresh read; the script's header and `--help` own its exact flags, bounds, environment overrides, output contract, and safety mechanics.
2. Opens the returned `panel` path with the ordinary nonblocking browser opener, `open <path>`, on every invocation.
   Do not use `lavish-axi` for this display-only dashboard because its feedback poll is appropriate for review surfaces, not a read-only status view.
3. Reports the provider-level summary in chat: per provider, how many accounts are answering, how much the healthiest account has left, how constrained the tightest one is, and when the next window resets.
4. Adds `--accounts` only when the captain wants the masked per-account and per-window detail in the terminal as well.

Run the command fresh every time.
A previous run's numbers are already out of date, and the panel is rebuilt from the new read rather than reused.

## The panel is local and private

The panel describes the captain's paid accounts and their remaining capacity.
Open it only through the local path with `open <path>`.
Never run `lavish-axi` or `lavish-axi share` on it, never copy its contents into a message that leaves this machine, and never attach it to an issue, a pull request, or a commit.

The artifact itself carries no credential and no full account address, but it is still private operational detail about the captain's subscriptions.

## Reading the numbers honestly

Percentages are per provider and per window.
Claude's session and weekly windows and Codex's weekly window measure different things, so never add them, average them, or say the pool is "at X percent" overall.
Report each provider on its own terms.

The headline number for a provider is its healthiest account, because that is the capacity actually available to the next task.
Report the most constrained account's quota-axi value without assigning a local threshold or status to it.

Preserve quota-axi's quota status exactly.
If quota-axi reports unknown availability, call it unknown and do not turn it into a percentage or a healthy claim.

An account that does not answer is not an account at zero.
Say that it did not report, and say what the read gave back, rather than folding it into a capacity number.

Files the command refused as unsafe, or skipped because the pool has them disabled, are reported as exactly that.
A refusal is a fact to relay, not an error to retry around.

## Chat-response contract

Lead with the answer the captain asked for.
When they asked whether there is room to run something, say yes or no and on which provider before anything else.

Keep the chat summary in plain outcomes: capacity left, accounts answering, when a limit clears, and what is degraded.
Do not print raw command output, file paths, account file names, masked identifiers, or window ids into chat unless the captain is debugging a specific account, in which case name it once with its masked label.

If the pool directory is absent or no account answers, say so plainly with what the read reported and stop.
Do not enable the proxy's management interface, restart the service, edit account files, or install anything to make a read succeed; those are captain decisions, and the blocker is the report.

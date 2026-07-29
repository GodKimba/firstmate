# Subscription pool account routing - verification record

Audience: maintainer verification.
This record holds the empirical facts that decide where account selection for the local CLIProxyAPI pool can and cannot live.
It is the disconfirming-evidence owner for the pool-routing design; `docs/configuration.md` owns the resulting operator-facing configuration.

Verified 2026-07-29 on macOS (Darwin 25.5.0) with cliproxyapi from Homebrew, `codex-cli 0.145.0`, `no-mistakes v1.41.2`, and `quota-axi 0.1.13`.

The machine-global routing cutover recorded here changes no repository behavior because its configuration lives in `~/.no-mistakes/config.yaml` outside this repository.
This branch as a whole is not documentation-only: it also introduces `bin/fm-pool-preflight.sh` and its behavior tests.
That command is separate advisory behavior and does not enact or configure the routing cutover.

## Why this record exists

A natural design for "quota-aware pool routing" is for firstmate to read each pooled account's quota, pick the healthiest one, and hand that account to the worker.
Every part of that design except the last step is supported.
The last step is not, and the evidence below is what proves it, so a future session does not re-derive it or quietly build the unsupported version.

## The proxy already owns account selection

`routing` in the proxy's configuration file is the account-selection owner:

```
routing:
  strategy: "round-robin" # round-robin (default), fill-first
  session-affinity: true
  session-affinity-ttl: "6h"
```

The proxy's own comment records that "Automatic failover is always enabled when bound auth becomes unavailable", and the binary carries `RoundRobinSelector` and `FillFirstSelector` implementations plus a `cooldown` subsystem (`quotaCooldownAfterFailure`, `cooldownStateFile`, `model_cooldown`) that withdraws an account after an upstream quota failure and restores it later.

Consequence: selection, failover, and post-exhaustion cooldown are already implemented once, inside the proxy, across every client that uses the pool.
A second selector in firstmate would not extend that behavior; it would race it.

## No per-request account-pin interface exists

This is the decisive negative result.

Searched the proxy binary for any request header or field that would let a client name the account to use:

```
strings -a /opt/homebrew/opt/cliproxyapi/bin/cliproxyapi \
  | grep -oiE 'x-cpa-auth[a-z-]*|x-auth-id|x-account[a-z-]*|x-cliproxy-auth[a-z-]*|auth-id-header|force-auth-id'
```

Empty result.
The `X-Cpa-*` family that does exist is response metadata only (`x-cpa-version`, `x-cpa-commit`, `x-cpa-build-date`, `x-cpa-safe-mode`, `x-cpa-support-plugin`), not request routing input.

The only client-controllable routing inputs are the session-affinity keys the configuration comment names: `X-Session-ID`, `Session_id` (Codex), `X-Client-Request-Id` (PI), `conversation_id`, `metadata.user_id`, or a hash of the first few messages.
These bind *related requests to each other* - they are a stickiness key, not an account selector.
A client can ask for "the same account as last time"; it cannot ask for "account N".

Consequence: a firstmate-side selector has no supported way to make its choice take effect.
It could compute a healthiest account and the proxy would still route by its own strategy.

## The Management API is disabled and must stay disabled

The one interface that can enumerate and manipulate pooled accounts is the Management API under `/v0/management/*` (`auth-files`, `get-auth-status`, `api-keys`, `config`).

Its `secret-key` is empty in the local configuration, and the proxy's own comment states that empty means "disable the Management API entirely (404 for all /v0/management routes)".
Confirmed empty by parsing the `remote-management` block.

The task brief forbids enabling it.
It is therefore not an available interface, and this record does not treat it as a latent option: enabling a management control plane to pick an account would add a privileged mutation surface to solve a routing problem the proxy already solves.

## Codex can reach the pool, but not a chosen account

`~/.codex/cliproxy.config.toml` already defines a working pool profile:

```
model = "gpt-5.6-sol"
model_provider = "cliproxyapi"
model_reasoning_effort = "high"

[model_providers.cliproxyapi]
base_url = "http://127.0.0.1:8317/v1"
wire_api = "responses"
env_key = "CLIPROXY_API_KEY"
```

`codex --help` confirms `-p, --profile <CONFIG_PROFILE_V2>` layers `$CODEX_HOME/<name>.config.toml` over the base config, and `-c key=value` overrides individual keys.
So routing a Codex run through the pool is supported and needs no new mechanism.

What that buys is pool access, not account choice: once the request reaches the proxy, account selection is the proxy's, per the section above.
`~/.codex/config.toml` sets `model` and `model_reasoning_effort` with no `model_provider`, so the default Codex path is direct authentication - which is the ambient-account behavior the brief set out to remove.
The cutover recorded below removes it for no-mistakes validations by selecting the profile per invocation, leaving this base config untouched for everything else.

## no-mistakes cannot bind a per-run Codex profile

`no-mistakes` selects its pipeline agent from `~/.no-mistakes/config.yaml` (`agent: codex`).
Extra agent flags come from `agent_args_override`, whose own comment states it is **global only**:

```
# Extra native agent CLI flags (optional, global only)
# agent_args_override:
#   codex:
#     - -c
#     - model_reasoning_effort="low"
```

`no-mistakes init --help` exposes only `--fork-url`; `no-mistakes axi run --help` exposes only `--intent`, `--skip`, and `--yes`.
There is no per-run, per-repo, or per-branch agent-argument surface.

Consequence: any change that routes the no-mistakes Codex agent through the pool is **global to every repository and every concurrent lane on this machine**, not scoped to one validation run.
Confirmed the hazard is live rather than theoretical: `no-mistakes status` showed an active run on another branch (`fm/fm-decision-hold-colon-title-idempotency`) while this task was being investigated.

A task-bound pool reservation for one Codex validation run is therefore unimplementable with the installed no-mistakes contract.
Attempting it by writing global config at run start and reverting at run end would corrupt any concurrently running lane's agent configuration, and would violate the shared-daemon rule that firstmate briefs already enforce.

## Quota data is per-account and normalized, and is not the blocker

`quota-axi 0.1.13` reports normalized per-account quota with model-scoped windows, so the data side of a quota-aware decision is available:

```
{"provider":"codex","source":"cli-rpc","plan":"pro",
 "state":{"status":"fresh","stale":false},
 "avail":[{"scope":"all_models","status":"known","effectivePercentRemaining":91,"limitingWindowIds":["weekly"]},
          {"scope":"model:codex_bengalfox","status":"known","effectivePercentRemaining":91,"limitingWindowIds":["weekly"]}]}
```

`bin/fm-pool-quota.sh` already measures every pooled account this way, per account, with masked identities.
The gap is not measurement.
The gap is that no supported interface turns a measurement into a binding routing decision.

## What follows from this evidence

- Do not build a firstmate-side account selector; the proxy owns selection, and firstmate cannot make a choice take effect.
- Do not enable the Management API to obtain one.
- Do not write global `agent_args_override` to pool-route a *single* run and revert it afterwards; it is machine-global, so a temporary write would corrupt any concurrently running lane.
  A *permanent* cutover is a different action with different risk, and the captain approved one - see "The approved permanent cutover" below.
- A quota-floor preflight snapshot is implementable today because measurement is supported.
  In pool mode it uses the best known all-models reading, can use only a subset of the account measurements, does not know which account the proxy will route, does not have a target-model bound, and does not enforce freshness.
  It therefore cannot determine whether the routed account has enough capacity or prevent mid-run exhaustion.

`bin/fm-pool-preflight.sh` implements that explicitly approximate signal; its header owns the exact contract.

## The approved permanent cutover

The captain approved routing every no-mistakes Codex validation on this machine through the pool profile, accepting the proxy's own round-robin selection, failover, cooldown, and session affinity, with reasoning depth pinned so only account routing changes.
The scope is the only one the interfaces permit: all repositories on the machine, never the firstmate primary chat and never a per-project, per-branch, or per-run subset.

The applied shape in `~/.no-mistakes/config.yaml` is the documented global surface and nothing else:

```
agent_args_override:
  codex:
    - --profile
    - cliproxy
    - -c
    - model_reasoning_effort="xhigh"
```

What the probes established, each read-only and printing no credential:

- `--profile cliproxy` resolves `provider: cliproxyapi` with `model: gpt-5.6-sol` preserved.
  Codex prints its resolved session header before it issues any request, so with the credential deliberately unset the resolution can be read without spending quota.
- The profile lowers reasoning depth to `high`, and `-c model_reasoning_effort="xhigh"` overrides it back to `xhigh`.
  A `-c` override therefore wins over a layered profile, which is what makes the pinned depth reliable.
- With `CLIPROXY_API_KEY` absent, codex fails closed with `Missing environment variable: CLIPROXY_API_KEY`.
  It does not fall back to the ambient direct login, so a broken pool route is loud rather than a silent return to the account this work set out to stop depending on.
- `--profile` applies only to codex runtime commands, so `codex doctor` rejects it and cannot be used to verify profile resolution.
- `no-mistakes doctor` does not validate `agent_args_override`; an isolated `NM_HOME` probe accepted an argument the binary's own error text calls managed.
  Validation happens when a run starts, so whether `--profile` survives it is proven only by a real run.

Two operational cautions this record exists to preserve:

- No per-run snapshot of agent arguments exists anywhere in no-mistakes state, and runs resume durable Codex sessions across steps.
  Change this configuration only when no run is active, or a run will split across two providers and try to resume sessions against a backend that never created them.
- `ps eww` does not reveal a process environment on this macOS, not even the caller's own.
  It cannot be used to check whether a daemon inherited a variable; verify the method against a process where `env` confirms the variable before trusting any absence it reports.

## Reproducing these checks

Each check is read-only and prints no credential.
Run from anywhere:

```
sed -n '/^routing:/,/^[a-z]/p' /opt/homebrew/etc/cliproxyapi.conf
strings -a /opt/homebrew/opt/cliproxyapi/bin/cliproxyapi | grep -oiE 'x-cpa-[a-z0-9-]+' | sort -u
codex --help | grep -E 'profile|--config'
no-mistakes axi run --help
quota-axi --provider codex --json
```

The cutover probes, which print codex's resolved header before any request is issued:

```
codex --profile cliproxy exec --skip-git-repo-check --sandbox read-only 'x' < /dev/null | grep -E '^(model|provider|reasoning effort):'
codex --profile cliproxy -c model_reasoning_effort="xhigh" exec --skip-git-repo-check --sandbox read-only 'x' < /dev/null | grep -E '^(model|provider|reasoning effort):'
```

Run them from a trusted directory.
As written they continue into a real request; prefixing `env -u CLIPROXY_API_KEY` stops them at the header, which both avoids spending quota and shows the fail-closed behavior.

Do not read the proxy configuration's `api-keys` block without redacting values; it holds a live client credential.

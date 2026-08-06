# Claude pool route - verification record

Audience: maintainer verification.
This record holds the empirical facts the `claude-pool` worker adapter rests on.
[`docs/configuration.md`](../configuration.md) is the operator owner for the route, and [`bin/fm-claude-pool.sh`](../../bin/fm-claude-pool.sh) owns the exact contract.
[`pool-account-routing.md`](pool-account-routing.md) remains the owner of why account selection cannot live in firstmate; that evidence is not repeated here.

Verified 2026-08-06 on macOS (Darwin 25.5.0) against the local CLIProxyAPI on `127.0.0.1:8317`, Claude Code 2.x, and `curl` 8.x.

## The pool serves real Claude models over the Anthropic contract

`GET /v1/models` returns 25 entries, including `claude-opus-5`, `claude-sonnet-5`, `claude-fable-5`, `claude-opus-4-8`, and `claude-haiku-4-5-20251001` alongside the `gpt-5.*` family.

A minimal `POST /v1/messages` confirms the Anthropic contract end to end, returning an Anthropic-shaped message that names the Claude model:

```json
{"model":"claude-opus-5","type":"message","role":"assistant",
 "content":[{"type":"text","text":"Hi!"}],"stop_reason":"max_tokens",
 "usage":{"input_tokens":6,"output_tokens":4,"service_tier":"standard"}}
```

This is what distinguishes the route from the pre-existing `claude-sol` shell function, which sets `ANTHROPIC_DEFAULT_OPUS_MODEL='gpt-5.6-sol'` and therefore runs an OpenAI model behind the Claude CLI.

## Family validation is necessary, not defensive

The decisive negative result.
The same Anthropic-shaped `/v1/messages` endpoint accepts an OpenAI model and answers **HTTP 200**:

```
gpt-5.6-sol      -> http 200
not-a-real-model -> http 502  {"type":"error","error":{"message":"unknown provider for model not-a-real-model"}}
```

So "the pool answered" proves reachability, not model family.
Only a genuinely unknown id is rejected by the proxy; a real model of the wrong family is served.

The catalog carries the authority needed to tell them apart, so validation reads it rather than guessing from a name prefix:

```json
[{"id":"claude-sonnet-5","object":"model","owned_by":"anthropic"},
 {"id":"gpt-5.6-sol","object":"model","owned_by":"openai"},
 {"id":"claude-opus-5","object":"model","owned_by":"anthropic"}]
```

`/v1/models` also refuses an unauthenticated read (`401`), so one authenticated catalog fetch validates the credential and the model family together, with no request that spends model quota.

## Validation must happen before launch

Both runtime failure modes are slow and opaque at the worker, which is why `fm-spawn.sh` refuses before creating an endpoint rather than letting the worker discover them.

With a credential the pool rejects, the CLI retries and then reports only:

```
Execution error
```

after more than 25 seconds, with no indication that the credential or the pool is at fault.
An unreachable base URL produces the same bare text.

The important half of that result is what does **not** happen: it never answers from the native Claude login.
A broken pool route fails; it does not silently spend the subscription the route exists to preserve.

## The credential cannot come from interactive shell state

`CLIPROXY_API_KEY` is exported from `~/.config/cliproxy/shell.zsh`, which is sourced from `.zshrc` and therefore reaches interactive shells only:

```
clean non-interactive zsh: UNSET
clean interactive zsh:     set
```

A worker launched non-interactively - which is how a remote second mate starts - cannot see it.
This is why the route reads the variable by parsing the file rather than relying on the environment, and why it never sources the file: sourcing an operator's shell configuration would execute arbitrary code as a side effect of a launch.

## The supported credential channel

`claude --help` documents `apiKeyHelper` as an authentication source usable through `--settings`, and a live non-interactive probe confirms the whole route:

```sh
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
  ANTHROPIC_BASE_URL='http://127.0.0.1:8317' \
  claude -p 'Reply with exactly: PROBE-OK' \
    --model claude-opus-5 --settings "{\"apiKeyHelper\":\"$HELPER\"}"
```

```
PROBE-OK
```

The helper receives no argument carrying a value and returns the credential on stdout, so it never enters argv.
`curl -q --config <file>` provides the same property for the catalog fetch: `-q` is the first option so ambient curl configuration is disabled, and the `header = "Authorization: Bearer ..."` line lives in a mode-0600 file inside a mode-0700 private directory.

`--settings` adds settings rather than replacing them, so it does not disturb the per-worktree `.claude/settings.local.json` that `fm-spawn.sh` writes for busy-state reporting.

## The route works from a scrubbed non-interactive environment

This is the remote second-mate condition, and it is the check that distinguishes this route from the interactive `claude-sol` function.
The environment below carries no `CLIPROXY_API_KEY`, no ambient Anthropic credential, and no interactive shell, and the settings payload is the exact one `bin/fm-claude-pool.sh settings-json` emits:

```sh
env -i HOME="$HOME" PATH="$PATH" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
  ANTHROPIC_BASE_URL="$(bin/fm-claude-pool.sh base-url)" \
  claude -p 'Reply with exactly: POOL-ROUTE-OK' \
    --model claude-opus-5 --settings "$(bin/fm-claude-pool.sh settings-json)"
```

```
POOL-ROUTE-OK
```

The emitted payload contains only this script's path, the credential source path, and the variable name:

```json
{"apiKeyHelper":"'<repo>/bin/fm-claude-pool.sh' secret --secret-file '<home>/.config/cliproxy/shell.zsh' --secret-var 'CLIPROXY_API_KEY'"}
```

## Compatibility axes reviewed

`claude-pool` launches the same `claude` executable, so every adapter behavior keyed on the CLI is shared rather than borrowed.

| Axis | Status |
| --- | --- |
| Busy-state signature (`bin/fm-tmux-lib.sh`) | Shares the Claude regex; same TUI |
| Busy adapter (`bin/fm-busy-lib.sh`) | Already `claude*`; matches unchanged |
| Vim-mode recovery (`bin/fm-send.sh`) | Accepts both Claude adapters; same composer quirk |
| Model and effort flags (`bin/fm-spawn.sh`) | Full `low..max` effort range, as for `claude` |
| Claude config store | `CLAUDE_CONFIG_DIR` forwarded identically; credential still comes from the helper |
| Dispatch profile validation (`bin/fm-bootstrap.sh`) | Verified adapter with the Claude effort range |
| Secondmate inheritance (`bin/fm-config-inherit-lib.sh`) | `config/claude-pool` in the declared inheritable set |
| Runtime backends | No backend-specific behavior; the adapter changes only the launch command |
| Own-harness detection (`bin/fm-harness.sh`) | **Not applicable.** Detection answers "which CLI am I" and correctly reports `claude` for a pool-routed agent |
| Primary-session harness set | **Not applicable.** Crew and secondmate launch adapter only; supervision protocols, turn-end guards, and session-lock ancestry are unchanged and continue to match the `claude` process name |

## Reproducing these checks

Each check is read-only apart from two four-token model calls, and none prints a credential.
The credential is written only to a mode-0600 curl config inside a mode-0700 private directory by the existing helper, then removed with that private directory.

```sh
POOL_CURL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-pool-verify.XXXXXX")
chmod 700 "$POOL_CURL_DIR"
(
  umask 077
  bin/fm-claude-pool.sh secret | awk '{
    printf "header = \"Authorization: Bearer %s\"\n", $0
    printf "header = \"x-api-key: %s\"\n", $0
  }' > "$POOL_CURL_DIR/auth.conf"
)
chmod 600 "$POOL_CURL_DIR/auth.conf"

curl -q -sS --config "$POOL_CURL_DIR/auth.conf" http://127.0.0.1:8317/v1/models | jq -r '.data[].id'
curl -q -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8317/v1/models   # 401, unauthenticated
curl -q -sS --config "$POOL_CURL_DIR/auth.conf" -H "anthropic-version: 2023-06-01" -H 'content-type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":4,"messages":[{"role":"user","content":"hi"}]}' \
  http://127.0.0.1:8317/v1/messages | jq '{model, stop_reason}'
rm -f "$POOL_CURL_DIR/auth.conf"
rmdir "$POOL_CURL_DIR"
env -i HOME="$HOME" PATH="$PATH" zsh -c  'echo ${CLIPROXY_API_KEY:-UNSET}'   # UNSET
env -i HOME="$HOME" PATH="$PATH" zsh -ic 'echo ${CLIPROXY_API_KEY:+set}'     # set
```

The route's own decisions, which print no credential:

```sh
bin/fm-claude-pool.sh check --model claude-opus-5    # exit 0
bin/fm-claude-pool.sh check --model gpt-5.6-sol      # exit 5, wrong-family
bin/fm-claude-pool.sh check --model claude-not-real  # exit 4
FM_CLAUDE_POOL_BASE_URL=http://127.0.0.1:59999 bin/fm-claude-pool.sh check --model claude-opus-5  # exit 3
FM_CLAUDE_POOL_SECRET_FILE=/absent bin/fm-claude-pool.sh check --model claude-opus-5              # exit 6
```

`tests/fm-claude-pool.test.sh` is the executable regression owner for all of the above.
It fakes `curl` and `tmux` and pins `--backend tmux`, so it needs no live pool and creates no endpoint.
Its fixture credential is a visibly fake literal; a real pool key must never enter that file.

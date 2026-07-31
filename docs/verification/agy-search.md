# agy-backed `gemini_search` verification

This record captures the active empirical guarantees for the tracked Pi extension at [`.pi/extensions/gemini-search.ts`](../../.pi/extensions/gemini-search.ts).
The public Pi tool name remains `gemini_search`, while the subprocess owner is agy and the companion `web_fetch` tool remains in the same extension.
The tracked [`.pi/settings.json`](../../.pi/settings.json) lists that project-local extension explicitly so Pi resolves it before a user-scoped legacy registration, while auto-discovery deduplicates the same tracked path.
The deterministic loading-order and behavior regression is [`tests/fm-gemini-search-agy.test.sh`](../../tests/fm-gemini-search-agy.test.sh).

## Environment

This pass ran on 2026-07-31 with Pi 0.83.0 and agy 1.1.9.

```sh
$ /opt/homebrew/bin/agy --version
1.1.9

$ node -p "require('/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/package.json').version"
0.83.0
```

The deterministic regression below exercises Pi's installed resource resolver with synthetic tracked and user-scoped registrations.
It proves the tracked extension resolves first and exactly once.

## Authenticated grounded-search smoke

The authenticated smoke used agy's plan mode, sandbox restrictions, structured output, a bounded print timeout, and the low-effort Flash model.
The full JSON schema required `summary`, `queries`, `results`, and `notes`, with each result requiring `title`, `url`, and `snippet`.

```sh
$ SCHEMA='{"type":"object","additionalProperties":false,"required":["summary","queries","results","notes"],"properties":{"summary":{"type":"string"},"queries":{"type":"array","items":{"type":"string"}},"results":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["title","url","snippet"],"properties":{"title":{"type":"string"},"url":{"type":"string"},"snippet":{"type":"string"}}}},"notes":{"type":"array","items":{"type":"string"}}}}'

$ /opt/homebrew/bin/agy \
    --sandbox \
    --mode plan \
    --model gemini-3.6-flash-low \
    --output-format stream-json \
    --json-schema "$SCHEMA" \
    --print-timeout 90s \
    -p 'Use your available internet or Google-search capability to find the official Pi coding agent extensions documentation. Do not read or write workspace files and do not run terminal commands. Return exact source URLs observed from search, including the official documentation URL and repository URL when found. Keep the response compact and match the required JSON schema.' \
  > search.ndjson

$ jq -c 'select(.event=="init") | {model:.init.model,permission_mode:.init.permission_mode,has_search_web:(.init.tools|index("search_web")!=null),schema_required:.init.json_schema.required}' search.ndjson
{"model":"gemini-3.6-flash-low","permission_mode":"request-review","has_search_web":true,"schema_required":["summary","queries","results","notes"]}

$ jq -c 'select(.event=="step_update" and .step_update.step_type=="tool" and .step_update.tool_name=="search_web") | {state:.step_update.state,tool:.step_update.tool_name,query:.step_update.tool_info.parameters.query}' search.ndjson
{"state":"ACTIVE","tool":"search_web","query":"pi coding agent extensions documentation"}
{"state":"DONE","tool":"search_web","query":"pi coding agent extensions documentation"}
{"state":"ACTIVE","tool":"search_web","query":"\"pi-coding-agent\" site:github.com"}
{"state":"DONE","tool":"search_web","query":"\"pi-coding-agent\" site:github.com"}

$ jq -c 'select(.event=="result") | {status:.result.status,queries:.result.structured_output.queries,urls:[.result.structured_output.results[].url]}' search.ndjson
{"status":"SUCCESS","queries":["pi coding agent extensions documentation","\"pi-coding-agent\" site:github.com"],"urls":["https://pi.dev","https://github.com/earendil-works/pi"]}
```

This proves that the installed authenticated agy process exposed and invoked `search_web`, returned the queries it used, and produced source URLs through enforced structured output.
The smoke URLs were not independently validated by this command, so they remain source candidates rather than citeable evidence.
The extension preserves that distinction by assigning unvalidated results medium confidence and telling callers to validate or fetch them before citation.

## Deterministic regression

```sh
$ tests/fm-gemini-search-agy.test.sh
ok - agy command construction, structured parsing, retries, cancellation boundaries, best-effort cleanup, HEAD-to-GET validation fallback, strict cache admission, cache separation, and failure output are deterministic
ok - tracked project settings load the authoritative extension before the configured legacy source without duplicate auto-discovery
ok - TUI rendering strips untrusted terminal controls while preserving trusted theme styling
ok - web_fetch binds and falls back across public DNS answers, blocks non-global ranges and redirect rebinding, propagates cancellation, and retains response-size protections
```

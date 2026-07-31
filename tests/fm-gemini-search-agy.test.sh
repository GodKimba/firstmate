#!/usr/bin/env bash
# Deterministic agy-backed gemini_search integration, ownership, cache, and safety checks.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for agy search extension test"; exit 0; }
command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for agy search extension test"; exit 0; }

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo "skip: installed @earendil-works/pi-coding-agent package not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-gemini-search-agy)
FIXTURE="$TMP_ROOT/fixture"
mkdir -p "$FIXTURE/node_modules/@earendil-works" "$FIXTURE/cache" "$FIXTURE/project/.pi/extensions" "$FIXTURE/agent"
cp "$ROOT/.pi/extensions/gemini-search.ts" "$FIXTURE/gemini-search.ts"
cp "$ROOT/.pi/extensions/gemini-search.ts" "$FIXTURE/project/.pi/extensions/gemini-search.ts"
cp "$ROOT/.pi/settings.json" "$FIXTURE/project/.pi/settings.json"
ln -s "$PI_PACKAGE_DIR" "$FIXTURE/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$FIXTURE/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$FIXTURE/node_modules/typebox"
printf '%s\n' '{"type":"module"}' > "$FIXTURE/package.json"

cat > "$FIXTURE/fake-agy.mjs" <<'JS'
#!/usr/bin/env node
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";

const args = process.argv.slice(2);
appendFileSync(process.env.AGY_FAKE_ARGS, `${JSON.stringify(args)}\n`);
const prompt = args.at(-1) ?? "";
const counts = existsSync(process.env.AGY_FAKE_COUNTS)
  ? JSON.parse(readFileSync(process.env.AGY_FAKE_COUNTS, "utf8"))
  : {};
const key = prompt.includes("RETRY_TEST") ? "retry"
  : prompt.includes("CANCEL_TEST") ? "cancel"
    : prompt.includes("PERMANENT_FAIL") ? "permanent"
      : "other";
counts[key] = (counts[key] ?? 0) + 1;
writeFileSync(process.env.AGY_FAKE_COUNTS, JSON.stringify(counts));

function output(value, code) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
  process.exit(code);
}

if (key === "cancel") {
  process.on("SIGTERM", () => output({ status: "ERROR", response: "", error: "context canceled" }, 1));
  setTimeout(() => output({ status: "SUCCESS", structured_output: { summary: "late", queries: [], results: [], notes: [] } }, 0), 10_000);
} else if (key === "permanent") {
  output({ status: "ERROR", response: "", error: "invalid request for deterministic failure" }, 1);
} else if (key === "retry" && counts.retry === 1) {
  output({ status: "ERROR", response: "", error: "temporarily unavailable" }, 1);
} else {
  output({
    status: "SUCCESS",
    response: "grounded response",
    structured_output: {
      summary: "Grounded summary from search_web.",
      queries: ["official docs RETRY_TEST"],
      results: [{ title: "Official docs", url: "https://example.com/docs", snippet: "Primary documentation." }],
      notes: [],
    },
  }, 0);
}
JS
chmod +x "$FIXTURE/fake-agy.mjs"

cat > "$FIXTURE/legacy.ts" <<'TS'
import { Type } from "typebox";
export default function legacy(pi: any) {
  pi.registerTool({
    name: "gemini_search",
    label: "Legacy Gemini Search",
    description: "legacy",
    parameters: Type.Object({ query: Type.String() }),
    async execute() { return { content: [{ type: "text", text: "legacy" }] }; },
  });
}
TS
printf '{"extensions":[%s]}\n' "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$FIXTURE/legacy.ts")" > "$FIXTURE/agent/settings.json"

PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
EXT="$FIXTURE/gemini-search.ts" \
PROJECT="$FIXTURE/project" \
AGENT_DIR="$FIXTURE/agent" \
PI_AGY_SEARCH_BIN="$FIXTURE/fake-agy.mjs" \
PI_AGY_SEARCH_MODEL="model-default" \
PI_AGY_SEARCH_CACHE_DIR="$FIXTURE/cache" \
PI_AGY_SEARCH_TIMEOUT_MS=2000 \
PI_AGY_SEARCH_MAX_ATTEMPTS=2 \
PI_AGY_SEARCH_RETRY_BASE_DELAY_MS=1 \
PI_AGY_SEARCH_RETRY_JITTER_MS=0 \
AGY_FAKE_ARGS="$FIXTURE/args.log" \
AGY_FAKE_COUNTS="$FIXTURE/counts.json" \
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const extension = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);
const args = extension.buildAgyArgs("PROMPT", "model-a", 2500);
assert.deepEqual(args.slice(0, 5), ["--sandbox", "--mode", "plan", "--output-format", "json"]);
assert.equal(args.includes("--disable-slash-commands"), true);
assert.equal(args.includes("--dangerously-skip-permissions"), false);
assert.equal(args.includes("--approval-mode"), false);
assert.equal(args.includes("--skip-trust"), false);
assert.equal(args[args.indexOf("--print-timeout") + 1], "2500ms");
assert.equal(args[args.indexOf("--model") + 1], "model-a");
assert.equal(args.at(-2), "-p");
assert.equal(args.at(-1), "PROMPT");
const schema = JSON.parse(args[args.indexOf("--json-schema") + 1]);
assert.deepEqual(schema.required, ["summary", "queries", "results", "notes"]);

const parsed = extension.parseAgyCliOutput(JSON.stringify({
  status: "SUCCESS",
  response: "response text",
  structured_output: { summary: "s", queries: ["q"], results: [], notes: [] },
}));
assert.equal(parsed.rawResponseText, "response text");
assert.equal(parsed.parsed.summary, "s");
assert.throws(
  () => extension.parseAgyCliOutput(JSON.stringify({ status: "ERROR", error: "timeout waiting for response" })),
  /timeout waiting for response/,
);
assert.throws(
  () => extension.parseAgyCliOutput(JSON.stringify({ status: "SUCCESS", response: "missing" })),
  /structured_output object/,
);

const baseKey = {
  query: "same",
  limit: 5,
  mode: "search",
  model: "model-a",
  validateUrls: false,
  binary: "/opt/homebrew/bin/agy",
};
assert.equal(extension.cacheKey(baseKey), extension.cacheKey({ ...baseKey }));
assert.notEqual(extension.cacheKey(baseKey), extension.cacheKey({ ...baseKey, model: "model-b" }));
assert.notEqual(extension.cacheKey(baseKey), extension.cacheKey({ ...baseKey, binary: "/custom/agy" }));
assert.notEqual(extension.cacheKey(baseKey), extension.cacheKey({ ...baseKey, validateUrls: true }));

const tools = new Map();
extension.default({ registerTool(tool) { tools.set(tool.name, tool); } });
const search = tools.get("gemini_search");
const webFetch = tools.get("web_fetch");
assert(search);
assert(webFetch);
assert.equal(search.label, "Grounded Search (agy)");
assert.match(search.description, /name is retained for compatibility/);

const updates = [];
const first = await search.execute("call-1", {
  query: "RETRY_TEST official docs",
  limit: 3,
  mode: "search",
  validateUrls: false,
  model: "model-a",
}, undefined, (update) => updates.push(update));
assert.equal(first.details.source, "agy-cli-search-web");
assert.equal(first.details.retryAttempts, 2);
assert.equal(first.details.cached, false);
assert.equal(first.details.confidence, "medium");
assert.equal("queue" in first.details, false);
assert.match(first.content[0].text, /Source candidates \(validate or fetch before citing\)/);
assert.match(first.content[0].text, /URL not fully validated/);
assert.equal(updates[0].details.status, "running");

const countsAfterFirst = JSON.parse(readFileSync(process.env.AGY_FAKE_COUNTS, "utf8"));
assert.equal(countsAfterFirst.retry, 2);
const second = await search.execute("call-2", {
  query: "RETRY_TEST official docs",
  limit: 3,
  mode: "search",
  validateUrls: false,
  model: "model-a",
}, undefined, undefined);
assert.equal(second.details.cached, true);
assert.equal(JSON.parse(readFileSync(process.env.AGY_FAKE_COUNTS, "utf8")).retry, 2);
await search.execute("call-3", {
  query: "RETRY_TEST official docs",
  limit: 3,
  mode: "search",
  validateUrls: false,
  model: "model-a",
  forceRefresh: true,
}, undefined, undefined);
assert.equal(JSON.parse(readFileSync(process.env.AGY_FAKE_COUNTS, "utf8")).retry, 3);

await assert.rejects(
  search.execute("call-4", { query: "PERMANENT_FAIL", validateUrls: false }, undefined, undefined),
  (error) => {
    assert.match(error.message, /agy process failed/);
    assert.match(error.message, /invalid request for deterministic failure/);
    assert.doesNotMatch(error.message, /Gemini CLI/);
    return true;
  },
);

const controller = new AbortController();
const cancellationStarted = Date.now();
const cancellation = search.execute("call-5", { query: "CANCEL_TEST", validateUrls: false }, controller.signal, undefined);
setTimeout(() => controller.abort(), 100);
await assert.rejects(cancellation, /cancelled while agy was running/);
assert(Date.now() - cancellationStarted < 3000);

const originalFetch = globalThis.fetch;
let fetchCalls = 0;
globalThis.fetch = async () => {
  fetchCalls += 1;
  return new Response("", { status: 302, headers: { location: "http://127.0.0.1/private" } });
};
const redirectBlocked = await webFetch.execute("fetch-1", { urls: ["https://1.1.1.1/start"] }, undefined, undefined);
assert.equal(fetchCalls, 1);
assert.match(redirectBlocked.details.pages[0].error, /local\/private host|private IP address/);

globalThis.fetch = async () => new Response("body", {
  status: 200,
  headers: { "content-length": "2000000", "content-type": "text/plain" },
});
const sizeBlocked = await webFetch.execute("fetch-2", { urls: ["https://1.1.1.1/large"] }, undefined, undefined);
assert.match(sizeBlocked.details.pages[0].error, /exceeds 1500000 byte safety limit/);
globalThis.fetch = originalFetch;

const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ SettingsManager }, { DefaultPackageManager }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/core/settings-manager.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/core/package-manager.js`).href),
]);
const settingsManager = SettingsManager.create(process.env.PROJECT, process.env.AGENT_DIR, { projectTrusted: true });
const manager = new DefaultPackageManager({ cwd: process.env.PROJECT, agentDir: process.env.AGENT_DIR, settingsManager });
const resolved = await manager.resolve();
const enabled = resolved.extensions.filter((entry) => entry.enabled).map((entry) => entry.path);
const tracked = `${process.env.PROJECT}/.pi/extensions/gemini-search.ts`;
const legacy = process.env.PROJECT.replace(/\/project$/, "/legacy.ts");
assert.equal(enabled[0], tracked);
assert.equal(enabled.filter((path) => path === tracked).length, 1);
assert(enabled.indexOf(legacy) > enabled.indexOf(tracked));

const loggedArgs = readFileSync(process.env.AGY_FAKE_ARGS, "utf8").trim().split("\n").map(JSON.parse);
const retryArgs = loggedArgs.find((entry) => entry.at(-1).includes("RETRY_TEST"));
assert(retryArgs);
assert.equal(retryArgs.includes("--sandbox"), true);
assert.equal(retryArgs[retryArgs.indexOf("--mode") + 1], "plan");
assert.equal(retryArgs[retryArgs.indexOf("--output-format") + 1], "json");
assert.match(retryArgs.at(-1), /Use the search_web tool/);

console.log("ok - agy command construction, structured parsing, retries, cancellation, cache separation, and failure output are deterministic");
console.log("ok - tracked project settings load the authoritative extension before the configured legacy source without duplicate auto-discovery");
console.log("ok - web_fetch retains private-redirect and response-size protections");
JS

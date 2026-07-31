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
    : prompt.includes("STRICT_DOCS") ? "strict_docs"
      : prompt.includes("STRICT_SOURCE") ? "strict_source"
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
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
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

function nat64Address(ipv4) {
  const bytes = ipv4.split(".").map(Number);
  const high = ((bytes[0] << 8) | bytes[1]).toString(16);
  const low = ((bytes[2] << 8) | bytes[3]).toString(16);
  return `64:ff9b::${high}:${low}`;
}

for (const address of ["93.184.216.34", "192.0.0.9", "192.0.0.10"]) {
  const publicIpv4 = { address, family: 4 };
  assert.deepEqual(extension.canonicalPublicIp(address), publicIpv4);
  assert.deepEqual(extension.canonicalPublicIp(`::ffff:${address}`), publicIpv4);
  assert.deepEqual(extension.canonicalPublicIp(nat64Address(address)), {
    address: nat64Address(address),
    family: 6,
  });
}

for (const address of [
  "0.1.2.3",
  "10.0.0.1",
  "100.64.0.1",
  "127.0.0.1",
  "169.254.169.254",
  "172.16.0.1",
  "192.0.0.1",
  "192.0.2.1",
  "192.88.99.1",
  "192.168.0.1",
  "198.18.0.1",
  "198.51.100.1",
  "203.0.113.1",
  "224.0.0.1",
  "240.0.0.1",
  "255.255.255.255",
]) {
  assert.throws(() => extension.canonicalPublicIp(address), /private or non-global IP address/);
  assert.throws(() => extension.canonicalPublicIp(`::ffff:${address}`), /private or non-global IP address/);
  assert.throws(() => extension.canonicalPublicIp(nat64Address(address)), /private or non-global IP address/);
}

for (const [address, canonical] of [
  ["2001:1::1", "2001:1::1"],
  ["2001:1::2", "2001:1::2"],
  ["2001:1::3", "2001:1::3"],
  ["2001:3::", "2001:3::"],
  ["2001:3:ffff:ffff:ffff:ffff:ffff:ffff", "2001:3:ffff:ffff:ffff:ffff:ffff:ffff"],
  ["2001:4:112::", "2001:4:112::"],
  ["2001:4:112:ffff:ffff:ffff:ffff:ffff", "2001:4:112:ffff:ffff:ffff:ffff:ffff"],
  ["2001:20::", "2001:20::"],
  ["2001:2f:ffff:ffff:ffff:ffff:ffff:ffff", "2001:2f:ffff:ffff:ffff:ffff:ffff:ffff"],
  ["2001:30::", "2001:30::"],
  ["2001:3f:ffff:ffff:ffff:ffff:ffff:ffff", "2001:3f:ffff:ffff:ffff:ffff:ffff:ffff"],
  ["2606:4700:4700:0:0:0:0:1111", "2606:4700:4700::1111"],
  ["2620:4f:8000::1", "2620:4f:8000::1"],
]) {
  assert.deepEqual(extension.canonicalPublicIp(address), { address: canonical, family: 6 });
}

for (const address of [
  "::",
  "::1",
  "64:ff9a:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
  "64:ff9b:0:1::",
  "64:ff9b:1::",
  "64:ff9b:1:ffff:ffff:ffff:ffff:ffff",
  "100::1",
  "100:ffff:ffff:ffff::ffff",
  "100:0:0:1::",
  "100:0:0:1:ffff:ffff:ffff:ffff",
  "2001::1",
  "2001:1::",
  "2001:1::4",
  "2001:2::",
  "2001:2:0:ffff:ffff:ffff:ffff:ffff",
  "2001:2:ffff:ffff:ffff:ffff:ffff:ffff",
  "2001:4:111:ffff:ffff:ffff:ffff:ffff",
  "2001:4:113::",
  "2001:10::",
  "2001:1f:ffff:ffff:ffff:ffff:ffff:ffff",
  "2001:40::",
  "2001:db8::1",
  "2002:7f00:1::",
  "3fff::1",
  "5f00::1",
  "5f00:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
  "fc00::1",
  "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
  "fe80::1",
  "febf::1",
  "ff02::1",
]) {
  assert.throws(() => extension.canonicalPublicIp(address), /private or non-global IP address/);
}
const publicIpv4 = extension.canonicalPublicIp("93.184.216.34");
const pinnedOptions = extension.buildPinnedRequestOptions(
  new URL("https://source.example:8443/docs?q=one"),
  publicIpv4,
  { method: "GET", headers: { accept: "text/plain" } },
);
assert.equal(pinnedOptions.hostname, "93.184.216.34");
assert.equal(pinnedOptions.family, 4);
assert.equal(pinnedOptions.servername, "source.example");
assert.equal(pinnedOptions.headers.host, "source.example:8443");
assert.equal(pinnedOptions.path, "/docs?q=one");

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

function toolsWithSearchDependencies(dependencies) {
  const registered = new Map();
  extension.default({ registerTool(tool) { registered.set(tool.name, tool); } }, undefined, dependencies);
  return registered;
}

async function settlesWithin(promise, label) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} did not settle`)), 250);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function fakeChild({ stdout, error, code = 0 }) {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.kill = () => true;
  queueMicrotask(() => {
    if (stdout) child.stdout.emit("data", Buffer.from(stdout));
    if (error) child.emit("error", error);
    else child.emit("close", code, null);
  });
  return child;
}

const cachedFixtureKey = extension.cacheKey({
  query: "RETRY_TEST official docs",
  limit: 3,
  mode: "search",
  model: "model-a",
  validateUrls: false,
  binary: process.env.PI_AGY_SEARCH_BIN,
});
const cachedFixture = JSON.parse(readFileSync(`${process.env.PI_AGY_SEARCH_CACHE_DIR}/${cachedFixtureKey}.json`, "utf8"));
const cacheReadStarted = Promise.withResolvers();
const releaseCacheRead = Promise.withResolvers();
let cacheRaceSpawns = 0;
const cacheRaceSearch = toolsWithSearchDependencies({
  async readCache() {
    cacheReadStarted.resolve();
    await releaseCacheRead.promise;
    return cachedFixture;
  },
  spawnProcess() {
    cacheRaceSpawns += 1;
    throw new Error("cache-race search must not spawn");
  },
}).get("gemini_search");
const cacheRaceController = new AbortController();
const cacheRaceResult = cacheRaceSearch.execute(
  "cache-race",
  { query: "RETRY_TEST official docs", limit: 3, mode: "search", validateUrls: false, model: "model-a" },
  cacheRaceController.signal,
  undefined,
);
await cacheReadStarted.promise;
cacheRaceController.abort();
releaseCacheRead.resolve();
await assert.rejects(cacheRaceResult, /cancelled during cache access/);
assert.equal(cacheRaceSpawns, 0);

const temporaryDirectoryStarted = Promise.withResolvers();
const releaseTemporaryDirectory = Promise.withResolvers();
const removedTemporaryDirectories = [];
let temporaryDirectoryRaceSpawns = 0;
const temporaryDirectoryRaceSearch = toolsWithSearchDependencies({
  async createTemporaryDirectory() {
    temporaryDirectoryStarted.resolve();
    await releaseTemporaryDirectory.promise;
    return "/virtual/pi-agy-search-cancelled";
  },
  async removeTemporaryDirectory(path) {
    removedTemporaryDirectories.push(path);
  },
  spawnProcess() {
    temporaryDirectoryRaceSpawns += 1;
    throw new Error("temporary-directory race search must not spawn");
  },
}).get("gemini_search");
const temporaryDirectoryRaceController = new AbortController();
const temporaryDirectoryRaceResult = temporaryDirectoryRaceSearch.execute(
  "temporary-directory-race",
  { query: "CANCEL_TEST temporary-directory setup", validateUrls: false, forceRefresh: true },
  temporaryDirectoryRaceController.signal,
  undefined,
);
await temporaryDirectoryStarted.promise;
temporaryDirectoryRaceController.abort();
releaseTemporaryDirectory.resolve();
await assert.rejects(temporaryDirectoryRaceResult, /cancelled during agy temporary-directory setup/);
assert.deepEqual(removedTemporaryDirectories, ["/virtual/pi-agy-search-cancelled"]);
assert.equal(temporaryDirectoryRaceSpawns, 0);

const cleanupOutput = JSON.stringify({
  status: "SUCCESS",
  response: "cleanup success",
  structured_output: {
    summary: "cleanup success",
    queries: [],
    results: [{ title: "Cleanup source", url: "https://example.com/cleanup", snippet: "source" }],
    notes: [],
  },
});
const cleanupAttempts = [];
const cleanupCloseSearch = toolsWithSearchDependencies({
  async createTemporaryDirectory() { return "/virtual/pi-agy-search-cleanup-close"; },
  async removeTemporaryDirectory(path) {
    cleanupAttempts.push(path);
    throw new Error("cleanup close rejection");
  },
  async writeCache() {},
  spawnProcess() { return fakeChild({ stdout: cleanupOutput }); },
}).get("gemini_search");
const cleanupCloseResult = await settlesWithin(cleanupCloseSearch.execute(
  "cleanup-close",
  { query: "CLEANUP_CLOSE", validateUrls: false, forceRefresh: true },
  undefined,
  undefined,
), "agy close after cleanup rejection");
assert.equal(cleanupCloseResult.details.summary, "cleanup success");

const cleanupErrorSearch = toolsWithSearchDependencies({
  async createTemporaryDirectory() { return "/virtual/pi-agy-search-cleanup-error"; },
  async removeTemporaryDirectory(path) {
    cleanupAttempts.push(path);
    throw new Error("cleanup error rejection");
  },
  spawnProcess() { return fakeChild({ error: new Error("primary child error") }); },
}).get("gemini_search");
await assert.rejects(
  settlesWithin(cleanupErrorSearch.execute(
    "cleanup-error",
    { query: "CLEANUP_ERROR", validateUrls: false, forceRefresh: true },
    undefined,
    undefined,
  ), "agy error after cleanup rejection"),
  /primary child error/,
);

const cleanupSpawnSearch = toolsWithSearchDependencies({
  async createTemporaryDirectory() { return "/virtual/pi-agy-search-cleanup-spawn"; },
  async removeTemporaryDirectory(path) {
    cleanupAttempts.push(path);
    throw new Error("cleanup spawn rejection");
  },
  spawnProcess() { throw new Error("primary spawn error"); },
}).get("gemini_search");
await assert.rejects(
  settlesWithin(cleanupSpawnSearch.execute(
    "cleanup-spawn",
    { query: "CLEANUP_SPAWN", validateUrls: false, forceRefresh: true },
    undefined,
    undefined,
  ), "agy spawn throw after cleanup rejection"),
  /primary spawn error/,
);
assert.deepEqual(cleanupAttempts, [
  "/virtual/pi-agy-search-cleanup-close",
  "/virtual/pi-agy-search-cleanup-error",
  "/virtual/pi-agy-search-cleanup-spawn",
]);

await search.execute("call-3", {
  query: "RETRY_TEST official docs",
  limit: 3,
  mode: "search",
  validateUrls: false,
  model: "model-a",
  forceRefresh: true,
}, undefined, undefined);
assert.equal(JSON.parse(readFileSync(process.env.AGY_FAKE_COUNTS, "utf8")).retry, 3);

for (const [query, mode, countKey] of [
  ["STRICT_DOCS", "docs", "strict_docs"],
  ["STRICT_SOURCE", "source-finder", "strict_source"],
]) {
  const strictFirst = await search.execute(`strict-${mode}-1`, { query, mode, validateUrls: false }, undefined, undefined);
  const strictSecond = await search.execute(`strict-${mode}-2`, { query, mode, validateUrls: false }, undefined, undefined);
  assert.equal(strictFirst.details.confidence, "medium");
  assert.equal(strictFirst.details.cacheWritten, false);
  assert.equal(strictSecond.details.cached, false);
  assert.match(strictSecond.content[0].text, /No validated citeable results found/);
  assert.equal(JSON.parse(readFileSync(process.env.AGY_FAKE_COUNTS, "utf8"))[countKey], 2);
}

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

const hostileTerminalText = "visible\x1b]52;c;clipboard\x07\x1b[2J\x9b31m\rhidden";
const trustedThemePrefix = "\x1b[32m";
const testTheme = {
  fg(_color, value) { return `${trustedThemePrefix}${value}\x1b[39m`; },
  bold(value) { return `\x1b[1m${value}\x1b[22m`; },
};
function renderText(component) {
  return component.render(320).join("\n");
}
function assertNoHostileTerminalSequences(value) {
  assert.doesNotMatch(value, /\x1b\]52|\x1b\[2J|\x9b|\x07/);
}
const hostileCall = renderText(search.renderCall({ query: hostileTerminalText }, testTheme));
const hostileDetails = {
  query: hostileTerminalText,
  limit: 1,
  mode: "search",
  cached: true,
  validateUrls: true,
  status: "done",
  cacheWritten: true,
  cacheExpiresAt: hostileTerminalText,
  confidence: "high",
  source: "agy-cli-search-web",
  binary: hostileTerminalText,
  model: hostileTerminalText,
  stderr: hostileTerminalText,
  durationMs: 10,
  retryAttempts: 1,
  summary: hostileTerminalText,
  queries: [hostileTerminalText],
  results: [{
    title: hostileTerminalText,
    url: `https://source.example/${hostileTerminalText}`,
    snippet: hostileTerminalText,
    source: "agy-search-web",
    warning: hostileTerminalText,
    confidence: "high",
    validation: {
      ok: true,
      status: 200,
      finalUrl: `https://final.example/${hostileTerminalText}`,
      contentType: hostileTerminalText,
      method: "GET",
      quality: "high",
      error: hostileTerminalText,
    },
  }],
  notes: [hostileTerminalText],
  rawResponseText: hostileTerminalText,
};
const hostileCollapsed = renderText(search.renderResult(
  { content: [{ type: "text", text: hostileTerminalText }], details: hostileDetails },
  { expanded: false },
  testTheme,
));
const hostileExpanded = renderText(search.renderResult(
  { content: [{ type: "text", text: hostileTerminalText }], details: hostileDetails },
  { expanded: true },
  testTheme,
));
const hostileFallback = renderText(search.renderResult(
  { content: [{ type: "text", text: hostileTerminalText }] },
  {},
  testTheme,
));
for (const rendered of [hostileCall, hostileCollapsed, hostileExpanded, hostileFallback]) {
  assertNoHostileTerminalSequences(rendered);
  assert.match(rendered, /visible/);
}
assert.match(hostileCall, /\x1b\[32m/);
assert.match(hostileExpanded, /\x1b\[32m/);

function toolsWithNetwork(network) {
  const registered = new Map();
  extension.default({ registerTool(tool) { registered.set(tool.name, tool); } }, network);
  return registered;
}

let rebindLookups = 0;
let boundRequests = 0;
const reboundNetwork = {
  async lookupHost(hostname) {
    assert.equal(hostname, "rebind.example");
    rebindLookups += 1;
    return [{ address: rebindLookups === 1 ? "93.184.216.34" : "127.0.0.1", family: 4 }];
  },
  async requestAddress(url, address) {
    boundRequests += 1;
    assert.equal(url.hostname, "rebind.example");
    assert.equal(address.address, "93.184.216.34");
    return new Response("bound body", { status: 200, headers: { "content-type": "text/plain" } });
  },
};
const reboundFetch = toolsWithNetwork(reboundNetwork).get("web_fetch");
const reboundResult = await reboundFetch.execute("fetch-bound", { urls: ["https://rebind.example/start"] }, undefined, undefined);
assert.equal(reboundResult.details.pages[0].text, "bound body");
assert.equal(rebindLookups, 1);
assert.equal(boundRequests, 1);

const fallbackAttempts = [];
const timedOutAddresses = [];
const fallbackNetwork = {
  addressAttemptTimeoutMs: 5,
  async lookupHost(hostname) {
    assert.equal(hostname, "fallback.example");
    return [
      { address: "93.184.216.34", family: 4 },
      { address: "1.1.1.1", family: 4 },
      { address: "8.8.8.8", family: 4 },
    ];
  },
  async requestAddress(_url, address, _init, signal) {
    fallbackAttempts.push(address.address);
    if (address.address === "93.184.216.34") throw new Error("first address unreachable");
    if (address.address === "1.1.1.1") {
      return new Promise((_resolve, reject) => {
        const rejectTimedOut = () => {
          timedOutAddresses.push(address.address);
          reject(new Error("second address cancelled"));
        };
        signal.addEventListener("abort", rejectTimedOut, { once: true });
        if (signal.aborted) rejectTimedOut();
      });
    }
    return new Response("fallback body", { status: 200, headers: { "content-type": "text/plain" } });
  },
};
const fallbackFetch = toolsWithNetwork(fallbackNetwork).get("web_fetch");
const fallbackResult = await fallbackFetch.execute("fetch-fallback", { urls: ["https://fallback.example/start"] }, undefined, undefined);
assert.deepEqual(fallbackAttempts, ["93.184.216.34", "1.1.1.1", "8.8.8.8"]);
assert.deepEqual(timedOutAddresses, ["1.1.1.1"]);
assert.equal(fallbackResult.details.pages[0].text, "fallback body");

const redirectRequests = [];
const redirectNetwork = {
  async lookupHost(hostname) {
    return hostname === "public.example"
      ? [{ address: "93.184.216.34", family: 4 }]
      : [{ address: "::ffff:169.254.169.254", family: 6 }];
  },
  async requestAddress(url, address) {
    redirectRequests.push([url.toString(), address.address]);
    return new Response("", { status: 302, headers: { location: "http://metadata.example/latest" } });
  },
};
const redirectFetch = toolsWithNetwork(redirectNetwork).get("web_fetch");
const redirectBlocked = await redirectFetch.execute("fetch-redirect", { urls: ["https://public.example/start"] }, undefined, undefined);
assert.equal(redirectRequests.length, 1);
assert.match(redirectBlocked.details.pages[0].error, /private or non-global IP address/);

const sizeNetwork = {
  async lookupHost() { return [{ address: "93.184.216.34", family: 4 }]; },
  async requestAddress() {
    return new Response("body", {
      status: 200,
      headers: { "content-length": "2000000", "content-type": "text/plain" },
    });
  },
};
const sizeFetch = toolsWithNetwork(sizeNetwork).get("web_fetch");
const sizeBlocked = await sizeFetch.execute("fetch-size", { urls: ["https://large.example/file"] }, undefined, undefined);
assert.match(sizeBlocked.details.pages[0].error, /exceeds 1500000 byte safety limit/);

const hostilePageNetwork = {
  async lookupHost() { return [{ address: "93.184.216.34", family: 4 }]; },
  async requestAddress() {
    return new Response(`<html><title>${hostileTerminalText}</title><body>${hostileTerminalText}</body></html>`, {
      status: 200,
      headers: { "content-type": "text/html" },
    });
  },
};
const hostilePageFetch = toolsWithNetwork(hostilePageNetwork).get("web_fetch");
const hostilePageResult = await hostilePageFetch.execute("fetch-hostile-page", { urls: ["https://page.example/content"] }, undefined, undefined);
assertNoHostileTerminalSequences(hostilePageResult.content[0].text);
assert.match(hostilePageResult.content[0].text, /visible/);

const requestStarted = Promise.withResolvers();
const cancellationRequests = [];
const cancellationNetwork = {
  async lookupHost(hostname) {
    return [{ address: hostname === "first.example" ? "93.184.216.34" : "1.1.1.1", family: 4 }];
  },
  requestAddress(url, _address, _init, signal) {
    cancellationRequests.push(url.hostname);
    requestStarted.resolve();
    return new Promise((_resolve, reject) => {
      const rejectCancelled = () => reject(new Error("transport cancelled"));
      signal.addEventListener("abort", rejectCancelled, { once: true });
      if (signal.aborted) rejectCancelled();
    });
  },
};
const cancellationFetch = toolsWithNetwork(cancellationNetwork).get("web_fetch");
const fetchController = new AbortController();
const cancelledFetch = cancellationFetch.execute("fetch-cancel", {
  urls: ["https://first.example/slow", "https://second.example/never"],
}, fetchController.signal, undefined);
await requestStarted.promise;
fetchController.abort();
await assert.rejects(cancelledFetch, /web_fetch cancelled/);
assert.deepEqual(cancellationRequests, ["first.example"]);

const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ SettingsManager }, { DefaultPackageManager }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/core/settings-manager.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/core/package-manager.js`).href),
]);
const settingsManager = SettingsManager.create(process.env.PROJECT, process.env.AGENT_DIR, { projectTrusted: true });
const manager = new DefaultPackageManager({ cwd: process.env.PROJECT, agentDir: process.env.AGENT_DIR, settingsManager });
const resolved = await manager.resolve();
const enabled = resolved.extensions.filter((entry) => entry.enabled).map((entry) => entry.path);
const tracked = resolve(process.env.PROJECT, ".pi/extensions/gemini-search.ts");
const legacy = resolve(process.env.PROJECT, "../legacy.ts");
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

console.log("ok - agy command construction, structured parsing, retries, cancellation boundaries, best-effort cleanup, strict cache admission, cache separation, and failure output are deterministic");
console.log("ok - tracked project settings load the authoritative extension before the configured legacy source without duplicate auto-discovery");
console.log("ok - TUI rendering strips untrusted terminal controls while preserving trusted theme styling");
console.log("ok - web_fetch binds and falls back across public DNS answers, blocks non-global ranges and redirect rebinding, propagates cancellation, and retains response-size protections");
JS

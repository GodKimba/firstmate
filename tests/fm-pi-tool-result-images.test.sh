#!/usr/bin/env bash
# Pi primary tool-result image normalization and OpenAI Codex request regression.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-tool-result-images)
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
PI_AI_SHARED="$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai/dist/api/openai-responses-shared.js"
[ -f "$PI_AI_SHARED" ] || { echo "skip: installed Pi request converter not found"; exit 0; }

mkdir -p "$TMP_ROOT/state"
FM_STATE_OVERRIDE="$TMP_ROOT/state" \
PI_AI_SHARED="$PI_AI_SHARED" \
TURNEND_EXT="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" \
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const { convertResponsesMessages } = await import(pathToFileURL(process.env.PI_AI_SHARED).href);

const handlers = new Map();
const pi = {
  on(name, handler) {
    handlers.set(name, handler);
  },
};
const extension = await import(`${pathToFileURL(process.env.TURNEND_EXT).href}?test=${Date.now()}`);
extension.default(pi);
const normalizeToolResult = handlers.get("tool_result");
assert.equal(typeof normalizeToolResult, "function");

const model = {
  provider: "openai-codex",
  api: "openai-codex-responses",
  id: "gpt-test",
  input: ["text", "image"],
};
const tinyPng = "iVBORw0KGgo=";
const text = { type: "text", text: "attachment" };

function requestInput(content) {
  const context = {
    systemPrompt: "",
    tools: [],
    messages: [
      {
        role: "assistant",
        content: [{ type: "toolCall", id: "call_1|fc_1", name: "gaia_kanban_read_attachment", arguments: {} }],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "toolUse",
        timestamp: 1,
      },
      {
        role: "toolResult",
        toolCallId: "call_1|fc_1",
        toolName: "gaia_kanban_read_attachment",
        content,
        isError: false,
        timestamp: 2,
      },
    ],
  };
  return convertResponsesMessages(model, context, new Set(["openai-codex"]), { includeSystemPrompt: false });
}

function imageUrl(input) {
  return input[1].output[1].image_url;
}

const gaiaShape = [
  text,
  { type: "image", source: { type: "base64", mediaType: "image/png", data: tinyPng } },
];
assert.equal(imageUrl(requestInput(gaiaShape)), "data:undefined;base64,undefined");

const gaiaEvent = {
  toolName: "gaia_kanban_read_attachment",
  content: gaiaShape,
  details: { attachment: "preserved" },
  isError: false,
};
const patch = normalizeToolResult(gaiaEvent);
assert.deepEqual(Object.keys(patch).sort(), ["content", "isError"]);
assert.strictEqual(patch.content[0], text);
assert.deepEqual(patch.content[1], { type: "image", mimeType: "image/png", data: tinyPng });
assert.equal(patch.isError, false);
assert.equal(imageUrl(requestInput(patch.content)), `data:image/png;base64,${tinyPng}`);

const canonicalImage = { type: "image", mimeType: "image/png", data: tinyPng };
const canonicalContent = [text, canonicalImage];
assert.equal(normalizeToolResult({ content: canonicalContent, isError: false }), undefined);
assert.strictEqual(canonicalContent[1], canonicalImage);
assert.equal(imageUrl(requestInput(canonicalContent)), `data:image/png;base64,${tinyPng}`);

const textOnly = [{ type: "text", text: "plain tool output" }];
assert.equal(normalizeToolResult({ content: textOnly, isError: false }), undefined);
assert.equal(requestInput(textOnly)[1].output, "plain tool output");

for (const malformed of [
  { type: "image", source: { type: "base64", mediaType: "image/svg+xml", data: tinyPng } },
  { type: "image", source: { type: "base64", mediaType: "image/png", data: "not-base64" } },
  { type: "image", source: { type: "url", url: "https://example.invalid/image.png" } },
  { type: "image", mimeType: undefined, data: tinyPng },
]) {
  const malformedPatch = normalizeToolResult({ content: [text, malformed], details: { untouched: true }, isError: false });
  assert.equal(malformedPatch.isError, true);
  assert.equal(malformedPatch.content[1].type, "text");
  assert.match(malformedPatch.content[1].text, /Firstmate Pi image normalization error/);
  assert.equal(requestInput(malformedPatch.content)[1].output.includes("normalization error"), true);
}

const terminalResults = [];
for (const terminal of ["WezTerm", "Apple_Terminal", "iTerm.app", undefined]) {
  if (terminal === undefined) delete process.env.TERM_PROGRAM;
  else process.env.TERM_PROGRAM = terminal;
  const result = normalizeToolResult({ content: gaiaShape, isError: false });
  terminalResults.push(JSON.stringify(result));
}
assert.equal(new Set(terminalResults).size, 1);

console.log("ok - Pi primary normalizes Gaia source images before OpenAI Codex request construction");
console.log("ok - canonical images, text results, malformed images, and terminal independence are covered");
JS

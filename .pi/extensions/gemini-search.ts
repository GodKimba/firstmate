import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Container, Spacer, Text } from "@earendil-works/pi-tui";
import { Type, type Static } from "typebox";
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { lookup } from "node:dns/promises";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { isIP } from "node:net";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

const MAX_RESULTS = 8;
const DEFAULT_LIMIT = 5;
const SEARCH_MODES = ["search", "research", "docs", "comparison", "source-finder"] as const;
const DEFAULT_TIMEOUT_MS = 90_000;
const MAX_CAPTURE_BYTES = 1024 * 1024;
const AGY_BINARY = process.env.PI_AGY_SEARCH_BIN?.trim() || "agy";
const AGY_DEFAULT_MODEL = process.env.PI_AGY_SEARCH_MODEL?.trim();
const TIMEOUT_MS = Number.parseInt(process.env.PI_AGY_SEARCH_TIMEOUT_MS || "", 10) || DEFAULT_TIMEOUT_MS;
const DEFAULT_MAX_AGY_ATTEMPTS = 3;
const MAX_AGY_ATTEMPTS = Math.max(
  1,
  Number.parseInt(process.env.PI_AGY_SEARCH_MAX_ATTEMPTS || "", 10) || DEFAULT_MAX_AGY_ATTEMPTS,
);
const AGY_RETRY_BASE_DELAY_MS = Number.parseInt(process.env.PI_AGY_SEARCH_RETRY_BASE_DELAY_MS || "", 10) || 1_500;
const parsedRetryJitterMs = Number.parseInt(process.env.PI_AGY_SEARCH_RETRY_JITTER_MS || "", 10);
const AGY_RETRY_JITTER_MS = Number.isFinite(parsedRetryJitterMs) ? Math.max(0, parsedRetryJitterMs) : 400;
const CACHE_DIR = process.env.PI_AGY_SEARCH_CACHE_DIR?.trim()
  || join(process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent"), "cache", "agy-search");
const CACHE_VERSION = 4;
const AGY_RESULT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["summary", "queries", "results", "notes"],
  properties: {
    summary: { type: "string" },
    queries: { type: "array", items: { type: "string" } },
    results: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["title", "url", "snippet"],
        properties: {
          title: { type: "string" },
          url: { type: "string" },
          snippet: { type: "string" },
        },
      },
    },
    notes: { type: "array", items: { type: "string" } },
  },
} as const;
const LOW_CONFIDENCE_CACHE_TTL_MS = 30 * 60 * 1000;
const MAX_DISPLAY_SUMMARY_CHARS = 220;
const MAX_DISPLAY_SNIPPET_CHARS = 200;
const MAX_DISPLAY_NOTE_CHARS = 120;
const MAX_DISPLAY_NOTES = 2;
const WEB_FETCH_USER_AGENT = "PiWebFetch/1.0 (+https://pi.dev)";
const MAX_FETCH_URLS = 6;
const DEFAULT_FETCH_CHARS_PER_URL = 12_000;
const MAX_FETCH_CHARS_PER_URL = 30_000;
const MAX_FETCH_BYTES = 1_500_000;
const WEB_FETCH_TIMEOUT_MS = 20_000;
const URL_VALIDATION_TIMEOUT_MS = 8_000;
const MAX_REDIRECTS = 5;
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

const GeminiSearchParams = Type.Object({
  query: Type.String({ description: "Search query for agy's grounded web-search capability." }),
  limit: Type.Optional(Type.Number({ description: `Maximum normalized results, 1-${MAX_RESULTS}. Defaults to ${DEFAULT_LIMIT}.` })),
  mode: Type.Optional(
    Type.Union([
      Type.Literal("search"),
      Type.Literal("research"),
      Type.Literal("docs"),
      Type.Literal("comparison"),
      Type.Literal("source-finder"),
    ], { description: "Search style: search, research, docs, comparison, or source-finder." }),
  ),
  forceRefresh: Type.Optional(Type.Boolean({ description: "Bypass the local cache and force a fresh agy search." })),
  validateUrls: Type.Optional(Type.Boolean({ description: "Lightly validate result URLs with HTTP HEAD/GET and record final status/final URL. Defaults to true for docs/source-finder, false otherwise." })),
  model: Type.Optional(Type.String({ description: "Optional agy model override for this search, e.g. gemini-3.6-flash-low. Defaults to PI_AGY_SEARCH_MODEL or agy's default model." })),
});

const WebFetchParams = Type.Object({
  urls: Type.Array(Type.String({ description: "HTTP(S) URL to fetch." }), {
    minItems: 1,
    maxItems: MAX_FETCH_URLS,
    description: `URLs to fetch, max ${MAX_FETCH_URLS}.`,
  }),
  maxCharsPerUrl: Type.Optional(Type.Number({ description: `Maximum cleaned characters per URL, 1-${MAX_FETCH_CHARS_PER_URL}. Defaults to ${DEFAULT_FETCH_CHARS_PER_URL}.` })),
});

type GeminiSearchInput = Static<typeof GeminiSearchParams>;
type WebFetchInput = Static<typeof WebFetchParams>;

type AgyCliJsonOutput = {
  status?: unknown;
  response?: unknown;
  error?: unknown;
  structured_output?: unknown;
  duration_seconds?: unknown;
  num_turns?: unknown;
  usage?: unknown;
};

type ParsedAgyResult = {
  summary?: unknown;
  queries?: unknown;
  results?: unknown;
  notes?: unknown;
};

type SearchMode = typeof SEARCH_MODES[number];

type UrlQuality = "high" | "blocked" | "generic_homepage" | "redirect_suspicious" | "not_found" | "private_blocked" | "invalid";

type SearchConfidence = "high" | "medium" | "low";

type UrlValidation = {
  ok: boolean;
  status?: number;
  finalUrl?: string;
  contentType?: string;
  method?: "HEAD" | "GET";
  quality: UrlQuality;
  error?: string;
};

type NormalizedResult = {
  title: string;
  url: string;
  snippet: string;
  source: "agy-search-web";
  warning?: string;
  validation?: UrlValidation;
  confidence?: SearchConfidence;
};

type NormalizedSearch = {
  summary: string;
  queries: string[];
  results: NormalizedResult[];
  notes: string[];
  rawResponseText: string;
};

type GeminiSearchStatus = "running" | "validating" | "done";

type GeminiSearchDetails = NormalizedSearch & {
  query: string;
  limit: number;
  mode: SearchMode;
  cached: boolean;
  validateUrls: boolean;
  status?: GeminiSearchStatus;
  cacheWritten?: boolean;
  cacheExpiresAt?: string;
  confidence?: SearchConfidence;
  source: "agy-cli-search-web";
  binary: string;
  model: string;
  stderr?: string;
  durationMs?: number;
  retryAttempts?: number;
};

type PiTheme = {
  fg: (color: string, value: string) => string;
  bold: (value: string) => string;
};

type ProcessResult = {
  code: number | null;
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
  durationMs: number;
  attempts?: number;
};

type SearchCacheEntry = {
  version: number;
  createdAt: number;
  expiresAt: number;
  normalized: NormalizedSearch;
  stderr: string;
  durationMs: number;
  confidence: SearchConfidence;
};

type FetchedPage = {
  originalUrl: string;
  finalUrl?: string;
  status?: number;
  ok: boolean;
  contentType?: string;
  title?: string;
  text: string;
  truncated: boolean;
  byteTruncated?: boolean;
  error?: string;
};

function clampLimit(value: number | undefined): number {
  if (!Number.isFinite(value)) return DEFAULT_LIMIT;
  return Math.max(1, Math.min(MAX_RESULTS, Math.floor(value ?? DEFAULT_LIMIT)));
}

function clampFetchChars(value: number | undefined): number {
  if (!Number.isFinite(value)) return DEFAULT_FETCH_CHARS_PER_URL;
  return Math.max(1, Math.min(MAX_FETCH_CHARS_PER_URL, Math.floor(value ?? DEFAULT_FETCH_CHARS_PER_URL)));
}

function cleanText(value: unknown): string {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

function truncateCapture(value: string): string {
  if (Buffer.byteLength(value, "utf8") <= MAX_CAPTURE_BYTES) return value;
  return value.slice(0, MAX_CAPTURE_BYTES) + "\n[truncated by gemini_search agy capture limit]";
}

export function parseAgyCliOutput(stdout: string): { parsed: ParsedAgyResult; rawResponseText: string } {
  const outer = JSON.parse(stdout) as AgyCliJsonOutput;
  const status = cleanText(outer.status).toUpperCase();
  const errorText = cleanText(outer.error);
  if (status !== "SUCCESS") {
    throw new Error(errorText || `agy returned status ${status || "unknown"}.`);
  }
  if (!outer.structured_output || typeof outer.structured_output !== "object" || Array.isArray(outer.structured_output)) {
    throw new Error("agy JSON output did not include a structured_output object.");
  }
  return {
    parsed: outer.structured_output as ParsedAgyResult,
    rawResponseText: cleanText(outer.response) || JSON.stringify(outer.structured_output),
  };
}

function hostnameIsHomepage(url: URL): boolean {
  return (url.pathname === "" || url.pathname === "/") && !url.search && !url.hash;
}

function urlQuality(urlText: string): UrlQuality {
  try {
    const url = new URL(urlText);
    const host = url.hostname.toLowerCase();
    if (host === "vertexaisearch.cloud.google.com" || host === "www.google.com" || host === "google.com") return "redirect_suspicious";
    if (hostnameIsHomepage(url)) return "generic_homepage";
  } catch {
    return "invalid";
  }
  return "high";
}

function qualityWarning(quality: UrlQuality): string | undefined {
  switch (quality) {
    case "redirect_suspicious":
      return "agy returned a Google/Vertex redirect instead of a canonical source URL. Verify before citing.";
    case "generic_homepage":
      return "agy returned a generic homepage URL; prefer a specific docs/article URL when citing.";
    case "not_found":
      return "URL validation found a missing source. Do not cite unless independently verified.";
    case "private_blocked":
      return "URL points at a local/private host and was blocked for safety.";
    case "invalid":
      return "agy returned an invalid URL string. Verify before citing.";
    case "blocked":
      return "URL validation was blocked or rate-limited by the server; source may still be citeable if independently verified.";
    case "high":
      return undefined;
  }
}

function classifyUrlWarning(urlText: string): string | undefined {
  return qualityWarning(urlQuality(urlText));
}

function normalizeStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map(cleanText).filter(Boolean).slice(0, 8);
}

function normalizeParsedResult(parsed: ParsedAgyResult, rawResponseText: string, limit: number): NormalizedSearch {
  const rawResults = Array.isArray(parsed.results) ? parsed.results : [];
  const results: NormalizedResult[] = [];
  const notes = normalizeStringArray(parsed.notes);

  for (const rawResult of rawResults) {
    if (!rawResult || typeof rawResult !== "object") continue;
    const record = rawResult as Record<string, unknown>;
    const title = cleanText(record.title);
    const url = cleanText(record.url);
    const snippet = cleanText(record.snippet);
    if (!title || !url) continue;

    results.push({
      title,
      url,
      snippet,
      source: "agy-search-web",
      warning: classifyUrlWarning(url),
    });

    if (results.length >= limit) break;
  }

  return {
    summary: cleanText(parsed.summary),
    queries: normalizeStringArray(parsed.queries),
    results,
    notes,
    rawResponseText,
  };
}

function effectiveValidateUrls(mode: SearchMode, requested: boolean | undefined): boolean {
  return requested ?? (mode === "docs" || mode === "source-finder");
}

function ttlMsForMode(mode: SearchMode): number {
  switch (mode) {
    case "docs":
    case "source-finder":
      return 7 * 24 * 60 * 60 * 1000;
    case "research":
    case "comparison":
      return 24 * 60 * 60 * 1000;
    case "search":
    default:
      return 6 * 60 * 60 * 1000;
  }
}

function confidenceForResult(result: NormalizedResult): SearchConfidence {
  const initialQuality = urlQuality(result.url);
  const validationQuality = result.validation?.quality;
  if (validationQuality === "not_found" || validationQuality === "private_blocked" || validationQuality === "invalid") return "low";
  if (initialQuality === "redirect_suspicious" || initialQuality === "invalid") return "low";
  if (!result.validation) return "medium";
  if (!result.validation.ok || validationQuality === "blocked" || validationQuality === "generic_homepage" || initialQuality === "generic_homepage") return "medium";
  return "high";
}

function confidenceRank(confidence: SearchConfidence): number {
  switch (confidence) {
    case "high":
      return 3;
    case "medium":
      return 2;
    case "low":
      return 1;
  }
}

function annotateAndSortResults(results: NormalizedResult[]): NormalizedResult[] {
  return results
    .map((result) => ({ ...result, confidence: confidenceForResult(result) }))
    .sort((left, right) => confidenceRank(right.confidence ?? "low") - confidenceRank(left.confidence ?? "low"));
}

function searchConfidence(search: NormalizedSearch): SearchConfidence {
  const confidences = search.results.map((result) => result.confidence ?? confidenceForResult(result));
  if (confidences.some((confidence) => confidence === "high")) return "high";
  if (confidences.some((confidence) => confidence === "medium")) return "medium";
  return "low";
}

function cacheTtlMs(mode: SearchMode, confidence: SearchConfidence): number {
  return confidence === "low" ? LOW_CONFIDENCE_CACHE_TTL_MS : ttlMsForMode(mode);
}

function shouldCacheSearch(search: NormalizedSearch, confidence: SearchConfidence): boolean {
  return search.results.length > 0 && confidence !== "low";
}

export function cacheKey(input: { query: string; limit: number; mode: string; model: string; validateUrls: boolean; binary: string }): string {
  return createHash("sha256").update(JSON.stringify({ version: CACHE_VERSION, provider: "agy-search-web", ...input })).digest("hex");
}

function cachePath(key: string): string {
  return join(CACHE_DIR, `${key}.json`);
}

async function readSearchCache(key: string): Promise<SearchCacheEntry | undefined> {
  const path = cachePath(key);
  if (!existsSync(path)) return undefined;
  try {
    const entry = JSON.parse(await readFile(path, "utf8")) as SearchCacheEntry;
    if (entry.version !== CACHE_VERSION) return undefined;
    if (entry.expiresAt <= Date.now()) return undefined;
    return entry;
  } catch {
    return undefined;
  }
}

async function writeSearchCache(key: string, entry: SearchCacheEntry): Promise<void> {
  const path = cachePath(key);
  await mkdir(dirname(path), { recursive: true });
  const temporaryPath = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporaryPath, JSON.stringify(entry, null, 2), "utf8");
    await rename(temporaryPath, path);
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

function buildPrompt(params: GeminiSearchInput, limit: number): string {
  const mode = params.mode ?? "search";
  const modeInstruction: Record<SearchMode, string> = {
    search: "Return concise, source-oriented search results.",
    research: "Synthesize the answer briefly, then list the most useful sources.",
    docs: "Prioritize official documentation, llms.txt, markdown docs, API references, changelogs, and canonical source repositories.",
    comparison: "Compare the options with balanced tradeoffs, then list primary and high-quality secondary sources.",
    "source-finder": "Do not synthesize much. Focus on finding exact, citeable URLs for primary sources and relevant docs/articles.",
  };

  return `You are a web search adapter for another coding agent.\n\nUse the search_web tool for live internet research. Do not read workspace files, write files, run terminal commands, use browser automation, or modify anything.\n\nMode: ${mode}\nInstruction: ${modeInstruction[mode]}\nQuery: ${JSON.stringify(params.query)}\nMax results: ${limit}\n\nReturn a compact object matching the required JSON schema.\n\nRules:\n- Prefer primary and official sources.\n- URLs must be exact destination URLs observed in search results. Do not infer canonical URLs from memory.\n- Prefer fewer specific URLs over more speculative URLs.\n- For docs mode, prefer exact docs pages over homepages.\n- For comparison mode, include both vendors' official pages plus neutral comparisons when available.\n- If you only have a redirect URL, include it but add a note saying it is a redirect.\n- Record the search queries actually used when known.\n- Do not invent sources, titles, snippets, or URLs.`;
}

function resolveModelForCli(params: GeminiSearchInput): string | undefined {
  return params.model?.trim() || AGY_DEFAULT_MODEL || undefined;
}

function modelForDetails(modelForCli: string | undefined): string {
  return modelForCli || "agy-cli-default";
}

function isAbortLike(signal: AbortSignal | undefined): boolean {
  return Boolean(signal?.aborted);
}

function isTransientAgyText(value: string): boolean {
  const text = value.toLowerCase();
  return [
    "exhausted your capacity",
    "quota",
    "rate limit",
    "rate-limit",
    "too many requests",
    "429",
    "timeout",
    "timed out",
    "temporarily unavailable",
    "service unavailable",
    "econnreset",
    "etimedout",
    "socket hang up",
    "502",
    "503",
    "504",
  ].some((needle) => text.includes(needle));
}

function isTransientAgyFailure(result: ProcessResult): boolean {
  if (result.timedOut) return true;
  return isTransientAgyText(`${result.stderr}\n${result.stdout}`);
}

function isTransientError(error: unknown): boolean {
  return isTransientAgyText(error instanceof Error ? error.message : String(error));
}

function retryDelayMs(attempt: number): number {
  const jitterMs = Math.floor(Math.random() * AGY_RETRY_JITTER_MS);
  return AGY_RETRY_BASE_DELAY_MS * 2 ** Math.max(0, attempt - 1) + jitterMs;
}

async function sleepWithAbort(ms: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) throw new Error("gemini_search agy retry cancelled.");
  let abortHandler: (() => void) | undefined;
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(resolve, ms);
    abortHandler = () => {
      clearTimeout(timeout);
      reject(new Error("gemini_search agy retry cancelled."));
    };
    signal?.addEventListener("abort", abortHandler, { once: true });
  }).finally(() => {
    if (abortHandler) signal?.removeEventListener("abort", abortHandler);
  });
}

export function buildAgyArgs(prompt: string, model: string | undefined, timeoutMs = TIMEOUT_MS): string[] {
  const args = [
    "--sandbox",
    "--mode",
    "plan",
    "--output-format",
    "json",
    "--json-schema",
    JSON.stringify(AGY_RESULT_SCHEMA),
    "--disable-slash-commands",
    "--print-timeout",
    `${timeoutMs}ms`,
  ];
  if (model) args.push("--model", model);
  args.push("-p", prompt);
  return args;
}

async function runAgy(prompt: string, model: string | undefined, signal?: AbortSignal): Promise<ProcessResult> {
  const cwd = await mkdtemp(join(tmpdir(), "pi-agy-search-"));
  const startedAt = Date.now();

  return new Promise((resolve, reject) => {
    const args = buildAgyArgs(prompt, model);
    let stdout = "";
    let stderr = "";
    let settled = false;
    let timedOut = false;
    let forceKillTimer: ReturnType<typeof setTimeout> | undefined;

    const cleanup = async () => {
      await rm(cwd, { recursive: true, force: true });
    };

    const child = spawn(AGY_BINARY, args, {
      cwd,
      env: { ...process.env, NO_COLOR: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    });

    const terminate = () => {
      child.kill("SIGTERM");
      forceKillTimer = setTimeout(() => child.kill("SIGKILL"), 2_000);
      forceKillTimer.unref();
    };
    const timeout = setTimeout(() => {
      timedOut = true;
      terminate();
    }, TIMEOUT_MS + 2_000);
    timeout.unref();

    const abortHandler = () => terminate();
    signal?.addEventListener("abort", abortHandler, { once: true });

    child.stdout.on("data", (chunk: Buffer) => {
      stdout = truncateCapture(stdout + chunk.toString("utf8"));
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr = truncateCapture(stderr + chunk.toString("utf8"));
    });
    child.on("error", async (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (forceKillTimer) clearTimeout(forceKillTimer);
      signal?.removeEventListener("abort", abortHandler);
      await cleanup();
      reject(error);
    });
    child.on("close", async (code, childSignal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (forceKillTimer) clearTimeout(forceKillTimer);
      signal?.removeEventListener("abort", abortHandler);
      await cleanup();
      resolve({ code, signal: childSignal, stdout, stderr, timedOut, durationMs: Date.now() - startedAt });
    });
  });
}

async function runAgyWithRetry(prompt: string, model: string | undefined, signal?: AbortSignal): Promise<ProcessResult> {
  let lastResult: ProcessResult | undefined;
  let lastError: unknown;

  for (let attempt = 1; attempt <= MAX_AGY_ATTEMPTS; attempt += 1) {
    if (isAbortLike(signal)) throw new Error("gemini_search cancelled before agy completed.");

    try {
      const result = await runAgy(prompt, model, signal);
      lastResult = { ...result, attempts: attempt };
      if (isAbortLike(signal)) throw new Error("gemini_search cancelled while agy was running.");
      if (result.code === 0 && !result.timedOut) return lastResult;
      if (!isTransientAgyFailure(result) || attempt === MAX_AGY_ATTEMPTS) return lastResult;
    } catch (error) {
      lastError = error;
      if (isAbortLike(signal)) throw new Error("gemini_search cancelled while agy was running.");
      if (!isTransientError(error) || attempt === MAX_AGY_ATTEMPTS) throw error;
    }

    await sleepWithAbort(retryDelayMs(attempt), signal);
  }

  if (lastResult) return lastResult;
  throw lastError instanceof Error ? lastError : new Error(String(lastError ?? "gemini_search failed before agy produced a process result."));
}

function validationFromResponse(response: Response, method: "HEAD" | "GET"): UrlValidation {
  const finalQuality = urlQuality(response.url);
  const statusQuality: UrlQuality = response.status === 404 || response.status === 410
    ? "not_found"
    : response.status === 401 || response.status === 403 || response.status === 405 || response.status === 429 || response.status >= 500
      ? "blocked"
      : response.status >= 400
        ? "invalid"
        : finalQuality;

  return {
    ok: response.ok,
    status: response.status,
    finalUrl: response.url,
    contentType: response.headers.get("content-type") ?? undefined,
    method,
    quality: statusQuality,
  };
}

function shouldRetryValidationWithGet(validation: UrlValidation): boolean {
  return validation.status === 403 || validation.status === 405 || validation.status === 429 || validation.error !== undefined;
}

async function validateUrl(url: string, signal?: AbortSignal): Promise<UrlValidation> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), URL_VALIDATION_TIMEOUT_MS);
  const abortHandler = () => controller.abort();
  signal?.addEventListener("abort", abortHandler, { once: true });
  try {
    await assertPublicFetchableUrl(url);
    const headResponse = await fetchPublic(url, {
      method: "HEAD",
      headers: { "user-agent": WEB_FETCH_USER_AGENT, accept: "text/html,text/markdown,text/plain,*/*" },
    }, controller.signal);
    const headValidation = validationFromResponse(headResponse, "HEAD");
    await headResponse.body?.cancel();
    if (!shouldRetryValidationWithGet(headValidation)) return headValidation;

    const getResponse = await fetchPublic(url, {
      method: "GET",
      headers: { "user-agent": WEB_FETCH_USER_AGENT, accept: "text/html,text/markdown,text/plain,*/*", range: "bytes=0-1024" },
    }, controller.signal);
    const getValidation = validationFromResponse(getResponse, "GET");
    await getResponse.body?.cancel();
    return getValidation;
  } catch (error) {
    if (signal?.aborted) throw new Error("gemini_search cancelled during URL validation.");
    const message = error instanceof Error ? error.message : String(error);
    const quality: UrlQuality = message.includes("local/private") || message.includes("private IP") ? "private_blocked" : "invalid";
    return { ok: false, quality, error: message };
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener("abort", abortHandler);
  }
}

function mergeWarnings(...warnings: Array<string | undefined>): string | undefined {
  const uniqueWarnings = Array.from(new Set(warnings.filter((warning): warning is string => Boolean(warning))));
  return uniqueWarnings.join(" ") || undefined;
}

async function maybeValidateResults(search: NormalizedSearch, enabled: boolean, signal?: AbortSignal): Promise<NormalizedSearch> {
  if (!enabled) return { ...search, results: annotateAndSortResults(search.results) };
  const results: NormalizedResult[] = [];
  for (const result of search.results) {
    if (signal?.aborted) throw new Error("gemini_search cancelled during URL validation.");
    const validation = await validateUrl(result.url, signal);
    const finalUrlQuality = validation.finalUrl ? urlQuality(validation.finalUrl) : undefined;
    const canCanonicalizeRedirect = validation.finalUrl
      && validation.finalUrl !== result.url
      && urlQuality(result.url) === "redirect_suspicious"
      && finalUrlQuality === "high";
    const url = canCanonicalizeRedirect ? validation.finalUrl! : result.url;
    const validationWarning = canCanonicalizeRedirect ? undefined : qualityWarning(validation.quality);
    const finalUrlWarning = !canCanonicalizeRedirect && validation.finalUrl && validation.finalUrl !== result.url
      ? classifyUrlWarning(validation.finalUrl)
      : undefined;
    const canonicalizationWarning = canCanonicalizeRedirect
      ? "URL canonicalized from an agy search redirect; verify the page matches the snippet before citing."
      : undefined;
    results.push({ ...result, url, validation, warning: mergeWarnings(canCanonicalizeRedirect ? undefined : result.warning, validationWarning, finalUrlWarning, canonicalizationWarning) });
  }
  return { ...search, results: annotateAndSortResults(results) };
}

function truncateDisplayText(value: string, maxChars: number): string {
  if (value.length <= maxChars) return value;
  return `${value.slice(0, Math.max(0, maxChars - 1)).trimEnd()}…`;
}

function acceptsResultInContent(result: NormalizedResult, mode: SearchMode): boolean {
  const confidence = result.confidence ?? confidenceForResult(result);
  if (confidence === "high") return true;
  if (mode === "docs" || mode === "source-finder") return false;
  return confidence === "medium";
}

function formatOmittedResultsLine(omittedCount: number, mode: SearchMode): string | undefined {
  if (omittedCount <= 0) return undefined;
  const policy = mode === "docs" || mode === "source-finder"
    ? "showing high-confidence sources only"
    : "low-confidence sources hidden";
  return `Omitted ${omittedCount} result(s): ${policy}. See details if needed.`;
}

function buildGeminiDetails(
  base: Pick<GeminiSearchDetails, "query" | "limit" | "mode" | "cached" | "validateUrls" | "model">,
  search?: NormalizedSearch,
  extras: Partial<GeminiSearchDetails> = {},
): GeminiSearchDetails {
  const normalized = search ?? { summary: "", queries: [], results: [], notes: [], rawResponseText: "" };
  return {
    ...normalized,
    rawResponseText: normalized.rawResponseText.slice(0, 4000),
    source: "agy-cli-search-web",
    binary: AGY_BINARY,
    ...base,
    ...extras,
  };
}

function formatResults(query: string, search: NormalizedSearch, cached: boolean, mode: SearchMode): string {
  const lines = [`agy grounded search results for: ${query}${cached ? " (cached)" : ""}`];
  const acceptedResults = search.results.filter((result) => acceptsResultInContent(result, mode));
  const omittedCount = search.results.length - acceptedResults.length;
  const strictMode = mode === "docs" || mode === "source-finder";
  const allAcceptedAreVerified = acceptedResults.every((result) => result.confidence === "high");

  if (search.summary) lines.push("", `Summary: ${truncateDisplayText(search.summary, MAX_DISPLAY_SUMMARY_CHARS)}`);

  if (acceptedResults.length === 0) {
    lines.push("", strictMode ? "No validated citeable results found." : "No usable source candidates found.");
  } else {
    lines.push("", allAcceptedAreVerified ? "Validated citeable results:" : "Source candidates (validate or fetch before citing):");
    acceptedResults.forEach((result, index) => {
      lines.push(`${index + 1}. ${result.title}`, `   ${result.url}`);
      if (result.snippet) lines.push(`   ${truncateDisplayText(result.snippet, MAX_DISPLAY_SNIPPET_CHARS)}`);
      if (result.confidence === "medium") lines.push("   Confidence: medium - URL not fully validated; verify before citing.");
    });
  }

  const omittedLine = formatOmittedResultsLine(omittedCount, mode);
  if (omittedLine) lines.push("", omittedLine);

  if (search.notes.length > 0) {
    const compactNotes = search.notes
      .slice(0, MAX_DISPLAY_NOTES)
      .map((note) => truncateDisplayText(note, MAX_DISPLAY_NOTE_CHARS));
    lines.push("", `Notes: ${compactNotes.join(" | ")}`);
  }

  return lines.join("\n");
}

function hostForDisplay(urlText: string): string {
  try {
    return new URL(urlText).hostname.replace(/^www\./, "");
  } catch {
    return urlText;
  }
}

function formatDuration(ms: number | undefined): string | undefined {
  if (!Number.isFinite(ms)) return undefined;
  if ((ms ?? 0) < 1000) return `${ms}ms`;
  return `${Math.round((ms ?? 0) / 100) / 10}s`;
}

function formatSourceDomains(results: NormalizedResult[]): string {
  const domains = Array.from(new Set(results.map((result) => hostForDisplay(result.url)).filter(Boolean))).slice(0, 4);
  if (domains.length === 0) return "no sources";
  const extra = Math.max(0, new Set(results.map((result) => hostForDisplay(result.url))).size - domains.length);
  return `${domains.join(", ")}${extra > 0 ? `, +${extra}` : ""}`;
}

function formatValidation(validation: UrlValidation | undefined): string | undefined {
  if (!validation) return undefined;
  const status = validation.status ? `HTTP ${validation.status}` : validation.ok ? "ok" : "not ok";
  const finalUrl = validation.finalUrl ? ` · final ${validation.finalUrl}` : "";
  const method = validation.method ? ` · ${validation.method}` : "";
  return `${status}${method} · ${validation.quality}${finalUrl}`;
}

function renderGeminiSearchCall(args: GeminiSearchInput, theme: PiTheme) {
  const query = typeof args.query === "string" && args.query.trim() ? args.query.trim() : "…";
  const mode = SEARCH_MODES.includes(args.mode as SearchMode) ? args.mode as SearchMode : "search";
  const limit = clampLimit(args.limit);
  const validateUrls = typeof args.validateUrls === "boolean" ? `validation ${args.validateUrls ? "on" : "off"}` : "validation auto";
  const cache = args.forceRefresh ? "force refresh" : "cache allowed";
  return new Text(
    `${theme.fg("toolTitle", theme.bold("gemini_search "))}${theme.fg("accent", mode)} ${theme.fg("muted", `limit ${limit} · ${validateUrls} · ${cache}`)}\n` +
      `  ${theme.fg("dim", truncateDisplayText(query, 120))}`,
    0,
    0,
  );
}

function renderGeminiSearchResult(
  result: { content: Array<{ type: string; text?: string }>; details?: unknown },
  state: { expanded?: boolean; isPartial?: boolean },
  theme: PiTheme,
) {
  const details = result.details as GeminiSearchDetails | undefined;
  if (!details?.query) {
    const first = result.content[0];
    return new Text(first?.type === "text" ? first.text ?? "" : "(no output)", 0, 0);
  }

  const running = state.isPartial || details.status === "running" || details.status === "validating";
  const icon = running ? theme.fg("warning", "⏳") : details.results.length > 0 ? theme.fg("success", "✓") : theme.fg("warning", "◇");
  const duration = formatDuration(details.durationMs);
  const cacheLabel = details.cached ? "cached" : details.cacheWritten ? "fresh, cached" : "fresh";
  const validationLabel = details.validateUrls ? "validation on" : "validation off";
  const sourceLabel = `${details.results.length} source${details.results.length === 1 ? "" : "s"}`;
  const confidence = details.confidence ? ` · confidence ${details.confidence}` : "";
  const status = details.status && details.status !== "done" ? ` · ${details.status}` : "";

  if (!state.expanded) {
    let text = `${icon} ${theme.fg("toolTitle", theme.bold(`gemini_search ${details.mode}`))}${theme.fg("muted", status)}\n`;
    text += `${theme.fg("dim", truncateDisplayText(details.query, 140))}\n`;
    text += theme.fg("muted", `${sourceLabel} · ${formatSourceDomains(details.results)} · ${cacheLabel} · ${validationLabel}${confidence}${duration ? ` · ${duration}` : ""}`);
    if (details.queries.length > 0) text += `\n${theme.fg("muted", `reported query: ${truncateDisplayText(details.queries[0], 110)}${details.queries.length > 1 ? ` (+${details.queries.length - 1})` : ""}`)}`;
    if (details.results.length > 0 || details.queries.length > 0 || details.notes.length > 0) text += `\n${theme.fg("muted", "(Ctrl+O to expand details)")}`;
    return new Text(text, 0, 0);
  }

  const container = new Container();
  container.addChild(new Text(`${icon} ${theme.fg("toolTitle", theme.bold(`gemini_search ${details.mode}`))} ${theme.fg("accent", sourceLabel)}`, 0, 0));
  container.addChild(new Text(theme.fg("dim", `Query sent: ${details.query}`), 0, 0));
  container.addChild(new Text(theme.fg("muted", [
    `limit ${details.limit}`,
    validationLabel,
    cacheLabel,
    details.confidence ? `confidence ${details.confidence}` : undefined,
    duration,
    details.retryAttempts ? `${details.retryAttempts} attempt(s)` : undefined,
    details.model,
  ].filter(Boolean).join(" · ")), 0, 0));
  if (details.cacheExpiresAt) container.addChild(new Text(theme.fg("muted", `Cache expires: ${details.cacheExpiresAt}`), 0, 0));

  if (details.queries.length > 0) {
    container.addChild(new Spacer(1));
    container.addChild(new Text(theme.fg("toolTitle", theme.bold("agy-reported queries")), 0, 0));
    container.addChild(new Text(details.queries.map((query) => `- ${query}`).join("\n"), 0, 0));
  }

  if (details.summary) {
    container.addChild(new Spacer(1));
    container.addChild(new Text(theme.fg("toolTitle", theme.bold("Summary")), 0, 0));
    container.addChild(new Text(details.summary, 0, 0));
  }

  if (details.results.length > 0) {
    container.addChild(new Spacer(1));
    container.addChild(new Text(theme.fg("toolTitle", theme.bold("Sources returned")), 0, 0));
    for (const [index, source] of details.results.entries()) {
      const confidenceText = source.confidence ? ` · ${source.confidence}` : "";
      container.addChild(new Text(`${theme.fg("accent", `${index + 1}. ${source.title}`)}${theme.fg("muted", confidenceText)}\n${source.url}`, 0, 0));
      const validation = formatValidation(source.validation);
      if (validation) container.addChild(new Text(theme.fg("muted", validation), 0, 0));
      if (source.snippet) container.addChild(new Text(theme.fg("dim", source.snippet), 0, 0));
      if (source.warning) container.addChild(new Text(theme.fg("warning", source.warning), 0, 0));
    }
  }

  if (details.notes.length > 0) {
    container.addChild(new Spacer(1));
    container.addChild(new Text(theme.fg("toolTitle", theme.bold("Notes")), 0, 0));
    container.addChild(new Text(details.notes.map((note) => `- ${note}`).join("\n"), 0, 0));
  }

  if (details.stderr?.trim()) {
    container.addChild(new Spacer(1));
    container.addChild(new Text(theme.fg("toolTitle", theme.bold("agy stderr")), 0, 0));
    container.addChild(new Text(theme.fg("error", details.stderr.trim()), 0, 0));
  }

  container.addChild(new Spacer(1));
  container.addChild(new Text(theme.fg("muted", `Binary: ${details.binary} · Source: ${details.source}. agy search_web internals may be unavailable; shown queries are agent-reported.`), 0, 0));
  return container;
}

function isLikelyPrivateIp(address: string): boolean {
  if (isIP(address) === 6) {
    const normalized = address.toLowerCase();
    return normalized === "::1"
      || normalized.startsWith("fc")
      || normalized.startsWith("fd")
      || normalized.startsWith("fe80:")
      || normalized.startsWith("::ffff:127.")
      || normalized.startsWith("::ffff:10.")
      || normalized.startsWith("::ffff:192.168.");
  }

  if (isIP(address) !== 4) return false;
  return /^10\./.test(address)
    || /^127\./.test(address)
    || /^169\.254\./.test(address)
    || /^192\.168\./.test(address)
    || /^172\.(1[6-9]|2\d|3[0-1])\./.test(address)
    || address === "0.0.0.0";
}

function assertFetchableUrl(urlText: string): URL {
  const url = new URL(urlText);
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error(`Only http(s) URLs are supported: ${urlText}`);
  }
  const host = url.hostname.toLowerCase();
  const blockedHosts = new Set(["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]);
  if (blockedHosts.has(host) || host.endsWith(".local")) throw new Error(`Refusing to fetch local/private host: ${host}`);
  if (isLikelyPrivateIp(host)) throw new Error(`Refusing to fetch private IP address: ${host}`);
  return url;
}

async function assertPublicFetchableUrl(urlText: string): Promise<URL> {
  const url = assertFetchableUrl(urlText);
  const host = url.hostname.toLowerCase();
  if (isIP(host)) return url;

  const addresses = await lookup(host, { all: true, verbatim: true });
  const privateAddress = addresses.find((entry) => isLikelyPrivateIp(entry.address));
  if (privateAddress) throw new Error(`Refusing to fetch host that resolves to private IP address: ${host}`);
  return url;
}

function redirectTarget(currentUrl: string, location: string | null): string | undefined {
  if (!location) return undefined;
  return new URL(location, currentUrl).toString();
}

async function fetchPublic(urlText: string, init: RequestInit, signal?: AbortSignal): Promise<Response> {
  let currentUrl = (await assertPublicFetchableUrl(urlText)).toString();

  for (let redirectCount = 0; redirectCount <= MAX_REDIRECTS; redirectCount += 1) {
    const response = await fetch(currentUrl, { ...init, redirect: "manual", signal });
    if (!REDIRECT_STATUSES.has(response.status)) return response;

    const nextUrl = redirectTarget(currentUrl, response.headers.get("location"));
    await response.body?.cancel();
    if (!nextUrl) return response;
    if (redirectCount === MAX_REDIRECTS) throw new Error(`Too many redirects while fetching ${urlText}`);
    currentUrl = (await assertPublicFetchableUrl(nextUrl)).toString();
  }

  throw new Error(`Too many redirects while fetching ${urlText}`);
}

function decodeHtmlEntities(value: string): string {
  return value
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&#x2F;/gi, "/");
}

function extractTitle(html: string): string | undefined {
  const match = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  return match ? cleanText(decodeHtmlEntities(match[1])) : undefined;
}

function htmlToText(html: string): string {
  return decodeHtmlEntities(
    html
      .replace(/<script\b[\s\S]*?<\/script>/gi, "\n")
      .replace(/<style\b[\s\S]*?<\/style>/gi, "\n")
      .replace(/<noscript\b[\s\S]*?<\/noscript>/gi, "\n")
      .replace(/<\/(p|div|section|article|header|footer|li|ul|ol|h[1-6]|tr|table)>/gi, "\n")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<[^>]+>/g, " ")
      .replace(/[ \t]+/g, " ")
      .replace(/\n\s+/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim(),
  );
}

function normalizeFetchedText(contentType: string | undefined, body: string): { text: string; title?: string } {
  if (contentType?.toLowerCase().includes("html") || /<html[\s>]/i.test(body)) {
    return { text: htmlToText(body), title: extractTitle(body) };
  }
  return { text: body.replace(/\r\n/g, "\n").trim() };
}

async function readResponseBodyWithinLimit(response: Response): Promise<{ body: string; byteTruncated: boolean }> {
  if (!response.body) return { body: await response.text(), byteTruncated: false };

  const reader = response.body.getReader();
  const chunks: Buffer[] = [];
  let totalBytes = 0;
  let byteTruncated = false;

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    if (!value) continue;

    const nextTotal = totalBytes + value.byteLength;
    if (nextTotal > MAX_FETCH_BYTES) {
      const remainingBytes = Math.max(0, MAX_FETCH_BYTES - totalBytes);
      if (remainingBytes > 0) chunks.push(Buffer.from(value.slice(0, remainingBytes)));
      byteTruncated = true;
      await reader.cancel();
      break;
    }

    chunks.push(Buffer.from(value));
    totalBytes = nextTotal;
  }

  return { body: Buffer.concat(chunks).toString("utf8"), byteTruncated };
}

async function fetchOne(urlText: string, maxChars: number, signal?: AbortSignal): Promise<FetchedPage> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), WEB_FETCH_TIMEOUT_MS);
  const abortHandler = () => controller.abort();
  signal?.addEventListener("abort", abortHandler, { once: true });

  try {
    await assertPublicFetchableUrl(urlText);
    const response = await fetchPublic(urlText, {
      method: "GET",
      headers: { "user-agent": WEB_FETCH_USER_AGENT, accept: "text/html,text/markdown,text/plain,application/json,*/*" },
    }, controller.signal);
    const contentLength = Number.parseInt(response.headers.get("content-length") || "", 10);
    if (Number.isFinite(contentLength) && contentLength > MAX_FETCH_BYTES) {
      await response.body?.cancel();
      return {
        originalUrl: urlText,
        finalUrl: response.url,
        status: response.status,
        ok: false,
        contentType: response.headers.get("content-type") ?? undefined,
        text: "",
        truncated: false,
        error: `Content-Length ${contentLength} exceeds ${MAX_FETCH_BYTES} byte safety limit.`,
      };
    }

    const { body, byteTruncated } = await readResponseBodyWithinLimit(response);
    const contentType = response.headers.get("content-type") ?? undefined;
    const normalized = normalizeFetchedText(contentType, body);
    const truncated = byteTruncated || normalized.text.length > maxChars;

    return {
      originalUrl: urlText,
      finalUrl: response.url,
      status: response.status,
      ok: response.ok && !byteTruncated,
      contentType,
      title: normalized.title,
      text: normalized.text.length > maxChars ? normalized.text.slice(0, maxChars) : normalized.text,
      truncated,
      byteTruncated,
      error: byteTruncated
        ? `Response exceeded ${MAX_FETCH_BYTES} byte safety limit and was truncated.`
        : response.ok ? undefined : `HTTP ${response.status} ${response.statusText}`,
    };
  } catch (error) {
    return { originalUrl: urlText, ok: false, text: "", truncated: false, error: error instanceof Error ? error.message : String(error) };
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener("abort", abortHandler);
  }
}

function formatFetchedPages(pages: FetchedPage[]): string {
  const lines = [`Fetched ${pages.length} URL(s).`];
  pages.forEach((page, index) => {
    lines.push("", `--- ${index + 1}. ${page.title || page.originalUrl} ---`, `URL: ${page.originalUrl}`);
    if (page.finalUrl && page.finalUrl !== page.originalUrl) lines.push(`Final URL: ${page.finalUrl}`);
    if (page.status) lines.push(`Status: ${page.status}`);
    if (page.contentType) lines.push(`Content-Type: ${page.contentType}`);
    if (page.error) lines.push(`Error: ${page.error}`);
    if (page.text) {
      lines.push("", page.text);
      if (page.byteTruncated) lines.push("", `[Byte safety limit reached at ${MAX_FETCH_BYTES} bytes.]`);
      if (page.truncated) lines.push("", `[Truncated at ${page.text.length} characters.]`);
    }
  });
  return lines.join("\n");
}

export default function geminiSearch(pi: ExtensionAPI) {
  pi.registerTool({
    name: "gemini_search",
    label: "Grounded Search (agy)",
    description: "Search the live web through the authenticated agy CLI search_web capability. The gemini_search name is retained for compatibility. Returns a grounded summary plus normalized source URLs, with optional URL validation and a local cache.",
    promptSnippet: "Search the live web through agy's search_web capability and return a grounded summary plus source URLs.",
    promptGuidelines: [
      "Use gemini_search when Brave web_search gives weak snippets or when the user asks for synthesized current web research.",
      "Use gemini_search mode docs for technical documentation searches; prefer official docs, llms.txt, markdown docs, and source repos.",
      "Treat unvalidated gemini_search URLs as candidates, not citeable sources; validate them or use web_fetch before citing.",
      "After gemini_search finds important docs or articles, use web_fetch on exact URLs when you need citeable page content rather than snippets.",
    ],
    parameters: GeminiSearchParams,
    async execute(_toolCallId, params, signal, onUpdate) {
      const query = params.query.trim();
      if (!query) throw new Error("gemini_search requires a non-empty query.");

      const limit = clampLimit(params.limit);
      const mode: SearchMode = params.mode ?? "search";
      const validateUrls = effectiveValidateUrls(mode, params.validateUrls);
      const modelForCli = resolveModelForCli(params);
      const model = modelForDetails(modelForCli);
      const key = cacheKey({ query, limit, mode, model, validateUrls, binary: AGY_BINARY });
      const cachedEntry = params.forceRefresh ? undefined : await readSearchCache(key);
      if (cachedEntry) {
        return {
          content: [{ type: "text", text: formatResults(query, cachedEntry.normalized, true, mode) }],
          details: buildGeminiDetails({ query, limit, mode, cached: true, validateUrls, model }, cachedEntry.normalized, {
            status: "done",
            cacheExpiresAt: new Date(cachedEntry.expiresAt).toISOString(),
            confidence: cachedEntry.confidence,
            stderr: cachedEntry.stderr,
            durationMs: cachedEntry.durationMs,
          }),
        };
      }

      onUpdate?.({
        content: [{ type: "text", text: `Running agy grounded search (${mode}, validation ${validateUrls ? "on" : "off"})...` }],
        details: buildGeminiDetails({ query, limit, mode, cached: false, validateUrls, model }, undefined, {
          status: "running",
        }),
      });
      const prompt = buildPrompt({ ...params, query, mode, model: modelForCli }, limit);
      const processResult = await runAgyWithRetry(prompt, modelForCli, signal);

      if (processResult.timedOut) {
        throw new Error(`gemini_search agy process timed out after ${TIMEOUT_MS}ms and ${processResult.attempts ?? 1} attempt(s).`);
      }
      if (processResult.code !== 0) {
        let agyError = "";
        try {
          agyError = cleanText((JSON.parse(processResult.stdout) as AgyCliJsonOutput).error);
        } catch {
        }
        throw new Error(
          `gemini_search agy process failed with exit code ${processResult.code}${processResult.signal ? ` (${processResult.signal})` : ""} after ${processResult.attempts ?? 1} attempt(s).\n` +
            `agy error: ${agyError || "not reported"}\n` +
            `stderr: ${cleanText(processResult.stderr).slice(0, 1200)}\n` +
            `stdout: ${cleanText(processResult.stdout).slice(0, 1200)}`,
        );
      }

      let parsed: ParsedAgyResult;
      let rawResponseText: string;
      try {
        ({ parsed, rawResponseText } = parseAgyCliOutput(processResult.stdout));
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        throw new Error(
          `gemini_search could not parse agy JSON output: ${message}.\n` +
            `agy output: ${cleanText(processResult.stdout).slice(0, 2000)}\n` +
            `stderr: ${cleanText(processResult.stderr).slice(0, 800)}`,
        );
      }

      if (validateUrls) {
        onUpdate?.({
          content: [{ type: "text", text: "Validating agy result URLs..." }],
          details: buildGeminiDetails({ query, limit, mode, cached: false, validateUrls, model }, undefined, {
            status: "validating",
            durationMs: processResult.durationMs,
            retryAttempts: processResult.attempts ?? 1,
          }),
        });
      }
      const normalized = await maybeValidateResults(normalizeParsedResult(parsed, rawResponseText, limit), validateUrls, signal);
      const confidence = searchConfidence(normalized);
      const expiresAt = Date.now() + cacheTtlMs(mode, confidence);
      const cacheEntry: SearchCacheEntry = {
        version: CACHE_VERSION,
        createdAt: Date.now(),
        expiresAt,
        normalized,
        stderr: cleanText(processResult.stderr).slice(0, 2000),
        durationMs: processResult.durationMs,
        confidence,
      };
      const cacheWritten = shouldCacheSearch(normalized, confidence);
      if (cacheWritten) await writeSearchCache(key, cacheEntry);

      return {
        content: [{ type: "text", text: formatResults(query, normalized, false, mode) }],
        details: buildGeminiDetails({ query, limit, mode, cached: false, validateUrls, model }, normalized, {
          status: "done",
          cacheWritten,
          cacheExpiresAt: cacheWritten ? new Date(cacheEntry.expiresAt).toISOString() : undefined,
          confidence,
          stderr: cacheEntry.stderr,
          durationMs: processResult.durationMs,
          retryAttempts: processResult.attempts ?? 1,
        }),
      };
    },
    renderCall: renderGeminiSearchCall,
    renderResult: renderGeminiSearchResult,
  });

  pi.registerTool({
    name: "web_fetch",
    label: "Web Fetch",
    description: "Fetch HTTP(S) URLs and return cleaned text/markdown with status, final URL, content type, title, and truncation metadata. Useful after web_search or gemini_search finds exact sources.",
    promptSnippet: "Fetch exact HTTP(S) URLs and return cleaned citeable page content, especially docs, markdown, and llms.txt pages.",
    promptGuidelines: [
      "Use web_fetch after web_search or gemini_search when snippets are insufficient and exact source content is needed.",
      "Prefer web_fetch for direct docs, markdown, llms.txt, GitHub raw, changelog, and API reference URLs.",
      "Do not use web_fetch for local/private hosts; the tool blocks obvious localhost/private IP targets.",
    ],
    parameters: WebFetchParams,
    async execute(_toolCallId, params: WebFetchInput, signal, onUpdate) {
      const maxCharsPerUrl = clampFetchChars(params.maxCharsPerUrl);
      const urls = params.urls.map((url) => url.trim()).filter(Boolean).slice(0, MAX_FETCH_URLS);
      if (urls.length === 0) throw new Error("web_fetch requires at least one non-empty URL.");

      const pages: FetchedPage[] = [];
      for (const [index, url] of urls.entries()) {
        onUpdate?.({ content: [{ type: "text", text: `Fetching URL ${index + 1}/${urls.length}: ${url}` }], details: {} });
        pages.push(await fetchOne(url, maxCharsPerUrl, signal));
      }

      return {
        content: [{ type: "text", text: formatFetchedPages(pages) }],
        details: {
          urls,
          maxCharsPerUrl,
          source: "direct-http-fetch",
          pages,
        },
      };
    },
  });
}

type ToolResultContent = Record<string, unknown>;

type ToolResultImageNormalization = {
  content: ToolResultContent[];
  changed: boolean;
  malformed: boolean;
};

const SUPPORTED_IMAGE_MIME_TYPES = new Set([
  "image/gif",
  "image/jpeg",
  "image/png",
  "image/webp",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isValidBase64(value: unknown): value is string {
  if (typeof value !== "string" || value.length === 0 || value.length % 4 === 1) return false;
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return false;
  return !value.includes("=") || value.length % 4 === 0;
}

function malformedImageText(index: number, reason: string): ToolResultContent {
  return {
    type: "text",
    text: `[Firstmate Pi image normalization error: tool result image ${index + 1} ${reason}.]`,
  };
}

export function normalizePiToolResultImages(content: readonly unknown[]): ToolResultImageNormalization {
  let changed = false;
  let malformed = false;
  const normalized = content.map((item, index): ToolResultContent => {
    if (!isRecord(item) || item.type !== "image") return item as ToolResultContent;

    if ("mimeType" in item || "data" in item) {
      if (!SUPPORTED_IMAGE_MIME_TYPES.has(String(item.mimeType))) {
        changed = true;
        malformed = true;
        return malformedImageText(index, `uses unsupported MIME type ${JSON.stringify(item.mimeType)}`);
      }
      if (!isValidBase64(item.data)) {
        changed = true;
        malformed = true;
        return malformedImageText(index, "does not contain valid base64 data");
      }
      return item;
    }

    if (!isRecord(item.source) || item.source.type !== "base64") {
      changed = true;
      malformed = true;
      return malformedImageText(index, "does not use a supported base64 source");
    }
    if (!SUPPORTED_IMAGE_MIME_TYPES.has(String(item.source.mediaType))) {
      changed = true;
      malformed = true;
      return malformedImageText(index, `uses unsupported MIME type ${JSON.stringify(item.source.mediaType)}`);
    }
    if (!isValidBase64(item.source.data)) {
      changed = true;
      malformed = true;
      return malformedImageText(index, "does not contain valid base64 data");
    }

    changed = true;
    return {
      type: "image",
      mimeType: item.source.mediaType,
      data: item.source.data,
    };
  });

  return { content: normalized, changed, malformed };
}

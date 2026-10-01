import { fetchImageFromPublicUrl } from "../lib/fetch-image.js";
import { processImage } from "../lib/process-image.js";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, X-Draw-Me-Key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function sendJson(res: any, data: unknown, status = 200) {
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    res.setHeader(key, value);
  }

  return res.status(status).json(data);
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : fallback;
}

function one(value: unknown): unknown {
  return Array.isArray(value) ? value[0] : value;
}

function numberQuery(value: unknown): number | undefined {
  const raw = one(value);

  if (typeof raw !== "string" || raw.trim() === "") {
    return undefined;
  }

  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function bodyFromQuery(query: Record<string, unknown>): Record<string, unknown> {
  const skipWhiteRaw = one(query.skipWhite);

  return {
    url: one(query.url),
    width: numberQuery(query.width),
    height: numberQuery(query.height),
    colors: numberQuery(query.colors),
    whiteThreshold: numberQuery(query.whiteThreshold),
    skipWhite:
      typeof skipWhiteRaw === "string"
        ? skipWhiteRaw.toLowerCase() !== "false"
        : true,
  };
}

export default async function handler(req: any, res: any) {
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    res.setHeader(key, value);
  }

  if (req.method === "OPTIONS") {
    return res.status(204).end();
  }

  let body: Record<string, unknown>;

  if (req.method === "GET") {
    body = bodyFromQuery(req.query ?? {});
  } else if (req.method === "POST") {
    try {
      if (typeof req.body === "string") {
        body = JSON.parse(req.body) as Record<string, unknown>;
      } else if (req.body && typeof req.body === "object") {
        body = req.body as Record<string, unknown>;
      } else {
        throw new Error("Missing JSON body.");
      }
    } catch {
      return sendJson(
        res,
        { ok: false, error: "Request body must be valid JSON." },
        400,
      );
    }
  } else {
    return sendJson(res, { ok: false, error: "Method not allowed." }, 405);
  }

  const configuredKey = process.env.DRAW_ME_API_KEY?.trim();

  if (
    configuredKey &&
    req.headers["x-draw-me-key"] !== configuredKey
  ) {
    return sendJson(res, { ok: false, error: "Unauthorized." }, 401);
  }

  if (
    typeof body.url !== "string" ||
    body.url.length < 8 ||
    body.url.length > 2048
  ) {
    return sendJson(
      res,
      { ok: false, error: "A valid image URL is required." },
      400,
    );
  }

  const width = Math.round(numberOr(body.width, 64));
  const height = Math.round(numberOr(body.height, 64));
  const colors = Math.round(numberOr(body.colors, 16));
  const whiteThreshold = Math.round(
    numberOr(body.whiteThreshold, 245),
  );
  const skipWhite = body.skipWhite !== false;

  if (
    width < 8 ||
    width > 128 ||
    height < 8 ||
    height > 128
  ) {
    return sendJson(
      res,
      {
        ok: false,
        error: "width and height must each be between 8 and 128.",
      },
      400,
    );
  }

  if (colors < 2 || colors > 32) {
    return sendJson(
      res,
      { ok: false, error: "colors must be between 2 and 32." },
      400,
    );
  }

  if (whiteThreshold < 200 || whiteThreshold > 255) {
    return sendJson(
      res,
      {
        ok: false,
        error: "whiteThreshold must be between 200 and 255.",
      },
      400,
    );
  }

  try {
    const fetched = await fetchImageFromPublicUrl(body.url);

    const drawing = await processImage(fetched.buffer, {
      width,
      height,
      colors,
      skipWhite,
      whiteThreshold,
    });

    return sendJson(res, {
      ok: true,
      source: {
        url: fetched.finalUrl,
        mime: fetched.mime,
      },
      drawing,
    });
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : "Image processing failed.";

    return sendJson(res, { ok: false, error: message }, 422);
  }
}

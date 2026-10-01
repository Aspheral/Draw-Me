import { NextRequest, NextResponse } from "next/server";
import { fetchImageFromPublicUrl } from "../../../lib/fetch-image";
import { processImage } from "../../../lib/process-image";

export const runtime = "nodejs";
export const maxDuration = 15;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, X-Draw-Me-Key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return NextResponse.json(data, { status, headers: CORS_HEADERS });
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

export async function OPTIONS() {
  return new NextResponse(null, { status: 204, headers: CORS_HEADERS });
}

export async function POST(request: NextRequest) {
  const configuredKey = process.env.DRAW_ME_API_KEY?.trim();
  if (configuredKey && request.headers.get("x-draw-me-key") !== configuredKey) {
    return json({ ok: false, error: "Unauthorized." }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return json({ ok: false, error: "Request body must be valid JSON." }, 400);
  }

  if (typeof body.url !== "string" || body.url.length < 8 || body.url.length > 2048) {
    return json({ ok: false, error: "A valid image URL is required." }, 400);
  }

  const width = Math.round(numberOr(body.width, 64));
  const height = Math.round(numberOr(body.height, 64));
  const colors = Math.round(numberOr(body.colors, 16));
  const whiteThreshold = Math.round(numberOr(body.whiteThreshold, 245));
  const skipWhite = body.skipWhite !== false;

  if (width < 8 || width > 128 || height < 8 || height > 128) {
    return json({ ok: false, error: "width and height must each be between 8 and 128." }, 400);
  }
  if (colors < 2 || colors > 32) {
    return json({ ok: false, error: "colors must be between 2 and 32." }, 400);
  }
  if (whiteThreshold < 200 || whiteThreshold > 255) {
    return json({ ok: false, error: "whiteThreshold must be between 200 and 255." }, 400);
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

    return json({
      ok: true,
      source: {
        url: fetched.finalUrl,
        mime: fetched.mime,
      },
      drawing,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Image processing failed.";
    return json({ ok: false, error: message }, 422);
  }
}

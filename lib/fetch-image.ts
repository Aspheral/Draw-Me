import { assertPublicHttpUrl } from "./url-safety";

const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_REDIRECTS = 3;
const REQUEST_TIMEOUT_MS = 10_000;

const ALLOWED_MIME = new Set([
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/gif",
  "image/avif",
]);

async function readBodyWithLimit(response: Response): Promise<Buffer> {
  if (!response.body) throw new Error("Image response had no body.");

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;

    total += value.byteLength;
    if (total > MAX_IMAGE_BYTES) {
      await reader.cancel("Image exceeded size limit.");
      throw new Error("Image is larger than the 8 MB limit.");
    }

    chunks.push(value);
  }

  return Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)));
}

export async function fetchImageFromPublicUrl(input: string): Promise<{
  buffer: Buffer;
  finalUrl: string;
  mime: string;
}> {
  let current = await assertPublicHttpUrl(input);

  for (let redirectCount = 0; redirectCount <= MAX_REDIRECTS; redirectCount += 1) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

    let response: Response;
    try {
      response = await fetch(current, {
        method: "GET",
        redirect: "manual",
        signal: controller.signal,
        headers: {
          "User-Agent": "DrawMeImageProcessor/1.0",
          Accept: "image/avif,image/webp,image/png,image/jpeg,image/gif;q=0.9,*/*;q=0.1",
        },
      });
    } catch (error) {
      if (error instanceof Error && error.name === "AbortError") {
        throw new Error("Image request timed out.");
      }

      throw new Error("Could not fetch the image URL.");
    } finally {
      clearTimeout(timeout);
    }

    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) {
        throw new Error("Image URL redirected without a Location header.");
      }

      if (redirectCount === MAX_REDIRECTS) {
        throw new Error("Too many redirects.");
      }

      current = await assertPublicHttpUrl(new URL(location, current).toString());
      continue;
    }

    if (!response.ok) {
      throw new Error("Image server returned HTTP " + response.status + ".");
    }

    const contentLength = Number(response.headers.get("content-length") || 0);
    if (contentLength > MAX_IMAGE_BYTES) {
      throw new Error("Image is larger than the 8 MB limit.");
    }

    const mime = (response.headers.get("content-type") || "")
      .split(";")[0]
      .trim()
      .toLowerCase();

    if (!ALLOWED_MIME.has(mime)) {
      throw new Error(
        "URL did not return a supported raster image (PNG, JPEG, WebP, GIF, or AVIF).",
      );
    }

    return {
      buffer: await readBodyWithLimit(response),
      finalUrl: current.toString(),
      mime,
    };
  }

  throw new Error("Too many redirects.");
}

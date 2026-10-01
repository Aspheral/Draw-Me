const dns = require("node:dns").promises;
const { isIP } = require("node:net");
const sharp = require("sharp");

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

const FORBIDDEN_HOSTS = new Set([
  "localhost",
  "localhost.localdomain",
  "metadata.google.internal",
  "metadata",
]);

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, X-Draw-Me-Key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function sendJson(res, data, status = 200) {
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    res.setHeader(key, value);
  }
  return res.status(status).json(data);
}

function clampInt(value, min, max) {
  return Math.max(min, Math.min(max, Math.round(value)));
}

function numberOr(value, fallback) {
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : fallback;
}

function one(value) {
  return Array.isArray(value) ? value[0] : value;
}

function numberQuery(value) {
  const raw = one(value);
  if (typeof raw !== "string" || raw.trim() === "") return undefined;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function bodyFromQuery(query) {
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

function isPrivateIPv4(ip) {
  const parts = ip.split(".").map(Number);

  if (
    parts.length !== 4 ||
    parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)
  ) {
    return true;
  }

  const [a, b] = parts;

  return (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 0) ||
    (a === 192 && b === 168) ||
    (a === 198 && (b === 18 || b === 19)) ||
    a >= 224
  );
}

function isPrivateIPv6(ip) {
  const value = ip.toLowerCase();

  if (value === "::" || value === "::1") return true;

  if (
    value.startsWith("fe80:") ||
    value.startsWith("fe90:") ||
    value.startsWith("fea0:") ||
    value.startsWith("feb0:")
  ) {
    return true;
  }

  if (value.startsWith("fc") || value.startsWith("fd")) return true;

  const mapped = value.match(/::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  return mapped ? isPrivateIPv4(mapped[1]) : false;
}

function isPrivateAddress(ip) {
  const family = isIP(ip);
  if (family === 4) return isPrivateIPv4(ip);
  if (family === 6) return isPrivateIPv6(ip);
  return true;
}

async function assertPublicHttpUrl(input) {
  let url;

  try {
    url = new URL(input);
  } catch {
    throw new Error("Invalid URL.");
  }

  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error("Only http:// and https:// image URLs are supported.");
  }

  if (url.username || url.password) {
    throw new Error("URLs containing embedded credentials are not allowed.");
  }

  const hostname = url.hostname.toLowerCase().replace(/\.$/, "");

  if (
    FORBIDDEN_HOSTS.has(hostname) ||
    hostname.endsWith(".localhost") ||
    hostname.endsWith(".local") ||
    hostname.endsWith(".internal")
  ) {
    throw new Error("Private/local network targets are not allowed.");
  }

  if (isIP(hostname)) {
    if (isPrivateAddress(hostname)) {
      throw new Error("Private/local IP targets are not allowed.");
    }
    return url;
  }

  const addresses = await dns.lookup(hostname, {
    all: true,
    verbatim: true,
  });

  if (
    addresses.length === 0 ||
    addresses.some((entry) => isPrivateAddress(entry.address))
  ) {
    throw new Error("URL resolved to a private or invalid network address.");
  }

  return url;
}

async function readBodyWithLimit(response) {
  if (!response.body) throw new Error("Image response had no body.");

  const reader = response.body.getReader();
  const chunks = [];
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

    chunks.push(Buffer.from(value));
  }

  return Buffer.concat(chunks);
}

async function fetchImageFromPublicUrl(input) {
  let current = await assertPublicHttpUrl(input);

  for (
    let redirectCount = 0;
    redirectCount <= MAX_REDIRECTS;
    redirectCount += 1
  ) {
    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      REQUEST_TIMEOUT_MS,
    );

    let response;

    try {
      response = await fetch(current, {
        method: "GET",
        redirect: "manual",
        signal: controller.signal,
        headers: {
          "User-Agent": "DrawMeImageProcessor/1.0",
          Accept:
            "image/avif,image/webp,image/png,image/jpeg,image/gif;q=0.9,*/*;q=0.1",
        },
      });
    } catch (error) {
      if (error && error.name === "AbortError") {
        throw new Error("Image request timed out.");
      }
      throw new Error("Could not fetch the image URL.");
    } finally {
      clearTimeout(timeout);
    }

    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");

      if (!location) {
        throw new Error(
          "Image URL redirected without a Location header.",
        );
      }

      if (redirectCount === MAX_REDIRECTS) {
        throw new Error("Too many redirects.");
      }

      current = await assertPublicHttpUrl(
        new URL(location, current).toString(),
      );
      continue;
    }

    if (!response.ok) {
      throw new Error(
        "Image server returned HTTP " + response.status + ".",
      );
    }

    const contentLength = Number(
      response.headers.get("content-length") || 0,
    );

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

function toHex(rgb) {
  return (
    "#" +
    rgb
      .map((value) =>
        clampInt(value, 0, 255).toString(16).padStart(2, "0"),
      )
      .join("")
  ).toUpperCase();
}

function isNearWhite(r, g, b, threshold) {
  return r >= threshold && g >= threshold && b >= threshold;
}

function squaredDistance(a, b) {
  const dr = a[0] - b[0];
  const dg = a[1] - b[1];
  const db = a[2] - b[2];
  return dr * dr + dg * dg + db * db;
}

function buildPalette(raw, colors, skipWhite, whiteThreshold) {
  const buckets = new Map();

  for (let i = 0; i < raw.length; i += 3) {
    const r = raw[i];
    const g = raw[i + 1];
    const b = raw[i + 2];

    if (skipWhite && isNearWhite(r, g, b, whiteThreshold)) {
      continue;
    }

    const key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
    const bucket = buckets.get(key);

    if (bucket) {
      bucket.count += 1;
      bucket.r += r;
      bucket.g += g;
      bucket.b += b;
    } else {
      buckets.set(key, { count: 1, r, g, b });
    }
  }

  return [...buckets.values()]
    .sort((a, b) => b.count - a.count)
    .slice(0, colors)
    .map((bucket) => [
      Math.round(bucket.r / bucket.count),
      Math.round(bucket.g / bucket.count),
      Math.round(bucket.b / bucket.count),
    ]);
}

function nearestPaletteIndex(pixel, palette) {
  let bestIndex = 0;
  let bestDistance = Number.POSITIVE_INFINITY;

  for (let i = 0; i < palette.length; i += 1) {
    const distance = squaredDistance(pixel, palette[i]);

    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = i;
    }
  }

  return bestIndex;
}

async function processImage(buffer, options) {
  const width = clampInt(options.width, 8, 128);
  const height = clampInt(options.height, 8, 128);
  const colorCount = clampInt(options.colors, 2, 32);
  const whiteThreshold = clampInt(
    options.whiteThreshold,
    200,
    255,
  );

  const { data, info } = await sharp(buffer, {
    animated: false,
    limitInputPixels: 40_000_000,
  })
    .rotate()
    .resize({
      width,
      height,
      fit: "contain",
      background: { r: 255, g: 255, b: 255, alpha: 1 },
      kernel: sharp.kernel.lanczos3,
    })
    .flatten({ background: "#FFFFFF" })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });

  if (info.channels !== 3) {
    throw new Error(
      "Unexpected processed channel count: " +
        info.channels +
        ".",
    );
  }

  const palette = buildPalette(
    data,
    colorCount,
    options.skipWhite,
    whiteThreshold,
  );

  if (palette.length === 0) {
    return {
      version: 1,
      width: info.width,
      height: info.height,
      groups: [],
      stats: {
        colors: 0,
        segments: 0,
        drawablePixels: 0,
        skippedPixels: info.width * info.height,
      },
    };
  }

  const mapped = new Int16Array(info.width * info.height);
  mapped.fill(-1);

  let drawablePixels = 0;
  let skippedPixels = 0;

  for (
    let pixelIndex = 0, i = 0;
    i < data.length;
    i += 3, pixelIndex += 1
  ) {
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];

    if (
      options.skipWhite &&
      isNearWhite(r, g, b, whiteThreshold)
    ) {
      skippedPixels += 1;
      continue;
    }

    mapped[pixelIndex] = nearestPaletteIndex(
      [r, g, b],
      palette,
    );
    drawablePixels += 1;
  }

  const groups = palette.map((rgb) => ({
    color: toHex(rgb),
    rgb,
    segments: [],
  }));

  let segmentCount = 0;

  for (let y = 0; y < info.height; y += 1) {
    let x = 0;

    while (x < info.width) {
      const index = mapped[y * info.width + x];

      if (index < 0) {
        x += 1;
        continue;
      }

      const x0 = x;
      x += 1;

      while (
        x < info.width &&
        mapped[y * info.width + x] === index
      ) {
        x += 1;
      }

      groups[index].segments.push([y, x0, x - 1]);
      segmentCount += 1;
    }
  }

  const usedGroups = groups.filter(
    (group) => group.segments.length > 0,
  );

  return {
    version: 1,
    width: info.width,
    height: info.height,
    groups: usedGroups,
    stats: {
      colors: usedGroups.length,
      segments: segmentCount,
      drawablePixels,
      skippedPixels,
    },
  };
}

module.exports = async function handler(req, res) {
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    res.setHeader(key, value);
  }

  if (req.method === "OPTIONS") {
    return res.status(204).end();
  }

  let body;

  if (req.method === "GET") {
    body = bodyFromQuery(req.query || {});
  } else if (req.method === "POST") {
    try {
      if (typeof req.body === "string") {
        body = JSON.parse(req.body);
      } else if (req.body && typeof req.body === "object") {
        body = req.body;
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
    return sendJson(
      res,
      { ok: false, error: "Method not allowed." },
      405,
    );
  }

  const configuredKey = process.env.DRAW_ME_API_KEY
    ? process.env.DRAW_ME_API_KEY.trim()
    : "";

  if (
    configuredKey &&
    req.headers["x-draw-me-key"] !== configuredKey
  ) {
    return sendJson(
      res,
      { ok: false, error: "Unauthorized." },
      401,
    );
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

    return sendJson(
      res,
      { ok: false, error: message },
      422,
    );
  }
};

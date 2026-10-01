import sharp from "sharp";

export type Segment = [y: number, x0: number, x1: number];

export type DrawingGroup = {
  color: string;
  rgb: [number, number, number];
  segments: Segment[];
};

export type DrawingPayload = {
  version: 1;
  width: number;
  height: number;
  groups: DrawingGroup[];
  stats: {
    colors: number;
    segments: number;
    drawablePixels: number;
    skippedPixels: number;
  };
};

type Pixel = [number, number, number];

type Bucket = {
  count: number;
  r: number;
  g: number;
  b: number;
};

function clampInt(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, Math.round(value)));
}

function toHex([r, g, b]: Pixel): string {
  return (
    "#" +
    [r, g, b]
      .map((value) =>
        clampInt(value, 0, 255).toString(16).padStart(2, "0"),
      )
      .join("")
  ).toUpperCase();
}

function isNearWhite(
  r: number,
  g: number,
  b: number,
  threshold: number,
): boolean {
  return r >= threshold && g >= threshold && b >= threshold;
}

function squaredDistance(a: Pixel, b: Pixel): number {
  const dr = a[0] - b[0];
  const dg = a[1] - b[1];
  const db = a[2] - b[2];

  return dr * dr + dg * dg + db * db;
}

function buildPalette(
  raw: Buffer,
  colors: number,
  skipWhite: boolean,
  whiteThreshold: number,
): Pixel[] {
  const buckets = new Map<number, Bucket>();

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
    .map(
      (bucket) =>
        [
          Math.round(bucket.r / bucket.count),
          Math.round(bucket.g / bucket.count),
          Math.round(bucket.b / bucket.count),
        ] as Pixel,
    );
}

function nearestPaletteIndex(pixel: Pixel, palette: Pixel[]): number {
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

export async function processImage(
  buffer: Buffer,
  options: {
    width: number;
    height: number;
    colors: number;
    skipWhite: boolean;
    whiteThreshold: number;
  },
): Promise<DrawingPayload> {
  const width = clampInt(options.width, 8, 128);
  const height = clampInt(options.height, 8, 128);
  const colorCount = clampInt(options.colors, 2, 32);
  const whiteThreshold = clampInt(options.whiteThreshold, 200, 255);

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
      "Unexpected processed channel count: " + info.channels + ".",
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

    mapped[pixelIndex] = nearestPaletteIndex([r, g, b], palette);
    drawablePixels += 1;
  }

  const groups: DrawingGroup[] = palette.map((rgb) => ({
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

      const x1 = x - 1;
      groups[index].segments.push([y, x0, x1]);
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

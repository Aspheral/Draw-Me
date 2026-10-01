import { lookup } from "node:dns/promises";
import { isIP } from "node:net";

const FORBIDDEN_HOSTS = new Set([
  "localhost",
  "localhost.localdomain",
  "metadata.google.internal",
  "metadata",
]);

function isPrivateIPv4(ip: string): boolean {
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

function isPrivateIPv6(ip: string): boolean {
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
  if (mapped) return isPrivateIPv4(mapped[1]);

  return false;
}

function isPrivateAddress(ip: string): boolean {
  const family = isIP(ip);

  if (family === 4) return isPrivateIPv4(ip);
  if (family === 6) return isPrivateIPv6(ip);

  return true;
}

export async function assertPublicHttpUrl(input: string): Promise<URL> {
  let url: URL;

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

  const addresses = await lookup(hostname, { all: true, verbatim: true });

  if (
    addresses.length === 0 ||
    addresses.some((entry) => isPrivateAddress(entry.address))
  ) {
    throw new Error("URL resolved to a private or invalid network address.");
  }

  return url;
}

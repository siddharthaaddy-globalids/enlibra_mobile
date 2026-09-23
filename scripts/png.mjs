/**
 * A PNG encoder, so icon generation needs a rasteriser and nothing else.
 *
 * It exists for one requirement the rasteriser will not meet: iOS app icons
 * must have no alpha channel at all -- App Store validation rejects them --
 * while Android adaptive foregrounds must have one. Encoding here means both
 * come out of the same pipeline, rather than adding an image-processing
 * dependency to flatten one of them.
 */

import { deflateSync } from "node:zlib";

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) {
    c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([length, body, crc]);
}

/**
 * @param rgba   RGBA pixel buffer, width*height*4 bytes
 * @param alpha  keep the alpha channel (colour type 6) or drop it (type 2).
 *               Dropping it assumes the image has already been composited onto
 *               an opaque background -- alpha is discarded, not flattened.
 */
export function encodePng(rgba, width, height, { alpha = true } = {}) {
  const channels = alpha ? 4 : 3;
  const stride = width * channels;

  // One filter byte per scanline. Filter 0 (None) keeps this simple; the icons
  // are small and flat, and deflate handles them well regardless.
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    const rowStart = y * (stride + 1);
    raw[rowStart] = 0;
    for (let x = 0; x < width; x++) {
      const src = (y * width + x) * 4;
      const dst = rowStart + 1 + x * channels;
      raw[dst] = rgba[src];
      raw[dst + 1] = rgba[src + 1];
      raw[dst + 2] = rgba[src + 2];
      if (alpha) raw[dst + 3] = rgba[src + 3];
    }
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = alpha ? 6 : 2; // colour type: RGBA / RGB
  ihdr[10] = 0; // deflate
  ihdr[11] = 0; // adaptive filtering
  ihdr[12] = 0; // no interlace

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/** #rgb / #rrggbb -> {r,g,b}. */
export function parseHexColor(value) {
  const hex = value.replace("#", "").trim();
  const full = hex.length === 3 ? [...hex].map((c) => c + c).join("") : hex;
  if (!/^[0-9a-f]{6}$/i.test(full)) {
    throw new Error(`not a hex colour: ${value}`);
  }
  return {
    r: parseInt(full.slice(0, 2), 16),
    g: parseInt(full.slice(2, 4), 16),
    b: parseInt(full.slice(4, 6), 16),
  };
}

/**
 * Centres [src] on a [size]x[size] canvas over [background], or over
 * transparency when background is null.
 *
 * Source-over compositing, straight (un-premultiplied) alpha -- which is what
 * resvg hands back.
 */
export function composite(src, srcWidth, srcHeight, size, background) {
  const out = Buffer.alloc(size * size * 4);

  if (background) {
    for (let i = 0; i < size * size; i++) {
      out[i * 4] = background.r;
      out[i * 4 + 1] = background.g;
      out[i * 4 + 2] = background.b;
      out[i * 4 + 3] = 255;
    }
  }

  const offsetX = Math.round((size - srcWidth) / 2);
  const offsetY = Math.round((size - srcHeight) / 2);

  for (let y = 0; y < srcHeight; y++) {
    const destY = y + offsetY;
    if (destY < 0 || destY >= size) continue;
    for (let x = 0; x < srcWidth; x++) {
      const destX = x + offsetX;
      if (destX < 0 || destX >= size) continue;

      const s = (y * srcWidth + x) * 4;
      const d = (destY * size + destX) * 4;
      const srcAlpha = src[s + 3] / 255;
      if (srcAlpha === 0) continue;

      const destAlpha = out[d + 3] / 255;
      const outAlpha = srcAlpha + destAlpha * (1 - srcAlpha);
      for (let c = 0; c < 3; c++) {
        out[d + c] = Math.round(
          (src[s + c] * srcAlpha + out[d + c] * destAlpha * (1 - srcAlpha)) /
            outAlpha
        );
      }
      out[d + 3] = Math.round(outAlpha * 255);
    }
  }

  return out;
}

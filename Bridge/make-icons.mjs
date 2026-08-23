#!/usr/bin/env node
// Rasterise the app icon into the PNGs a phone needs to install the bridge as
// an app.
//
// Chrome only mints a real installed app (a WebAPK, no address bar) when the
// manifest offers a RASTER icon of at least 192px — an SVG alone leaves it
// creating a plain bookmark that opens in a tab, which is exactly the "it still
// looks like a web page" symptom. iOS ignores SVG for `apple-touch-icon` too.
//
// Written by hand rather than pulled from a library: the bridge ships with no
// dependencies, the artwork is three shapes, and Node's zlib is all a PNG
// encoder actually needs. Re-run after changing web/icon.svg:
//
//     node Bridge/make-icons.mjs
//
// The same geometry as web/icon.svg, in its 180-unit space.

import { deflateSync } from "node:zlib"
import { writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const WEB = join(dirname(fileURLToPath(import.meta.url)), "web")

const BG = [0x1c, 0x1c, 0x1e]

/**
 * The mark's colour: Claude orange, or a hue derived from this Mac's name.
 *
 * One phone can hold two of these apps, and two identical icons on a Home Screen
 * is a choice made by reading labels. The name alone is not enough — an icon is
 * what a thumb aims at. So the second Mac's icon is a different colour, derived
 * rather than chosen, which means it is stable across reinstalls and needs
 * nobody to pick anything.
 */
const FG = (() => {
  const name = (process.argv[2] ?? process.env.CS_BRIDGE_NAME ?? "").trim()
  if (!name) return [0xd9, 0x77, 0x57]
  let hash = 0x811c9dc5
  for (const byte of Buffer.from(name, "utf8")) {
    hash ^= byte
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  // Claude orange is ~18°; every icon keeps its saturation and lightness so the
  // family still looks like one app.
  return hsl(hash % 360, 0.62, 0.59)
})()

function hsl(h, s, l) {
  const c = (1 - Math.abs(2 * l - 1)) * s
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1))
  const m = l - c / 2
  const [r, g, b] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x]
    : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x]
  return [r, g, b].map((v) => Math.round((v + m) * 255))
}
const UNITS = 180
const CORNER = 40
const STROKE = 12

/** The prompt mark: a chevron and the line after it. */
const SEGMENTS = [
  [52, 62, 78, 90],
  [78, 90, 52, 118],
  [92, 118, 132, 118],
]

function distanceToSegment(px, py, [ax, ay, bx, by]) {
  const dx = bx - ax
  const dy = by - ay
  const length = dx * dx + dy * dy
  const t = length === 0 ? 0 : Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / length))
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy))
}

/** Signed distance to the rounded rectangle that backs the icon. */
function insideBackground(x, y, radius) {
  if (radius <= 0) return x >= 0 && x <= UNITS && y >= 0 && y <= UNITS
  const cx = Math.min(Math.max(x, radius), UNITS - radius)
  const cy = Math.min(Math.max(y, radius), UNITS - radius)
  return Math.hypot(x - cx, y - cy) <= radius + 1e-9
}

/**
 * @param {number} size    pixels
 * @param {boolean} maskable  full-bleed square with the mark pulled into the
 *   safe zone — Android crops maskable icons to whatever shape the launcher uses.
 */
function render(size, { maskable = false } = {}) {
  const pixels = Buffer.alloc(size * size * 4)
  const scale = UNITS / size
  const radius = maskable ? 0 : CORNER
  // A launcher may crop up to ~20% off each edge of a maskable icon.
  const shrink = maskable ? 0.72 : 1
  const samples = 3 // 3×3 supersampling: enough for round caps at 192px

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let background = 0
      let mark = 0
      for (let sy = 0; sy < samples; sy++) {
        for (let sx = 0; sx < samples; sx++) {
          const ux = (x + (sx + 0.5) / samples) * scale
          const uy = (y + (sy + 0.5) / samples) * scale
          if (insideBackground(ux, uy, radius)) background++
          // Scaling the sample point about the centre scales the artwork.
          const gx = (ux - UNITS / 2) / shrink + UNITS / 2
          const gy = (uy - UNITS / 2) / shrink + UNITS / 2
          for (const segment of SEGMENTS) {
            if (distanceToSegment(gx, gy, segment) <= STROKE / 2) {
              mark++
              break
            }
          }
        }
      }
      const total = samples * samples
      const alpha = background / total
      const ink = Math.min(mark / total, alpha)
      const offset = (y * size + x) * 4
      for (let channel = 0; channel < 3; channel++) {
        // Composite the mark over the background, both already premultiplied by
        // their own coverage, then un-premultiply for the straight-alpha PNG.
        const value = BG[channel] * (alpha - ink) + FG[channel] * ink
        pixels[offset + channel] = alpha === 0 ? 0 : Math.round(value / alpha)
      }
      pixels[offset + 3] = Math.round(alpha * 255)
    }
  }
  return pixels
}

// ---------------------------------------------------------------- PNG encoder

const CRC_TABLE = (() => {
  const table = new Int32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c
  }
  return table
})()

function crc32(buffer) {
  let c = 0xffffffff
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

function chunk(type, data) {
  const length = Buffer.alloc(4)
  length.writeUInt32BE(data.length)
  const body = Buffer.concat([Buffer.from(type, "ascii"), data])
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(body))
  return Buffer.concat([length, body, crc])
}

function png(size, pixels) {
  const header = Buffer.alloc(13)
  header.writeUInt32BE(size, 0)
  header.writeUInt32BE(size, 4)
  header[8] = 8 // bit depth
  header[9] = 6 // colour type: RGBA
  // 10..12: deflate, adaptive filtering, no interlace — all zero.

  // One filter byte (0 = none) per scanline; the artwork is flat colour, so
  // deflate does the work and a cleverer filter would buy nothing.
  const raw = Buffer.alloc(size * (size * 4 + 1))
  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0
    pixels.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4)
  }

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ])
}

// ---------------------------------------------------------------- output

const targets = [
  ["icon-192.png", 192, {}],
  ["icon-512.png", 512, {}],
  ["icon-maskable-512.png", 512, { maskable: true }],
  // iOS rounds the corners itself, so the Home Screen icon is a full square.
  ["apple-touch-icon.png", 180, { maskable: true }],
]

for (const [name, size, options] of targets) {
  const file = join(WEB, name)
  writeFileSync(file, png(size, render(size, options)))
  console.log(`wrote ${name} (${size}×${size})`)
}

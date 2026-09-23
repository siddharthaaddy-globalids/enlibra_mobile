#!/usr/bin/env node
/**
 * Renders the Enlibra mark into every launcher-icon slot the project has.
 *
 * Source of truth is `assets/logo/enlibra-mark.svg`; everything under
 * `android/`, `ios/` and `web/` is generated from it, so re-running this after
 * an artwork change is the whole update.
 *
 * Usage (from scripts/):
 *   node make-icons.mjs [--source ../assets/logo/enlibra-mark.svg]
 *                       [--background "#262624"] [--check]
 *
 *   --check   verify the icons are current without writing; exits 1 otherwise.
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join, resolve, relative } from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

import { Resvg } from "@resvg/resvg-js";

import { encodePng, parseHexColor, composite } from "./png.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(here, "..");

/**
 * The mark is portrait (149x190) and every icon slot is square, so it is fitted
 * by height and centred, inset to leave breathing room. 0.62 is the figure that
 * keeps it clear of the circular mask Android and iOS both apply.
 */
const INSET = 0.62;

/** Android adaptive foregrounds live on a 108dp canvas of which only the middle
 *  66dp is guaranteed visible, so the mark is inset harder there. */
const ADAPTIVE_INSET = 0.52;

const ANDROID_DENSITIES = [
  { dir: "mipmap-mdpi", legacy: 48, adaptive: 108 },
  { dir: "mipmap-hdpi", legacy: 72, adaptive: 162 },
  { dir: "mipmap-xhdpi", legacy: 96, adaptive: 216 },
  { dir: "mipmap-xxhdpi", legacy: 144, adaptive: 324 },
  { dir: "mipmap-xxxhdpi", legacy: 192, adaptive: 432 },
];

/** Matches the slots in ios/Runner/Assets.xcassets/AppIcon.appiconset. */
const IOS_ICONS = [
  ["Icon-App-20x20@1x.png", 20],
  ["Icon-App-20x20@2x.png", 40],
  ["Icon-App-20x20@3x.png", 60],
  ["Icon-App-29x29@1x.png", 29],
  ["Icon-App-29x29@2x.png", 58],
  ["Icon-App-29x29@3x.png", 87],
  ["Icon-App-40x40@1x.png", 40],
  ["Icon-App-40x40@2x.png", 80],
  ["Icon-App-40x40@3x.png", 120],
  ["Icon-App-60x60@2x.png", 120],
  ["Icon-App-60x60@3x.png", 180],
  ["Icon-App-76x76@1x.png", 76],
  ["Icon-App-76x76@2x.png", 152],
  ["Icon-App-83.5x83.5@2x.png", 167],
  ["Icon-App-1024x1024@1x.png", 1024],
];

const WEB_ICONS = [
  ["web/favicon.png", 32, INSET],
  ["web/icons/Icon-192.png", 192, INSET],
  ["web/icons/Icon-512.png", 512, INSET],
  // Maskable icons are cropped to a circle inscribed in 80% of the canvas.
  ["web/icons/Icon-maskable-192.png", 192, ADAPTIVE_INSET],
  ["web/icons/Icon-maskable-512.png", 512, ADAPTIVE_INSET],
];

function parseArgs(argv) {
  const opts = {
    source: join(projectRoot, "assets", "logo", "enlibra-mark.svg"),
    background: "#262624", // AppColors.darkBackground
    check: false,
  };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "--source": opts.source = resolve(argv[++i]); break;
      case "--background": opts.background = argv[++i]; break;
      case "--check": opts.check = true; break;
      case "-h":
      case "--help":
        console.log(
          "node make-icons.mjs [--source <svg>] [--background <#hex>] [--check]"
        );
        process.exit(0);
        break;
      default:
        console.error(`make-icons: unknown option ${argv[i]}`);
        process.exit(1);
    }
  }
  return opts;
}

/**
 * Renders the SVG at the pixel height it will occupy, rather than rendering
 * once and resampling. Vector all the way down to the target size is why a
 * 20x20 icon still reads.
 */
function renderMark(svg, height) {
  const resvg = new Resvg(svg, { fitTo: { mode: "height", value: height } });
  const image = resvg.render();
  return { pixels: image.pixels, width: image.width, height: image.height };
}

function iconPng(svg, size, inset, background) {
  const mark = renderMark(svg, Math.max(1, Math.round(size * inset)));
  const rgba = composite(mark.pixels, mark.width, mark.height, size, background);
  // No alpha when there is a background: iOS requires it, and an opaque icon
  // has nothing to gain from carrying a fourth channel.
  return encodePng(rgba, size, size, { alpha: background === null });
}

const LOCK_PATH = "scripts/icons.lock.json";

const written = [];

function emit(relativePath, bytes) {
  const target = join(projectRoot, relativePath);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, bytes);
  written.push(relativePath);
}

/**
 * `--check` compares the artwork's hash against what was last generated from,
 * and confirms every target still exists. It deliberately does not re-render
 * and diff pixels: that would make CI depend on the rasteriser producing
 * byte-identical output on a different OS and version, and the failure it is
 * actually guarding against is someone changing the SVG without regenerating.
 */
function check(sourceHash, opts) {
  const lockPath = join(projectRoot, LOCK_PATH);
  if (!existsSync(lockPath)) {
    console.error(
      `make-icons: no ${LOCK_PATH}. Run \`node scripts/make-icons.mjs\`.`
    );
    process.exit(1);
  }
  const lock = JSON.parse(readFileSync(lockPath, "utf8"));
  const problems = [];

  if (lock.sha256 !== sourceHash) {
    problems.push(
      `${lock.source} has changed since the icons were generated from it`
    );
  }
  if (lock.background !== opts.background) {
    problems.push(
      `background is ${opts.background} but icons were generated with ${lock.background}`
    );
  }
  for (const file of lock.generated) {
    if (!existsSync(join(projectRoot, file))) problems.push(`missing ${file}`);
  }

  if (problems.length > 0) {
    console.error(
      "make-icons: icons are out of date:\n  " +
        problems.join("\n  ") +
        "\n  Run `node scripts/make-icons.mjs` and commit the result."
    );
    process.exit(1);
  }
  console.log(`make-icons: ${lock.generated.length} icons match the artwork.`);
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (!existsSync(opts.source)) {
    console.error(`make-icons: no such file: ${opts.source}`);
    process.exit(1);
  }
  const svg = readFileSync(opts.source, "utf8");
  const sourceHash = createHash("sha256").update(svg).digest("hex");

  if (opts.check) {
    check(sourceHash, opts);
    return;
  }

  const background = parseHexColor(opts.background);

  for (const density of ANDROID_DENSITIES) {
    const base = `android/app/src/main/res/${density.dir}`;
    emit(
      `${base}/ic_launcher.png`,
      iconPng(svg, density.legacy, INSET, background)
    );
    // The adaptive foreground is transparent: the background layer underneath
    // is a flat colour, and the launcher animates the two independently.
    emit(
      `${base}/ic_launcher_foreground.png`,
      iconPng(svg, density.adaptive, ADAPTIVE_INSET, null)
    );
  }

  emit(
    "android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml",
    Buffer.from(
      '<?xml version="1.0" encoding="utf-8"?>\n' +
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n' +
        '    <background android:drawable="@color/ic_launcher_background" />\n' +
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n' +
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />\n' +
        "</adaptive-icon>\n",
      "utf8"
    )
  );

  emit(
    "android/app/src/main/res/values/ic_launcher_background.xml",
    Buffer.from(
      '<?xml version="1.0" encoding="utf-8"?>\n' +
        "<resources>\n" +
        `    <color name="ic_launcher_background">${opts.background.toUpperCase()}</color>\n` +
        "</resources>\n",
      "utf8"
    )
  );

  for (const [name, size] of IOS_ICONS) {
    emit(
      `ios/Runner/Assets.xcassets/AppIcon.appiconset/${name}`,
      iconPng(svg, size, INSET, background)
    );
  }

  for (const [path, size, inset] of WEB_ICONS) {
    emit(path, iconPng(svg, size, inset, background));
  }

  // What `--check` reads. Records the artwork this output came from, so a
  // changed SVG with stale icons beside it is a CI failure rather than a
  // surprise on someone's home screen.
  writeFileSync(
    join(projectRoot, LOCK_PATH),
    JSON.stringify(
      {
        source: relative(projectRoot, opts.source).split("\\").join("/"),
        sha256: sourceHash,
        background: opts.background,
        generated: written,
      },
      null,
      2
    ) + "\n"
  );

  console.log(`make-icons: wrote ${written.length} files.`);
  for (const line of written) {
    console.log(`  ${line}`);
  }
}

main();

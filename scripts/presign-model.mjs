#!/usr/bin/env node
/**
 * Mint pre-signed S3 GET URLs for a quantized model so a phone can download it
 * without any AWS identity of its own.
 *
 * The real path for this is the managed-service-api content endpoint
 * (`GET /slms/{slmId}/runs/{runId}/files/content`), which signs with the SI
 * Factory credentials behind Cognito. This script is the same last step --
 * `GetObjectCommand` + `getSignedUrl` -- run from a laptop that already has
 * the credentials, so model loading can be built and tested before the app
 * carries a Cognito login.
 *
 * Usage:
 *   node presign-model.mjs s3://enlibra/dss/dev/runs/<run>/outputs/gkd/runs/<model>/gguf/
 *
 * Options:
 *   --profile <name>     AWS profile to sign with (default: standard chain)
 *   --region <region>    bucket region (default: detected, else AWS_REGION)
 *   --expires <seconds>  URL lifetime, max 604800 (7 days). Default 604800.
 *   --file <substring>   only objects whose key contains this (repeatable)
 *   --manifest <path>    also write a source file the app can be pointed at
 *   --checksum           stream each object to compute its sha256 first.
 *                        Exact integrity checking on the phone, but it moves
 *                        the whole file over your connection to do it.
 *   --json               emit JSON instead of the human-readable report
 *
 * Nothing here is written back to S3: read-only, plus the local manifest file.
 */

import { writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { pipeline } from "node:stream/promises";

import {
  S3Client,
  ListObjectsV2Command,
  GetBucketLocationCommand,
  GetObjectCommand,
  HeadObjectCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { fromNodeProviderChain } from "@aws-sdk/credential-providers";

// The AWS SDK v3 builds we depend on require Node 20+. Saying so here beats a
// stack trace from inside a transitive dependency.
const [major] = process.versions.node.split(".").map(Number);
if (major < 20) {
  console.error(
    "presign-model: needs Node 20 or newer (running " +
      process.versions.node +
      ").\n  nvm use 22"
  );
  process.exit(1);
}

const MAX_EXPIRES = 604800; // SigV4 ceiling: 7 days.

/** The only weights format the app can load: llama.cpp reads GGUF and nothing else. */
const WEIGHT_EXTENSIONS = [".gguf"];

/**
 * Formats that are weights but not *loadable* weights. A run's `quantized/`
 * directory holds a Hugging Face checkpoint -- `model.safetensors` plus
 * config and tokenizer JSON -- which is what the quantisation pipeline
 * produces and what llama.cpp cannot open. Signing it would hand over a URL
 * that downloads 2.5GB and then fails on the phone, so it is refused here
 * with the conversion step spelled out instead.
 */
const UNUSABLE_EXTENSIONS = [".safetensors", ".bin", ".pt", ".pth"];

function parseArgs(argv) {
  const opts = {
    target: null,
    profile: process.env.AWS_PROFILE ?? undefined,
    region: process.env.AWS_REGION ?? process.env.AWS_DEFAULT_REGION ?? undefined,
    expires: MAX_EXPIRES,
    filters: [],
    manifest: null,
    checksum: false,
    json: false,
    accelerate: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) fail(arg + " needs a value");
      return v;
    };
    switch (arg) {
      case "--profile": opts.profile = next(); break;
      case "--region": opts.region = next(); break;
      case "--expires": opts.expires = Number(next()); break;
      case "--file": opts.filters.push(next()); break;
      case "--manifest": opts.manifest = next(); break;
      case "--checksum": opts.checksum = true; break;
      case "--accelerate": opts.accelerate = true; break;
      case "--json": opts.json = true; break;
      case "-h":
      case "--help": usage(); process.exit(0); break;
      default:
        if (arg.startsWith("-")) fail("unknown option " + arg);
        if (opts.target) fail("pass exactly one s3:// location");
        opts.target = arg;
    }
  }

  if (!opts.target) { usage(); process.exit(1); }
  if (!Number.isInteger(opts.expires) || opts.expires < 1 || opts.expires > MAX_EXPIRES) {
    fail("--expires must be 1.." + MAX_EXPIRES + " seconds");
  }
  return opts;
}

function usage() {
  console.log([
    "Mint pre-signed download URLs for a quantized model in S3.",
    "",
    "  node presign-model.mjs s3://bucket/prefix/ [options]",
    "",
    "  --profile <name>     AWS profile to sign with",
    "  --region <region>    bucket region (detected when omitted)",
    "  --expires <seconds>  URL lifetime, max " + MAX_EXPIRES + " (7 days)",
    "  --file <substring>   only keys containing this (repeatable)",
    "  --manifest <path>    write a model source file for the app",
    "  --checksum           compute sha256 by streaming each object",
    "  --accelerate         sign against the S3 Transfer Acceleration endpoint",
    "  --json               machine-readable output",
  ].join("\n"));
}

function fail(message) {
  console.error("presign-model: " + message);
  process.exit(1);
}

/** `s3://bucket/some/prefix/` or `s3://bucket/some/key.gguf`. */
function parseS3Uri(uri) {
  const match = /^s3:\/\/([^/]+)\/?(.*)$/.exec(uri);
  if (!match) fail("not an s3:// URI: " + uri);
  return { bucket: match[1], key: match[2] };
}

/**
 * A pre-signed URL is only valid against the host of the region the bucket
 * actually lives in, so signing with the wrong region yields a URL that fails
 * at download time rather than here.
 *
 * Three ways to find out, cheapest permission first. `GetBucketLocation` is the
 * official one and the one a read-only identity is least likely to hold, so it
 * goes last: an anonymous HEAD of the bucket endpoint answers with
 * `x-amz-bucket-region` even when it answers 403, which needs no permission at
 * all.
 */
async function resolveRegion(bucket, credentials, hint) {
  if (hint) return hint;

  try {
    const res = await fetch("https://" + bucket + ".s3.amazonaws.com/", {
      method: "HEAD",
    });
    const region = res.headers.get("x-amz-bucket-region");
    if (region) return region;
  } catch {
    // No network, or DNS refused a bucket name with dots in it. Fall through.
  }

  const probe = new S3Client({ region: "us-east-1", credentials });
  try {
    const res = await probe.send(new GetBucketLocationCommand({ Bucket: bucket }));
    // The API answers "" for us-east-1, and EU for the legacy eu-west-1 alias.
    const raw = res.LocationConstraint;
    if (!raw) return "us-east-1";
    return raw === "EU" ? "eu-west-1" : raw;
  } catch {
    console.warn(
      "presign-model: could not determine the bucket's region; assuming " +
      "us-east-1. Pass --region if the download 403s."
    );
    return "us-east-1";
  } finally {
    probe.destroy();
  }
}

async function listObjects(s3, bucket, prefix) {
  const out = [];
  let token;
  do {
    const res = await s3.send(new ListObjectsV2Command({
      Bucket: bucket, Prefix: prefix, ContinuationToken: token,
    }));
    for (const obj of res.Contents ?? []) {
      if (obj.Key.endsWith("/")) continue; // directory marker
      out.push({ key: obj.Key, size: obj.Size ?? 0 });
    }
    token = res.IsTruncated ? res.NextContinuationToken : undefined;
  } while (token);
  return out;
}

function isDenied(err) {
  return (
    err?.name === "AccessDenied" ||
    err?.name === "AccessDeniedException" ||
    err?.name === "Forbidden" ||
    err?.$metadata?.httpStatusCode === 403
  );
}

/**
 * Streams the object past a hash without keeping it. Costs one full transfer
 * of the file, which for a 2.5GB model is the slow part of this script --
 * hence opt-in. Without it the phone still checks the byte count, which
 * catches a truncated download; sha256 is what catches a corrupted one.
 */
async function sha256OfObject(s3, bucket, key) {
  const res = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  const hash = createHash("sha256");
  await pipeline(res.Body, hash);
  return hash.digest("hex");
}

function humanBytes(n) {
  if (n >= 1 << 30) return (n / (1 << 30)).toFixed(2) + " GB";
  if (n >= 1 << 20) return (n / (1 << 20)).toFixed(1) + " MB";
  if (n >= 1 << 10) return (n / (1 << 10)).toFixed(1) + " KB";
  return n + " B";
}

/**
 * Directory names that say what a thing is rather than which thing it is.
 * `.../runs/<model-run>/gguf/` and `.../runs/<model-run>/quantized/` are the
 * same model in two formats, so neither tail names it -- the run directory
 * does. Must stay in step with `idFromUrl` in lib/models/model_link.dart,
 * which derives the same id on the app side; both have tests pinning it.
 */
const GENERIC_SEGMENTS = new Set([
  "gguf",
  "quantized",
  "outputs",
  "runs",
  "models",
  "weights",
  "artifacts",
  "export",
]);

/**
 * A model id that stays stable across re-signings, so a re-pasted URL updates
 * the existing model on the phone instead of installing a second copy of a
 * 2.5GB file. The run directory name (`enlibraQ3-14B-to-4B-2026-09-22-1209`)
 * is the natural key: it is what the factory named this build.
 */
function deriveIdentity(bucket, prefix, fileName) {
  const segments = prefix.split("/").filter(Boolean);
  const name =
    [...segments].reverse().find((s) => !GENERIC_SEGMENTS.has(s)) ??
    fileName.replace(/\.gguf$/i, "");
  return {
    id: name.toLowerCase().replace(/[^a-z0-9._-]+/g, "-"),
    displayName: name,
    source: "s3://" + bucket + "/" + prefix,
  };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const { bucket, key } = parseS3Uri(opts.target);

  const credentials = fromNodeProviderChain(
    opts.profile ? { profile: opts.profile } : {}
  );

  let resolved;
  try {
    resolved = await credentials();
  } catch (err) {
    fail(
      "no AWS credentials (" + err.message + ").\n" +
      "  Export them, or pass --profile <name>:\n" +
      '    $env:AWS_ACCESS_KEY_ID="..."; $env:AWS_SECRET_ACCESS_KEY="..."'
    );
  }

  const region = await resolveRegion(bucket, credentials, opts.region);
  const s3 = new S3Client({
    region,
    credentials,
    // Keeps `x-amz-checksum-mode` out of the signed query string. It would be
    // harmless, but every signed parameter is one the downloader has to send
    // back verbatim, and this URL gets copied around by hand.
    responseChecksumValidation: "WHEN_REQUIRED",
    requestChecksumCalculation: "WHEN_REQUIRED",
    // Routes the transfer through the nearest CloudFront edge and over AWS's
    // own backbone for the long leg, instead of the public internet end to
    // end. Worth a lot when the client and the bucket are on different
    // continents -- and nothing at all when they are not. The bucket owner
    // has to have enabled it; a URL signed for an endpoint that is not
    // accelerated fails rather than falling back.
    useAccelerateEndpoint: opts.accelerate,
  });

  // A key ending in `/`, or with no extension, is a prefix to list. Anything
  // else is a single object, which we head rather than list -- listing needs
  // s3:ListBucket, and a caller may only have s3:GetObject.
  const isPrefix = key === "" || key.endsWith("/") || !/\.[a-z0-9]+$/i.test(key);
  let objects;
  let headDenied = false;
  if (isPrefix) {
    try {
      objects = await listObjects(s3, bucket, key);
    } catch (err) {
      // Acceleration is a bucket setting its owner has to turn on. When it is
      // off, the accelerate endpoint rejects the request outright -- and a URL
      // signed against an endpoint that rejects it is worse than a slow one,
      // so this is fatal rather than a warning.
      if (opts.accelerate && !isDenied(err)) {
        fail(
          "the S3 Transfer Acceleration endpoint rejected this request (" +
            (err.name ?? "unknown error") +
            ").\n" +
            "  Acceleration has to be enabled on the bucket by its owner. A URL\n" +
            "  signed against that endpoint will not work until it is, so\n" +
            "  re-run without --accelerate."
        );
      }
      if (!isDenied(err)) throw err;
      // Signing itself needs no permission -- it is an HMAC over the request,
      // computed locally. Only the *discovery* of what is in the prefix needs
      // s3:ListBucket, so an identity with just s3:GetObject can still do this
      // job if it is told the exact key.
      fail(
        "this identity may not list s3://" + bucket + "/" + key + "\n" +
        "  Pass the full object key instead -- listing is the only part that\n" +
        "  needs s3:ListBucket, and signing needs no permission at all:\n" +
        "    node presign-model.mjs s3://" + bucket + "/" + key + "model-q4_k_m.gguf\n" +
        "  (the file name is in the run's run_manifest.json, or the S3 console)"
      );
    }
    if (objects.length === 0) fail("nothing under s3://" + bucket + "/" + key);
  } else {
    let size = 0;
    try {
      const head = await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
      size = head.ContentLength ?? 0;
    } catch (err) {
      // Acceleration is a bucket setting its owner has to turn on. When it is
      // off, the accelerate endpoint rejects the request outright -- and a URL
      // signed against an endpoint that rejects everything is worse than a
      // slow one, so this is fatal rather than a warning.
      if (opts.accelerate && !isDenied(err)) {
        fail(
          "the S3 Transfer Acceleration endpoint rejected this request (" +
            (err.name ?? "unknown error") +
            ").\n" +
            "  Acceleration has to be enabled on the bucket by its owner. A\n" +
            "  URL signed against that endpoint will not work until it is, so\n" +
            "  re-run without --accelerate."
        );
      }
      if (!isDenied(err)) throw err;
      // s3:GetObject is what grants HeadObject, so a 403 here all but
      // guarantees the signed URL will be refused the same way. The URL is
      // still printed -- signing is local and the caller may know something we
      // do not -- but quietly calling this a missing file size would send
      // someone off to debug a download that was never going to start.
      headDenied = true;
      console.warn(
        "\npresign-model: WARNING -- HeadObject was refused (403) for this\n" +
        "  object. s3:GetObject is what grants HeadObject, so the URL below\n" +
        "  will almost certainly be refused too. Signing is a local HMAC and\n" +
        "  needs no permission, which is why it still succeeds here.\n" +
        "  Check which credentials are exported in THIS shell before using it."
      );
    }
    objects = [{ key, size }];
  }

  if (opts.filters.length > 0) {
    objects = objects.filter((o) => opts.filters.some((f) => o.key.includes(f)));
    if (objects.length === 0) fail("no object matched --file");
  }

  // Sign the weights, and list the rest. A quantized output directory usually
  // holds a config.json / tokenizer beside the .gguf, and the app does not
  // want them: llama.cpp reads the tokenizer out of the GGUF itself.
  const weights = objects.filter((o) =>
    WEIGHT_EXTENSIONS.some((ext) => o.key.toLowerCase().endsWith(ext))
  );

  if (weights.length === 0) {
    const unusable = objects.filter((o) =>
      UNUSABLE_EXTENSIONS.some((ext) => o.key.toLowerCase().endsWith(ext))
    );
    if (unusable.length > 0) {
      fail(
        "no .gguf here -- this is a Hugging Face checkpoint (" +
          unusable.map((o) => o.key.split("/").pop()).join(", ") + ").\n" +
          "  llama.cpp cannot load it, so the app cannot either. It has to be\n" +
          "  converted first, on a machine that has the weights:\n" +
          "    python llama.cpp/convert_hf_to_gguf.py <dir> --outfile model-f16.gguf --outtype f16\n" +
          "    llama-quantize model-f16.gguf model-q4_k_m.gguf Q4_K_M\n" +
          "  then upload the .gguf and sign that. A checkpoint already quantised\n" +
          "  by llm-compressor has to be decompressed to bf16 before step one.\n" +
          "  See scripts/README.md -> 'Converting a checkpoint to GGUF'."
      );
    }
  }

  const toSign = weights.length > 0 ? weights : objects;
  const skipped = objects.filter((o) => !toSign.includes(o));

  const files = [];
  for (const obj of toSign) {
    const fileName = obj.key.split("/").pop();
    let sha256 = null;
    if (opts.checksum) {
      const label = obj.size > 0 ? " (" + humanBytes(obj.size) + ")" : "";
      process.stderr.write("  hashing " + fileName + label + "...");
      sha256 = await sha256OfObject(s3, bucket, obj.key);
      process.stderr.write(" done\n");
    }
    const url = await getSignedUrl(
      s3,
      new GetObjectCommand({ Bucket: bucket, Key: obj.key }),
      { expiresIn: opts.expires }
    );
    files.push({
      role: "weights",
      fileName,
      // null rather than 0 when HeadObject was refused: the app treats an
      // absent size as "discover it", and a zero as "expect zero bytes".
      sizeBytes: obj.size > 0 ? obj.size : null,
      sha256,
      url,
      key: obj.key,
    });
  }

  const prefix = isPrefix ? key : key.slice(0, key.lastIndexOf("/") + 1);
  const identity = deriveIdentity(bucket, prefix, files[0].fileName);
  const expiresAt = new Date(Date.now() + opts.expires * 1000).toISOString();

  const manifest = {
    kind: "enlibra-model-source",
    version: 1,
    id: identity.id,
    displayName: identity.displayName,
    source: identity.source,
    expiresAt,
    files: files.map(({ key: _key, ...rest }) => rest),
  };

  if (opts.manifest) {
    writeFileSync(opts.manifest, JSON.stringify(manifest, null, 2) + "\n");
  }

  if (opts.json) {
    console.log(JSON.stringify(manifest, null, 2));
  } else {
    report({
      bucket, prefix, region, files, skipped, expiresAt, opts, resolved,
      headDenied,
    });
  }
  s3.destroy();
}

function report({
  bucket, prefix, region, files, skipped, expiresAt, opts, resolved, headDenied,
}) {
  const total = files.reduce((n, f) => n + (f.sizeBytes ?? 0), 0);
  console.log("");
  console.log("  s3://" + bucket + "/" + prefix);
  console.log(
    "  region " + region + "  |  " + files.length + " file(s)  |  " +
    (total > 0 ? humanBytes(total) : "size unknown")
  );
  console.log("  valid until " + expiresAt);
  // Which identity signed this. The single most common reason a URL 403s is
  // that the wrong credentials were in the shell, and that is invisible in
  // the URL unless you know to look for it.
  if (resolved && resolved.accessKeyId) {
    console.log("  signed by " + resolved.accessKeyId);
  }
  console.log("");

  for (const f of files) {
    const size = f.sizeBytes ? humanBytes(f.sizeBytes) : "size unknown";
    console.log("  " + f.fileName + "  (" + size + ")");
    if (f.sha256) console.log("  sha256 " + f.sha256);
    console.log("");
    console.log(f.url);
    console.log("");
  }

  if (skipped.length > 0) {
    const names = skipped.map((o) => o.key.split("/").pop()).join(", ");
    console.log("  not signed (not weights): " + names);
    console.log("");
  }

  // Temporary credentials expire on their own schedule, and the signature dies
  // with them regardless of --expires. Worth saying out loud: the alternative
  // is a URL that looks good for a week and 403s tomorrow morning.
  if (resolved && resolved.sessionToken) {
    const until = resolved.expiration
      ? " Your session ends " + new Date(resolved.expiration).toISOString() + "."
      : "";
    console.log(
      "  Note: signed with temporary credentials, so these URLs stop working\n" +
      "  when that session expires, whatever --expires says." + until + "\n" +
      "  Use a long-lived key pair if you want the full 7 days."
    );
    console.log("");
  }

  if (headDenied) {
    console.log(
      "  This URL is expected to fail: the identity above could not read\n" +
      "  the object. Export the credentials that can, and sign it again."
    );
    console.log("");
  }

  console.log("  In the app: Models -> Add model -> paste the URL above.");
  if (!opts.checksum) {
    console.log("  No sha256 (re-run with --checksum to add one); the app will");
    console.log("  verify the file's byte count instead.");
  }
  console.log("");
}

main().catch((err) => {
  console.error("presign-model: " + (err.stack ?? err.message ?? err));
  process.exit(1);
});

# scripts

Dev-time helpers. Not shipped in the app.

## presign-model.mjs — get a model out of S3 and onto a phone

The app's real model-distribution path is the managed-service-api content
endpoint (`GET /slms/{slmId}/runs/{runId}/files/content`), which holds the AWS
credentials and hands back a short-lived pre-signed URL. That endpoint sits
behind AWS Cognito, and the app does not speak Cognito yet.

This script is the same last step of that endpoint — `GetObjectCommand` +
`getSignedUrl` — run from a laptop that already has credentials. Paste what it
prints into **Models → Add model** and the phone downloads the model directly
from S3, no login anywhere in the loop.

### Setup

Needs Node 20+ (the AWS SDK v3 builds do):

```powershell
nvm use 22
cd scripts
npm install
```

### Credentials

The DSS bucket (`enlibra`) is not readable by a general-purpose developer IAM
user — worth knowing before you debug a 403 that is not the script's fault.
`managed-service-api` reads it with one of two configured key pairs
(`src/util/SlmS3.ts`):

| Purpose | Env keys in managed-service-api |
| --- | --- |
| SI Factory / DSS reads | `si_factory_aws_access_key_id`, `si_factory_aws_secret_key`, `si_factory_aws_region` |
| Reading what the pod wrote (run outputs) | `slm_runpod_access_key_id`, `slm_runpod_secret_access_key`, `slm_runpod_region` |

Quantized weights under `runs/<runId>/outputs/` were written **by the pod**, so
the `slm_runpod_*` pair is the one to reach for. Export it as standard AWS
credentials:

```powershell
$env:AWS_ACCESS_KEY_ID     = "<slm_runpod_access_key_id>"
$env:AWS_SECRET_ACCESS_KEY = "<slm_runpod_secret_access_key>"
$env:AWS_REGION            = "us-east-1"
```

Or, if you keep them in a named profile, `--profile slm-runpod`.

A 403 with `not authorized to perform: s3:GetObject` means the identity is
wrong, not the URL. The script cannot tell you that up front: signing is a local
HMAC and needs no permission at all, so an unauthorized key still produces a
well-formed URL.

### Use

```powershell
node presign-model.mjs s3://enlibra/dss/dev/runs/20260818_215840_neuroscience_8f33eb7cf609/outputs/gkd/runs/enlibraQ3-14B-to-4B-2026-09-22-1209/quantized/
```

It lists the prefix, signs every `.gguf` in it, and prints the URLs.

If the identity has `s3:GetObject` but not `s3:ListBucket` — a reasonable way to
scope a read-only key — listing fails and the script says so. Pass the full
object key instead; signing needs no permission:

```powershell
node presign-model.mjs s3://enlibra/…/quantized/model-q4_k_m.gguf
```

Options:

| Flag | Effect |
| --- | --- |
| `--profile <name>` | AWS profile to sign with |
| `--region <region>` | bucket region; detected otherwise |
| `--expires <seconds>` | URL lifetime, max 604800 (7 days), default 7 days |
| `--file <substring>` | only keys containing this, repeatable |
| `--manifest <path>` | also write a JSON source file (see below) |
| `--checksum` | stream each object to compute its sha256 |
| `--json` | machine-readable output |

### What the app does with the URL

Pasting a bare `.gguf` URL is enough. The app reads the GGUF's own header over a
ranged request — a couple of megabytes of a 2.5GB file — and gets the
architecture, layer count, KV head count, head dimension, trained context length
and parameter count from it. That is what lets it say *"runs with a 8192-token
context on this 8GB device"* before you commit to the download, and refuse
models that will not fit.

The total size comes from the ranged response's `Content-Range`, so the app
learns it even when the script could not call `HeadObject`.

`--manifest out.json` writes this instead, for a model that is more than one
file, or when you want the checksum carried along:

```json
{
  "kind": "enlibra-model-source",
  "version": 1,
  "id": "enlibraq3-14b-to-4b-2026-09-22-1209",
  "displayName": "enlibraQ3-14B-to-4B-2026-09-22-1209",
  "source": "s3://enlibra/dss/dev/runs/…/quantized/",
  "expiresAt": "2026-09-30T07:57:24.486Z",
  "files": [
    {
      "role": "weights",
      "fileName": "model-q4_k_m.gguf",
      "sizeBytes": 2684354560,
      "sha256": null,
      "url": "https://enlibra.s3.us-east-1.amazonaws.com/…"
    }
  ]
}
```

The whole file can be pasted into the same field.

### Expiry

A pre-signed URL is a capability with a deadline, and 2.5GB over a phone
connection can outlive a short one. Two things follow:

- The app reads `X-Amz-Date` + `X-Amz-Expires` out of the URL and shows how long
  the link has left *before* starting, rather than failing at 80%.
- Temporary (STS) credentials expire on their own schedule and the signature dies
  with them, whatever `--expires` says. The script warns when it signed with a
  session token. Use a long-lived key pair if you want the full 7 days.

When a link does expire, **Models → ⋯ → Update download link** and paste a fresh
one. The model id is derived from the run directory, not from the signature, so
re-pasting updates the existing entry and the partial download **resumes** —
it does not start over.

### Checksums

Without `--checksum` there is no published sha256, and the app verifies the
download by byte count instead. That catches a truncated transfer but not a
corrupted one; a corrupt GGUF of the right length fails later, inside
llama.cpp. `--checksum` closes that gap at the cost of streaming the whole
object past a hash on your machine first — for 2.5GB, the slowest thing the
script does.

## make-icons.mjs — launcher icons from the mark

`assets/logo/enlibra-mark.svg` is the source of truth for every app icon.
Everything under `android/app/src/main/res/mipmap-*`,
`ios/Runner/Assets.xcassets/AppIcon.appiconset` and `web/` is generated:

```powershell
npm run icons
```

Each slot is rendered from the vector at its final pixel size rather than
resampled from one large bitmap, which is why the 20x20 still reads. The mark is
portrait (149x190) on square canvases, so it is fitted by height, centred, and
inset to clear the circular mask both platforms apply.

Platform differences the script handles:

- **iOS** icons are written without an alpha channel — App Store validation
  rejects icons that have one — so they are composited onto the brand charcoal
  (`#262624`, `AppColors.darkBackground`) and encoded as RGB.
- **Android** gets both the legacy `ic_launcher.png` and an adaptive icon: a
  transparent `ic_launcher_foreground.png` on a 108dp canvas plus a flat colour
  background, wired up by a generated `mipmap-anydpi-v26/ic_launcher.xml`. The
  foreground is inset harder, since only the middle 66dp of that canvas is
  guaranteed visible. The same artwork is declared as the monochrome layer, for
  themed icons on Android 13+.
- **Web** gets the favicon and both maskable PWA sizes.

Override the backdrop with `--background "#ffffff"`, or point at different
artwork with `--source`.

`npm run icons:check` verifies the icons are current and is wired into CI. It
compares the artwork's hash against `icons.lock.json` rather than re-rendering
and diffing pixels — CI should not depend on a rasteriser producing
byte-identical output on another OS, and the mistake actually worth catching is
changing the SVG without regenerating.

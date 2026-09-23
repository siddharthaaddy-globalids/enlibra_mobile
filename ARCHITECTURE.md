# Enlibra — on-device LLM chat

Flutter app running a quantized LLM locally via llama.cpp, targeting
Android and iOS. Windows and macOS builds exist only as a fast dev harness.

## The constraint everything follows from

Mobile RAM. iOS kills an app at roughly 50–55% of device RAM; Android is
more permissive in the foreground but kills large processes on backgrounding.
The 6 GB Android floor gives us about **3.3 GB**, a 6 GB iPhone about
**3.0 GB**.

Measured (see `test/memory_math_test.dart`, all figures GiB, Q4_K_M):

| Model | Context | KV type | Peak | 6 GB iPhone headroom |
|---|---|---|---|---|
| 1B | 4096 | q8_0 | ~1.17 | plenty |
| 3B | 4096 | q8_0 | ~2.36 | ~21% |
| 3B | 8192 | f16  | ~2.93 | ~2% — crashes in practice |
| 3B | 8192 | q8_0 | ~2.47 | ~18% |
| 7B | 4096 | q8_0 | ~4.7  | does not fit |

Two conclusions baked into the code:

- **Quantize the KV cache to `q8_0`** (`ModelManifest.kvCacheType`). On a 3B
  it saves ~230 MiB at 4k and ~460 MiB at 8k. That is the difference between
  running and being jetsammed.
- **`fitsOn()` requires real headroom**, not just a positive number. A
  configuration with 2% margin is arithmetically fine and dies on a real
  device, because the estimate cannot see fragmentation or OS pressure.

## Layout

```
lib/
  core/
    memory_math.dart      Weight + KV cache estimation. Start here.
    device_tier.dart      RAM detection -> usable budget -> tier.
  models/
    model_manifest.dart   Schema v1: what a model is, what it costs.
    manifest_source.dart  Bundled catalog | backend with presigned URLs.
  download/
    storage_paths.dart    Per-platform paths. iOS backup exclusion notes.
    model_downloader.dart Resumable, checksummed, atomic promotion.
  db/
    app_database.dart     SQLite schema.
    chat_repository.dart  Conversations, messages, summaries.
  llama/
    llama_engine.dart     The FFI boundary. Pure interface.
    fake_llama_engine.dart Simulates a mid-range device. Swap this out.
  chat/
    context_budget.dart   What fits in the window; when to summarize.
    chat_controller.dart  Orchestrates a conversation.
  ui/
    models_screen.dart    Catalog, size/RAM cost, download.
    chat_screen.dart      Streaming chat.
```

## Memory (the chat kind)

Three layers, two of which are built:

1. **KV cache persistence** — `llama_state_save_file` per conversation
   (`StoragePaths.sessionFile`). Reopening a chat otherwise pays full
   prefill, which on a mid-range Android CPU is 25–60 s for a 2000-token
   history. This is the single biggest UX lever in the app.
2. **Rolling summarization** — triggers at **50%** of the prompt budget
   (`ContextBudget.summarizeAtFraction`), not the 70–80% that is reasonable
   on a server. A 4k window plus slow prefill means overflowing mid-chat is
   not recoverable gracefully. Summarized messages stay visible in the UI
   but leave the prompt. Summarizing invalidates the saved KV session,
   because history no longer matches the cache.
3. **Retrieval over past chats** — deliberately not built. An embedding
   model costs 200–500 MB of a budget we do not have, and it inflates every
   prompt, which is the exact thing that is slow.

## Model distribution

App → your backend → presigned S3 URLs. The backend holds the AWS
credentials; the app never does. Anything in the binary, **including
`--dart-define` values**, is extractable.

```
GET  {api}/models                    -> catalog (no URLs, cacheable)
POST {api}/models/{id}/download      -> { urls: { file: signed }, expiresInSeconds }
```

URLs are resolved immediately before download and never cached. A resumed
download that outlives the expiry re-resolves.

Download invariants: HTTP Range resume, SHA-256 verified before use, written
to `.part` and atomically renamed, `.version` marker written last so a
crash mid-download leaves the model correctly marked as not installed.

### Who moves the bytes

Two transfers, one contract -- when either finishes, the `.part` file holds the
whole thing, and verification and promotion are shared so neither can skip an
integrity check.

- **Mobile** hands the transfer to the platform: an Android foreground service,
  `URLSession` background transfers on iOS, both via `background_downloader`.
  A 2.3GB download over a mobile connection gives Android plenty of chances to
  reclaim the app, and an in-process download does not survive that. The
  notification is not decoration: Android will not run a foreground service
  without one.
- **Desktop** downloads in-process. There is no equivalent notion of the app
  being killed to reclaim memory, and the in-process path is simpler to reason
  about -- it is also the one the tests cover.

Failure modes that cost real time to diagnose, and what now catches them:

- A **stalled** connection produces no error and no end of stream. Without a
  watchdog it is indistinguishable from a download frozen at 7%. `stallTimeout`
  turns it into a `DownloadStalled` the user can retry; the partial file is
  kept, so retrying resumes.
- **Cancel** tears the subscription down rather than setting a flag read on the
  next chunk -- on a stalled connection that flag is never read, which is
  exactly when Cancel gets pressed.
- `yield*` **forwards a delegated stream's errors past the enclosing
  try/catch**, so every download failure used to escape as a stream error
  instead of a `failed` event, leaving the UI frozen at whatever percentage it
  had reached. The loop is an explicit `await for` for that reason.

### What a model owns

Removing one has to reach all of it, and nothing cleans up anything else:

| | Cleared by |
| --- | --- |
| Weights, `.part`, `.version` | `StoragePaths.deleteModel` |
| Manifest + its download link | `ManualModelStore.remove` |
| Conversations (messages, summaries cascade) | `deleteConversation` per id |
| Serialised KV cache per conversation | walked by hand -- a foreign key cascade cannot reach a file |
| In-flight transfer | cancelled first, so nothing re-creates what was just deleted |

The UI's progress map is keyed by model id, and **ids are derived from the URL**
-- so re-pasting the same link yields the same id. Failing to clear that entry
makes a freshly added model open at the percentage the deleted one reached,
which looks exactly like a download cache that was never cleared.

### Adding a model by link (the interim path)

That backend is `managed-service-api`, and its content endpoint
(`GET /slms/{slmId}/runs/{runId}/files/content`) is behind AWS Cognito, which
the app does not speak yet. Until it does, a model gets onto a device by
pasting a link:

```
scripts/presign-model.mjs  →  pre-signed URL  →  Models → Add model
```

The script is the last step of that endpoint — `GetObjectCommand` +
`getSignedUrl` — run from a laptop that has credentials. See
[scripts/README.md](scripts/README.md).

**A pasted URL is not a manifest**, and the app needs a manifest: without a
model's layer count, KV head count and head dimension it cannot say whether the
model fits in RAM, and offering a download that will OOM on load is the one
thing [memory sizing](#memory-the-chat-kind) exists to prevent.

So `GgufProbe` reads the GGUF's own header over a ranged request — a couple of
megabytes of a 2.5GB file — and builds the manifest from it: architecture,
block count, KV heads, head dimension, trained context, quantisation label, and
a parameter count summed over the tensor index. The total file size comes from
the response's `Content-Range`, so it is learned even when the script's identity
could not call `HeadObject`. This is `lib/models/gguf_header.dart` plus
`lib/models/gguf_probe.dart`; the format is stable and versioned, and the parser
refuses versions it does not know.

Consequences worth stating:

- **No checksum.** A pasted URL has no catalog entry to carry one, so the
  download is verified by byte count (`SizeMismatch`) rather than SHA-256. That
  catches a truncated transfer, not a corrupted one. `--checksum` on the script
  closes the gap at the cost of streaming the object past a hash first.
- **The URL is stored.** `ManualModelStore` persists the manifest *including*
  its pre-signed URL, because there is nothing to re-request it from. It is an
  expiring capability to read one object, not a credential.
- **Expiry is surfaced, not discovered.** `X-Amz-Date` + `X-Amz-Expires` are
  read out of the URL, so the app states the deadline before a multi-gigabyte
  download rather than failing at 80%.
- **Identity comes from the key, not the signature.** The model id is derived
  from the run directory (`enlibraq3-14b-to-4b-2026-09-22-1209`), which is
  stable across re-signings — so pasting a refreshed URL updates the model in
  place and the partial download *resumes*. The script and the app derive it
  the same way, and both have tests pinning that.

`CompositeManifestSource` puts these in front of the backend catalog and routes
`resolve()` by id, so the catalog path stays wired up and starts working the
moment Cognito lands, with no change at the call site.

## The llama.cpp layer

`third_party/llama.cpp` is a git submodule. After cloning:

```
git submodule update --init --recursive
```

### Why a hand-written C bridge

`packages/llama_bridge/src/llama_bridge.h` is a deliberately narrow C ABI —
about twenty functions over opaque pointers and flat POD. Dart binds to
*that*, never to `llama.h`.

This matters more than it looks. `llama.h`'s structs change shape between
releases; `llama_context_params` alone has a dozen fields that have come and
gone. Any Dart mirror of those structs would keep compiling after an
upstream change and start corrupting memory at runtime. With the bridge, a
llama.cpp bump can break the C++ build — loud, in CI — but cannot produce a
silently misaligned struct on a user's phone.

It also means no ffigen, no libclang, and no codegen step in anyone's setup.

### What the bridge does that a thinner one would not

- **Prefix reuse.** `lb_generate_begin` diffs the new prompt against the
  tokens already in the KV cache, drops only the diverging tail with
  `llama_memory_seq_rm`, and decodes the remainder. `lb_last_cached_tokens`
  reports how much was reused. This is what makes turn two of a conversation
  fast instead of paying full prefill again.
- **Chat templating via the GGUF's own template**
  (`llama_model_chat_template`). It throws rather than guessing when a model
  carries no template, because a wrong template produces output that looks
  like a bad model rather than a bad prompt.
- **Cancellation that actually interrupts.** `lb_generate_cancel` sets a
  `std::atomic<bool>` checked inside the decode loop. See below for why the
  usual isolate message would not work.

### Threading

`lib/llama/llama_worker.dart` owns the native session on a background
isolate. Every native call blocks its thread, prefill included; on the UI
isolate that freezes the app for the whole generation.

The stop button is the subtle part. The worker is blocked inside
`lb_generate_next` and will not read its message queue until that call
returns — during prefill, potentially a minute. So `LlamaCanceller` holds
the session pointer as an integer address and calls `lb_generate_cancel`
straight from the UI isolate into the native atomic flag. Same process, so
the address is valid; atomic, so the cross-thread write is safe.

### Stop strings

`StopStringFilter` holds back any suffix that could still grow into a stop
string. A stop marker rarely arrives as one token — `<|im_end|>` may stream
as `<|`, `im`, `_end`, `|>` — so emitting each token directly puts half a
stop marker on screen. Correctly converted GGUFs mark these as
end-of-generation and llama.cpp halts on its own; this covers the ones
whose metadata is wrong.

### Apple platforms

CocoaPods cannot drive llama.cpp's CMake build, so iOS and macOS consume a
prebuilt `llama.xcframework`:

```
packages/llama_bridge/tool/build_apple_frameworks.sh
```

Takes 10–20 minutes, produces ~200MB, gitignored. CI caches it keyed on the
llama.cpp submodule SHA, so it only rebuilds when the submodule moves.
Android, Windows and Linux build llama.cpp from source through CMake and
need no such step.

### Android ABIs

Both Gradle modules derive their ABI list from Flutter's own
`-Ptarget-platform`, so one flag governs Flutter's libraries and the native
bridge together:

```
flutter build appbundle --release --target-platform android-arm64
```

With no flag, the default is `arm64-v8a,x86_64`. The x86_64 slice exists
only so the Android Studio emulator works on an Intel/AMD host, where the
system image is x86_64 and an arm64-only library will not load at all.

No 32-bit ABI is ever built — such a device cannot address enough memory to
hold even the 1B model.

Verified: a debug APK carries `lib/x86_64/libllama_bridge.so` at 4.58MB, and
an arm64 build produces 4.24MB.

### Windows toolchain notes

Two things bite on Windows and neither is a project problem:

- The Gradle wrapper can leave a zero-byte `.part` file after a failed
  download, and then times out on every later build. Clear
  `~/.gradle/wrapper/dists/<version>` and let it re-fetch.
- The `-all` Gradle distribution ships Kotlin DSL docs whose generated
  filenames exceed the 260-character `MAX_PATH` limit, so extraction fails.
  Switching `distributionUrl` to `-bin` avoids this entirely and costs
  nothing but IDE autocomplete in `build.gradle.kts`.

### Developing without a native toolchain

```
flutter run --dart-define=USE_FAKE_ENGINE=true
```

`FakeLlamaEngine` implements the same interface and simulates 6 tok/s
generation with 60 tok/s prefill, so UI work does not require an NDK or
Xcode. This flag also lets the Models screen open a model that was never
downloaded, so the app is demoable on a fresh clone with no backend
running.

## Before shipping

- [ ] iOS/macOS: call `StoragePaths.iosBackupExclusionSnippet` from
      `AppDelegate.swift`. Apple rejects apps that back up multi-GB
      re-downloadable files to iCloud.
- [ ] iOS: request `com.apple.developer.kernel.increased-memory-limit`.
- [ ] iOS: handle background suspension — generation stops mid-stream.
- [ ] Android: ship `arm64-v8a` only; build llama.cpp with dotprod/i8mm
      (roughly 2x on modern SoCs). Treat GPU as opportunistic; CPU is the
      baseline.
- [ ] Wi-Fi-only default for downloads.
- [ ] Test on a cheap real Android device early. The simulator and a Mac
      both lie about speed.
- [ ] Replace the placeholder `sha256` values in
      `assets/manifests/catalog.json`.

## Branding

Three pieces of artwork, all under `assets/logo/`:

- `enlibra-light.svg` / `enlibra-dark.svg` — the wordmark, shown by `AppLogo`.
  Two files rather than one tinted file, because the dark-background version
  uses a softer orange (`#f69446`) than the light one (`#f67711`) — the usual
  correction for a saturated hue glowing against a dark field.
- `enlibra-mark.svg` — the mark on its own. Single-colour and theme-independent,
  shown by `AppMark`, and the source every launcher icon is generated from.

Launcher icons are **generated, not hand-placed**: `scripts/make-icons.mjs`
writes all 30 of them (Android mipmaps plus an adaptive icon, the iOS
`AppIcon.appiconset`, and the web favicon and maskable icons) from that one SVG.
CI checks they are current. See [scripts/README.md](scripts/README.md#make-iconsmjs--launcher-icons-from-the-mark).

## Notes

- `flutter run -d windows` needs Developer Mode enabled on Windows
  (`start ms-settings:developers`) because plugins use symlinks.
- `web/` and `linux/` are unused; `web` cannot run FFI at all.
  Remove with `rm -rf web linux`.

## CI/CD

`.github/workflows/ci.yml` — on push/PR to `main`:

- `analyze` — `dart format --set-exit-if-changed`, `flutter analyze
  --fatal-infos`, `flutter test --coverage`, and `make-icons --check`.
  Everything else depends on it.
- `android` — debug APK, arm64 only.
- `ios` — `--no-codesign`. Compiles and links without certificates, so real
  build breaks are caught. Skipped for fork PRs, which cannot read secrets
  and would burn macOS minutes for nothing.
- `desktop` — Windows and macOS release builds.

macOS runners bill at **10x** minutes on private repos, which is why
`concurrency.cancel-in-progress` is set and the iOS job is gated.

`.github/workflows/release.yml` — on a `v*` tag:

Signed Android (AAB + APK), signed iOS IPA, Windows and macOS builds, then
a **draft** GitHub release. Drafted rather than published because a release
is outward-facing and a human should look first.

### Required secrets

| Secret | Notes |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 upload-keystore.jks` |
| `ANDROID_STORE_PASSWORD` | |
| `ANDROID_KEY_ALIAS` | |
| `ANDROID_KEY_PASSWORD` | |
| `IOS_CERTIFICATE_P12_BASE64` | Distribution certificate |
| `IOS_CERTIFICATE_PASSWORD` | |
| `IOS_PROVISIONING_PROFILE_BASE64` | |
| `IOS_KEYCHAIN_PASSWORD` | Any random string; scopes a temp keychain |

`android/app/build.gradle.kts` reads `android/key.properties` when present
and falls back to debug signing when it is not, so a fresh clone still
builds. Both files are gitignored. **Back up the Android upload keystore
somewhere durable** — losing it means you can never update the app on Play
under the same listing.

`ios/ExportOptions.plist` is referenced by the release job but is not in the
repo (it carries your team ID). Generate it once from a local
`flutter build ipa` and add it as a secret or commit a sanitised version.

### When llama.cpp lands

Build times jump once there is native code. Expect to add: NDK + CMake setup
on the Android job, `actions/cache` for the llama.cpp build directory, and a
longer `timeout-minutes` on the macOS jobs. Consider building the native
libraries in a separate workflow and consuming them as prebuilt artifacts,
so ordinary Dart changes do not pay for a full native rebuild.

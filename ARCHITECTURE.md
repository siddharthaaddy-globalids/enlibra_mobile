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

## Wiring in llama.cpp

`FakeLlamaEngine` implements the full `LlamaEngine` interface and simulates
6 tok/s generation and 60 tok/s prefill, so the UI is designed against
realistic latency. To go real:

1. Evaluate `fllama` / `llama_cpp_dart` on pub.dev — **verify each builds
   for Android and iOS** before committing.
2. Fallback that always works: a thin C wrapper over `llama.h`
   (load/tokenize/decode/sample/free) bound with `package:ffigen`.
3. Run it on a **background isolate**. Calling `llama_decode` on the UI
   isolate freezes the app for the entire generation.
4. `countTokens` must use the model's real tokenizer. The fake's
   3.6-chars-per-token heuristic is wrong by enough to blow the window.
5. Prefer the chat template baked into the GGUF over
   `manifest.chatTemplate`. Wrong templating is the top cause of
   "the model outputs garbage" and it does not look like a formatting bug.

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

## Notes

- `flutter run -d windows` needs Developer Mode enabled on Windows
  (`start ms-settings:developers`) because plugins use symlinks.
- `web/` and `linux/` are unused; `web` cannot run FFI at all.
  Remove with `rm -rf web linux`.

## CI/CD

`.github/workflows/ci.yml` — on push/PR to `main`:

- `analyze` — `dart format --set-exit-if-changed`, `flutter analyze
  --fatal-infos`, `flutter test --coverage`. Everything else depends on it.
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

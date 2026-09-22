/// Bindings to the narrow C ABI in `src/llama_bridge.h`.
///
/// These are written by hand rather than generated. The ABI is twenty-odd
/// functions over opaque pointers and flat structs, which is small enough
/// to maintain directly and avoids a codegen step (and a libclang
/// dependency) in every developer's setup and in CI.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// --- native structs --------------------------------------------------------

final class LbModelParams extends Struct {
  external Pointer<Utf8> modelPath;
  @Int32()
  external int nCtx;
  @Int32()
  external int nBatch;
  @Int32()
  external int nThreads;
  @Int32()
  external int nGpuLayers;
  external Pointer<Utf8> kvType;
  @Bool()
  external bool useMmap;
}

final class LbSamplingParams extends Struct {
  @Float()
  external double temperature;
  @Float()
  external double topP;
  @Int32()
  external int topK;
  @Float()
  external double repeatPenalty;
  @Int32()
  external int repeatLastN;
  @Uint32()
  external int seed;
}

// --- status codes (must match llama_bridge.h) ------------------------------

class LbStatus {
  static const ok = 0;
  static const doneEos = -1;
  static const doneMaxTokens = -2;
  static const doneCancelled = -3;
  static const errGeneric = -10;
  static const errNotGenerating = -11;
  static const errDecode = -12;
  static const errContextFull = -13;

  static String describe(int code) => switch (code) {
    doneEos => 'eos',
    doneMaxTokens => 'maxTokens',
    doneCancelled => 'cancelled',
    errNotGenerating => 'not generating',
    errDecode => 'decode failed',
    errContextFull => 'context full',
    _ => 'error ($code)',
  };
}

class LlamaException implements Exception {
  LlamaException(this.message);
  final String message;
  @override
  String toString() => 'LlamaException: $message';
}

// --- dynamic library -------------------------------------------------------

DynamicLibrary _open() {
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libllama_bridge.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('llama_bridge.dll');
  }
  // iOS and macOS link the bridge into the app binary via the podspec, so
  // the symbols are already in the process image.
  return DynamicLibrary.process();
}

final DynamicLibrary _lib = _open();

// --- function lookups ------------------------------------------------------

final _backendInit = _lib.lookupFunction<Void Function(), void Function()>(
  'lb_backend_init',
);

final _load = _lib
    .lookupFunction<
      Pointer<Void> Function(Pointer<LbModelParams>, Pointer<Utf8>, Int32),
      Pointer<Void> Function(Pointer<LbModelParams>, Pointer<Utf8>, int)
    >('lb_load');

final _free = _lib
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'lb_free',
    );

final _nCtx = _lib
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'lb_n_ctx',
    );

final _countTokens = _lib
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf8>, Bool),
      int Function(Pointer<Void>, Pointer<Utf8>, bool)
    >('lb_count_tokens');

final _formatPrompt = _lib
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Pointer<Utf8>>,
        Pointer<Pointer<Utf8>>,
        Int32,
        Bool,
        Pointer<Utf8>,
        Int32,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Pointer<Utf8>>,
        Pointer<Pointer<Utf8>>,
        int,
        bool,
        Pointer<Utf8>,
        int,
      )
    >('lb_format_prompt');

final _generateBegin = _lib
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Utf8>,
        Pointer<LbSamplingParams>,
        Int32,
      ),
      int Function(Pointer<Void>, Pointer<Utf8>, Pointer<LbSamplingParams>, int)
    >('lb_generate_begin');

final _generateNext = _lib
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32),
      int Function(Pointer<Void>, Pointer<Utf8>, int)
    >('lb_generate_next');

final _generateCancel = _lib
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'lb_generate_cancel',
    );

final _lastPrefillUs = _lib
    .lookupFunction<Int64 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'lb_last_prefill_us',
    );

final _lastPromptTokens = _lib
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'lb_last_prompt_tokens',
    );

final _lastCachedTokens = _lib
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'lb_last_cached_tokens',
    );

final _sessionSave = _lib
    .lookupFunction<
      Bool Function(Pointer<Void>, Pointer<Utf8>),
      bool Function(Pointer<Void>, Pointer<Utf8>)
    >('lb_session_save');

final _sessionLoad = _lib
    .lookupFunction<
      Bool Function(Pointer<Void>, Pointer<Utf8>),
      bool Function(Pointer<Void>, Pointer<Utf8>)
    >('lb_session_load');

// --- public API ------------------------------------------------------------

/// One loaded model plus its context.
///
/// Every method here blocks the calling thread, including for the whole of
/// prompt processing. Own this from a background isolate, never the UI one.
class LlamaSession {
  LlamaSession._(this._handle);

  final Pointer<Void> _handle;
  bool _disposed = false;

  /// The native handle as an integer, so another isolate can construct a
  /// cancel-only view of this session. See [LlamaCanceller].
  int get address => _handle.address;

  static LlamaSession open({
    required String modelPath,
    required int contextLength,
    required int threadCount,
    int batchSize = 512,
    int gpuLayers = 0,
    String kvType = 'q8_0',
    bool useMmap = true,
  }) {
    _backendInit();

    final params = calloc<LbModelParams>();
    final err = calloc<Uint8>(512).cast<Utf8>();
    try {
      params.ref
        ..modelPath = modelPath.toNativeUtf8()
        ..nCtx = contextLength
        ..nBatch = batchSize
        ..nThreads = threadCount
        ..nGpuLayers = gpuLayers
        ..kvType = kvType.toNativeUtf8()
        ..useMmap = useMmap;

      final handle = _load(params, err, 512);
      if (handle == nullptr) {
        throw LlamaException(err.toDartString());
      }
      return LlamaSession._(handle);
    } finally {
      if (params.ref.modelPath != nullptr) calloc.free(params.ref.modelPath);
      if (params.ref.kvType != nullptr) calloc.free(params.ref.kvType);
      calloc.free(params);
      calloc.free(err);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _free(_handle);
  }

  int get contextLength => _nCtx(_handle);

  int countTokens(String text, {bool addSpecial = true}) {
    final ptr = text.toNativeUtf8();
    try {
      return _countTokens(_handle, ptr, addSpecial);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Applies the chat template baked into the GGUF.
  ///
  /// Throws if the model carries no template — better a loud failure than a
  /// silently mis-formatted prompt, which produces bad output that looks
  /// like a bad model rather than a bad prompt.
  String formatPrompt(
    List<({String role, String content})> messages, {
    bool addAssistant = true,
  }) {
    final n = messages.length;
    final roles = calloc<Pointer<Utf8>>(n);
    final contents = calloc<Pointer<Utf8>>(n);
    for (var i = 0; i < n; i++) {
      roles[i] = messages[i].role.toNativeUtf8();
      contents[i] = messages[i].content.toNativeUtf8();
    }

    Pointer<Utf8> buf = nullptr;
    try {
      // Ask for the required size, then allocate exactly once.
      final needed = _formatPrompt(
        _handle,
        roles,
        contents,
        n,
        addAssistant,
        nullptr,
        0,
      );
      if (needed == LbStatus.errGeneric) {
        throw LlamaException('model has no chat template baked into the GGUF');
      }
      final size = needed < 0 ? -needed : needed + 1;
      buf = calloc<Uint8>(size).cast<Utf8>();

      final written = _formatPrompt(
        _handle,
        roles,
        contents,
        n,
        addAssistant,
        buf,
        size,
      );
      if (written < 0) {
        throw LlamaException('failed to apply chat template');
      }
      return buf.toDartString();
    } finally {
      for (var i = 0; i < n; i++) {
        calloc.free(roles[i]);
        calloc.free(contents[i]);
      }
      calloc.free(roles);
      calloc.free(contents);
      if (buf != nullptr) calloc.free(buf);
    }
  }

  /// Tokenizes, reuses whatever KV prefix still matches, and decodes the
  /// rest. This is the expensive call: on a mid-range Android CPU a long
  /// history costs tens of seconds.
  void beginGeneration(
    String prompt, {
    required double temperature,
    required double topP,
    required int topK,
    required double repeatPenalty,
    int repeatLastN = 64,
    int? seed,
    required int maxTokens,
  }) {
    final promptPtr = prompt.toNativeUtf8();
    final sampling = calloc<LbSamplingParams>();
    try {
      sampling.ref
        ..temperature = temperature
        ..topP = topP
        ..topK = topK
        ..repeatPenalty = repeatPenalty
        ..repeatLastN = repeatLastN
        ..seed = seed ?? 0xFFFFFFFF;

      final rc = _generateBegin(_handle, promptPtr, sampling, maxTokens);
      if (rc != LbStatus.ok) {
        throw LlamaException('prefill failed: ${LbStatus.describe(rc)}');
      }
    } finally {
      calloc.free(promptPtr);
      calloc.free(sampling);
    }
  }

  /// Decodes one token. Returns its text, or null when generation ended —
  /// in which case [lastStopReason] says why.
  String? nextToken() {
    // 256 bytes is far more than any single token's UTF-8 form; the native
    // side still reports a larger requirement rather than truncating.
    const size = 256;
    final buf = calloc<Uint8>(size).cast<Utf8>();
    try {
      final n = _generateNext(_handle, buf, size);
      if (n > 0) return buf.toDartString(length: n);
      _lastStopReason = LbStatus.describe(n);
      if (n == LbStatus.doneEos ||
          n == LbStatus.doneMaxTokens ||
          n == LbStatus.doneCancelled) {
        return null;
      }
      throw LlamaException('generation failed: ${LbStatus.describe(n)}');
    } finally {
      calloc.free(buf);
    }
  }

  String _lastStopReason = 'eos';
  String get lastStopReason => _lastStopReason;

  Duration get lastPrefill => Duration(microseconds: _lastPrefillUs(_handle));
  int get lastPromptTokens => _lastPromptTokens(_handle);

  /// Prompt tokens served from the existing KV cache. When this approaches
  /// [lastPromptTokens], prefix reuse is working.
  int get lastCachedTokens => _lastCachedTokens(_handle);

  bool saveSession(String path) {
    final ptr = path.toNativeUtf8();
    try {
      return _sessionSave(_handle, ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  bool loadSession(String path) {
    final ptr = path.toNativeUtf8();
    try {
      return _sessionLoad(_handle, ptr);
    } finally {
      calloc.free(ptr);
    }
  }
}

/// A cancel-only handle to a session owned by another isolate.
///
/// [LlamaSession.nextToken] blocks its isolate, so the stop button cannot
/// go through the normal isolate message queue — the worker will not read
/// it until it has finished the token it is already computing, and during
/// prefill that could be a minute. This calls straight into the native
/// atomic flag instead, from whichever isolate holds it.
class LlamaCanceller {
  LlamaCanceller(this.address);

  final int address;

  void cancel() => _generateCancel(Pointer<Void>.fromAddress(address));
}

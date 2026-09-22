import '../models/model_manifest.dart';

/// A single chat turn as the engine sees it.
class ChatTurn {
  const ChatTurn({required this.role, required this.content});

  /// 'system' | 'user' | 'assistant'
  final String role;
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

sealed class GenerationEvent {
  const GenerationEvent();
}

/// One decoded token. The UI appends these as they arrive.
class TokenEvent extends GenerationEvent {
  const TokenEvent(this.text);
  final String text;
}

/// Emitted once, after prompt processing and before the first token.
///
/// Prefill is the dominant latency on mobile -- a 2000-token history costs
/// 25-60s on a mid-range Android CPU. Surfacing it separately lets the UI
/// show "thinking" honestly instead of appearing frozen.
class PrefillDoneEvent extends GenerationEvent {
  const PrefillDoneEvent({
    required this.promptTokens,
    required this.cachedTokens,
    required this.elapsed,
  });

  final int promptTokens;

  /// Tokens served from the reused KV cache rather than recomputed. When
  /// this is close to [promptTokens], session restore is doing its job.
  final int cachedTokens;

  final Duration elapsed;
}

class DoneEvent extends GenerationEvent {
  const DoneEvent({
    required this.tokenCount,
    required this.elapsed,
    required this.stopReason,
  });

  final int tokenCount;
  final Duration elapsed;

  /// 'eos' | 'stopString' | 'maxTokens' | 'cancelled'
  final String stopReason;

  double get tokensPerSecond => elapsed.inMilliseconds == 0
      ? 0
      : tokenCount / (elapsed.inMilliseconds / 1000);
}

class ErrorEvent extends GenerationEvent {
  const ErrorEvent(this.error);
  final Object error;
}

class EngineConfig {
  const EngineConfig({
    required this.modelPath,
    required this.manifest,
    required this.contextLength,
    required this.threadCount,
  });

  final String modelPath;
  final ModelManifest manifest;

  /// May be lower than the manifest's context if the device cannot afford
  /// the KV cache. Decided by the caller, not the engine.
  final int contextLength;

  /// Performance cores only. Using every core (`Platform.numberOfProcessors`)
  /// is slower on big.LITTLE Android SoCs, not faster, because the whole
  /// batch waits on the efficiency cores.
  final int threadCount;
}

/// The boundary between the app and llama.cpp.
///
/// Everything above this interface is plain Dart and testable. The real
/// implementation runs on a background isolate and talks to llama.cpp over
/// FFI; calling `llama_decode` on the UI isolate freezes the app for the
/// whole generation.
abstract class LlamaEngine {
  Future<void> load(EngineConfig config);
  Future<void> unload();
  bool get isLoaded;

  /// Streams a reply for [turns]. Cancel by calling [stop].
  Stream<GenerationEvent> generate({
    required List<ChatTurn> turns,
    SamplingDefaults? sampling,
    int? seed,
  });

  /// Halts the current generation. The stream closes with a [DoneEvent]
  /// carrying stopReason 'cancelled'.
  Future<void> stop();

  /// Token count for [text], used by the context budget. Must be the
  /// model's own tokenizer -- a character heuristic will be wrong by enough
  /// to blow the context window.
  Future<int> countTokens(String text);

  /// Serialises the KV cache so a reopened conversation skips prefill.
  /// Maps to `llama_state_save_file` / `llama_state_load_file`.
  Future<void> saveSession(String path);
  Future<bool> loadSession(String path);
}

import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../models/model_manifest.dart';
import 'llama_engine.dart';

/// Stands in for llama.cpp so the whole app -- UI, persistence, context
/// budgeting, session restore -- can be built and tested before the FFI
/// binding exists.
///
/// It deliberately imitates the timings you will actually see on a
/// mid-range Android so the UI is designed against realistic latency rather
/// than instant replies. Swap it for the real engine; nothing above this
/// interface changes.
class FakeLlamaEngine implements LlamaEngine {
  FakeLlamaEngine({this.tokensPerSecond = 6, this.prefillTokensPerSecond = 60});

  final double tokensPerSecond;
  final double prefillTokensPerSecond;

  EngineConfig? _config;
  bool _stopRequested = false;
  int _cachedTokens = 0;

  @override
  bool get isLoaded => _config != null;

  @override
  Future<void> load(EngineConfig config) async {
    // Real loads mmap a multi-gigabyte file; not instant.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    _config = config;
  }

  @override
  Future<void> unload() async {
    _config = null;
    _cachedTokens = 0;
  }

  @override
  Stream<GenerationEvent> generate({
    required List<ChatTurn> turns,
    SamplingDefaults? sampling,
    int? seed,
  }) async* {
    final config = _config;
    if (config == null) {
      yield ErrorEvent(StateError('engine not loaded'));
      return;
    }

    _stopRequested = false;
    final settings = sampling ?? config.manifest.sampling;

    final promptTokens = await countTokens(
      turns.map((t) => t.content).join('\n'),
    );

    // Only the tokens beyond the cached prefix need recomputing. This is
    // exactly the win that session restore buys on a real device.
    final toPrefill = max(0, promptTokens - _cachedTokens);
    final prefillMs = (toPrefill / prefillTokensPerSecond * 1000).round();
    final prefillWatch = Stopwatch()..start();
    await Future<void>.delayed(Duration(milliseconds: prefillMs));
    prefillWatch.stop();

    yield PrefillDoneEvent(
      promptTokens: promptTokens,
      cachedTokens: _cachedTokens,
      elapsed: prefillWatch.elapsed,
    );

    final reply = _canned(turns);
    final words = reply.split(' ');
    final delay = Duration(milliseconds: (1000 / tokensPerSecond).round());
    final watch = Stopwatch()..start();
    var emitted = 0;

    for (final word in words) {
      if (_stopRequested) {
        watch.stop();
        yield DoneEvent(
          tokenCount: emitted,
          elapsed: watch.elapsed,
          stopReason: 'cancelled',
        );
        return;
      }
      if (emitted >= settings.maxTokens) break;
      await Future<void>.delayed(delay);
      yield TokenEvent(emitted == 0 ? word : ' $word');
      emitted++;
    }

    watch.stop();
    _cachedTokens = promptTokens + emitted;

    yield DoneEvent(
      tokenCount: emitted,
      elapsed: watch.elapsed,
      stopReason: emitted >= settings.maxTokens ? 'maxTokens' : 'eos',
    );
  }

  @override
  Future<void> stop() async => _stopRequested = true;

  /// ~3.6 characters per token, which is close enough for English prose to
  /// exercise the budgeting logic. The real engine must use the model's
  /// tokenizer.
  @override
  Future<int> countTokens(String text) async => (text.length / 3.6).ceil();

  @override
  Future<void> saveSession(String path) async {
    await File(path).writeAsString('$_cachedTokens');
  }

  @override
  Future<bool> loadSession(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    _cachedTokens = int.tryParse(await file.readAsString()) ?? 0;
    return _cachedTokens > 0;
  }

  String _canned(List<ChatTurn> turns) {
    final last = turns.lastWhere(
      (t) => t.role == 'user',
      orElse: () => const ChatTurn(role: 'user', content: ''),
    );
    return 'This is a simulated reply from FakeLlamaEngine, streamed at '
        '${tokensPerSecond.toStringAsFixed(0)} tokens per second to match a '
        'mid-range Android device. You said: "${last.content}". Replace this '
        'engine with the llama.cpp FFI implementation and nothing else in '
        'the app has to change.';
  }
}

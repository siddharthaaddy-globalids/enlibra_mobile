import 'dart:async';
import 'dart:isolate';

import 'package:llama_bridge/llama_bridge.dart';

import '../models/model_manifest.dart';
import 'llama_engine.dart';
import 'llama_worker.dart';
import 'stop_string_filter.dart';

/// The real engine: llama.cpp over FFI, running on a background isolate.
///
/// Every native call blocks its thread, prefill included. On the UI isolate
/// that would freeze the app for the entire generation, so the native
/// session lives in [llamaWorkerMain] and this class only exchanges
/// messages with it.
class LlamaFfiEngine implements LlamaEngine {
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _responses;
  StreamQueue<dynamic>? _incoming;

  /// Calls straight into the native cancel flag. The stop button cannot go
  /// through the worker's message queue, because the worker is blocked
  /// inside a decode call and will not read it until that call returns.
  LlamaCanceller? _canceller;

  EngineConfig? _config;
  @override
  bool get isLoaded => _config != null;

  @override
  Future<void> load(EngineConfig config) async {
    await unload();

    final responses = ReceivePort();
    _responses = responses;
    _incoming = StreamQueue<dynamic>(responses);

    _isolate = await Isolate.spawn(
      llamaWorkerMain,
      responses.sendPort,
      debugName: 'llama',
      errorsAreFatal: true,
    );

    _commands = await _incoming!.next as SendPort;

    final reply = ReceivePort();
    _commands!.send(
      LoadCommand(
        reply: reply.sendPort,
        modelPath: config.modelPath,
        contextLength: config.contextLength,
        threadCount: config.threadCount,
        kvType: config.manifest.kvCacheType,
      ),
    );

    final result = await reply.first;
    reply.close();
    if (result is WorkerError) {
      await unload();
      throw LlamaException(result.message);
    }

    _canceller = LlamaCanceller((result as LoadedReply).sessionAddress);
    _config = config;
  }

  @override
  Future<void> unload() async {
    _commands?.send(const DisposeCommand());
    // The worker may be mid-decode; give it a moment to unwind before
    // killing it, so llama.cpp gets a chance to free its buffers.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate?.kill(priority: Isolate.immediate);
    await _incoming?.cancel();
    _responses?.close();

    _isolate = null;
    _commands = null;
    _responses = null;
    _incoming = null;
    _canceller = null;
    _config = null;
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

    final settings = sampling ?? config.manifest.sampling;
    final reply = ReceivePort();

    _commands!.send(
      GenerateCommand(
        reply: reply.sendPort,
        messages: turns.map((t) => (role: t.role, content: t.content)).toList(),
        temperature: settings.temperature,
        topP: settings.topP,
        topK: settings.topK,
        repeatPenalty: settings.repeatPenalty,
        maxTokens: settings.maxTokens,
        seed: seed,
      ),
    );

    final filter = StopStringFilter(config.manifest.stopStrings);
    final watch = Stopwatch();
    var tokenCount = 0;

    try {
      await for (final message in reply) {
        switch (message) {
          case PrefillReply(
            :final promptTokens,
            :final cachedTokens,
            :final elapsed,
          ):
            watch.start();
            yield PrefillDoneEvent(
              promptTokens: promptTokens,
              cachedTokens: cachedTokens,
              elapsed: elapsed,
            );

          case TokenReply(:final text):
            tokenCount++;
            final emit = filter.add(text);
            if (emit.isNotEmpty) yield TokenEvent(emit);
            if (filter.stopped) {
              // A stop string arrived mid-stream. Tell the worker to stop
              // decoding rather than letting it run to maxTokens.
              _canceller?.cancel();
            }

          case DoneReply(:final stopReason):
            watch.stop();
            final tail = filter.flush();
            if (tail.isNotEmpty) yield TokenEvent(tail);
            yield DoneEvent(
              tokenCount: tokenCount,
              elapsed: watch.elapsed,
              stopReason: filter.stopped ? 'stopString' : stopReason,
            );
            return;

          case WorkerError(:final message):
            watch.stop();
            yield ErrorEvent(LlamaException(message));
            return;
        }
      }
    } finally {
      reply.close();
    }
  }

  @override
  Future<void> stop() async => _canceller?.cancel();

  @override
  Future<int> countTokens(String text) async {
    if (_commands == null) return 0;
    final reply = ReceivePort();
    _commands!.send(CountTokensCommand(reply: reply.sendPort, text: text));
    final result = await reply.first;
    reply.close();
    return result is int ? result : 0;
  }

  @override
  Future<void> saveSession(String path) async {
    if (_commands == null) return;
    final reply = ReceivePort();
    _commands!.send(SaveSessionCommand(reply: reply.sendPort, path: path));
    await reply.first;
    reply.close();
  }

  @override
  Future<bool> loadSession(String path) async {
    if (_commands == null) return false;
    final reply = ReceivePort();
    _commands!.send(LoadSessionCommand(reply: reply.sendPort, path: path));
    final result = await reply.first;
    reply.close();
    return result == true;
  }
}

/// Minimal single-subscription queue over a [ReceivePort].
///
/// `package:async`'s StreamQueue would do, but pulling in the dependency
/// for one handshake is not worth it.
class StreamQueue<T> {
  StreamQueue(Stream<T> source) : _subscription = source.listen(null) {
    _subscription
      ..onData(_onData)
      ..onDone(_onDone);
  }

  final StreamSubscription<T> _subscription;
  final List<T> _buffered = [];
  final List<Completer<T>> _waiting = [];
  bool _done = false;

  void _onData(T value) {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete(value);
    } else {
      _buffered.add(value);
    }
  }

  void _onDone() {
    _done = true;
    for (final c in _waiting) {
      c.completeError(StateError('worker closed'));
    }
    _waiting.clear();
  }

  Future<T> get next {
    if (_buffered.isNotEmpty) return Future.value(_buffered.removeAt(0));
    if (_done) return Future.error(StateError('worker closed'));
    final completer = Completer<T>();
    _waiting.add(completer);
    return completer.future;
  }

  Future<void> cancel() => _subscription.cancel();
}

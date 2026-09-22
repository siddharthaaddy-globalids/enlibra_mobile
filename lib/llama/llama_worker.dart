import 'dart:isolate';

import 'package:llama_bridge/llama_bridge.dart';

/// Messages between [LlamaFfiEngine] and the worker isolate.
///
/// Everything crossing an isolate boundary must be sendable, so these are
/// plain data. The native session pointer travels as an integer address,
/// which is safe because both isolates are in the same process.
sealed class WorkerCommand {
  const WorkerCommand();
}

class LoadCommand extends WorkerCommand {
  const LoadCommand({
    required this.reply,
    required this.modelPath,
    required this.contextLength,
    required this.threadCount,
    required this.kvType,
  });

  final SendPort reply;
  final String modelPath;
  final int contextLength;
  final int threadCount;
  final String kvType;
}

class GenerateCommand extends WorkerCommand {
  const GenerateCommand({
    required this.reply,
    required this.messages,
    required this.temperature,
    required this.topP,
    required this.topK,
    required this.repeatPenalty,
    required this.maxTokens,
    this.seed,
  });

  final SendPort reply;
  final List<({String role, String content})> messages;
  final double temperature;
  final double topP;
  final int topK;
  final double repeatPenalty;
  final int maxTokens;
  final int? seed;
}

class CountTokensCommand extends WorkerCommand {
  const CountTokensCommand({required this.reply, required this.text});
  final SendPort reply;
  final String text;
}

class SaveSessionCommand extends WorkerCommand {
  const SaveSessionCommand({required this.reply, required this.path});
  final SendPort reply;
  final String path;
}

class LoadSessionCommand extends WorkerCommand {
  const LoadSessionCommand({required this.reply, required this.path});
  final SendPort reply;
  final String path;
}

class DisposeCommand extends WorkerCommand {
  const DisposeCommand();
}

// --- replies ---------------------------------------------------------------

sealed class WorkerReply {
  const WorkerReply();
}

class LoadedReply extends WorkerReply {
  const LoadedReply({
    required this.sessionAddress,
    required this.contextLength,
  });

  /// Native pointer as an integer, so the main isolate can build a
  /// [LlamaCanceller] that reaches the decode loop while it is blocked.
  final int sessionAddress;
  final int contextLength;
}

class PrefillReply extends WorkerReply {
  const PrefillReply({
    required this.promptTokens,
    required this.cachedTokens,
    required this.elapsed,
  });

  final int promptTokens;
  final int cachedTokens;
  final Duration elapsed;
}

class TokenReply extends WorkerReply {
  const TokenReply(this.text);
  final String text;
}

class DoneReply extends WorkerReply {
  const DoneReply(this.stopReason);
  final String stopReason;
}

class WorkerError extends WorkerReply {
  const WorkerError(this.message);
  final String message;
}

// --- worker ----------------------------------------------------------------

/// Isolate entry point. Owns the native session for its whole lifetime.
void llamaWorkerMain(SendPort handshake) {
  final commands = ReceivePort();
  handshake.send(commands.sendPort);

  LlamaSession? session;

  commands.listen((message) {
    switch (message as WorkerCommand) {
      case LoadCommand(
        :final reply,
        :final modelPath,
        :final contextLength,
        :final threadCount,
        :final kvType,
      ):
        try {
          session = LlamaSession.open(
            modelPath: modelPath,
            contextLength: contextLength,
            threadCount: threadCount,
            kvType: kvType,
          );
          reply.send(
            LoadedReply(
              sessionAddress: session!.address,
              contextLength: session!.contextLength,
            ),
          );
        } catch (e) {
          reply.send(WorkerError('$e'));
        }

      case GenerateCommand cmd:
        final s = session;
        if (s == null) {
          cmd.reply.send(const WorkerError('engine not loaded'));
          return;
        }
        try {
          // Formatting happens here, using the template inside the GGUF,
          // rather than being assembled in Dart where it is easy to get
          // subtly wrong.
          final prompt = s.formatPrompt(cmd.messages);

          s.beginGeneration(
            prompt,
            temperature: cmd.temperature,
            topP: cmd.topP,
            topK: cmd.topK,
            repeatPenalty: cmd.repeatPenalty,
            seed: cmd.seed,
            maxTokens: cmd.maxTokens,
          );

          cmd.reply.send(
            PrefillReply(
              promptTokens: s.lastPromptTokens,
              cachedTokens: s.lastCachedTokens,
              elapsed: s.lastPrefill,
            ),
          );

          // Each nextToken() blocks this isolate until the token is
          // decoded. That is the point of being on a worker.
          while (true) {
            final piece = s.nextToken();
            if (piece == null) break;
            cmd.reply.send(TokenReply(piece));
          }
          cmd.reply.send(DoneReply(s.lastStopReason));
        } catch (e) {
          cmd.reply.send(WorkerError('$e'));
        }

      case CountTokensCommand(:final reply, :final text):
        reply.send(session?.countTokens(text) ?? 0);

      case SaveSessionCommand(:final reply, :final path):
        reply.send(session?.saveSession(path) ?? false);

      case LoadSessionCommand(:final reply, :final path):
        reply.send(session?.loadSession(path) ?? false);

      case DisposeCommand():
        session?.dispose();
        session = null;
        commands.close();
    }
  });
}

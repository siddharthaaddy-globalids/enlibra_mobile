import 'dart:async';

import 'package:flutter/foundation.dart';

import '../db/chat_repository.dart';
import '../download/storage_paths.dart';
import '../llama/llama_engine.dart';
import '../models/model_manifest.dart';
import 'context_budget.dart';

enum ChatStatus { idle, restoring, prefilling, generating, summarizing, error }

/// Drives one conversation: assembles the prompt, streams the reply,
/// persists both sides, and keeps the context window from overflowing.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.engine,
    required this.repository,
    required this.manifest,
    required this.conversation,
    required int contextLength,
  }) : budget = ContextBudget(
         contextLength: contextLength,
         maxResponseTokens: manifest.sampling.maxTokens,
       );

  final LlamaEngine engine;
  final ChatRepository repository;
  final ModelManifest manifest;
  final Conversation conversation;
  final ContextBudget budget;

  final List<StoredMessage> _messages = [];
  List<StoredMessage> get messages => List.unmodifiable(_messages);

  ChatStatus _status = ChatStatus.idle;
  ChatStatus get status => _status;

  String _streaming = '';
  String get streamingText => _streaming;

  Object? _error;
  Object? get error => _error;

  int _promptTokens = 0;

  /// How full the context window is, for a UI indicator. Users deserve to
  /// know before the app silently starts dropping their history.
  double get contextFraction =>
      (_promptTokens / budget.promptBudget).clamp(0.0, 1.0);

  Duration? _lastPrefill;
  Duration? get lastPrefill => _lastPrefill;

  double? _lastTokensPerSecond;
  double? get lastTokensPerSecond => _lastTokensPerSecond;

  StreamSubscription<GenerationEvent>? _subscription;

  Future<void> initialize() async {
    _setStatus(ChatStatus.restoring);
    _messages
      ..clear()
      ..addAll(await repository.messages(conversation.id));

    // Restoring the KV cache turns a 25-60s prefill into roughly nothing.
    // A failed restore is not an error; it just means paying the prefill.
    if (conversation.hasSession) {
      final path = StoragePaths.instance.sessionFile(conversation.id).path;
      final restored = await engine.loadSession(path);
      if (!restored) await repository.setHasSession(conversation.id, false);
    }

    _setStatus(ChatStatus.idle);
  }

  Future<void> send(String text) async {
    if (_status != ChatStatus.idle || text.trim().isEmpty) return;

    _error = null;
    final trimmed = text.trim();
    final userTokens = await engine.countTokens(trimmed);

    final id = await repository.addMessage(
      conversationId: conversation.id,
      role: 'user',
      content: trimmed,
      tokenCount: userTokens,
    );
    _messages.add(
      StoredMessage(
        id: id,
        role: 'user',
        content: trimmed,
        tokenCount: userTokens,
      ),
    );
    notifyListeners();

    var summary = await repository.latestSummary(conversation.id);
    var plan = budget.plan(
      systemPrompt: conversation.systemPrompt,
      summary: summary?.content,
      summaryTokens: summary?.tokenCount ?? 0,
      history: _messages,
    );

    if (plan.needsSummarization) {
      await _summarize(plan.messagesToSummarize, summary);
      summary = await repository.latestSummary(conversation.id);
      _messages
        ..clear()
        ..addAll(await repository.messages(conversation.id));
      plan = budget.plan(
        systemPrompt: conversation.systemPrompt,
        summary: summary?.content,
        summaryTokens: summary?.tokenCount ?? 0,
        history: _messages,
      );
    }

    _promptTokens = plan.tokenCount;
    await _stream(plan.turns);
  }

  Future<void> _stream(List<ChatTurn> turns) async {
    _streaming = '';
    _setStatus(ChatStatus.prefilling);

    final completer = Completer<void>();
    _subscription = engine
        .generate(turns: turns, sampling: manifest.sampling)
        .listen(
          (event) {
            switch (event) {
              case PrefillDoneEvent(:final elapsed):
                _lastPrefill = elapsed;
                _setStatus(ChatStatus.generating);
              case TokenEvent(:final text):
                _streaming += text;
                notifyListeners();
              case DoneEvent(:final tokensPerSecond):
                _lastTokensPerSecond = tokensPerSecond;
              case ErrorEvent(:final error):
                _error = error;
                _setStatus(ChatStatus.error);
            }
          },
          onError: (Object e) {
            _error = e;
            _setStatus(ChatStatus.error);
            if (!completer.isCompleted) completer.complete();
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
        );

    await completer.future;
    await _subscription?.cancel();
    _subscription = null;

    if (_streaming.isNotEmpty) {
      final tokens = await engine.countTokens(_streaming);
      final id = await repository.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        content: _streaming,
        tokenCount: tokens,
      );
      _messages.add(
        StoredMessage(
          id: id,
          role: 'assistant',
          content: _streaming,
          tokenCount: tokens,
        ),
      );
      _promptTokens += tokens;

      // Persist the KV cache now, while it matches the stored history
      // exactly. Saving later risks the two drifting apart.
      final path = StoragePaths.instance.sessionFile(conversation.id).path;
      await engine.saveSession(path);
      await repository.setHasSession(conversation.id, true);
    }

    _streaming = '';
    if (_status != ChatStatus.error) _setStatus(ChatStatus.idle);
  }

  /// Compresses the oldest turns into a summary using the same model.
  ///
  /// This costs a full generation the user did not ask for, so it runs only
  /// when the budget demands it, and the UI says what is happening.
  Future<void> _summarize(
    List<StoredMessage> toSummarize,
    ConversationSummary? previous,
  ) async {
    _setStatus(ChatStatus.summarizing);

    final transcript = toSummarize
        .map((m) => (m.role == 'user' ? 'User: ' : 'Assistant: ') + m.content)
        .join('\n');

    final instruction = StringBuffer()
      ..writeln('Condense the conversation below into a brief factual note.')
      ..writeln('Keep names, decisions, preferences and open questions.')
      ..writeln('Drop small talk. At most 150 words. No preamble.');
    if (previous != null) {
      instruction
        ..writeln()
        ..writeln('Existing note to fold in:')
        ..writeln(previous.content);
    }
    instruction
      ..writeln()
      ..writeln('Conversation:')
      ..writeln(transcript);

    final buffer = StringBuffer();
    await for (final event in engine.generate(
      turns: [ChatTurn(role: 'user', content: instruction.toString())],
      sampling: const SamplingDefaults(temperature: 0.3, maxTokens: 256),
    )) {
      if (event is TokenEvent) buffer.write(event.text);
      if (event is ErrorEvent) {
        _error = event.error;
        _setStatus(ChatStatus.error);
        return;
      }
    }

    final content = buffer.toString().trim();
    if (content.isEmpty) return;

    await repository.saveSummary(
      conversationId: conversation.id,
      content: content,
      tokenCount: await engine.countTokens(content),
      coversUntilId: toSummarize.last.id,
    );

    // History changed underneath the KV cache, so the saved session no
    // longer matches the prompt. Drop it rather than restore a stale one.
    await repository.setHasSession(conversation.id, false);
    final file = StoragePaths.instance.sessionFile(conversation.id);
    if (await file.exists()) await file.delete();
  }

  Future<void> stop() async => engine.stop();

  void _setStatus(ChatStatus value) {
    _status = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

import '../llama/llama_engine.dart';

/// A message as stored, with its cached token count.
class StoredMessage {
  const StoredMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.tokenCount,
    this.summarized = false,
  });

  final int id;
  final String role;
  final String content;
  final int tokenCount;
  final bool summarized;

  ChatTurn toTurn() => ChatTurn(role: role, content: content);
}

/// What the engine should actually be sent this turn.
class PromptPlan {
  const PromptPlan({
    required this.turns,
    required this.tokenCount,
    required this.needsSummarization,
    required this.messagesToSummarize,
  });

  final List<ChatTurn> turns;
  final int tokenCount;

  /// True when the caller should run the summarizer before sending.
  final bool needsSummarization;

  /// Messages the summarizer should compress, oldest first.
  final List<StoredMessage> messagesToSummarize;
}

/// Decides what fits in the context window.
///
/// The thresholds here are tuned for mobile, where the window is 4k rather
/// than 128k and prefill is the dominant cost. Summarization triggers at
/// 50% rather than the 70-80% that is reasonable on a server: crossing the
/// limit mid-conversation on a phone means either a truncated prompt or a
/// multi-second recovery, and neither is acceptable in a chat UI.
class ContextBudget {
  const ContextBudget({
    required this.contextLength,
    required this.maxResponseTokens,
    this.summarizeAtFraction = 0.50,
    this.keepRecentTurns = 6,
  });

  final int contextLength;

  /// Reserved for the reply. Prompt plus this must stay inside the window.
  final int maxResponseTokens;

  final double summarizeAtFraction;

  /// Turns always kept verbatim, never summarized. Below about 4 the model
  /// loses the thread of the immediate exchange.
  final int keepRecentTurns;

  /// Tokens available to the prompt.
  int get promptBudget => contextLength - maxResponseTokens;

  int get summarizeThreshold => (promptBudget * summarizeAtFraction).round();

  /// Builds the turn list to send, and reports whether summarization should
  /// run first.
  PromptPlan plan({
    required String? systemPrompt,
    required String? summary,
    required int summaryTokens,
    required List<StoredMessage> history,
  }) {
    final turns = <ChatTurn>[];
    var tokens = 0;

    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      turns.add(ChatTurn(role: 'system', content: systemPrompt));
      tokens += _estimate(systemPrompt);
    }

    if (summary != null && summary.isNotEmpty) {
      // Carried as a system turn rather than a fake assistant message, so
      // the model treats it as context rather than as something it said.
      turns.add(
        ChatTurn(
          role: 'system',
          content: 'Summary of the earlier conversation:\n$summary',
        ),
      );
      tokens += summaryTokens;
    }

    final live = history.where((m) => !m.summarized).toList(growable: false);
    for (final m in live) {
      turns.add(m.toTurn());
      tokens += m.tokenCount;
    }

    final over = tokens >= summarizeThreshold;
    final candidates = over && live.length > keepRecentTurns
        ? live.sublist(0, live.length - keepRecentTurns)
        : const <StoredMessage>[];

    return PromptPlan(
      turns: turns,
      tokenCount: tokens,
      needsSummarization: candidates.isNotEmpty,
      messagesToSummarize: candidates,
    );
  }

  /// Emergency trim, for when summarization has run and the prompt is still
  /// too large -- a single pasted wall of text can do this. Drops the oldest
  /// non-system turns until it fits.
  List<ChatTurn> hardTrim(List<ChatTurn> turns, List<int> tokenCounts) {
    final result = List<ChatTurn>.from(turns);
    final counts = List<int>.from(tokenCounts);
    var total = counts.fold(0, (a, b) => a + b);

    var i = 0;
    while (total > promptBudget && result.length > 1) {
      if (result[i].role == 'system') {
        i++;
        if (i >= result.length) break;
        continue;
      }
      total -= counts.removeAt(i);
      result.removeAt(i);
    }
    return result;
  }

  static int _estimate(String text) => (text.length / 3.6).ceil();
}

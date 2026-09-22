import 'package:sqflite/sqflite.dart';

import '../chat/context_budget.dart';

class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.modelId,
    this.systemPrompt,
    this.hasSession = false,
  });

  final int id;
  final String title;
  final String modelId;
  final String? systemPrompt;
  final bool hasSession;
}

class ConversationSummary {
  const ConversationSummary({
    required this.content,
    required this.tokenCount,
    required this.coversUntilId,
  });

  final String content;
  final int tokenCount;
  final int coversUntilId;
}

class ChatRepository {
  ChatRepository(this._db);
  final Database _db;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<List<Conversation>> listConversations() async {
    final rows = await _db.query('conversations', orderBy: 'updated_at DESC');
    return rows.map(_toConversation).toList(growable: false);
  }

  Future<Conversation> createConversation({
    required String modelId,
    String title = 'New chat',
    String? systemPrompt,
  }) async {
    final now = _now();
    final id = await _db.insert('conversations', {
      'title': title,
      'model_id': modelId,
      'system_prompt': systemPrompt,
      'created_at': now,
      'updated_at': now,
      'has_session': 0,
    });
    return Conversation(
      id: id,
      title: title,
      modelId: modelId,
      systemPrompt: systemPrompt,
    );
  }

  Future<void> deleteConversation(int id) =>
      _db.delete('conversations', where: 'id = ?', whereArgs: [id]);

  Future<List<StoredMessage>> messages(int conversationId) async {
    final rows = await _db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows
        .map(
          (r) => StoredMessage(
            id: r['id'] as int,
            role: r['role'] as String,
            content: r['content'] as String,
            tokenCount: r['token_count'] as int,
            summarized: (r['summarized'] as int) == 1,
          ),
        )
        .toList(growable: false);
  }

  Future<int> addMessage({
    required int conversationId,
    required String role,
    required String content,
    required int tokenCount,
  }) async {
    final now = _now();
    final id = await _db.insert('messages', {
      'conversation_id': conversationId,
      'role': role,
      'content': content,
      'token_count': tokenCount,
      'created_at': now,
      'summarized': 0,
    });
    await _db.update(
      'conversations',
      {'updated_at': now},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
    return id;
  }

  /// Latest summary for a conversation, or null if none has been made yet.
  Future<ConversationSummary?> latestSummary(int conversationId) async {
    final rows = await _db.query(
      'summaries',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return ConversationSummary(
      content: r['content'] as String,
      tokenCount: r['token_count'] as int,
      coversUntilId: r['covers_until_id'] as int,
    );
  }

  /// Records a summary and marks the messages it absorbed. Done in one
  /// transaction: a summary that is stored without marking its messages
  /// would duplicate that content in every later prompt.
  Future<void> saveSummary({
    required int conversationId,
    required String content,
    required int tokenCount,
    required int coversUntilId,
  }) async {
    await _db.transaction((txn) async {
      await txn.insert('summaries', {
        'conversation_id': conversationId,
        'content': content,
        'token_count': tokenCount,
        'covers_until_id': coversUntilId,
        'created_at': _now(),
      });
      await txn.update(
        'messages',
        {'summarized': 1},
        where: 'conversation_id = ? AND id <= ?',
        whereArgs: [conversationId, coversUntilId],
      );
    });
  }

  Future<void> setHasSession(int conversationId, bool value) => _db.update(
    'conversations',
    {'has_session': value ? 1 : 0},
    where: 'id = ?',
    whereArgs: [conversationId],
  );

  Future<void> renameConversation(int id, String title) => _db.update(
    'conversations',
    {'title': title, 'updated_at': _now()},
    where: 'id = ?',
    whereArgs: [id],
  );

  static Conversation _toConversation(Map<String, Object?> r) => Conversation(
    id: r['id'] as int,
    title: r['title'] as String,
    modelId: r['model_id'] as String,
    systemPrompt: r['system_prompt'] as String?,
    hasSession: (r['has_session'] as int) == 1,
  );
}

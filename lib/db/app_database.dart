import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// SQLite schema for conversations, messages and rolling summaries.
///
/// Raw turns are kept forever for display. What goes into the prompt is
/// decided separately by ContextBudget, which may substitute a summary for
/// the older turns. Keeping the two apart means the UI can show full
/// history while the prompt stays small.
class AppDatabase {
  AppDatabase._(this.db);
  final Database db;

  static const _version = 1;

  static Future<AppDatabase> open() async {
    // sqflite has no native desktop implementation; the ffi backend covers
    // the Windows/macOS dev harness.
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'enlibra.db');

    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onCreate: _createSchema,
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE conversations (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        title         TEXT    NOT NULL,
        model_id      TEXT    NOT NULL,
        system_prompt TEXT,
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL,
        -- Set when a llama.cpp KV state file exists for this conversation.
        -- Invalidated whenever history is edited or the model changes.
        has_session   INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL
                        REFERENCES conversations(id) ON DELETE CASCADE,
        role            TEXT    NOT NULL,
        content         TEXT    NOT NULL,
        -- Cached tokenizer count. Recomputing every turn on device is
        -- wasteful, and the budget check runs on every send.
        token_count     INTEGER NOT NULL DEFAULT 0,
        created_at      INTEGER NOT NULL,
        -- 1 once a summary has absorbed this message, so it is shown in the
        -- UI but excluded from the prompt.
        summarized      INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_messages_conversation '
      'ON messages(conversation_id, created_at)',
    );

    await db.execute('''
      CREATE TABLE summaries (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id  INTEGER NOT NULL
                         REFERENCES conversations(id) ON DELETE CASCADE,
        content          TEXT    NOT NULL,
        token_count      INTEGER NOT NULL,
        -- Range of messages this summary replaces.
        covers_until_id  INTEGER NOT NULL,
        created_at       INTEGER NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_summaries_conversation ON summaries(conversation_id)',
    );

    await db.execute('''
      CREATE TABLE installed_models (
        id            TEXT PRIMARY KEY,
        version       TEXT    NOT NULL,
        display_name  TEXT    NOT NULL,
        manifest_json TEXT    NOT NULL,
        size_bytes    INTEGER NOT NULL,
        installed_at  INTEGER NOT NULL
      )
    ''');
  }

  Future<void> close() => db.close();
}

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Schema migrations, applied in order. `PRAGMA user_version` stores the
/// number of migrations already applied.
///
/// RULES (a shipped migration is never edited, moved or removed):
/// - Only append new migrations to the END of this list.
/// - Never insert in the middle: version numbers would shift and users' databases
///   would be marked as migrated when they are not (this caused 1.2.1–1.2.3 breakage).
/// - Changing an old entry is forbidden; `test/data/migrate_test.dart` checks this.
const _migrations = <String>[
  '''
  CREATE TABLE notes (
    id        TEXT PRIMARY KEY,
    title     TEXT NOT NULL DEFAULT '',
    content   TEXT NOT NULL,
    plain     TEXT NOT NULL DEFAULT '',
    search    TEXT NOT NULL DEFAULT '',
    created   INTEGER NOT NULL,
    updated   INTEGER NOT NULL,
    vv        TEXT NOT NULL,
    dev       TEXT NOT NULL,
    deleted   INTEGER NOT NULL DEFAULT 0,
    seq       INTEGER NOT NULL,
    src       TEXT,
    dismissed TEXT NOT NULL DEFAULT '[]'
  );
  CREATE INDEX notes_seq ON notes(seq);
  CREATE INDEX notes_updated ON notes(deleted, updated);

  CREATE TABLE change_log (
    seq     INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id TEXT NOT NULL,
    op      TEXT NOT NULL,
    vv      TEXT NOT NULL,
    device  TEXT NOT NULL,
    at      INTEGER NOT NULL
  );

  CREATE TABLE conflicts (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id   TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    loser_key TEXT NOT NULL,
    payload   TEXT NOT NULL,
    detected  INTEGER NOT NULL,
    UNIQUE(note_id, loser_key)
  );

  CREATE TABLE peers (
    device_id   TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    public_key  TEXT NOT NULL,
    paired      INTEGER NOT NULL,
    last_sync   INTEGER,
    addr        TEXT,
    port        INTEGER,
    epoch       TEXT,
    recv_cursor INTEGER NOT NULL DEFAULT 0
  );

  CREATE TABLE settings (
    key   TEXT PRIMARY KEY,
    value TEXT
  );
  ''',
  '''
  CREATE TABLE attachments (
    id        TEXT PRIMARY KEY,
    note_id   TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    name      TEXT NOT NULL,
    mime      TEXT NOT NULL DEFAULT '',
    size      INTEGER NOT NULL,
    sha256    TEXT NOT NULL,
    created   INTEGER NOT NULL
  );
  CREATE INDEX attachments_note ON attachments(note_id);
  ''',
  '''
  CREATE TABLE file_holders (
    sha256    TEXT NOT NULL,
    device_id TEXT NOT NULL,
    PRIMARY KEY (sha256, device_id)
  );
  ''',
  '''
  ALTER TABLE notes ADD COLUMN important INTEGER NOT NULL DEFAULT 0;
  CREATE INDEX notes_important ON notes(deleted, important, updated);
  ''',
  '''
  ALTER TABLE notes ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;
  CREATE INDEX notes_archived ON notes(deleted, archived, updated);
  ''',
  '''
  CREATE TABLE IF NOT EXISTS saved_copies (
    sha256 TEXT PRIMARY KEY,
    path   TEXT NOT NULL
  );
  ''',
  '''
  ALTER TABLE notes ADD COLUMN trashed_at INTEGER;
  ALTER TABLE notes ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
  CREATE INDEX notes_trashed ON notes(deleted, trashed_at);
  ''',
  '''
  ALTER TABLE notes ADD COLUMN kind TEXT NOT NULL DEFAULT 'text';
  ''',
];

int get schemaVersion => _migrations.length;

/// Read-only view of the migration list for tests.
List<String> migrationsForTest() => List.unmodifiable(_migrations);

void migrate(Database db, {String? backupPath}) {
  final current = db.select('PRAGMA user_version').first.values.first as int;
  if (backupPath != null && current < _migrations.length && current > 0) {
    _backup(db, '$backupPath.bak-v$current');
  }
  for (var v = current; v < _migrations.length; v++) {
    db.execute('BEGIN');
    try {
      _applyMigration(db, _migrations[v]);
      db.execute('PRAGMA user_version = ${v + 1}');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  _repairSchema(db);
}

/// Copies the database before a migration, so a failed upgrade never loses data.
/// Keeps the copy only if it does not exist yet.
void _backup(Database db, String target) {
  final f = File(target);
  if (f.existsSync()) return;
  final escaped = target.replaceAll("'", "''");
  db.execute("VACUUM INTO '$escaped'");
}

void _applyMigration(Database db, String sql) {
  for (final stmt in sql.split(';')) {
    final s = stmt.trim();
    if (s.isEmpty) continue;
    final add = RegExp(r'^ALTER TABLE (\w+) ADD COLUMN (\w+)').firstMatch(s);
    if (add != null && _hasColumn(db, add.group(1)!, add.group(2)!)) continue;
    final idx = RegExp(r'^CREATE INDEX (\w+)').firstMatch(s);
    if (idx != null && _hasIndex(db, idx.group(1)!)) continue;
    db.execute(s);
  }
}

/// Adds columns and indexes that the recorded version says exist but are missing.
/// A database can end up with `user_version` ahead of its real schema.
void _repairSchema(Database db) {
  final required = <String>[
    'ALTER TABLE notes ADD COLUMN important INTEGER NOT NULL DEFAULT 0',
    'ALTER TABLE notes ADD COLUMN archived INTEGER NOT NULL DEFAULT 0',
    'CREATE INDEX notes_important ON notes(deleted, important, updated)',
    'CREATE INDEX notes_archived ON notes(deleted, archived, updated)',
    'CREATE TABLE IF NOT EXISTS saved_copies (sha256 TEXT PRIMARY KEY, path TEXT NOT NULL)',
    'ALTER TABLE notes ADD COLUMN trashed_at INTEGER',
    'ALTER TABLE notes ADD COLUMN position INTEGER NOT NULL DEFAULT 0',
    'CREATE INDEX notes_trashed ON notes(deleted, trashed_at)',
    "ALTER TABLE notes ADD COLUMN kind TEXT NOT NULL DEFAULT 'text'",
  ];
  db.execute('BEGIN');
  try {
    _applyMigration(db, required.join(';'));
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

bool _hasColumn(Database db, String table, String column) =>
    db.select('PRAGMA table_info($table)').any((r) => r['name'] == column);

bool _hasIndex(Database db, String name) =>
    db.select("SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?", [name]).isNotEmpty;

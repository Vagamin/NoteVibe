import 'package:sqlite3/sqlite3.dart';

/// Schema migrations, applied in order. `PRAGMA user_version` stores the
/// number of migrations already applied.
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
];

int get schemaVersion => _migrations.length;

void migrate(Database db) {
  final current = db.select('PRAGMA user_version').first.values.first as int;
  for (var v = current; v < _migrations.length; v++) {
    db.execute('BEGIN');
    try {
      db.execute(_migrations[v]);
      db.execute('PRAGMA user_version = ${v + 1}');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}

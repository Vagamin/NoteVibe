import 'dart:convert';

import 'version_vector.dart';

/// Empty Quill document in Delta JSON form.
const emptyDeltaJson = '[{"insert":"\\n"}]';

/// One line of a note as shown in the list preview.
class NoteLine {
  final String text;

  /// `plain`, `bullet`, `unchecked` or `checked`.
  final String kind;
  const NoteLine(this.text, this.kind);
}

/// Splits Quill Delta JSON into lines with their list kind. Inline styles are dropped.
/// Falls back to [plainText] if the Delta cannot be read.
List<NoteLine> noteLines(String deltaJson, String plainText) {
  try {
    final ops = jsonDecode(deltaJson) as List;
    final lines = <NoteLine>[];
    final buf = StringBuffer();
    for (final op in ops) {
      if (op is! Map) continue;
      final insert = op['insert'];
      if (insert is! String) continue;
      var start = 0;
      while (true) {
        final nl = insert.indexOf('\n', start);
        if (nl < 0) {
          buf.write(insert.substring(start));
          break;
        }
        buf.write(insert.substring(start, nl));
        final attrs = op['attributes'];
        final list = attrs is Map ? attrs['list'] : null;
        final kind = switch (list) {
          'checked' => 'checked',
          'unchecked' => 'unchecked',
          'bullet' => 'bullet',
          _ => 'plain',
        };
        lines.add(NoteLine(buf.toString().trim(), kind));
        buf.clear();
        start = nl + 1;
      }
    }
    if (buf.isNotEmpty) lines.add(NoteLine(buf.toString().trim(), 'plain'));
    return lines;
  } catch (_) {
    return [for (final l in plainText.split('\n')) NoteLine(l.trim(), 'plain')];
  }
}

class Note {
  final String id;
  final String title;

  /// Quill Delta serialized as JSON.
  final String content;

  /// Plain-text projection of [content], used for search and previews.
  final String plainText;
  final DateTime createdAt;
  final DateTime updatedAt;
  final VersionVector version;

  /// Device that produced this version.
  final String lastDevice;
  final bool deleted;

  /// User marked the note as important (shown on top, highlighted).
  final bool important;

  /// Moved to the archive: hidden from the main list, kept for reading.
  final bool archived;

  /// When the note was moved to the trash; null when it is not in the trash.
  final DateTime? trashedAt;

  /// Place in the manual order: smaller values are higher in the list.
  final int position;

  /// `text` for a usual note, `voice` for a note made of voice recordings.
  final String kind;

  /// Computed: there are unresolved conflicting versions for this note.
  final bool hasConflict;

  const Note({
    required this.id,
    required this.title,
    required this.content,
    required this.plainText,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
    required this.lastDevice,
    this.deleted = false,
    this.important = false,
    this.archived = false,
    this.trashedAt,
    this.position = 0,
    this.kind = 'text',
    this.hasConflict = false,
  });

  bool get isVoice => kind == 'voice';

  Note copyWith({
    String? title,
    String? content,
    String? plainText,
    DateTime? updatedAt,
    VersionVector? version,
    String? lastDevice,
    bool? deleted,
    bool? important,
    bool? archived,
    DateTime? trashedAt,
    bool clearTrashed = false,
    int? position,
    String? kind,
    bool? hasConflict,
  }) =>
      Note(
        id: id,
        title: title ?? this.title,
        content: content ?? this.content,
        plainText: plainText ?? this.plainText,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        version: version ?? this.version,
        lastDevice: lastDevice ?? this.lastDevice,
        deleted: deleted ?? this.deleted,
        important: important ?? this.important,
        archived: archived ?? this.archived,
        trashedAt: clearTrashed ? null : (trashedAt ?? this.trashedAt),
        position: position ?? this.position,
        kind: kind ?? this.kind,
        hasConflict: hasConflict ?? this.hasConflict,
      );

  /// Whether user-visible data is identical (ignores metadata).
  bool sameDataAs(Note other) =>
      title == other.title &&
      content == other.content &&
      deleted == other.deleted &&
      important == other.important &&
      archived == other.archived &&
      (trashedAt == null) == (other.trashedAt == null) &&
      kind == other.kind;

  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    final firstLine = plainText.trim().split('\n').first.trim();
    return firstLine.isEmpty ? 'Без названия' : firstLine;
  }

  Map<String, dynamic> toWire() => {
        'id': id,
        'title': title,
        'content': content,
        'plain': plainText,
        'created': createdAt.millisecondsSinceEpoch,
        'updated': updatedAt.millisecondsSinceEpoch,
        'vv': version.toJson(),
        'dev': lastDevice,
        'del': deleted,
        'imp': important,
        'arc': archived,
        'trs': trashedAt?.millisecondsSinceEpoch ?? 0,
        'pos': position,
        'knd': kind,
      };

  static Note fromWire(Map<String, dynamic> m) {
    final content = m['content'] as String? ?? emptyDeltaJson;
    // Validate the delta is well-formed JSON to avoid storing garbage.
    jsonDecode(content);
    final trs = (m['trs'] as num?)?.toInt() ?? 0;
    return Note(
      id: m['id'] as String,
      title: m['title'] as String? ?? '',
      content: content,
      plainText: m['plain'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch((m['created'] as num).toInt()),
      updatedAt: DateTime.fromMillisecondsSinceEpoch((m['updated'] as num).toInt()),
      version: VersionVector.fromJson(m['vv']),
      lastDevice: m['dev'] as String? ?? '',
      deleted: m['del'] as bool? ?? false,
      important: m['imp'] as bool? ?? false,
      archived: m['arc'] as bool? ?? false,
      trashedAt: trs == 0 ? null : DateTime.fromMillisecondsSinceEpoch(trs),
      position: (m['pos'] as num?)?.toInt() ?? 0,
      kind: m['knd'] as String? ?? 'text',
    );
  }

  @override
  String toString() => 'Note($id, "$title", $version, deleted=$deleted)';
}

import 'dart:convert';

import 'version_vector.dart';

/// Empty Quill document in Delta JSON form.
const emptyDeltaJson = '[{"insert":"\\n"}]';

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
    this.hasConflict = false,
  });

  Note copyWith({
    String? title,
    String? content,
    String? plainText,
    DateTime? updatedAt,
    VersionVector? version,
    String? lastDevice,
    bool? deleted,
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
        hasConflict: hasConflict ?? this.hasConflict,
      );

  /// Whether user-visible data is identical (ignores metadata).
  bool sameDataAs(Note other) =>
      title == other.title && content == other.content && deleted == other.deleted;

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
      };

  static Note fromWire(Map<String, dynamic> m) {
    final content = m['content'] as String? ?? emptyDeltaJson;
    // Validate the delta is well-formed JSON to avoid storing garbage.
    jsonDecode(content);
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
    );
  }

  @override
  String toString() => 'Note($id, "$title", $version, deleted=$deleted)';
}

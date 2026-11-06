/// A file attached to a note. The bytes live on disk (see AttachmentStorage);
/// only the metadata is stored in SQLite.
class Attachment {
  final String id;
  final String noteId;
  final String name;
  final String? displayName;
  String get label => displayName ?? name;
  final String mime;
  final int size;
  final String sha256;
  final DateTime createdAt;

  const Attachment({
    required this.id,
    required this.noteId,
    required this.name,
    this.displayName,
    required this.mime,
    required this.size,
    required this.sha256,
    required this.createdAt,
  });

  bool get isImage => mime.startsWith('image/');

  Map<String, dynamic> toWire() => {
        'id': id,
        'name': name,
        if (displayName != null) 'displayName': displayName,
        'mime': mime,
        'size': size,
        'sha256': sha256,
        'created': createdAt.millisecondsSinceEpoch,
      };

  static Attachment fromWire(Map<String, dynamic> m, {required String noteId}) => Attachment(
        id: m['id'] as String,
        noteId: noteId,
        name: m['name'] as String,
        displayName: m['displayName'] as String?,
        mime: m['mime'] as String? ?? '',
        size: (m['size'] as num).toInt(),
        sha256: m['sha256'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch((m['created'] as num).toInt()),
      );

  String get sizeLabel {
    const kb = 1024;
    const mb = 1024 * 1024;
    if (size >= mb) return '${(size / mb).toStringAsFixed(1)} МБ';
    if (size >= kb) return '${(size / kb).round()} КБ';
    return '$size Б';
  }
}

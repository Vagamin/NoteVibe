/// A file attached to a note. The bytes live on disk (see AttachmentStorage);
/// only the metadata is stored in SQLite.
class Attachment {
  final String id;
  final String noteId;
  final String name;
  final String mime;
  final int size;
  final String sha256;
  final DateTime createdAt;

  const Attachment({
    required this.id,
    required this.noteId,
    required this.name,
    required this.mime,
    required this.size,
    required this.sha256,
    required this.createdAt,
  });

  bool get isImage => mime.startsWith('image/');

  String get sizeLabel {
    const kb = 1024;
    const mb = 1024 * 1024;
    if (size >= mb) return '${(size / mb).toStringAsFixed(1)} МБ';
    if (size >= kb) return '${(size / kb).round()} КБ';
    return '$size Б';
  }
}

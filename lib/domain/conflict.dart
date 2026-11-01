import 'note.dart';

/// An alternative version of a note that lost automatic conflict resolution.
/// It is kept until the user decides what to do with it.
class NoteConflict {
  final int id;
  final String noteId;

  /// The alternative (non-winning) version.
  final Note other;
  final DateTime detectedAt;

  const NoteConflict({
    required this.id,
    required this.noteId,
    required this.other,
    required this.detectedAt,
  });
}

enum ConflictChoice {
  /// Keep the current (winning) version and drop the alternative.
  keepCurrent,

  /// Replace the current version with the alternative.
  takeOther,

  /// Keep current and save the alternative as a separate new note.
  keepBoth,
}

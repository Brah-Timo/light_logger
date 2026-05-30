// lib/src/io/log_file_manager.dart
//
// Low-level helpers for creating, listing, and sizing log files in the
// configured log directory.
//
// Naming convention for .llog files:
//
//   app_2026-05-29_001.llog          ← active file (being written to)
//   app_2026-05-29_001.llog.arch     ← rotated / archived file
//
// The 3-digit sequence number allows multiple rotations within the same day.

import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/log_config.dart';
import '../binary/binary_schema.dart';

/// Manages the file-system view of the log directory.
///
/// Does NOT perform any I/O beyond directory creation and file listing.
/// Compression and writing are handled by [AsyncWriter].
final class LogFileManager {
  // ─────────────────────────────────────────────────────────
  //  State
  // ─────────────────────────────────────────────────────────

  final LogConfig _config;
  Directory?      _directory;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  LogFileManager(this._config);

  // ─────────────────────────────────────────────────────────
  //  Initialisation
  // ─────────────────────────────────────────────────────────

  /// Ensures the log directory exists, creating it if necessary.
  Future<void> initialize() async {
    _directory = Directory(_config.logDirectory);
    if (!await _directory!.exists()) {
      await _directory!.create(recursive: true);
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Active file
  // ─────────────────────────────────────────────────────────

  /// Returns the path of the current active log file.
  ///
  /// Creates a new file (with the correct header) if none exists.
  Future<String> getActiveFilePath() async {
    await _ensureInitialized();

    final existing = await _findActiveFile();
    if (existing != null) return existing;

    return _createNewActiveFile();
  }

  /// Creates a brand-new active file and returns its path.
  Future<String> _createNewActiveFile() async {
    final name = _buildFileName(
      date: _today(),
      sequence: await _nextSequenceNumber(),
      archived: false,
    );
    final path = p.join(_config.logDirectory, name);
    await File(path).create();
    return path;
  }

  /// Searches for an existing unarchived file.  Returns `null` if none found.
  Future<String?> _findActiveFile() async {
    final files = await listAllFiles();
    final active = files.where((f) => !f.endsWith('.arch')).toList();
    if (active.isEmpty) return null;
    active.sort();
    return active.last; // most recent
  }

  // ─────────────────────────────────────────────────────────
  //  Listing
  // ─────────────────────────────────────────────────────────

  /// Lists all .llog files (active + archived) sorted by name ascending.
  Future<List<String>> listAllFiles() async {
    await _ensureInitialized();
    final dir   = _directory!;
    final files = <String>[];

    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = p.basename(entity.path);
        if (name.endsWith(BinarySchema.fileExtension) ||
            name.endsWith('${BinarySchema.fileExtension}.arch')) {
          files.add(entity.path);
        }
      }
    }
    files.sort();
    return files;
  }

  /// Lists only archived files, sorted oldest first.
  Future<List<String>> listArchivedFiles() async {
    final all = await listAllFiles();
    return all.where((f) => f.endsWith('.arch')).toList();
  }

  // ─────────────────────────────────────────────────────────
  //  Size queries
  // ─────────────────────────────────────────────────────────

  /// Returns the combined size in bytes of all log files.
  Future<int> totalDiskUsage() async {
    final files = await listAllFiles();
    int total = 0;
    for (final path in files) {
      try {
        total += await File(path).length();
      } catch (_) {
        // File disappeared between listing and stat — ignore
      }
    }
    return total;
  }

  /// Returns the size of a single file in bytes, or 0 if not found.
  Future<int> fileSize(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Archive / delete
  // ─────────────────────────────────────────────────────────

  /// Renames [filePath] to mark it as archived (appends `.arch`).
  Future<String> archiveFile(String filePath) async {
    final archivedPath = '$filePath.arch';
    await File(filePath).rename(archivedPath);
    return archivedPath;
  }

  /// Deletes [filePath] from disk.
  Future<void> deleteFile(String filePath) async {
    try {
      await File(filePath).delete();
    } catch (_) {
      // Already gone — ignore
    }
  }

  /// Deletes the oldest archived file and returns its path, or `null` if
  /// no archived files exist.
  Future<String?> deleteOldestArchive() async {
    final archived = await listArchivedFiles();
    if (archived.isEmpty) return null;
    final oldest = archived.first; // already sorted oldest-first
    await deleteFile(oldest);
    return oldest;
  }

  // ─────────────────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────────────────

  String _today() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  String _buildFileName({
    required String date,
    required int    sequence,
    required bool   archived,
  }) {
    final seq  = sequence.toString().padLeft(3, '0');
    final base = 'app_${date}_$seq${BinarySchema.fileExtension}';
    return archived ? '$base.arch' : base;
  }

  Future<int> _nextSequenceNumber() async {
    final files  = await listAllFiles();
    final today  = _today();
    int   highest = 0;

    for (final path in files) {
      final name = p.basename(path);
      // Pattern: app_YYYY-MM-DD_NNN.llog
      if (name.contains(today)) {
        final parts = name.split('_');
        if (parts.length >= 3) {
          final seqStr = parts[2].split('.').first;
          final seq    = int.tryParse(seqStr) ?? 0;
          if (seq > highest) highest = seq;
        }
      }
    }
    return highest + 1;
  }

  Future<void> _ensureInitialized() async {
    if (_directory == null) await initialize();
  }
}

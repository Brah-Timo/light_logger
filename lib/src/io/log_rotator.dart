// lib/src/io/log_rotator.dart
//
// Controls when the active log file is "rotated" — closed, archived, and
// replaced with a fresh file — and enforces the archive count / total-size
// limits defined in LogConfig.
//
// Rotation triggers (evaluated after every block write):
//   1. Active file size >= LogConfig.maxFileSizeBytes
//   2. (Optional) Daily boundary crossed  — RotationPolicy.daily / sizeAndDaily
//
// Post-rotation cleanup:
//   After creating the new active file, the rotator:
//   a. Enforces LogConfig.maxArchivedFiles (deletes oldest archives first).
//   b. Enforces LogConfig.maxTotalDiskBytes (deletes archives until limit met).

import 'dart:io';
import '../core/log_config.dart';
import 'log_file_manager.dart';

/// Decides when and how to rotate log files.
final class LogRotator {
  // ─────────────────────────────────────────────────────────
  //  Dependencies
  // ─────────────────────────────────────────────────────────

  final LogConfig      _config;
  final LogFileManager _fileManager;

  // ─────────────────────────────────────────────────────────
  //  State
  // ─────────────────────────────────────────────────────────

  String? _activeFilePath;
  int     _lastRotationDay = -1;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  LogRotator({
    required LogConfig config,
    required LogFileManager fileManager,
  })  : _config      = config,
        _fileManager = fileManager;

  // ─────────────────────────────────────────────────────────
  //  Initialise
  // ─────────────────────────────────────────────────────────

  Future<void> initialize() async {
    await _fileManager.initialize();
    _activeFilePath = await _fileManager.getActiveFilePath();
    _lastRotationDay = DateTime.now().day;
  }

  // ─────────────────────────────────────────────────────────
  //  Active file access
  // ─────────────────────────────────────────────────────────

  /// Returns the [File] object for the current active log file.
  Future<File> getActiveFile() async {
    _activeFilePath ??= await _fileManager.getActiveFilePath();
    return File(_activeFilePath!);
  }

  /// Path of the current active log file.
  String? get activeFilePath => _activeFilePath;

  // ─────────────────────────────────────────────────────────
  //  Rotation decision
  // ─────────────────────────────────────────────────────────

  /// Returns `true` if the active file should be rotated now.
  ///
  /// Checks:
  ///   - File size >= [LogConfig.maxFileSizeBytes]
  ///   - Daily boundary (if [RotationPolicy.daily] or [sizeAndDaily])
  Future<bool> shouldRotate() async {
    if (_activeFilePath == null) return false;

    // Size-based check
    if (_config.rotationPolicy == RotationPolicy.sizeOnly ||
        _config.rotationPolicy == RotationPolicy.sizeAndDaily) {
      final size = await _fileManager.fileSize(_activeFilePath!);
      if (size >= _config.maxFileSizeBytes) return true;
    }

    // Daily check
    if (_config.rotationPolicy == RotationPolicy.daily ||
        _config.rotationPolicy == RotationPolicy.sizeAndDaily) {
      final today = DateTime.now().day;
      if (today != _lastRotationDay) return true;
    }

    return false;
  }

  // ─────────────────────────────────────────────────────────
  //  Rotation execution
  // ─────────────────────────────────────────────────────────

  /// Archives the current active file and opens a new one.
  ///
  /// Does nothing if [_activeFilePath] is null.
  Future<void> rotate() async {
    if (_activeFilePath == null) return;

    // Archive the current file
    await _fileManager.archiveFile(_activeFilePath!);

    // Open a fresh active file
    _activeFilePath  = await _fileManager.getActiveFilePath();
    _lastRotationDay = DateTime.now().day;

    // Enforce archive limits
    await _enforceArchiveLimits();
  }

  /// Forces rotation without checking thresholds.  Used by [AsyncWriter]
  /// when the file size is about to be exceeded mid-block.
  Future<String> rotateActiveFile() async {
    await rotate();
    return _activeFilePath!;
  }

  /// Deletes the oldest archived file to free space.
  ///
  /// Returns the path of the deleted file, or `null` if nothing was deleted.
  Future<String?> deleteOldestArchive() async {
    return _fileManager.deleteOldestArchive();
  }

  // ─────────────────────────────────────────────────────────
  //  Limit enforcement
  // ─────────────────────────────────────────────────────────

  Future<void> _enforceArchiveLimits() async {
    await _enforceArchiveCount();
    await _enforceTotalDiskBytes();
  }

  Future<void> _enforceArchiveCount() async {
    final archived = await _fileManager.listArchivedFiles();
    if (archived.length <= _config.maxArchivedFiles) return;

    // Delete oldest archives first
    final excess = archived.length - _config.maxArchivedFiles;
    for (int i = 0; i < excess; i++) {
      await _fileManager.deleteFile(archived[i]);
    }
  }

  Future<void> _enforceTotalDiskBytes() async {
    while (true) {
      final total = await _fileManager.totalDiskUsage();
      if (total <= _config.maxTotalDiskBytes) break;

      final deleted = await _fileManager.deleteOldestArchive();
      if (deleted == null) break; // nothing left to delete
    }
  }
}

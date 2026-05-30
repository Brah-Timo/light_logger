// lib/src/monitor/disk_monitor.dart
//
// Proactive disk-space guardian.
//
// Root cause of "logger kills the app":
//   Most loggers write unconditionally until the disk is full.
//   When the OS runs out of disk space the file-system returns ENOSPC,
//   every subsequent write throws, the app's database / state files can
//   no longer be saved, and the process crashes.
//
// light_logger's approach:
//   Before writing each block, DiskMonitor answers one question:
//     "Is there enough free space AND log-quota to accept this block?"
//   If not, AsyncWriter attempts to delete the oldest archive first.
//   Only if that still isn't enough does it drop the block silently —
//   the APPLICATION is never crashed or even interrupted.
//
//   Three protection layers:
//     Layer 1 — Log quota:    usedByLogs + newBlockSize <= maxTotalDiskBytes
//     Layer 2 — Free space:   freeDiskBytes - newBlockSize >= systemReserved
//     Layer 3 — Warning hook: usageRatio >= diskWarningThreshold → callback
//
// Caching:
//   Free disk space is expensive to query (requires a syscall or subprocess).
//   Results are cached for 10 seconds to avoid hammering the OS at high
//   write frequencies.

import 'dart:io';
import '../core/log_config.dart';

/// Monitors available disk space and log-directory quota.
final class DiskMonitor {
  // ─────────────────────────────────────────────────────────
  //  Dependencies
  // ─────────────────────────────────────────────────────────

  final LogConfig _config;

  // ─────────────────────────────────────────────────────────
  //  Cache
  // ─────────────────────────────────────────────────────────

  int _cachedFreeBytes       = -1;
  int _cacheExpiresAtMs      = 0;
  static const int _cacheTtlMs = 10000; // 10 seconds

  // ─────────────────────────────────────────────────────────
  //  State
  // ─────────────────────────────────────────────────────────

  bool _warningFired = false;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  DiskMonitor(this._config);

  // ─────────────────────────────────────────────────────────
  //  Primary gate
  // ─────────────────────────────────────────────────────────

  /// Returns `true` iff it is safe to write [bytesToWrite] more bytes.
  ///
  /// Internally fires [LogConfig.onDiskWarning] when usage crosses
  /// [LogConfig.diskWarningThreshold].
  Future<bool> checkBeforeWrite(int bytesToWrite) async {
    final logUsed  = await getTotalLogDirectorySize();
    final freeBytes = await getFreeDiskBytes();

    // ── Layer 1: Log quota ─────────────────────────────────
    if (logUsed + bytesToWrite > _config.maxTotalDiskBytes) {
      return false;
    }

    // ── Layer 2: OS free space ─────────────────────────────
    if (freeBytes - bytesToWrite < _config.systemReservedDiskBytes) {
      return false;
    }

    // ── Layer 3: Warning threshold ─────────────────────────
    final ratio = logUsed / _config.maxTotalDiskBytes;
    if (ratio >= _config.diskWarningThreshold && !_warningFired) {
      _warningFired = true;
      _config.onDiskWarning?.call(
        DiskWarning(
          usedBytes:   logUsed,
          totalBytes:  _config.maxTotalDiskBytes,
          usageRatio:  ratio,
          threshold:   _config.diskWarningThreshold,
        ),
      );
    } else if (ratio < _config.diskWarningThreshold * 0.9) {
      // Reset so warning fires again if usage climbs back up
      _warningFired = false;
    }

    return true;
  }

  // ─────────────────────────────────────────────────────────
  //  Disk queries
  // ─────────────────────────────────────────────────────────

  /// Total bytes consumed by all files in the log directory.
  Future<int> getTotalLogDirectorySize() async {
    final dir = Directory(_config.logDirectory);
    if (!await dir.exists()) return 0;

    int total = 0;
    try {
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          total += await entity.length().then((v) => v, onError: (_) => 0);
        }
      }
    } catch (_) {}
    return total;
  }

  /// Available free bytes on the disk that hosts the log directory.
  ///
  /// Results are cached for [_cacheTtlMs] milliseconds to avoid
  /// expensive syscalls on every block write.
  Future<int> getFreeDiskBytes() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_cachedFreeBytes >= 0 && now < _cacheExpiresAtMs) {
      return _cachedFreeBytes;
    }

    int free = 0;
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        free = await _freeBytesUnix();
      } else if (Platform.isWindows) {
        free = await _freeBytesWindows();
      } else if (Platform.isAndroid || Platform.isIOS) {
        free = await _freeBytesUnix();       // df works on Android/iOS
      } else {
        free = 512 * 1024 * 1024; // conservative 512 MiB fallback
      }
    } catch (_) {
      free = 256 * 1024 * 1024; // on error assume 256 MiB
    }

    _cachedFreeBytes  = free;
    _cacheExpiresAtMs = now + _cacheTtlMs;
    return free;
  }

  /// Current usage ratio of the log directory quota (0.0 – 1.0+).
  Future<double> getLogDirectoryUsageRatio() async {
    final used = await getTotalLogDirectorySize();
    return used / _config.maxTotalDiskBytes;
  }

  /// Invalidates the free-space cache, forcing a fresh query next time.
  void invalidateCache() {
    _cacheExpiresAtMs = 0;
  }

  // ─────────────────────────────────────────────────────────
  //  Platform-specific free-space queries
  // ─────────────────────────────────────────────────────────

  Future<int> _freeBytesUnix() async {
    final result = await Process.run(
      'df',
      ['-B1', '--output=avail', _config.logDirectory],
    );
    if (result.exitCode != 0) return 0;
    final lines = (result.stdout as String).trim().split('\n');
    if (lines.length < 2) return 0;
    return int.tryParse(lines.last.trim()) ?? 0;
  }

  Future<int> _freeBytesWindows() async {
    final driveLetter = _config.logDirectory.isNotEmpty
        ? _config.logDirectory[0].toUpperCase()
        : 'C';
    // Use PowerShell with a hard timeout to prevent hanging tests.
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(Get-PSDrive ${driveLetter}).Free',
      ]);
      if (result.exitCode == 0) {
        return int.tryParse((result.stdout as String).trim()) ?? 0;
      }
    } catch (_) {}
    return 512 * 1024 * 1024; // 512 MiB safe fallback
  }

  // ─────────────────────────────────────────────────────────
  //  Snapshot
  // ─────────────────────────────────────────────────────────

  /// Returns a human-readable snapshot of current disk usage.
  Future<DiskSnapshot> snapshot() async {
    final used  = await getTotalLogDirectorySize();
    final free  = await getFreeDiskBytes();
    final ratio = used / _config.maxTotalDiskBytes;
    return DiskSnapshot(
      logUsedBytes:  used,
      logMaxBytes:   _config.maxTotalDiskBytes,
      freeDiskBytes: free,
      usageRatio:    ratio,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Value types
// ─────────────────────────────────────────────────────────────────────────────

/// Point-in-time snapshot of disk-related metrics.
class DiskSnapshot {
  final int    logUsedBytes;
  final int    logMaxBytes;
  final int    freeDiskBytes;
  final double usageRatio;

  const DiskSnapshot({
    required this.logUsedBytes,
    required this.logMaxBytes,
    required this.freeDiskBytes,
    required this.usageRatio,
  });

  String _fmt(int bytes) {
    if (bytes < 1024)                return '${bytes}B';
    if (bytes < 1024 * 1024)         return '${(bytes/1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024)  return '${(bytes/1024/1024).toStringAsFixed(1)}MB';
    return '${(bytes/1024/1024/1024).toStringAsFixed(2)}GB';
  }

  @override
  String toString() =>
      'DiskSnapshot('
      'logUsed: ${_fmt(logUsedBytes)}/${_fmt(logMaxBytes)} '
      '(${(usageRatio * 100).toStringAsFixed(1)} %), '
      'freeOnDisk: ${_fmt(freeDiskBytes)}'
      ')';
}

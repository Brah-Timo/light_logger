// lib/src/core/light_logger_base.dart
//
// The single public class that application code interacts with.
//
// Design principles:
//
//   1. ZERO blocking on write path:
//      info() / error() / … call buffer.add() which returns immediately.
//      All I/O happens on a background stream listener.
//
//   2. NEVER crashes the app:
//      Every error in the write path is caught and written to stderr.
//      The logger keeps running (or silently drops entries) regardless.
//
//   3. Single entry point:
//      LightLogger.initialize() wires up every component;
//      the caller needs no knowledge of internals.
//
//   4. Singleton-friendly:
//      LightLogger can be stored in a top-level variable, a provider, or
//      a service locator — whatever fits the app's architecture.

import 'dart:io';
import '../io/log_buffer.dart';
import '../io/async_writer.dart';
import '../io/log_file_manager.dart';
import '../io/log_rotator.dart';
import '../compression/log_compressor.dart';
import '../monitor/disk_monitor.dart';
import '../monitor/performance_tracker.dart';
import '../monitor/health_checker.dart';
import '../utils/string_pool.dart';
import 'log_config.dart';
import 'log_entry.dart';
import 'log_level.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  LoggerStats
// ─────────────────────────────────────────────────────────────────────────────

/// Aggregated real-time statistics for a running [LightLogger] instance.
class LoggerStats {
  /// Total log entries written since initialisation.
  final int    totalEntriesWritten;

  /// Total log entries dropped (disk full or disposed state).
  final int    totalEntriesDropped;

  /// Approximate writes per second over the last 1 second.
  final double writesPerSecond;

  /// Highest write rate observed since start (writes/s).
  final int    peakWritesPerSecond;

  /// Bytes currently used by all log files combined.
  final int    diskBytesUsed;

  /// Uptime in seconds since [LightLogger.initialize] completed.
  final double uptimeSeconds;

  /// Per-level breakdown of writes.
  final Map<LogLevel, int> levelCounts;

  /// Cumulative compression ratio (0.0 = no compression, 1.0 = 100 %).
  final double compressionRatio;

  const LoggerStats({
    required this.totalEntriesWritten,
    required this.totalEntriesDropped,
    required this.writesPerSecond,
    required this.peakWritesPerSecond,
    required this.diskBytesUsed,
    required this.uptimeSeconds,
    required this.levelCounts,
    required this.compressionRatio,
  });

  String get diskUsedFormatted {
    if (diskBytesUsed < 1024)               return '${diskBytesUsed}B';
    if (diskBytesUsed < 1024 * 1024)        return '${(diskBytesUsed/1024).toStringAsFixed(1)}KB';
    if (diskBytesUsed < 1024*1024*1024)     return '${(diskBytesUsed/1024/1024).toStringAsFixed(1)}MB';
    return '${(diskBytesUsed/1024/1024/1024).toStringAsFixed(2)}GB';
  }

  @override
  String toString() =>
      'LoggerStats('
      'total: $totalEntriesWritten, '
      'rate: ${writesPerSecond.toStringAsFixed(0)}/s, '
      'disk: $diskUsedFormatted, '
      'compression: ${(compressionRatio * 100).toStringAsFixed(1)}%'
      ')';
}

// ─────────────────────────────────────────────────────────────────────────────
//  LightLogger
// ─────────────────────────────────────────────────────────────────────────────

/// High-performance binary logger for Dart & Flutter.
///
/// ## Quick start
/// ```dart
/// final logger = await LightLogger.initialize(
///   config: LogConfig(logDirectory: '/data/app/logs'),
/// );
///
/// logger.info('Server started on port 8080', tag: 'Main');
/// logger.error('DB query failed', tag: 'Database', extra: {'query': sql});
///
/// // On shutdown:
/// await logger.dispose();
/// ```
///
/// ## Thread safety
/// [LightLogger] is designed for use from a single Dart isolate.
/// To log from multiple isolates, create one instance per isolate and
/// direct them all to the same log directory — file names include sequence
/// numbers to avoid collisions.
final class LightLogger {
  // ─────────────────────────────────────────────────────────
  //  Internal components
  // ─────────────────────────────────────────────────────────

  final LogConfig          _config;
  final LogBuffer          _buffer;
  final AsyncWriter        _writer;
  final DiskMonitor        _diskMonitor;
  final PerformanceTracker _perfTracker;
  final LogCompressor      _compressor;
  final HealthChecker      _healthChecker;

  bool _disposed = false;

  // ─────────────────────────────────────────────────────────
  //  Private constructor
  // ─────────────────────────────────────────────────────────

  LightLogger._({
    required LogConfig          config,
    required LogBuffer          buffer,
    required AsyncWriter        writer,
    required DiskMonitor        diskMonitor,
    required PerformanceTracker perfTracker,
    required LogCompressor      compressor,
    required HealthChecker      healthChecker,
  })  : _config        = config,
        _buffer        = buffer,
        _writer        = writer,
        _diskMonitor   = diskMonitor,
        _perfTracker   = perfTracker,
        _compressor    = compressor,
        _healthChecker = healthChecker;

  // ─────────────────────────────────────────────────────────
  //  Factory / initialisation
  // ─────────────────────────────────────────────────────────

  /// Creates and fully initialises a [LightLogger] instance.
  ///
  /// This is an **async** method because it:
  /// - Creates the log directory if it doesn't exist.
  /// - Determines the active log file name.
  /// - Opens the active file for appending.
  ///
  /// Throws [ArgumentError] if [config] contains invalid values.
  static Future<LightLogger> initialize({required LogConfig config}) async {
    final pool         = StringPool();
    final compressor   = LogCompressor(config.compressionStrategy);
    final diskMonitor  = DiskMonitor(config);
    final perfTracker  = PerformanceTracker();
    final fileManager  = LogFileManager(config);
    final rotator      = LogRotator(config: config, fileManager: fileManager);

    final buffer = LogBuffer(config: config, stringPool: pool);
    final writer = AsyncWriter(
      config:       config,
      compressor:   compressor,
      rotator:      rotator,
      diskMonitor:  diskMonitor,
    );

    final healthChecker = HealthChecker(
      config:       config,
      diskMonitor:  diskMonitor,
      perfTracker:  perfTracker,
    );

    await writer.start(buffer.blockStream);

    final instance = LightLogger._(
      config:         config,
      buffer:         buffer,
      writer:         writer,
      diskMonitor:    diskMonitor,
      perfTracker:    perfTracker,
      compressor:     compressor,
      healthChecker:  healthChecker,
    );

    return instance;
  }

  // ─────────────────────────────────────────────────────────
  //  Write API — convenience methods
  // ─────────────────────────────────────────────────────────

  /// Logs a [LogLevel.verbose] entry.
  void verbose(String message, {String? tag, Map<String, dynamic>? extra, String? traceId}) =>
      _log(LogLevel.verbose, message, tag: tag, extra: extra, traceId: traceId);

  /// Logs a [LogLevel.debug] entry.
  void debug(String message, {String? tag, Map<String, dynamic>? extra, String? traceId}) =>
      _log(LogLevel.debug, message, tag: tag, extra: extra, traceId: traceId);

  /// Logs a [LogLevel.info] entry.
  void info(String message, {String? tag, Map<String, dynamic>? extra, String? traceId}) =>
      _log(LogLevel.info, message, tag: tag, extra: extra, traceId: traceId);

  /// Logs a [LogLevel.warning] entry.
  void warning(String message, {String? tag, Map<String, dynamic>? extra, String? traceId}) =>
      _log(LogLevel.warning, message, tag: tag, extra: extra, traceId: traceId);

  /// Logs a [LogLevel.error] entry with optional exception details.
  void error(
    String message, {
    String?              tag,
    Map<String, dynamic>? extra,
    String?              traceId,
    Object?              exception,
    StackTrace?          stackTrace,
  }) {
    final enriched = <String, dynamic>{
      ...?extra,
      if (exception  != null) 'exception':  exception.toString(),
      if (stackTrace != null) 'stackTrace': stackTrace.toString(),
    };
    _log(LogLevel.error, message,
        tag: tag, extra: enriched.isEmpty ? null : enriched, traceId: traceId);
  }

  /// Logs a [LogLevel.fatal] entry.
  void fatal(String message, {String? tag, Map<String, dynamic>? extra, String? traceId}) =>
      _log(LogLevel.fatal, message, tag: tag, extra: extra, traceId: traceId);

  // ─────────────────────────────────────────────────────────
  //  Generic write
  // ─────────────────────────────────────────────────────────

  /// Writes an entry with an arbitrary [level].
  void log(
    LogLevel level,
    String   message, {
    String?              tag,
    Map<String, dynamic>? extra,
    String?              traceId,
  }) => _log(level, message, tag: tag, extra: extra, traceId: traceId);

  void _log(
    LogLevel level,
    String   message, {
    String?              tag,
    Map<String, dynamic>? extra,
    String?              traceId,
  }) {
    if (_disposed) return;
    if (!level.isAtLeast(_config.minimumLevel)) return;

    _perfTracker.recordWrite(level);

    final entry = LogEntry.now(
      level:   level,
      message: message,
      tag:     tag,
      extra:   extra,
      traceId: traceId,
    );

    _buffer.add(entry);

    if (_config.enableConsoleOutput) {
      stderr.writeln(
        '${entry.timestamp.toIso8601String()} '
        '${level.paddedLabel} '
        '${tag != null ? "[$tag] " : ""}'
        '$message',
      );
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Flush
  // ─────────────────────────────────────────────────────────

  /// Forces an immediate flush of all buffered entries to disk.
  ///
  /// Useful before taking a heap snapshot, before app backgrounding,
  /// or before calling [dispose].
  void flush() => _buffer.forceFlush();

  // ─────────────────────────────────────────────────────────
  //  Stats & health
  // ─────────────────────────────────────────────────────────

  /// Returns a snapshot of real-time logger statistics.
  Future<LoggerStats> getStats() async {
    final diskUsed = await _diskMonitor.getTotalLogDirectorySize();
    final perfSnap = _perfTracker.snapshot();
    return LoggerStats(
      totalEntriesWritten: perfSnap.totalWrites,
      totalEntriesDropped: perfSnap.totalDropped,
      writesPerSecond:     perfSnap.writesPerSecond,
      peakWritesPerSecond: perfSnap.peakWritesPerSecond,
      diskBytesUsed:       diskUsed,
      uptimeSeconds:       perfSnap.uptimeSeconds,
      levelCounts:         perfSnap.levelCounts,
      compressionRatio:    _compressor.compressionRatio,
    );
  }

  /// Performs a full health check and returns a [HealthReport].
  Future<HealthReport> checkHealth() => _healthChecker.check();

  // ─────────────────────────────────────────────────────────
  //  Configuration access
  // ─────────────────────────────────────────────────────────

  /// The [LogConfig] this instance was initialised with.
  LogConfig get config => _config;

  // ─────────────────────────────────────────────────────────
  //  Dispose
  // ─────────────────────────────────────────────────────────

  /// Flushes all remaining buffered entries and closes the active log file.
  ///
  /// After [dispose] any further writes are silently discarded.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    flush();
    await _buffer.dispose();
    await _writer.dispose();
  }
}

// lib/src/core/log_config.dart
//
// Single configuration object passed to LightLogger.initialize().
// Every tunable behaviour of the package lives here.

import 'package:meta/meta.dart';
import 'log_level.dart';
import '../compression/compression_strategy.dart';
import '../compression/lz4_strategy.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  DiskWarning
// ─────────────────────────────────────────────────────────────────────────────

/// Payload delivered to [LogConfig.onDiskWarning] when the log directory
/// consumption crosses [LogConfig.diskWarningThreshold].
@immutable
class DiskWarning {
  /// Bytes currently consumed by all log files combined.
  final int usedBytes;

  /// Maximum bytes allowed, as configured by [LogConfig.maxTotalDiskBytes].
  final int totalBytes;

  /// [usedBytes] / [totalBytes] — value between 0.0 and 1.0.
  final double usageRatio;

  /// The threshold that triggered this warning.
  final double threshold;

  const DiskWarning({
    required this.usedBytes,
    required this.totalBytes,
    required this.usageRatio,
    required this.threshold,
  });

  /// Percentage string, e.g. `"87.3 %"`.
  String get usagePercent => '${(usageRatio * 100).toStringAsFixed(1)} %';

  @override
  String toString() =>
      'DiskWarning(used: $usedBytes, total: $totalBytes, '
      'ratio: $usagePercent)';
}

// ─────────────────────────────────────────────────────────────────────────────
//  CompressionLevel
// ─────────────────────────────────────────────────────────────────────────────

/// Trade-off between compression speed and ratio.
///
/// Passed to the active [CompressionStrategy] so each implementation can
/// map the enum to its own internal level integers.
enum CompressionLevel {
  /// Prioritise raw write speed — slightly worse compression ratio.
  fast,

  /// Balanced speed / ratio (recommended for most cases).
  balanced,

  /// Maximum compression ratio — slower, higher CPU cost.
  best,
}

// ─────────────────────────────────────────────────────────────────────────────
//  RotationPolicy
// ─────────────────────────────────────────────────────────────────────────────

/// Determines when the active log file is rotated (closed and archived).
enum RotationPolicy {
  /// Rotate when the file reaches [LogConfig.maxFileSizeBytes].
  sizeOnly,

  /// Rotate at midnight local time regardless of size.
  daily,

  /// Both size and daily triggers apply (whichever fires first).
  sizeAndDaily,
}

// ─────────────────────────────────────────────────────────────────────────────
//  LogConfig
// ─────────────────────────────────────────────────────────────────────────────

/// Complete configuration for a [LightLogger] instance.
///
/// Pass an instance to [LightLogger.initialize]:
/// ```dart
/// final logger = await LightLogger.initialize(
///   config: LogConfig(
///     logDirectory: '/data/app/logs',
///     minimumLevel: LogLevel.warning,
///   ),
/// );
/// ```
///
/// Or use one of the ready-made factories:
/// ```dart
/// LogConfig.development(logDirectory: '/tmp/dev-logs')
/// LogConfig.production(logDirectory: '/data/prod-logs')
/// ```
@immutable
final class LogConfig {
  // ── Storage ──────────────────────────────────────────────────────────────

  /// Absolute path to the directory where `.llog` files will be written.
  ///
  /// The directory is created automatically if it does not exist.
  final String logDirectory;

  /// Maximum size (bytes) a single active log file may reach before rotation.
  ///
  /// Default: **50 MiB**.
  final int maxFileSizeBytes;

  /// Maximum number of archived (rotated) log files to retain.
  ///
  /// The oldest archive is deleted when this limit is exceeded.
  /// Default: **10**.
  final int maxArchivedFiles;

  /// Hard ceiling (bytes) for the combined size of ALL log files.
  ///
  /// When adding a new block would breach this limit, the oldest archive is
  /// removed first.  Writing is suspended if no space can be reclaimed.
  /// Default: **500 MiB**.
  final int maxTotalDiskBytes;

  /// Controls when the active file is rotated.
  final RotationPolicy rotationPolicy;

  // ── Filtering ─────────────────────────────────────────────────────────────

  /// Entries below this level are silently discarded **before** reaching the
  /// buffer — zero CPU cost for filtered-out entries.
  ///
  /// Default: [LogLevel.info].
  final LogLevel minimumLevel;

  // ── Buffering ─────────────────────────────────────────────────────────────

  /// Soft maximum size (bytes) of the in-memory write buffer.
  ///
  /// When the buffer reaches this size a flush is triggered immediately,
  /// regardless of [flushInterval].  Default: **1 MiB**.
  final int bufferSizeBytes;

  /// Maximum time between automatic buffer flushes.
  ///
  /// Guarantees that entries are persisted even during low-activity periods.
  /// Default: **5 seconds**.
  final Duration flushInterval;

  // ── Compression ───────────────────────────────────────────────────────────

  /// The algorithm used to compress binary blocks before writing.
  ///
  /// Default: [LZ4Strategy] (fast, ~75 % ratio).
  final CompressionStrategy compressionStrategy;

  /// Trade-off hint passed to [compressionStrategy].
  final CompressionLevel compressionLevel;

  // ── Developer conveniences ────────────────────────────────────────────────

  /// When `true`, entries are also printed to [stderr] in a human-readable
  /// format.  Useful in development; disable in production.
  ///
  /// Default: `false`.
  final bool enableConsoleOutput;

  /// When `true`, the encoder captures the calling stack frame and stores
  /// the source file name + line number on every entry.
  ///
  /// Adds a small overhead (~5 µs per entry) due to stack introspection.
  /// Default: `false`.
  final bool includeSourceInfo;

  // ── Disk protection ───────────────────────────────────────────────────────

  /// Fraction of [maxTotalDiskBytes] at which [onDiskWarning] is called.
  ///
  /// For example `0.85` means "warn at 85 % capacity".
  /// Default: `0.85`.
  final double diskWarningThreshold;

  /// Callback invoked when disk usage crosses [diskWarningThreshold].
  ///
  /// The application can react (e.g. upload and purge old logs) without the
  /// logger stopping it.  The logger **never** throws or crashes the app.
  final void Function(DiskWarning warning)? onDiskWarning;

  /// Minimum free-disk-space (bytes) the logger tries to preserve for the
  /// rest of the OS / application.  Default: **100 MiB**.
  final int systemReservedDiskBytes;

  // ── Encryption ────────────────────────────────────────────────────────────

  /// When `true`, each compressed block is encrypted with AES-256-GCM before
  /// being written to disk.
  ///
  /// Requires [encryptionKey] to be provided.
  /// Default: `false`.
  final bool enableEncryption;

  /// 32-byte AES-256 key.  **Required** when [enableEncryption] is `true`.
  final List<int>? encryptionKey;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  const LogConfig({
    required this.logDirectory,
    this.minimumLevel         = LogLevel.info,
    this.maxFileSizeBytes     = 50 * 1024 * 1024,       // 50 MiB
    this.maxArchivedFiles     = 10,
    this.maxTotalDiskBytes    = 500 * 1024 * 1024,      // 500 MiB
    this.rotationPolicy       = RotationPolicy.sizeOnly,
    this.bufferSizeBytes      = 1024 * 1024,            // 1 MiB
    this.flushInterval        = const Duration(seconds: 5),
    this.compressionStrategy  = const LZ4Strategy(),
    this.compressionLevel     = CompressionLevel.balanced,
    this.enableConsoleOutput  = false,
    this.includeSourceInfo    = false,
    this.diskWarningThreshold = 0.85,
    this.onDiskWarning,
    this.systemReservedDiskBytes = 100 * 1024 * 1024,   // 100 MiB
    this.enableEncryption     = false,
    this.encryptionKey,
  })  : assert(
          !enableEncryption || encryptionKey != null,
          'encryptionKey must be provided when enableEncryption is true',
        ),
        assert(
          encryptionKey == null || encryptionKey.length == 32,
          'encryptionKey must be exactly 32 bytes (AES-256)',
        ),
        assert(
          diskWarningThreshold > 0.0 && diskWarningThreshold < 1.0,
          'diskWarningThreshold must be in range (0.0, 1.0)',
        );

  // ─────────────────────────────────────────────────────────
  //  Preset factories
  // ─────────────────────────────────────────────────────────

  /// Ready-to-use configuration for local development.
  ///
  /// - Captures VERBOSE and above.
  /// - Prints to console.
  /// - Includes source file + line info.
  /// - Small files, fast flush.
  factory LogConfig.development({required String logDirectory}) {
    return LogConfig(
      logDirectory:       logDirectory,
      minimumLevel:       LogLevel.verbose,
      enableConsoleOutput: true,
      includeSourceInfo:  true,
      maxFileSizeBytes:   10 * 1024 * 1024,   // 10 MiB
      maxArchivedFiles:   3,
      maxTotalDiskBytes:  100 * 1024 * 1024,  // 100 MiB
      flushInterval:      const Duration(seconds: 1),
      compressionLevel:   CompressionLevel.fast,
    );
  }

  /// Ready-to-use configuration for production deployments.
  ///
  /// - Captures WARNING and above only.
  /// - No console output.
  /// - Large files, conservative flush.
  /// - Disk warning at 80 %.
  factory LogConfig.production({required String logDirectory}) {
    return LogConfig(
      logDirectory:          logDirectory,
      minimumLevel:          LogLevel.warning,
      enableConsoleOutput:   false,
      includeSourceInfo:     false,
      maxFileSizeBytes:      100 * 1024 * 1024,   // 100 MiB
      maxArchivedFiles:      5,
      maxTotalDiskBytes:     1024 * 1024 * 1024,   // 1 GiB
      flushInterval:         const Duration(seconds: 10),
      diskWarningThreshold:  0.80,
      compressionLevel:      CompressionLevel.balanced,
    );
  }

  /// Configuration for high-frequency server-side logging (10 k+ writes/s).
  ///
  /// - Large buffer to minimise I/O syscalls.
  /// - Best compression ratio to offset the high write volume.
  /// - Rotation on both size and daily cadence.
  factory LogConfig.highFrequency({required String logDirectory}) {
    return LogConfig(
      logDirectory:          logDirectory,
      minimumLevel:          LogLevel.info,
      enableConsoleOutput:   false,
      maxFileSizeBytes:      200 * 1024 * 1024,   // 200 MiB
      maxArchivedFiles:      20,
      maxTotalDiskBytes:     4 * 1024 * 1024 * 1024, // 4 GiB
      bufferSizeBytes:       4 * 1024 * 1024,     // 4 MiB buffer
      flushInterval:         const Duration(seconds: 30),
      rotationPolicy:        RotationPolicy.sizeAndDaily,
      compressionLevel:      CompressionLevel.best,
      diskWarningThreshold:  0.75,
    );
  }

  // ─────────────────────────────────────────────────────────
  //  copyWith
  // ─────────────────────────────────────────────────────────

  LogConfig copyWith({
    String? logDirectory,
    LogLevel? minimumLevel,
    int? maxFileSizeBytes,
    int? maxArchivedFiles,
    int? maxTotalDiskBytes,
    RotationPolicy? rotationPolicy,
    int? bufferSizeBytes,
    Duration? flushInterval,
    CompressionStrategy? compressionStrategy,
    CompressionLevel? compressionLevel,
    bool? enableConsoleOutput,
    bool? includeSourceInfo,
    double? diskWarningThreshold,
    void Function(DiskWarning)? onDiskWarning,
    int? systemReservedDiskBytes,
    bool? enableEncryption,
    List<int>? encryptionKey,
  }) {
    return LogConfig(
      logDirectory:            logDirectory ?? this.logDirectory,
      minimumLevel:            minimumLevel ?? this.minimumLevel,
      maxFileSizeBytes:        maxFileSizeBytes ?? this.maxFileSizeBytes,
      maxArchivedFiles:        maxArchivedFiles ?? this.maxArchivedFiles,
      maxTotalDiskBytes:       maxTotalDiskBytes ?? this.maxTotalDiskBytes,
      rotationPolicy:          rotationPolicy ?? this.rotationPolicy,
      bufferSizeBytes:         bufferSizeBytes ?? this.bufferSizeBytes,
      flushInterval:           flushInterval ?? this.flushInterval,
      compressionStrategy:     compressionStrategy ?? this.compressionStrategy,
      compressionLevel:        compressionLevel ?? this.compressionLevel,
      enableConsoleOutput:     enableConsoleOutput ?? this.enableConsoleOutput,
      includeSourceInfo:       includeSourceInfo ?? this.includeSourceInfo,
      diskWarningThreshold:    diskWarningThreshold ?? this.diskWarningThreshold,
      onDiskWarning:           onDiskWarning ?? this.onDiskWarning,
      systemReservedDiskBytes: systemReservedDiskBytes ?? this.systemReservedDiskBytes,
      enableEncryption:        enableEncryption ?? this.enableEncryption,
      encryptionKey:           encryptionKey ?? this.encryptionKey,
    );
  }

  @override
  String toString() => 'LogConfig('
      'dir: $logDirectory, '
      'level: ${minimumLevel.label}, '
      'maxFile: ${maxFileSizeBytes ~/ 1024 ~/ 1024} MiB, '
      'compress: ${compressionStrategy.algorithmName}'
      ')';
}

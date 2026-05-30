/// light_logger — High-Performance Binary Logging for Dart & Flutter
///
/// ## Features
/// - Writes compressed binary logs (up to 98 % smaller than plain text)
/// - Auto-rotation with configurable size / daily triggers
/// - Disk-exhaustion protection — never crashes the app
/// - Built-in query engine: filter by level, time, tag, text, regex
/// - Export to JSON Lines, JSON Array, CSV, or plain text
/// - AES-256-GCM encryption (optional)
/// - CLI viewer (`dart run bin/log_viewer.dart`)
///
/// ## Quick start
/// ```dart
/// import 'package:light_logger/light_logger.dart';
///
/// final logger = await LightLogger.initialize(
///   config: LogConfig(logDirectory: '/data/app/logs'),
/// );
///
/// logger.info('App started', tag: 'Main');
/// logger.error('DB query failed', tag: 'Database',
///     extra: {'query': 'SELECT …', 'durationMs': 5000});
///
/// // Query:
/// final reader = LogReader();
/// final errors = await LogQuery(reader, '/data/app/logs')
///     .whereLevel(LogLevel.error)
///     .whereTime(from: DateTime.now().subtract(const Duration(hours: 1)))
///     .limit(50)
///     .toList();
///
/// // Export:
/// await LogExporter.toCsvFile(
///   source:     Stream.fromIterable(errors),
///   outputPath: '/tmp/recent_errors.csv',
/// );
///
/// // Shutdown:
/// await logger.dispose();
/// ```
library light_logger;

// ─────────────────────────────────────────────────────────────────────────────
//  Core
// ─────────────────────────────────────────────────────────────────────────────

export 'src/core/light_logger_base.dart'    show LightLogger, LoggerStats;
export 'src/core/log_level.dart'            show LogLevel;
export 'src/core/log_entry.dart'            show LogEntry;
export 'src/core/log_config.dart'
    show LogConfig, DiskWarning, CompressionLevel, RotationPolicy;

// ─────────────────────────────────────────────────────────────────────────────
//  Binary schema (advanced use)
// ─────────────────────────────────────────────────────────────────────────────

export 'src/binary/binary_schema.dart'      show BinarySchema;
export 'src/binary/binary_encoder.dart'     show BinaryEncoder;
export 'src/binary/binary_decoder.dart'
    show BinaryDecoder, FileHeaderInfo;

// ─────────────────────────────────────────────────────────────────────────────
//  Compression
// ─────────────────────────────────────────────────────────────────────────────

export 'src/compression/compression_strategy.dart'
    show CompressionStrategy, CompressionException;
export 'src/compression/lz4_strategy.dart'  show LZ4Strategy;
export 'src/compression/zstd_strategy.dart' show ZstdStrategy;
export 'src/compression/gzip_strategy.dart' show GzipStrategy;
export 'src/compression/log_compressor.dart'
    show LogCompressor, LogCorruptionException;

// ─────────────────────────────────────────────────────────────────────────────
//  Reader & query
// ─────────────────────────────────────────────────────────────────────────────

export 'src/reader/log_reader.dart'         show LogReader;
export 'src/reader/log_query.dart'          show LogQuery;
export 'src/reader/log_exporter.dart'       show LogExporter;

// ─────────────────────────────────────────────────────────────────────────────
//  Monitor
// ─────────────────────────────────────────────────────────────────────────────

export 'src/monitor/disk_monitor.dart'
    show DiskMonitor, DiskSnapshot;
export 'src/monitor/performance_tracker.dart'
    show PerformanceTracker, PerformanceSnapshot;
export 'src/monitor/health_checker.dart'
    show HealthChecker, HealthReport, HealthStatus;

// ─────────────────────────────────────────────────────────────────────────────
//  Utils (advanced use)
// ─────────────────────────────────────────────────────────────────────────────

export 'src/utils/string_pool.dart'         show StringPool;
export 'src/utils/crc_validator.dart'       show CrcValidator;
export 'src/utils/timestamp_encoder.dart'   show TimestampEncoder;

// ─────────────────────────────────────────────────────────────────────────────
//  IO (advanced use / testing)
// ─────────────────────────────────────────────────────────────────────────────

export 'src/io/log_file_manager.dart'       show LogFileManager;
export 'src/io/log_rotator.dart'            show LogRotator;

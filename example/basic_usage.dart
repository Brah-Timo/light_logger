// example/basic_usage.dart
//
// Demonstrates the most common light_logger patterns.
// Run with:  dart run example/basic_usage.dart

import 'dart:io';
import 'package:light_logger/light_logger.dart';

Future<void> main() async {
  // ── 1. Initialise ─────────────────────────────────────────
  final dir = Directory.systemTemp.path;

  final logger = await LightLogger.initialize(
    config: LogConfig(
      logDirectory:      '$dir/demo_logs',
      minimumLevel:      LogLevel.verbose,
      enableConsoleOutput: true,          // print to stderr in development
      includeSourceInfo: false,
      maxFileSizeBytes:  10 * 1024 * 1024, // 10 MiB
      maxArchivedFiles:  3,
      maxTotalDiskBytes: 100 * 1024 * 1024,
      diskWarningThreshold: 0.80,
      onDiskWarning: (w) {
        stderr.writeln('⚠️  Log disk at ${w.usagePercent} — consider archiving.');
      },
    ),
  );

  print('Logger initialised.  Writing entries…');

  // ── 2. Write ──────────────────────────────────────────────
  logger.verbose('Startup diagnostics', tag: 'Boot');
  logger.debug('Loading configuration from disk', tag: 'Config');
  logger.info('HTTP server listening on :8080', tag: 'Server');
  logger.warning('Cache hit rate below threshold: 42 %', tag: 'Cache',
      extra: {'hitRate': 0.42, 'threshold': 0.70});
  logger.error(
    'Database connection refused',
    tag: 'Database',
    exception: Exception('ECONNREFUSED localhost:5432'),
    extra: {'host': 'localhost', 'port': 5432, 'retry': 3},
    traceId: 'req-001',
  );
  logger.fatal('Out of memory — aborting worker process', tag: 'Worker');

  // Simulate a burst
  for (int i = 0; i < 500; i++) {
    logger.debug('Heartbeat #$i', tag: 'HealthCheck', extra: {'seq': i});
  }

  // ── 3. Stats ─────────────────────────────────────────────
  final stats = await logger.getStats();
  print('\n─── Logger stats ───');
  print(stats);

  // ── 4. Health check ──────────────────────────────────────
  final health = await logger.checkHealth();
  print('\n─── Health report ───');
  print(health.summary);

  // ── 5. Flush & dispose ───────────────────────────────────
  logger.flush();
  await logger.dispose();
  print('\nLogger disposed.  Log files in: $dir/demo_logs/');

  // ── 6. Read back ─────────────────────────────────────────
  print('\n─── Reading back ERROR entries ───');
  final reader = LogReader();
  final errors = await LogQuery(reader, '$dir/demo_logs')
      .whereLevel(LogLevel.error)
      .toList();

  for (final e in errors) {
    print(LogExporter.formatEntry(e, colorCodes: stdout.hasTerminal));
  }

  // ── 7. Export ─────────────────────────────────────────────
  final csvPath = '$dir/demo_logs_export.csv';
  final reader2 = LogReader();
  final count = await LogExporter.toCsvFile(
    source:     LogQuery(reader2, '$dir/demo_logs').whereLevel(LogLevel.warning).execute(),
    outputPath: csvPath,
  );
  print('\nExported $count WARNING+ entries to $csvPath');
}

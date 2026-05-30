// example/server_side_dart.dart
//
// Demonstrates light_logger in a Dart server application (Shelf / plain Dart).
// Shows high-frequency logging, trace IDs, and health monitoring.
//
// Run with:  dart run example/server_side_dart.dart

import 'dart:io';
import 'dart:math';
import 'package:light_logger/light_logger.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Setup
// ─────────────────────────────────────────────────────────────────────────────

late LightLogger logger;

Future<void> main() async {
  const logDir = '/tmp/server_logs';

  logger = await LightLogger.initialize(
    config: LogConfig.highFrequency(logDirectory: logDir).copyWith(
      minimumLevel:      LogLevel.debug,
      enableConsoleOutput: false,
      onDiskWarning: (w) {
        stderr.writeln('[DISK WARNING] ${w.usagePercent} — rotating old logs…');
      },
    ),
  );

  print('Server logger started — logs at $logDir');

  await _simulateServerLoad();

  // ── Health check before shutdown ─────────────────────────
  final health = await logger.checkHealth();
  print('\n${health}');

  final stats = await logger.getStats();
  print('\n$stats');
  print('Compression ratio: ${(stats.compressionRatio * 100).toStringAsFixed(1)} %');
  print('Bytes saved so far: ${_fmt(stats.diskBytesUsed)} on disk '
      '(original would be ~${_fmt((stats.diskBytesUsed / (1 - stats.compressionRatio)).round())})');

  logger.flush();
  await logger.dispose();
  print('\nShutdown complete.');
}

// ─────────────────────────────────────────────────────────────────────────────
//  Simulated server workload
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _simulateServerLoad() async {
  print('Simulating 10 000 log entries…');

  final rng     = Random();
  final methods = ['GET', 'POST', 'PUT', 'DELETE'];
  final paths   = ['/api/users', '/api/orders', '/api/products', '/health'];
  final tags    = ['HttpServer', 'Database', 'Cache', 'Auth', 'Queue'];
  final levels  = [
    LogLevel.debug, LogLevel.debug, LogLevel.debug, LogLevel.info,
    LogLevel.info,  LogLevel.warning, LogLevel.error,
  ];

  for (int i = 0; i < 10000; i++) {
    final method  = methods[rng.nextInt(methods.length)];
    final path    = paths[rng.nextInt(paths.length)];
    final tag     = tags[rng.nextInt(tags.length)];
    final level   = levels[rng.nextInt(levels.length)];
    final traceId = 'req-${i.toString().padLeft(6, '0')}';
    final latency = 10 + rng.nextInt(490);

    logger.log(
      level,
      '$method $path — ${latency}ms',
      tag: tag,
      traceId: traceId,
      extra: {
        'method':  method,
        'path':    path,
        'latency': latency,
        'status':  _httpStatus(latency),
      },
    );

    // Realistic pacing: ~5 000 writes/s
    if (i % 100 == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  print('Simulation complete.');
}

int _httpStatus(int latencyMs) {
  if (latencyMs > 450) return 503;
  if (latencyMs > 350) return 500;
  if (latencyMs > 200) return 429;
  return 200;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Read-back & analysis
// ─────────────────────────────────────────────────────────────────────────────

String _fmt(int bytes) {
  if (bytes < 1024)              return '${bytes}B';
  if (bytes < 1024 * 1024)       return '${(bytes/1024).toStringAsFixed(1)}KB';
  if (bytes < 1024*1024*1024)    return '${(bytes/1024/1024).toStringAsFixed(1)}MB';
  return '${(bytes/1024/1024/1024).toStringAsFixed(2)}GB';
}

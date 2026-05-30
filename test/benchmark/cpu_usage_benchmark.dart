// test/benchmark/cpu_usage_benchmark.dart
//
// Measures the CPU cost of a single logger.info() call vs. plain print().
// Run with:  dart run test/benchmark/cpu_usage_benchmark.dart

import 'dart:io';
import 'package:light_logger/light_logger.dart';

Future<void> main() async {
  print('\n╔══════════════════════════════════════════════════════════╗');
  print('║         light_logger  CPU Cost Benchmark                 ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  const rounds = 100000;
  final tempDir = await Directory.systemTemp.createTemp('ll_cpu_bench_');

  try {
    final logger = await LightLogger.initialize(
      config: LogConfig(
        logDirectory:    tempDir.path,
        minimumLevel:    LogLevel.info,
        bufferSizeBytes: 64 * 1024 * 1024, // very large buffer — no I/O during bench
        flushInterval:   const Duration(minutes: 10),
        enableConsoleOutput: false,
      ),
    );

    // ── Warm up ─────────────────────────────────────────────
    for (int i = 0; i < 1000; i++) {
      logger.info('warmup $i');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // ── light_logger benchmark ───────────────────────────────
    final swLogger = Stopwatch()..start();
    for (int i = 0; i < rounds; i++) {
      logger.info('CPU bench entry $i — testing call overhead', tag: 'Bench',
          extra: {'i': i});
    }
    final loggerUs = (swLogger.elapsedMicroseconds / rounds);
    print('light_logger.info()  : ${loggerUs.toStringAsFixed(2)} µs/call');
    print('  → ${(1000000 / loggerUs).toStringAsFixed(0)} calls/s theoretical max');

    // ── Plain stderr benchmark ────────────────────────────────
    final swPrint = Stopwatch()..start();
    for (int i = 0; i < rounds; i++) {
      // Just string formatting, no I/O
      final _ = '[${DateTime.now().toIso8601String()}] INFO [Bench] CPU bench entry $i';
    }
    final printUs = (swPrint.elapsedMicroseconds / rounds);
    print('\nString format only    : ${printUs.toStringAsFixed(2)} µs/call');
    print('  Overhead of logger  : +${(loggerUs - printUs).toStringAsFixed(2)} µs/call');

    await logger.dispose();
  } finally {
    await tempDir.delete(recursive: true);
  }

  print('\n──────────────────────────────────────────────');
  print('Target: < 5 µs per call (100 % buffered, no I/O on hot path)');
  print('──────────────────────────────────────────────\n');
}

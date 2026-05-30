// test/benchmark/write_speed_benchmark.dart
//
// Measures raw write throughput of light_logger.
// Run with:  dart run test/benchmark/write_speed_benchmark.dart

import 'dart:io';
import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:light_logger/light_logger.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Benchmark
// ─────────────────────────────────────────────────────────────────────────────

class WriteSpeedBenchmark extends BenchmarkBase {
  late LightLogger _logger;
  late Directory   _tempDir;

  WriteSpeedBenchmark() : super('LightLogger_WriteSpeed');

  @override
  Future<void> setup() async {
    _tempDir = await Directory.systemTemp.createTemp('ll_bench_write_');
    _logger  = await LightLogger.initialize(
      config: LogConfig(
        logDirectory:    _tempDir.path,
        minimumLevel:    LogLevel.debug,
        bufferSizeBytes: 8 * 1024 * 1024,   // 8 MiB buffer
        flushInterval:   const Duration(minutes: 10), // don't flush during bench
        compressionStrategy: const LZ4Strategy(),
      ),
    );
  }

  @override
  void run() {
    _logger.info(
      'Benchmark entry with a realistic message length for testing',
      tag: 'BenchService',
      extra: {'requestId': 12345, 'latencyMs': 42, 'status': 200},
    );
  }

  @override
  Future<void> teardown() async {
    await _logger.dispose();
    await _tempDir.delete(recursive: true);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Additional manual benchmark for burst write
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _burstBenchmark() async {
  final tempDir = await Directory.systemTemp.createTemp('ll_burst_');

  try {
    final logger = await LightLogger.initialize(
      config: LogConfig(
        logDirectory:    tempDir.path,
        minimumLevel:    LogLevel.debug,
        bufferSizeBytes: 8 * 1024 * 1024,
        flushInterval:   const Duration(minutes: 10),
      ),
    );

    const count = 100000;
    final sw = Stopwatch()..start();

    for (int i = 0; i < count; i++) {
      logger.info('Burst message #$i — some realistic log text here',
          tag: 'BurstBench', extra: {'i': i});
    }

    final callsMs = sw.elapsedMilliseconds;
    print('\n=== Burst Write Benchmark ===');
    print('  Entries  : $count');
    print('  Call time: ${callsMs}ms (add() calls only, no I/O)');
    print('  Throughput: ${(count / (callsMs / 1000)).toStringAsFixed(0)} entries/s');

    logger.flush();
    await Future<void>.delayed(const Duration(seconds: 2));

    final stats = await logger.getStats();
    print('  Disk used  : ${stats.diskUsedFormatted}');
    print('  Compression: ${(stats.compressionRatio * 100).toStringAsFixed(1)} %');

    await logger.dispose();
  } finally {
    await tempDir.delete(recursive: true);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  main
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main() async {
  print('Running write-speed benchmark…');
  WriteSpeedBenchmark().report();
  await _burstBenchmark();
}

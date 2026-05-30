// test/integration/high_frequency_test.dart
//
// Verifies that the logger handles bursts of >10 000 entries without
// blocking, losing data, or throwing.

import 'dart:io';
import 'package:test/test.dart';
import 'package:light_logger/light_logger.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ll_hf_');
  });

  tearDown(() async {
    try { await tempDir.delete(recursive: true); } catch (_) {}
  });

  test('writes 10 000 entries without blocking', () async {
    final logger = await LightLogger.initialize(
      config: LogConfig(
        logDirectory:    tempDir.path,
        minimumLevel:    LogLevel.debug,
        bufferSizeBytes: 4 * 1024 * 1024,
        flushInterval:   const Duration(seconds: 60), // force buffer control
        compressionStrategy: const LZ4Strategy(),
      ),
    );

    final sw = Stopwatch()..start();

    for (int i = 0; i < 10000; i++) {
      logger.info('High-frequency entry #$i', tag: 'HF',
          extra: {'index': i, 'burst': true});
    }

    final writeMs = sw.elapsedMilliseconds;

    // Writing 10 000 entries should take well under 1 second
    expect(writeMs, lessThan(1000),
        reason: 'Buffered writes should be fast (<1s for 10k entries)');

    logger.flush();
    await logger.dispose(); // dispose() now waits for all in-flight I/O

    // All entries should be on disk
    final count = await LogQuery(LogReader(), tempDir.path).count();
    expect(count, 10000);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('performance tracker records writes correctly', () async {
    final logger = await LightLogger.initialize(
      config: LogConfig(
        logDirectory: tempDir.path,
        minimumLevel: LogLevel.verbose,
      ),
    );

    for (int i = 0; i < 500; i++) {
      logger.warning('perf test $i');
    }

    final stats = await logger.getStats();
    expect(stats.totalEntriesWritten, 500);
    expect(stats.levelCounts[LogLevel.warning], 500);

    await logger.dispose();
  });

  test('disposed logger silently discards entries', () async {
    final logger = await LightLogger.initialize(
      config: LogConfig(logDirectory: tempDir.path),
    );
    await logger.dispose();

    // Should not throw
    expect(() {
      logger.info('after dispose');
      logger.error('also after dispose');
    }, returnsNormally);
  });
}

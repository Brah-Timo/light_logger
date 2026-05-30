// test/integration/full_write_read_test.dart
//
// End-to-end test: initialize a logger, write entries, dispose it,
// then read them back and verify round-trip fidelity.

import 'dart:io';
import 'package:test/test.dart';
import 'package:light_logger/light_logger.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ll_e2e_');
  });

  tearDown(() async {
    try { await tempDir.delete(recursive: true); } catch (_) {}
  });

  test('full write → dispose → read round-trip', () async {
    // ── Write ──────────────────────────────────────────────
    final logger = await LightLogger.initialize(
      config: LogConfig(
        logDirectory:    tempDir.path,
        minimumLevel:    LogLevel.verbose,
        flushInterval:   const Duration(milliseconds: 100),
        bufferSizeBytes: 512, // force frequent flushes
        compressionStrategy: const LZ4Strategy(),
      ),
    );

    final written = <LogEntry>[];
    for (int i = 0; i < 200; i++) {
      final entry = LogEntry.now(
        level:   LogLevel.values[i % LogLevel.values.length],
        message: 'Message number $i — some repeated text',
        tag:     'Integration',
        extra:   {'seq': i, 'burst': i < 100},
        traceId: 'trace-${i ~/ 10}',
      );
      logger.log(entry.level, entry.message,
          tag: entry.tag, extra: entry.extra, traceId: entry.traceId);
      written.add(entry);
    }

    logger.flush();
    await logger.dispose(); // dispose() waits for all in-flight I/O

    // ── Verify files were created ──────────────────────────
    final llogFiles = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.llog'))
        .toList();
    expect(llogFiles.isNotEmpty, isTrue,
        reason: 'At least one .llog file must exist');

    // ── Read back ──────────────────────────────────────────
    final read = await LogReader().readAll(tempDir.path).toList();

    expect(read.length, equals(200),
        reason: 'All 200 entries should be readable');

    // Verify message content
    for (int i = 0; i < written.length; i++) {
      expect(read[i].message, written[i].message);
      expect(read[i].level,   written[i].level);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('multi-level query on written data', () async {
    final logger = await LightLogger.initialize(
      config: LogConfig(
        logDirectory:  tempDir.path,
        minimumLevel:  LogLevel.verbose,
        flushInterval: const Duration(milliseconds: 50),
      ),
    );

    for (int i = 0; i < 50; i++) {
      logger.info('info $i', tag: 'Test');
    }
    for (int i = 0; i < 20; i++) {
      logger.error('error $i', tag: 'Test');
    }
    for (int i = 0; i < 5; i++) {
      logger.fatal('fatal $i', tag: 'Test');
    }

    logger.flush();
    await logger.dispose(); // dispose() waits for all in-flight I/O

    final errors = await LogQuery(LogReader(), tempDir.path)
        .whereLevel(LogLevel.error)
        .toList();

    expect(errors.length, 25); // 20 errors + 5 fatals
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('stats reflect written entries', () async {
    final logger = await LightLogger.initialize(
      config: LogConfig(
        logDirectory:  tempDir.path,
        minimumLevel:  LogLevel.verbose,
        flushInterval: const Duration(milliseconds: 50),
      ),
    );

    for (int i = 0; i < 100; i++) {
      logger.debug('stat test $i');
    }

    final stats = await logger.getStats();
    expect(stats.totalEntriesWritten, 100);
    expect(stats.levelCounts[LogLevel.debug], 100);

    await logger.dispose();
  });
}

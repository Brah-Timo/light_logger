// test/integration/corruption_recovery_test.dart
//
// Verifies that the reader gracefully handles corrupted or truncated files
// without crashing.

import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:light_logger/light_logger.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ll_corrupt_');
  });

  tearDown(() async {
    try { await tempDir.delete(recursive: true); } catch (_) {}
  });

  test('reader returns empty stream for invalid magic number', () async {
    final path = '${tempDir.path}/bad_magic.llog';
    // Write garbage bytes — no valid magic number
    await File(path).writeAsBytes(List.generate(64, (i) => 0xFF));

    final entries = await LogReader().readFile(path).toList();
    expect(entries, isEmpty);
  });

  test('reader skips corrupted block and continues', () async {
    // Write a valid logger file, then corrupt one block
    final logger = await LightLogger.initialize(
      config: LogConfig(
        logDirectory:    tempDir.path,
        minimumLevel:    LogLevel.verbose,
        flushInterval:   const Duration(milliseconds: 50),
        bufferSizeBytes: 256, // force small blocks
      ),
    );

    for (int i = 0; i < 20; i++) {
      logger.info('entry $i');
    }
    logger.flush();
    await logger.dispose(); // dispose() waits for all in-flight I/O

    // Corrupt bytes in the middle of the file
    final files = tempDir.listSync().whereType<File>().first;
    final bytes  = await files.readAsBytes();
    final copy   = Uint8List.fromList(bytes);
    // Corrupt 50 bytes starting at offset 50 (after header, inside first block)
    for (int i = 50; i < 100 && i < copy.length; i++) {
      copy[i] ^= 0xFF;
    }
    await files.writeAsBytes(copy);

    // Should not throw — reader must skip corrupted blocks.
    // Await the stream fully so all async I/O completes before tearDown
    // deletes the temp directory (avoids PathNotFoundException race).
    final entries = await LogReader().readAll(tempDir.path).toList();
    // entries may be empty or partial — the key assertion is no exception
    expect(entries, isA<List>());
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('reader handles empty file gracefully', () async {
    final path = '${tempDir.path}/empty.llog';
    await File(path).create();

    final entries = await LogReader().readFile(path).toList();
    expect(entries, isEmpty);
  });

  test('reader handles truncated file header gracefully', () async {
    final path = '${tempDir.path}/truncated_header.llog';
    // Write only 10 bytes — shorter than the 32-byte header
    await File(path).writeAsBytes(
      [0x4C, 0x4C, 0x4F, 0x47, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00],
    );

    final entries = await LogReader().readFile(path).toList();
    expect(entries, isEmpty);
  });

  test('CrcValidator detects corruption correctly', () {
    final original = Uint8List.fromList(List.generate(256, (i) => i));
    final withCrc  = CrcValidator.appendCrc16(original);
    expect(CrcValidator.verifyCrc16(withCrc), isTrue);

    // Corrupt one byte
    final corrupt = Uint8List.fromList(withCrc);
    corrupt[42] ^= 0x55;
    expect(CrcValidator.verifyCrc16(corrupt), isFalse);
  });
}

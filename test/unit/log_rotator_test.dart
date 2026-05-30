// test/unit/log_rotator_test.dart

import 'dart:io';
import 'package:test/test.dart';
import 'package:light_logger/light_logger.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ll_rotator_test_');
  });

  tearDown(() async {
    try { await tempDir.delete(recursive: true); } catch (_) {}
  });

  LogConfig makeConfig({int maxSize = 1024, int maxArchives = 3}) {
    return LogConfig(
      logDirectory:    tempDir.path,
      maxFileSizeBytes: maxSize,
      maxArchivedFiles: maxArchives,
      maxTotalDiskBytes: 50 * 1024 * 1024,
    );
  }

  group('LogFileManager', () {
    test('initialize creates directory if missing', () async {
      final subDir = Directory('${tempDir.path}/subdir');
      expect(await subDir.exists(), isFalse);

      final cfg     = LogConfig(logDirectory: subDir.path);
      final manager = LogFileManager(cfg);
      await manager.initialize();

      expect(await subDir.exists(), isTrue);
    });

    test('getActiveFilePath creates a new file on first call', () async {
      final manager = LogFileManager(makeConfig());
      await manager.initialize();
      final path = await manager.getActiveFilePath();
      expect(await File(path).exists(), isTrue);
    });

    test('getActiveFilePath returns same path on second call', () async {
      final manager = LogFileManager(makeConfig());
      await manager.initialize();
      final p1 = await manager.getActiveFilePath();
      final p2 = await manager.getActiveFilePath();
      expect(p1, p2);
    });

    test('listAllFiles returns active file', () async {
      final manager = LogFileManager(makeConfig());
      await manager.initialize();
      await manager.getActiveFilePath();
      final files = await manager.listAllFiles();
      expect(files.length, 1);
    });

    test('archiveFile renames to .arch', () async {
      final manager = LogFileManager(makeConfig());
      await manager.initialize();
      final active   = await manager.getActiveFilePath();
      final archived = await manager.archiveFile(active);
      expect(archived.endsWith('.arch'), isTrue);
      expect(await File(archived).exists(), isTrue);
      expect(await File(active).exists(), isFalse);
    });

    test('totalDiskUsage sums file sizes', () async {
      final manager = LogFileManager(makeConfig());
      await manager.initialize();
      final path = await manager.getActiveFilePath();
      await File(path).writeAsBytes(List.generate(512, (i) => i & 0xFF));
      final total = await manager.totalDiskUsage();
      expect(total, 512);
    });

    test('deleteOldestArchive removes oldest file', () async {
      final manager = LogFileManager(makeConfig());
      await manager.initialize();

      // Create two archive files with different names
      final a1 = File('${tempDir.path}/app_2026-01-01_001.llog.arch');
      final a2 = File('${tempDir.path}/app_2026-01-02_001.llog.arch');
      await a1.create();
      await a2.create();

      final deleted = await manager.deleteOldestArchive();
      expect(deleted, isNotNull);
      expect(await a1.exists(), isFalse); // oldest deleted
      expect(await a2.exists(), isTrue);
    });
  });

  group('LogRotator', () {
    test('shouldRotate returns true when file exceeds maxFileSizeBytes', () async {
      final cfg     = makeConfig(maxSize: 256);
      final manager = LogFileManager(cfg);
      final rotator = LogRotator(config: cfg, fileManager: manager);
      await rotator.initialize();

      // Write more than 256 bytes to the active file
      final active = rotator.activeFilePath!;
      await File(active).writeAsBytes(List.generate(512, (i) => i & 0xFF));

      expect(await rotator.shouldRotate(), isTrue);
    });

    test('rotate creates a new active file', () async {
      final cfg     = makeConfig(maxSize: 256);
      final manager = LogFileManager(cfg);
      final rotator = LogRotator(config: cfg, fileManager: manager);
      await rotator.initialize();

      final before = rotator.activeFilePath!;
      await rotator.rotate();
      final after = rotator.activeFilePath!;

      expect(after, isNot(before));
      expect(await File(after).exists(), isTrue);
    });

    test('rotate enforces maxArchivedFiles', () async {
      final cfg     = makeConfig(maxSize: 64, maxArchives: 2);
      final manager = LogFileManager(cfg);

      // Pre-create 3 archive files
      for (int i = 1; i <= 3; i++) {
        final f = File('${tempDir.path}/app_2025-01-0${i}_001.llog.arch');
        await f.create();
      }

      final rotator = LogRotator(config: cfg, fileManager: manager);
      await rotator.initialize();
      await rotator.rotate();

      final archived = await manager.listArchivedFiles();
      expect(archived.length, lessThanOrEqualTo(cfg.maxArchivedFiles));
    });
  });
}

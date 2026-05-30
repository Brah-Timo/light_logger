// test/unit/disk_monitor_test.dart

import 'dart:io';
import 'package:test/test.dart';
import 'package:light_logger/light_logger.dart';

// Disk-space queries on Windows spawn a PowerShell process which can take
// several seconds on first invocation.  Give each test a generous timeout.
const _diskTimeout = Timeout(Duration(seconds: 60));

void main() {
  late Directory tempDir;
  late LogConfig config;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ll_disk_test_');
    config  = LogConfig(
      logDirectory:      tempDir.path,
      maxTotalDiskBytes: 10 * 1024 * 1024, // 10 MiB
      systemReservedDiskBytes: 1024,        // tiny for tests
    );
  });

  tearDown(() async {
    try { await tempDir.delete(recursive: true); } catch (_) {}
  });

  group('DiskMonitor', () {
    test('getTotalLogDirectorySize returns 0 for empty dir', () async {
      final monitor = DiskMonitor(config);
      final size    = await monitor.getTotalLogDirectorySize();
      expect(size, 0);
    }, timeout: _diskTimeout);

    test('getTotalLogDirectorySize counts file sizes', () async {
      // Create a 1 KB test file
      final file = File('${tempDir.path}/test.llog');
      await file.writeAsBytes(List.generate(1024, (i) => i & 0xFF));

      final monitor = DiskMonitor(config);
      final size    = await monitor.getTotalLogDirectorySize();
      expect(size, 1024);
    }, timeout: _diskTimeout);

    test('checkBeforeWrite allows write within quota', () async {
      final monitor = DiskMonitor(config);
      final ok      = await monitor.checkBeforeWrite(1024);
      expect(ok, isTrue);
    }, timeout: _diskTimeout);

    test('checkBeforeWrite refuses when log quota would be exceeded', () async {
      // Fill up the directory to the quota limit
      final file = File('${tempDir.path}/big.llog');
      final data = List.generate(config.maxTotalDiskBytes, (i) => 0);
      await file.writeAsBytes(data);

      final monitor = DiskMonitor(config);
      final ok      = await monitor.checkBeforeWrite(1);
      expect(ok, isFalse);
    }, timeout: _diskTimeout);

    test('getLogDirectoryUsageRatio is in [0, 1+]', () async {
      final monitor = DiskMonitor(config);
      final ratio   = await monitor.getLogDirectoryUsageRatio();
      expect(ratio, greaterThanOrEqualTo(0.0));
    }, timeout: _diskTimeout);

    test('snapshot returns coherent data', () async {
      final monitor = DiskMonitor(config);
      final snap    = await monitor.snapshot();
      expect(snap.logUsedBytes,  greaterThanOrEqualTo(0));
      expect(snap.logMaxBytes,   config.maxTotalDiskBytes);
      expect(snap.usageRatio,    greaterThanOrEqualTo(0.0));
    }, timeout: _diskTimeout);

    test('onDiskWarning is fired when threshold is crossed', () async {
      bool warningFired = false;
      final cfg = config.copyWith(
        diskWarningThreshold: 0.50,
        onDiskWarning: (_) => warningFired = true,
      );
      // Write a file that is 60 % of quota
      final bytes = (cfg.maxTotalDiskBytes * 0.6).round();
      await File('${tempDir.path}/big.llog')
          .writeAsBytes(List.generate(bytes, (_) => 0));

      final monitor = DiskMonitor(cfg);
      await monitor.checkBeforeWrite(1);
      expect(warningFired, isTrue);
    }, timeout: _diskTimeout);

    test('getFreeDiskBytes returns positive value', () async {
      final monitor = DiskMonitor(config);
      final free    = await monitor.getFreeDiskBytes();
      expect(free, greaterThan(0));
    }, timeout: _diskTimeout);

    test('invalidateCache resets the cache', () async {
      final monitor = DiskMonitor(config);
      await monitor.getFreeDiskBytes(); // populate cache
      monitor.invalidateCache();
      // Should not throw; cache is just cleared
      final free = await monitor.getFreeDiskBytes();
      expect(free, greaterThan(0));
    }, timeout: _diskTimeout);
  });
}

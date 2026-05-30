// lib/src/monitor/health_checker.dart
//
// Aggregates disk and performance metrics into a single health report.
//
// Usage:
//   final report = await healthChecker.check();
//   if (report.status == HealthStatus.critical) {
//     alertOps(report.summary);
//   }

import '../core/log_config.dart';
import 'disk_monitor.dart';
import 'performance_tracker.dart';

/// Overall health status of the logging system.
enum HealthStatus {
  /// Everything is operating within normal parameters.
  healthy,

  /// One or more metrics are approaching limits; action may be needed soon.
  warning,

  /// One or more limits have been breached; immediate action required.
  critical,
}

/// Combines [DiskMonitor] and [PerformanceTracker] into a single health check.
final class HealthChecker {
  // ─────────────────────────────────────────────────────────
  //  Dependencies
  // ─────────────────────────────────────────────────────────

  final LogConfig          _config;
  final DiskMonitor        _diskMonitor;
  final PerformanceTracker _perfTracker;

  // ─────────────────────────────────────────────────────────
  //  Thresholds
  // ─────────────────────────────────────────────────────────

  /// Fraction of maxTotalDiskBytes at which status becomes [HealthStatus.warning].
  final double warningDiskRatio;

  /// Fraction of maxTotalDiskBytes at which status becomes [HealthStatus.critical].
  final double criticalDiskRatio;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  HealthChecker({
    required LogConfig          config,
    required DiskMonitor        diskMonitor,
    required PerformanceTracker perfTracker,
    this.warningDiskRatio  = 0.80,
    this.criticalDiskRatio = 0.95,
  })  : _config      = config,
        _diskMonitor = diskMonitor,
        _perfTracker = perfTracker;

  // ─────────────────────────────────────────────────────────
  //  Health check
  // ─────────────────────────────────────────────────────────

  /// Performs an async health check and returns a [HealthReport].
  Future<HealthReport> check() async {
    final disk    = await _diskMonitor.snapshot();
    final perf    = _perfTracker.snapshot();
    final issues  = <String>[];

    // Disk evaluation
    HealthStatus diskStatus = HealthStatus.healthy;
    if (disk.usageRatio >= criticalDiskRatio) {
      diskStatus = HealthStatus.critical;
      issues.add('CRITICAL: Log disk usage at ${(disk.usageRatio * 100).toStringAsFixed(1)}% '
          '(threshold: ${(criticalDiskRatio * 100).toStringAsFixed(0)}%)');
    } else if (disk.usageRatio >= warningDiskRatio) {
      diskStatus = HealthStatus.warning;
      issues.add('WARNING: Log disk usage at ${(disk.usageRatio * 100).toStringAsFixed(1)}% '
          '(threshold: ${(warningDiskRatio * 100).toStringAsFixed(0)}%)');
    }

    if (disk.freeDiskBytes < _config.systemReservedDiskBytes * 2) {
      diskStatus = HealthStatus.critical;
      issues.add('CRITICAL: OS free disk space below safety margin '
          '(${_formatBytes(disk.freeDiskBytes)} free)');
    }

    // Drop rate evaluation
    HealthStatus perfStatus = HealthStatus.healthy;
    if (perf.totalDropped > 0) {
      final dropRate = perf.totalDropped / (perf.totalWrites + perf.totalDropped);
      if (dropRate > 0.01) {
        perfStatus = HealthStatus.critical;
        issues.add('CRITICAL: ${(dropRate * 100).toStringAsFixed(1)}% of log entries are being dropped');
      } else if (dropRate > 0) {
        perfStatus = HealthStatus.warning;
        issues.add('WARNING: ${perf.totalDropped} log entries have been dropped');
      }
    }

    // Overall status = worst of the two
    final overall = _worst(diskStatus, perfStatus);

    return HealthReport(
      status:    overall,
      diskInfo:  disk,
      perfInfo:  perf,
      issues:    List.unmodifiable(issues),
    );
  }

  HealthStatus _worst(HealthStatus a, HealthStatus b) {
    if (a == HealthStatus.critical || b == HealthStatus.critical) {
      return HealthStatus.critical;
    }
    if (a == HealthStatus.warning || b == HealthStatus.warning) {
      return HealthStatus.warning;
    }
    return HealthStatus.healthy;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  HealthReport
// ─────────────────────────────────────────────────────────────────────────────

/// Result of a [HealthChecker.check] call.
class HealthReport {
  final HealthStatus       status;
  final DiskSnapshot       diskInfo;
  final PerformanceSnapshot perfInfo;
  final List<String>       issues;

  const HealthReport({
    required this.status,
    required this.diskInfo,
    required this.perfInfo,
    required this.issues,
  });

  bool get isHealthy  => status == HealthStatus.healthy;
  bool get isWarning  => status == HealthStatus.warning;
  bool get isCritical => status == HealthStatus.critical;

  String get summary {
    if (issues.isEmpty) {
      return '✅ Logger healthy — '
          '${diskInfo.logUsedBytes ~/ 1024 ~/ 1024} MB log data, '
          '${perfInfo.writesPerSecond.toStringAsFixed(0)} writes/s';
    }
    return issues.join('; ');
  }

  @override
  String toString() => 'HealthReport(status: $status)\n'
      '  Disk  : $diskInfo\n'
      '  Perf  : $perfInfo\n'
      '  Issues: ${issues.isEmpty ? "none" : issues.join(", ")}';
}

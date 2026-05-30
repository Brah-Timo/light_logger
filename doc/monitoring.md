# Monitoring

## DiskMonitor

```dart
final monitor = DiskMonitor(config: config);
final snap = await monitor.snapshot();

print('Log used : ${snap.logUsedBytes ~/ 1024} KB');
print('OS free  : ${snap.freeDiskBytes ~/ 1024 ~/ 1024} MB');
print('Usage    : ${(snap.usageRatio * 100).toStringAsFixed(1)}%');
```

## PerformanceTracker

```dart
final tracker = PerformanceTracker();
final snap = tracker.snapshot();

print('Writes/s : ${snap.writesPerSecond.toStringAsFixed(0)}');
print('Avg lat  : ${snap.avgWriteLatencyUs.toStringAsFixed(1)} µs');
print('Dropped  : ${snap.totalDropped}');
```

## HealthChecker

Combines disk and performance into one status:

```dart
final checker = HealthChecker(
  config:      config,
  diskMonitor: diskMonitor,
  perfTracker: perfTracker,
  warningDiskRatio:  0.80,
  criticalDiskRatio: 0.95,
);

final report = await checker.check();

switch (report.status) {
  case HealthStatus.healthy:
    print('✅ ${report.summary}');
  case HealthStatus.warning:
    print('⚠️  ${report.summary}');
  case HealthStatus.critical:
    alertOps(report.summary);
}
```

### HealthReport Fields

| Field | Type | Description |
|-------|------|-------------|
| `status` | `HealthStatus` | `healthy` / `warning` / `critical` |
| `diskInfo` | `DiskSnapshot` | Current disk metrics |
| `perfInfo` | `PerformanceSnapshot` | Current performance metrics |
| `issues` | `List<String>` | Human-readable issue descriptions |
| `summary` | `String` | One-line status summary |

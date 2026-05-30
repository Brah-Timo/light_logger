# Getting Started with light_logger

light_logger is a high-performance **binary logging** package for Dart & Flutter.
It writes compressed binary logs instead of plain text, reducing log file sizes
by up to 98% while protecting your app from disk exhaustion.

---

## Installation

```yaml
dependencies:
  light_logger: ^1.0.0
```

```bash
dart pub get
```

---

## Quick Start

### Initialize

```dart
import 'package:light_logger/light_logger.dart';

final logger = await LightLogger.initialize(
  config: LogConfig(logDirectory: '/data/app/logs'),
);
```

### Write Logs

```dart
logger.verbose('Entering method',   tag: 'Auth');
logger.debug('Token refreshed',     tag: 'Auth');
logger.info('User logged in',       tag: 'Auth');
logger.warning('High memory usage', tag: 'Memory');
logger.error('DB query failed',     tag: 'Database',
    exception: e, stackTrace: st,
    extra: {'query': sql, 'durationMs': 5000});
logger.fatal('Out of memory',       tag: 'Worker');
```

### Query Logs

```dart
final reader = LogReader();
final errors = await LogQuery(reader, '/data/app/logs')
    .whereLevel(LogLevel.error)
    .whereTime(from: DateTime.now().subtract(const Duration(hours: 1)))
    .limit(50)
    .toList();
```

### Export

```dart
await LogExporter.toCsvFile(
  source:     Stream.fromIterable(errors),
  outputPath: '/tmp/recent_errors.csv',
);
```

### Shutdown

```dart
await logger.dispose();
```

---

## Next Steps

- [Architecture](architecture.md) — binary format, compression, rotation
- [Configuration Reference](configuration.md) — all `LogConfig` options
- [Query API](query_api.md) — filtering and exporting logs
- [Monitoring](monitoring.md) — disk monitor, health checker, performance tracker
- [CLI Viewer](cli_viewer.md) — `dart run bin/log_viewer.dart`

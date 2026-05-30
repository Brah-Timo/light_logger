# Query API

## LogQuery — Fluent Builder

```dart
final reader = LogReader();

final results = await LogQuery(reader, '/data/app/logs')
    .whereLevel(LogLevel.error)                              // min level
    .whereLevel(LogLevel.warning, max: LogLevel.fatal)       // level range
    .whereTime(from: DateTime.now().subtract(Duration(hours: 1)))
    .whereTime(to: DateTime.now())
    .whereTag('Database')
    .whereText('timeout')                                    // case-insensitive
    .whereRegex(r'query.*\d{4,}ms')                         // full regex
    .whereTraceId('req-001')
    .skip(10)
    .limit(50)
    .toList();
```

## Streaming (large files)

```dart
await for (final entry in LogQuery(reader, dir).whereLevel(LogLevel.error).execute()) {
  print(entry);
}
```

## LogExporter

Export to various formats:

```dart
// JSON Lines (one JSON object per line)
await LogExporter.toJsonLinesFile(
  source: Stream.fromIterable(entries),
  outputPath: '/tmp/errors.jsonl',
);

// JSON Array
await LogExporter.toJsonArrayFile(
  source: Stream.fromIterable(entries),
  outputPath: '/tmp/errors.json',
);

// CSV
await LogExporter.toCsvFile(
  source: Stream.fromIterable(entries),
  outputPath: '/tmp/errors.csv',
);

// Plain text
await LogExporter.toTextFile(
  source: Stream.fromIterable(entries),
  outputPath: '/tmp/errors.txt',
);
```

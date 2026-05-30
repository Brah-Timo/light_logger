# Configuration Reference

## Factory Constructors

```dart
// Development: verbose, small files, frequent rotation
LogConfig.development(logDirectory: '/tmp/logs')

// Production: compressed, larger files, strict disk limits
LogConfig.production(logDirectory: '/data/logs')
```

## Key Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `logDirectory` | `String` | required | Where `.llog` files are written |
| `maxFileSizeBytes` | `int` | `10 MB` | Rotate when active file exceeds this |
| `maxArchivedFiles` | `int` | `10` | Delete oldest archive beyond this count |
| `maxTotalDiskBytes` | `int` | `100 MB` | Delete archives to stay under this |
| `rotationPolicy` | `RotationPolicy` | `sizeOnly` | `sizeOnly` / `daily` / `sizeAndDaily` |
| `compressionLevel` | `CompressionLevel` | `balanced` | `none` / `fast` / `balanced` / `maximum` |
| `bufferSizeBytes` | `int` | `1 MB` | Flush buffer when this size is reached |
| `flushInterval` | `Duration` | `5s` | Timer-based flush interval |
| `diskWarningThreshold` | `double` | `0.85` | Warn at 85% of `maxTotalDiskBytes` |
| `onDiskWarning` | `Function?` | `null` | Callback when disk warning fires |
| `systemReservedDiskBytes` | `int` | `50 MB` | Minimum free OS disk space to preserve |

## Customizing

```dart
final config = LogConfig.production(logDirectory: dir).copyWith(
  maxFileSizeBytes:  50 * 1024 * 1024,   // 50 MiB
  maxArchivedFiles:  5,
  maxTotalDiskBytes: 250 * 1024 * 1024,  // 250 MiB
  diskWarningThreshold: 0.90,
);
```

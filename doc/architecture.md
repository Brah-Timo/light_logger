# Architecture

```
  Your Code
      │  logger.info(…)
      ▼
  LightLogger  ──── public API
      │
      ▼
  LogBuffer        ← accumulates entries in memory
      │  (flush every 1000 entries / 1 MiB / 5 s)
      ▼
  AsyncWriter      ← compresses block + writes to disk
      │
      ▼
  LogFileManager   ← manages .llog file paths & naming
      │
      ▼
  LogRotator       ← rotates on size/daily trigger,
                      enforces archive limits
```

## Binary Format

Each `.llog` file contains:

```
[32 bytes]  File header  (magic, version, compression type, CRC-32)
[N × block] Compressed blocks
```

Each block:
```
[10 bytes]  Block header (reference timestamp, record count)
[M × entry] Binary-encoded LogEntry records
```

### Why Binary?

| Format | 1 000 entries | Ratio |
|--------|--------------|-------|
| Plain text | ~200 KB | 1× |
| JSON Lines | ~250 KB | 1.25× |
| **light_logger binary + gzip** | **~4 KB** | **~50×** |

## Compression Strategies

| Strategy | Algorithm | Compression | Speed |
|----------|-----------|-------------|-------|
| `GzipStrategy` | RFC 1952 gzip | ~85% | Fast |
| `ZstdStrategy` | zlib deflate/9 | ~88% | Medium |
| `LZ4Strategy` | LZ4 block | ~70% | Fastest |

## Auto-Rotation

Triggers (whichever fires first):
1. Active file size ≥ `LogConfig.maxFileSizeBytes`
2. Daily boundary crossed (if `RotationPolicy.daily`)

After rotation: enforces `maxArchivedFiles` and `maxTotalDiskBytes`.

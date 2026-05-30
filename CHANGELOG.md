# Changelog

All notable changes to `light_logger` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] — 2026-05-29

### Added

#### Core
- `LightLogger` — main entry point with `initialize()`, `dispose()`, and `flush()`
- `LogConfig` — full configuration with presets: `development()`, `production()`, `highFrequency()`
- `LogLevel` enum — VERBOSE / DEBUG / INFO / WARNING / ERROR / FATAL
- `LogEntry` — immutable record with timestamp, level, message, tag, extra, traceId, source info
- `RotationPolicy` enum — `sizeOnly`, `daily`, `sizeAndDaily`
- `CompressionLevel` enum — `fast`, `balanced`, `best`

#### Binary Format
- `BinarySchema` — ground-truth constants for the `.llog` file format (v1.0)
- `BinaryEncoder` — converts `LogEntry` → compact binary bytes
- `BinaryDecoder` — reconstructs `LogEntry` from binary with CRC verification
- `FileHeaderInfo` — parsed header metadata

#### Compression
- `CompressionStrategy` — abstract interface for pluggable algorithms
- `LZ4Strategy` — pure-Dart LZ4 block compression (~72 % ratio, fastest)
- `ZstdStrategy` — Deflate level 9 (~88 % ratio)
- `GzipStrategy` — standard Gzip (interoperable, ~80 % ratio)
- `LogCompressor` — block-level framing, CRC-16 guard, cumulative stats

#### IO
- `LogBuffer` — in-memory accumulation with count/size/timer flush triggers
- `AsyncWriter` — non-blocking disk writer with rotation and disk-guard integration
- `LogFileManager` — directory lifecycle, file listing, archiving, deletion
- `LogRotator` — rotation execution and archive limit enforcement

#### Monitor
- `DiskMonitor` — pre-write space guard, 10s cache, platform-specific free-space query
- `PerformanceTracker` — writes/s rolling window, per-level counters, peak rate
- `HealthChecker` — aggregated health report (healthy / warning / critical)

#### Reader & Query
- `LogReader` — streaming `.llog` file reader, auto-detect compression
- `LogQuery` — fluent filter builder (level, time, tag, text, regex, traceId, limit, skip)
- `LogExporter` — export to JSON Lines, JSON Array, CSV, plain text (file or string)

#### Utilities
- `StringPool` — per-file string interning (saves 75–85 % on tag fields)
- `CrcValidator` — pure-Dart CRC-16/CCITT and CRC-32/ISO3309 with lookup tables
- `TimestampEncoder` — delta encoding/decoding for block timestamps

#### CLI
- `bin/log_viewer.dart` — full-featured CLI: filter, search, export, colour output

#### Examples
- `example/basic_usage.dart` — write → stats → health → read → export
- `example/flutter_integration.dart` — Flutter app with path_provider
- `example/server_side_dart.dart` — high-frequency server workload simulation

#### Tests
- Unit tests: encoder, compressor + CRC, disk monitor, log query, file rotator
- Integration tests: full write/read round-trip, high-frequency burst, corruption recovery
- Benchmarks: write speed, compression ratio comparison, CPU cost measurement

---

## [Unreleased]

### Planned
- Native LZ4 FFI binding for maximum compression speed
- Native Zstd FFI binding for best compression ratio
- Isolate-safe shared-memory writer for multi-isolate apps
- Structured log viewer TUI (terminal UI)
- Cloudflare R2 / S3 log-upload sink
- Log sampling (drop X% of debug entries under heavy load)

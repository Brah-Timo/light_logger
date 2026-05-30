// lib/src/io/log_buffer.dart
//
// The "secret weapon" of light_logger's write performance.
//
// Why buffering matters:
//   A naive logger calls File.writeAsString() once per log entry.
//   On modern SSDs an fsync costs ~100 µs and an I/O syscall ~10 µs.
//   At 10 000 writes/s that is 100 % CPU just on I/O overhead.
//
//   LogBuffer accumulates entries in memory and flushes them as a single
//   compressed block.  1 000 entries → 1 syscall instead of 1 000.
//   CPU overhead drops by ~99 %.
//
// Flush triggers (whichever fires first):
//   1. Record count reaches BinarySchema.maxBlockRecords (default 1 000)
//   2. Estimated raw byte size reaches LogConfig.bufferSizeBytes (default 1 MiB)
//   3. LogConfig.flushInterval timer fires (default 5 s)
//   4. Caller calls forceFlush()
//
// Output:
//   Each flush emits one [Uint8List] on [blockStream].  The bytes are the
//   raw (uncompressed) block payload, starting with the 10-byte block header.
//   [AsyncWriter] subscribes to this stream and handles compression + disk I/O.

import 'dart:async';
import 'dart:typed_data';

import '../core/log_entry.dart';
import '../core/log_config.dart';
import '../binary/binary_encoder.dart';
import '../binary/binary_schema.dart';
import '../utils/string_pool.dart';

/// In-memory accumulation buffer for log entries.
///
/// Thread-safety: designed to run on a single isolate.  If entries arrive
/// from multiple isolates, route them through a [SendPort] first.
final class LogBuffer {
  // ─────────────────────────────────────────────────────────
  //  Dependencies
  // ─────────────────────────────────────────────────────────

  final LogConfig     _config;
  final BinaryEncoder _encoder;

  // ─────────────────────────────────────────────────────────
  //  State
  // ─────────────────────────────────────────────────────────

  final List<LogEntry> _pending       = [];
  int                  _pendingBytes  = 0;
  Timer?               _flushTimer;
  bool                 _disposed      = false;

  // ─────────────────────────────────────────────────────────
  //  Output stream
  // ─────────────────────────────────────────────────────────

  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();

  /// Emits one [Uint8List] per flushed block (raw, before compression).
  Stream<Uint8List> get blockStream => _controller.stream;

  // ─────────────────────────────────────────────────────────
  //  Telemetry
  // ─────────────────────────────────────────────────────────

  int _totalEntriesBuffered = 0;
  int _totalBlocksFlushed   = 0;

  int get totalEntriesBuffered => _totalEntriesBuffered;
  int get totalBlocksFlushed   => _totalBlocksFlushed;
  int get pendingEntryCount    => _pending.length;
  int get pendingBytesEstimate => _pendingBytes;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  LogBuffer({
    required LogConfig  config,
    required StringPool stringPool,
  })  : _config  = config,
        _encoder = BinaryEncoder(stringPool) {
    _startTimer();
  }

  // ─────────────────────────────────────────────────────────
  //  Public API
  // ─────────────────────────────────────────────────────────

  /// Adds [entry] to the buffer.
  ///
  /// Returns immediately without blocking the caller.
  /// May trigger a synchronous flush if size/count thresholds are exceeded.
  void add(LogEntry entry) {
    if (_disposed) return;

    _pending.add(entry);
    _pendingBytes += entry.estimatedSizeBytes;
    _totalEntriesBuffered++;

    if (_pending.length >= BinarySchema.maxBlockRecords ||
        _pendingBytes   >= _config.bufferSizeBytes) {
      _flush();
    }
  }

  /// Forces an immediate flush, regardless of thresholds.
  ///
  /// Blocks until the block bytes have been emitted on [blockStream].
  void forceFlush() {
    if (_disposed) return;
    _flush();
  }

  // ─────────────────────────────────────────────────────────
  //  Dispose
  // ─────────────────────────────────────────────────────────

  /// Flushes any remaining entries, cancels the timer, and closes the stream.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _flushTimer?.cancel();
    _flush(); // emit final block (may be partial)
    await _controller.close();
  }

  // ─────────────────────────────────────────────────────────
  //  Internal flush
  // ─────────────────────────────────────────────────────────

  void _flush() {
    if (_pending.isEmpty) return;

    _flushTimer?.cancel();

    _encoder.beginBlock();

    // Accumulate all encoded records
    final rawRecords = <int>[];
    int refMs = _pending.first.timestampMs;

    for (final entry in _pending) {
      rawRecords.addAll(_encoder.encodeEntry(entry));
    }

    // Build block header (10 bytes)
    final blockHeader = _encoder.encodeBlockHeader(
      referenceTimestampMs: refMs,
      recordCount:          _pending.length,
    );

    // Full raw block = block header + all record bytes
    final rawBlock = Uint8List(blockHeader.length + rawRecords.length);
    rawBlock.setAll(0, blockHeader);
    rawBlock.setAll(blockHeader.length, rawRecords);

    _pending.clear();
    _pendingBytes = 0;
    _totalBlocksFlushed++;

    _controller.add(rawBlock);

    if (!_disposed) _startTimer();
  }

  void _startTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_config.flushInterval, _flush);
  }
}

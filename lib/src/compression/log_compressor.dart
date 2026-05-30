// lib/src/compression/log_compressor.dart
//
// Orchestrates compression of binary blocks before writing to disk.
//
// Design:
//   Compression is applied at BLOCK level, not record level.
//   A block typically contains 1 000 records (4 MiB of raw binary data).
//   Compressing the block as a unit lets the algorithm exploit repetition
//   across records (e.g. the same tag name, similar message prefixes,
//   sequential timestamps), yielding far higher ratios than per-record
//   compression.
//
// Wire format of a compressed block as written to the file:
//   4 bytes  uint32LE  compressed payload size (N)
//   4 bytes  uint32LE  original (decompressed) payload size
//   2 bytes  uint16LE  CRC-16 of the ORIGINAL (uncompressed) block
//   N bytes  u8[N]     compressed payload
//
// The CRC is computed BEFORE compression so that decompression failures
// are detected independently of the decompressor.

import 'dart:typed_data';
import '../utils/crc_validator.dart';
import 'compression_strategy.dart';

/// Wraps a [CompressionStrategy] with block-level framing and integrity
/// checking.
///
/// Thread-safety: this class is **not** thread-safe.  Use one instance
/// per writer isolate.
final class LogCompressor {
  // ─────────────────────────────────────────────────────────
  //  Dependencies
  // ─────────────────────────────────────────────────────────

  final CompressionStrategy _strategy;

  // ─────────────────────────────────────────────────────────
  //  Telemetry counters (cumulative, since instance creation)
  // ─────────────────────────────────────────────────────────

  int _totalRawBytes        = 0;
  int _totalCompressedBytes = 0;
  int _totalBlocksWritten   = 0;
  int _totalBlocksRead      = 0;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  LogCompressor(this._strategy);

  // ─────────────────────────────────────────────────────────
  //  Compress
  // ─────────────────────────────────────────────────────────

  /// Compresses [rawBlock] and wraps it with the block framing header.
  ///
  /// Returns the framed, compressed bytes ready to be written after the
  /// 4-byte `compressedBlockSize` size prefix (written by [AsyncWriter]).
  Uint8List compressBlock(Uint8List rawBlock) {
    if (rawBlock.isEmpty) return Uint8List(10); // empty framed block

    _totalRawBytes += rawBlock.length;

    // Compute CRC-16 of the raw block BEFORE compressing
    final rawCrc    = CrcValidator.crc16(rawBlock);

    // Compress
    final compressed = _strategy.compress(rawBlock);
    _totalCompressedBytes += compressed.length;
    _totalBlocksWritten++;

    // Build framed output:
    //   4 bytes  compressed size (uint32 LE)
    //   4 bytes  original size   (uint32 LE)
    //   2 bytes  CRC-16 of original (uint16 LE)
    //   N bytes  compressed payload
    final frame = Uint8List(10 + compressed.length);
    final view  = ByteData.sublistView(frame);
    view.setUint32(0, compressed.length, Endian.little);
    view.setUint32(4, rawBlock.length,   Endian.little);
    view.setUint16(8, rawCrc,            Endian.little);
    frame.setAll(10, compressed);

    return frame;
  }

  // ─────────────────────────────────────────────────────────
  //  Decompress
  // ─────────────────────────────────────────────────────────

  /// Decompresses a framed block and verifies its CRC-16.
  ///
  /// [framedBlock] is the exact byte slice produced by [compressBlock]
  /// (i.e. it starts with the 10-byte frame header).
  ///
  /// Throws [LogCorruptionException] if:
  ///   • The frame is too short.
  ///   • The CRC-16 of the decompressed data does not match.
  Uint8List decompressBlock(Uint8List framedBlock) {
    if (framedBlock.length < 10) {
      throw const LogCorruptionException(
        'Framed block is too short (< 10 bytes)',
      );
    }

    final view           = ByteData.sublistView(framedBlock);
    final compressedLen  = view.getUint32(0, Endian.little);
    final originalLen    = view.getUint32(4, Endian.little);
    final storedCrc      = view.getUint16(8, Endian.little);

    if (framedBlock.length < 10 + compressedLen) {
      throw LogCorruptionException(
        'Block payload truncated: expected ${10 + compressedLen} bytes, '
        'got ${framedBlock.length}',
      );
    }

    final payload      = framedBlock.sublist(10, 10 + compressedLen);
    final decompressed = _strategy.decompress(payload, originalLen);

    // Verify integrity of the decompressed data
    final actualCrc = CrcValidator.crc16(decompressed);
    if (actualCrc != storedCrc) {
      throw LogCorruptionException(
        'CRC-16 mismatch after decompression: '
        'expected $storedCrc, got $actualCrc',
      );
    }

    _totalBlocksRead++;
    return decompressed;
  }

  // ─────────────────────────────────────────────────────────
  //  Statistics
  // ─────────────────────────────────────────────────────────

  /// Cumulative compression ratio (0.0 = no compression, 1.0 = 100 %).
  double get compressionRatio {
    if (_totalRawBytes == 0) return 0.0;
    return 1.0 - (_totalCompressedBytes / _totalRawBytes);
  }

  /// Bytes saved since the compressor was created.
  int get bytesSaved => _totalRawBytes - _totalCompressedBytes;

  /// Number of blocks written.
  int get blocksWritten => _totalBlocksWritten;

  /// Number of blocks read (decompressed).
  int get blocksRead => _totalBlocksRead;

  CompressionStrategy get strategy => _strategy;

  /// Human-readable statistics summary.
  String get statsReport {
    final pct = (compressionRatio * 100).toStringAsFixed(1);
    final savedMB = (bytesSaved / 1024 / 1024).toStringAsFixed(2);
    return 'LogCompressor(${_strategy.algorithmName}) | '
        'ratio: $pct % | saved: ${savedMB} MB | '
        'blocks written: $_totalBlocksWritten, read: $_totalBlocksRead';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  LogCorruptionException (re-exported from here for convenience)
// ─────────────────────────────────────────────────────────────────────────────

/// Thrown when a compressed block or binary record fails an integrity check.
class LogCorruptionException implements Exception {
  final String message;
  const LogCorruptionException(this.message);

  @override
  String toString() => 'LogCorruptionException: $message';
}

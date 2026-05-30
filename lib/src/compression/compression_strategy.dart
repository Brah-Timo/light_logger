// lib/src/compression/compression_strategy.dart
//
// Abstract interface for compression algorithms.
//
// light_logger ships three built-in strategies:
//   • LZ4Strategy   — fastest (default), ~75 % ratio
//   • ZstdStrategy  — best ratio, ~90 %+, slightly slower
//   • GzipStrategy  — universally available, ~80 %, slowest of the three
//
// Implementors can provide custom strategies (e.g. Brotli, Snappy) by
// extending this class.  The chosen strategy is stored in the file header
// so the reader can auto-detect which algorithm to use.

import 'dart:typed_data';

/// Contract that every compression strategy must fulfil.
///
/// All implementations must be **stateless** and **thread-safe** — the same
/// instance is shared between the write and read paths.
abstract class CompressionStrategy {
  const CompressionStrategy();

  // ─────────────────────────────────────────────────────────
  //  Core contract
  // ─────────────────────────────────────────────────────────

  /// Compresses [input] and returns the compressed bytes.
  ///
  /// Must never return `null`.  On compression failure the implementation
  /// should return [input] unchanged (pass-through) rather than throwing.
  Uint8List compress(Uint8List input);

  /// Decompresses [input] back to the original bytes.
  ///
  /// [originalSize] is a hint (the uncompressed byte count) that some
  /// algorithms use to pre-allocate the output buffer.
  ///
  /// Throws [CompressionException] on failure.
  Uint8List decompress(Uint8List input, int originalSize);

  // ─────────────────────────────────────────────────────────
  //  Metadata
  // ─────────────────────────────────────────────────────────

  /// Short lowercase identifier stored in the file header.
  /// Must be unique across all strategies.
  String get algorithmName;

  /// The byte constant used in the binary file header
  /// (see [BinarySchema.compressionXxx]).
  int get headerByte;

  /// Typical compression ratio for log-like data, expressed as the fraction
  /// of the *retained* size.  E.g. 0.25 means 75 % compression.
  /// Used only for documentation / stats display.
  double get typicalRetentionRatio;

  @override
  String toString() => 'CompressionStrategy($algorithmName)';
}

// ─────────────────────────────────────────────────────────────────────────────
//  Exceptions
// ─────────────────────────────────────────────────────────────────────────────

/// Thrown when decompression fails due to corrupted or truncated data.
class CompressionException implements Exception {
  final String algorithm;
  final String details;

  const CompressionException(this.algorithm, this.details);

  @override
  String toString() => 'CompressionException($algorithm): $details';
}

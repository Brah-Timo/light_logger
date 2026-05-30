// lib/src/compression/gzip_strategy.dart
//
// Gzip compression strategy — universally readable, widely supported.
//
// Use this strategy when log files need to be opened by third-party tools
// (e.g. `zcat`, `gunzip`, `less`) without a custom decoder.
//
// Compression ratio: ~75-85 % reduction for structured log data.
// Speed: slowest of the three built-in strategies.

import 'dart:io';
import 'dart:typed_data';

import '../binary/binary_schema.dart';
import 'compression_strategy.dart';

/// Gzip compression.  Best interoperability; slightly slower than LZ4.
class GzipStrategy extends CompressionStrategy {
  /// Gzip compression level (1-9).  Default: 6 (balanced).
  final int level;

  const GzipStrategy({this.level = 6});

  @override
  String get algorithmName => 'gzip';

  @override
  int get headerByte => BinarySchema.compressionGzip;

  @override
  double get typicalRetentionRatio => 0.20; // ~80 % reduction

  // ─────────────────────────────────────────────────────────
  //  Compress
  // ─────────────────────────────────────────────────────────

  @override
  Uint8List compress(Uint8List input) {
    if (input.isEmpty) return Uint8List(0);
    try {
      final compressed = GZipCodec(level: level).encode(input);
      return Uint8List.fromList(compressed);
    } catch (_) {
      return input; // pass-through on failure
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Decompress
  // ─────────────────────────────────────────────────────────

  @override
  Uint8List decompress(Uint8List input, int originalSize) {
    if (input.isEmpty) return Uint8List(0);
    try {
      final decompressed = gzip.decode(input);
      return Uint8List.fromList(decompressed);
    } catch (e) {
      throw CompressionException('gzip', 'Decompression failed: $e');
    }
  }

  @override
  String toString() => 'GzipStrategy(level: $level)';
}

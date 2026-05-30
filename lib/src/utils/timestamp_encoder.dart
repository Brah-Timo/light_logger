// lib/src/utils/timestamp_encoder.dart
//
// Utilities for the compact timestamp representation used in binary blocks.
//
// Strategy:
//   • Each block has a reference timestamp (the millisecondsSinceEpoch of
//     the first record it contains).
//   • Subsequent records within the block store only the *delta* (signed
//     int64) relative to that reference.
//   • In practice most deltas are tiny positive numbers (< 1 000 ms), which
//     compress extremely well with LZ4 or Zstd.
//   • We still use int64 to handle the (rare) case of a clock jump.

import 'dart:typed_data';

/// Encodes and decodes timestamps for the binary block format.
abstract final class TimestampEncoder {
  TimestampEncoder._();

  // ─────────────────────────────────────────────────────────
  //  Encode
  // ─────────────────────────────────────────────────────────

  /// Writes [absoluteMs] as an int64 LE reference timestamp into [buffer]
  /// at [offset].  Returns the new offset (offset + 8).
  static int writeReference(ByteData buffer, int offset, int absoluteMs) {
    buffer.setInt64(offset, absoluteMs, Endian.little);
    return offset + 8;
  }

  /// Computes the delta between [absoluteMs] and [referenceMs] and writes it
  /// as an int64 LE into [buffer] at [offset].
  /// Returns the new offset (offset + 8).
  static int writeDelta(
    ByteData buffer,
    int offset,
    int absoluteMs,
    int referenceMs,
  ) {
    final delta = absoluteMs - referenceMs;
    buffer.setInt64(offset, delta, Endian.little);
    return offset + 8;
  }

  // ─────────────────────────────────────────────────────────
  //  Decode
  // ─────────────────────────────────────────────────────────

  /// Reads an int64 LE reference timestamp from [data] at [offset].
  static int readReference(ByteData data, int offset) {
    return data.getInt64(offset, Endian.little);
  }

  /// Reads an int64 LE delta from [data] at [offset] and returns
  /// the absolute timestamp by adding [referenceMs].
  static int readAbsolute(ByteData data, int offset, int referenceMs) {
    final delta = data.getInt64(offset, Endian.little);
    return referenceMs + delta;
  }

  // ─────────────────────────────────────────────────────────
  //  Formatting helpers
  // ─────────────────────────────────────────────────────────

  /// Formats [ms] as an ISO-8601 string (UTC), e.g.
  /// `"2026-05-29T14:32:01.123Z"`.
  static String formatMs(int ms) {
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
        .toIso8601String();
  }

  /// Parses an ISO-8601 string back to milliseconds since epoch.
  /// Returns `null` on parse failure.
  static int? parseIso8601(String iso) {
    try {
      return DateTime.parse(iso).millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  /// Returns the number of milliseconds elapsed since [startMs].
  static int elapsed(int startMs) {
    return DateTime.now().millisecondsSinceEpoch - startMs;
  }
}

// lib/src/binary/binary_encoder.dart
//
// Converts LogEntry objects into the raw binary format defined in
// binary_schema.dart.
//
// Design goals:
//   1. Zero allocations on the hot path — we reuse a ByteData write buffer.
//   2. Correct endianness (little-endian throughout).
//   3. Each method documents its exact byte layout for easy auditing.

import 'dart:convert';
import 'dart:typed_data';

import '../core/log_entry.dart';
import '../binary/binary_schema.dart';
import '../utils/string_pool.dart';
import '../utils/crc_validator.dart';
// import '../utils/timestamp_encoder.dart'; // reserved for future use

/// Encodes [LogEntry] objects into the binary format defined by
/// [BinarySchema].
///
/// **Lifecycle:** One [BinaryEncoder] is shared across the lifetime of a
/// single log file.  Call [beginBlock] at the start of every new block to
/// reset the timestamp reference.
final class BinaryEncoder {
  // ─────────────────────────────────────────────────────────
  //  Dependencies
  // ─────────────────────────────────────────────────────────

  final StringPool _pool;

  // ─────────────────────────────────────────────────────────
  //  Block state
  // ─────────────────────────────────────────────────────────

  int _blockReferenceMs = 0;
  bool _blockStarted    = false;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  BinaryEncoder(this._pool);

  // ─────────────────────────────────────────────────────────
  //  Block lifecycle
  // ─────────────────────────────────────────────────────────

  /// Signals the start of a new compression block.
  ///
  /// The first record encoded after this call sets the block's reference
  /// timestamp; all subsequent records in the block store deltas.
  void beginBlock() {
    _blockStarted    = false;
    _blockReferenceMs = 0;
  }

  /// The reference timestamp of the current block (set by the first
  /// [encodeEntry] call after [beginBlock]).
  int get blockReferenceMs => _blockReferenceMs;

  // ─────────────────────────────────────────────────────────
  //  Entry encoding
  // ─────────────────────────────────────────────────────────

  /// Encodes a single [LogEntry] to bytes.
  ///
  /// Record layout (without optional parts):
  /// ```
  ///  [0]      uint8     Record type  (0x01)
  ///  [1..8]   int64LE   Timestamp delta from block reference (ms)
  ///  [9]      uint8     Log level byte value
  ///  [10..11] uint16LE  Tag pool index   (0xFFFF = absent)
  ///  [12..13] uint16LE  Message byte length
  ///  [14..N]  u8[N]     Message content (UTF-8)
  ///  [N+14..N+15] uint16LE  TraceId pool index (0xFFFF = absent)
  ///  [N+16]   uint8     Source-info flag (0 = absent, 1 = present)
  ///  if source-info:
  ///    [N+17..N+18] uint16LE  Source file pool index
  ///    [N+19..N+22] uint32LE  Source line number
  ///  [M+0..M+3] uint32LE  Extra-data byte length (0 = absent)
  ///  [M+4..M+4+E] u8[E]  Extra-data bytes (compact map)
  ///  [end-2..end] uint16LE  CRC-16 of all bytes above
  /// ```
  Uint8List encodeEntry(LogEntry entry) {
    // ── Initialise block reference on first record ──────────
    if (!_blockStarted) {
      _blockReferenceMs = entry.timestampMs;
      _blockStarted     = true;
    }

    // ── Encode message ──────────────────────────────────────
    final msgBytes = utf8.encode(entry.message);
    if (msgBytes.length > BinarySchema.maxMessageBytes) {
      throw ArgumentError(
        'Message too long: ${msgBytes.length} bytes '
        '(max ${BinarySchema.maxMessageBytes})',
      );
    }

    // ── Resolve pool indices ────────────────────────────────
    final tagId     = entry.tag     != null ? _pool.intern(entry.tag!)     : BinarySchema.poolIndexAbsent;
    final traceId   = entry.traceId != null ? _pool.intern(entry.traceId!) : BinarySchema.poolIndexAbsent;

    final bool hasSource = entry.sourceFile != null || entry.sourceLine != null;
    final srcFileId = hasSource && entry.sourceFile != null
        ? _pool.intern(entry.sourceFile!)
        : BinarySchema.poolIndexAbsent;

    // ── Encode extra data ────────────────────────────────────
    Uint8List extraBytes = Uint8List(0);
    if (entry.extra != null && entry.extra!.isNotEmpty) {
      extraBytes = _encodeExtra(entry.extra!);
    }

    // ── Calculate total record size (before CRC) ─────────────
    // fixed:  1 + 8 + 1 + 2 + 2 = 14
    // msg:    N
    // trace:  2
    // src-flag: 1
    // src-info: 0 or (2+4) = 6
    // extra-len: 4
    // extra-data: M
    // crc:    2
    final srcSize     = hasSource ? 6 : 0;
    final totalBefore = 14 + msgBytes.length + 2 + 1 + srcSize + 4 + extraBytes.length;
    final totalSize   = totalBefore + 2; // + CRC-16

    final out    = Uint8List(totalSize);
    final buffer = ByteData.sublistView(out);
    int off = 0;

    // Record type
    buffer.setUint8(off++, BinarySchema.recordTypeStandard);

    // Timestamp delta
    final delta = entry.timestampMs - _blockReferenceMs;
    buffer.setInt64(off, delta, Endian.little);
    off += 8;

    // Log level
    buffer.setUint8(off++, entry.level.byteValue);

    // Tag pool index
    buffer.setUint16(off, tagId, Endian.little);
    off += 2;

    // Message length + content
    buffer.setUint16(off, msgBytes.length, Endian.little);
    off += 2;
    out.setAll(off, msgBytes);
    off += msgBytes.length;

    // TraceId pool index
    buffer.setUint16(off, traceId, Endian.little);
    off += 2;

    // Source-info flag
    buffer.setUint8(off++, hasSource ? 1 : 0);
    if (hasSource) {
      buffer.setUint16(off, srcFileId, Endian.little);
      off += 2;
      buffer.setUint32(off, entry.sourceLine ?? 0, Endian.little);
      off += 4;
    }

    // Extra-data length + content
    buffer.setUint32(off, extraBytes.length, Endian.little);
    off += 4;
    if (extraBytes.isNotEmpty) {
      out.setAll(off, extraBytes);
      off += extraBytes.length;
    }

    // CRC-16 over all bytes written so far
    final crc = CrcValidator.crc16(out.sublist(0, off));
    buffer.setUint16(off, crc, Endian.little);

    return out;
  }

  // ─────────────────────────────────────────────────────────
  //  File header
  // ─────────────────────────────────────────────────────────

  /// Builds the 32-byte file header written at offset 0 of every .llog file.
  Uint8List encodeFileHeader({
    required int  compressionType,
    required int  flags,
    required int  creationTimestampMs,
  }) {
    final out    = Uint8List(BinarySchema.fileHeaderSize);
    final buffer = ByteData.sublistView(out);

    // Magic number
    for (int i = 0; i < BinarySchema.magicNumber.length; i++) {
      buffer.setUint8(i, BinarySchema.magicNumber[i]);
    }

    // Version
    buffer.setUint16(4, BinarySchema.versionMajor, Endian.little);
    buffer.setUint16(6, BinarySchema.versionMinor, Endian.little);

    // Compression type & flags
    buffer.setUint8(8, compressionType);
    buffer.setUint8(9, flags);

    // Creation timestamp
    buffer.setInt64(10, creationTimestampMs, Endian.little);

    // String Pool Offset & Index Table Offset — filled in on close
    buffer.setUint32(18, 0, Endian.little);
    buffer.setUint32(22, 0, Endian.little);

    // CRC-32 of bytes [0..25]
    final crc = CrcValidator.crc32(out.sublist(0, 26));
    buffer.setUint32(26, crc, Endian.little);

    // Reserved
    buffer.setUint16(30, 0, Endian.little);

    return out;
  }

  /// Updates the String Pool and Index Table offsets in an already-written
  /// file header.  Returns the corrected 32-byte header.
  Uint8List patchFileHeader({
    required Uint8List existingHeader,
    required int stringPoolOffset,
    required int indexTableOffset,
  }) {
    final out    = Uint8List.fromList(existingHeader);
    final buffer = ByteData.sublistView(out);

    buffer.setUint32(18, stringPoolOffset, Endian.little);
    buffer.setUint32(22, indexTableOffset, Endian.little);

    // Recompute CRC-32
    final crc = CrcValidator.crc32(out.sublist(0, 26));
    buffer.setUint32(26, crc, Endian.little);

    return out;
  }

  // ─────────────────────────────────────────────────────────
  //  Block header
  // ─────────────────────────────────────────────────────────

  /// Builds the 10-byte block header prepended inside each compressed block.
  Uint8List encodeBlockHeader({
    required int referenceTimestampMs,
    required int recordCount,
  }) {
    final out    = Uint8List(BinarySchema.blockHeaderSize);
    final buffer = ByteData.sublistView(out);
    buffer.setInt64(0, referenceTimestampMs, Endian.little);
    buffer.setUint16(8, recordCount, Endian.little);
    return out;
  }

  // ─────────────────────────────────────────────────────────
  //  Extra-data encoding (compact binary map)
  // ─────────────────────────────────────────────────────────

  /// Serialises [extra] as a minimal binary map.
  ///
  /// Format (one entry per key-value pair, concatenated):
  /// ```
  ///  1 byte   uint8     key length in bytes (max 255)
  ///  N bytes  u8[N]     key content (UTF-8)
  ///  1 byte   uint8     value type tag (see _valueTag*)
  ///  M bytes  <varies>  value payload
  /// ```
  Uint8List _encodeExtra(Map<String, dynamic> extra) {
    final out = <int>[];

    for (final kv in extra.entries) {
      // Key
      final keyBytes = utf8.encode(kv.key);
      if (keyBytes.length > 255) continue; // skip oversized keys
      out.add(keyBytes.length);
      out.addAll(keyBytes);

      // Value
      out.addAll(_encodeValue(kv.value));
    }

    return Uint8List.fromList(out);
  }

  static const int _tagNull   = 0x00;
  static const int _tagBool   = 0x01;
  static const int _tagInt    = 0x02;
  static const int _tagDouble = 0x03;
  static const int _tagString = 0x04;
  // _tagOther = 0x05 reserved for future use; toString() fallback reuses _tagString

  List<int> _encodeValue(dynamic value) {
    if (value == null) return [_tagNull];

    if (value is bool) {
      return [_tagBool, value ? 1 : 0];
    }

    if (value is int) {
      final buf = ByteData(9);
      buf.setUint8(0, _tagInt);
      buf.setInt64(1, value, Endian.little);
      return buf.buffer.asUint8List().toList();
    }

    if (value is double) {
      final buf = ByteData(9);
      buf.setUint8(0, _tagDouble);
      buf.setFloat64(1, value, Endian.little);
      return buf.buffer.asUint8List().toList();
    }

    if (value is String) {
      final strBytes = utf8.encode(value.length > 1024 ? value.substring(0, 1024) : value);
      final buf = ByteData(3);
      buf.setUint8(0, _tagString);
      buf.setUint16(1, strBytes.length, Endian.little);
      return [...buf.buffer.asUint8List(), ...strBytes];
    }

    // Fallback — serialise as string via toString()
    return _encodeValue(value.toString());
  }
}

// lib/src/binary/binary_decoder.dart
//
// Mirror of BinaryEncoder — reads raw block bytes and reconstructs
// LogEntry objects in memory.
//
// Callers should always check CRC-16 before using the decoded entries.
// [decodeBlock] performs this check automatically and throws
// [LogCorruptionException] on any mismatch.

import 'dart:convert';
import 'dart:typed_data';

import '../core/log_entry.dart';
import '../core/log_level.dart';
import '../binary/binary_schema.dart';
import '../utils/string_pool.dart';
import '../utils/crc_validator.dart';

/// Exception thrown when a block or record fails its integrity check.
class LogCorruptionException implements Exception {
  final String message;
  final int?   byteOffset;

  const LogCorruptionException(this.message, {this.byteOffset});

  @override
  String toString() => byteOffset != null
      ? 'LogCorruptionException at byte $byteOffset: $message'
      : 'LogCorruptionException: $message';
}

/// Decodes raw (decompressed) block bytes back into [LogEntry] objects.
///
/// **Lifecycle:** One [BinaryDecoder] instance can be reused across many
/// blocks.  The [StringPool] passed at construction is shared and populated
/// incrementally as entries are decoded.
final class BinaryDecoder {
  // ─────────────────────────────────────────────────────────
  //  Dependencies
  // ─────────────────────────────────────────────────────────

  final StringPool _pool;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  BinaryDecoder(this._pool);

  /// Replaces the current string pool (e.g. after reading the pool section
  /// from the end of a closed log file).
  void replacePool(StringPool pool) {
    _pool.clear();
    for (final s in pool.allStrings) {
      _pool.intern(s);
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Block decoding
  // ─────────────────────────────────────────────────────────

  /// Decodes all records from a raw (already-decompressed) block.
  ///
  /// Throws [LogCorruptionException] on any CRC or format error.
  Stream<LogEntry> decodeBlock(Uint8List rawBlock) async* {
    if (rawBlock.length < BinarySchema.blockHeaderSize) {
      throw LogCorruptionException(
        'Block too short: ${rawBlock.length} bytes',
      );
    }

    final data      = ByteData.sublistView(rawBlock);
    final refMs     = data.getInt64(0, Endian.little);
    final recCount  = data.getUint16(8, Endian.little);

    int offset = BinarySchema.blockHeaderSize;
    int decoded = 0;

    while (offset < rawBlock.length && decoded < recCount) {
      final result = _decodeRecord(rawBlock, data, offset, refMs);
      yield result.entry;
      offset += result.bytesConsumed;
      decoded++;
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Record decoding
  // ─────────────────────────────────────────────────────────

  _RecordResult _decodeRecord(
    Uint8List block,
    ByteData  data,
    int       offset,
    int       refMs,
  ) {
    final start = offset;

    _assertBytes(block, offset, 14, 'record header');

    // Record type
    final recType = data.getUint8(offset);
    offset++;
    if (recType != BinarySchema.recordTypeStandard &&
        recType != BinarySchema.recordTypeDayMarker) {
      throw LogCorruptionException(
        'Unknown record type: 0x${recType.toRadixString(16)}',
        byteOffset: offset - 1,
      );
    }

    // Timestamp delta
    final delta       = data.getInt64(offset, Endian.little);
    final absoluteMs  = refMs + delta;
    offset += 8;

    // Log level
    final level = LogLevel.fromByte(data.getUint8(offset));
    offset++;

    // Tag pool index
    final tagId = data.getUint16(offset, Endian.little);
    offset += 2;
    final tag = tagId != BinarySchema.poolIndexAbsent ? _pool.lookup(tagId) : null;

    // Message
    final msgLen = data.getUint16(offset, Endian.little);
    offset += 2;
    _assertBytes(block, offset, msgLen, 'message content');
    final message = utf8.decode(block.sublist(offset, offset + msgLen));
    offset += msgLen;

    // TraceId pool index
    _assertBytes(block, offset, 2, 'traceId index');
    final traceIdx = data.getUint16(offset, Endian.little);
    offset += 2;
    final traceId = traceIdx != BinarySchema.poolIndexAbsent ? _pool.lookup(traceIdx) : null;

    // Source-info flag
    _assertBytes(block, offset, 1, 'source-info flag');
    final hasSource = data.getUint8(offset) == 1;
    offset++;

    String? sourceFile;
    int?    sourceLine;
    if (hasSource) {
      _assertBytes(block, offset, 6, 'source-info fields');
      final fileIdx = data.getUint16(offset, Endian.little);
      offset += 2;
      sourceFile = fileIdx != BinarySchema.poolIndexAbsent ? _pool.lookup(fileIdx) : null;
      sourceLine = data.getUint32(offset, Endian.little);
      offset += 4;
    }

    // Extra-data
    _assertBytes(block, offset, 4, 'extra-data length');
    final extraLen = data.getUint32(offset, Endian.little);
    offset += 4;

    Map<String, dynamic>? extra;
    if (extraLen > 0) {
      _assertBytes(block, offset, extraLen, 'extra-data content');
      extra = _decodeExtra(block.sublist(offset, offset + extraLen));
      offset += extraLen;
    }

    // CRC-16
    _assertBytes(block, offset, 2, 'CRC-16');
    final storedCrc  = data.getUint16(offset, Endian.little);
    final computed   = CrcValidator.crc16(block.sublist(start, offset));
    if (storedCrc != computed) {
      throw LogCorruptionException(
        'CRC-16 mismatch (expected $computed, got $storedCrc)',
        byteOffset: start,
      );
    }
    offset += 2;

    return _RecordResult(
      entry: LogEntry(
        timestampMs: absoluteMs,
        level:       level,
        message:     message,
        tag:         tag?.isNotEmpty == true ? tag : null,
        traceId:     traceId?.isNotEmpty == true ? traceId : null,
        extra:       extra,
        sourceFile:  sourceFile,
        sourceLine:  sourceLine,
      ),
      bytesConsumed: offset - start,
    );
  }

  // ─────────────────────────────────────────────────────────
  //  File header decoding
  // ─────────────────────────────────────────────────────────

  /// Validates and parses the 32-byte file header.
  ///
  /// Throws [LogCorruptionException] if the magic number or CRC are invalid.
  FileHeaderInfo decodeFileHeader(Uint8List header) {
    if (header.length < BinarySchema.fileHeaderSize) {
      throw LogCorruptionException('File header too short');
    }

    if (!BinarySchema.isValidMagic(header)) {
      throw LogCorruptionException('Invalid magic number — not a .llog file');
    }

    // Verify header CRC-32
    final data       = ByteData.sublistView(header);
    final storedCrc  = data.getUint32(26, Endian.little);
    final computed   = CrcValidator.crc32(header.sublist(0, 26));
    if (storedCrc != computed) {
      throw LogCorruptionException('File header CRC-32 mismatch');
    }

    return FileHeaderInfo(
      versionMajor:      data.getUint16(4, Endian.little),
      versionMinor:      data.getUint16(6, Endian.little),
      compressionType:   data.getUint8(8),
      flags:             data.getUint8(9),
      creationTimestamp: data.getInt64(10, Endian.little),
      stringPoolOffset:  data.getUint32(18, Endian.little),
      indexTableOffset:  data.getUint32(22, Endian.little),
    );
  }

  // ─────────────────────────────────────────────────────────
  //  Extra-data decoding
  // ─────────────────────────────────────────────────────────

  Map<String, dynamic> _decodeExtra(Uint8List bytes) {
    final result = <String, dynamic>{};
    int off = 0;

    while (off < bytes.length) {
      if (off + 1 > bytes.length) break;
      final keyLen = bytes[off++];
      if (off + keyLen > bytes.length) break;
      final key = utf8.decode(bytes.sublist(off, off + keyLen));
      off += keyLen;

      if (off >= bytes.length) break;
      final tag = bytes[off++];

      switch (tag) {
        case 0x00: // null
          result[key] = null;

        case 0x01: // bool
          if (off >= bytes.length) break;
          result[key] = bytes[off++] != 0;

        case 0x02: // int
          if (off + 8 > bytes.length) break;
          final view = ByteData.sublistView(bytes, off, off + 8);
          result[key] = view.getInt64(0, Endian.little);
          off += 8;

        case 0x03: // double
          if (off + 8 > bytes.length) break;
          final view = ByteData.sublistView(bytes, off, off + 8);
          result[key] = view.getFloat64(0, Endian.little);
          off += 8;

        case 0x04: // string
          if (off + 2 > bytes.length) break;
          final view   = ByteData.sublistView(bytes, off, off + 2);
          final strLen = view.getUint16(0, Endian.little);
          off += 2;
          if (off + strLen > bytes.length) break;
          result[key] = utf8.decode(bytes.sublist(off, off + strLen));
          off += strLen;

        default: // unknown / other — skip 1 byte
          break;
      }
    }

    return result;
  }

  // ─────────────────────────────────────────────────────────
  //  Guard helper
  // ─────────────────────────────────────────────────────────

  void _assertBytes(
    Uint8List block,
    int offset,
    int needed,
    String fieldName,
  ) {
    if (offset + needed > block.length) {
      throw LogCorruptionException(
        'Truncated record: need $needed bytes for $fieldName '
        'at offset $offset, but block is only ${block.length} bytes',
        byteOffset: offset,
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Value types
// ─────────────────────────────────────────────────────────────────────────────

class _RecordResult {
  final LogEntry entry;
  final int      bytesConsumed;
  const _RecordResult({required this.entry, required this.bytesConsumed});
}

/// Parsed content of a `.llog` file header.
class FileHeaderInfo {
  final int  versionMajor;
  final int  versionMinor;
  final int  compressionType;
  final int  flags;
  final int  creationTimestamp;
  final int  stringPoolOffset;
  final int  indexTableOffset;

  const FileHeaderInfo({
    required this.versionMajor,
    required this.versionMinor,
    required this.compressionType,
    required this.flags,
    required this.creationTimestamp,
    required this.stringPoolOffset,
    required this.indexTableOffset,
  });

  bool get hasStringPool  => (flags & BinarySchema.flagStringPool) != 0;
  bool get hasIndex       => (flags & BinarySchema.flagIndexed)    != 0;
  bool get isEncrypted    => (flags & BinarySchema.flagEncrypted)  != 0;
  bool get hasSourceInfo  => (flags & BinarySchema.flagSourceInfo) != 0;
  String get compressionName =>
      BinarySchema.compressionName(compressionType);

  @override
  String toString() =>
      'FileHeaderInfo(v$versionMajor.$versionMinor, '
      'compression: $compressionName, '
      'created: ${DateTime.fromMillisecondsSinceEpoch(creationTimestamp, isUtc: true).toIso8601String()})';
}

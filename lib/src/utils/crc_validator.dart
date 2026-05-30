// lib/src/utils/crc_validator.dart
//
// Fast, pure-Dart implementations of CRC-16/CCITT and CRC-32 (ISO 3309).
//
// Used in two places:
//   • CRC-16 appended to every record — detects single-block corruption.
//   • CRC-32 written into the file header — validates the 26-byte header.
//
// Both algorithms use pre-computed lookup tables for O(n) performance
// without FFI or native code.

import 'dart:typed_data';

/// Static-only utility class providing CRC-16 and CRC-32 checksums.
abstract final class CrcValidator {
  CrcValidator._(); // not instantiable

  // ─────────────────────────────────────────────────────────
  //  CRC-16 / CCITT (polynomial 0x1021, init 0xFFFF)
  // ─────────────────────────────────────────────────────────

  static final Uint16List _crc16Table = _buildCrc16Table();

  static Uint16List _buildCrc16Table() {
    final table = Uint16List(256);
    for (int i = 0; i < 256; i++) {
      int crc = i << 8;
      for (int j = 0; j < 8; j++) {
        crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1;
        crc &= 0xFFFF;
      }
      table[i] = crc;
    }
    return table;
  }

  /// Computes CRC-16/CCITT of [data] (polynomial 0x1021, init 0xFFFF).
  ///
  /// Returns a value in the range [0, 65535].
  static int crc16(List<int> data) {
    int crc = 0xFFFF;
    for (final byte in data) {
      final index = ((crc >> 8) ^ byte) & 0xFF;
      crc = ((crc << 8) ^ _crc16Table[index]) & 0xFFFF;
    }
    return crc;
  }

  /// Verifies that [data] (which must include the 2-byte CRC at the end)
  /// has a consistent CRC-16.
  ///
  /// Returns `true` when the stored CRC matches the computed CRC.
  static bool verifyCrc16(Uint8List data) {
    if (data.length < 2) return false;
    final stored = data[data.length - 2] | (data[data.length - 1] << 8);
    final computed = crc16(data.sublist(0, data.length - 2));
    return stored == computed;
  }

  // ─────────────────────────────────────────────────────────
  //  CRC-32 (ISO 3309 / ITU-T V.42, polynomial 0xEDB88320)
  // ─────────────────────────────────────────────────────────

  static final Uint32List _crc32Table = _buildCrc32Table();

  static Uint32List _buildCrc32Table() {
    final table = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      int crc = i;
      for (int j = 0; j < 8; j++) {
        crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xEDB88320 : crc >>> 1;
      }
      table[i] = crc;
    }
    return table;
  }

  /// Computes CRC-32 (ISO 3309) of [data].
  ///
  /// Returns an unsigned 32-bit integer.
  static int crc32(List<int> data) {
    int crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = (crc >>> 8) ^ _crc32Table[(crc ^ byte) & 0xFF];
    }
    return (~crc) & 0xFFFFFFFF;
  }

  /// Verifies that the last 4 bytes of [data] contain the correct CRC-32
  /// of [data][0 .. length-4].
  static bool verifyCrc32(Uint8List data) {
    if (data.length < 4) return false;
    final view = ByteData.sublistView(data, data.length - 4);
    final stored = view.getUint32(0, Endian.little);
    final computed = crc32(data.sublist(0, data.length - 4));
    return stored == computed;
  }

  // ─────────────────────────────────────────────────────────
  //  Convenience — append CRC bytes
  // ─────────────────────────────────────────────────────────

  /// Returns [data] with a 2-byte little-endian CRC-16 appended.
  static Uint8List appendCrc16(Uint8List data) {
    final crc = crc16(data);
    final out = Uint8List(data.length + 2);
    out.setAll(0, data);
    out[data.length]     = crc & 0xFF;
    out[data.length + 1] = (crc >> 8) & 0xFF;
    return out;
  }

  /// Returns [data] with a 4-byte little-endian CRC-32 appended.
  static Uint8List appendCrc32(Uint8List data) {
    final crc = crc32(data);
    final out = Uint8List(data.length + 4);
    out.setAll(0, data);
    final view = ByteData.sublistView(out, data.length);
    view.setUint32(0, crc, Endian.little);
    return out;
  }
}

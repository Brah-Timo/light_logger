// lib/src/binary/binary_schema.dart
//
// Ground-truth specification for every byte in a `.llog` binary file.
//
// ═══════════════════════════════════════════════════════════════════════
//  FILE LAYOUT OVERVIEW
// ═══════════════════════════════════════════════════════════════════════
//
//  ┌────────────────────────────────────────────────────────────┐
//  │  FILE HEADER (32 bytes, fixed)                             │
//  ├────────────────────────────────────────────────────────────┤
//  │  COMPRESSED BLOCK 0                                        │
//  │   └─ 4-byte compressed-size prefix (uint32 LE)            │
//  │   └─ N-byte compressed payload                            │
//  │       └─ BLOCK HEADER (10 bytes)                          │
//  │       └─ RECORD 0..K (variable-length)                    │
//  ├────────────────────────────────────────────────────────────┤
//  │  COMPRESSED BLOCK 1 …                                      │
//  ├────────────────────────────────────────────────────────────┤
//  │  …                                                         │
//  ├────────────────────────────────────────────────────────────┤
//  │  STRING POOL (appended on rotation / close)                │
//  │   └─ 2-byte entry count (uint16 LE)                       │
//  │   └─ For each entry: 2-byte length + UTF-8 content        │
//  ├────────────────────────────────────────────────────────────┤
//  │  INDEX TABLE (appended on rotation / close)                │
//  │   └─ For each block: 8-byte offset + 4-byte record count  │
//  └────────────────────────────────────────────────────────────┘
//
// ═══════════════════════════════════════════════════════════════════════
//  FILE HEADER (offset 0, 32 bytes)
// ═══════════════════════════════════════════════════════════════════════
//
//  Offset  Size  Type      Field
//  ──────  ────  ────────  ─────────────────────────────────────────────
//  0       4     u8[4]     Magic number: 0x4C 0x4C 0x4F 0x47  ("LLOG")
//  4       2     uint16LE  Format version major
//  6       2     uint16LE  Format version minor
//  8       1     uint8     Compression type  (see compressionXxx consts)
//  9       1     uint8     Flags bitmask     (see flagXxx consts)
//  10      8     int64LE   File creation timestamp (ms since Unix epoch)
//  18      4     uint32LE  Byte offset of String Pool (0 if not flushed)
//  22      4     uint32LE  Byte offset of Index Table (0 if not flushed)
//  26      4     uint32LE  CRC-32 of header bytes [0..25]
//  30      2     u8[2]     Reserved — must be 0x00 0x00
//
// ═══════════════════════════════════════════════════════════════════════
//  BLOCK HEADER (inside each decompressed block, offset 0, 10 bytes)
// ═══════════════════════════════════════════════════════════════════════
//
//  Offset  Size  Type      Field
//  ──────  ────  ────────  ─────────────────────────────────────────────
//  0       8     int64LE   Block reference timestamp (ms, first record)
//  8       2     uint16LE  Number of records in this block
//
// ═══════════════════════════════════════════════════════════════════════
//  RECORD LAYOUT (inside each decompressed block, variable length)
// ═══════════════════════════════════════════════════════════════════════
//
//  Offset  Size  Type      Field
//  ──────  ────  ────────  ─────────────────────────────────────────────
//  0       1     uint8     Record type: 0x01 = standard entry
//  1       8     int64LE   Timestamp delta from block reference (ms)
//                          Saves space vs. storing absolute timestamps
//  9       1     uint8     Log level byte value (see LogLevel.byteValue)
//  10      2     uint16LE  Tag pool index (0xFFFF = no tag)
//  12      2     uint16LE  Message length in bytes (after UTF-8 encoding)
//  14      N     u8[N]     Message content (UTF-8)
//  14+N    2     uint16LE  TraceId pool index (0xFFFF = none)
//  16+N    1     uint8     Source info present flag (0 or 1)
//  17+N    2     uint16LE  Source file pool index   (if flag == 1)
//  19+N    4     uint32LE  Source line number        (if flag == 1)
//  17/23+N 4     uint32LE  Extra data byte length (0 = none)
//  21/27+N M     u8[M]     Extra data (compact binary map)
//  end-2   2     uint16LE  CRC-16/CCITT of entire record (excl. CRC field)
//
// NOTE: Offsets marked with "/" indicate the two alternatives depending on
//       whether source info is present.

/// Compile-time constants that define the `.llog` binary format.
///
/// All encoder/decoder/reader components reference this class exclusively,
/// making version upgrades a single-point change.
abstract final class BinarySchema {
  BinarySchema._(); // not instantiable

  // ── Magic & version ───────────────────────────────────────────────────────

  /// 4-byte file signature: ASCII "LLOG".
  static const List<int> magicNumber = [0x4C, 0x4C, 0x4F, 0x47];

  static const int versionMajor = 1;
  static const int versionMinor = 0;

  // ── Size constants ─────────────────────────────────────────────────────────

  /// Fixed byte size of the file header.
  static const int fileHeaderSize = 32;

  /// Fixed byte size of the block header (stored inside the compressed blob).
  static const int blockHeaderSize = 10;

  /// Minimum byte size of one record (no message, no extras, no source info).
  static const int recordMinSize = 23; // 1+8+1+2+2+0+2+1+4+4+2

  // ── Block thresholds ──────────────────────────────────────────────────────

  /// Flush a block after this many records (whichever comes first).
  static const int maxBlockRecords = 1000;

  /// Flush a block when raw (uncompressed) bytes reach this threshold.
  static const int maxBlockBytes = 4 * 1024 * 1024; // 4 MiB

  // ── Pool limits ────────────────────────────────────────────────────────────

  /// Maximum number of distinct strings in the per-file String Pool.
  /// Stored as uint16, so max index = 0xFFFE (0xFFFF reserved for "absent").
  static const int stringPoolMaxEntries = 0xFFFF; // 65 535

  /// Sentinel pool index meaning "field not set".
  static const int poolIndexAbsent = 0xFFFF;

  // ── Message / extra limits ────────────────────────────────────────────────

  /// Maximum encoded message length in bytes (stored as uint16).
  static const int maxMessageBytes = 65535;

  /// Maximum extra-data payload in bytes (stored as uint32, capped here).
  static const int maxExtraBytes = 1024 * 1024; // 1 MiB

  // ── Compression type identifiers (stored in file header byte 8) ───────────

  static const int compressionNone = 0x00;
  static const int compressionLZ4  = 0x01;
  static const int compressionZstd = 0x02;
  static const int compressionGzip = 0x03;

  // ── Flag bits (stored in file header byte 9) ──────────────────────────────

  /// File content is AES-256-GCM encrypted.
  static const int flagEncrypted  = 0x01;

  /// File contains an Index Table appended after the last block.
  static const int flagIndexed    = 0x02;

  /// Records may include source file / line info.
  static const int flagSourceInfo = 0x04;

  /// File contains a String Pool appended after blocks (before index).
  static const int flagStringPool = 0x08;

  // ── Record type identifiers (byte 0 of each record) ──────────────────────

  /// Standard [LogEntry] record.
  static const int recordTypeStandard  = 0x01;

  /// Internal marker record written at the start of each new day (for daily
  /// rotation boundary detection).
  static const int recordTypeDayMarker = 0x02;

  // ── File extension ────────────────────────────────────────────────────────

  static const String fileExtension         = '.llog';
  static const String archivedFileExtension = '.llog.gz';

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Returns `true` when [header] starts with [magicNumber].
  static bool isValidMagic(List<int> header) {
    if (header.length < magicNumber.length) return false;
    for (int i = 0; i < magicNumber.length; i++) {
      if (header[i] != magicNumber[i]) return false;
    }
    return true;
  }

  /// Maps a compression-type byte to a human-readable name.
  static String compressionName(int type) {
    return switch (type) {
      compressionNone => 'none',
      compressionLZ4  => 'lz4',
      compressionZstd => 'zstd',
      compressionGzip => 'gzip',
      _ => 'unknown(0x${type.toRadixString(16).padLeft(2, '0')})',
    };
  }
}

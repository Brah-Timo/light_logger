// lib/src/utils/string_pool.dart
//
// Per-file string interning table.
//
// Instead of writing the tag string "NetworkService" (14 bytes) into every
// single record, we write it once into the pool and store only a uint16
// index (2 bytes) in each record.  For a file with 100 000 records that
// share the same tag the saving is:
//
//   Without pool : 14 bytes × 100 000 = 1 400 000 bytes ≈ 1.4 MB
//   With pool    :  2 bytes × 100 000 + 14 = 200 014 bytes ≈ 195 KB
//   Saving       : 85.7 %
//
// The pool is serialised and appended to the file on close/rotation.
// It is referenced by the file header (String Pool Offset field).

import 'dart:typed_data';
import 'dart:convert';
import '../binary/binary_schema.dart';

/// An in-memory string interning table that maps [String] → [int] (uint16).
///
/// Thread-safety note: this class is **not** thread-safe.  All writes must
/// occur from the same isolate (the logger's background writer isolate).
final class StringPool {
  // ─────────────────────────────────────────────────────────
  //  State
  // ─────────────────────────────────────────────────────────

  final Map<String, int> _stringToId = {};
  final List<String>     _idToString = [];

  // ─────────────────────────────────────────────────────────
  //  Core API
  // ─────────────────────────────────────────────────────────

  /// Interns [value] and returns its stable uint16 pool index.
  ///
  /// - If [value] is already in the pool the existing index is returned (O(1)).
  /// - If the pool is full ([BinarySchema.stringPoolMaxEntries] reached),
  ///   [BinarySchema.poolIndexAbsent] (0xFFFF) is returned as a safe fallback;
  ///   the string will be written inline if the encoder detects this.
  /// - Empty strings are treated as absent and return
  ///   [BinarySchema.poolIndexAbsent].
  int intern(String value) {
    if (value.isEmpty) return BinarySchema.poolIndexAbsent;

    final existing = _stringToId[value];
    if (existing != null) return existing;

    if (_idToString.length >= BinarySchema.stringPoolMaxEntries) {
      // Pool is full — signal "absent" so the caller writes it inline.
      return BinarySchema.poolIndexAbsent;
    }

    final id = _idToString.length;
    _idToString.add(value);
    _stringToId[value] = id;
    return id;
  }

  /// Looks up the string stored at [id].
  ///
  /// Returns an empty string when [id] is out of range or equals
  /// [BinarySchema.poolIndexAbsent].
  String lookup(int id) {
    if (id == BinarySchema.poolIndexAbsent) return '';
    if (id < 0 || id >= _idToString.length) return '';
    return _idToString[id];
  }

  /// Returns `true` when [value] is already in the pool.
  bool contains(String value) => _stringToId.containsKey(value);

  // ─────────────────────────────────────────────────────────
  //  Serialisation
  // ─────────────────────────────────────────────────────────

  /// Serialises the pool to bytes for appending to the log file.
  ///
  /// Wire format:
  /// ```
  ///  2 bytes  uint16LE  number of entries
  ///  for each entry:
  ///    2 bytes  uint16LE  byte length of UTF-8 string
  ///    N bytes  u8[N]     UTF-8 content
  /// ```
  Uint8List serialize() {
    final output = <int>[];

    // Entry count (uint16 LE)
    final count = _idToString.length;
    output.add(count & 0xFF);
    output.add((count >> 8) & 0xFF);

    for (final str in _idToString) {
      final encoded = utf8.encode(str);
      // String byte-length (uint16 LE)
      output.add(encoded.length & 0xFF);
      output.add((encoded.length >> 8) & 0xFF);
      output.addAll(encoded);
    }

    return Uint8List.fromList(output);
  }

  /// Deserialises a pool from [bytes] (the format produced by [serialize]).
  ///
  /// Returns a new [StringPool] populated with the stored strings.
  static StringPool deserialize(Uint8List bytes) {
    final pool = StringPool();
    if (bytes.length < 2) return pool;

    final view  = ByteData.sublistView(bytes);
    final count = view.getUint16(0, Endian.little);
    int offset  = 2;

    for (int i = 0; i < count && offset + 2 <= bytes.length; i++) {
      final len = view.getUint16(offset, Endian.little);
      offset += 2;
      if (offset + len > bytes.length) break;
      final str = utf8.decode(bytes.sublist(offset, offset + len));
      pool.intern(str);
      offset += len;
    }

    return pool;
  }

  // ─────────────────────────────────────────────────────────
  //  Diagnostics
  // ─────────────────────────────────────────────────────────

  /// Number of unique strings currently stored.
  int get size => _idToString.length;

  /// Whether the pool has reached its maximum capacity.
  bool get isFull => _idToString.length >= BinarySchema.stringPoolMaxEntries;

  /// Clears all interned strings.
  void clear() {
    _stringToId.clear();
    _idToString.clear();
  }

  /// An unmodifiable view of all interned strings in insertion order.
  List<String> get allStrings => List.unmodifiable(_idToString);

  @override
  String toString() => 'StringPool(${_idToString.length} entries)';
}

// lib/src/reader/log_reader.dart
//
// Reads .llog binary files and reconstructs LogEntry objects.
//
// Key design choices:
//
//   1. STREAMING — uses Dart async generators (yield*) so even a 4 GB
//      log file can be read without loading it all into RAM.
//
//   2. BLOCK-BY-BLOCK — reads one compressed block at a time, decompresses,
//      decodes records, then discards the raw bytes.  Peak memory per read
//      = one uncompressed block ≈ 4 MiB.
//
//   3. RESILIENT — a corrupted block triggers a [LogCorruptionException]
//      that is caught, emitted as a warning to stderr, and skipped.  The
//      reader continues with the next block rather than aborting.
//
//   4. AUTO-DETECT STRATEGY — the file header's compression-type byte is
//      used to instantiate the correct decompressor at runtime.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../binary/binary_decoder.dart';
import '../binary/binary_schema.dart';
import '../compression/log_compressor.dart';
import '../compression/compression_strategy.dart';
import '../compression/lz4_strategy.dart';
import '../compression/zstd_strategy.dart';
import '../compression/gzip_strategy.dart';
import '../core/log_entry.dart';
import '../utils/string_pool.dart';

/// Reads .llog files and emits [LogEntry] objects.
///
/// ```dart
/// final reader = LogReader();
/// await for (final entry in reader.readFile('/logs/app_2026-05-29_001.llog')) {
///   print(entry);
/// }
/// ```
class LogReader {
  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  const LogReader();

  // ─────────────────────────────────────────────────────────
  //  Single file
  // ─────────────────────────────────────────────────────────

  /// Reads all entries from [filePath] in chronological order.
  ///
  /// Skips corrupted blocks with a stderr warning; does not throw.
  Stream<LogEntry> readFile(String filePath) async* {
    final file = File(filePath);
    if (!await file.exists()) return;

    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);

      // ── 1. File header ─────────────────────────────────────
      final headerBytes = await raf.read(BinarySchema.fileHeaderSize);
      if (headerBytes.length < BinarySchema.fileHeaderSize) return;

      final pool    = StringPool();
      final decoder = BinaryDecoder(pool);
      FileHeaderInfo header;

      try {
        header = decoder.decodeFileHeader(headerBytes);
      } catch (e) {
        stderr.writeln('[light_logger reader] Bad header in $filePath: $e');
        return;
      }

      // ── 2. Select decompressor based on header ──────────────
      final compressor = _compressorFor(header.compressionType);

      // ── 3. If string pool is present, load it first ─────────
      if (header.hasStringPool && header.stringPoolOffset > 0) {
        await _loadStringPool(raf, header.stringPoolOffset, pool);
      }

      // ── 4. Read blocks ──────────────────────────────────────
      // Reset to position after header
      await raf.setPosition(BinarySchema.fileHeaderSize);

      while (true) {
        // Read 4-byte framed-block size prefix
        final sizeBuf = await raf.read(4);
        if (sizeBuf.length < 4) break; // EOF

        final frameSize = ByteData.sublistView(sizeBuf)
            .getUint32(0, Endian.little);
        if (frameSize == 0) break;

        // Read the framed block
        final framedBlock = await raf.read(frameSize);
        if (framedBlock.length < frameSize) break; // truncated

        // Stop if we've reached the string pool / index section
        final pos = await raf.position();
        if (header.stringPoolOffset > 0 && pos >= header.stringPoolOffset) {
          break;
        }

        // Decompress + decode
        Uint8List rawBlock;
        try {
          rawBlock = compressor.decompressBlock(framedBlock);
        } catch (e) {
          stderr.writeln('[light_logger reader] Skipping corrupted block '
              'in $filePath: $e');
          continue;
        }

        try {
          yield* decoder.decodeBlock(rawBlock);
        } catch (e) {
          stderr.writeln('[light_logger reader] Skipping partially corrupt '
              'block in $filePath: $e');
        }
      }
    } finally {
      await raf?.close();
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Directory (all files)
  // ─────────────────────────────────────────────────────────

  /// Reads all .llog files in [logDirectory], sorted by name (chronological).
  ///
  /// ```dart
  /// await for (final entry in reader.readAll('/logs')) {
  ///   print(entry);
  /// }
  /// ```
  Stream<LogEntry> readAll(String logDirectory) async* {
    final dir = Directory(logDirectory);
    if (!await dir.exists()) return;

    final files = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = entity.path;
        if (name.endsWith(BinarySchema.fileExtension) ||
            name.endsWith('${BinarySchema.fileExtension}.arch')) {
          files.add(entity.path);
        }
      }
    }
    files.sort(); // alphabetic = chronological given the naming convention

    for (final path in files) {
      yield* readFile(path);
    }
  }

  // ─────────────────────────────────────────────────────────
  //  String pool loading
  // ─────────────────────────────────────────────────────────

  Future<void> _loadStringPool(
    RandomAccessFile raf,
    int offset,
    StringPool pool,
  ) async {
    try {
      await raf.setPosition(offset);
      // Read up to 2 MiB for the string pool
      final poolBytes = await raf.read(2 * 1024 * 1024);
      final loaded    = StringPool.deserialize(poolBytes);
      for (final str in loaded.allStrings) {
        pool.intern(str);
      }
    } catch (_) {
      // String pool unreadable — entries will have null tags
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────────────────

  LogCompressor _compressorFor(int compressionType) {
    final CompressionStrategy strategy;
    switch (compressionType) {
      case BinarySchema.compressionZstd:
        strategy = const ZstdStrategy();
      case BinarySchema.compressionGzip:
        strategy = const GzipStrategy();
      default:
        strategy = const LZ4Strategy(); // also covers compressionNone
    }
    return LogCompressor(strategy);
  }
}

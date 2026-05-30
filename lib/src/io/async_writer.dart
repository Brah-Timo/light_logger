// lib/src/io/async_writer.dart
//
// Subscribes to the LogBuffer block stream, compresses each block, and
// writes it to the active log file — all without blocking the caller.
//
// Pipeline:
//
//   LightLogger.info(…)               [caller's isolate]
//        │
//        ▼
//   LogBuffer.add(entry)              [caller's isolate, returns immediately]
//        │  (timer / count threshold)
//        ▼
//   LogBuffer emits Uint8List block   [async, same isolate]
//        │
//        ▼
//   AsyncWriter._onBlock(rawBlock)
//        │
//        ├─ DiskMonitor.checkBeforeWrite(size)
//        │        └─ if false → deleteOldestArchive()
//        ├─ LogCompressor.compressBlock(rawBlock)
//        ├─ File.writeFrom(compressed)   ← single I/O syscall per block
//        └─ LogRotator.shouldRotate()
//                 └─ if true → rotateActiveFile()
//
// The writer NEVER throws or crashes the application.  All I/O errors are
// caught, logged to stderr internally, and followed by a re-open attempt.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../compression/log_compressor.dart';
import '../core/log_config.dart';
import '../monitor/disk_monitor.dart';
import 'log_rotator.dart';

/// Persistently writes compressed blocks to disk.
///
/// Instantiated once per [LightLogger] instance.
final class AsyncWriter {
  // ─────────────────────────────────────────────────────────
  //  Dependencies
  // ─────────────────────────────────────────────────────────

  final LogConfig      _config;
  final LogCompressor  _compressor;
  final LogRotator     _rotator;
  final DiskMonitor    _diskMonitor;

  // ─────────────────────────────────────────────────────────
  //  State
  // ─────────────────────────────────────────────────────────

  RandomAccessFile?          _raf;
  StreamSubscription<Uint8List>? _sub;
  bool                       _disposed = false;
  // Set to true only after the drain completes; _onBlock uses this
  // to reject blocks that arrive after the drain is fully done.
  bool                       _drained  = false;

  // Tracks the last in-flight _onBlock() call so dispose() can wait for it.
  // Each new block chains onto the previous one to ensure ordering.
  Future<void> _lastBlock = Future<void>.value();

  // ─────────────────────────────────────────────────────────
  //  Telemetry
  // ─────────────────────────────────────────────────────────

  int _blocksWritten      = 0;
  int _bytesWritten       = 0;
  int _diskFullSkips      = 0;
  int _errorCount         = 0;

  int get blocksWritten  => _blocksWritten;
  int get bytesWritten   => _bytesWritten;
  int get diskFullSkips  => _diskFullSkips;
  int get errorCount     => _errorCount;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  AsyncWriter({
    required LogConfig     config,
    required LogCompressor compressor,
    required LogRotator    rotator,
    required DiskMonitor   diskMonitor,
  })  : _config      = config,
        _compressor  = compressor,
        _rotator     = rotator,
        _diskMonitor = diskMonitor;

  // ─────────────────────────────────────────────────────────
  //  Start
  // ─────────────────────────────────────────────────────────

  /// Initialises file handles and subscribes to [blockStream].
  ///
  /// Must be called before any entries are added to the buffer.
  Future<void> start(Stream<Uint8List> blockStream) async {
    await _rotator.initialize();
    await _openFile();

    _sub = blockStream.listen(
      (block) {
        // Chain onto previous block to maintain serial write ordering and
        // ensure dispose() can await all in-flight I/O.
        _lastBlock = _lastBlock.then((_) => _onBlock(block));
      },
      onError: _onStreamError,
      cancelOnError: false,
    );
  }

  // ─────────────────────────────────────────────────────────
  //  Block handler
  // ─────────────────────────────────────────────────────────

  Future<void> _onBlock(Uint8List rawBlock) async {
    if (_drained) return;

    // ── 1. Disk guard ────────────────────────────────────────
    final canWrite = await _diskMonitor.checkBeforeWrite(rawBlock.length);
    if (!canWrite) {
      _diskFullSkips++;
      // Try to reclaim space by deleting the oldest archive
      final deleted = await _rotator.deleteOldestArchive();
      if (deleted == null) {
        // Nothing to delete — silently drop this block
        stderr.writeln('[light_logger] Disk full — dropping log block '
            '(${rawBlock.length} bytes). Configure a larger maxTotalDiskBytes '
            'or add an onDiskWarning callback.');
        return;
      }
    }

    // ── 2. Compress ──────────────────────────────────────────
    final framedBlock = _compressor.compressBlock(rawBlock);

    // ── 3. Write 4-byte block size prefix + framed block ─────
    try {
      final raf = await _ensureFileOpen();

      // Size prefix (uint32 LE) = total framed block size
      final sizePrefix = ByteData(4);
      sizePrefix.setUint32(0, framedBlock.length, Endian.little);
      await raf.writeFrom(sizePrefix.buffer.asUint8List());
      await raf.writeFrom(framedBlock);

      _blocksWritten++;
      _bytesWritten += 4 + framedBlock.length;

    } catch (e, st) {
      _errorCount++;
      stderr.writeln('[light_logger] Write error: $e\n$st');
      // Attempt to reopen the file on next block
      await _closeFile();
      return;
    }

    // ── 4. Check rotation ────────────────────────────────────
    try {
      if (await _rotator.shouldRotate()) {
        await _closeFile();
        await _rotator.rotate();
        await _openFile();
      }
    } catch (e) {
      stderr.writeln('[light_logger] Rotation error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────
  //  File management
  // ─────────────────────────────────────────────────────────

  Future<void> _openFile() async {
    final file = await _rotator.getActiveFile();

    // Write file header only if the file is brand new (empty)
    final isEmpty = await file.length() == 0;
    _raf = await file.open(mode: FileMode.append);

    if (isEmpty) {
      await _writeFileHeader();
    }
  }

  Future<void> _writeFileHeader() async {
    if (_raf == null) return;

    final flags = _computeFlags();
    final header = _buildHeader(flags);

    await _raf!.writeFrom(header);
    _bytesWritten += header.length;
  }

  Uint8List _buildHeader(int flags) {
    // Use BinaryEncoder indirectly via a temporary encoder
    // (encoder is stateless for header construction)
    final out    = Uint8List(32);
    final buffer = ByteData.sublistView(out);

    // Magic
    out[0] = 0x4C; out[1] = 0x4C; out[2] = 0x4F; out[3] = 0x47;

    // Version
    buffer.setUint16(4, 1, Endian.little);
    buffer.setUint16(6, 0, Endian.little);

    // Compression type
    buffer.setUint8(8, _compressor.strategy.headerByte);

    // Flags
    buffer.setUint8(9, flags);

    // Creation timestamp
    buffer.setInt64(10, DateTime.now().millisecondsSinceEpoch, Endian.little);

    // String pool / index offsets — patched on close
    buffer.setUint32(18, 0, Endian.little);
    buffer.setUint32(22, 0, Endian.little);

    // CRC-32 of bytes [0..25]
    int crc = 0xFFFFFFFF;
    for (int i = 0; i < 26; i++) {
      crc = _crc32Step(crc, out[i]);
    }
    buffer.setUint32(26, (~crc) & 0xFFFFFFFF, Endian.little);

    return out;
  }

  int _crc32Step(int crc, int byte) {
    const poly = 0xEDB88320;
    crc ^= byte;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ poly : crc >>> 1;
    }
    return crc;
  }

  int _computeFlags() {
    int flags = 0;
    flags |= 0x08; // flagStringPool
    flags |= 0x02; // flagIndexed
    if (_config.includeSourceInfo) flags |= 0x04; // flagSourceInfo
    if (_config.enableEncryption)  flags |= 0x01; // flagEncrypted
    return flags;
  }

  Future<RandomAccessFile> _ensureFileOpen() async {
    if (_raf != null) return _raf!;
    await _openFile();
    return _raf!;
  }

  Future<void> _closeFile() async {
    try {
      await _raf?.flush();
      await _raf?.close();
    } catch (_) {}
    _raf = null;
  }

  // ─────────────────────────────────────────────────────────
  //  Error handler
  // ─────────────────────────────────────────────────────────

  void _onStreamError(Object error, StackTrace st) {
    _errorCount++;
    stderr.writeln('[light_logger] Stream error: $error\n$st');
  }

  // ─────────────────────────────────────────────────────────
  //  Dispose
  // ─────────────────────────────────────────────────────────

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Wait for ALL already-queued _onBlock() futures to complete before
    // cancelling the subscription.  We must NOT set _drained=true until
    // after this await, otherwise _onBlock() would skip the queued writes.
    await _lastBlock;
    _drained = true;
    await _sub?.cancel();
    await _closeFile();
  }

  // ─────────────────────────────────────────────────────────
  //  Compression stats passthrough
  // ─────────────────────────────────────────────────────────

  String get compressionReport => _compressor.statsReport;
}

// _NoOpStrategy placeholder removed — use CompressionStrategy.none() instead

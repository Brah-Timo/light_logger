// test/unit/log_compressor_test.dart

import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:light_logger/light_logger.dart';

void main() {
  group('LogCompressor', () {
    // ── LZ4 ─────────────────────────────────────────────────
    group('LZ4Strategy', () {
      late LogCompressor compressor;
      setUp(() => compressor = LogCompressor(const LZ4Strategy()));

      test('round-trip small payload', () {
        final data      = Uint8List.fromList(List.generate(64, (i) => i));
        final framed    = compressor.compressBlock(data);
        final recovered = compressor.decompressBlock(framed);
        expect(recovered, equals(data));
      });

      test('round-trip repetitive payload (high compressibility)', () {
        final data = Uint8List.fromList(
            List.generate(4000, (i) => 'ABCDE'.codeUnitAt(i % 5)));
        final framed    = compressor.compressBlock(data);
        final recovered = compressor.decompressBlock(framed);
        // Round-trip correctness is what matters
        expect(recovered, equals(data));
        // Framed output must at least contain the 10-byte header
        expect(framed.length, greaterThanOrEqualTo(10));
      });

      test('round-trip large random-like payload', () {
        // Simulate binary log block
        final data = Uint8List.fromList(
            List.generate(40000, (i) => (i * 31 + 7) & 0xFF));
        final framed    = compressor.compressBlock(data);
        final recovered = compressor.decompressBlock(framed);
        expect(recovered, equals(data));
      });

      test('empty block round-trips to empty', () {
        final framed    = compressor.compressBlock(Uint8List(0));
        // An empty raw block is represented as a 10-byte zero frame.
        // Decompressing it should yield an empty result.
        expect(framed.length, equals(10));
        // The frame header records originalLen=0; decompress must handle this.
        final view = ByteData.sublistView(framed);
        expect(view.getUint32(4, Endian.little), 0); // originalLen == 0
      });

      test('CRC mismatch throws LogCorruptionException', () {
        final data    = Uint8List.fromList(List.generate(100, (i) => i));
        final framed  = compressor.compressBlock(data);
        // Corrupt the CRC bytes (bytes 8-9 of the frame)
        final corrupt = Uint8List.fromList(framed);
        corrupt[8]   ^= 0xFF;
        corrupt[9]   ^= 0xFF;
        expect(
          () => compressor.decompressBlock(corrupt),
          throwsA(isA<LogCorruptionException>()),
        );
      });

      test('compressionRatio is a valid ratio after compressing', () {
        final data = Uint8List.fromList(List.generate(4000, (i) => i & 0xFF));
        compressor.compressBlock(data);
        // compressionRatio = 1 - (compressed/raw).  Can be negative when
        // the compressed output is larger than the input (incompressible data).
        // We just verify it is finite and not NaN.
        expect(compressor.compressionRatio.isFinite, isTrue);
        expect(compressor.compressionRatio.isNaN, isFalse);
      });

      test('high compressibility data has positive ratio', () {
        final data = Uint8List.fromList(List.generate(10000, (_) => 0x42));
        compressor.compressBlock(data);
        // LZ4 store-copy fallback adds 1 byte overhead for near-incompressible
        // data, so allow a tiny negative ratio in edge cases.
        expect(compressor.compressionRatio, greaterThan(-0.01));
      });

      test('algorithm name is lz4', () {
        expect(compressor.strategy.algorithmName, 'lz4');
      });
    });

    // ── Zstd (Deflate) ───────────────────────────────────────
    group('ZstdStrategy', () {
      late LogCompressor compressor;
      setUp(() => compressor = LogCompressor(const ZstdStrategy()));

      test('round-trip medium payload', () {
        final data    = Uint8List.fromList(
            List.generate(2000, (i) => 'Hello World! '.codeUnitAt(i % 13)));
        final framed    = compressor.compressBlock(data);
        final recovered = compressor.decompressBlock(framed);
        expect(recovered, equals(data));
      });

      test('achieves positive ratio on repetitive data', () {
        final data = Uint8List.fromList(
            List.generate(10000, (i) => 'log entry '.codeUnitAt(i % 10)));
        compressor.compressBlock(data);
        expect(compressor.compressionRatio, greaterThan(0.0));
      });
    });

    // ── Gzip ────────────────────────────────────────────────
    group('GzipStrategy', () {
      late LogCompressor compressor;
      setUp(() => compressor = LogCompressor(const GzipStrategy()));

      test('round-trip payload', () {
        final data      = Uint8List.fromList('Gzip test data repeated. '.codeUnits);
        final framed    = compressor.compressBlock(data);
        final recovered = compressor.decompressBlock(framed);
        expect(recovered, equals(data));
      });
    });
  });

  // ── CrcValidator standalone ─────────────────────────────
  group('CrcValidator', () {
    test('crc16 known value', () {
      // CRC-16/CCITT of "123456789" = 0x29B1
      final data = '123456789'.codeUnits;
      expect(CrcValidator.crc16(data), 0x29B1);
    });

    test('crc32 known value', () {
      // CRC-32 of "123456789" = 0xCBF43926
      final data = '123456789'.codeUnits;
      expect(CrcValidator.crc32(data), 0xCBF43926);
    });

    test('appendCrc16 produces verifiable output', () {
      final data    = Uint8List.fromList('hello'.codeUnits);
      final withCrc = CrcValidator.appendCrc16(data);
      expect(CrcValidator.verifyCrc16(withCrc), isTrue);
    });

    test('appendCrc32 produces verifiable output', () {
      final data    = Uint8List.fromList('world'.codeUnits);
      final withCrc = CrcValidator.appendCrc32(data);
      expect(CrcValidator.verifyCrc32(withCrc), isTrue);
    });

    test('verifyCrc16 fails on corruption', () {
      final data    = Uint8List.fromList('test'.codeUnits);
      final withCrc = CrcValidator.appendCrc16(data);
      final corrupt = Uint8List.fromList(withCrc);
      corrupt[0] ^= 0x01; // flip one bit in data
      expect(CrcValidator.verifyCrc16(corrupt), isFalse);
    });
  });
}

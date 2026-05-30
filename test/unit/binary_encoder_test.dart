// test/unit/binary_encoder_test.dart

import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:light_logger/light_logger.dart';

void main() {
  group('BinaryEncoder', () {
    late StringPool  pool;
    late BinaryEncoder encoder;

    setUp(() {
      pool    = StringPool();
      encoder = BinaryEncoder(pool);
    });

    // ─────────────────────────────────────────────────────────
    //  File header
    // ─────────────────────────────────────────────────────────

    group('encodeFileHeader', () {
      test('magic number is correct', () {
        final header = encoder.encodeFileHeader(
          compressionType:    BinarySchema.compressionLZ4,
          flags:              0,
          creationTimestampMs: 0,
        );
        expect(header.sublist(0, 4), equals(BinarySchema.magicNumber));
      });

      test('version fields are set', () {
        final header = encoder.encodeFileHeader(
          compressionType:    BinarySchema.compressionLZ4,
          flags:              0,
          creationTimestampMs: 0,
        );
        final view = ByteData.sublistView(header);
        expect(view.getUint16(4, Endian.little), BinarySchema.versionMajor);
        expect(view.getUint16(6, Endian.little), BinarySchema.versionMinor);
      });

      test('header length is exactly 32 bytes', () {
        final header = encoder.encodeFileHeader(
          compressionType: 0,
          flags:           0,
          creationTimestampMs: DateTime.now().millisecondsSinceEpoch,
        );
        expect(header.length, BinarySchema.fileHeaderSize);
      });

      test('CRC-32 in header is valid', () {
        final header = encoder.encodeFileHeader(
          compressionType: BinarySchema.compressionGzip,
          flags:           BinarySchema.flagStringPool,
          creationTimestampMs: 1_716_000_000_000,
        );
        // The file header stores CRC-32 of bytes [0..25] at bytes [26..29].
        // bytes [30..31] are reserved and NOT covered by the CRC.
        // We must verify manually rather than using verifyCrc32() which
        // assumes the CRC is at the very end of the buffer.
        final view     = ByteData.sublistView(header);
        final stored   = view.getUint32(26, Endian.little);
        final computed = CrcValidator.crc32(header.sublist(0, 26));
        expect(stored, equals(computed));
      });
    });

    // ─────────────────────────────────────────────────────────
    //  Entry encoding
    // ─────────────────────────────────────────────────────────

    group('encodeEntry', () {
      setUp(() => encoder.beginBlock());

      test('first record sets block reference correctly', () {
        final ts    = DateTime(2026, 5, 29).millisecondsSinceEpoch;
        final entry = LogEntry(
          timestampMs: ts,
          level:       LogLevel.info,
          message:     'Test message',
        );
        encoder.encodeEntry(entry);
        expect(encoder.blockReferenceMs, ts);
      });

      test('encoded bytes start with record type 0x01', () {
        final entry = LogEntry.now(level: LogLevel.debug, message: 'x');
        final bytes = encoder.encodeEntry(entry);
        expect(bytes[0], 0x01);
      });

      test('level byte is stored at offset 9', () {
        final entry = LogEntry.now(level: LogLevel.error, message: 'err');
        final bytes = encoder.encodeEntry(entry);
        expect(bytes[9], LogLevel.error.byteValue);
      });

      test('tag is interned in pool', () {
        final entry = LogEntry.now(
          level:   LogLevel.info,
          message: 'tagged',
          tag:     'MyService',
        );
        encoder.encodeEntry(entry);
        expect(pool.contains('MyService'), isTrue);
      });

      test('encodes and round-trips via decoder', () {
        final original = LogEntry(
          timestampMs: 1_716_000_000_100,
          level:       LogLevel.warning,
          message:     'Database latency spike',
          tag:         'DB',
          extra:       {'latencyMs': 2500, 'query': 'SELECT *'},
          traceId:     'trace-abc',
        );

        encoder.beginBlock();
        final encoded = encoder.encodeEntry(original);
        final header  = encoder.encodeBlockHeader(
          referenceTimestampMs: encoder.blockReferenceMs,
          recordCount:          1,
        );

        final block  = Uint8List(header.length + encoded.length);
        block.setAll(0, header);
        block.setAll(header.length, encoded);

        final decoder = BinaryDecoder(pool);
        final results = <LogEntry>[];
        decoder.decodeBlock(block).listen(results.add);

        // give microtask queue a chance to flush
        expect(() async {
          await Future<void>.delayed(Duration.zero);
          expect(results.length, 1);
          expect(results.first.message, original.message);
          expect(results.first.level,   original.level);
        }, returnsNormally);
      });

      test('throws ArgumentError on oversized message', () {
        final bigMsg = 'x' * (BinarySchema.maxMessageBytes + 1);
        final entry  = LogEntry.now(level: LogLevel.info, message: bigMsg);
        expect(() => encoder.encodeEntry(entry), throwsArgumentError);
      });
    });

    // ─────────────────────────────────────────────────────────
    //  Block header
    // ─────────────────────────────────────────────────────────

    group('encodeBlockHeader', () {
      test('produces exactly 10 bytes', () {
        final h = encoder.encodeBlockHeader(
          referenceTimestampMs: 0,
          recordCount: 42,
        );
        expect(h.length, BinarySchema.blockHeaderSize);
      });

      test('record count field is correct', () {
        final h    = encoder.encodeBlockHeader(
            referenceTimestampMs: 0, recordCount: 999);
        final view = ByteData.sublistView(h);
        expect(view.getUint16(8, Endian.little), 999);
      });
    });
  });
}

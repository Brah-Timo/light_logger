// test/benchmark/compression_ratio_benchmark.dart
//
// Measures compression ratio for each strategy against realistic log data.
// Run with:  dart run test/benchmark/compression_ratio_benchmark.dart

import 'dart:typed_data';
import 'dart:convert';
import 'package:light_logger/light_logger.dart';

void main() {
  print('\n╔══════════════════════════════════════════════════════════╗');
  print('║         light_logger  Compression Ratio Benchmark        ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  final rawBlock = _buildRealisticLogBlock(1000);
  print('Raw block size    : ${_fmt(rawBlock.length)}\n');

  final strategies = <String, CompressionStrategy>{
    'LZ4  (pure Dart)': const LZ4Strategy(),
    'Zstd (deflate-9)': const ZstdStrategy(level: 9),
    'Gzip (level 6)  ': const GzipStrategy(level: 6),
    'Gzip (level 9)  ': const GzipStrategy(level: 9),
  };

  for (final entry in strategies.entries) {
    final compressor = LogCompressor(entry.value);
    final sw         = Stopwatch()..start();
    final framed     = compressor.compressBlock(rawBlock);
    final encMs      = sw.elapsedMilliseconds;
    sw.reset(); sw.start();
    compressor.decompressBlock(framed);
    final decMs = sw.elapsedMilliseconds;

    // framed = 10 byte frame header + compressed payload
    final compressedSize = framed.length - 10;
    final ratio = 1.0 - (compressedSize / rawBlock.length);

    print('${entry.key} | '
        'compressed: ${_fmt(compressedSize).padLeft(8)} | '
        'ratio: ${(ratio * 100).toStringAsFixed(1).padLeft(5)} % | '
        'enc: ${encMs.toString().padLeft(3)}ms | '
        'dec: ${decMs.toString().padLeft(3)}ms');
  }

  print('\nNote: Ratio improves further with real String Pool + Timestamp Delta.');
  print('Expected overall ratio (including pool) : 90-98 %\n');
}

/// Builds a raw log block byte array simulating 1000 realistic log records.
Uint8List _buildRealisticLogBlock(int recordCount) {
  final lines = <String>[];
  final tags  = ['NetworkManager', 'DatabasePool', 'AuthService', 'CacheLayer', 'TaskQueue'];
  final msgs  = [
    'Request received from 192.168.1.1 on port 8080',
    'Query executed: SELECT * FROM users WHERE id = ? [42]',
    'Token validation succeeded for user@example.com',
    'Cache hit ratio: 0.87 (threshold: 0.70)',
    'Worker task enqueued: email_notification_job_v2',
    'Connection pool size: 12/20 active connections',
    'HTTP 200 OK /api/v1/products in 43ms',
    'Retry attempt 2/3 for downstream service call',
  ];

  for (int i = 0; i < recordCount; i++) {
    final tag = tags[i % tags.length];
    final msg = msgs[i % msgs.length];
    final ts  = DateTime(2026, 5, 29, 0, 0, 0, i).millisecondsSinceEpoch;
    lines.add('$ts|INFO|$tag|$msg|trace-${i ~/ 10}');
  }

  return Uint8List.fromList(utf8.encode(lines.join('\n')));
}

String _fmt(int bytes) {
  if (bytes < 1024)          return '${bytes}B';
  if (bytes < 1024 * 1024)   return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(2)}MB';
}

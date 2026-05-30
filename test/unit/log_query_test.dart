// test/unit/log_query_test.dart

import 'package:test/test.dart';
import 'package:light_logger/light_logger.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Fake reader for testing without touching the filesystem
// ─────────────────────────────────────────────────────────────────────────────

class _FakeLogReader extends LogReader {
  final List<LogEntry> entries;
  const _FakeLogReader(this.entries);

  @override
  Stream<LogEntry> readAll(String logDirectory) => Stream.fromIterable(entries);

  @override
  Stream<LogEntry> readFile(String filePath) => Stream.fromIterable(entries);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Fixtures
// ─────────────────────────────────────────────────────────────────────────────

final _baseMs = DateTime(2026, 5, 29).millisecondsSinceEpoch;

List<LogEntry> _fixtures() => [
      LogEntry(timestampMs: _baseMs + 0,      level: LogLevel.verbose, message: 'boot start',      tag: 'Boot'),
      LogEntry(timestampMs: _baseMs + 1000,   level: LogLevel.debug,   message: 'config loaded',   tag: 'Config'),
      LogEntry(timestampMs: _baseMs + 2000,   level: LogLevel.info,    message: 'server started',  tag: 'Server'),
      LogEntry(timestampMs: _baseMs + 3000,   level: LogLevel.warning, message: 'cache miss rate', tag: 'Cache'),
      LogEntry(timestampMs: _baseMs + 4000,   level: LogLevel.error,   message: 'db timeout',      tag: 'Database', traceId: 'req-001'),
      LogEntry(timestampMs: _baseMs + 5000,   level: LogLevel.error,   message: 'db retry',        tag: 'Database', traceId: 'req-001'),
      LogEntry(timestampMs: _baseMs + 6000,   level: LogLevel.fatal,   message: 'oom killer',      tag: 'Worker'),
      LogEntry(timestampMs: _baseMs + 7000,   level: LogLevel.info,    message: 'reconnected',     tag: 'Database'),
    ];

// ─────────────────────────────────────────────────────────────────────────────
//  Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  late List<LogEntry> fixtures;

  setUp(() => fixtures = _fixtures());

  LogQuery query() =>
      LogQuery(_FakeLogReader(fixtures), '/fake');

  // ── whereLevel ──────────────────────────────────────────
  group('whereLevel', () {
    test('filters below min', () async {
      final results = await query().whereLevel(LogLevel.warning).toList();
      expect(results.every((e) => e.level.isAtLeast(LogLevel.warning)), isTrue);
      expect(results.length, 4); // warning + error×2 + fatal
    });

    test('range filter (min + max)', () async {
      final results = await query()
          .whereLevel(LogLevel.info, max: LogLevel.warning)
          .toList();
      expect(
        results.every((e) =>
            e.level.byteValue >= LogLevel.info.byteValue &&
            e.level.byteValue <= LogLevel.warning.byteValue),
        isTrue,
      );
    });
  });

  // ── whereTag ────────────────────────────────────────────
  group('whereTag', () {
    test('exact tag match', () async {
      final results = await query().whereTag('Database').toList();
      expect(results.length, 3); // db timeout, db retry, reconnected
      expect(results.every((e) => e.tag == 'Database'), isTrue);
    });

    test('unknown tag returns empty', () async {
      final results = await query().whereTag('Unknown').toList();
      expect(results, isEmpty);
    });
  });

  // ── whereText ───────────────────────────────────────────
  group('whereText', () {
    test('case-insensitive substring match', () async {
      final results = await query().whereText('DB').toList();
      expect(results.length, greaterThan(0));
      expect(
        results.every((e) => e.message.toLowerCase().contains('db')),
        isTrue,
      );
    });

    test('no match returns empty', () async {
      final results = await query().whereText('xyzzy123').toList();
      expect(results, isEmpty);
    });
  });

  // ── whereTime ───────────────────────────────────────────
  group('whereTime', () {
    test('from filter', () async {
      final from    = DateTime.fromMillisecondsSinceEpoch(_baseMs + 4000);
      final results = await query().whereTime(from: from).toList();
      expect(results.every((e) => e.timestampMs >= _baseMs + 4000), isTrue);
    });

    test('to filter', () async {
      final to      = DateTime.fromMillisecondsSinceEpoch(_baseMs + 2000);
      final results = await query().whereTime(to: to).toList();
      expect(results.every((e) => e.timestampMs <= _baseMs + 2000), isTrue);
    });

    test('window filter', () async {
      final from    = DateTime.fromMillisecondsSinceEpoch(_baseMs + 1000);
      final to      = DateTime.fromMillisecondsSinceEpoch(_baseMs + 3000);
      final results = await query().whereTime(from: from, to: to).toList();
      expect(results.length, 3); // debug, info, warning
    });
  });

  // ── whereTraceId ────────────────────────────────────────
  group('whereTraceId', () {
    test('returns entries for trace', () async {
      final results = await query().whereTraceId('req-001').toList();
      expect(results.length, 2);
      expect(results.every((e) => e.traceId == 'req-001'), isTrue);
    });
  });

  // ── limit / skip ────────────────────────────────────────
  group('limit and skip', () {
    test('limit returns at most N entries', () async {
      final results = await query().limit(3).toList();
      expect(results.length, 3);
    });

    test('skip skips first N entries', () async {
      final all     = await query().toList();
      final skipped = await query().skip(2).toList();
      expect(skipped.length, all.length - 2);
      expect(skipped.first, all[2]);
    });

    test('limit + skip combined', () async {
      final results = await query().skip(2).limit(2).toList();
      expect(results.length, 2);
    });
  });

  // ── count ───────────────────────────────────────────────
  group('count', () {
    test('returns correct count without loading into list', () async {
      // whereLevel(error) includes error AND fatal (both >= error severity)
      // fixtures: error×2 + fatal×1 = 3
      final c = await query().whereLevel(LogLevel.error).count();
      expect(c, 3);
    });

    test('exact-level count with max bound', () async {
      // Only error entries, not fatal
      final c = await query()
          .whereLevel(LogLevel.error, max: LogLevel.error)
          .count();
      expect(c, 2);
    });
  });

  // ── Regex ───────────────────────────────────────────────
  group('whereRegex', () {
    test('matches regex pattern', () async {
      final results = await query().whereRegex(r'db\s+\w+').toList();
      expect(results.length, greaterThan(0));
    });
  });
}

// lib/src/reader/log_query.dart
//
// Fluent builder API for filtering log entries.
//
// All filtering is applied at the stream level — entries that don't match
// are never stored in memory.  This makes LogQuery efficient even on
// files that contain millions of records.
//
// Usage:
//
//   final entries = await LogQuery(reader, '/logs')
//       .whereLevel(LogLevel.error)
//       .whereTime(from: DateTime.now().subtract(Duration(hours: 1)))
//       .whereTag('NetworkService')
//       .whereText('timeout')
//       .limit(50)
//       .toList();

import 'dart:async';
import '../core/log_entry.dart';
import '../core/log_level.dart';
import 'log_reader.dart';

/// Fluent query builder over a set of .llog files.
///
/// Every call to a `where*` method returns `this`, enabling chaining.
/// Call [execute] or [toList] to materialise results.
final class LogQuery {
  // ─────────────────────────────────────────────────────────
  //  Dependencies
  // ─────────────────────────────────────────────────────────

  final LogReader _reader;
  final String    _logDirectory;

  // ─────────────────────────────────────────────────────────
  //  Filters (null = no filter applied)
  // ─────────────────────────────────────────────────────────

  LogLevel? _minLevel;
  LogLevel? _maxLevel;
  DateTime? _from;
  DateTime? _to;
  String?   _tag;
  String?   _searchText;          // case-insensitive substring
  String?   _regexPattern;        // full regex search on message
  String?   _traceId;
  int?      _limit;
  int?      _offset;              // skip first N matching entries
  // _reverseOrder is reserved for future descending-order support

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  LogQuery(this._reader, this._logDirectory);

  // ─────────────────────────────────────────────────────────
  //  Filter builders
  // ─────────────────────────────────────────────────────────

  /// Only include entries with level >= [min] (and optionally <= [max]).
  LogQuery whereLevel(LogLevel min, {LogLevel? max}) {
    _minLevel = min;
    _maxLevel = max;
    return this;
  }

  /// Only include entries within the time window [from]..[to].
  ///
  /// Both bounds are inclusive.  Pass `null` to leave that bound open.
  LogQuery whereTime({DateTime? from, DateTime? to}) {
    _from = from;
    _to   = to;
    return this;
  }

  /// Only include entries whose [LogEntry.tag] exactly matches [tag].
  LogQuery whereTag(String tag) {
    _tag = tag;
    return this;
  }

  /// Only include entries whose message contains [text] (case-insensitive).
  LogQuery whereText(String text) {
    _searchText = text.toLowerCase();
    return this;
  }

  /// Only include entries whose message matches [pattern] (full Dart regex).
  LogQuery whereRegex(String pattern) {
    _regexPattern = pattern;
    return this;
  }

  /// Only include entries with a matching [LogEntry.traceId].
  LogQuery whereTraceId(String traceId) {
    _traceId = traceId;
    return this;
  }

  /// Stop after returning [count] matching entries.
  LogQuery limit(int count) {
    assert(count > 0, 'limit must be positive');
    _limit = count;
    return this;
  }

  /// Skip the first [count] matching entries.
  LogQuery skip(int count) {
    assert(count >= 0, 'skip must be >= 0');
    _offset = count;
    return this;
  }

  // ─────────────────────────────────────────────────────────
  //  Execution
  // ─────────────────────────────────────────────────────────

  /// Returns a lazy stream of matching [LogEntry] objects.
  ///
  /// Entries are emitted in file order (oldest first) by default.
  Stream<LogEntry> execute() async* {
    final regex = _regexPattern != null
        ? RegExp(_regexPattern!, caseSensitive: false)
        : null;

    int skipped = 0;
    int yielded = 0;

    await for (final entry in _reader.readAll(_logDirectory)) {
      if (_limit != null && yielded >= _limit!) break;
      if (!_matches(entry, regex)) continue;

      if (_offset != null && skipped < _offset!) {
        skipped++;
        continue;
      }

      yield entry;
      yielded++;
    }
  }

  /// Collects all matching entries into a [List].
  ///
  /// ⚠️ Use [execute] with `await for` for very large result sets to avoid
  /// loading everything into memory.
  Future<List<LogEntry>> toList() => execute().toList();

  /// Returns the number of matching entries without loading them.
  Future<int> count() async {
    int n = 0;
    await execute().forEach((_) => n++);
    return n;
  }

  /// Returns the first matching entry, or `null` if none found.
  Future<LogEntry?> first() async {
    await for (final entry in execute()) {
      return entry;
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────
  //  Match predicate
  // ─────────────────────────────────────────────────────────

  bool _matches(LogEntry entry, RegExp? regex) {
    // Level range
    if (_minLevel != null &&
        entry.level.byteValue < _minLevel!.byteValue) return false;
    if (_maxLevel != null &&
        entry.level.byteValue > _maxLevel!.byteValue) return false;

    // Time range
    if (_from != null &&
        entry.timestampMs < _from!.millisecondsSinceEpoch) return false;
    if (_to != null &&
        entry.timestampMs > _to!.millisecondsSinceEpoch) return false;

    // Tag
    if (_tag != null && entry.tag != _tag) return false;

    // TraceId
    if (_traceId != null && entry.traceId != _traceId) return false;

    // Text search
    if (_searchText != null &&
        !entry.message.toLowerCase().contains(_searchText!)) return false;

    // Regex search
    if (regex != null && !regex.hasMatch(entry.message)) return false;

    return true;
  }
}



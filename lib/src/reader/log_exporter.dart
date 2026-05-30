// lib/src/reader/log_exporter.dart
//
// Exports log entries to human-readable formats.
//
// Supported outputs:
//   • JSON Lines  (.jsonl) — one JSON object per line
//   • JSON Array  (.json)  — a single top-level array
//   • CSV         (.csv)   — spreadsheet-friendly
//   • Plain text  (.txt)   — one line per entry, console-style
//
// All methods accept a [Stream<LogEntry>] so they compose naturally with
// [LogQuery.execute()]:
//
//   await LogExporter.toJsonLinesFile(
//     source: query.execute(),
//     outputPath: '/tmp/errors.jsonl',
//   );

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../core/log_entry.dart';
import '../core/log_level.dart';

/// Utilities for exporting log entries to plain-text formats.
abstract final class LogExporter {
  LogExporter._();

  // ─────────────────────────────────────────────────────────
  //  JSON Lines  (one JSON object per line)
  // ─────────────────────────────────────────────────────────

  /// Exports all entries from [source] as JSON Lines to [outputPath].
  ///
  /// Each line is a complete JSON object matching [LogEntry.toJson].
  static Future<int> toJsonLinesFile({
    required Stream<LogEntry> source,
    required String outputPath,
  }) async {
    final sink  = File(outputPath).openWrite(mode: FileMode.writeOnly);
    int   count = 0;
    try {
      await for (final entry in source) {
        sink.writeln(jsonEncode(entry.toJson()));
        count++;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return count;
  }

  /// Returns a JSON Lines string for [entries] (in-memory convenience).
  static String toJsonLinesString(Iterable<LogEntry> entries) {
    return entries.map((e) => jsonEncode(e.toJson())).join('\n');
  }

  // ─────────────────────────────────────────────────────────
  //  JSON Array
  // ─────────────────────────────────────────────────────────

  /// Exports all entries from [source] as a JSON array to [outputPath].
  ///
  /// ⚠️ Loads all entries into memory — use only for small result sets.
  static Future<int> toJsonArrayFile({
    required Stream<LogEntry> source,
    required String outputPath,
    bool pretty = false,
  }) async {
    final entries = await source.toList();
    final list    = entries.map((e) => e.toJson()).toList();
    final content = pretty
        ? const JsonEncoder.withIndent('  ').convert(list)
        : jsonEncode(list);
    await File(outputPath).writeAsString(content);
    return entries.length;
  }

  /// Returns a JSON array string (in-memory convenience).
  static String toJsonArrayString(
    Iterable<LogEntry> entries, {
    bool pretty = false,
  }) {
    final list = entries.map((e) => e.toJson()).toList();
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(list)
        : jsonEncode(list);
  }

  // ─────────────────────────────────────────────────────────
  //  CSV
  // ─────────────────────────────────────────────────────────

  static const _csvHeader =
      'timestamp_iso,timestamp_ms,level,tag,message,trace_id,source_file,source_line';

  /// Exports all entries from [source] as CSV to [outputPath].
  static Future<int> toCsvFile({
    required Stream<LogEntry> source,
    required String outputPath,
  }) async {
    final sink  = File(outputPath).openWrite(mode: FileMode.writeOnly);
    int   count = 0;
    try {
      sink.writeln(_csvHeader);
      await for (final entry in source) {
        sink.writeln(_entryToCsvLine(entry));
        count++;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return count;
  }

  /// Returns a CSV string (in-memory convenience, includes header row).
  static String toCsvString(Iterable<LogEntry> entries) {
    final buf = StringBuffer(_csvHeader);
    buf.writeln();
    for (final e in entries) {
      buf.writeln(_entryToCsvLine(e));
    }
    return buf.toString();
  }

  static String _entryToCsvLine(LogEntry e) {
    final ts   = e.timestamp.toIso8601String();
    final msg  = _csvEscape(e.message);
    final tag  = _csvEscape(e.tag ?? '');
    final tid  = _csvEscape(e.traceId ?? '');
    final sf   = _csvEscape(e.sourceFile ?? '');
    final sl   = e.sourceLine?.toString() ?? '';
    return '$ts,${e.timestampMs},${e.level.label},$tag,$msg,$tid,$sf,$sl';
  }

  static String _csvEscape(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  // ─────────────────────────────────────────────────────────
  //  Plain text
  // ─────────────────────────────────────────────────────────

  /// Exports all entries from [source] as plain text to [outputPath].
  ///
  /// Format: `2026-05-29T14:32:01.123Z WARNING [NetworkService] Connection timeout`
  static Future<int> toTextFile({
    required Stream<LogEntry> source,
    required String outputPath,
    bool colorCodes = false,
  }) async {
    final sink  = File(outputPath).openWrite(mode: FileMode.writeOnly);
    int   count = 0;
    try {
      await for (final entry in source) {
        sink.writeln(_entryToTextLine(entry, colorCodes: colorCodes));
        count++;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return count;
  }

  /// Returns a single formatted line for the given entry.
  static String formatEntry(LogEntry entry, {bool colorCodes = false}) =>
      _entryToTextLine(entry, colorCodes: colorCodes);

  static String _entryToTextLine(LogEntry entry, {bool colorCodes = false}) {
    final time   = entry.timestamp.toIso8601String();
    final level  = entry.level.paddedLabel;
    final tag    = entry.tag != null ? ' [${entry.tag}]' : '';
    final line   = '$time $level$tag ${entry.message}';

    if (!colorCodes) return line;

    final color = switch (entry.level) {
      LogLevel.verbose => '\x1B[37m', // white
      LogLevel.debug   => '\x1B[36m', // cyan
      LogLevel.info    => '\x1B[32m', // green
      LogLevel.warning => '\x1B[33m', // yellow
      LogLevel.error   => '\x1B[31m', // red
      LogLevel.fatal   => '\x1B[35m', // magenta
    };
    return '$color$line\x1B[0m';
  }

  // ─────────────────────────────────────────────────────────
  //  Stats summary
  // ─────────────────────────────────────────────────────────

  /// Counts entries per level from [entries] and returns a readable summary.
  static Map<LogLevel, int> countByLevel(Iterable<LogEntry> entries) {
    final counts = {for (final l in LogLevel.values) l: 0};
    for (final e in entries) {
      counts[e.level] = (counts[e.level] ?? 0) + 1;
    }
    return Map.unmodifiable(counts);
  }
}

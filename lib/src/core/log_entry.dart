// lib/src/core/log_entry.dart
//
// Defines the canonical in-memory representation of one log record.
//
// A LogEntry is the unit of currency that flows through the entire
// light_logger pipeline:
//
//   LightLogger.info(…)
//     → LogEntry.now(…)          ← constructed here
//     → LogBuffer.add(entry)
//     → BinaryEncoder.encodeEntry(entry)
//     → LogCompressor.compressBlock(bytes)
//     → AsyncWriter._onBlockReceived(compressed)
//     → File on disk
//
// On read-back the flow is reversed via BinaryDecoder → LogEntry.

import 'package:meta/meta.dart';
import 'log_level.dart';

/// Immutable snapshot of a single log event.
///
/// All timestamps are stored as **milliseconds since the Unix epoch** (int64)
/// to avoid repeated string parsing and to keep the binary footprint minimal
/// (8 bytes vs. the 23 bytes of an ISO-8601 string).
@immutable
final class LogEntry {
  // ─────────────────────────────────────────────────────────
  //  Core fields
  // ─────────────────────────────────────────────────────────

  /// Wall-clock time of the event in milliseconds since Unix epoch.
  ///
  /// Stored as int64 little-endian in the binary format → 8 bytes.
  final int timestampMs;

  /// Severity level of the event.
  ///
  /// Stored as a single byte in the binary format → 1 byte.
  final LogLevel level;

  /// Primary human-readable description of the event.
  ///
  /// Length is stored as uint16 (max 65 535 chars) then followed by the
  /// UTF-8 encoded content.
  final String message;

  // ─────────────────────────────────────────────────────────
  //  Optional / enrichment fields
  // ─────────────────────────────────────────────────────────

  /// Module or component that emitted this entry (e.g. `'NetworkService'`).
  ///
  /// Interned into the file-level String Pool so repetitions cost only
  /// 2 bytes (uint16 pool index) instead of the full string length.
  final String? tag;

  /// Arbitrary structured metadata serialised as key-value pairs.
  ///
  /// Encoded as a compact binary map (similar to MessagePack) appended after
  /// the message bytes.  Null if no extra data was provided.
  final Map<String, dynamic>? extra;

  /// Correlation / distributed-tracing identifier.
  ///
  /// Useful for linking all log entries that belong to a single request or
  /// transaction.  Also interned in the String Pool.
  final String? traceId;

  /// Source file name (without path) where this entry was created.
  final String? sourceFile;

  /// Line number inside [sourceFile] — set only when
  /// [LogConfig.includeSourceInfo] is `true`.
  final int? sourceLine;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  const LogEntry({
    required this.timestampMs,
    required this.level,
    required this.message,
    this.tag,
    this.extra,
    this.traceId,
    this.sourceFile,
    this.sourceLine,
  });

  // ─────────────────────────────────────────────────────────
  //  Factory helpers
  // ─────────────────────────────────────────────────────────

  /// Creates a [LogEntry] stamped with the current wall-clock time.
  factory LogEntry.now({
    required LogLevel level,
    required String message,
    String? tag,
    Map<String, dynamic>? extra,
    String? traceId,
    String? sourceFile,
    int? sourceLine,
  }) {
    return LogEntry(
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      level: level,
      message: message,
      tag: tag,
      extra: extra,
      traceId: traceId,
      sourceFile: sourceFile,
      sourceLine: sourceLine,
    );
  }

  /// Creates a copy of this entry with selected fields overridden.
  LogEntry copyWith({
    int? timestampMs,
    LogLevel? level,
    String? message,
    String? tag,
    Map<String, dynamic>? extra,
    String? traceId,
    String? sourceFile,
    int? sourceLine,
  }) {
    return LogEntry(
      timestampMs: timestampMs ?? this.timestampMs,
      level: level ?? this.level,
      message: message ?? this.message,
      tag: tag ?? this.tag,
      extra: extra ?? this.extra,
      traceId: traceId ?? this.traceId,
      sourceFile: sourceFile ?? this.sourceFile,
      sourceLine: sourceLine ?? this.sourceLine,
    );
  }

  // ─────────────────────────────────────────────────────────
  //  Derived properties
  // ─────────────────────────────────────────────────────────

  /// The event time as a [DateTime] object (UTC).
  DateTime get timestamp =>
      DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);

  /// Conservative estimate of in-memory size in bytes.
  ///
  /// Used by [LogBuffer] to decide when to flush without waiting for the
  /// record count threshold.
  int get estimatedSizeBytes {
    int size = 8;  // timestamp  (int64)
    size += 1;     // level      (uint8)
    size += 2 + (message.length * 3); // length prefix + worst-case UTF-8
    if (tag != null) size += 2 + tag!.length;
    if (traceId != null) size += 2 + traceId!.length;
    if (sourceFile != null) size += 2 + sourceFile!.length;
    size += 4;     // sourceLine (int32)
    // Extra: rough estimate — 32 bytes per key-value pair
    if (extra != null) size += extra!.length * 32;
    return size;
  }

  // ─────────────────────────────────────────────────────────
  //  Serialisation helpers (plain text / debug)
  // ─────────────────────────────────────────────────────────

  /// Converts the entry to a [Map] suitable for JSON serialisation.
  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.toIso8601String(),
      'timestampMs': timestampMs,
      'level': level.label,
      if (tag != null) 'tag': tag,
      'message': message,
      if (extra != null) 'extra': extra,
      if (traceId != null) 'traceId': traceId,
      if (sourceFile != null) 'sourceFile': sourceFile,
      if (sourceLine != null) 'sourceLine': sourceLine,
    };
  }

  /// Returns a single-line human-readable representation.
  @override
  String toString() {
    final time = timestamp.toIso8601String();
    final levelStr = level.paddedLabel;
    final tagStr = tag != null ? ' [${tag!}]' : '';
    return '$time $levelStr$tagStr $message';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogEntry &&
          runtimeType == other.runtimeType &&
          timestampMs == other.timestampMs &&
          level == other.level &&
          message == other.message &&
          tag == other.tag &&
          traceId == other.traceId;

  @override
  int get hashCode =>
      Object.hash(timestampMs, level, message, tag, traceId);
}

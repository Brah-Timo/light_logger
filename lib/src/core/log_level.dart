// lib/src/core/log_level.dart
//
// Defines every log severity level supported by light_logger.
//
// Each level is stored as a single byte (byteValue) inside the binary log
// file, saving ~85 % space versus storing the label string.
// The numeric values are intentionally gapped to allow future insertion of
// intermediate levels without breaking existing binary files.

/// All severity levels supported by light_logger.
///
/// Levels are ordered from least to most severe.  Only entries whose level
/// is >= [LogConfig.minimumLevel] are actually written to disk.
enum LogLevel {
  /// Extremely detailed diagnostic information – spammy by nature.
  /// Intended for development / tracing; disable in production.
  verbose(0x01, 'VERBOSE'),

  /// Developer-oriented debug information.
  debug(0x02, 'DEBUG'),

  /// Normal operational messages that track application progress.
  info(0x03, 'INFO'),

  /// Something unexpected happened but the application can continue.
  warning(0x04, 'WARNING'),

  /// A recoverable error occurred; the operation failed but the app lives on.
  error(0x05, 'ERROR'),

  /// A non-recoverable error; a subsystem may have crashed.
  fatal(0x06, 'FATAL');

  // ─────────────────────────────────────────────────────────
  //  Fields
  // ─────────────────────────────────────────────────────────

  /// The single byte written to / read from the binary log file.
  final int byteValue;

  /// Human-readable label used by the CLI viewer and console output.
  final String label;

  // ─────────────────────────────────────────────────────────
  //  Constructor
  // ─────────────────────────────────────────────────────────

  const LogLevel(this.byteValue, this.label);

  // ─────────────────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────────────────

  /// Reconstructs a [LogLevel] from its stored [byte].
  ///
  /// Falls back to [LogLevel.debug] if the byte is unrecognised (e.g. a
  /// future format written by a newer version of the package).
  static LogLevel fromByte(int byte) {
    return LogLevel.values.firstWhere(
      (level) => level.byteValue == byte,
      orElse: () => LogLevel.debug,
    );
  }

  /// Reconstructs a [LogLevel] from its [label] string (case-insensitive).
  ///
  /// Falls back to [LogLevel.info] on no match.
  static LogLevel fromLabel(String label) {
    final upper = label.toUpperCase().trim();
    return LogLevel.values.firstWhere(
      (level) => level.label == upper,
      orElse: () => LogLevel.info,
    );
  }

  /// Returns `true` when [this] is at least as severe as [other].
  bool isAtLeast(LogLevel other) => byteValue >= other.byteValue;

  /// Returns a fixed-width 7-character padded label suitable for aligned
  /// console / terminal output (e.g. `"WARNING"`).
  String get paddedLabel => label.padRight(7);

  @override
  String toString() => label;
}

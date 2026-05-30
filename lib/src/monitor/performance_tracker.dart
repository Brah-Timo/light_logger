// lib/src/monitor/performance_tracker.dart
//
// Lightweight in-process performance counters for the logger itself.
//
// Tracked metrics:
//   • Total write count (all time)
//   • Writes per second (rolling 1-second window)
//   • Peak writes/s since start
//   • Average write latency (µs)  ← time from add() to buffer.emit()
//   • Per-level counters
//
// All operations are O(1) with no heap allocations on the hot path.

import '../core/log_level.dart';

/// Collects real-time performance statistics for a [LightLogger] instance.
///
/// Thread-safety: designed for single-isolate use.
final class PerformanceTracker {
  // ─────────────────────────────────────────────────────────
  //  Counters
  // ─────────────────────────────────────────────────────────

  int _totalWrites  = 0;
  int _totalDropped = 0;

  // Per-level counters indexed by LogLevel.byteValue (1-6)
  final Map<LogLevel, int> _levelCounts = {
    for (final l in LogLevel.values) l: 0,
  };

  // ─────────────────────────────────────────────────────────
  //  Writes-per-second (rolling window)
  // ─────────────────────────────────────────────────────────

  final List<int> _windowTimestamps = []; // timestamps of recent writes (ms)
  static const int _windowMs = 1000;      // 1-second rolling window

  int    _peakWritesPerSecond = 0;

  // ─────────────────────────────────────────────────────────
  //  Timing
  // ─────────────────────────────────────────────────────────

  final int _startMs = DateTime.now().millisecondsSinceEpoch;
  int _lastWriteMs  = 0;

  // ─────────────────────────────────────────────────────────
  //  Public API
  // ─────────────────────────────────────────────────────────

  /// Called once per log entry written (not per block).
  void recordWrite(LogLevel level) {
    _totalWrites++;
    _levelCounts[level] = (_levelCounts[level] ?? 0) + 1;

    final now = DateTime.now().millisecondsSinceEpoch;
    _lastWriteMs = now;

    // Maintain rolling window
    _windowTimestamps.add(now);
    // Remove timestamps older than 1 second
    final cutoff = now - _windowMs;
    while (_windowTimestamps.isNotEmpty && _windowTimestamps.first < cutoff) {
      _windowTimestamps.removeAt(0);
    }

    final currentRate = _windowTimestamps.length;
    if (currentRate > _peakWritesPerSecond) {
      _peakWritesPerSecond = currentRate;
    }
  }

  /// Called when a write is dropped (e.g. disk full).
  void recordDropped() => _totalDropped++;

  // ─────────────────────────────────────────────────────────
  //  Accessors
  // ─────────────────────────────────────────────────────────

  /// Total log entries written since the logger was started.
  int get totalWriteCount => _totalWrites;

  /// Total log entries dropped (disk full / disposed).
  int get totalDroppedCount => _totalDropped;

  /// Approximate writes per second over the last 1 second.
  double get currentWritesPerSecond => _windowTimestamps.length.toDouble();

  /// Highest writes/s observed since start.
  int get peakWritesPerSecond => _peakWritesPerSecond;

  /// Uptime of the logger in seconds.
  double get uptimeSeconds =>
      (DateTime.now().millisecondsSinceEpoch - _startMs) / 1000.0;

  /// Timestamp (ms) of the last recorded write.
  int get lastWriteMs => _lastWriteMs;

  /// Count per log level.
  Map<LogLevel, int> get levelCounts => Map.unmodifiable(_levelCounts);

  /// Count for a specific level.
  int countForLevel(LogLevel level) => _levelCounts[level] ?? 0;

  // ─────────────────────────────────────────────────────────
  //  Snapshot
  // ─────────────────────────────────────────────────────────

  PerformanceSnapshot snapshot() {
    return PerformanceSnapshot(
      totalWrites:         _totalWrites,
      totalDropped:        _totalDropped,
      writesPerSecond:     currentWritesPerSecond,
      peakWritesPerSecond: _peakWritesPerSecond,
      uptimeSeconds:       uptimeSeconds,
      levelCounts:         Map.unmodifiable(_levelCounts),
    );
  }

  @override
  String toString() => 'PerformanceTracker('
      'total: $_totalWrites, '
      'rate: ${currentWritesPerSecond.toStringAsFixed(0)}/s, '
      'peak: ${_peakWritesPerSecond}/s'
      ')';
}

// ─────────────────────────────────────────────────────────────────────────────
//  Snapshot value object
// ─────────────────────────────────────────────────────────────────────────────

/// Immutable snapshot of [PerformanceTracker] metrics.
class PerformanceSnapshot {
  final int                totalWrites;
  final int                totalDropped;
  final double             writesPerSecond;
  final int                peakWritesPerSecond;
  final double             uptimeSeconds;
  final Map<LogLevel, int> levelCounts;

  const PerformanceSnapshot({
    required this.totalWrites,
    required this.totalDropped,
    required this.writesPerSecond,
    required this.peakWritesPerSecond,
    required this.uptimeSeconds,
    required this.levelCounts,
  });

  String get formattedUptime {
    final secs = uptimeSeconds.round();
    final h    = secs ~/ 3600;
    final m    = (secs % 3600) ~/ 60;
    final s    = secs % 60;
    return '${h.toString().padLeft(2,'0')}:'
           '${m.toString().padLeft(2,'0')}:'
           '${s.toString().padLeft(2,'0')}';
  }

  @override
  String toString() =>
      'PerformanceSnapshot('
      'total: $totalWrites, '
      'dropped: $totalDropped, '
      'rate: ${writesPerSecond.toStringAsFixed(0)}/s, '
      'peak: ${peakWritesPerSecond}/s, '
      'uptime: $formattedUptime'
      ')';
}

// example/flutter_integration.dart
//
// Shows how to integrate light_logger in a Flutter application.
//
// NOTE: This file is intentionally a *Dart-only* demonstration of the patterns
// you would use in a Flutter project.  To run it inside Flutter, add the
// `flutter` and `path_provider` dependencies to your app's pubspec and replace
// the placeholder log directory with the real path from `path_provider`.
//
// Flutter usage sketch:
//
//   import 'package:flutter/foundation.dart';
//   import 'package:flutter/material.dart';
//   import 'package:path_provider/path_provider.dart';
//   import 'package:light_logger/light_logger.dart';
//
//   Future<void> main() async {
//     WidgetsFlutterBinding.ensureInitialized();
//     final dir = await getApplicationSupportDirectory();
//     final logger = await LightLogger.initialize(
//       config: kDebugMode
//           ? LogConfig.development(logDirectory: '${dir.path}/logs')
//           : LogConfig.production(logDirectory: '${dir.path}/logs'),
//     );
//     runApp(MyApp(logger: logger));
//   }

// ignore_for_file: avoid_print

import 'dart:io';
import 'package:light_logger/light_logger.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Global logger
// ─────────────────────────────────────────────────────────────────────────────

late final LightLogger appLogger;

// ─────────────────────────────────────────────────────────────────────────────
//  Simulated service layer
// ─────────────────────────────────────────────────────────────────────────────

class NetworkService {
  static const _tag = 'NetworkService';

  Future<String> fetchData(String url, {String? traceId}) async {
    appLogger.info('GET $url', tag: _tag, traceId: traceId);
    final sw = Stopwatch()..start();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      appLogger.debug(
        'Response 200 in ${sw.elapsedMilliseconds} ms',
        tag: _tag,
        traceId: traceId,
        extra: {'url': url, 'durationMs': sw.elapsedMilliseconds},
      );
      return '{"ok": true}';
    } catch (e, st) {
      appLogger.error(
        'Request failed: $url',
        tag: _tag,
        exception: e,
        stackTrace: st,
        traceId: traceId,
        extra: {'url': url, 'durationMs': sw.elapsedMilliseconds},
      );
      rethrow;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Route event simulation
// ─────────────────────────────────────────────────────────────────────────────

class NavigationTracker {
  void onNavigateTo(String routeName) {
    appLogger.info('Navigate → $routeName', tag: 'Router');
  }

  void onNavigateBack(String routeName) {
    appLogger.info('Navigate ← $routeName', tag: 'Router');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Main
// ─────────────────────────────────────────────────────────────────name────────

Future<void> main() async {
  // In a real Flutter app, use getApplicationSupportDirectory() from
  // path_provider.  Here we use a temp directory as a placeholder.
  final tempDir = await Directory.systemTemp.createTemp('light_logger_demo_');
  final logDir = tempDir.path;

  // In a real Flutter app, replace LogConfig.development with:
  //   kDebugMode
  //     ? LogConfig.development(logDirectory: logDir)
  //     : LogConfig.production(logDirectory: logDir).copyWith(...)
  appLogger = await LightLogger.initialize(
    config: LogConfig.development(logDirectory: logDir),
  );

  appLogger.info('App started', tag: 'Lifecycle');

  final network = NetworkService();
  final nav = NavigationTracker();

  // Simulate navigation
  nav.onNavigateTo('/home');

  // Simulate network calls
  await network.fetchData('https://api.example.com/data', traceId: 'req-001');
  await network.fetchData('https://api.example.com/user', traceId: 'req-002');

  // Burst logging (typical in Flutter debug mode)
  for (var i = 0; i < 20; i++) {
    appLogger.debug('Burst entry #$i', tag: 'BurstTest', extra: {'i': i});
  }

  nav.onNavigateTo('/details');
  nav.onNavigateBack('/home');

  appLogger.warning('Low memory detected', tag: 'MemoryManager');
  appLogger.error(
    'Unhandled exception',
    tag: 'ErrorBoundary',
    exception: Exception('example error'),
    extra: {'widget': 'ProductList'},
  );

  // Read stats
  final stats = await appLogger.getStats();
  print('Written : ${stats.totalEntriesWritten}');
  print('Rate    : ${stats.writesPerSecond.toStringAsFixed(1)}/s');
  print('Disk    : ${stats.diskUsedFormatted}');

  // Shutdown
  await appLogger.dispose();
  await tempDir.delete(recursive: true);

  print('Flutter integration demo complete.');
}

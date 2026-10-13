// Direct unit tests for lib/logger.dart's `LoggerExtensions` — the
// debug/error/warn/trace alias methods are not exercised by
// mcp_bridge_test.dart (which only tests the standard package:logging
// API directly).

import 'package:mcp_bridge/logger.dart';
import 'package:test/test.dart';

void main() {
  group('LoggerExtensions', () {
    test('debug() emits at FINE level with the given message', () {
      final log = Logger.detached('test.ext.debug')..level = Level.ALL;
      final captured = <Level>[];
      final messages = <String>[];
      final sub = log.onRecord.listen((r) {
        captured.add(r.level);
        messages.add(r.message);
      });
      log.debug('hello debug');
      sub.cancel();
      expect(captured, equals([Level.FINE]));
      expect(messages, equals(['hello debug']));
    });

    test('error() emits at SEVERE level with the given message', () {
      final log = Logger.detached('test.ext.error')..level = Level.ALL;
      final captured = <Level>[];
      final sub = log.onRecord.listen((r) => captured.add(r.level));
      log.error('hello error');
      sub.cancel();
      expect(captured, equals([Level.SEVERE]));
    });

    test('warn() emits at WARNING level with the given message', () {
      final log = Logger.detached('test.ext.warn')..level = Level.ALL;
      final captured = <Level>[];
      final sub = log.onRecord.listen((r) => captured.add(r.level));
      log.warn('hello warn');
      sub.cancel();
      expect(captured, equals([Level.WARNING]));
    });

    test('trace() emits at FINEST level with the given message', () {
      final log = Logger.detached('test.ext.trace')..level = Level.ALL;
      final captured = <Level>[];
      final sub = log.onRecord.listen((r) => captured.add(r.level));
      log.trace('hello trace');
      sub.cancel();
      expect(captured, equals([Level.FINEST]));
    });
  });
}

// Direct unit tests for lib/src/transport/_byte_stream_framing.dart
// (ByteStreamFramer) covering the branches not exercised by
// frame_transparency_test.dart: malformed JSON -> onError, and blank
// / whitespace-only lines being silently skipped (not emitted as
// frames, not errored).

import 'dart:convert';

import 'package:mcp_bridge/src/transport/_byte_stream_framing.dart';
import 'package:test/test.dart';

void main() {
  group('ByteStreamFramer edge cases', () {
    test('malformed JSON in a frame routes to onError, not onFrame', () {
      final frames = <dynamic>[];
      final errors = <Object>[];
      final framer = ByteStreamFramer(
        onFrame: frames.add,
        onError: (e, st) => errors.add(e),
      );

      framer.feedBytes(utf8.encode('{not valid json\n'));

      expect(frames, isEmpty);
      expect(errors, hasLength(1));
      expect(errors.single, isA<FormatException>());
    });

    test('a malformed frame does not block subsequent valid frames', () {
      final frames = <dynamic>[];
      final errors = <Object>[];
      final framer = ByteStreamFramer(
        onFrame: frames.add,
        onError: (e, st) => errors.add(e),
      );

      framer.feedBytes(utf8.encode('{bad\n{"ok":1}\n'));

      expect(errors, hasLength(1));
      expect(frames, hasLength(1));
      expect(frames.single, equals({'ok': 1}));
    });

    test('blank line is skipped — no frame, no error', () {
      final frames = <dynamic>[];
      final errors = <Object>[];
      final framer = ByteStreamFramer(
        onFrame: frames.add,
        onError: (e, st) => errors.add(e),
      );

      framer.feedBytes(utf8.encode('\n'));

      expect(frames, isEmpty);
      expect(errors, isEmpty);
    });

    test('whitespace-only line is trimmed to empty and skipped', () {
      final frames = <dynamic>[];
      final errors = <Object>[];
      final framer = ByteStreamFramer(
        onFrame: frames.add,
        onError: (e, st) => errors.add(e),
      );

      framer.feedBytes(utf8.encode('   \t  \n{"a":1}\n'));

      expect(errors, isEmpty);
      expect(frames, hasLength(1));
      expect(frames.single, equals({'a': 1}));
    });

    test('a chunk with no newline yet is buffered — no frame emitted', () {
      final frames = <dynamic>[];
      final framer = ByteStreamFramer(
        onFrame: frames.add,
        onError: (e, st) => fail('unexpected: $e'),
      );

      framer.feedBytes(utf8.encode('{"partial":true'));
      expect(frames, isEmpty);

      // Completing the frame across a second chunk flushes it.
      framer.feedBytes(utf8.encode('}\n'));
      expect(frames, hasLength(1));
      expect(frames.single, equals({'partial': true}));
    });

    test('multiple blank lines between frames are all skipped', () {
      final frames = <dynamic>[];
      final framer = ByteStreamFramer(
        onFrame: frames.add,
        onError: (e, st) => fail('unexpected: $e'),
      );

      framer.feedBytes(utf8.encode('{"id":1}\n\n\n{"id":2}\n'));
      expect(frames, hasLength(2));
      expect((frames[0] as Map)['id'], equals(1));
      expect((frames[1] as Map)['id'], equals(2));
    });

    test('encodeFrame appends a single trailing newline', () {
      final bytes = ByteStreamFramer.encodeFrame({'x': 1});
      final text = utf8.decode(bytes);
      expect(text, equals('{"x":1}\n'));
    });
  });
}

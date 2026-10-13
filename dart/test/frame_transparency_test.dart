// Frame transparency regression (mcp_bridge Part-A, PROTOCOL-REVISION-PLAN).
//
// The bridge's byte-stream framing encodes/decodes whole JSON-RPC messages
// (jsonEncode/jsonDecode), so it is structurally agnostic to the payload
// shape. This test locks that in: 2025-11-25 (and any future) fields —
// `_meta`, `icons`, `structuredContent`, and unknown/forward-compat keys —
// must survive an encode → feed → decode round-trip unchanged. If a future
// change ever makes a transport parse-and-rebuild messages selectively, this
// fails.
import 'package:mcp_bridge/src/transport/_byte_stream_framing.dart';
import 'package:test/test.dart';

void main() {
  test('byte-stream framing preserves _meta / icons / unknown fields', () {
    final original = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': 7,
      'result': {
        'tools': [
          {
            'name': 'demo',
            'description': 'x',
            'inputSchema': {'type': 'object'},
            // 2025-11-25 metadata that a naive re-serializer might drop:
            'icons': [
              {'src': 'https://example.com/i.png', 'sizes': '48x48'}
            ],
            '_meta': {'vendor': 'makemind', 'nested': {'k': 1}},
            'outputSchema': {'type': 'object'},
          }
        ],
        'structuredContent': {'a': 1, 'b': [true, null, 'z']},
        // A key no current model knows about — forward compatibility.
        'x-future-field': {'keep': 'me'},
      },
    };

    final frames = <dynamic>[];
    final framer = ByteStreamFramer(
      onFrame: frames.add,
      onError: (e, st) => fail('unexpected framing error: $e'),
    );

    // Encode → wire bytes → feed back into the framer.
    framer.feedBytes(ByteStreamFramer.encodeFrame(original));

    expect(frames, hasLength(1));
    expect(frames.single, equals(original),
        reason: 'every field must round-trip unchanged');
  });

  test('framing handles split chunks and multiple frames', () {
    final frames = <dynamic>[];
    final framer = ByteStreamFramer(
      onFrame: frames.add,
      onError: (e, st) => fail('unexpected framing error: $e'),
    );

    final a = ByteStreamFramer.encodeFrame({'id': 1, '_meta': {'p': 'q'}});
    final b = ByteStreamFramer.encodeFrame({'id': 2, 'icons': []});
    // Feed a partial chunk boundary mid-frame.
    framer.feedBytes(a.sublist(0, 3));
    framer.feedBytes([...a.sublist(3), ...b]);

    expect(frames, hasLength(2));
    expect((frames[0] as Map)['_meta'], equals({'p': 'q'}));
    expect((frames[1] as Map)['id'], equals(2));
  });
}

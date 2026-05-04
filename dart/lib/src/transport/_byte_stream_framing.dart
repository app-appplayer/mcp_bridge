import 'dart:convert';

/// Newline-delimited JSON framing helper used by byte-stream transports
/// (TCP, serial, USB).
///
/// Holds a UTF-8 buffer; `feedBytes(chunk)` parses out as many complete
/// `\n`-terminated JSON frames as possible, emitting each on the
/// supplied [_onFrame] callback. Malformed JSON inside a frame surfaces
/// via [_onError] so the consumer can route it to the right error sink.
class ByteStreamFramer {
  ByteStreamFramer({
    required void Function(dynamic message) onFrame,
    required void Function(Object error, StackTrace stack) onError,
  })  : _onFrame = onFrame,
        _onError = onError;

  final void Function(dynamic message) _onFrame;
  final void Function(Object error, StackTrace stack) _onError;
  final _buffer = StringBuffer();

  void feedBytes(List<int> chunk) {
    _buffer.write(utf8.decode(chunk, allowMalformed: true));
    while (true) {
      final s = _buffer.toString();
      final nl = s.indexOf('\n');
      if (nl < 0) break;
      final line = s.substring(0, nl).trim();
      _buffer
        ..clear()
        ..write(s.substring(nl + 1));
      if (line.isEmpty) continue;
      try {
        _onFrame(jsonDecode(line));
      } catch (e, st) {
        _onError(e, st);
      }
    }
  }

  /// Encode a JSON-RPC message into the wire bytes (with `\n` terminator).
  static List<int> encodeFrame(dynamic message) =>
      utf8.encode('${jsonEncode(message)}\n');
}

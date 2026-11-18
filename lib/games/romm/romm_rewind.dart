import 'dart:collection';
import 'dart:typed_data';

/// Session-only states, independent of named saves and autosave storage.
/// Copies native scratch memory before the next serialization can overwrite it.
class RommRewindHistory {
  RommRewindHistory({this.byteBudget = 16 * 1024 * 1024, this.maxStates = 60});
  final int byteBudget, maxStates;
  final _states = ListQueue<({Uint8List bytes, int frame})>();
  int bytesHeld = 0;
  int get length => _states.length;
  bool get isEmpty => _states.isEmpty;
  int? get firstFrame => _states.firstOrNull?.frame;

  bool add(Uint8List bytes, int frame) {
    if (bytes.isEmpty || bytes.length > byteBudget ~/ 2) return false;
    while (_states.isNotEmpty && (bytesHeld + bytes.length > byteBudget || _states.length >= maxStates)) {
      bytesHeld -= _states.removeFirst().bytes.length;
    }
    _states.addLast((bytes: Uint8List.fromList(bytes), frame: frame));
    bytesHeld += bytes.length;
    return true;
  }

  ({Uint8List bytes, int frame})? takeLast() {
    if (_states.isEmpty) return null;
    final value = _states.removeLast();
    bytesHeld -= value.bytes.length;
    return value;
  }

  void clear() {
    _states.clear();
    bytesHeld = 0;
  }
}

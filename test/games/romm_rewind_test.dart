import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/romm/romm_rewind.dart';

void main() {
  test('rewind owns its bytes, evicts oldest states, and branches from the selected moment', () {
    final history = RommRewindHistory(byteBudget: 12, maxStates: 3);
    final scratch = Uint8List.fromList([1, 2, 3, 4]);
    expect(history.add(scratch, 30), isTrue);
    scratch[0] = 9;
    history.add(scratch, 60);
    history.add(scratch, 90);
    expect(history.bytesHeld, 12);
    history.add(scratch, 120);
    expect(history.firstFrame, 60);
    expect(history.takeLast()!.frame, 120);
    expect(history.takeLast()!.frame, 90);
    expect(history.bytesHeld, 4);
    history.add(scratch, 80);
    expect(history.takeLast()!.frame, 80);
    expect(history.takeLast()!.frame, 60);
    expect(history.takeLast(), isNull);
    expect(history.bytesHeld, 0);
  });
  test('rewind caps memory and rejects oversized or unsupported state serialization', () {
    final history = RommRewindHistory(byteBudget: 8, maxStates: 10);
    expect(history.add(Uint8List(5), 1), isFalse);
    expect(history.add(Uint8List(0), 1), isFalse);
    history.add(Uint8List.fromList([7, 8]), 1);
    history.clear();
    expect(history.length, 0);
    expect(history.firstFrame, isNull);
    expect(history.bytesHeld, 0);
    final input = Uint8List.fromList([1, 2]);
    history.add(input, 2);
    input[0] = 99;
    expect(history.takeLast()!.bytes.first, 1);
  });
}

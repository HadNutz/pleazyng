/// Runs asynchronous operations one at a time. Each caller receives its own
/// result or error. Releasing the tail when idle also releases its async zone.
class SerialFutureQueue {
  Future<void>? _tail;

  Future<T> run<T>(Future<T> Function() operation) {
    final result = settled.then((_) => operation());
    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(() {
      if (identical(_tail, tail)) _tail = null;
    });
    _tail = tail;
    return result;
  }

  Future<void> get settled => _tail ?? Future<void>.value();

  void reset() => _tail = null;
}

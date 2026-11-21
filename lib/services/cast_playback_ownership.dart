import 'dart:async';

Future<void> loadAcknowledgedCastMedia<Status>({
  required Stream<Status> statuses,
  required bool Function(Status) acknowledge,
  required Future<void> Function() load,
  Stream<void>? invalidated,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final accepted = Completer<void>();
  final interrupted = Completer<void>();
  final subscription = statuses.listen(
    (status) {
      if (accepted.isCompleted) return;
      try {
        if (acknowledge(status)) accepted.complete();
      } catch (error, stack) {
        accepted.completeError(error, stack);
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!accepted.isCompleted) accepted.completeError(error, stack);
    },
    onDone: () {
      if (!accepted.isCompleted) accepted.completeError(StateError('Cast status stream closed'));
    },
  );
  final cancellation = invalidated?.listen((_) {
    if (!interrupted.isCompleted) interrupted.completeError(StateError('Cast load was invalidated'));
  });
  final deadline = Timer(timeout, () {
    if (!interrupted.isCompleted) interrupted.completeError(TimeoutException('Cast load did not complete', timeout));
  });
  try {
    await Future.any<void>([
      Future.wait<void>([Future.sync(load), accepted.future], eagerError: true).then((_) {}),
      interrupted.future,
    ]);
  } finally {
    deadline.cancel();
    await subscription.cancel();
    await cancellation?.cancel();
  }
}

class CastPlaybackOwnership {
  String? _token;
  int? _session;
  bool Function()? _authorized;
  int _revision = 0;
  int get revision => _revision;

  void begin(String token, bool Function() authorized) {
    _revision++;
    _token = token;
    _session = null;
    _authorized = authorized;
  }

  bool acknowledge(String? token, int session) {
    if (session <= 0 || token == null || token != _token || _authorized?.call() != true) return false;
    if (_session != null && _session != session) return false;
    _session = session;
    return true;
  }

  /// Queue advances can acquire a new receiver session ID. Require the original
  /// queue token again before accepting the new session.
  bool acknowledgeQueueItem(String? token, int session) {
    if (session <= 0 || token == null || token != _token || !authorized) return false;
    _session = session;
    return true;
  }

  /// Transfer a verified candidate into the active control handle. Advancing
  /// its revision invalidates handles from the previous movie.
  Future<void> replaceWith(
    CastPlaybackOwnership candidate, {
    required Future<void> Function() finishPrevious,
    required bool Function() current,
  }) async {
    void ensureAccepted() {
      if (!current() || !candidate.authorized || candidate._session == null) {
        throw StateError('Cast replacement is no longer acknowledged');
      }
    }

    ensureAccepted();
    await finishPrevious();
    ensureAccepted();
    _revision++;
    _token = candidate._token;
    _session = candidate._session;
    _authorized = candidate._authorized;
  }

  bool owns(String? token, int session) => matches(token, session) && _authorized?.call() == true;

  bool matches(String? token, int session) =>
      _session != null && session == _session && (token == null || token == _token);

  bool get authorized => _token != null && _authorized?.call() == true;

  void clear() {
    _revision++;
    _token = null;
    _session = null;
    _authorized = null;
  }
}

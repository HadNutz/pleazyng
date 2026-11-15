import 'dart:async';

import 'package:flutter/foundation.dart';

import '../utils/media_server_http_client.dart' show AbortController;

/// Visible lifecycle for one automatic preferred-subtitle fetch.
enum SubtitleFetchStage { idle, searching, downloading, refreshing, completed, noMatch, failed, cancelled, expired }

/// Owns the one automatic subtitle operation associated with a playback screen.
///
/// Each attempt has one wall-clock budget shared by provider search, download,
/// and catalog discovery. Cancellation releases the playback wait immediately
/// and aborts supported HTTP requests. A request already accepted by a server
/// may still finish remotely; its retired result cannot be applied locally.
final class SubtitleAutomaticFetch extends ChangeNotifier {
  SubtitleAutomaticFetch({this.budget = const Duration(seconds: 12)});

  final Duration budget;
  SubtitleFetchAttempt? _active;
  SubtitleFetchStage _stage = SubtitleFetchStage.idle;

  SubtitleFetchStage get stage => _stage;
  bool get busy => _active != null;

  void _changed() => notifyListeners();

  SubtitleFetchAttempt start({required bool Function() isCurrent}) {
    cancel();
    final attempt = SubtitleFetchAttempt._(this, isCurrent, DateTime.now().add(budget));
    _active = attempt;
    _stage = SubtitleFetchStage.searching;
    notifyListeners();
    attempt._watch = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!attempt._sourceStillCurrent()) {
        attempt.finish(SubtitleFetchStage.cancelled);
      } else if (!DateTime.now().isBefore(attempt.deadline)) {
        attempt.finish(SubtitleFetchStage.expired);
      }
    });
    return attempt;
  }

  void cancel() => _active?.finish(SubtitleFetchStage.cancelled);

  void reset() {
    cancel();
    _stage = SubtitleFetchStage.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}

final class SubtitleFetchAttempt {
  SubtitleFetchAttempt._(this._owner, this._sourceCurrent, this.deadline);

  final SubtitleAutomaticFetch _owner;
  final bool Function() _sourceCurrent;
  final DateTime deadline;
  final AbortController abort = AbortController();
  Timer? _watch;

  bool _sourceStillCurrent() {
    try {
      return _sourceCurrent();
    } catch (_) {
      return false;
    }
  }

  bool get current =>
      identical(_owner._active, this) && !abort.isAborted && _sourceStillCurrent() && DateTime.now().isBefore(deadline);

  void check() {
    if (!current) {
      if (identical(_owner._active, this)) {
        finish(DateTime.now().isBefore(deadline) ? SubtitleFetchStage.cancelled : SubtitleFetchStage.expired);
      }
      throw const SubtitleFetchRetiredException();
    }
  }

  void phase(SubtitleFetchStage stage) {
    check();
    _owner._stage = stage;
    _owner._changed();
  }

  /// Await [operation] without allowing a retired or expired attempt to return
  /// a value that its caller could accidentally apply to playback.
  Future<T> wait<T>(Future<T> Function() operation) async {
    check();
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      finish(SubtitleFetchStage.expired);
      throw const SubtitleFetchRetiredException();
    }

    final timeout = Completer<T>();
    final timer = Timer(remaining, () {
      finish(SubtitleFetchStage.expired);
      if (!timeout.isCompleted) timeout.completeError(const SubtitleFetchRetiredException());
    });
    try {
      final value = await Future.any<T>([
        Future<T>.sync(operation),
        abort.trigger.then<T>((_) => throw const SubtitleFetchRetiredException()),
        timeout.future,
      ]);
      check();
      return value;
    } finally {
      timer.cancel();
    }
  }

  void finish(SubtitleFetchStage stage) {
    if (!identical(_owner._active, this)) return;
    _watch?.cancel();
    _watch = null;
    _owner._active = null;
    _owner._stage = stage;
    abort.abort();
    _owner._changed();
  }
}

final class SubtitleFetchRetiredException implements Exception {
  const SubtitleFetchRetiredException();
}

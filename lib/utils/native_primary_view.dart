import 'dart:async';

/// Resolves a Flutter view using the native host's view identity.
///
/// A multiview engine may expose its implicit view before the host's primary
/// window view, so callers must select by the native identifier rather than
/// assuming the first Dart view is the root.
Future<T> waitForNativePrimaryView<T>({
  required Future<int?> Function() readNativeViewId,
  required Iterable<T> Function() currentViews,
  required int Function(T view) viewId,
  required bool Function(Object error) isTransientError,
  Duration timeout = const Duration(seconds: 5),
  Duration requestTimeout = const Duration(milliseconds: 500),
  Duration retryDelay = const Duration(milliseconds: 50),
}) async {
  final elapsed = Stopwatch()..start();
  var lastObservation = 'native primary view ID unavailable';

  while (elapsed.elapsed < timeout) {
    final remaining = timeout - elapsed.elapsed;
    try {
      final nativeId = await readNativeViewId().timeout(
        requestTimeout.inMicroseconds < remaining.inMicroseconds ? requestTimeout : remaining,
      );
      if (nativeId == null) {
        lastObservation = 'native primary view ID was null';
      } else {
        final views = currentViews().toList();
        for (final view in views) {
          if (viewId(view) == nativeId) return view;
        }
        lastObservation = 'nativeId=$nativeId; Dart view IDs=${views.map(viewId).join(',')}';
      }
    } on Object catch (error, stackTrace) {
      if (!isTransientError(error)) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      lastObservation = 'native ID lookup failed with ${error.runtimeType}';
    }

    final delay = timeout - elapsed.elapsed;
    if (delay.inMicroseconds <= 0) break;
    await Future<void>.delayed(retryDelay.inMicroseconds < delay.inMicroseconds ? retryDelay : delay);
  }

  final finalIds = currentViews().map(viewId).join(',');
  throw TimeoutException(
    'native primary view was not present before the ${timeout.inSeconds}s deadline; '
    '$lastObservation; final Dart view IDs=[$finalIds]',
    timeout,
  );
}

/// Preserves the standard single-view launch off macOS and uses a resolved
/// native view only on hosts that explicitly provide one.
void runWithOptionalNativeView<T>({
  required bool useNativeView,
  required void Function() runDefault,
  required Future<T> Function() resolveNativeView,
  required void Function(T view) runNativeView,
  required void Function(Object error, StackTrace stackTrace) onFailure,
}) {
  if (!useNativeView) {
    runDefault();
    return;
  }
  unawaited(resolveNativeView().then<void>(runNativeView).catchError(onFailure));
}

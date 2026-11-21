import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/navigation/video_task_restoration.dart';

void main() {
  const task = SavedVideoTask(
    server: 'plex:home',
    item: '493',
    backend: 'plex',
    edition: 1,
    source: 'edition-2',
    positionMs: 85467,
    paused: true,
    offline: true,
  );
  test('keeps the exact paused position and edition without storing a playback URL', () {
    final restored = SavedVideoTask.decode(task.encode())!;
    expect(restored.encode(), task.encode());
    for (final data in [
      null,
      '',
      '[]',
      task.encode().replaceFirst('493', 'https://host/video?token=s'),
      task.encode().replaceFirst('85467', '-1'),
    ]) {
      expect(SavedVideoTask.decode(data), isNull);
    }
  });

  testWidgets('covered or retired players cannot overwrite a replacement checkpoint', (tester) async {
    final values = <String?>[];
    final observer = VideoTaskObserver(values.add);
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, navigatorObservers: [observer], home: const SizedBox()));
    final first = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    key.currentState!.push(first);
    await tester.pumpAndSettle();
    observer.record(first, task);
    expect(values, [task.encode()]);
    final next = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    key.currentState!.pushReplacement(next);
    await tester.pumpAndSettle();
    observer.record(next, task);
    observer.record(first, task);
    observer.clear(first);
    expect(values, [task.encode(), null, task.encode()]);
    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(values.last, isNull);
  });
}

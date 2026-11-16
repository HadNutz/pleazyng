import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_drm/video_player_drm.dart';

void main() {
  testWidgets('source size refreshes the exported crop without a viewport resize', (tester) async {
    const id = 877;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final resizeCalls = <Map<dynamic, dynamic>>[];
    const window = MethodChannel('webos/exported_windows');
    const events = MethodChannel('flutter.io/videoPlayer/videoEvents$id');
    messenger.setMockMethodCallHandler(window, (call) async {
      if (call.method == 'resize') resizeCalls.add(Map<dynamic, dynamic>.from(call.arguments as Map));
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    final player = VideoPlayerWebOs();
    final subscription = player.videoEventsFor(id).listen((_) {});
    Future<void> event(Map<String, Object> data) async {
      unawaited(
        messenger.handlePlatformMessage(events.name, const StandardMethodCodec().encodeSuccessEnvelope(data), (_) {}),
      );
      await tester.pump();
    }

    await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: player.buildView(id)));
    await event({'event': 'initialized', 'width': 1280, 'height': 720, 'duration': 60000});
    await event({'event': 'onLoaded'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(resizeCalls.last['srcRect'], [0, 0, 1280, 720]);
    final destination = resizeCalls.last['dstRect'];
    final count = resizeCalls.length;
    await event({'event': 'initialized', 'width': 1920, 'height': 1080, 'duration': 60000});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(resizeCalls.length, greaterThan(count));
    expect(resizeCalls.last['srcRect'], [0, 0, 1920, 1080]);
    expect(resizeCalls.last['dstRect'], destination);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    await tester.runAsync(subscription.cancel);
    messenger.setMockMethodCallHandler(window, null);
    messenger.setMockMethodCallHandler(events, null);
  });
}

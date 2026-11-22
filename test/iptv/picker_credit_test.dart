import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/iptv/iptv_picker_credit.dart';
import 'package:plezy/utils/external_url.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  testWidgets('TV users can read the original author and scan the original project link', (tester) async {
    debugTvosRunnerOverride = true;
    addTearDown(() => debugTvosRunnerOverride = null);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: IptvPickerCredit())));
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(find.text('Zachary Schmook (@zschmook)'), findsOneWidget);
    expect(find.text('https://github.com/zschmook/m3u-web-picker'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}

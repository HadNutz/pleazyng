import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/licenses_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lists the bundled LCEVCdec license', (tester) async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await tester.pumpWidget(const MaterialApp(home: LicensesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('LCEVCdec 4.3.1'), findsOneWidget);
  });
}

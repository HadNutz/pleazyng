import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/licenses_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lists one bundled SDK notice when bootstrap also registers it', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // Read the real notice files without racing filesystem I/O against the
    // widget test's virtual clock. Other assets keep the normal test loader.
    messenger.setMockMessageHandler('flutter/assets', (ByteData? message) async {
      final key = utf8.decode(message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes));
      if (!key.startsWith('assets/licenses/')) return messenger.delegate.send('flutter/assets', message);
      final bytes = key == 'assets/licenses/LCEVCdec.txt'
          ? File(key).readAsBytesSync()
          : utf8.encode('Unrelated package notice');
      return ByteData.sublistView(Uint8List.fromList(bytes));
    });
    LicenseRegistry.reset();
    LicenseRegistry.addLicense(() async* {
      yield const LicenseEntryWithLineBreaks(['LCEVCdec (V-Nova)'], 'Bootstrap registration');
    });
    addTearDown(() {
      messenger.setMockMessageHandler('flutter/assets', null);
      LicenseRegistry.reset();
      rootBundle.clear();
    });
    LocaleSettings.setLocaleSync(AppLocale.en);
    await tester.pumpWidget(const MaterialApp(home: LicensesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('LCEVCdec (V-Nova)'), findsOneWidget);
    expect(find.textContaining('LCEVCdec'), findsOneWidget);
  });
}

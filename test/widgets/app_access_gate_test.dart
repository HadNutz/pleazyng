import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/supporter/supporter_mode.dart';
import 'package:plezy/services/supporter/supporter_service.dart';
import 'package:plezy/services/supporter/supporter_store.dart';
import 'package:plezy/widgets/app_access_gate.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/supporter_store_fakes.dart';

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('Apple trial requires a visible disclosure and explicit button press', (tester) async {
    final platform = FakeInAppPurchasePlatform();
    addTearDown(platform.close);
    final appStore = FakeAppStore(platform);
    platform.productResults = [supporterProduct(), appStoreTrialProduct()];
    final service = SupporterService.forTesting(
      availability: SupporterAvailability.purchasable,
      store: appStore.store,
      appleStoreBuild: true,
    );
    addTearDown(service.dispose);
    await service.init();

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: AppAccessGate(service: service, child: const Text('app content')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('app content'), findsNothing);
    expect(find.text(t.appAccess.appleTrialDisclosure(price: r'$2.99')), findsOneWidget);
    expect(find.textContaining('ends after 7 days'), findsOneWidget);
    expect(find.textContaining('one-time lifetime purchase'), findsOneWidget);
    expect(find.textContaining('no subscription or automatic charge'), findsOneWidget);
    expect(platform.boughtProductIds, isEmpty);

    await tester.tap(find.text(t.appAccess.startTrial));
    await tester.pump();

    expect(platform.boughtProductIds, [appStoreTrialProductId]);
    expect(find.text('app content'), findsNothing, reason: 'the purchase prompt alone does not grant access');
  });
}

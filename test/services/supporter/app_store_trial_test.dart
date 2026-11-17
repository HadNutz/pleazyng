import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/supporter/supporter_mode.dart';
import 'package:plezy/services/supporter/supporter_service.dart';
import 'package:plezy/services/supporter/supporter_store.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/supporter_store_fakes.dart';

Future<int> _cachedTrialStartedAt() async =>
    (await SettingsService.getInstance()).read(SettingsService.appAccessTrialStartedAtEpochMs);

Future<bool> _cachedLifetimeEntitlement() async =>
    (await SettingsService.getInstance()).read(SettingsService.supporterEntitlementCached);

void main() {
  setUp(resetSharedPreferencesForTest);

  test('Apple initialization does not auto-start or trust the local trial clock', () async {
    final settings = await SettingsService.getInstance();
    final localStart = DateTime.now().toUtc().subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    await settings.write(SettingsService.appAccessTrialStartedAtEpochMs, localStart);
    final platform = FakeInAppPurchasePlatform();
    addTearDown(platform.close);
    final appStore = FakeAppStore(platform);
    final service = SupporterService.forTesting(
      availability: SupporterAvailability.purchasable,
      store: appStore.store,
      appleStoreBuild: true,
    );
    addTearDown(service.dispose);

    await service.init();

    expect(service.isAppleStoreBuild, isTrue);
    expect(service.isReady, isTrue);
    expect(service.hasAccess, isFalse);
    expect(service.hasStartedTrial, isFalse);
    expect(service.canStartTrial, isFalse);
    expect(await _cachedTrialStartedAt(), localStart);
    expect(platform.boughtProductIds, isEmpty);
    expect(await _cachedLifetimeEntitlement(), isFalse);
    expect(
      SupporterService.startupUnlocked(settings, appleStoreBuild: true),
      isFalse,
      reason: 'Apple startup cannot use a local trial timestamp as proof',
    );
  });

  test('starting the Apple trial requires an exact zero-price Non-Consumable and explicit action', () async {
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
    await service.loadProduct();

    expect(service.hasAccess, isFalse);
    expect(service.canStartTrial, isTrue);
    expect(platform.boughtProductIds, isEmpty);
    expect(await service.startTrial(), isTrue);
    expect(platform.boughtProductIds, [appStoreTrialProductId]);
    expect(service.hasAccess, isFalse, reason: 'opening the purchase sheet is not a verified entitlement');

    final purchaseDate = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    appStore.transactions = [
      appStoreTransaction(productId: appStoreTrialProductId, originalPurchaseDate: purchaseDate),
    ];
    platform.deliver([appStorePurchase(productId: appStoreTrialProductId)]);
    await pumpEventQueue();

    expect(service.hasStartedTrial, isTrue);
    expect(service.isTrialActive, isTrue);
    expect(service.hasAccess, isTrue);
    expect(service.hasLifetimeUnlock, isFalse);
    expect(await _cachedLifetimeEntitlement(), isFalse);
    expect(await _cachedTrialStartedAt(), 0, reason: 'the Apple trial date comes from StoreKit history');
  });

  test('Apple trial product must be free and non-consumable', () async {
    for (final invalidProduct in [
      appStoreTrialProduct(price: 0.01),
      appStoreTrialProduct(type: SK2ProductType.consumable),
    ]) {
      final platform = FakeInAppPurchasePlatform();
      addTearDown(platform.close);
      final appStore = FakeAppStore(platform);
      platform.productResults = [supporterProduct(), invalidProduct];
      final service = SupporterService.forTesting(
        availability: SupporterAvailability.purchasable,
        store: appStore.store,
        appleStoreBuild: true,
      );
      addTearDown(service.dispose);

      await service.init();
      await service.loadProduct();

      expect(service.canStartTrial, isFalse);
      expect(service.storeState.value.trialProductError, SupporterError.trialProductInvalid);
      expect(await service.startTrial(), isFalse);
      expect(platform.boughtProductIds, isEmpty);
    }
  });

  test('Apple cancellation and pending states never grant trial access', () async {
    for (final status in [PurchaseStatus.canceled, PurchaseStatus.pending]) {
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
      await service.loadProduct();
      expect(await service.startTrial(), isTrue);
      platform.deliver([appStorePurchase(productId: appStoreTrialProductId, status: status)]);
      await pumpEventQueue();

      expect(service.hasAccess, isFalse, reason: '$status');
      expect(service.hasStartedTrial, isFalse, reason: '$status');
      if (status == PurchaseStatus.pending) {
        expect(service.storeState.value.status, SupporterPurchaseStatus.pending);
        expect(service.canStartTrial, isFalse);
        platform.deliver([appStorePurchase(productId: appStoreTrialProductId, status: PurchaseStatus.canceled)]);
        await pumpEventQueue();
        expect(service.storeState.value.status, SupporterPurchaseStatus.idle);
        expect(service.canStartTrial, isTrue, reason: 'a later cancellation closes the pending store flow');
      } else {
        expect(service.storeState.value.status, SupporterPurchaseStatus.idle);
        expect(service.canStartTrial, isTrue);
      }
      expect(service.hasAccess, isFalse);
      expect(service.hasStartedTrial, isFalse);
    }
  });

  test('Restore uses the verified original StoreKit purchase date', () async {
    final platform = FakeInAppPurchasePlatform();
    addTearDown(platform.close);
    final appStore = FakeAppStore(platform);
    final purchaseDate = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().toUtc().subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      isUtc: true,
    );
    appStore.transactions = [
      appStoreTransaction(productId: appStoreTrialProductId, originalPurchaseDate: purchaseDate),
    ];
    final service = SupporterService.forTesting(
      availability: SupporterAvailability.purchasable,
      store: appStore.store,
      appleStoreBuild: true,
    );
    addTearDown(service.dispose);

    await service.init();
    expect(service.trialEndsAt, purchaseDate.add(SupporterService.fullAccessTrialDuration));
    expect(service.hasAccess, isTrue);

    appStore.transactions = [];
    await service.restore();
    expect(service.hasAccess, isFalse);

    appStore.transactions = [
      appStoreTransaction(productId: appStoreTrialProductId, originalPurchaseDate: purchaseDate),
    ];
    await service.restore();

    expect(appStore.syncs, 2);
    expect(service.hasStartedTrial, isTrue);
    expect(service.trialEndsAt, purchaseDate.add(SupporterService.fullAccessTrialDuration));
    expect(service.hasAccess, isTrue);
    expect(service.hasLifetimeUnlock, isFalse);
    expect(await _cachedLifetimeEntitlement(), isFalse);
  });

  test('an Apple trial older than seven days restores as expired and cannot restart', () async {
    final platform = FakeInAppPurchasePlatform();
    addTearDown(platform.close);
    final appStore = FakeAppStore(platform);
    final purchaseDate = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().toUtc().subtract(const Duration(days: 8)).millisecondsSinceEpoch,
      isUtc: true,
    );
    appStore.transactions = [
      appStoreTransaction(productId: appStoreTrialProductId, originalPurchaseDate: purchaseDate),
    ];
    final service = SupporterService.forTesting(
      availability: SupporterAvailability.purchasable,
      store: appStore.store,
      appleStoreBuild: true,
    );
    addTearDown(service.dispose);

    await service.init();

    expect(service.isTrialActive, isFalse);
    expect(service.hasStartedTrial, isTrue);
    expect(service.trialEndsAt, purchaseDate.add(SupporterService.fullAccessTrialDuration));
    expect(service.hasAccess, isFalse);
    expect(service.canStartTrial, isFalse);

    await service.restore();

    expect(appStore.syncs, 1);
    expect(service.isTrialActive, isFalse);
    expect(service.hasStartedTrial, isTrue);
    expect(service.trialEndsAt, purchaseDate.add(SupporterService.fullAccessTrialDuration));
    expect(service.hasAccess, isFalse);
    expect(service.canStartTrial, isFalse);
    expect(platform.boughtProductIds, isEmpty);
    expect(service.hasLifetimeUnlock, isFalse);
    expect(await _cachedLifetimeEntitlement(), isFalse);
  });

  test('revoked and malformed StoreKit trial transactions grant no access', () async {
    for (final transaction in [
      appStoreTransaction(
        productId: appStoreTrialProductId,
        revoked: true,
        originalPurchaseDate: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      ),
      appStoreTransaction(productId: appStoreTrialProductId, jsonRepresentation: '{invalid'),
      appStoreTransaction(
        productId: appStoreTrialProductId,
        jsonRepresentation: '{"productId":"another.product","originalPurchaseDate":1767225600000}',
      ),
      appStoreTransaction(
        productId: appStoreTrialProductId,
        jsonRepresentation: jsonEncode({
          'productId': appStoreTrialProductId,
          'type': 'Consumable',
          'originalPurchaseDate': 1767225600000,
        }),
      ),
      appStoreTransaction(
        productId: appStoreTrialProductId,
        jsonRepresentation: jsonEncode({'productId': appStoreTrialProductId, 'type': 'Non-Consumable'}),
      ),
      appStoreTransaction(
        productId: appStoreTrialProductId,
        jsonRepresentation: jsonEncode({
          'productId': appStoreTrialProductId,
          'type': 'Non-Consumable',
          'originalPurchaseDate': DateTime.now().toUtc().add(const Duration(days: 1)).millisecondsSinceEpoch,
        }),
      ),
      appStoreTransaction(
        productId: appStoreTrialProductId,
        jsonRepresentation: jsonEncode({
          'productId': appStoreTrialProductId,
          'type': 'Non-Consumable',
          'originalPurchaseDate': 9000000000000000000,
        }),
      ),
    ]) {
      final platform = FakeInAppPurchasePlatform();
      addTearDown(platform.close);
      final appStore = FakeAppStore(platform)..transactions = [transaction];
      final service = SupporterService.forTesting(
        availability: SupporterAvailability.purchasable,
        store: appStore.store,
        appleStoreBuild: true,
      );
      addTearDown(service.dispose);

      await service.init();

      expect(service.hasAccess, isFalse);
      expect(service.isTrialActive, isFalse);
      expect(service.hasStartedTrial, isTrue, reason: 'do not offer the same Apple Account another trial');
      expect(service.hasLifetimeUnlock, isFalse);
      expect(await _cachedLifetimeEntitlement(), isFalse);
    }
  });
}

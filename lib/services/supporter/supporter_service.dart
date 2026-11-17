import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart' as openiap;
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';

import '../../mixins/disposable_change_notifier_mixin.dart';
import '../../utils/app_logger.dart';
import '../settings_service.dart';
import 'amazon_supporter_store.dart';
import 'lg_paymentwall_client.dart';
import 'supporter_mode.dart';
import 'supporter_store.dart';
import 'review_access.dart';

/// The StoreKit plugin's error code for a product query that found nothing.
const _storeKitNoProducts = 'storekit_no_response';
const _amazonStoreBuild = bool.fromEnvironment('AMAZON_STORE');
const _webosBuild = bool.fromEnvironment('PLEZY_WEBOS');
const _lgPaymentwallBuild = _webosBuild && supporterBuildMode == SupporterMode.iap;

/// Where a purchase or restore the user started currently stands.
enum SupporterPurchaseStatus {
  idle,

  /// The store's purchase flow is open.
  purchasing,

  /// The store accepted the purchase but is waiting on payment or on a parent
  /// (Ask to Buy). Perks unlock when the store completes it.
  pending,

  /// Restore Purchases is reading the store account.
  restoring,

  /// Securely creating or reading the LG accountless recovery identity.
  preparingRecovery,
}

/// Why the store could not price, sell or restore the lifetime unlock.
enum SupporterError {
  /// Purchases are not possible here: no store account, the store app is
  /// missing, or purchases are restricted on this device.
  storeUnavailable,

  /// The store answered without the Supporter product.
  productNotFound,

  /// The store could not be reached for the product and its price.
  productQueryFailed,

  /// The store reported a failed purchase.
  purchaseFailed,

  /// Restore could not read the store account.
  restoreFailed,

  /// The store account has no lifetime unlock to restore.
  nothingToRestore,

  /// The dedicated LG payment service is temporarily unavailable.
  paymentServiceUnavailable,

  /// The dedicated LG payment service could not verify restore status.
  paymentRestoreFailed,

  /// The recovery identity has no verified lifetime purchase.
  paymentNothingToRestore,

  /// The LG checkout could not be opened.
  paymentPurchaseFailed,

  /// App Store Connect did not return the free trial product.
  trialProductNotFound,

  /// The App Store trial product is not a zero-price Non-Consumable.
  trialProductInvalid,
}

/// The store-facing state the Supporter sheet renders.
@immutable
class SupporterStoreState {
  const SupporterStoreState({
    this.isLoadingProduct = false,
    this.price,
    this.productError,
    this.trialProductError,
    this.status = SupporterPurchaseStatus.idle,
    this.error,
  });

  final bool isLoadingProduct;

  /// The store's localized price label, once the product has loaded.
  final String? price;

  /// Why [price] is unavailable after loading finished.
  final SupporterError? productError;

  /// Why the Apple zero-price trial product cannot be started.
  final SupporterError? trialProductError;

  final SupporterPurchaseStatus status;

  /// Why the last purchase or restore did not unlock the perks.
  final SupporterError? error;

  bool get isBusy =>
      status == SupporterPurchaseStatus.purchasing ||
      status == SupporterPurchaseStatus.restoring ||
      status == SupporterPurchaseStatus.preparingRecovery;

  SupporterStoreState copyWith({
    bool? isLoadingProduct,
    String? price,
    SupporterError? Function()? productError,
    SupporterError? Function()? trialProductError,
    SupporterPurchaseStatus? status,
    SupporterError? Function()? error,
  }) => SupporterStoreState(
    isLoadingProduct: isLoadingProduct ?? this.isLoadingProduct,
    price: price ?? this.price,
    productError: productError != null ? productError() : this.productError,
    trialProductError: trialProductError != null ? trialProductError() : this.trialProductError,
    status: status ?? this.status,
    error: error != null ? error() : this.error,
  );
}

/// App-lifetime owner of the lifetime access entitlement, provided at the root
/// scope: a purchase belongs to the store account on this device, not to a
/// profile.
///
/// [isUnlocked] turns false only after a confirmed revocation (a refund), never
/// because the store is unreachable, so a listener may treat a true→false
/// transition as a real revocation. Listeners are notified only when
/// [isUnlocked] changes; the purchase sheet's store state is [storeState].
///
/// How each store reports a revocation:
/// - Google Play: a successful purchase query that no longer lists the
///   product, checked at startup and on Restore Purchases. Play sends the app
///   nothing when a refund happens.
/// - App Store: StoreKit 2 delivers the revoked transaction through
///   `Transaction.updates` while the app runs, and `Transaction.all` keeps it
///   with a `revocationDate` for the startup check. An empty history is not a
///   revocation, because another Apple Account may be signed in.
///
/// StoreKit purchase-stream events are not treated as proof on their own. The
/// current plugin can forward an unverified transaction as purchased, so the
/// App Store history API must confirm ownership before a new entitlement is
/// granted. The history wrapper exposes verified transactions only.
class SupporterService extends ChangeNotifier with DisposableChangeNotifierMixin, WidgetsBindingObserver {
  static const fullAccessTrialDuration = Duration(days: 7);

  /// Seeds the cached entitlement synchronously, so the first frame under the
  /// providers already renders unlocked perks. Billing starts in [init].
  SupporterService()
    : this._(
        supporterAvailabilityFor(supporterBuildMode),
        appleStoreBuild: _appleStoreTarget,
        // Const guard: builds other than `iap` never reach the billing plugin.
        createStore: supporterBuildMode == SupporterMode.iap && !_amazonStoreBuild && !_webosBuild
            ? SupporterStore.forThisDevice
            : null,
        lgPaymentwallClient: _lgPaymentwallBuild ? LgPaymentwallClient() : null,
        lgPaymentwallBuild: _lgPaymentwallBuild,
      );

  /// Without [purchased], seeds from the cache like the app does. [store]
  /// stands in for the device's store in purchasable tests; without one, no
  /// billing runs and purchases report [SupporterError.storeUnavailable].
  @visibleForTesting
  SupporterService.forTesting({
    required SupporterAvailability availability,
    bool? purchased,
    SupporterStore? store,
    String reviewVerificationKey = ReviewAccess.publicKey,
    bool? appleStoreBuild,
    LgPaymentwallClient? lgPaymentwallClient,
  }) : this._(
         availability,
         purchased: purchased,
         reviewVerificationKey: reviewVerificationKey,
         appleStoreBuild: appleStoreBuild ?? (store is AppStoreSupporterStore),
         createStore: store == null ? null : () => store,
         lgPaymentwallClient: lgPaymentwallClient,
         lgPaymentwallBuild: lgPaymentwallClient != null,
       );

  SupporterService._(
    this.availability, {
    bool? purchased,
    required bool appleStoreBuild,
    this._createStore,
    this._lgPaymentwallClient,
    bool lgPaymentwallBuild = false,
    this.reviewVerificationKey = ReviewAccess.publicKey,
  }) : _purchased =
           purchased ??
           (availability == SupporterAvailability.purchasable &&
               !lgPaymentwallBuild &&
               (SettingsService.instanceOrNull?.read(SettingsService.supporterEntitlementCached) ?? false)),
       _appleStoreBuild = appleStoreBuild,
       _isLGPaymentwallBuild = lgPaymentwallBuild,
       _trialStartedAtEpochMs = appleStoreBuild
           ? 0
           : SettingsService.instanceOrNull?.read(SettingsService.appAccessTrialStartedAtEpochMs) ?? 0;

  /// Fixed for the life of the process.
  final SupporterAvailability availability;
  final String reviewVerificationKey;
  final bool _appleStoreBuild;
  final LgPaymentwallClient? _lgPaymentwallClient;
  final bool _isLGPaymentwallBuild;

  final SupporterStore? Function()? _createStore;
  bool _storeCreated = false;
  SupporterStore? _store;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;
  AmazonSupporterStore? _amazonStore;
  StreamSubscription<openiap.Purchase>? _amazonPurchaseSubscription;
  StreamSubscription<openiap.PurchaseError>? _amazonErrorSubscription;
  ProductDetails? _product;
  ProductDetails? _trialProduct;
  openiap.Product? _amazonProduct;
  int _trialStartedAtEpochMs;
  bool _appStoreTrialPurchased = false;
  bool _appStoreTrialHistoryChecked = false;
  DateTime? _appStoreTrialStartedAt;
  Timer? _trialExpiryTimer;
  Timer? _reviewExpiryTimer;
  DateTime? _reviewExpiresAt;
  bool _ready = false;
  bool _waitingForLGCheckoutReturn = false;
  bool _lgCheckoutWentBackground = false;

  /// Bumped by every confirmed purchase or revocation from the purchase
  /// stream, so an older history query cannot overwrite a newer store event.
  int _entitlementGeneration = 0;

  bool _purchased;

  final ValueNotifier<SupporterStoreState> _storeState = ValueNotifier(const SupporterStoreState());

  /// Product, trial, purchase and restore progress for app access.
  ValueListenable<SupporterStoreState> get storeState => _storeState;

  bool get isReady => _ready;

  bool get hasLifetimeUnlock => _purchased;

  bool get isAppleStoreBuild => _appleStoreBuild;

  bool get isLGPaymentwallBuild => _isLGPaymentwallBuild;

  bool get hasLGPaymentwallIdentity => _lgPaymentwallClient?.hasLocalIdentity ?? false;

  bool get hasStartedTrial => _appleStoreBuild ? _appStoreTrialPurchased : _trialStartedAtEpochMs > 0;

  DateTime? get trialEndsAt {
    final startedAt = _appleStoreBuild
        ? _appStoreTrialStartedAt
        : hasStartedTrial
        ? DateTime.fromMillisecondsSinceEpoch(_trialStartedAtEpochMs, isUtc: true)
        : null;
    return startedAt?.add(fullAccessTrialDuration);
  }

  bool get isTrialActive {
    final end = trialEndsAt;
    return end != null && DateTime.now().toUtc().isBefore(end);
  }

  Duration? get trialRemaining {
    final end = trialEndsAt;
    if (end == null) return null;
    final remaining = end.difference(DateTime.now().toUtc());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get hasReviewAccess => _reviewExpiresAt?.isAfter(DateTime.now().toUtc()) ?? false;

  bool get supportsReviewAccess =>
      availability == SupporterAvailability.purchasable && ReviewAccess.supportedFor(reviewVerificationKey);

  /// Verifies and saves an explicitly provided store-review grant. It does not
  /// change the trial clock or write the lifetime purchase cache.
  Future<bool> redeemReviewAccess(String token) async {
    if (!supportsReviewAccess) return false;
    final expiry = await ReviewAccess.verify(token, verificationKey: reviewVerificationKey);
    if (expiry == null || isDisposed) return false;
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.storeReviewAccessGrant, token.trim());
    if (isDisposed) return false;
    _setReviewExpiry(expiry);
    safeNotifyListeners();
    return true;
  }

  void _setReviewExpiry(DateTime expiry) {
    _reviewExpiresAt = expiry;
    _reviewExpiryTimer?.cancel();
    _reviewExpiryTimer = Timer(expiry.difference(DateTime.now().toUtc()), safeNotifyListeners);
  }

  bool get hasAccess =>
      availability != SupporterAvailability.purchasable || _purchased || isTrialActive || hasReviewAccess;

  bool get shouldOfferTrial => availability == SupporterAvailability.purchasable && !_purchased && !hasStartedTrial;

  bool get canStartTrial =>
      shouldOfferTrial &&
      (!_appleStoreBuild ||
          (_appStoreTrialHistoryChecked &&
              _trialProduct != null &&
              _product != null &&
              !_storeState.value.isBusy &&
              _storeState.value.status != SupporterPurchaseStatus.pending));

  bool get _lifetimeProductLoaded => _lgPaymentwallClient != null
      ? _lgPaymentwallClient.isConfigured && _storeState.value.price != null
      : _amazonStoreBuild
      ? _amazonProduct != null
      : _product != null;

  /// Whether any perk UI is shown on this install.
  bool get isAvailable => availability != SupporterAvailability.hidden;

  /// Whether entitlement-controlled presentation is usable right now.
  bool get isUnlocked => switch (availability) {
    SupporterAvailability.hidden => false,
    SupporterAvailability.free => true,
    SupporterAvailability.purchasable => _purchased || isTrialActive || hasReviewAccess,
  };

  /// Loads store entitlements. Apple trial access is never started here.
  Future<void> init() async {
    if (availability != SupporterAvailability.purchasable) {
      _ready = true;
      safeNotifyListeners();
      return;
    }
    try {
      final settings = await SettingsService.getInstance();
      if (isDisposed) return;
      // LG ownership comes only from the signed key-store grant. Its legacy
      // boolean cache is deliberately ignored, including when the key store is
      // unavailable or the paid build lacks its public verification key.
      if (_lgPaymentwallClient != null) {
        WidgetsBinding.instance.addObserver(this);
        try {
          final cached = await _lgPaymentwallClient.readCachedEntitlement();
          if (cached != null && _lgPaymentwallClient.isCurrentEntitlement(cached)) _purchased = cached.owned;
        } on LgPaymentwallFailure {
          _setStoreState(_storeState.value.copyWith(error: () => SupporterError.paymentRestoreFailed));
        }
      } else if (settings.read(SettingsService.supporterEntitlementCached) && !_purchased) {
        // Other store caches only ever raise a lifetime entitlement here;
        // lowering it takes a confirmed store revocation.
        _purchased = true;
      }
      _trialStartedAtEpochMs = _appleStoreBuild ? 0 : settings.read(SettingsService.appAccessTrialStartedAtEpochMs);
      if (supportsReviewAccess) {
        final expiry = await ReviewAccess.verify(
          settings.read(SettingsService.storeReviewAccessGrant),
          verificationKey: reviewVerificationKey,
        );
        if (isDisposed) return;
        if (expiry != null) _setReviewExpiry(expiry);
      }
      _scheduleTrialExpiry();
      safeNotifyListeners();

      // Other store builds retain their existing local first-launch trial.
      // Apple users must explicitly approve the zero-price StoreKit product.
      if (!_appleStoreBuild &&
          !_purchased &&
          !hasStartedTrial &&
          !(_isLGPaymentwallBuild && settings.read(SettingsService.supporterEntitlementCached))) {
        await startTrial();
      }

      if (_lgPaymentwallClient != null) {
        if (!_lgPaymentwallClient.isConfigured) {
          _setStoreState(_storeState.value.copyWith(error: () => SupporterError.paymentServiceUnavailable));
        } else {
          try {
            final entitlement = await _lgPaymentwallClient.refreshEntitlement();
            if (entitlement != null && _lgPaymentwallClient.isCurrentEntitlement(entitlement)) {
              _setPurchased(entitlement.owned);
              _setStoreState(_storeState.value.copyWith(error: () => null));
            }
          } on LgPaymentwallFailure catch (error) {
            _setStoreState(
              _storeState.value.copyWith(error: () => _supporterErrorForLGFailure(error, restoring: true)),
            );
          }
        }
      } else if (_amazonStoreBuild) {
        final store = _ensureAmazonStore();
        if (store != null) {
          await store.initialize();
          if (isDisposed) return;
          final ownership = await _refreshAmazonEntitlement(store);
          if (ownership == SupporterOwnership.pending && !_purchased && !_storeState.value.isBusy) {
            _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.pending));
          }
        }
      } else {
        final store = _ensureStore();
        if (store != null) {
          if (_appleStoreBuild && store is AppStoreSupporterStore) {
            await _refreshAppStoreTrial(
              store,
              onFailure: (error) {
                _setStoreState(_storeState.value.copyWith(error: () => error));
              },
            );
            if (isDisposed) return;
          }
          final ownership = await _refreshEntitlement(store);
          if (isDisposed) return;
          if (ownership == SupporterOwnership.pending && !_purchased && !_storeState.value.isBusy) {
            _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.pending));
          }
        }
      }
    } catch (error, stackTrace) {
      appLogger.w('Pleazyng access initialization failed', error: error, stackTrace: stackTrace);
    } finally {
      if (!isDisposed) {
        _ready = true;
        safeNotifyListeners();
      }
    }
  }

  /// [isUnlocked] for the pre-provider startup frame, from the same build
  /// policy and entitlement cache this service starts from.
  static bool startupUnlocked(SettingsService settings, {bool? appleStoreBuild}) =>
      switch (supporterAvailabilityFor(supporterBuildMode)) {
        SupporterAvailability.hidden => false,
        SupporterAvailability.free => true,
        SupporterAvailability.purchasable =>
          (!_lgPaymentwallBuild && settings.read(SettingsService.supporterEntitlementCached)) ||
              (!(appleStoreBuild ?? _appleStoreTarget) &&
                  _trialIsActive(settings.read(SettingsService.appAccessTrialStartedAtEpochMs))),
      };

  static bool get _appleStoreTarget =>
      defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;

  static bool _trialIsActive(int startedAtEpochMs) =>
      startedAtEpochMs > 0 &&
      DateTime.now().toUtc().isBefore(
        DateTime.fromMillisecondsSinceEpoch(startedAtEpochMs, isUtc: true).add(fullAccessTrialDuration),
      );

  Future<bool> startTrial() async {
    if (!canStartTrial) return false;
    if (_appleStoreBuild) return _startAppStoreTrial();
    final startedAtEpochMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    try {
      final settings = await SettingsService.getInstance();
      if (isDisposed || !canStartTrial) return false;
      await settings.write(SettingsService.appAccessTrialStartedAtEpochMs, startedAtEpochMs);
      _trialStartedAtEpochMs = startedAtEpochMs;
      _scheduleTrialExpiry();
      safeNotifyListeners();
      return true;
    } catch (error, stackTrace) {
      appLogger.e('Pleazyng trial start could not be saved', error: error, stackTrace: stackTrace);
      return false;
    }
  }

  void _scheduleTrialExpiry() {
    _trialExpiryTimer?.cancel();
    final remaining = trialRemaining;
    if (remaining == null || remaining == Duration.zero || _purchased) return;
    _trialExpiryTimer = Timer(remaining, safeNotifyListeners);
  }

  /// Loads the lifetime unlock product and its localized price, once per process.
  Future<void> loadProduct() async {
    if (availability != SupporterAvailability.purchasable) return;
    final current = _storeState.value;
    if ((_lifetimeProductLoaded && (!_appleStoreBuild || _trialProduct != null)) || current.isLoadingProduct) return;
    if (_lgPaymentwallClient != null) {
      if (!_lgPaymentwallClient.isConfigured) {
        _setStoreState(current.copyWith(productError: () => SupporterError.paymentServiceUnavailable));
      } else {
        _setStoreState(current.copyWith(price: 'USD 2.99', productError: () => null, error: () => null));
      }
      return;
    }
    if (_amazonStoreBuild) {
      final amazonStore = _ensureAmazonStore();
      if (amazonStore == null) {
        _setStoreState(current.copyWith(productError: () => SupporterError.storeUnavailable));
        return;
      }
      _setStoreState(current.copyWith(isLoadingProduct: true, productError: () => null, error: () => null));
      SupporterError? failure;
      try {
        final products = await amazonStore.queryProducts({lifetimeUnlockProductId});
        _amazonProduct = products.firstWhereOrNull((product) => product.id == lifetimeUnlockProductId);
        if (_amazonProduct == null) {
          appLogger.w('Pleazyng: Amazon Appstore has no "$lifetimeUnlockProductId" product');
          failure = SupporterError.productNotFound;
        }
      } catch (error, stackTrace) {
        appLogger.w('Pleazyng: Amazon Appstore product query failed', error: error, stackTrace: stackTrace);
        failure = error is StateError ? SupporterError.storeUnavailable : SupporterError.productQueryFailed;
      }
      if (isDisposed) return;
      _setStoreState(
        _storeState.value.copyWith(
          isLoadingProduct: false,
          price: _amazonProduct?.displayPrice,
          productError: () => failure,
        ),
      );
      return;
    }
    final store = _ensureStore();
    if (store == null) {
      _setStoreState(
        current.copyWith(
          productError: () => SupporterError.storeUnavailable,
          trialProductError: () => _appleStoreBuild ? SupporterError.storeUnavailable : null,
        ),
      );
      return;
    }
    _setStoreState(
      current.copyWith(
        isLoadingProduct: true,
        productError: () => null,
        trialProductError: () => null,
        error: () => null,
      ),
    );
    SupporterError? failure;
    SupporterError? trialFailure;
    try {
      if (!await store.platform.isAvailable()) {
        failure = SupporterError.storeUnavailable;
        if (_appleStoreBuild) trialFailure = SupporterError.storeUnavailable;
      } else {
        final productIds = {lifetimeUnlockProductId, if (_appleStoreBuild) appStoreTrialProductId};
        final response = await store.platform.queryProductDetails(productIds);
        _product = response.productDetails.firstWhereOrNull(
          (p) => p.id == lifetimeUnlockProductId && store.acceptsProduct(p),
        );
        if (_appleStoreBuild) {
          final trial = response.productDetails.firstWhereOrNull((p) => p.id == appStoreTrialProductId);
          if (trial == null) {
            final error = response.error;
            trialFailure = error != null && error.code != _storeKitNoProducts
                ? SupporterError.productQueryFailed
                : SupporterError.trialProductNotFound;
          } else if (!_isValidAppStoreTrialProduct(trial)) {
            trialFailure = SupporterError.trialProductInvalid;
          } else {
            _trialProduct = trial;
          }
        }
        if (_product == null) {
          // StoreKit 2 reports a query that found no product as the error
          // `storekit_no_response` rather than an empty result.
          final error = response.error;
          if (error != null && error.code != _storeKitNoProducts) {
            appLogger.w('Pleazyng access: product query failed: ${error.code} ${error.message}');
            failure = SupporterError.productQueryFailed;
          } else {
            appLogger.w('Pleazyng: the store has no "$lifetimeUnlockProductId" product');
            failure = SupporterError.productNotFound;
          }
        }
      }
    } catch (error, stackTrace) {
      appLogger.w('Pleazyng access: product query failed', error: error, stackTrace: stackTrace);
      failure = SupporterError.productQueryFailed;
      if (_appleStoreBuild) trialFailure = SupporterError.productQueryFailed;
    }
    if (isDisposed) return;
    _setStoreState(
      _storeState.value.copyWith(
        isLoadingProduct: false,
        price: _product?.price,
        productError: () => failure,
        trialProductError: () => trialFailure,
      ),
    );
  }

  static bool _isValidAppStoreTrialProduct(ProductDetails product) =>
      product.id == appStoreTrialProductId &&
      product is AppStoreProduct2Details &&
      product.sk2Product.id == appStoreTrialProductId &&
      product.sk2Product.type == SK2ProductType.nonConsumable &&
      product.rawPrice == 0 &&
      product.sk2Product.price == 0;

  Future<bool> _startAppStoreTrial() async {
    final store = _ensureStore();
    final product = _trialProduct;
    if (store is! AppStoreSupporterStore || product == null || !_isValidAppStoreTrialProduct(product)) {
      _setStoreState(_storeState.value.copyWith(trialProductError: () => SupporterError.trialProductInvalid));
      return false;
    }
    if (!_appStoreTrialHistoryChecked) {
      final history = await _refreshAppStoreTrial(store);
      if (history == null || history.status != AppStoreTrialStatus.notPurchased || !canStartTrial) return false;
    }
    _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.purchasing, error: () => null));
    try {
      final launched = await store.platform.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: product));
      if (!launched) {
        _setStoreState(
          _storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => SupporterError.purchaseFailed),
        );
      }
      return launched;
    } catch (error, stackTrace) {
      appLogger.w('Pleazyng App Store trial purchase could not start', error: error, stackTrace: stackTrace);
      _setStoreState(
        _storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => SupporterError.purchaseFailed),
      );
      return false;
    }
  }

  /// Starts the lifetime purchase flow. The outcome arrives on the purchase
  /// stream and shows up in [storeState] and [hasLifetimeUnlock].
  Future<void> purchase() async {
    if (availability != SupporterAvailability.purchasable || _purchased || _storeState.value.isBusy) return;
    if (_lgPaymentwallClient != null) {
      await _purchaseLGPaymentwall();
      return;
    }
    if (_amazonStoreBuild) {
      await _startAmazonPurchase();
      return;
    }
    final store = _ensureStore();
    if (store == null) {
      _setStoreState(_storeState.value.copyWith(error: () => SupporterError.storeUnavailable));
      return;
    }
    if (_product == null) await loadProduct();
    final product = _product;
    if (product == null || isDisposed || _storeState.value.isBusy) return;
    _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.purchasing, error: () => null));
    try {
      final launched = await store.platform.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: product));
      if (!launched) {
        appLogger.w('Pleazyng access: the store did not open its purchase flow');
        _failPurchase(store);
      }
    } catch (error, stackTrace) {
      appLogger.w('Pleazyng access: purchase failed', error: error, stackTrace: stackTrace);
      _failPurchase(store);
    }
  }

  /// Restore Purchases: re-reads the store account's lifetime unlock.
  Future<void> restore() async {
    if (availability != SupporterAvailability.purchasable || _storeState.value.isBusy) return;
    if (_lgPaymentwallClient != null) {
      await _restoreLGPaymentwall();
      return;
    }
    if (_amazonStoreBuild) {
      await _restoreAmazonPurchases();
      return;
    }
    final store = _ensureStore();
    if (store == null) {
      _setStoreState(_storeState.value.copyWith(error: () => SupporterError.storeUnavailable));
      return;
    }
    _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.restoring, error: () => null));
    var synced = true;
    try {
      await store.syncForRestore();
    } on SupporterRestoreCancelled {
      if (!isDisposed) _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle));
      return;
    } catch (error, stackTrace) {
      // The history may still hold the purchase; only report this failure if
      // it does not.
      appLogger.w('Supporter: store sync for restore failed', error: error, stackTrace: stackTrace);
      synced = false;
    }
    if (isDisposed) return;
    var failure = SupporterError.restoreFailed;
    final ownership = await _refreshEntitlement(store, onFailure: (error) => failure = error);
    if (isDisposed) return;
    AppStoreTrialHistory? trialHistory;
    if (_appleStoreBuild && store is AppStoreSupporterStore) {
      trialHistory = await _refreshAppStoreTrial(store, onFailure: (error) => failure = error);
      if (isDisposed) return;
    }
    if (ownership == SupporterOwnership.owned || trialHistory?.status == AppStoreTrialStatus.owned) {
      _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => null));
      return;
    }
    if (trialHistory == null && _appleStoreBuild) {
      _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => failure));
      return;
    }
    _setStoreState(switch (ownership) {
      SupporterOwnership.owned => _storeState.value.copyWith(status: SupporterPurchaseStatus.idle),
      SupporterOwnership.pending => _storeState.value.copyWith(status: SupporterPurchaseStatus.pending),
      SupporterOwnership.revoked || SupporterOwnership.unknown => _storeState.value.copyWith(
        status: SupporterPurchaseStatus.idle,
        error: () => synced ? SupporterError.nothingToRestore : SupporterError.restoreFailed,
      ),
      null => _storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => failure),
    });
  }

  /// Drops the last purchase or restore error, so a sheet opened later starts
  /// from the offer rather than an old failure.
  void clearError() {
    if (_storeState.value.error != null && !_storeState.value.isBusy) {
      _setStoreState(_storeState.value.copyWith(error: () => null));
    }
  }

  /// Prepares the secure identity and recovery disclosure for the LG checkout.
  /// No checkout is opened until the user has acknowledged saving this code.
  Future<LgPaymentwallRecoveryOffer?> prepareLGRecoveryCode() async {
    final client = _lgPaymentwallClient;
    if (client == null || !client.isConfigured) {
      _setStoreState(_storeState.value.copyWith(error: () => SupporterError.paymentServiceUnavailable));
      return null;
    }
    _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.preparingRecovery, error: () => null));
    try {
      final offer = await client.prepareCheckoutRecoveryCode();
      if (!isDisposed) _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle));
      return offer;
    } on LgPaymentwallFailure catch (error) {
      _setStoreState(
        _storeState.value.copyWith(
          status: SupporterPurchaseStatus.idle,
          error: () => _supporterErrorForLGFailure(error),
        ),
      );
      return null;
    } catch (_) {
      _setStoreState(
        _storeState.value.copyWith(
          status: SupporterPurchaseStatus.idle,
          error: () => SupporterError.paymentServiceUnavailable,
        ),
      );
      return null;
    }
  }

  /// Re-shows the active accountless recovery code from secure storage.
  Future<String?> revealLGRecoveryCode() async {
    final client = _lgPaymentwallClient;
    if (client == null) return null;
    try {
      return await client.revealRecoveryCode();
    } catch (_) {
      _setStoreState(_storeState.value.copyWith(error: () => SupporterError.paymentRestoreFailed));
      return null;
    }
  }

  Future<bool> acknowledgeLGRecoveryCode() async {
    final client = _lgPaymentwallClient;
    if (client == null) return false;
    try {
      await client.acknowledgeRecoveryCode();
      return true;
    } catch (_) {
      _setStoreState(_storeState.value.copyWith(error: () => SupporterError.paymentServiceUnavailable));
      return false;
    }
  }

  /// Applies an imported recovery code only after the backend authenticates
  /// the existing identity and returns a valid signed ownership proof.
  Future<bool> restoreLGWithRecoveryCode(String code, {bool confirmSwitch = false}) async {
    final client = _lgPaymentwallClient;
    if (client == null || _storeState.value.isBusy) return false;
    _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.restoring, error: () => null));
    try {
      final entitlement = await client.restoreWithRecoveryCode(code, confirmSwitch: confirmSwitch);
      if (isDisposed) return false;
      if (!client.isCurrentEntitlement(entitlement)) {
        _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle));
        return false;
      }
      _setPurchased(entitlement.owned);
      _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => null));
      return true;
    } on LgPaymentwallFailure catch (error) {
      if (!isDisposed) {
        _setStoreState(
          _storeState.value.copyWith(
            status: SupporterPurchaseStatus.idle,
            error: () => _supporterErrorForLGFailure(error, restoring: true),
          ),
        );
      }
      return false;
    } catch (_) {
      if (!isDisposed) {
        _setStoreState(
          _storeState.value.copyWith(
            status: SupporterPurchaseStatus.idle,
            error: () => SupporterError.paymentRestoreFailed,
          ),
        );
      }
      return false;
    }
  }

  Future<void> _purchaseLGPaymentwall() async {
    final client = _lgPaymentwallClient!;
    if (!client.isConfigured || !client.hasLocalIdentity) {
      _setStoreState(_storeState.value.copyWith(error: () => SupporterError.paymentServiceUnavailable));
      return;
    }
    _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.purchasing, error: () => null));
    _waitingForLGCheckoutReturn = true;
    _lgCheckoutWentBackground = false;
    try {
      await client.beginCheckout();
      if (isDisposed) return;
      if (_waitingForLGCheckoutReturn) {
        // A launched checkout stays pending until a fresh Status API response
        // confirms ownership. The browser callback is never entitlement proof.
        _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.pending, error: () => null));
      }
    } on LgPaymentwallFailure catch (error) {
      _waitingForLGCheckoutReturn = false;
      _setStoreState(
        _storeState.value.copyWith(
          status: SupporterPurchaseStatus.idle,
          error: () => _supporterErrorForLGFailure(error),
        ),
      );
    } catch (_) {
      _waitingForLGCheckoutReturn = false;
      _setStoreState(
        _storeState.value.copyWith(
          status: SupporterPurchaseStatus.idle,
          error: () => SupporterError.paymentPurchaseFailed,
        ),
      );
    }
  }

  Future<void> _restoreLGPaymentwall() async {
    final client = _lgPaymentwallClient!;
    if (!client.isConfigured) {
      _setStoreState(_storeState.value.copyWith(error: () => SupporterError.paymentServiceUnavailable));
      return;
    }
    if (!client.hasLocalIdentity) {
      _setStoreState(_storeState.value.copyWith(error: () => SupporterError.paymentNothingToRestore));
      return;
    }
    _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.restoring, error: () => null));
    await _refreshLGPaymentwall(restoring: true);
  }

  Future<void> _refreshLGPaymentwall({required bool restoring}) async {
    final client = _lgPaymentwallClient!;
    try {
      final entitlement = await client.refreshEntitlement();
      if (isDisposed) return;
      if (entitlement == null) {
        _setStoreState(
          _storeState.value.copyWith(
            status: SupporterPurchaseStatus.idle,
            error: () => restoring ? SupporterError.paymentNothingToRestore : null,
          ),
        );
        return;
      }
      if (!client.isCurrentEntitlement(entitlement)) {
        _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle));
        return;
      }
      _setPurchased(entitlement.owned);
      _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => null));
    } on LgPaymentwallFailure catch (error) {
      if (!isDisposed) {
        _setStoreState(
          _storeState.value.copyWith(
            status: SupporterPurchaseStatus.idle,
            error: () => _supporterErrorForLGFailure(error, restoring: restoring),
          ),
        );
      }
    } catch (_) {
      if (!isDisposed) {
        _setStoreState(
          _storeState.value.copyWith(
            status: SupporterPurchaseStatus.idle,
            error: () => restoring ? SupporterError.paymentRestoreFailed : null,
          ),
        );
      }
    }
  }

  SupporterError _supporterErrorForLGFailure(LgPaymentwallFailure error, {bool restoring = false}) =>
      switch (error.kind) {
        LgPaymentwallFailureKind.unauthorized =>
          restoring ? SupporterError.paymentNothingToRestore : SupporterError.paymentPurchaseFailed,
        LgPaymentwallFailureKind.invalidRecoveryCode ||
        LgPaymentwallFailureKind.identitySwitchNeedsConfirmation ||
        LgPaymentwallFailureKind.invalidProof => SupporterError.paymentRestoreFailed,
        LgPaymentwallFailureKind.unavailable =>
          restoring ? SupporterError.paymentRestoreFailed : SupporterError.paymentServiceUnavailable,
      };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_lgPaymentwallClient == null || !_waitingForLGCheckoutReturn) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _lgCheckoutWentBackground = true;
    } else if (state == AppLifecycleState.resumed && _lgCheckoutWentBackground) {
      _waitingForLGCheckoutReturn = false;
      unawaited(_refreshLGPaymentwall(restoring: false));
    }
  }

  /// Creates the store and subscribes to its purchase stream on first use.
  /// Subscribing early matters: StoreKit replays unfinished transactions and
  /// Play delivers completed pending purchases to the first listener.
  SupporterStore? _ensureStore() {
    if (_amazonStoreBuild || _storeCreated || isDisposed) return _store;
    _storeCreated = true;
    final SupporterStore store;
    try {
      final created = _createStore?.call();
      if (created == null) return null;
      store = created;
    } catch (error, stackTrace) {
      appLogger.e('Supporter: store setup failed', error: error, stackTrace: stackTrace);
      return null;
    }
    _store = store;
    _purchaseSubscription = store.platform.purchaseStream.listen(
      (purchases) => unawaited(_handlePurchases(store, purchases)),
      onError: (Object error, StackTrace stackTrace) {
        appLogger.w('Supporter: purchase stream error', error: error, stackTrace: stackTrace);
      },
    );
    return store;
  }

  AmazonSupporterStore? _ensureAmazonStore() {
    if (!_amazonStoreBuild || isDisposed) return null;
    final current = _amazonStore;
    if (current != null) return current;
    final store = AmazonSupporterStore();
    _amazonStore = store;
    _amazonPurchaseSubscription = store.purchases.listen(
      (purchase) => unawaited(_handleAmazonPurchase(store, purchase)),
      onError: (Object error, StackTrace stackTrace) {
        appLogger.w('Pleazyng: Amazon Appstore purchase stream error', error: error, stackTrace: stackTrace);
      },
    );
    _amazonErrorSubscription = store.purchaseErrors.listen(
      (error) => _handleAmazonPurchaseError(store, error),
      onError: (Object error, StackTrace stackTrace) {
        appLogger.w('Pleazyng: Amazon Appstore purchase error stream failed', error: error, stackTrace: stackTrace);
      },
    );
    return store;
  }

  Future<bool> _startAmazonPurchase() async {
    final store = _ensureAmazonStore();
    if (store == null) {
      _setStoreState(_storeState.value.copyWith(error: () => SupporterError.storeUnavailable));
      return false;
    }
    if (!_lifetimeProductLoaded) await loadProduct();
    if (_amazonProduct == null || isDisposed) {
      _setStoreState(_storeState.value.copyWith(error: () => SupporterError.productNotFound));
      return false;
    }
    _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.purchasing, error: () => null));
    try {
      await store.purchase(lifetimeUnlockProductId);
      return true;
    } catch (error, stackTrace) {
      appLogger.w('Pleazyng: Amazon Appstore purchase could not start', error: error, stackTrace: stackTrace);
      _failAmazonPurchase(store);
      return false;
    }
  }

  Future<void> _restoreAmazonPurchases() async {
    final store = _ensureAmazonStore();
    if (store == null) {
      _setStoreState(_storeState.value.copyWith(error: () => SupporterError.storeUnavailable));
      return;
    }
    _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.restoring, error: () => null));
    var synced = true;
    try {
      await store.syncForRestore();
    } catch (error, stackTrace) {
      appLogger.w('Pleazyng: Amazon restore sync failed', error: error, stackTrace: stackTrace);
      synced = false;
    }
    if (isDisposed) return;
    var failure = SupporterError.restoreFailed;
    final ownership = await _refreshAmazonEntitlement(store, onFailure: (error) => failure = error);
    if (isDisposed) return;
    _setStoreState(switch (ownership) {
      SupporterOwnership.owned => _storeState.value.copyWith(status: SupporterPurchaseStatus.idle),
      SupporterOwnership.pending => _storeState.value.copyWith(status: SupporterPurchaseStatus.pending),
      SupporterOwnership.revoked || SupporterOwnership.unknown => _storeState.value.copyWith(
        status: SupporterPurchaseStatus.idle,
        error: () => synced ? SupporterError.nothingToRestore : SupporterError.restoreFailed,
      ),
      null => _storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => failure),
    });
  }

  Future<SupporterOwnership?> _refreshAmazonEntitlement(
    AmazonSupporterStore store, {
    void Function(SupporterError error)? onFailure,
  }) async {
    final generation = _entitlementGeneration;
    try {
      final purchases = await store.queryHistory();
      if (isDisposed) return null;
      if (generation != _entitlementGeneration) {
        return _purchased ? SupporterOwnership.owned : SupporterOwnership.unknown;
      }
      final amazonPurchases = purchases.where(_isAmazonPurchase).toList();
      final lifetimePurchases = amazonPurchases.where((purchase) => purchase.productId == lifetimeUnlockProductId);
      if (lifetimePurchases.any((purchase) => purchase.purchaseState == openiap.PurchaseState.Purchased)) {
        _setPurchased(true);
        _setStoreState(_storeState.value.copyWith(error: () => null));
        return SupporterOwnership.owned;
      }
      if (lifetimePurchases.any((purchase) => purchase.purchaseState == openiap.PurchaseState.Pending)) {
        return SupporterOwnership.pending;
      }
      if (generation == _entitlementGeneration) {
        if (_purchased) appLogger.i('Pleazyng: Amazon no longer reports the lifetime entitlement');
        _setPurchased(false);
      }
      _clearPendingStatus();
      return SupporterOwnership.revoked;
    } catch (error, stackTrace) {
      appLogger.w(
        'Pleazyng: Amazon purchase history unavailable; keeping the cached entitlement',
        error: error,
        stackTrace: stackTrace,
      );
      onFailure?.call(SupporterError.restoreFailed);
      return null;
    }
  }

  bool _isAmazonPurchase(openiap.Purchase purchase) =>
      purchase.store == openiap.IapStore.Amazon || purchase.storeId == 'amazon';

  Future<void> _handleAmazonPurchase(AmazonSupporterStore store, openiap.Purchase purchase) async {
    if (!_isAmazonPurchase(purchase)) return;
    if (purchase.purchaseState == openiap.PurchaseState.Pending) {
      _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.pending, error: () => null));
      return;
    }
    if (purchase.purchaseState != openiap.PurchaseState.Purchased) {
      _failAmazonPurchase(store);
      return;
    }
    switch (purchase.productId) {
      case lifetimeUnlockProductId:
        _entitlementGeneration++;
        _setPurchased(true);
        _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => null));
      default:
        return;
    }
    try {
      await store.finish(purchase);
    } catch (error, stackTrace) {
      appLogger.e('Pleazyng: Amazon transaction fulfillment failed', error: error, stackTrace: stackTrace);
    }
  }

  void _handleAmazonPurchaseError(AmazonSupporterStore store, openiap.PurchaseError error) {
    if (error.code == openiap.ErrorCode.UserCancelled) {
      if (_storeState.value.status == SupporterPurchaseStatus.purchasing) {
        _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle));
      }
      return;
    }
    appLogger.w('Pleazyng: Amazon Appstore purchase failed: ${error.code} ${error.message}');
    _failAmazonPurchase(store);
  }

  void _failAmazonPurchase(AmazonSupporterStore store) {
    if (_storeState.value.status == SupporterPurchaseStatus.purchasing) {
      _setStoreState(
        _storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => SupporterError.purchaseFailed),
      );
    }
    unawaited(_refreshAmazonEntitlement(store));
  }

  Future<void> _handlePurchases(SupporterStore store, List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (isDisposed) return;
      if (purchase.productID == lifetimeUnlockProductId) {
        await _handleLifetimeUnlockPurchase(store, purchase);
      } else if (_appleStoreBuild && store is AppStoreSupporterStore && purchase.productID == appStoreTrialProductId) {
        await _handleAppStoreTrialPurchase(store, purchase);
      } else if (purchase.productID.isEmpty && _storeState.value.status == SupporterPurchaseStatus.purchasing) {
        // Play reports a cancelled or failed billing flow without a product.
        if (purchase.status == PurchaseStatus.canceled) {
          _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle));
        } else if (purchase.status == PurchaseStatus.error) {
          appLogger.w('Supporter: purchase failed: ${purchase.error?.code} ${purchase.error?.message}');
          _failPurchase(store);
        }
      }
      // Any other product is not Pleazyng's; leave it to the store.
    }
  }

  Future<void> _handleAppStoreTrialPurchase(AppStoreSupporterStore store, PurchaseDetails purchase) async {
    switch (purchase.status) {
      case PurchaseStatus.pending:
        _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.pending, error: () => null));
        return;
      case PurchaseStatus.canceled:
        if (_storeState.value.status == SupporterPurchaseStatus.purchasing ||
            _storeState.value.status == SupporterPurchaseStatus.pending) {
          _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle));
        }
        return;
      case PurchaseStatus.error:
        appLogger.w('Supporter: App Store trial purchase failed: ${purchase.error?.code} ${purchase.error?.message}');
        _setStoreState(
          _storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => SupporterError.purchaseFailed),
        );
        return;
      case PurchaseStatus.purchased || PurchaseStatus.restored:
        final history = await _refreshAppStoreTrial(store);
        if (isDisposed) return;
        final verifiedTrial = history?.status == AppStoreTrialStatus.owned && _appStoreTrialStartedAt != null;
        if (!verifiedTrial) {
          _setStoreState(
            _storeState.value.copyWith(
              status: SupporterPurchaseStatus.idle,
              error: () => SupporterError.purchaseFailed,
            ),
          );
          if (history?.status == AppStoreTrialStatus.revoked && purchase.pendingCompletePurchase) {
            await _complete(store, purchase);
          }
          return;
        }
        _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => null));
        if (purchase.pendingCompletePurchase) await _complete(store, purchase);
    }
  }

  Future<void> _handleLifetimeUnlockPurchase(SupporterStore store, PurchaseDetails purchase) async {
    final generation = _entitlementGeneration;
    final status = purchase.status;
    var transactionVerified = false;
    if (status == PurchaseStatus.purchased || status == PurchaseStatus.restored) {
      try {
        transactionVerified = await store.verifyPurchase(purchase);
        if (generation != _entitlementGeneration) {
          if (transactionVerified && purchase.pendingCompletePurchase) {
            await _complete(store, purchase);
          }
          return;
        }
        if (!transactionVerified) {
          _failPurchase(store);
          return;
        }
      } on Object {
        if (generation != _entitlementGeneration) return;
        _failPurchase(store);
        return;
      }
    }
    if (store is AppStoreSupporterStore &&
        !store.isRevocation(purchase) &&
        (status == PurchaseStatus.purchased || status == PurchaseStatus.restored)) {
      // StoreKit's cross-platform purchase event does not expose its
      // VerificationResult. Confirm a verified lifetime transaction through
      // Transaction.all before persisting a new entitlement.
      try {
        final history = await store.queryHistory();
        if (generation != _entitlementGeneration) {
          if (transactionVerified && purchase.pendingCompletePurchase) {
            await _complete(store, purchase);
          }
          return;
        }
        if (history.ownership != SupporterOwnership.owned) {
          _failPurchase(store);
          return;
        }
      } on Object {
        if (generation != _entitlementGeneration) {
          if (transactionVerified && purchase.pendingCompletePurchase) {
            await _complete(store, purchase);
          }
          return;
        }
        _failPurchase(store);
        return;
      }
    }
    if (store.isRevocation(purchase)) {
      _entitlementGeneration++;
      appLogger.i('Supporter: the store revoked the purchase');
      _setPurchased(false);
    } else {
      switch (status) {
        case PurchaseStatus.purchased || PurchaseStatus.restored:
          _entitlementGeneration++;
          _setPurchased(true);
          _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => null));
        case PurchaseStatus.pending:
          if (!_purchased) {
            _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.pending, error: () => null));
          }
        case PurchaseStatus.canceled:
          if (_storeState.value.status == SupporterPurchaseStatus.purchasing) {
            _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle));
          }
        case PurchaseStatus.error:
          appLogger.w('Supporter: purchase failed: ${purchase.error?.code} ${purchase.error?.message}');
          if (_storeState.value.status == SupporterPurchaseStatus.purchasing) _failPurchase(store);
      }
    }
    // Completing acknowledges a Play purchase (Play refunds one left
    // unacknowledged for three days) and finishes a StoreKit transaction.
    // A pending Play purchase cannot be acknowledged until it is paid.
    if (purchase.pendingCompletePurchase && (status == PurchaseStatus.purchased || status == PurchaseStatus.restored)) {
      await _complete(store, purchase);
    }
  }

  Future<void> _complete(SupporterStore store, PurchaseDetails purchase) async {
    try {
      await store.platform.completePurchase(purchase);
    } catch (error, stackTrace) {
      // Left incomplete, the store reports it again on the next launch's
      // history refresh or transaction replay.
      appLogger.e('Supporter: completing the purchase failed', error: error, stackTrace: stackTrace);
    }
  }

  /// A purchase attempt failed. The account may already own the product (an
  /// earlier purchase on another device, or one left unfinished), so the
  /// history decides before the error stands.
  void _failPurchase(SupporterStore store) {
    if (_storeState.value.status == SupporterPurchaseStatus.purchasing) {
      _setStoreState(
        _storeState.value.copyWith(status: SupporterPurchaseStatus.idle, error: () => SupporterError.purchaseFailed),
      );
    }
    unawaited(_refreshEntitlement(store));
  }

  /// Applies the store's history. Returns null when the store could not
  /// answer, in which case the cached entitlement stands and [onFailure]
  /// learns why.
  Future<SupporterOwnership?> _refreshEntitlement(
    SupporterStore store, {
    void Function(SupporterError error)? onFailure,
  }) async {
    final generation = _entitlementGeneration;
    final SupporterHistory history;
    try {
      history = await store.queryHistory();
    } catch (error, stackTrace) {
      appLogger.w(
        'Supporter: store history unavailable; keeping the cached entitlement',
        error: error,
        stackTrace: stackTrace,
      );
      onFailure?.call(
        error is SupporterStoreUnavailable ? SupporterError.storeUnavailable : SupporterError.restoreFailed,
      );
      return null;
    }
    if (isDisposed) return null;
    if (generation != _entitlementGeneration) {
      return _purchased ? SupporterOwnership.owned : SupporterOwnership.unknown;
    }
    switch (history.ownership) {
      case SupporterOwnership.owned:
        _setPurchased(true);
        _setStoreState(_storeState.value.copyWith(error: () => null));
        for (final purchase in history.unfinished) {
          await _complete(store, purchase);
        }
      case SupporterOwnership.revoked:
        if (generation == _entitlementGeneration) {
          if (_purchased) appLogger.i('Supporter: the store no longer lists the purchase; it was refunded or revoked');
          _setPurchased(false);
        }
        _clearPendingStatus();
      case SupporterOwnership.unknown:
        _clearPendingStatus();
      case SupporterOwnership.pending:
        break;
    }
    return history.ownership;
  }

  Future<AppStoreTrialHistory?> _refreshAppStoreTrial(
    AppStoreSupporterStore store, {
    void Function(SupporterError error)? onFailure,
  }) async {
    try {
      final history = await store.queryTrialHistory();
      if (isDisposed) return null;
      _appStoreTrialHistoryChecked = true;
      _appStoreTrialPurchased = history.status != AppStoreTrialStatus.notPurchased;
      _appStoreTrialStartedAt = history.status == AppStoreTrialStatus.owned ? history.originalPurchaseDate : null;
      _scheduleTrialExpiry();
      safeNotifyListeners();
      if (history.status == AppStoreTrialStatus.invalid) onFailure?.call(SupporterError.restoreFailed);
      return history;
    } catch (error, stackTrace) {
      appLogger.w(
        'Supporter: App Store trial history unavailable; no trial access granted',
        error: error,
        stackTrace: stackTrace,
      );
      onFailure?.call(
        error is SupporterStoreUnavailable ? SupporterError.storeUnavailable : SupporterError.restoreFailed,
      );
      return null;
    }
  }

  void _clearPendingStatus() {
    if (_storeState.value.status == SupporterPurchaseStatus.pending) {
      _setStoreState(_storeState.value.copyWith(status: SupporterPurchaseStatus.idle));
    }
  }

  /// Commits a confirmed entitlement change and caches it.
  void _setPurchased(bool purchased) {
    if (isDisposed || _purchased == purchased) return;
    _purchased = purchased;
    if (!_isLGPaymentwallBuild) unawaited(_persist(purchased));
    if (purchased) _trialExpiryTimer?.cancel();
    safeNotifyListeners();
  }

  Future<void> _persist(bool purchased) async {
    try {
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.supporterEntitlementCached, purchased);
    } catch (error, stackTrace) {
      appLogger.e('Pleazyng access: caching the lifetime unlock failed', error: error, stackTrace: stackTrace);
    }
  }

  void _setStoreState(SupporterStoreState state) {
    if (isDisposed) return;
    _storeState.value = state;
  }

  @override
  void dispose() {
    if (_lgPaymentwallClient != null) {
      WidgetsBinding.instance.removeObserver(this);
      _lgPaymentwallClient.close();
    }
    _reviewExpiryTimer?.cancel();
    unawaited(_purchaseSubscription?.cancel());
    unawaited(_amazonPurchaseSubscription?.cancel());
    unawaited(_amazonErrorSubscription?.cancel());
    unawaited(_amazonStore?.dispose());
    _trialExpiryTimer?.cancel();
    _storeState.dispose();
    super.dispose();
  }
}

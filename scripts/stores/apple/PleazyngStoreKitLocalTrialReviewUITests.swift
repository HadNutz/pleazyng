import Foundation
import StoreKit
import StoreKitTest
import XCTest

final class PleazyngStoreKitLocalTrialReviewUITests: XCTestCase {
  private let appBundleID = "org.snapetech.pleazyng"
  private let trialProductID = "pleazyng_7_day_trial"
  private let lifetimeProductID = "pleazyng_lifetime_unlock"

  func testCaptureTrialBackedFilesBooksAndAccessSheet() async throws {
    let configurationURL = try XCTUnwrap(
      Bundle(for: PleazyngStoreKitLocalTrialReviewUITests.self).url(
        forResource: "pleazyng-trial-review",
        withExtension: "storekit"
      ),
      "The pinned LOCALTEST StoreKit catalog was not bundled with the XCTest target"
    )
    let session = try SKTestSession(contentsOf: configurationURL)
    session.resetToDefaultState()
    session.storefront = "USA"
    session.locale = Locale(identifier: "en_US")
    session.disableDialogs = true
    session.clearTransactions()
    XCTAssertTrue(session.allTransactions().isEmpty, "The LOCALTEST store must begin without transactions")

    let transactionsBeforeLaunch = session.allTransactions()
    XCTAssertTrue(transactionsBeforeLaunch.isEmpty, "The LOCALTEST store must be empty before the app starts")

    // The test plan associates the exact receipt-verified product bundle
    // with this UI test. The user-visible button below starts the free trial
    // through the actual product app and its native StoreKit integration.
    let app = XCUIApplication(bundleIdentifier: appBundleID)
    app.launch()
    attachScreenshot(of: app, named: "pleazyng-diagnostic-after-launch-\(platformName())")
    attachText(app.debugDescription, named: "pleazyng-diagnostic-accessibility-after-launch-\(platformName())")

    let trialButton = app.buttons["Start my 7-day free trial"]
    XCTAssertTrue(trialButton.waitForExistence(timeout: 90), "The actual product trial offer did not load")
    XCTAssertTrue(trialButton.isEnabled, "The actual product trial offer is unavailable")
    let lifetimeOffer = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Unlock every feature", "$2.99")
    ).firstMatch
    XCTAssertTrue(lifetimeOffer.waitForExistence(timeout: 60), "The scheme-associated LOCALTEST catalog did not load")
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS[c] %@", "There is no subscription or automatic charge")
      )
      .firstMatch.exists,
      "The actual product trial disclosure was not visible"
    )
    let trialOfferShown = trialButton.exists
    let trialOfferLifetimePriceShown = lifetimeOffer.exists
    let lifetimeDisplayPrice = lifetimeOffer.label
    attachScreenshot(of: app, named: "pleazyng-localtest-trial-offer-\(platformName())")
    select(trialButton, in: app)

    let useFiles = app.buttons["Use files and books"]
    XCTAssertTrue(useFiles.waitForExistence(timeout: 90), "The app did not unlock after its LOCALTEST trial purchase")
    let trialTransactions = session.allTransactions()
    XCTAssertEqual(trialTransactions.count, 1, "The actual product CTA must create only one LOCALTEST trial")
    let original = try XCTUnwrap(trialTransactions.first)
    XCTAssertEqual(original.productIdentifier, trialProductID)
    XCTAssertEqual(original.state, .purchased)
    XCTAssertFalse(trialTransactions.contains { $0.productIdentifier == lifetimeProductID })

    select(useFiles, in: app)

    let addSource = app.buttons["Add source"]
    XCTAssertTrue(addSource.waitForExistence(timeout: 60), "The product did not open its local Files and Books screen")
    XCTAssertTrue(app.buttons["Import files"].exists, "The local library import action was missing")
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Add a source or import a book"))
        .firstMatch.exists,
      "Expected the actual empty local library, without seeded media or a server"
    )
    let filesBooksScreenOpened = addSource.exists
    attachScreenshot(of: app, named: "pleazyng-localtest-files-books-\(platformName())")

    openSettings(in: app)
    let lifetimeTile = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "Pleazyng lifetime access")
    ).firstMatch
    XCTAssertTrue(lifetimeTile.waitForExistence(timeout: 60), "The actual product Settings row was not available")
    select(lifetimeTile, in: app)

    let activeTrial = app.staticTexts["Your 7-day full-feature trial is active."]
    XCTAssertTrue(
      activeTrial.waitForExistence(timeout: 60), "The actual app did not restore the native trial entitlement")
    let restoreButton = app.buttons["Restore lifetime purchase"]
    XCTAssertTrue(restoreButton.waitForExistence(timeout: 60), "The real access sheet did not show its Restore action")
    let lifetimePrice = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Unlock every feature", "$2.99")
    ).firstMatch
    XCTAssertTrue(
      lifetimePrice.waitForExistence(timeout: 60), "The app did not show the queried LOCALTEST lifetime price")
    let activeTrialShown = activeTrial.exists
    let accessSheetLifetimePriceShown = lifetimePrice.exists
    attachScreenshot(of: app, named: "pleazyng-localtest-supporter-\(platformName())")

    let finalTransactions = session.allTransactions()
    XCTAssertEqual(finalTransactions.count, 1, "Opening product screens must not change the local transaction history")
    let finalTrial = try XCTUnwrap(finalTransactions.first)
    XCTAssertEqual(finalTrial.productIdentifier, trialProductID)
    XCTAssertEqual(finalTrial.state, .purchased)
    XCTAssertEqual(finalTrial.originalTransactionIdentifier, original.originalTransactionIdentifier)
    XCTAssertEqual(finalTrial.purchaseDate, original.purchaseDate)
    XCTAssertFalse(finalTransactions.contains { $0.productIdentifier == lifetimeProductID })

    let record: [String: Any] = [
      "environment": "LOCALTEST",
      "qualification":
        "The actual product UI started a native Apple StoreKitTest free-trial transaction using the exact scheme-associated local catalog. This is local test evidence only, not App Store Connect, App Store Sandbox, or live purchase evidence.",
      "storefront": "USA",
      "catalog_queries": [
        "trial_product_id": trialProductID,
        "lifetime_product_id": lifetimeProductID,
        "lifetime_display_price": lifetimeDisplayPrice,
      ],
      "transactions": finalTransactions.map { transaction in
        [
          "product_id": transaction.productIdentifier,
          "state": transaction.state == .purchased ? "purchased" : "other",
          "transaction_id": String(transaction.identifier),
          "original_transaction_id": String(transaction.originalTransactionIdentifier),
          "purchase_date": ISO8601DateFormatter().string(from: transaction.purchaseDate),
          "expiration_date": optionalDate(transaction.expirationDate),
          "cancel_date": optionalDate(transaction.cancelDate),
        ]
      },
      "history": [
        "beforeAppLaunch": [
          "transactionCount": transactionsBeforeLaunch.count
        ],
        "afterProductTrialCTA": [
          "transactionCount": trialTransactions.count,
          "originalTransactionId": String(original.originalTransactionIdentifier),
          "purchaseDate": ISO8601DateFormatter().string(from: original.purchaseDate),
        ],
        "afterProductNavigation": [
          "transactionCount": finalTransactions.count,
          "originalTransactionId": String(finalTrial.originalTransactionIdentifier),
          "purchaseDate": ISO8601DateFormatter().string(from: finalTrial.purchaseDate),
        ],
      ],
      "app_behavior": [
        "trial_offer_shown": trialOfferShown,
        "trial_offer_lifetime_price_shown": trialOfferLifetimePriceShown,
        "trial_started_via_product_ui": true,
        "transaction_created_outside_product_app_ui": false,
        "active_trial_restored_by_app": activeTrialShown,
        "files_and_books_screen_opened": filesBooksScreenOpened,
        "active_trial_sheet_shown": activeTrialShown,
        "lifetime_price_shown": accessSheetLifetimePriceShown,
        "lifetime_purchase_activated": false,
        "lifetime_transaction_created": false,
      ],
      "raw_jws_included": false,
    ]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "pleazyng-storekit-macos-tvos-localtest-record"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func platformName() -> String {
    #if os(tvOS)
      return "tvos"
    #else
      return "macos"
    #endif
  }

  private func select(_ element: XCUIElement, in app: XCUIApplication) {
    #if os(tvOS)
      let deadline = Date().addingTimeInterval(45)
      while !element.hasFocus && Date() < deadline {
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 0.2)
      }
      XCTAssertTrue(element.hasFocus, "The requested actual tvOS control did not receive remote focus")
      XCUIRemote.shared.press(.select)
    #else
      XCTAssertTrue(element.isHittable, "The requested actual Mac control is not hittable")
      element.tap()
    #endif
  }

  private func openSettings(in app: XCUIApplication) {
    #if os(tvOS)
      let homeTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home")).firstMatch
      XCTAssertTrue(homeTab.waitForExistence(timeout: 30), "The actual Home navigation action was not available")
      select(homeTab, in: app)
      let profilesMenu = app.buttons["Profiles"]
      XCTAssertTrue(profilesMenu.waitForExistence(timeout: 30), "The actual Profiles menu was not available")
      select(profilesMenu, in: app)
      let settingsItem = app.buttons["Settings"]
      XCTAssertTrue(settingsItem.waitForExistence(timeout: 30), "The actual Settings action was not available")
      select(settingsItem, in: app)
    #else
      app.activate()
      app.typeKey(",", modifierFlags: .command)
    #endif
  }

  private func optionalDate(_ value: Date?) -> Any {
    guard let value else { return NSNull() }
    return ISO8601DateFormatter().string(from: value)
  }

  private func attachScreenshot(of app: XCUIApplication, named name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func attachText(_ value: String, named name: String) {
    let attachment = XCTAttachment(string: value)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

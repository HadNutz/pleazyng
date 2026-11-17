import Foundation
import StoreKit
import StoreKitTest
import XCTest
#if os(macOS)
import CoreGraphics
import ImageIO
import Vision
#endif

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

    #if os(macOS)
      assertVisionWindowCoordinateScale()
      try tapMacVisibleText("Start fresh", in: app, attachmentName: "pleazyng-macos-legacy-onboarding")
      let afterOnboarding = try waitForMacVisibleText(
        "Start my 7-day free trial", in: app, attachmentName: "pleazyng-diagnostic-after-onboarding-macos",
        timeout: 90)
      XCTAssertTrue(
        joinedText(afterOnboarding).contains("Read, listen, and watch from your own files"),
        "The actual first-run app access screen did not appear after choosing Start fresh")
    #endif

    var trialOfferShown = false
    var trialOfferLifetimePriceShown = false
    var lifetimeDisplayPrice = ""
    #if os(macOS)
      let offer = try waitForMacVisibleText(
        "Start my 7-day free trial", in: app, attachmentName: "pleazyng-localtest-trial-offer-macos",
        timeout: 60)
      let offerText = joinedText(offer)
      XCTAssertTrue(offerText.contains("Unlock every feature"), "The queried LOCALTEST lifetime product was not visible")
      XCTAssertTrue(offerText.contains("$2.99"), "The queried LOCALTEST lifetime price was not visible")
      XCTAssertTrue(
        offerText.contains("There is no subscription or automatic charge"),
        "The actual product trial disclosure was not visible")
      trialOfferShown = true
      trialOfferLifetimePriceShown = offerText.contains("Unlock every feature") && offerText.contains("$2.99")
      lifetimeDisplayPrice = offer.first(where: { $0.text.contains("$2.99") })?.text ?? "$2.99"
      try tapMacVisibleText(
        "Start my 7-day free trial", in: app, attachmentName: "pleazyng-macos-trial-offer-action")
    #else
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
      trialOfferShown = trialButton.exists
      trialOfferLifetimePriceShown = lifetimeOffer.exists
      lifetimeDisplayPrice = lifetimeOffer.label
      attachScreenshot(of: app, named: "pleazyng-localtest-trial-offer-\(platformName())")
      select(trialButton, in: app)
    #endif

    #if os(macOS)
      _ = try waitForMacVisibleText(
        "Use files and books", in: app, attachmentName: "pleazyng-diagnostic-after-trial-purchase-macos",
        timeout: 90)
    #else
      let useFiles = app.buttons["Use files and books"]
      XCTAssertTrue(useFiles.waitForExistence(timeout: 90), "The app did not unlock after its LOCALTEST trial purchase")
    #endif
    let trialTransactions = session.allTransactions()
    XCTAssertEqual(trialTransactions.count, 1, "The actual product CTA must create only one LOCALTEST trial")
    let original = try XCTUnwrap(trialTransactions.first)
    XCTAssertEqual(original.productIdentifier, trialProductID)
    XCTAssertEqual(original.state, .purchased)
    XCTAssertFalse(trialTransactions.contains { $0.productIdentifier == lifetimeProductID })

    #if os(macOS)
      try tapMacVisibleText("Use files and books", in: app, attachmentName: "pleazyng-macos-use-files-action")
    #else
      select(useFiles, in: app)
    #endif

    var filesBooksScreenOpened = false
    #if os(macOS)
      let files = try waitForMacVisibleText(
        "Add a source or import a book", in: app, attachmentName: "pleazyng-localtest-files-books-macos",
        timeout: 60)
      let filesText = joinedText(files)
      XCTAssertTrue(filesText.contains("Add source"), "The real local library Add source action is missing")
      XCTAssertTrue(filesText.contains("Import files"), "The real local library Import files action is missing")
      filesBooksScreenOpened = true
    #else
      let addSource = app.buttons["Add source"]
      XCTAssertTrue(addSource.waitForExistence(timeout: 60), "The product did not open its local Files and Books screen")
      XCTAssertTrue(app.buttons["Import files"].exists, "The local library import action was missing")
      XCTAssertTrue(
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Add a source or import a book"))
          .firstMatch.exists,
        "Expected the actual empty local library, without seeded media or a server"
      )
      filesBooksScreenOpened = addSource.exists
      attachScreenshot(of: app, named: "pleazyng-localtest-files-books-\(platformName())")
    #endif

    openSettings(in: app)
    #if os(macOS)
      _ = try waitForMacVisibleText(
        "Pleazyng lifetime access", in: app, attachmentName: "pleazyng-diagnostic-settings-macos",
        timeout: 60)
      try tapMacVisibleText(
        "Pleazyng lifetime access", in: app, attachmentName: "pleazyng-macos-lifetime-settings-action")
    #endif
    #if os(tvOS)
      let lifetimeTile = app.descendants(matching: .any).matching(
        NSPredicate(format: "label CONTAINS %@", "Pleazyng lifetime access")
      ).firstMatch
      XCTAssertTrue(lifetimeTile.waitForExistence(timeout: 60), "The actual product Settings row was not available")
      select(lifetimeTile, in: app)
    #endif

    var activeTrialShown = false
    var accessSheetLifetimePriceShown = false
    #if os(macOS)
      let accessSheet = try waitForMacVisibleText(
        "Your 7-day full-feature trial is active.", in: app,
        attachmentName: "pleazyng-localtest-supporter-macos", timeout: 60)
      let accessText = joinedText(accessSheet)
      XCTAssertTrue(accessText.contains("Restore lifetime purchase"), "The real access sheet did not show its Restore action")
      XCTAssertTrue(accessText.contains("$2.99"), "The app did not show the queried LOCALTEST lifetime price")
      activeTrialShown = true
      accessSheetLifetimePriceShown = accessText.contains("$2.99")
    #else
      let activeTrial = app.staticTexts["Your 7-day full-feature trial is active."]
      let restoreButton = app.buttons["Restore lifetime purchase"]
      let lifetimePrice = app.buttons.matching(
        NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Unlock every feature", "$2.99")
      ).firstMatch
      XCTAssertTrue(
        activeTrial.waitForExistence(timeout: 60), "The actual app did not restore the native trial entitlement")
      XCTAssertTrue(restoreButton.waitForExistence(timeout: 60), "The real access sheet did not show its Restore action")
      XCTAssertTrue(
        lifetimePrice.waitForExistence(timeout: 60), "The app did not show the queried LOCALTEST lifetime price")
      activeTrialShown = activeTrial.exists
      accessSheetLifetimePriceShown = lifetimePrice.exists
      attachScreenshot(of: app, named: "pleazyng-localtest-supporter-\(platformName())")
    #endif

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
    #if os(macOS)
      let window = app.windows.firstMatch
      let screenshot = window.exists ? window.screenshot() : app.screenshot()
    #else
      let screenshot = app.screenshot()
    #endif
    attachScreenshot(screenshot, named: name)
  }

  private func attachScreenshot(_ screenshot: XCUIScreenshot, named name: String) {
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  #if os(macOS)
    private struct MacScreenText {
      let text: String
      let boundingBox: CGRect
    }

    private func waitForMacVisibleText(
      _ expected: String, in app: XCUIApplication, attachmentName: String, timeout: TimeInterval
    ) throws -> [MacScreenText] {
      let window = app.windows.firstMatch
      guard window.waitForExistence(timeout: min(timeout, 30)) else {
        throw NSError(
          domain: "PleazyngStoreKitReviewCapture", code: 4,
          userInfo: [NSLocalizedDescriptionKey: "The real app window did not appear before the OCR deadline"])
      }
      let deadline = Date().addingTimeInterval(timeout)
      var latest: [MacScreenText] = []
      var latestScreenshot: XCUIScreenshot?
      repeat {
        let screenshot = window.screenshot()
        latestScreenshot = screenshot
        latest = try recognizeMacScreenText(in: screenshot)
        if joinedText(latest).localizedCaseInsensitiveContains(expected) {
          attachScreenshot(screenshot, named: attachmentName)
          attachText(app.debugDescription, named: "\(attachmentName)-accessibility")
          attachText(macScreenTextJSON(latest), named: "\(attachmentName)-vision-ocr")
          return latest
        }
        Thread.sleep(forTimeInterval: 0.5)
      } while Date() < deadline

      if let latestScreenshot {
        attachScreenshot(latestScreenshot, named: "\(attachmentName)-timeout")
        attachText(macScreenTextJSON(latest), named: "\(attachmentName)-timeout-vision-ocr")
        attachText(app.debugDescription, named: "\(attachmentName)-timeout-accessibility")
      }
      throw NSError(
        domain: "PleazyngStoreKitReviewCapture", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for visible text \(expected.debugDescription); OCR saw: \(joinedText(latest))"])
    }

    private func tapMacVisibleText(
      _ expected: String, in app: XCUIApplication, attachmentName: String, timeout: TimeInterval = 30
    ) throws {
      let window = app.windows.firstMatch
      let button = app.buttons[expected]
      if button.exists && button.isHittable {
        button.tap()
        attachText("Used the real XCTest accessibility button for \(expected)", named: "\(attachmentName)-action")
        return
      }

      let lines = try waitForMacVisibleText(
        expected, in: app, attachmentName: "\(attachmentName)-before-action", timeout: timeout)
      let matchingLines = lines.filter { $0.text.localizedCaseInsensitiveContains(expected) }
      guard matchingLines.count == 1, let match = matchingLines.first else {
        throw NSError(
          domain: "PleazyngStoreKitReviewCapture", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "Expected one visible OCR hit for \(expected.debugDescription), got \(matchingLines.count)"])
      }
      let offset = try macWindowOffset(forVisionBounds: match.boundingBox)
      attachText(
        "Used the observed OCR bounds \(NSStringFromRect(match.boundingBox)) to click visible text \(expected.debugDescription) at normalized window offset (\(offset.dx), \(offset.dy)).",
        named: "\(attachmentName)-action")
      window.coordinate(withNormalizedOffset: offset).tap()
    }

    private func macWindowOffset(forVisionBounds bounds: CGRect) throws -> CGVector {
      guard bounds.minX >= 0, bounds.minY >= 0, bounds.maxX <= 1, bounds.maxY <= 1,
            bounds.width > 0, bounds.height > 0 else {
        throw NSError(
          domain: "PleazyngStoreKitReviewCapture", code: 5,
          userInfo: [NSLocalizedDescriptionKey: "Vision returned a text box outside normalized screenshot bounds: \(NSStringFromRect(bounds))"])
      }
      return CGVector(dx: bounds.midX, dy: 1 - bounds.midY)
    }

    private func assertVisionWindowCoordinateScale() {
      let upperScreenText = CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2)
      let lowerScreenText = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
      do {
        let upperOffset = try macWindowOffset(forVisionBounds: upperScreenText)
        let lowerOffset = try macWindowOffset(forVisionBounds: lowerScreenText)
        XCTAssertEqual(upperOffset.dx, 0.2, accuracy: 0.0001)
        XCTAssertEqual(upperOffset.dy, 0.2, accuracy: 0.0001)
        XCTAssertEqual(lowerOffset.dx, 0.2, accuracy: 0.0001)
        XCTAssertEqual(lowerOffset.dy, 0.8, accuracy: 0.0001)
      } catch {
        XCTFail("The Vision-to-window coordinate transform rejected a normalized test rectangle: \(error)")
      }
    }

    private func recognizeMacScreenText(in screenshot: XCUIScreenshot) throws -> [MacScreenText] {
      guard let source = CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(
          domain: "PleazyngStoreKitReviewCapture", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "XCTest did not provide a decodable PNG screenshot"])
      }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = false
      request.recognitionLanguages = ["en-US"]
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
      return (request.results ?? []).compactMap { observation in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        return MacScreenText(text: text, boundingBox: observation.boundingBox)
      }
    }

    private func joinedText(_ lines: [MacScreenText]) -> String {
      lines.map(\.text).joined(separator: " ")
    }

    private func macScreenTextJSON(_ lines: [MacScreenText]) -> String {
      let records: [[String: Any]] = lines.map { line in
        [
          "text": line.text,
          "normalized_bounds": [
            line.boundingBox.minX, line.boundingBox.minY,
            line.boundingBox.width, line.boundingBox.height,
          ],
        ]
      }
      guard let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8) else {
        return "Could not serialize native Vision OCR observations"
      }
      return text
    }
  #endif

  private func attachText(_ value: String, named name: String) {
    let attachment = XCTAttachment(string: value)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

import Foundation
import StoreKit
import StoreKitTest
import XCTest

final class PleazyngTrialReviewUITests: XCTestCase {
    private let appBundleID = "org.snapetech.pleazyng"
    private let trialProductID = "pleazyng_7_day_trial"
    private let lifetimeProductID = "pleazyng_lifetime_unlock"

    func testCaptureRealTrialOfferAndActiveAccess() throws {
        let configurationURL = try XCTUnwrap(
            Bundle(for: PleazyngTrialReviewUITests.self).url(
                forResource: "pleazyng-trial-review",
                withExtension: "storekit"
            ),
            "The local StoreKit Test configuration was not bundled with the test runner"
        )
        let session = try SKTestSession(contentsOf: configurationURL)
        session.resetToDefaultState()
        session.storefront = "USA"
        session.locale = Locale(identifier: "en_US")
        session.disableDialogs = true
        session.clearTransactions()
        XCTAssertTrue(session.allTransactions().isEmpty, "The LOCALTEST store session must start without prior transactions")

        let app = XCUIApplication(bundleIdentifier: appBundleID)
        app.launch()

        let trialButton = app.buttons["Start my 7-day free trial"]
        XCTAssertTrue(trialButton.waitForExistence(timeout: 90), "The app did not load its real StoreKit trial product")
        XCTAssertTrue(trialButton.isEnabled, "The real App Store trial offer is not available to start")
        let localLifetimePrice = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Unlock every feature", "$2.99")
        ).firstMatch
        XCTAssertTrue(localLifetimePrice.waitForExistence(timeout: 60), "The app did not display the queried LOCALTEST lifetime price")
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "There is no subscription or automatic charge")
            ).firstMatch.exists,
            "The live trial disclosure was not visible"
        )
        let trialProductVisibleInApp = trialButton.exists
        let lifetimeProductVisibleInApp = localLifetimePrice.exists
        let lifetimeDisplayPrice = localLifetimePrice.label
        attachScreenshot(of: app, named: "pleazyng-trial-offer-localtest")

        // This is the actual app's UI action. Do not call SKTestSession.buyProduct
        // or activate the lifetime purchase button anywhere in this test.
        trialButton.tap()
        let useFiles = app.buttons["Use files and books"]
        XCTAssertTrue(
            useFiles.waitForExistence(timeout: 90),
            "The app did not leave the trial gate after its StoreKit transaction was verified"
        )
        let trialGateOpenedAfterPurchase = useFiles.exists

        let trialTransactions = session.allTransactions().filter { $0.productIdentifier == trialProductID }
        XCTAssertEqual(trialTransactions.count, 1, "Expected exactly one LOCALTEST trial transaction")
        let transaction = try XCTUnwrap(trialTransactions.first)
        XCTAssertEqual(transaction.state, .purchased, "The LOCALTEST trial transaction did not complete")
        XCTAssertFalse(
            session.allTransactions().contains { $0.productIdentifier == lifetimeProductID },
            "The test must never create a lifetime purchase transaction"
        )

        useFiles.tap()
        let addSource = app.buttons["Add source"]
        XCTAssertTrue(addSource.waitForExistence(timeout: 60), "The actual local Files and Books screen did not open")
        XCTAssertTrue(app.buttons["Import files"].exists, "The actual local screen is missing its import action")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Add a source or import a book"))
                .firstMatch.exists,
            "Expected the real empty local library state with no server or seeded media"
        )
        let localFilesScreenOpened = addSource.exists
        attachScreenshot(of: app, named: "pleazyng-trial-active-files-books-localtest")

        let settingsTab = app.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 60), "The real Settings navigation action was not available")
        settingsTab.tap()
        let lifetimeTile = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Pleazyng lifetime access")
        ).firstMatch
        XCTAssertTrue(lifetimeTile.waitForExistence(timeout: 60), "The actual lifetime-access Settings row was not available")
        lifetimeTile.tap()

        let restoreButton = app.buttons["Restore lifetime purchase"]
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 60), "The real lifetime sheet did not show Restore")
        XCTAssertTrue(localLifetimePrice.waitForExistence(timeout: 60), "The real lifetime sheet lost the queried price")
        let activeTrial = app.staticTexts["Your 7-day full-feature trial is active."]
        XCTAssertTrue(activeTrial.waitForExistence(timeout: 30), "App Store transaction history did not show the active trial")

        restoreButton.tap()
        let restoreIdle = NSPredicate(format: "isEnabled == true")
        expectation(for: restoreIdle, evaluatedWith: restoreButton)
        waitForExpectations(timeout: 90)
        XCTAssertTrue(activeTrial.exists, "Restore changed the verified local trial entitlement")
        XCTAssertFalse(
            app.staticTexts["No Pleazyng lifetime purchase was found for this store account."].exists,
            "A verified trial history should let the actual restore path complete without claiming lifetime ownership"
        )
        XCTAssertFalse(
            session.allTransactions().contains { $0.productIdentifier == lifetimeProductID },
            "Restore must not create or buy a lifetime transaction"
        )
        let activeTrialShownAfterRestore = activeTrial.exists
        let restoreActionCompleted = restoreButton.isEnabled
        attachScreenshot(of: app, named: "pleazyng-trial-active-supporter-localtest")

        app.terminate()
        app.launch()
        let relaunchedLocalScreen = app.buttons["Add source"]
        XCTAssertTrue(
            relaunchedLocalScreen.waitForExistence(timeout: 90),
            "Fresh launch did not restore the active trial from the app's verified StoreKit history"
        )

        let record: [String: Any] = [
            "environment": "LOCALTEST",
            "qualification": "Xcode StoreKitTest local configuration only; not App Store Connect or App Store Sandbox evidence.",
            "productQueries": [
                "trialProductVisibleInApp": trialProductVisibleInApp,
                "lifetimeProductVisibleInApp": lifetimeProductVisibleInApp,
                "lifetimeDisplayPrice": lifetimeDisplayPrice,
                "storefront": "USA",
            ],
            "trialTransaction": [
                "productID": transaction.productIdentifier,
                "state": "purchased",
                "testTransactionIdentifier": transaction.identifier,
                "originalTestTransactionIdentifier": transaction.originalTransactionIdentifier,
                "purchaseDate": ISO8601DateFormatter().string(from: transaction.purchaseDate),
                "expirationDate": optionalDate(transaction.expirationDate),
                "cancelDate": optionalDate(transaction.cancelDate),
            ],
            "appBehavior": [
                "trialGateOpenedAfterLivePurchaseAction": trialGateOpenedAfterPurchase,
                "localFilesAndBooksScreenOpened": localFilesScreenOpened,
                "activeTrialShownByAppAfterRestore": activeTrialShownAfterRestore,
                "restoreActionCompleted": restoreActionCompleted,
                "activeTrialRestoredAfterFreshRelaunch": relaunchedLocalScreen.exists,
                "lifetimePurchaseActivated": false,
                "lifetimeTransactionCreated": false,
            ],
            "allLocalTestTransactions": session.allTransactions().map { item in
                [
                    "productID": item.productIdentifier,
                    "state": item.state == .purchased ? "purchased" : "other",
                    "testTransactionIdentifier": item.identifier,
                    "originalTestTransactionIdentifier": item.originalTransactionIdentifier,
                    "purchaseDate": ISO8601DateFormatter().string(from: item.purchaseDate),
                ]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "pleazyng-trial-storekit-localtest-record"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func optionalDate(_ value: Date?) -> Any {
        guard let value else { return NSNull() }
        return ISO8601DateFormatter().string(from: value)
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

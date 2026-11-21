import UIKit
import XCTest

@testable import Pleazyng

#if compiler(>=6.4)
  /// Built with the iOS 27 SDK, the app gets its video-only external-display
  /// scene only for a registered scene accessory; iOS mirrors the device
  /// without one (#2471).
  final class ExternalDisplayAccessoryTests: XCTestCase {
    @MainActor
    func testRootViewControllerRegistersExternalDisplayAccessory() throws {
      guard #available(iOS 27.0, *) else { throw XCTSkip("Scene accessories need iOS 27") }

      let controller = try XCTUnwrap(
        UIApplication.shared.connectedScenes
          .compactMap { $0 as? UIWindowScene }
          .filter { !ExternalDisplayManager.isExternalDisplayRole($0.session.role) }
          .flatMap(\.windows)
          .lazy.compactMap { $0.rootViewController as? PlezyFlutterViewController }
          .first)
      let registration = try XCTUnwrap(controller.externalDisplayAccessory as? UISceneAccessoryRegistration)
      XCTAssertTrue(registration.isEnabled)
    }

    @MainActor
    func testExternalDisplayAccessoryConfigurationUsesExternalDisplaySceneDelegate() throws {
      guard #available(iOS 27.0, *) else { throw XCTSkip("Scene accessories need iOS 27") }

      let configuration = ExternalDisplayManager.makeSceneAccessoryConfiguration()
      XCTAssertEqual(configuration.name, "external-display")
      XCTAssertEqual(configuration.role, .windowExternalDisplayNonInteractive)
      XCTAssertTrue(configuration.sceneClass == UIWindowScene.self)
      XCTAssertTrue(configuration.delegateClass == ExternalDisplaySceneDelegate.self)
    }
  }
#endif

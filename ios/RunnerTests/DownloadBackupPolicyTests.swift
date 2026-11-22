import Foundation
import XCTest

@testable import Pleazyng

final class DownloadBackupPolicyTests: XCTestCase {
  func testManagedRootIsExcludedWithoutExcludingSiblingDocuments() throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let downloads = base.appendingPathComponent("downloads", isDirectory: true)
    let documents = base.appendingPathComponent("personal", isDirectory: true)
    try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
    try manager.createDirectory(at: documents, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }

    XCTAssertTrue(try DownloadBackupPolicy.exclude(downloads, allowedRoots: [downloads]))
    XCTAssertEqual(try downloads.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    XCTAssertFalse(try DownloadBackupPolicy.exclude(documents, allowedRoots: [downloads]))
    XCTAssertNotEqual(try documents.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    XCTAssertFalse(try DownloadBackupPolicy.exclude(base, allowedRoots: [downloads]))

    // Recreated directories need their own attribute; a former exclusion is
    // not treated as a permanent cached success by the policy.
    try manager.removeItem(at: downloads)
    try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
    XCTAssertTrue(try DownloadBackupPolicy.exclude(downloads, allowedRoots: [downloads]))
    XCTAssertEqual(try downloads.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }
}

import Foundation

let appPath = CommandLine.arguments.dropFirst().first ?? ""
let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
let bundle = Bundle(url: appURL)
let executableURL = bundle?.executableURL
let report: [String: Any] = [
  "app_path": appURL.path,
  "bundle_created": bundle != nil,
  "bundle_identifier": bundle?.bundleIdentifier as Any? ?? NSNull(),
  "executable_path": executableURL?.path as Any? ?? NSNull(),
  "executable_exists": executableURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false,
]

let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))

import Foundation
import SwiftUI

@_silgen_name("avcodec_version")
private func avcodec_version() -> UInt32

@main
struct StaticMPVKitProbeApp: App {
    var body: some Scene {
        WindowGroup {
            let version = avcodec_version()
            Text("avcodec_version: \(version)")
                .onAppear {
                    let fileManager = FileManager.default
                    let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    let marker = cacheDirectory.appendingPathComponent("avcodec-version.txt")
                    do {
                        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                        try "\(version)\n".write(to: marker, atomically: true, encoding: .utf8)
                    } catch {
                        fatalError("Could not write the avcodec version marker: \(error)")
                    }
                }
        }
    }
}

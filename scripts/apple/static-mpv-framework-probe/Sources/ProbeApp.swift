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
                    let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("avcodec-version.txt")
                    do {
                        try "\(version)\n".write(to: marker, atomically: true, encoding: .utf8)
                    } catch {
                        fatalError("Could not write the avcodec version marker: \(error)")
                    }
                }
        }
    }
}

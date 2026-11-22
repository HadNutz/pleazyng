import AVFoundation
import Flutter
import UIKit

@testable import Pleazyng

final class ControllablePropertyCore: MpvPlayerCoreBase {
  var nextResult: Result<Void, Error>?
  private(set) var propertyCalls: [(String, String)] = []
  private var pendingCompletion: ((Result<Void, Error>) -> Void)?

  override func setPropertyAsync(
    _ name: String,
    value: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    propertyCalls.append((name, value))
    if let nextResult {
      self.nextResult = nil
      completion(nextResult)
    } else {
      pendingCompletion = completion
    }
  }

  func finish(_ result: Result<Void, Error>) {
    let completion = pendingCompletion
    pendingCompletion = nil
    completion?(result)
  }
}

final class RecordingSpeedFlushCore: MpvPlayerCoreBase {
  let currentAudioOutput: String
  let currentPosition: String
  private(set) var operations: [String] = []

  init(currentAudioOutput: String, currentPosition: String = "12.5") {
    self.currentAudioOutput = currentAudioOutput
    self.currentPosition = currentPosition
    super.init()
  }

  override func getPropertyAsync(
    _ name: String,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    operations.append("get:\(name)")
    let value = name == "current-ao" ? currentAudioOutput : currentPosition
    completion(.success(value))
  }

  override func setRawStringPropertyAsync(
    _ name: String,
    value: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    operations.append("set:\(name)=\(value)")
    completion(.success(()))
  }

  override func commandAsync(
    _ args: [String],
    completion: @escaping (Result<Int64?, Error>) -> Void
  ) {
    operations.append("command:\(args.joined(separator: " "))")
    completion(.success(nil))
  }
}

final class RecordingMpvPlugin: MpvPluginShared {
  var coreBase: MpvPlayerCoreBase?
  var eventSink: FlutterEventSink?
  var nameToId: [String: Int] = [:]
  private(set) var pauseHookValues: [String] = []

  init(core: MpvPlayerCoreBase?) {
    coreBase = core
  }

  func setPlayerVisible(_ visible: Bool, restoreOnWindowVisible: Bool) {}
  func updatePlayerFrame() {}
  func setPlayerVideoRect(
    left _: Int, top _: Int, right _: Int, bottom _: Int, devicePixelRatio _: Double
  ) {}
  func setPlayerVideoZoom(_ scale: Double) {}

  func didSetPauseProperty(value: String) {
    pauseHookValues.append(value)
  }
}

final class RecordingLifecycleDelegate: MpvPlayerDelegate {
  private(set) var events: [String] = []
  private(set) var properties: [String] = []

  func onPropertyChange(name: String, value: Any?, sourceId: Int64?) {
    properties.append(name)
  }

  func onEvent(name: String, data: [String: Any]?) {
    events.append(name)
  }
}

final class EventOrderRecorder: MpvPlayerDelegate {
  private(set) var events: [(name: String, data: [String: Any]?)] = []
  var onEndFile: (() -> Void)?

  func onPropertyChange(name: String, value: Any?, sourceId: Int64?) {}

  func onEvent(name: String, data: [String: Any]?) {
    events.append((name, data))
    if name == "end-file" { onEndFile?() }
  }
}

final class FakePictureInPictureController: MpvPictureInPictureControlling {
  var isPictureInPicturePossible = false
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var automaticStartValues: [Bool] = []
  private(set) var invalidateCount = 0

  func startPictureInPicture() { startCount += 1 }
  func stopPictureInPicture() { stopCount += 1 }
  func setAutomaticStart(_ enabled: Bool) { automaticStartValues.append(enabled) }
  func invalidatePlaybackState() { invalidateCount += 1 }
}

final class RecordingPipDelegate: MpvPipDelegate {
  private(set) var events: [String] = []
  var onDidStart: (() -> Void)?
  func pipWillStart() { events.append("willStart") }
  func pipDidStart() {
    onDidStart?()
    events.append("didStart")
  }
  func pipDidStop(restored: Bool) { events.append("didStop:\(restored)") }
  func pipDidFailToStart(error: Error?) { events.append("failed") }
  func pipSetPlaying(_ playing: Bool) {}
  func pipSkip(byInterval seconds: Double, completion: @escaping () -> Void) { completion() }
  var isPipPlaying: Bool { true }
  var pipDuration: Double { 60 }
  var pipPosition: Double { 0 }
}

final class ReleaseTrackingCore: MpvPlayerCoreBase {
  let onDeinit: () -> Void
  init(onDeinit: @escaping () -> Void) {
    self.onDeinit = onDeinit
    super.init()
  }
  deinit { onDeinit() }
}

import AVFoundation
import VideoToolbox
#if os(macOS)
import AppKit
import FlutterMacOS
#else
import UIKit
import Flutter
#endif

/// AVPlayer owns decode, timing and presentation. Keeping the AVPlayerLayer
/// attached to a Flutter platform view preserves the native display pipeline.
private final class AVVideoSession {
  let item: AVPlayerItem
  let player: AVPlayer
  let layer: AVPlayerLayer
  var speed: Float = 1
  var ended = false
  var failed = false
  private var observers: [NSObjectProtocol] = []

  init(url: URL) {
    item = AVPlayerItem(url: url)
    player = AVPlayer(playerItem: item)
    layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resizeAspect
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) {
      [weak self] _ in self?.ended = true
    })
    observers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) {
      [weak self] _ in self?.failed = true
    })
  }

  deinit {
    for token in observers { NotificationCenter.default.removeObserver(token) }
    player.pause()
    layer.player = nil
  }

  func state() -> [String: Any] {
    func ms(_ time: CMTime) -> Int {
      let seconds = time.seconds
      return seconds.isFinite && seconds > 0 ? Int(seconds * 1000) : 0
    }
    return ["ready": item.status == .readyToPlay, "failed": failed || item.status == .failed,
            "width": item.presentationSize.width, "height": item.presentationSize.height,
            "playing": player.timeControlStatus == .playing,
            "buffering": player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            "position": ms(player.currentTime()), "duration": ms(item.duration),
            "frame": layer.isReadyForDisplay, "ended": ended]
  }

  func tracks() -> [[String: Any]] {
    var rows: [[String: Any]] = []
    for (type, characteristic): (String, AVMediaCharacteristic) in [("audio", .audible), ("subtitle", .legible)] {
      guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) else { continue }
      let selected = item.currentMediaSelection.selectedMediaOption(in: group)
      for (index, option) in group.options.enumerated() {
        rows.append(["id": String(index), "type": type, "title": option.displayName,
                     "language": option.extendedLanguageTag ?? option.locale?.identifier ?? "und",
                     "selected": option == selected])
      }
    }
    return rows
  }
}

#if os(macOS)
private final class AVVideoView: NSView {
  private let video: AVPlayerLayer?
  init(video: AVPlayerLayer?) {
    self.video = video
    super.init(frame: .zero)
    wantsLayer = true
    if let video { layer?.addSublayer(video) }
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    video?.frame = bounds
  }
}
#else
private final class AVVideoView: UIView, FlutterPlatformView {
  private let video: AVPlayerLayer?
  init(frame: CGRect, video: AVPlayerLayer?) {
    self.video = video
    super.init(frame: frame)
    if let video { layer.addSublayer(video) }
    isUserInteractionEnabled = false
  }
  required init?(coder: NSCoder) { nil }
  override func layoutSubviews() {
    super.layoutSubviews()
    video?.frame = bounds
  }
  func view() -> UIView { self }
}
#endif

final class SystemVideoPlugin: NSObject, FlutterPlatformViewFactory {
  private var sessions: [Int64: AVVideoSession] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(macOS)
    let messenger = registrar.messenger
    #else
    let messenger = registrar.messenger()
    #endif
    let factory = SystemVideoPlugin()
    registrar.register(factory, withId: "org.snapetech.pleazyng/avplayer")
    let channel = FlutterMethodChannel(name: "org.snapetech.pleazyng/system_video", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in factory.handle(call, result: result) }
  }

  #if os(macOS)
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    AVVideoView(video: (args as? NSNumber).flatMap { sessions[$0.int64Value]?.layer })
  }
  #else
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    AVVideoView(frame: frame, video: (args as? NSNumber).flatMap { sessions[$0.int64Value]?.layer })
  }
  #endif

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "decoderInventory" {
      let formats: [(String, String, CMVideoCodecType)] = [
        ("h264", "avc1.4D4029", kCMVideoCodecType_H264),
        ("hevc", "hvc1.1.6.L120.B0", kCMVideoCodecType_HEVC),
        ("av1", "av01.0.08M.08", kCMVideoCodecType_AV1),
      ]
      let playable = formats.filter { AVURLAsset.isPlayableExtendedMIMEType("video/mp4; codecs=\"\($0.1)\"") }
      result(["video": playable.map { $0.0 }, "hardware": playable.filter { VTIsHardwareDecodeSupported($0.2) }.map { $0.0 }])
      return
    }
    guard let args = call.arguments as? [String: Any], let id = (args["id"] as? NSNumber)?.int64Value else {
      result(FlutterError(code: "id", message: "Missing session", details: nil))
      return
    }
    if call.method == "dispose" { sessions.removeValue(forKey: id); result(nil); return }
    if call.method == "create", let raw = args["uri"] as? String, let url = URL(string: raw) {
      sessions[id] = AVVideoSession(url: url)
      result(nil)
      return
    }
    guard let session = sessions[id] else {
      result(FlutterError(code: "session", message: "Closed video session", details: nil))
      return
    }
    let value = args["value"] as? NSNumber
    switch call.method {
    case "state": result(session.state()); return
    case "tracks": result(session.tracks()); return
    case "play": session.player.playImmediately(atRate: session.speed)
    case "pause": session.player.pause()
    case "rate":
      session.speed = value?.floatValue ?? 1
      if session.player.rate != 0 { session.player.rate = session.speed }
    case "volume": session.player.volume = value?.floatValue ?? 1
    case "seek":
      session.ended = false
      let target = CMTime(value: value?.int64Value ?? 0, timescale: 1000)
      session.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
        DispatchQueue.main.async {
          result(finished ? nil : FlutterError(code: "seek", message: "Seek superseded", details: nil))
        }
      }
      return
    case "audio", "subtitle":
      let kind: AVMediaCharacteristic = call.method == "audio" ? .audible : .legible
      let key = args["value"] as? String
      if let group = session.item.asset.mediaSelectionGroup(forMediaCharacteristic: kind) {
        if key == "no" { session.item.select(nil, in: group) }
        else if let index = Int(key ?? ""), group.options.indices.contains(index) {
          session.item.select(group.options[index], in: group)
        } else { result(FlutterError(code: "track", message: "Track unavailable", details: nil)); return }
      }
    default: result(FlutterMethodNotImplemented); return
    }
    result(nil)
  }
}

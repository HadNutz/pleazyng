import plezy_preparation
import Flutter
import UIKit
import AVFoundation
import MediaPlayer
import MusicKit
import CoreImage
import CarPlay
import Intents
#if canImport(GoogleCast)
  import GoogleCast
#endif

/// Re-downloadable media is not user-created document data. Keep the policy
/// confined to our two managed roots, including their legacy support paths.
enum DownloadBackupPolicy {
  static var managedRoots: [URL] {
    let manager = FileManager.default
    return [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory]
      .flatMap { manager.urls(for: $0, in: .userDomainMask) }
      .flatMap { base in ["downloads", "artwork"].map { base.appendingPathComponent($0, isDirectory: true) } }
  }

  @discardableResult
  static func exclude(_ directory: URL, allowedRoots: [URL] = managedRoots) throws -> Bool {
    guard directory.isFileURL else { return false }
    let target = directory.standardizedFileURL.resolvingSymlinksInPath()
    guard allowedRoots.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == target }) else {
      return false
    }
    let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { return false }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var writableURL = directory
    try writableURL.setResourceValues(values)
    return true
  }

  static func refreshExistingRoots() {
    for root in managedRoots where FileManager.default.fileExists(atPath: root.path) {
      do {
        try exclude(root)
      } catch {
        MpvLog.error("Could not exclude downloaded content from backup: \(error)")
      }
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  // One explicit engine survives both the phone scene and CarPlay-only launch.
  // The normal Dart entry point owns authentication and the only music session.
  private(set) var musicEngine: FlutterEngine?

  func ensureMusicEngine() -> FlutterEngine {
    if let engine = musicEngine { return engine }
    let engine = FlutterEngine(name: "pleazyng_shared_music", project: nil, allowHeadlessExecution: true, restorationEnabled: true)
    musicEngine = engine
    guard
      engine.run(
        withEntrypoint: "main", libraryURI: nil, initialRoute: nil,
        entrypointArgs: ["--pleazyng-car-host"])
    else {
      musicEngine = nil
      return engine
    }
    registerApplicationPlugins(engine)
    return engine
  }

  private let musicIntentHandler = MusicPlayIntentHandler()
  private let musicNfcBridge = MusicNfcBridge()

  override func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
    if intent is INPlayMediaIntent {
      _ = ensureMusicEngine()
      return musicIntentHandler
    }
    return super.application(application, handlerFor: intent)
  }

  private var deviceAdjustmentChannel: FlutterMethodChannel?
  /// The screen whose brightness the player changed, and the level to restore
  /// on it. Track the display because foldable iPhones can move the app between
  /// screens while playback is active.
  private var brightnessOverride: (screen: UIScreen, original: CGFloat)?
  private var volumeView: MPVolumeView?
  private weak var volumeSlider: UISlider?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    RommAppleBroker.install()
    DownloadBackupPolicy.refreshExistingRoots()
    PlezyPreparationPlugin.registerBackgroundTasks { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Configure the non-mixing session; activate it only when playback starts.
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default)
    } catch {
      MpvLog.error("Failed to configure audio session: \(error)")
    }
    // Declares that playback can carry 5.1/7.1 and Dolby content, so the
    // system offers multichannel Spatial Audio on AirPods (#2264). mpv's
    // AVFoundation output only declares it for sources above stereo, and only
    // in builds that compiled the call in; declaring it here does not depend
    // on either.
    do {
      try AVAudioSession.sharedInstance().setSupportsMultichannelContent(true)
    } catch {
      MpvLog.error("Failed to declare multichannel audio content: \(error)")
    }

    application.beginReceivingRemoteControlEvents()
    // Register plugins before delivering didFinishLaunching, including on a
    // CarPlay-only start. Dart enables UI restoration once a phone attaches.
    _ = ensureMusicEngine()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func registerApplicationPlugins(_ registry: FlutterPluginRegistry) {
    if let registrar = registry.registrar(forPlugin: "PlezySteamPlugin") {
      PlezySteamPlugin.register(with: registrar)
    }

    GeneratedPluginRegistrant.register(with: registry)
    if let registrar = registry.registrar(forPlugin: "MusicCarBridge") {
      MusicCarBridge.shared.attach(registrar.messenger())
    }
    if let registrar = registry.registrar(forPlugin: "MusicNfcBridge") {
      musicNfcBridge.attach(registrar.messenger())
    }

    if let registrar = registry.registrar(forPlugin: "DownloadStorageChannel") {
      let channel = FlutterMethodChannel(name: "com.pleazyng/download_storage", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "excludeFromBackup", let path = call.arguments as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        do {
          result(try DownloadBackupPolicy.exclude(URL(fileURLWithPath: path)))
        } catch {
          result(
            FlutterError(code: "backup_exclusion", message: "Could not update download backup policy", details: nil))
        }
      }
    }

    if let registrar = registry.registrar(forPlugin: "MpvPlayerPlugin") {
      MpvPlayerPlugin.register(with: registrar)
    }

    if let registrar = registry.registrar(forPlugin: "MpvWorkspacePlayerPlugin") {
      MpvPlayerPlugin.registerWorkspace(with: registrar)
    }
    for (slot, pluginName) in [(2, "MpvWorkspace2PlayerPlugin"), (3, "MpvWorkspace3PlayerPlugin")] {
      if let registrar = registry.registrar(forPlugin: pluginName) {
        MpvPlayerPlugin.registerWorkspace(with: registrar, slot: slot)
      }
    }

    if let registrar = registry.registrar(forPlugin: "MpvAudioPlayerPlugin") {
      MpvAudioPlayerPlugin.register(with: registrar)
    }

    if let registrar = registry.registrar(forPlugin: "MpvAudioOverlapPlugin") {
      MpvAudioPlayerPlugin.registerOverlap(with: registrar)
    }
    if let registrar = registry.registrar(forPlugin: "MpvAudioGroupOutputPlugin") {
      MpvAudioPlayerPlugin.registerGroupOutput(with: registrar)
    }

    if let registrar = registry.registrar(forPlugin: "VideoDecodeCapabilitiesPlugin") {
      VideoDecodeCapabilitiesPlugin.register(with: registrar)
    }

    if let registrar = registry.registrar(forPlugin: "DeviceAdjustmentChannel") {
      registerDeviceAdjustmentChannel(messenger: registrar.messenger())
    }

    if let registrar = registry.registrar(forPlugin: "AppIconPlugin") {
      AppIconPlugin.register(with: registrar)
    }

    if let registrar = registry.registrar(forPlugin: "DeepLinkPlugin") {
      DeepLinkPlugin.register(with: registrar)
    }

    #if canImport(GoogleCast)
      if let registrar = registry.registrar(forPlugin: "CastMusicQueuePlugin") {
        CastMusicQueuePlugin.register(with: registrar)
      }
    #endif

    if #available(iOS 15.0, *),
      let registrar = registry.registrar(forPlugin: "AppleMusicKitPlugin")
    {
      AppleMusicKitPlugin.register(with: registrar)
    }
  }

  private func registerDeviceAdjustmentChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.plezy/device_adjustment", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        self?.handleDeviceAdjustmentCall(call, result: result)
      }
    }
    deviceAdjustmentChannel = channel
  }

  private func handleDeviceAdjustmentCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getBrightness":
      result(activeScreen.map { Double($0.brightness) })
    case "setBrightness":
      guard let value = normalizedArgument(call.arguments, result: result) else { return }
      guard let screen = activeScreen else {
        result(FlutterError(code: "DEVICE_ADJUSTMENT_UNAVAILABLE", message: "No active screen", details: nil))
        return
      }
      if let override = brightnessOverride, override.screen !== screen {
        override.screen.brightness = override.original
        brightnessOverride = nil
      }
      if brightnessOverride == nil {
        brightnessOverride = (screen, screen.brightness)
      }
      screen.brightness = CGFloat(value)
      result(nil)
    case "restoreBrightness":
      if let override = brightnessOverride {
        override.screen.brightness = override.original
        brightnessOverride = nil
      }
      result(nil)
    case "getMediaVolume":
      result(Double(AVAudioSession.sharedInstance().outputVolume))
    case "setMediaVolume":
      guard let value = normalizedArgument(call.arguments, result: result) else { return }
      if setMediaVolume(value) {
        result(nil)
      } else {
        result(
          FlutterError(code: "DEVICE_ADJUSTMENT_UNAVAILABLE", message: "System volume slider unavailable", details: nil)
        )
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func normalizedArgument(_ arguments: Any?, result: @escaping FlutterResult) -> Double? {
    guard let value = arguments as? NSNumber else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected a numeric value", details: nil))
      return nil
    }
    let doubleValue = value.doubleValue
    guard doubleValue.isFinite else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected a finite numeric value", details: nil))
      return nil
    }
    return min(1.0, max(0.0, doubleValue))
  }

  private func setMediaVolume(_ value: Double) -> Bool {
    guard let slider = ensureVolumeSlider() else { return false }
    slider.setValue(Float(value), animated: false)
    slider.sendActions(for: .valueChanged)
    slider.sendActions(for: .touchUpInside)
    return true
  }

  private func ensureVolumeSlider() -> UISlider? {
    if let volumeSlider = volumeSlider { return volumeSlider }

    let volumeView = self.volumeView ?? MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    volumeView.showsRouteButton = false
    volumeView.showsVolumeSlider = true
    volumeView.alpha = 0.01
    volumeView.isUserInteractionEnabled = false

    if volumeView.superview == nil {
      activeWindow?.addSubview(volumeView)
    }
    volumeView.layoutIfNeeded()

    self.volumeView = volumeView
    let slider = findVolumeSlider(in: volumeView)
    volumeSlider = slider
    return slider
  }

  private func findVolumeSlider(in view: UIView) -> UISlider? {
    if let slider = view as? UISlider { return slider }
    for subview in view.subviews {
      if let slider = findVolumeSlider(in: subview) { return slider }
    }
    return nil
  }

  /// The display showing the app. `UIScreen.main` may still refer to the
  /// outer display while a foldable iPhone shows the app on its inner display.
  private var activeScreen: UIScreen? {
    activeWindow?.windowScene?.screen
  }

  private var activeWindow: UIWindow? {
    if let primary = musicEngine?.viewController?.viewIfLoaded?.window { return primary }
    if #available(iOS 13.0, *) {
      for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
          return keyWindow
        }
      }
      for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene, let window = windowScene.windows.first else { continue }
        return window
      }
      return nil
    }

    return UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first
  }
}

/// Narrow iOS MusicKit pilot. Apple remains the catalog and playback owner;
/// Pleazyng receives catalog metadata and never receives protected media bytes.
@available(iOS 15.0, *)
final class AppleMusicKitPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.plezy/apple_music_kit",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(AppleMusicKitPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    Task { @MainActor in
      await handleMusicKitCall(call, result: result)
    }
  }

  @MainActor
  private func handleMusicKitCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
    switch call.method {
    case "requestAuthorization":
      let status = await MusicAuthorization.request()
      result(status == .authorized ? "authorized" : "denied")
    case "search":
      guard MusicAuthorization.currentStatus == .authorized,
        let arguments = call.arguments as? [String: Any],
        let query = arguments["query"] as? String,
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        query.count <= 160
      else {
        result(
          FlutterError(
            code: "INVALID_OR_UNAUTHORIZED", message: "A granted MusicKit session and search query are required.",
            details: nil))
        return
      }
      do {
        var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
        request.limit = 20
        let response = try await request.response()
        result(
          response.songs.map { song in
            [
              "id": song.id.rawValue,
              "title": song.title,
              "artist": song.artistName,
              "album": song.albumTitle ?? "",
            ] as [String: Any]
          })
      } catch {
        result(FlutterError(code: "CATALOG_UNAVAILABLE", message: "Apple Music catalog search failed.", details: nil))
      }
    case "canPlayCatalogContent":
      guard MusicAuthorization.currentStatus == .authorized else {
        result(false)
        return
      }
      do {
        let subscription = try await MusicSubscription.current
        result(subscription.canPlayCatalogContent)
      } catch {
        result(
          FlutterError(
            code: "SUBSCRIPTION_UNAVAILABLE", message: "Apple Music subscription status is unavailable.", details: nil))
      }
    case "play":
      guard MusicAuthorization.currentStatus == .authorized,
        let arguments = call.arguments as? [String: Any],
        let songID = arguments["id"] as? String,
        !songID.isEmpty,
        songID.count <= 128
      else {
        result(
          FlutterError(
            code: "INVALID_OR_UNAUTHORIZED", message: "A granted MusicKit session and song id are required.",
            details: nil))
        return
      }
      do {
        let subscription = try await MusicSubscription.current
        guard subscription.canPlayCatalogContent else {
          result(
            FlutterError(
              code: "SUBSCRIPTION_REQUIRED", message: "An Apple Music subscription is required for catalog playback.",
              details: nil))
          return
        }
        let request = MusicCatalogResourceRequest<Song>(
          matching: \.id,
          equalTo: MusicItemID(songID)
        )
        let response = try await request.response()
        guard let song = response.items.first else {
          result(
            FlutterError(
              code: "SONG_NOT_FOUND", message: "The selected Apple Music item is no longer available.", details: nil))
          return
        }
        let player = ApplicationMusicPlayer.shared
        player.queue = .init(for: [song])
        try await player.play()
        result(nil)
      } catch {
        result(
          FlutterError(code: "PLAYBACK_UNAVAILABLE", message: "Apple Music could not start playback.", details: nil))
      }
    case "stop":
      ApplicationMusicPlayer.shared.stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// The phone attaches to the same engine a CarPlay-only launch prewarmed.
/// Forward every scene callback through Flutter's lifecycle adapter so URL,
/// authentication and background-download plugins retain their existing hooks.
@objc(MusicPhoneSceneDelegate)
final class MusicPhoneSceneDelegate: UIResponder, UIWindowSceneDelegate, FlutterSceneLifeCycleProvider {
  // Share the lifecycle adapter with Flutter's UIKit state-restoration delegate.
  // It is the adapter to which the view registers its engine on attachment.
  lazy var sceneLifeCycleDelegate: FlutterPluginSceneLifeCycleDelegate = {
    (restorationDelegate as? FlutterSceneLifeCycleProvider)?.sceneLifeCycleDelegate ?? FlutterPluginSceneLifeCycleDelegate()
  }()
  var window: UIWindow?
  private var companion = false
  private let restorationDelegate: UIWindowSceneDelegate = FlutterSceneDelegate()

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
      let app = UIApplication.shared.delegate as? AppDelegate
    else { return }
    let engine = app.ensureMusicEngine()
    if let existing = engine.viewController?.viewIfLoaded?.window?.windowScene, existing != windowScene {
      companion = true
      let window = UIWindow(windowScene: windowScene)
      let browser = CompanionCatalogController(folder: "root", title: "Pleazyng")
      window.rootViewController = UINavigationController(rootViewController: browser)
      self.window = window
      window.makeKeyAndVisible()
      return
    }
    let window = UIWindow(windowScene: windowScene)
    let controller = PlezyFlutterViewController(engine: engine, nibName: nil, bundle: nil)
    controller.restorationIdentifier = "PleazyngPrimary"
    window.rootViewController = controller
    self.window = window
    sceneLifeCycleDelegate.scene(scene, willConnectTo: session, options: connectionOptions)
    window.makeKeyAndVisible()
  }

  func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
    guard !companion else { return nil }
    return restorationDelegate.stateRestorationActivity?(for: scene) ?? nil
  }

  func scene(_ scene: UIScene, restoreInteractionStateWith stateRestorationActivity: NSUserActivity) {
    guard !companion else { return }
    restorationDelegate.scene?(scene, restoreInteractionStateWith: stateRestorationActivity)
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    if companion { window = nil; companion = false; return }
    sceneLifeCycleDelegate.sceneDidDisconnect(scene)
    if let controller = window?.rootViewController as? FlutterViewController,
      let app = UIApplication.shared.delegate as? AppDelegate,
      app.musicEngine?.viewController === controller
    {
      app.musicEngine?.viewController = nil
    }
    window = nil
  }
  func sceneWillEnterForeground(_ scene: UIScene) { if !companion { sceneLifeCycleDelegate.sceneWillEnterForeground(scene) } }
  func sceneDidBecomeActive(_ scene: UIScene) { if !companion { sceneLifeCycleDelegate.sceneDidBecomeActive(scene) } }
  func sceneWillResignActive(_ scene: UIScene) { if !companion { sceneLifeCycleDelegate.sceneWillResignActive(scene) } }
  func sceneDidEnterBackground(_ scene: UIScene) { if !companion { sceneLifeCycleDelegate.sceneDidEnterBackground(scene) } }
  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    guard !companion else { return }
    sceneLifeCycleDelegate.scene(scene, openURLContexts: contexts)
  }
  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    guard !companion else { return }
    sceneLifeCycleDelegate.scene(scene, continue: userActivity)
  }
  func windowScene(
    _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    guard !companion else { completionHandler(false); return }
    sceneLifeCycleDelegate.windowScene(
      windowScene, performActionFor: shortcutItem, completionHandler: completionHandler)
  }
}

/// A second application scene owns its own navigation, while transport and
/// authorization stay on the existing profile's engine. UIKit supplies the
/// hardware keyboard, VoiceOver, safe-area and resizable-window behavior.
private final class CompanionCatalogController: UITableViewController {
  private let folder: String
  private var rows: [[String: Any]] = []
  private var revision = 0

  init(folder: String, title: String) {
    self.folder = folder
    super.init(style: .insetGrouped)
    self.title = title
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    NotificationCenter.default.addObserver(self, selector: #selector(scopeChanged),
      name: MusicCarBridge.scopeChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(reloadCatalog),
      name: MusicCarBridge.catalogChanged, object: nil)
    refreshControl = UIRefreshControl()
    refreshControl?.addTarget(self, action: #selector(reloadCatalog), for: .valueChanged)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadCatalog()
  }

  @objc private func scopeChanged() {
    revision += 1
    rows = []
    tableView.reloadData()
    if folder == "root" {
      navigationController?.popToRootViewController(animated: false)
      reloadCatalog()
    }
  }

  @objc private func reloadCatalog() {
    revision += 1
    let current = revision
    MusicCarBridge.shared.request("browse", ["id": folder]) { [weak self] result in
      guard let self, self.revision == current else { return }
      self.rows = (result as? [[String: Any]] ?? []).filter { row in
        guard let id = row["id"] as? String, row["title"] is String else { return false }
        // Guest hosting and vehicle video require their dedicated CarPlay template.
        return !id.hasPrefix("guest") && id != "continueCarVideo" && !id.hasPrefix("carVideo:")
      }
      self.tableView.reloadData()
      self.refreshControl?.endRefreshing()
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "item") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "item")
    let row = rows[indexPath.row]
    cell.textLabel?.text = row["title"] as? String
    cell.detailTextLabel?.text = row["subtitle"] as? String
    cell.textLabel?.numberOfLines = 0
    cell.detailTextLabel?.numberOfLines = 0
    cell.textLabel?.adjustsFontForContentSizeCategory = true
    cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
    cell.accessoryType = row["playable"] as? Bool == true ? .none : .disclosureIndicator
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard MusicCarBridge.shared.ready, rows.indices.contains(indexPath.row),
      let id = rows[indexPath.row]["id"] as? String else { return }
    let row = rows[indexPath.row]
    if row["playable"] as? Bool == true {
      MusicCarBridge.shared.request("playItem", ["id": id]) { [weak self] value in
        if value as? Bool != true { self?.reloadCatalog() }
      }
    } else {
      navigationController?.pushViewController(CompanionCatalogController(folder: id, title: row["title"] as? String ?? ""), animated: true)
    }
  }
}

/// Native CarPlay templates backed by the same profile-scoped Dart catalog.
/// MPNowPlaying/remote commands remain owned by os_media_controls.
final class MusicCarBridge {
  static let shared = MusicCarBridge()
  static let scopeChanged = Notification.Name("PleazyngCompanionProfileChanged")
  static let catalogChanged = Notification.Name("PleazyngCompanionCatalogChanged")
  private var channel: FlutterMethodChannel?
  private(set) var ready = false
  private var epoch = 0
  private var pending = Set<String>()
  private var invalidations: [String: () -> Void] = [:]
  private func invalidateRequests() {
    let callbacks = Array(invalidations.values)
    invalidations.removeAll()
    pending.removeAll()
    callbacks.forEach { $0() }
  }
  private var carVideo: AnyObject?
  private var widgetSnapshot: MusicWidgetSnapshot?
  private(set) var playback: [String: Any] = [:]
  private(set) var connected = false
  weak var scene: MusicCarSceneDelegate?

  func attach(_ messenger: FlutterBinaryMessenger) {
    stopVideo()
    invalidateRequests()
    ready = false
    epoch += 1
    NotificationCenter.default.post(name: Self.scopeChanged, object: self)
    playback = [:]
    updateWidget(nil)
    channel = FlutterMethodChannel(name: "com.pleazyng/music_car", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "openCarVideo":
        guard #available(iOS 27.0, *), self.ready, self.connected, self.scene?.supportsVideo == true,
          let args = call.arguments as? [String: Any], let id = args["id"] as? String,
          let raw = args["url"] as? String, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "")
        else { result(false); return }
        self.stopVideo()
        let video = CarVideoPlayer(
          id: id, url: url, title: args["title"] as? String ?? "Pleazyng",
          offset: args["offset"] as? Int ?? 0, duration: args["duration"] as? Int ?? 0,
          multipart: args["multipart"] as? Bool ?? false)
        self.carVideo = video
        video.open(
          position: args["position"] as? Int ?? 0, playing: args["playing"] as? Bool ?? true,
          ready: { ok in result(ok) }
        ) {
          [weak self, weak video] position, paused, reason, seek in
          guard let self, let video, self.carVideo === video else { return }
          self.channel?.invokeMethod(
            "videoEvent",
            arguments: [
              "id": id, "position": position, "paused": paused, "ended": reason == "completed" || reason == "failed",
              "reason": reason, "seek": seek as Any,
            ])
        }
      case "stopCarVideo":
        if #available(iOS 27.0, *), let video = self.carVideo as? CarVideoPlayer, video.id == call.arguments as? String
        {
          let position = video.position
          self.stopVideo()
          result(position)
        } else {
          result(nil)
        }
      case "acceptCarRequest":
        let id = call.arguments as? String ?? ""
        result(self.pending.remove(id) != nil)
      case "ready":
        self.invalidateRequests()
        self.ready = true
        self.epoch += 1
        self.updateWidget(nil)
        if self.connected { self.connection(true) }
        self.scene?.refresh()
        NotificationCenter.default.post(name: Self.scopeChanged, object: self)
        result(nil)
      case "catalogChanged":
        self.scene?.refreshCatalog()
        NotificationCenter.default.post(name: Self.catalogChanged, object: self)
        result(nil)
      case "snapshot":
        if self.ready {
          let previousRevision = self.playback["revision"] as? Int
          self.playback = call.arguments as? [String: Any] ?? [:]
          self.scene?.configurePlayback()
          if previousRevision != self.playback["revision"] as? Int {
            self.scene?.refreshPlaybackList()
          }
          self.updateWidget(MusicWidgetSnapshot(message: call.arguments))
        }
        result(nil)
      case "close":
        self.stopVideo()
        self.invalidateRequests()
        self.ready = false
        self.playback = [:]
        self.epoch += 1
        self.updateWidget(nil)
        self.scene?.refresh()
        NotificationCenter.default.post(name: Self.scopeChanged, object: self)
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func updateWidget(_ snapshot: MusicWidgetSnapshot?) {
    if let snapshot, let previous = widgetSnapshot,
      snapshot.content == previous.content, previous.isFresh(at: snapshot.capturedAt),
      snapshot.capturedAt.timeIntervalSince(previous.capturedAt) < MusicWidgetSnapshot.lifetime / 2
    {
      return
    }
    widgetSnapshot = snapshot
    MusicWidgetStore.publish(snapshot)
  }

  @MainActor
  func performWidgetTransport(_ command: String, scope: String, revision: Int) async {
    guard ready, widgetSnapshot?.authorizes(command, scope: scope, revision: revision) == true else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      request("transport", ["command": command, "scope": scope, "revision": revision]) { _ in
        continuation.resume()
      }
    }
  }

  private func stopVideo() {
    if #available(iOS 27.0, *) { (carVideo as? CarVideoPlayer)?.stop() }
    carVideo = nil
  }

  func connection(_ value: Bool) {
    connected = value
    if !value {
      invalidateRequests()
      if #available(iOS 27.0, *), let video = carVideo as? CarVideoPlayer {
        channel?.invokeMethod(
          "videoEvent", arguments: ["id": video.id, "position": video.position, "paused": true, "ended": true])
      }
      stopVideo()
    }
    guard ready else { return }
    channel?.invokeMethod(
      "connection", arguments: ["connected": value, "video": value && scene?.supportsVideo == true])
  }

  func request(_ method: String, _ args: [String: Any], completion: @escaping (Any?) -> Void) {
    guard ready, let channel else { completion(nil); return }
    let expected = epoch
    let guarded = [
      "transport", "playItem", "playSearch", "play", "pause", "next", "previous", "guestAction", "videoStart",
    ].contains(method)
    let id = UUID().uuidString
    var arguments = args
    if guarded {
      pending.insert(id)
      arguments["carRequest"] = id
    }
    var finished = false
    let finish: (Any?) -> Void = { [weak self] value in
      guard !finished else { return }
      finished = true
      self?.pending.remove(id)
      self?.invalidations.removeValue(forKey: id)
      completion(self?.epoch == expected ? value : nil)
    }
    if guarded { invalidations[id] = { finish(nil) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard !finished else { return }
      // Dart claims a live request immediately before changing the player.
      // An accepted operation finishes with its actual result.
      if !guarded || self?.pending.contains(id) == true || self?.epoch != expected { finish(nil) }
    }
    channel.invokeMethod(method, arguments: arguments, result: finish)
  }
}

/// CarPlay owns the external video surface and transitions to audio when the vehicle requires it.
@available(iOS 27.0, *)
private final class CarVideoPlayer {
  let id: String
  private let player: AVPlayer
  private let session: MPNowPlayingSession
  private var status: NSKeyValueObservation?
  private var playbackStatus: NSKeyValueObservation?
  private var observer: Any?
  private var notifications: [NSObjectProtocol] = []
  private var remotes: [(MPRemoteCommand, Any)] = []
  private var opening: ((Bool) -> Void)?
  private var stopped = false
  var position: Int {
    let seconds = player.currentTime().seconds
    return seconds.isFinite ? max(0, Int(seconds * 1000)) : 0
  }

  private let offset: Int
  private let duration: Int
  private let multipart: Bool
  private let title: String
  init(id: String, url: URL, title: String, offset: Int, duration: Int, multipart: Bool) {
    self.offset = offset
    self.duration = duration
    self.multipart = multipart
    self.title = title
    self.id = id
    let item = AVPlayerItem(url: url)
    let metadata = AVMutableMetadataItem()
    metadata.identifier = .commonIdentifierTitle
    metadata.value = title as NSString
    metadata.extendedLanguageTag = "und"
    item.externalMetadata = [metadata]
    player = AVPlayer(playerItem: item)
    player.allowsExternalPlayback = true
    session = MPNowPlayingSession(players: [player])
    session.automaticallyPublishesNowPlayingInfo = !multipart
  }

  func open(
    position: Int, playing: Bool, ready: @escaping (Bool) -> Void, event: @escaping (Int, Bool, String, Int?) -> Void
  ) {
    guard let item = player.currentItem else { ready(false); return }
    opening = ready
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch { finishOpening(false); return }
    let center = session.remoteCommandCenter
    func register(
      _ command: MPRemoteCommand, _ action: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
      command.isEnabled = true
      remotes.append((command, command.addTarget(handler: action)))
    }
    register(center.playCommand) { [weak self] _ in
      self?.player.play(); return .success
    }
    register(center.pauseCommand) { [weak self] _ in
      self?.player.pause(); return .success
    }
    register(center.changePlaybackPositionCommand) { [weak self] command in
      guard let self, let command = command as? MPChangePlaybackPositionCommandEvent, command.positionTime.isFinite
      else { return .commandFailed }
      if self.multipart {
        let milliseconds = Int(min(Double(self.duration), max(0, command.positionTime * 1000)))
        event(self.position, self.player.timeControlStatus == .paused, "seek", milliseconds)
      } else {
        self.player.seek(to: CMTime(seconds: command.positionTime, preferredTimescale: 1000))
      }
      return .success
    }
    func report(_ reason: String) {
      guard !stopped, opening == nil else { return }
      if multipart {
        session.nowPlayingInfoCenter.nowPlayingInfo = [
          MPMediaItemPropertyTitle: title,
          MPMediaItemPropertyPlaybackDuration: Double(duration) / 1000,
          MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(offset + self.position) / 1000,
          MPNowPlayingInfoPropertyPlaybackRate: player.rate,
        ]
      }
      event(self.position, player.timeControlStatus == .paused, reason, nil)
    }
    for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
      notifications.append(
        NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
          guard let self else { return }
          if self.opening != nil {
            self.finishOpening(false)
          } else {
            report(name == AVPlayerItem.didPlayToEndTimeNotification ? "completed" : "failed")
          }
        })
    }
    observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) {
      _ in report("progress")
    }
    playbackStatus = player.observe(\.timeControlStatus, options: [.new]) { _, _ in
      DispatchQueue.main.async { report("progress") }
    }
    status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self, !self.stopped else { return }
        if item.status == .failed {
          if self.opening != nil { self.finishOpening(false) } else { report("failed") }
        } else if item.status == .readyToPlay && self.opening != nil {
          self.player.seek(to: CMTime(value: Int64(position), timescale: 1000)) { [weak self] ok in
            DispatchQueue.main.async {
              guard let self, !self.stopped, self.opening != nil else { return }
              if ok {
                self.session.becomeActiveIfPossible(completion: nil)
                if playing { self.player.play() }
              }
              self.finishOpening(ok)
              if ok { report("progress") }
            }
          }
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.finishOpening(false) }
  }

  private func finishOpening(_ ok: Bool) {
    let reply = opening
    opening = nil
    reply?(ok)
  }

  func stop() {
    stopped = true
    status = nil
    playbackStatus = nil
    for notification in notifications { NotificationCenter.default.removeObserver(notification) }
    notifications.removeAll()
    if let observer { player.removeTimeObserver(observer) }
    observer = nil
    for (command, token) in remotes { command.removeTarget(token) }
    remotes.removeAll()
    player.pause()
    player.replaceCurrentItem(with: nil)
    finishOpening(false)
  }
}

@objc(MusicCarSceneDelegate)
final class MusicCarSceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver,
  CPTabBarTemplateDelegate, CPSearchTemplateDelegate, CPSessionConfigurationDelegate
{
  private var controller: CPInterfaceController?
  private var artworkGeneration = 0
  private var searchGeneration = 0
  private lazy var configuration = CPSessionConfiguration(delegate: self)
  var supportsVideo: Bool {
    #if compiler(>=6.3)
      if #available(iOS 27.0, *) {
        return Bundle.main.object(forInfoDictionaryKey: "PleazyngCarVideoEnabled") as? String == "YES"
          && configuration.supportsVideoPlayback
      }
    #endif
    return false
  }
  private var initialPlayback = false
  private var rootInstalled = false

  private func enterNowPlaying() {
    guard let controller, controller.topTemplate !== CPNowPlayingTemplate.shared else { return }
    let template = CPNowPlayingTemplate.shared
    if controller.templates.contains(where: { $0 === template }) {
      controller.pop(to: template, animated: true, completion: nil)
    } else if controller.templates.count >= 5 {
      controller.popTemplate(animated: false) { ok, _ in
        if ok { controller.pushTemplate(template, animated: true, completion: nil) }
      }
    } else {
      controller.pushTemplate(template, animated: true, completion: nil)
    }
  }

  private func restoreInitialPlayback() {
    guard initialPlayback, rootInstalled, let playing = MusicCarBridge.shared.playback["playing"] as? Bool else {
      return
    }
    initialPlayback = false
    if playing { enterNowPlaying() }
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    _ = (UIApplication.shared.delegate as? AppDelegate)?.ensureMusicEngine()
    initialPlayback = true
    rootInstalled = false
    controller = interfaceController
    CPNowPlayingTemplate.shared.add(self)
    configurePlayback()
    MusicCarBridge.shared.scene = self
    MusicCarBridge.shared.connection(true)
    refresh()
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnect interfaceController: CPInterfaceController
  ) {
    artworkGeneration += 1
    CPNowPlayingTemplate.shared.remove(self)
    searchGeneration += 1
    rootInstalled = false
    initialPlayback = false
    tabs.removeAll()
    MusicCarBridge.shared.connection(false)
    MusicCarBridge.shared.scene = nil
    controller = nil
  }

  private var tabs: [ObjectIdentifier: String] = [:]
  private let pages = NSMapTable<CPListTemplate, NSString>.weakToStrongObjects()

  func refreshPlaybackList() {
    guard let controller else { return }
    let list =
      controller.topTemplate as? CPListTemplate ?? (controller.topTemplate as? CPTabBarTemplate)?.selectedTemplate
      as? CPListTemplate
    guard let list, let id = pages.object(forKey: list) as String?,
      ["home", "queue", "chapters", "bookmarks", "spoken"].contains(id)
    else { return }
    show(id: id, title: list.title ?? "Pleazyng", target: list)
  }

  func refreshCatalog() {
    guard MusicCarBridge.shared.ready, let controller, let bar = controller.rootTemplate as? CPTabBarTemplate
    else { refresh(); return }
    MusicCarBridge.shared.request("browse", ["id": "root"]) { [weak self, weak bar] value in
      guard let self, let bar, controller.rootTemplate === bar, MusicCarBridge.shared.ready else { return }
      let ids = (value as? [[String: Any]])?.compactMap { $0["id"] as? String }
      let tabIds = bar.templates.compactMap { self.tabs[ObjectIdentifier($0)] }
      guard ids == tabIds else { self.refresh(); return }
      if let list = controller.topTemplate as? CPListTemplate, let id = self.pages.object(forKey: list) {
        self.show(id: id as String, title: list.title ?? "Pleazyng", target: list)
      } else if controller.topTemplate === bar, let selected = bar.selectedTemplate {
        self.tabBarTemplate(bar, didSelect: selected)
      }
    }
  }

  func configurePlayback() {
    let bridge = MusicCarBridge.shared
    let snapshot = bridge.playback
    let template = CPNowPlayingTemplate.shared
    let actions = snapshot["actions"] as? [String: String] ?? [:]
    let spoken = snapshot["spoken"] as? Bool == true
    template.isUpNextButtonEnabled =
      bridge.ready && (spoken || snapshot["hasQueue"] as? Bool == true)
    let labels = snapshot["carLabels"] as? [String: String] ?? [:]
    template.upNextTitle = labels[spoken ? "upNext" : "queue"] ?? "Up Next"
    let symbols = [
      "rating": "star", "favorite": snapshot["favorite"] as? Bool == true ? "heart.fill" : "heart",
      "shuffle": "shuffle",
      "repeat": snapshot["repeatMode"] as? String == "one" ? "repeat.1" : "repeat",
      "radio": "dot.radiowaves.left.and.right", "bookmark": "bookmark", "speed": "speedometer",
      "back15": "gobackward.15", "forward30": "goforward.30",
    ]
    let order =
      spoken ? ["back15", "forward30", "speed", "bookmark"] : ["favorite", "rating", "shuffle", "repeat", "radio"]
    let buttons: [CPNowPlayingButton] = order.compactMap { action in
      guard bridge.ready, let label = actions[action], let symbol = symbols[action],
        let image = UIImage(systemName: symbol), let scope = snapshot["scope"], let revision = snapshot["revision"]
      else { return nil }
      image.accessibilityLabel = label
      let button = CPNowPlayingImageButton(image: image) { [weak self] _ in
        if action == "rating" { self?.show(id: "rating", title: label); return }
        bridge.request("transport", ["scope": scope, "revision": revision, "command": action]) { _ in }
      }
      button.isSelected =
        (action == "favorite" && snapshot["favorite"] as? Bool == true)
        || (action == "shuffle" && snapshot["shuffled"] as? Bool == true)
        || (action == "repeat" && snapshot["repeatMode"] as? String != "off")
      return button
    }
    template.updateNowPlayingButtons(buttons)
    restoreInitialPlayback()
  }

  func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    let spoken = MusicCarBridge.shared.playback["spoken"] as? Bool == true
    show(id: spoken ? "spokenControls" : "queue", title: nowPlayingTemplate.upNextTitle)
  }

  func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
    guard let list = selectedTemplate as? CPListTemplate, let id = tabs[ObjectIdentifier(list)] else { return }
    show(id: id, title: list.title ?? "Pleazyng", target: list)
  }

  func refresh() {
    artworkGeneration += 1
    guard let controller else { return }
    if !MusicCarBridge.shared.ready {
      searchGeneration += 1
      rootInstalled = false
      tabs.removeAll()
      configurePlayback()
      let item = CPListItem(
        text: NSLocalizedString("Open Pleazyng to unlock your music", comment: "CarPlay locked profile"),
        detailText: nil)
      item.isEnabled = false
      controller.setRootTemplate(
        CPListTemplate(title: "Pleazyng", sections: [CPListSection(items: [item])]), animated: false, completion: nil)
      return
    }
    show(id: "root", title: "Pleazyng", root: true)
  }

  private func loadArtwork(_ rows: [(String, CPListItem)], generation: Int, scale: CGFloat) {
    // CPListItem.setImage accepts a display-ready image. Bound both the
    // bridge payload and concurrent work; no media URL enters the native list.
    let size = min(
      256,
      max(
        32,
        Int(
          ceil(
            max(
              CPListItem.maximumImageSize.width, CPListItem.maximumImageSize.height) * scale))))
    weak var scene = self
    var cursor = 0
    var active = 0
    func pump() {
      guard let scene, generation == scene.artworkGeneration, scene.controller != nil else { return }
      while active < 3, cursor < rows.count {
        let (id, item) = rows[cursor]
        cursor += 1
        active += 1
        MusicCarBridge.shared.request("artwork", ["id": id, "size": size]) { [weak scene, weak item] value in
          guard let scene, generation == scene.artworkGeneration, scene.controller != nil else { return }
          if let data = value as? FlutterStandardTypedData, data.data.count <= 512 * 1024,
            let image = UIImage(data: data.data, scale: scale)
          {
            item?.setImage(image)
          }
          active -= 1
          pump()
        }
      }
    }
    pump()
  }

  func searchTemplate(
    _ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
    completionHandler: @escaping ([CPListItem]) -> Void
  ) {
    searchGeneration += 1
    let generation = searchGeneration
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { completionHandler([]); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak searchTemplate] in
      guard let self, let searchTemplate, self.searchGeneration == generation,
        self.controller?.topTemplate === searchTemplate
      else { completionHandler([]); return }
      MusicCarBridge.shared.request("search", ["query": query]) { [weak self] value in
        guard self?.searchGeneration == generation, self?.controller?.topTemplate === searchTemplate,
          let rows = value as? [[String: Any]]
        else { completionHandler([]); return }
        completionHandler(
          rows.prefix(CPListTemplate.maximumItemCount).map { row in
            let item = CPListItem(text: row["title"] as? String, detailText: row["subtitle"] as? String)
            item.userInfo = row
            return item
          })
      }
    }
  }

  func searchTemplate(
    _ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
    completionHandler: @escaping () -> Void
  ) {
    guard let row = item.userInfo as? [String: Any] else { completionHandler(); return }
    select(row, done: completionHandler)
  }

  private func select(_ row: [String: Any], done: @escaping () -> Void) {
    guard let id = row["id"] as? String, let title = row["title"] as? String, let controller else { done(); return }
    let labels = MusicCarBridge.shared.playback["carLabels"] as? [String: String] ?? [:]
    if row["video"] as? Bool == true {
      guard supportsVideo else { done(); return }
      MusicCarBridge.shared.request("videoStart", ["id": id]) { [weak self] value in
        if !(value as? Bool ?? false), let self, self.controller === controller {
          let close = CPAlertAction(title: labels["close"] ?? "Close", style: .cancel) { _ in
            controller.dismissTemplate(animated: true, completion: nil)
          }
          controller.presentTemplate(
            CPAlertTemplate(titleVariants: [labels["unavailable"] ?? "Media unavailable"], actions: [close]),
            animated: true, completion: nil)
        }
        done()
      }
      return
    }
    if let action = row["guest"] as? String {
      var arguments = row
      arguments["action"] = action
      MusicCarBridge.shared.request("guestAction", arguments) { [weak self] value in
        guard let self, self.controller === controller else { done(); return }
        if action == "invite", let url = value as? String,
          let filter = CIFilter(name: "CIQRCodeGenerator")
        {
          filter.setValue(Data(url.utf8), forKey: "inputMessage")
          filter.setValue("M", forKey: "inputCorrectionLevel")
          if let code = filter.outputImage {
            let bordered = code.composited(
              over: CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -4, dy: -4)))
            let output = bordered.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
            if let cg = CIContext().createCGImage(output, from: output.extent) {
              let image = UIImage(cgImage: cg)
              let qr = CPListImageRowItem(text: title, images: [image])
              let page = CPListTemplate(title: title, sections: [CPListSection(items: [qr])])
              controller.pushTemplate(page, animated: true, completion: nil)
            }
          }
        } else if value as? Bool == true {
          self.show(id: "guest", title: title, target: controller.topTemplate as? CPListTemplate)
        } else {
          let retry = CPAlertAction(title: labels["retry"] ?? "Retry", style: .default) { _ in
            controller.dismissTemplate(animated: true) { ok, _ in if ok { self.select(row, done: {}) } }
          }
          let close = CPAlertAction(title: labels["close"] ?? "Close", style: .cancel) { _ in
            controller.dismissTemplate(animated: true, completion: nil)
          }
          controller.presentTemplate(
            CPAlertTemplate(titleVariants: [labels["unavailable"] ?? "Unavailable"], actions: [retry, close]),
            animated: true, completion: nil)
        }
        done()
      }
      return
    }
    guard row["playable"] as? Bool == true else { show(id: id, title: title); done(); return }
    func play(_ queue: String? = nil) {
      var arguments: [String: Any] = ["id": id]
      if let queue { arguments["queue"] = queue }
      MusicCarBridge.shared.request("playItem", arguments) { [weak self] value in
        guard let self, self.controller === controller else { return }
        if value as? Bool == true {
          if row["quiet"] as? Bool == true, let list = controller.topTemplate as? CPListTemplate {
            self.show(id: "rating", title: list.title ?? "", target: list)
          } else if queue == nil {
            self.enterNowPlaying()
          }
        } else {
          let alert = CPAlertTemplate(
            titleVariants: [labels["unavailable"] ?? "Media unavailable"],
            actions: [
              CPAlertAction(title: labels["retry"] ?? "Retry", style: .default) { _ in
                controller.dismissTemplate(animated: true) { ok, _ in if ok { play(queue) } }
              },
              CPAlertAction(title: labels["close"] ?? "Close", style: .cancel) { _ in
                controller.dismissTemplate(animated: true, completion: nil)
              },
            ])
          controller.presentTemplate(alert, animated: true, completion: nil)
        }
      }
    }
    let queued = row["queuedSpoken"] as? Bool == true
    if queued || ["podcast", "audiobook"].contains(row["kind"] as? String ?? "") && row["quickResume"] as? Bool != true
    {
      func action(_ name: String, _ queue: String?) -> CPAlertAction {
        CPAlertAction(title: name, style: .default) { _ in
          controller.dismissTemplate(animated: true) { ok, _ in if ok { play(queue) } }
        }
      }
      var actions = [action(labels["playNow"] ?? "Play now", nil)]
      if queued {
        actions.append(action(labels["remove"] ?? "Remove", "remove"))
      } else {
        actions.append(action(labels["next"] ?? "Play next", "next"))
        actions.append(action(labels["later"] ?? "Add to queue", "later"))
      }
      let sheet = CPActionSheetTemplate(
        title: title, message: nil,
        actions: actions + [
          CPAlertAction(title: labels["close"] ?? "Close", style: .cancel) { _ in
            controller.dismissTemplate(animated: true, completion: nil)
          }
        ])
      controller.presentTemplate(sheet, animated: true, completion: nil)
    } else {
      play()
    }
    done()
  }

  private func show(id: String, title: String, root: Bool = false, target: CPListTemplate? = nil, offset: Int = 0) {
    artworkGeneration += 1
    let generation = artworkGeneration
    let previous = controller?.topTemplate
    MusicCarBridge.shared.request("browse", ["id": id]) { [weak self] value in
      guard let self, generation == self.artworkGeneration, let controller = self.controller else { return }
      guard
        root || controller.topTemplate === previous
          || (target != nil
            && (controller.rootTemplate as? CPTabBarTemplate)?.templates.contains(where: { $0 === target }) == true)
      else { return }
      let labels = MusicCarBridge.shared.playback["carLabels"] as? [String: String] ?? [:]
      if root, let rows = value as? [[String: Any]], !rows.isEmpty {
        self.tabs.removeAll()
        let symbols = ["home": "house", "music": "music.note", "spoken": "waveform", "downloads": "arrow.down.circle"]
        let lists: [CPListTemplate] = rows.prefix(CPTabBarTemplate.maximumTabCount).compactMap { row in
          guard let id = row["id"] as? String, let name = row["title"] as? String else { return nil }
          let list = CPListTemplate(title: name, sections: [])
          if #available(iOS 27.0, *), let icon = UIImage(systemName: "magnifyingglass") {
            icon.accessibilityLabel = labels["search"] ?? "Search"
            list.trailingNavigationBarButtons = [
              CPBarButton(image: icon) { [weak self] _ in
                let search = CPSearchTemplate()
                search.delegate = self
                self?.controller?.pushTemplate(search, animated: true, completion: nil)
              }
            ]
          }
          list.tabTitle = name
          list.tabImage = UIImage(systemName: symbols[id] ?? "list.bullet")
          list.emptyViewTitleVariants = [labels["loading"] ?? "Loading…"]
          self.tabs[ObjectIdentifier(list)] = id
          return list
        }
        guard !lists.isEmpty else { return }
        let bar = CPTabBarTemplate(templates: lists)
        bar.delegate = self
        controller.setRootTemplate(bar, animated: false) { [weak self] ok, _ in
          if ok, let self, let first = lists.first {
            self.rootInstalled = true
            self.tabBarTemplate(bar, didSelect: bar.selectedTemplate ?? first)
            self.restoreInitialPlayback()
          }
        }
        return
      }
      let rows = value as? [[String: Any]] ?? []
      var artworkRows: [(String, CPListItem)] = []
      let limit = max(1, CPListTemplate.maximumItemCount)
      let hasMore = rows.count - offset > limit && limit > 1
      let pageSize = hasMore ? limit - 1 : limit
      let items: [CPListItem] = rows.dropFirst(offset).prefix(pageSize).compactMap { row in
        guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
        let item = CPListItem(text: title, detailText: row["subtitle"] as? String)
        #if compiler(>=6.3)
          if #available(iOS 27.0, *), self.supportsVideo, row["video"] as? Bool == true {
            item.playbackConfiguration = CPPlaybackConfiguration(
              preferredPresentation: .video, playbackAction: .play,
              elapsedTime: CMTime(value: Int64(row["elapsed"] as? Int ?? 0), timescale: 1000),
              duration: CMTime(value: Int64(row["duration"] as? Int ?? 0), timescale: 1000))
          }
        #endif
        if row["artwork"] as? Bool == true { artworkRows.append((id, item)) }
        item.handler = { [weak self] _, done in
          guard let self else { done(); return }
          self.select(row, done: done)
        }
        return item
      }
      var displayed = items
      if hasMore {
        let more = CPListItem(text: labels["more"] ?? "More", detailText: nil)
        more.handler = { [weak self] _, done in
          self?.show(
            id: id, title: title,
            target: (self?.controller?.topTemplate as? CPListTemplate)
              ?? (self?.controller?.topTemplate as? CPTabBarTemplate)?.selectedTemplate as? CPListTemplate,
            offset: offset + pageSize)
          done()
        }
        displayed.append(more)
      }
      if !(value is [[String: Any]]) {
        let retry = CPListItem(
          text: labels["retry"] ?? "Retry", detailText: labels["unavailable"] ?? "Library unavailable")
        retry.handler = { [weak self] _, done in
          self?.show(id: id, title: title, root: root, target: self?.controller?.topTemplate as? CPListTemplate)
          done()
        }
        displayed = [retry]
      }
      let template = CPListTemplate(title: title, sections: [CPListSection(items: displayed)])
      template.emptyViewTitleVariants = [labels["empty"] ?? "No items"]
      self.pages.setObject(id as NSString, forKey: target ?? template)
      if let target {
        target.emptyViewTitleVariants = [labels["empty"] ?? "No items"]
        target.updateSections(template.sections)
      } else if root {
        controller.setRootTemplate(template, animated: false, completion: nil)
      } else if id.hasPrefix("page:") || id.hasPrefix("audiobookPage:") || id.hasPrefix("downloadBookPage:")
        || controller.templates.count >= 5, let current = controller.topTemplate as? CPListTemplate
      {
        // Pagination updates the current level instead of exhausting CarPlay's
        // template stack after a few pages of a large music library.
        self.pages.setObject(id as NSString, forKey: current)
        current.updateSections(template.sections)
      } else {
        controller.pushTemplate(template, animated: true, completion: nil)
      }
      self.loadArtwork(artworkRows, generation: generation, scale: controller.carTraitCollection.displayScale)
    }
  }
}

/// Siri resolves through the unlocked profile's catalog. Identifiers are
/// ephemeral, profile-qualified catalog references, never server credentials.
/// A cold/locked session reports that the app must open; it cannot bypass PINs.
final class MusicPlayIntentHandler: NSObject, INPlayMediaIntentHandling {
  func resolveMediaItems(
    for intent: INPlayMediaIntent,
    with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
  ) {
    DispatchQueue.main.async {
      guard MusicCarBridge.shared.ready else {
        completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .unsupported())])
        return
      }
      if intent.resumePlayback == true {
        completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .notRequired())])
        return
      }
      if let selected = intent.mediaItems?.first,
        (selected.identifier?.hasPrefix("item:") == true || selected.identifier?.hasPrefix("audiobook:") == true
          || selected.identifier?.hasPrefix("serverRadio:") == true
          || selected.identifier?.hasPrefix("genre:") == true || selected.identifier?.hasPrefix("downloadMix:") == true
          || selected.identifier?.hasPrefix("similar:") == true
          || selected.identifier?.hasPrefix("favorites:") == true
          || selected.identifier?.hasPrefix("station:") == true || selected.identifier?.hasPrefix("recipe:") == true)
      {
        // The play command revalidates this identifier against the active map.
        completion(INPlayMediaMediaItemResolutionResult.successes(with: [selected]))
        return
      }
      let search = intent.mediaSearch
      let genre = search?.genreNames?.count == 1 ? search?.genreNames?.first : nil
      let similar = search?.reference == .currentlyPlaying && search?.sortOrder == .recommended
      guard let name = search?.mediaName ?? genre ?? (similar ? "More like this" : nil),
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .needsValue())])
        return
      }
      var args: [String: Any] = ["query": name]
      if let artist = intent.mediaSearch?.artistName { args["artist"] = artist }
      if intent.mediaSearch?.sortOrder == .newest { args["latest"] = true }
      if let album = intent.mediaSearch?.albumName { args["album"] = album }
      switch intent.mediaSearch?.mediaType {
      case .song: args["kind"] = "track"
      case .podcastShow: args["kind"] = "show"
      case .podcastEpisode: args["kind"] = "podcast"
      case .audioBook: args["kind"] = "audiobook"
      case .album: args["kind"] = "album"
      case .artist: args["kind"] = "artist"
      case .playlist: args["kind"] = "playlist"
      case .radioStation: args["kind"] = "station"
      default: break
      }
      if genre != nil && search?.mediaName == nil { args["kind"] = "genre" }
      if similar { args["similar"] = true }
      MusicCarBridge.shared.request("resolveVoice", args) { value in
        let items: [INMediaItem] = (value as? [[String: Any]] ?? []).compactMap { row in
          guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
          let type: INMediaItemType =
            row["kind"] as? String == "album"
            ? .album
            : row["kind"] as? String == "artist"
              ? .artist
              : row["kind"] as? String == "station"
                ? .radioStation
                : row["kind"] as? String == "audiobook"
                  ? .audioBook
                  : row["kind"] as? String == "podcast"
                    ? .podcastEpisode
                    : row["kind"] as? String == "playlist" ? .playlist : .song
          return INMediaItem(
            identifier: id, title: title, type: type, artwork: nil,
            artist: row["subtitle"] as? String)
        }
        if items.count == 1 {
          completion(INPlayMediaMediaItemResolutionResult.successes(with: items))
        } else if items.isEmpty {
          completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .unsupported())])
        } else {
          completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .disambiguation(with: items))])
        }
      }
    }
  }

  func confirm(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
    DispatchQueue.main.async {
      completion(
        INPlayMediaIntentResponse(
          code: MusicCarBridge.shared.ready ? .ready : .failureRequiringAppLaunch,
          userActivity: nil))
    }
  }

  func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
    DispatchQueue.main.async {
      guard MusicCarBridge.shared.ready else {
        completion(INPlayMediaIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil))
        return
      }
      let finish: (Any?) -> Void = { result in
        completion(INPlayMediaIntentResponse(code: result as? Bool == true ? .success : .failure, userActivity: nil))
      }
      if intent.resumePlayback == true {
        MusicCarBridge.shared.request("play", [:], completion: finish)
      } else if let id = intent.mediaItems?.first?.identifier {
        var args: [String: Any] = ["id": id, "shuffle": intent.playShuffled == true]
        switch intent.playbackRepeatMode {
        case .one: args["repeat"] = "one"
        case .all: args["repeat"] = "all"
        default: break
        }
        switch intent.playbackQueueLocation {
        case .next: args["queue"] = "next"
        case .later: args["queue"] = "later"
        default: break
        }
        MusicCarBridge.shared.request("playItem", args, completion: finish)
      } else {
        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
      }
    }
  }
}

#if canImport(GoogleCast)
  /// Clones the receiver's acknowledged item, preserving its ID and media metadata.
  private final class CastMusicQueuePlugin: NSObject, FlutterPlugin, GCKRequestDelegate {
    private var pending: (request: GCKRequest, result: FlutterResult, owned: () -> Bool)?
    private var timeout: DispatchWorkItem?

    static func register(with registrar: FlutterPluginRegistrar) {
      let channel = FlutterMethodChannel(name: "com.pleazyng/cast_music_queue", binaryMessenger: registrar.messenger())
      registrar.addMethodCallDelegate(CastMusicQueuePlugin(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      guard call.method == "armRepeat" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard pending == nil, GCKCastContext.isSharedInstanceInitialized(),
        let args = call.arguments as? [String: Any],
        let sessionID = args["session"] as? String, !sessionID.isEmpty,
        let device = args["device"] as? String, !device.isEmpty,
        let mediaSession = args["mediaSession"] as? Int, mediaSession > 0,
        let itemID = args["item"] as? UInt, itemID > 0,
        let token = args["token"] as? String, !token.isEmpty, token.count <= 128,
        let occurrence = args["occurrence"] as? String, !occurrence.isEmpty,
        let contentID = args["contentId"] as? String, contentID == "pleazyng:\(token):\(occurrence)",
        let repeatName = args["repeat"] as? String, ["SINGLE", "ALL"].contains(repeatName),
        let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
        let remote = session.remoteMediaClient
      else {
        result(false)
        return
      }
      let repeatMode: GCKMediaRepeatMode = repeatName == "SINGLE" ? .single : .all
      func mediaMatches(_ media: GCKMediaInformation?) -> Bool {
        let custom = media?.customData as? [String: Any]
        return media?.contentID == contentID && custom?["pleazyngOwner"] as? String == token
          && custom?["pleazyngOccurrence"] as? String == occurrence
      }
      func owned() -> Bool {
        guard GCKCastContext.sharedInstance().sessionManager.currentCastSession === session,
          session.connectionState == .connected, session.sessionID == sessionID,
          session.device.deviceID == device, let status = remote.mediaStatus
        else { return false }
        return status.mediaSessionID == mediaSession && status.currentItemID == itemID
          && status.playerState == .paused && status.queueRepeatMode == repeatMode
          && mediaMatches(status.mediaInformation)
      }
      guard owned(), let item = remote.mediaStatus?.queueItem(withItemID: itemID),
        mediaMatches(item.mediaInformation)
      else {
        result(false)
        return
      }
      let builder = GCKMediaQueueItemBuilder(mediaQueueItem: item)
      builder.autoplay = true
      let request = remote.queueUpdate([builder.build()])
      pending = (
        request, result,
        {
          owned() && remote.mediaStatus?.queueItem(withItemID: itemID)?.autoplay == true
        }
      )
      request.delegate = self
      let deadline = DispatchWorkItem { [weak self, weak request] in
        guard let request else { return }
        self?.finish(request, success: false)
      }
      timeout = deadline
      DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
    }

    private func finish(_ request: GCKRequest, success: Bool) {
      guard let operation = pending, operation.request === request else { return }
      pending = nil
      timeout?.cancel()
      timeout = nil
      request.delegate = nil
      operation.result(success && operation.owned())
    }

    func requestDidComplete(_ request: GCKRequest) {
      finish(request, success: true)
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
      finish(request, success: false)
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
      finish(request, success: false)
    }

    deinit {
      timeout?.cancel()
      pending?.request.delegate = nil
      pending?.result(false)
    }
  }
#endif

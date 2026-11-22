import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var workspaceViews: WorkspaceDesktopWindows?
  private var primaryViewPluginRegistry: PrimaryViewPluginRegistry?

  private var screenshotDirectory: ScreenshotDirectory?
  private var downloadStorageChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
    // FlutterEngineAddView must be able to synchronously reach the Dart UI
    // isolate. Keep the platform and UI task runners merged (see Info.plist),
    // run the engine, then attach the first multiview controller.
    let engine = FlutterEngine(name: "Pleazyng", project: project, allowHeadlessExecution: true)
    let enableMultiView = NSSelectorFromString("enableMultiView")
    let supportsMultiView = engine.responds(to: enableMultiView)
    if supportsMultiView { _ = engine.perform(enableMultiView) }
    workspaceViews = WorkspaceDesktopWindows(engine: engine, parent: self, available: supportsMultiView)
    screenshotDirectory = ScreenshotDirectory(messenger: engine.binaryMessenger)
    DownloadBackupPolicy.refreshExistingRoots()
    let storageChannel = FlutterMethodChannel(
      name: "com.pleazyng/download_storage", binaryMessenger: engine.binaryMessenger)
    storageChannel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup", let path = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        result(try DownloadBackupPolicy.exclude(URL(fileURLWithPath: path)))
      } catch {
        result(FlutterError(code: "backup_exclusion", message: "Could not update download backup policy", details: nil))
      }
    }
    downloadStorageChannel = storageChannel
    let preparationWorker = CommandLine.arguments.contains("--plezy-preparation-worker")
    if preparationWorker {
      NSApp.setActivationPolicy(.prohibited)
      self.orderOut(nil)
      guard engine.run(withEntrypoint: nil) else {
        fatalError("Could not start the Flutter preparation worker engine")
      }
      let flutterViewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
      self.contentViewController = flutterViewController
      let pluginRegistry = PrimaryViewPluginRegistry(engine: engine, primaryViewController: flutterViewController)
      primaryViewPluginRegistry = pluginRegistry
      RegisterGeneratedPlugins(registry: pluginRegistry)
      return
    }

    // Keep the window itself opaque so WindowServer does not have to blend the
    // whole video window with the desktop every frame. Flutter stays clear so
    // the native video layer behind it remains visible.
    self.isOpaque = true
    self.backgroundColor = NSColor.black

    let windowFrame = self.frame

    // Configure window chrome before restoring the saved frame.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    guard engine.run(withEntrypoint: nil) else {
      fatalError("Could not start the Pleazyng Flutter engine")
    }
    let flutterViewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    flutterViewController.backgroundColor = NSColor.clear
    self.contentViewController = flutterViewController

    MpvPlayerPlugin.register(
      with: flutterViewController.registrar(forPlugin: "MpvPlayerPlugin"))

    MpvPlayerPlugin.registerWorkspace(
      with: flutterViewController.registrar(forPlugin: "MpvWorkspacePlayerPlugin"))
    for (slot, pluginName) in [(2, "MpvWorkspace2PlayerPlugin"), (3, "MpvWorkspace3PlayerPlugin")] {
      MpvPlayerPlugin.registerWorkspace(
        with: flutterViewController.registrar(forPlugin: pluginName), slot: slot)
    }

    MpvAudioPlayerPlugin.register(
      with: flutterViewController.registrar(forPlugin: "MpvAudioPlayerPlugin"))

    MpvAudioPlayerPlugin.registerOverlap(
      with: flutterViewController.registrar(forPlugin: "MpvAudioOverlapPlugin"))
    MpvAudioPlayerPlugin.registerGroupOutput(
      with: flutterViewController.registrar(forPlugin: "MpvAudioGroupOutputPlugin"))

    WindowUtilsPlugin.register(
      with: flutterViewController.registrar(forPlugin: "WindowUtilsPlugin"))
    WindowUtilsPlugin.setWindow(self)
    WindowUtilsPlugin.installWindowDelegate()

    AppLookupPlugin.register(
      with: flutterViewController.registrar(forPlugin: "AppLookupPlugin"))

    DeepLinkPlugin.register(
      with: flutterViewController.registrar(forPlugin: "DeepLinkPlugin"))

    PlezySteamPlugin.register(with: flutterViewController.registrar(forPlugin: "PlezySteamPlugin"))

    let pluginRegistry = PrimaryViewPluginRegistry(engine: engine, primaryViewController: flutterViewController)
    primaryViewPluginRegistry = pluginRegistry
    RegisterGeneratedPlugins(registry: pluginRegistry)
    self.setFrame(windowFrame, display: true)

    // Add forwarding toolbar for click-through in titlebar area
    let toolbar = ForwardingToolbar(flutterViewController: flutterViewController)
    self.toolbar = toolbar

    self.setFrameAutosaveName("org.snapetech.plezyng.MainWindow")
    WindowUtilsPlugin.syncWindowChrome()

    super.awakeFromNib()
  }
}

/// Additional Flutter views share the existing engine, isolate and session owners.
private final class WorkspaceDesktopWindows: NSObject {
  private let engine: FlutterEngine
  private weak var parentWindow: NSWindow?
  private let available: Bool
  private let channel: FlutterMethodChannel
  private var windows: [String: WorkspaceDesktopWindow] = [:]
  private var closingObserver: NSObjectProtocol?

  init(engine: FlutterEngine, parent: NSWindow, available: Bool) {
    self.engine = engine
    self.parentWindow = parent
    self.available = available
    channel = FlutterMethodChannel(name: "com.pleazyng/workspace_views", binaryMessenger: engine.binaryMessenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      self.handle(call, result: result)
    }
    closingObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: parent, queue: .main
    ) { [weak self] _ in self?.closeAll() }
  }

  deinit {
    if let closingObserver { NotificationCenter.default.removeObserver(closingObserver) }
    channel.setMethodCallHandler(nil)
    closeAll()
  }

  private func closeAll() {
    let previous = windows
    windows.removeAll()
    for window in previous.values { window.retire() }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "mainViewId" {
      guard let controller = parentWindow?.contentViewController as? FlutterViewController else {
        result(
          FlutterError(
            code: "PRIMARY_VIEW_UNAVAILABLE", message: "The primary Flutter view is not attached", details: nil))
        return
      }
      result(controller.viewIdentifier)
      return
    }
    if call.method == "available" { result(available); return }
    guard let args = call.arguments as? [String: Any],
      let token = args["token"] as? String,
      token.range(of: "^[A-Za-z0-9_-]{32}$", options: .regularExpression) != nil
    else {
      result(FlutterError(code: "INVALID_WINDOW", message: "Invalid window identity", details: nil))
      return
    }
    switch call.method {
    case "create":
      guard available, windows.count < 8, windows[token] == nil,
        let geometry = args["geometryKey"] as? String,
        geometry.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
        let title = args["title"] as? String, title.utf8.count <= 1024
      else {
        result(FlutterError(code: "INVALID_WINDOW", message: "Invalid window configuration", details: nil))
        return
      }
      let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
      let window = WorkspaceDesktopWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = title
      window.minSize = NSSize(width: 320, height: 240)
      window.contentViewController = controller
      window.setFrameAutosaveName("org.snapetech.pleazyng.workspace." + geometry)
      window.delegate = window
      window.requestClose = { [weak self] in
        self?.channel.invokeMethod("closeRequested", arguments: ["token": token])
      }
      if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
        window.center()
      }
      windows[token] = window
      result(["viewId": controller.viewIdentifier])
    case "show":
      windows[token]?.makeKeyAndOrderFront(nil)
      result(nil)
    case "close":
      windows.removeValue(forKey: token)?.retire()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private final class WorkspaceDesktopWindow: NSWindow, NSWindowDelegate {
  var requestClose: (() -> Void)?
  private var retiring = false
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if retiring { return true }
    requestClose?()
    return false
  }

  func retire() {
    guard !retiring else { return }
    retiring = true
    requestClose = nil
    contentViewController = nil
    close()
  }
}

/// Holds a user-selected directory grant while mpv writes screenshots.
private final class ScreenshotDirectory {
  private let key = "desktopScreenshotDirectoryBookmark"
  private let channel: FlutterMethodChannel
  private var active: URL?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.pleazyng/screenshot_directory", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      do {
        switch call.method {
        case "choose":
          let panel = NSOpenPanel()
          panel.canChooseDirectories = true
          panel.canChooseFiles = false
          panel.allowsMultipleSelection = false
          panel.prompt = call.arguments as? String
          guard panel.runModal() == .OK, let url = panel.url else {
            result(nil)
            return
          }
          try self.save(url)
          result(try self.resolve())
        case "resolve":
          result(try self.resolve())
        case "reset":
          UserDefaults.standard.removeObject(forKey: self.key)
          self.releaseAccess()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(
          FlutterError(code: "screenshot_directory", message: "Could not access the screenshot folder", details: nil))
      }
    }
  }

  private func save(_ url: URL) throws {
    let bookmark = try url.bookmarkData(
      options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    UserDefaults.standard.set(bookmark, forKey: key)
  }

  private func resolve() throws -> String? {
    guard let bookmark = UserDefaults.standard.data(forKey: key) else { return nil }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    if active != url {
      let scoped = url.startAccessingSecurityScopedResource()
      guard scoped || FileManager.default.isWritableFile(atPath: url.path) else { return nil }
      releaseAccess()
      if scoped { active = url }
    }
    if stale { try save(url) }
    return url.path
  }

  private func releaseAccess() {
    active?.stopAccessingSecurityScopedResource()
    active = nil
  }

  deinit {
    active?.stopAccessingSecurityScopedResource()
  }
}

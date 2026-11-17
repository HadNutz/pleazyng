import Cocoa
import FlutterMacOS

/// Supplies the primary window's view to macOS plugins that still use the
/// single-view registrar properties while Flutter multiview is enabled.
final class PrimaryViewPluginRegistry: NSObject, FlutterPluginRegistry {
  private static let primaryViewPluginKeys: Set<String> = [
    "DesktopDropPlugin",
    "FilePickerPlugin",
    "WindowManagerPlugin",
  ]

  private let engine: FlutterEngine
  private weak var primaryViewController: FlutterViewController?
  private var registrarProxies: [String: PrimaryViewPluginRegistrar] = [:]

  init(engine: FlutterEngine, primaryViewController: FlutterViewController) {
    self.engine = engine
    self.primaryViewController = primaryViewController
    super.init()
  }

  func registrar(forPlugin pluginKey: String) -> FlutterPluginRegistrar {
    guard Self.primaryViewPluginKeys.contains(pluginKey) else {
      return engine.registrar(forPlugin: pluginKey)
    }
    if let proxy = registrarProxies[pluginKey] {
      return proxy
    }

    let proxy = PrimaryViewPluginRegistrar(
      engineRegistrar: engine.registrar(forPlugin: pluginKey),
      primaryViewController: primaryViewController
    )
    registrarProxies[pluginKey] = proxy
    return proxy
  }

  func valuePublished(byPlugin pluginKey: String) -> NSObject? {
    engine.valuePublished(byPlugin: pluginKey)
  }
}

/// Forwards the registrar contract unchanged except for the legacy single-view
/// accessors, which point at this engine's attached primary controller.
private final class PrimaryViewPluginRegistrar: NSObject, FlutterPluginRegistrar {
  private let engineRegistrar: FlutterPluginRegistrar
  private weak var primaryViewController: FlutterViewController?

  init(engineRegistrar: FlutterPluginRegistrar, primaryViewController: FlutterViewController?) {
    self.engineRegistrar = engineRegistrar
    self.primaryViewController = primaryViewController
    super.init()
  }

  var messenger: FlutterBinaryMessenger {
    engineRegistrar.messenger
  }

  var textures: FlutterTextureRegistry {
    engineRegistrar.textures
  }

  private var attachedPrimaryViewController: FlutterViewController? {
    guard let controller = primaryViewController,
      controller.attached(),
      controller.isViewLoaded,
      controller.view.window != nil
    else {
      return nil
    }
    return controller
  }

  var view: NSView? {
    attachedPrimaryViewController?.view
  }

  var viewController: NSViewController? {
    attachedPrimaryViewController
  }

  func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel) {
    engineRegistrar.addMethodCallDelegate(delegate, channel: channel)
  }

  func addApplicationDelegate(_ delegate: FlutterAppLifecycleDelegate) {
    engineRegistrar.addApplicationDelegate(delegate)
  }

  func register(_ factory: FlutterPlatformViewFactory, withId factoryId: String) {
    engineRegistrar.register(factory, withId: factoryId)
  }

  func publish(_ value: NSObject) {
    engineRegistrar.publish(value)
  }

  func lookupKey(forAsset asset: String) -> String {
    engineRegistrar.lookupKey(forAsset: asset)
  }

  func lookupKey(forAsset asset: String, fromPackage package: String) -> String {
    engineRegistrar.lookupKey(forAsset: asset, fromPackage: package)
  }
}

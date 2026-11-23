part of 'motion_processing_service.dart';

Future<_DesktopPmeRuntime?> _findDesktopPmeRuntime() async {
  final executableDirectory = Directory(p.dirname(Platform.resolvedExecutable));
  final directories = <Directory>[];
  final runtimeOverride = Platform.environment['PLEZY_PME_RUNTIME_DIR']?.trim();
  if (runtimeOverride != null && runtimeOverride.isNotEmpty) {
    directories.add(Directory(runtimeOverride));
  }
  directories.addAll(<Directory>[
    executableDirectory,
    Directory(p.join(executableDirectory.path, 'lib')),
    Directory(p.normalize(p.join(executableDirectory.path, '..', 'lib'))),
    Directory(p.normalize(p.join(executableDirectory.path, '..', 'lib', 'plezy'))),
    Directory(p.normalize(p.join(executableDirectory.path, '..', 'lib', 'plezyng'))),
  ]);
  final windows = Platform.isWindows;
  final manifestName = windows ? 'providers.windows.tsv' : 'providers.linux.tsv';
  final pmeName = windows ? 'plezy_motion_engine.dll' : 'libplezy_motion_engine.so';
  final ortName = windows ? 'onnxruntime.dll' : 'libonnxruntime.so';
  for (final directory in directories) {
    final manifest = File(p.join(directory.path, manifestName));
    final pme = File(p.join(directory.path, pmeName));
    final ort = File(p.join(directory.path, ortName));
    if (await manifest.exists() && await pme.exists() && await ort.exists()) {
      return _DesktopPmeRuntime(providerManifest: manifest.path, pmeLibrary: pme.path, ortLibrary: ort.path);
    }
  }
  return null;
}

/// Hardware routes a motion setting can offer on the selected playback backend.
final class MotionSmoothingCapabilities {
  const MotionSmoothingCapabilities({
    this.mpv = false,
    this.gpu = false,
    this.npu = false,
    this.mpvGpu = false,
    this.videoToolbox = false,
  });

  final bool mpv;
  final bool gpu;
  final bool npu;
  final bool mpvGpu;
  final bool videoToolbox;

  bool get neural => gpu || npu || videoToolbox;

  List<MotionProcessingMode> get modes => [
    MotionProcessingMode.off,
    if (mpv) MotionProcessingMode.mpv,
    if (neural) MotionProcessingMode.neural,
  ];

  static Future<({bool gpu, bool npu})>? _deviceAccelerators;

  static bool supportsMpv(String backend) =>
      backend == 'tvmpv' || (backend == 'mpv' && MotionProcessingService.isMpvPlatformSupported);

  static MotionSmoothingCapabilities forBackend(String backend) =>
      MotionSmoothingCapabilities(mpv: supportsMpv(backend));

  static Future<MotionSmoothingCapabilities> detectPlayer(Player player) => detect(player.playerType, player: player);

  static Future<MotionSmoothingCapabilities> detect(String backend, {Player? player}) async {
    final mpv = supportsMpv(backend);
    if (!mpv || backend == 'tvmpv') return MotionSmoothingCapabilities(mpv: mpv);
    try {
      if (MotionProcessingService._isApplePlatform && player != null) {
        final output = await player.getProperty('current-vo').timeout(const Duration(seconds: 1));
        if (output != null && output.isNotEmpty && output != 'avfoundation') {
          return const MotionSmoothingCapabilities();
        }
        final [mixer, videoToolbox] = await Future.wait([
          player.getProperty('pleazyng-apple-mixer-gpu-supported'),
          player.getProperty('pleazyng-vt-motion-supported'),
        ]).timeout(const Duration(seconds: 1));
        return MotionSmoothingCapabilities(mpv: mpv, mpvGpu: mixer == 'yes', videoToolbox: videoToolbox == 'yes');
      }
      final hardware = await (_deviceAccelerators ??= _detectHardware());
      return MotionSmoothingCapabilities(mpv: mpv, gpu: hardware.gpu, npu: hardware.npu);
    } catch (error) {
      // An unavailable probe provides no evidence for advertising hardware.
      _deviceAccelerators = null;
      appLogger.d('Motion accelerator capabilities unavailable', error: error);
      return MotionSmoothingCapabilities(mpv: mpv);
    }
  }

  static Future<({bool gpu, bool npu})> _detectHardware() async {
    if (Platform.isAndroid) {
      const channel = MethodChannel('com.plezy/mpv_player');
      final capabilities = await channel
          .invokeMapMethod<Object?, Object?>('getAndroidMotionRuntimeCapabilities')
          .timeout(const Duration(seconds: 3));
      return androidMotionAccelerators(capabilities ?? const {});
    }
    if (!MotionProcessingService._isDesktopPmePlatform) return (gpu: false, npu: false);
    final runtime = await _findDesktopPmeRuntime();
    if (runtime == null) return (gpu: false, npu: false);
    final manifestFile = File(runtime.providerManifest);
    final installedProviders = <String>[];
    for (final line in await manifestFile.readAsLines()) {
      final fields = line.trim().split('\t');
      if (fields.length < 3 || line.trimLeft().startsWith('#')) continue;
      final library = fields[2];
      if (library == 'windows-ml' ||
          library.startsWith('builtin-') ||
          await File(p.join(manifestFile.parent.path, library)).exists()) {
        installedProviders.add(line);
      }
    }
    final manifest = installedProviders.join('\n');
    if (Platform.isLinux) return linuxMotionAccelerators(Directory('/sys/class'), manifest);
    return _windowsMotionAccelerators(manifest);
  }

  @visibleForTesting
  static ({bool gpu, bool npu}) androidMotionAccelerators(Map<Object?, Object?> capabilities) {
    final modelPack = capabilities['litertModelManifestPresent'] == true;
    final contexts = capabilities['anvilContextIds'];
    final npuProviders = capabilities['litertNpuProviders'];
    return (
      gpu: modelPack && capabilities['litertGpuAvailable'] == true && capabilities['gpuHardwareAvailable'] == true,
      npu:
          (capabilities['qnnHtpAvailable'] == true && contexts is List && contexts.isNotEmpty) ||
          (modelPack && npuProviders is List && npuProviders.any(const {'google-tensor', 'samsung'}.contains)),
    );
  }

  @visibleForTesting
  static Future<({bool gpu, bool npu})> linuxMotionAccelerators(Directory sysClass, String manifest) async {
    Future<bool> hasDriver(String subsystem, RegExp nodeName, Set<String> drivers) async {
      final directory = Directory(p.join(sysClass.path, subsystem));
      if (!await directory.exists()) return false;
      await for (final node in directory.list(followLinks: false)) {
        if (!nodeName.hasMatch(p.basename(node.path))) continue;
        final driver = Link(p.join(node.path, 'device', 'driver'));
        if (await driver.exists() && drivers.contains(p.basename(await driver.target()))) return true;
      }
      return false;
    }

    final renderNode = RegExp(r'^renderD\d+$');
    final gpu =
        (_hasProvider(manifest, 'GPU', {'WebGpuExecutionProvider'}) &&
            await hasDriver('drm', renderNode, {'amdgpu', 'nvidia', 'nouveau', 'i915', 'xe', 'panthor', 'msm'})) ||
        (_hasProvider(manifest, 'GPU', {'MIGraphXExecutionProvider'}) &&
            await hasDriver('drm', renderNode, {'amdgpu'})) ||
        (_hasProvider(manifest, 'GPU', {'OpenVINOExecutionProvider'}) &&
            await hasDriver('drm', renderNode, {'i915', 'xe'}));
    final npu =
        _hasProvider(manifest, 'NPU', {'OpenVINOExecutionProvider'}) &&
        await hasDriver('accel', RegExp(r'^accel\d+$'), {'intel_vpu', 'ivpu'});
    return (gpu: gpu, npu: npu);
  }

  static Future<({bool gpu, bool npu})> _windowsMotionAccelerators(String manifest) async {
    final root = Platform.environment['SystemRoot'];
    if (root == null) return (gpu: false, npu: false);
    final powershell = p.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    final process = await Process.start(powershell, [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'''
$devices = Get-PnpDevice -PresentOnly -Status OK -Class Display,ComputeAccelerator -ErrorAction SilentlyContinue
foreach ($device in $devices) {
  if ($device.Class -eq 'Display' -and
      ($device.InstanceId -match '^PCI\\VEN_(1002|8086|10DE|5143)' -or $device.FriendlyName -match 'Adreno')) { 'GPU' }
  if ($device.Class -eq 'ComputeAccelerator') {
    if ($device.FriendlyName -match 'Intel.*(NPU|AI Boost|Neural)') { 'NPU:OpenVINO' }
    if ($device.FriendlyName -match 'AMD.*(NPU|IPU|Ryzen AI)') { 'NPU:VitisAI' }
    if ($device.FriendlyName -match '(Qualcomm|Snapdragon).*(NPU|Neural|Hexagon)') { 'NPU:QNN' }
  }
}
''',
    ]);
    final output = process.stdout.transform(const SystemEncoding().decoder).toList();
    final errors = process.stderr.drain<void>();
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      rethrow;
    }
    await errors;
    final kinds = (await output).join().split(RegExp(r'\s+')).toSet();
    return (
      gpu: exitCode == 0 && kinds.contains('GPU') && _hasProvider(manifest, 'GPU'),
      npu:
          exitCode == 0 &&
          _hasProvider(manifest, 'NPU', {
            for (final kind in kinds)
              if (kind.startsWith('NPU:')) kind.substring(4),
          }),
    );
  }

  static bool _hasProvider(String manifest, String kind, [Set<String>? names]) => manifest.split('\n').any((line) {
    final fields = line.trim().split('\t');
    return fields.length >= 3 && fields[1] == kind && (names == null || names.contains(fields.first));
  });
}

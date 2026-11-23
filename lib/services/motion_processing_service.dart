import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../media/media_stream.dart';
import '../media/media_version.dart';
import '../models/motion_processing_mode.dart';
import '../models/playback_capability_report.dart';
import '../mpv/models.dart';
import '../mpv/player/player.dart';
import '../mpv/player/platform/player_system.dart';
import '../mpv/player/player_native.dart';
import 'android_anvil_provider_status.dart';
import 'motion_clarity_service.dart';
import 'neural_model_pack_service.dart';
import 'power_source_service.dart';
import 'settings_service.dart';
import '../utils/app_logger.dart';

part 'motion_processing_mpv.dart';

/// Applies display-synced MPV temporal interpolation. Windows uses gpu-next;
/// Linux's Wayland video plane supplies monitor refresh and render-swap
/// feedback to libmpv. Android keeps direct MediaCodec output for Off and opts
/// into an arbiter-managed GPU output for eligible MPV/Neural sessions. Apple Neural
/// requests use the AVFoundation VO's VideoToolbox frame processor.
abstract final class MotionProcessingService {
  static final Expando<_OriginalMotionProperties> _originals = Expando('motion-processing-originals');
  static final Expando<_OriginalAppleMotionOptions> _appleOriginals = Expando('motion-processing-apple-originals');
  static final Expando<StreamSubscription<void>> _appleLoadSubscriptions = Expando('apple-motion-file-loads');
  static final Expando<bool> _appleFileLoaded = Expando('apple-motion-file-loaded');
  static final Expando<String> _appleMixerOriginalHwdec = Expando('apple-motion-hwdec');
  static final Expando<String> _appleMixer = Expando('apple-frame-mixer');
  static final Expando<bool> _appleNeuralEligible = Expando('motion-processing-apple-neural-eligible');
  static final Expando<NeuralInterpolationPreset> _appleNeuralPreset = Expando('motion-processing-apple-neural-preset');
  static final Expando<_OriginalAndroidMotionOptions> _androidOriginals = Expando(
    'motion-processing-android-originals',
  );
  static final Expando<bool> _androidAnvilActive = Expando('motion-processing-android-anvil-active');
  static final Expando<int> _androidAnvilProviderGeneration = Expando('motion-processing-android-provider-generation');
  static final Expando<_AndroidAnvilBackend> _androidAnvilBackend = Expando('motion-processing-android-backend');
  static final Expando<int> _androidAnvilRequestGeneration = Expando('motion-processing-android-request-generation');
  static final Expando<String> _configuredNeuralModelId = Expando('motion-processing-configured-neural-model-id');
  static final Expando<NeuralInterpolationPreset> _androidAnvilPreset = Expando(
    'motion-processing-android-anvil-preset',
  );
  static final Expando<bool> _androidMpvOutputActive = Expando('motion-processing-android-mpv-output-active');
  static final Expando<bool> _interpolationBufferReady = Expando('motion-processing-buffer-ready');
  static final Expando<bool> _desktopPmeActive = Expando('motion-processing-desktop-pme-active');
  static final Expando<NeuralInterpolationPreset> _desktopPmePreset = Expando('motion-processing-desktop-pme-preset');
  static final Expando<MediaVersion> _sessionSelectedVersion = Expando('motion-processing-session-version');
  static final Expando<bool> _sessionIsLive = Expando('motion-processing-session-live');
  static final Expando<bool> _sessionIsTranscoding = Expando('motion-processing-session-transcoding');
  static final Expando<bool> _powerLimited = Expando('motion-processing-power-limited');
  static final Expando<bool> _thermalLimited = Expando('motion-processing-thermal-limited');
  static final Expando<String> _thermalStatus = Expando('motion-processing-thermal-status');
  static final Expando<Timer> _thermalTimers = Expando('motion-processing-thermal-timer');
  static final Expando<bool> _thermalPollInFlight = Expando('motion-processing-thermal-poll-in-flight');
  static final Expando<int> _thermalGeneration = Expando('motion-processing-thermal-generation');
  static final Expando<bool> _powerSuspendedForSession = Expando('motion-processing-power-suspended');
  static final Expando<bool> _neuralRequested = Expando('motion-processing-neural-requested');
  static final Expando<StreamSubscription<bool?>> _powerSubscriptions = Expando('motion-processing-power-subscription');
  static final Expando<int> _powerSourceGeneration = Expando('motion-processing-power-generation');
  static final Expando<_OriginalDesktopPmeOptions> _desktopPmeOriginals = Expando(
    'motion-processing-desktop-pme-originals',
  );
  static final Expando<Future<void>> _operationTails = Expando('motion-processing-operation-tails');
  static final Expando<StreamSubscription<Tracks>> _videoTrackSubscriptions = Expando(
    'motion-processing-video-track-subscription',
  );
  static final Expando<String> _lastVideoTrackSelection = Expando('motion-processing-last-video-track-selection');
  static final Expando<int> _videoTrackMonitorGeneration = Expando('motion-processing-video-track-generation');
  static final Expando<int> _motionSessionGeneration = Expando('motion-processing-session-generation');
  static final Expando<bool> _interlacedTrackSuppressed = Expando('motion-processing-interlaced-track-suppressed');

  /// Windows uses MPV's embedded gpu-next output. Linux's Wayland plane uses
  /// libmpv and reports both display refresh and successful swaps. Android
  /// keeps direct-to-surface MediaCodec by default and requests a GPU VO through
  /// the native surface arbiter only for an eligible motion-processing path.
  static bool get isMpvPlatformSupported =>
      Platform.isWindows || Platform.isLinux || Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  static bool get _isApplePlatform => Platform.isIOS || Platform.isMacOS;

  static bool get _isDesktopPmePlatform => Platform.isWindows || Platform.isLinux;

  static bool supportsPlayer(Player player) =>
      player.playerType == 'tvmpv' || (isMpvPlatformSupported && player.playerType == 'mpv');

  /// A CPU session only qualifies after the filter reports generated frames.
  static bool isCpuOnlyNeuralProviderStatus(String? providerStatus) {
    final normalized = providerStatus?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return false;
    final provider = normalized.endsWith('-ready')
        ? normalized.substring(0, normalized.length - '-ready'.length)
        : normalized;
    return provider == 'cpu' ||
        provider == 'cpu-fallback' ||
        provider == 'cpuexecutionprovider' ||
        provider.endsWith('-cpu') ||
        provider.endsWith(':cpu') ||
        provider.endsWith(':cpuexecutionprovider');
  }

  static bool isNeuralBypassStatus(String? status) =>
      const {'cpu-fallback', 'cpu-fallback-ready'}.contains(status?.trim().toLowerCase());

  /// Resolves a request to a provider available on this player's output path.
  /// Apple Neural mode is available only while the AVFoundation VideoToolbox
  /// processor reports initialization, readiness, or actual frame output.
  static MotionProcessingResolution resolveForPlayer(
    Player player,
    MotionProcessingMode requested, {
    String? currentVideoOutput,
    String? nativeInterpolationStatus,
    String? neuralProviderStatus,
    PlaybackCapabilityReport? capabilityReport,
    bool isLive = false,
    NeuralInterpolationPreset neuralPreset = NeuralInterpolationPreset.balanced,
  }) {
    final appleOutput = _isApplePlatform && (currentVideoOutput == null || currentVideoOutput == 'avfoundation');
    final rendererAvailable =
        supportsPlayer(player) &&
        !appleOutput &&
        (currentVideoOutput == null
            ? capabilityReport == null
            : player.playerType == 'tvmpv'
            ? currentVideoOutput == 'libmpv-texture'
            : _supportsVideoOutput(currentVideoOutput)) &&
        (capabilityReport == null || capabilityReport.rendererInterpolationActive == true);
    final providerStatus = capabilityReport?.neuralProvider ?? neuralProviderStatus;
    final normalizedProviderStatus = neuralProviderStatus?.trim().toLowerCase();
    final providerReady =
        !isNeuralBypassStatus(providerStatus) &&
        (!isCpuOnlyNeuralProviderStatus(providerStatus) || capabilityReport?.hasObservedNeuralOutput == true) &&
        (capabilityReport?.neuralProviderReady ??
            (normalizedProviderStatus != null &&
                RegExp(
                  r'^(qnn-htp(-v\d+)?|qnn-(npu|gpu)|litert-(npu|gpu)|openvino(-npu|-gpu)?|cuda-gpu|directml-gpu|vitisai-npu|nvtensorrtrtx-gpu|migraphx-gpu|webgpu(-gpu)?|webgpuexecutionprovider|winml(-npu|-gpu)?)(-ready)?$|^pme:(openvino|qnn|cuda|directml)(:(npu|gpu))?(-ready)?$',
                ).hasMatch(normalizedProviderStatus)));
    final nativeProviderReady =
        (appleOutput && const {'initializing', 'ready', 'active'}.contains(nativeInterpolationStatus)) ||
        (rendererAvailable &&
            providerReady &&
            !const {'mpv-bypass', 'recovery-probe'}.contains(capabilityReport?.neuralDeadlineGovernor));
    final streamSupported = capabilityReport == null || _supportsReportedMotionStream(capabilityReport);
    final neuralStreamFallback = capabilityReport?.dolbyVisionProfile != null
        ? MotionProcessingFallback.dolbyVision
        : capabilityReport?.sourceIsHdr == true
        ? MotionProcessingFallback.highDynamicRange
        : null;
    final desktopCadenceStatus = capabilityReport?.sourceCadenceStatus;
    final desktopCadenceConfirmed =
        !_isDesktopPmePlatform || capabilityReport == null || const {'cfr-24', 'cfr-30'}.contains(desktopCadenceStatus);
    return resolveMotionProcessing(
      requested: requested,
      mpvRendererAvailable:
          (rendererAvailable ||
              (appleOutput && const {'libplacebo GPU', 'FFmpeg CPU'}.contains(nativeInterpolationStatus))) &&
          streamSupported,
      neuralProviderAvailable: nativeProviderReady && streamSupported && desktopCadenceConfirmed,
      neuralStreamSupported: neuralStreamFallback == null,
      neuralStreamFallback: neuralStreamFallback ?? MotionProcessingFallback.unsupportedStream,
      neuralPowerLimited:
          _powerLimited[player] == true &&
          (SettingsService.instanceOrNull?.read(SettingsService.neuralOnlyWhenPluggedIn) ?? true),
      neuralThermalLimited: _thermalLimited[player] == true,
      isLive: isLive,
      streamSupported: streamSupported,
      neuralPreset: neuralPreset,
    );
  }

  static bool supportsTvMotionSource(MediaVersion? version) => version != null && _supportsMotionSource(version);

  /// Active stream facts can invalidate a previously configured renderer path
  /// after a track or file transition. Missing facts remain unknown; positive
  /// evidence outside the initial progressive 24/30 fps, up-to-1080p scope
  /// resolves the request to Off. HDR/Dolby Vision is a separate Neural-only
  /// restriction because desktop MPV smoothing can remain available.
  static bool _supportsReportedMotionStream(PlaybackCapabilityReport report) {
    if (report.sourceIsInterlaced == true) return false;

    final width = report.sourceWidth;
    final height = report.sourceHeight;
    if ((width != null && width > 1920) || (height != null && height > 1920)) return false;
    if (width != null && width > 0 && height != null && height > 0) {
      final longerEdge = width > height ? width : height;
      final shorterEdge = width > height ? height : width;
      if (longerEdge > 1920 || shorterEdge > 1080) return false;
    }

    final fps = report.sourceFps;
    // Desktop PME measures cadence from decoded source PTS. Prefer it over
    // container FPS metadata, which can be wrong for VFR or remuxed media.
    // MPV can still smooth irregular cadence; Neural needs confirmed CFR.
    final measuredDesktopCadence =
        _isDesktopPmePlatform &&
        const {
          'probing',
          'cfr-24',
          'cfr-30',
          'non-uniform-pts',
          'pts-discontinuity',
        }.contains(report.sourceCadenceStatus);
    if (!measuredDesktopCadence && fps != null && fps > 0 && (fps - 24).abs() > 0.1 && (fps - 30).abs() > 0.1) {
      return false;
    }
    return true;
  }

  /// Scan type for the video track currently decoded by MPV.
  ///
  /// The server's selected-track flag is only a setup-time fallback. During
  /// playback, use the active FFmpeg stream index when MPV reports libavformat
  /// as its demuxer; other demuxers can expose a different index space. A
  /// missing or ambiguous match stays unknown so motion eligibility never
  /// assumes that the active source is progressive.
  static bool? sourceInterlacedForPlayer(
    Player player, {
    int? activeVideoStreamIndex,
    String? currentDemuxer,
    bool allowSelectedTrackFallback = true,
  }) {
    final version = _sessionSelectedVersion[player];
    if (version == null) return null;

    final streams = version.parts
        .expand((part) => part.streams)
        .where((stream) => stream.kind == MediaStreamKind.video)
        .toList(growable: false);

    final demuxer = currentDemuxer?.trim().toLowerCase();
    if (activeVideoStreamIndex != null || (demuxer != null && demuxer.isNotEmpty)) {
      if (demuxer != 'lavf' || activeVideoStreamIndex == null) return null;
      final scanTypes = streams
          .where((stream) => stream.index == activeVideoStreamIndex)
          .map((stream) => stream.interlaced)
          .toSet();
      return scanTypes.length == 1 ? scanTypes.single : null;
    }

    if (!allowSelectedTrackFallback) return null;

    final video = streams.firstWhere(
      (stream) => stream.selected,
      orElse: () => streams.length == 1 ? streams.single : const MediaStream(id: '', kind: MediaStreamKind.unknown),
    );
    return video.kind == MediaStreamKind.video ? video.interlaced : null;
  }

  static void _watchVideoTrackChanges(Player player) {
    if (_videoTrackSubscriptions[player] != null) return;
    final generation = _videoTrackMonitorGeneration[player] ?? 0;
    _videoTrackMonitorGeneration[player] = generation;
    _videoTrackSubscriptions[player] = player.streams.tracks.listen((tracks) {
      final selection = tracks.video.where((track) => track.isSelected).map((track) => track.id).join('\u0000');
      final previous = _lastVideoTrackSelection[player];
      if (previous == selection) return;
      if (selection.isEmpty) {
        if (previous != null && previous.isNotEmpty) _lastVideoTrackSelection[player] = '';
        return;
      }
      _lastVideoTrackSelection[player] = selection;

      final selectionChanged = previous != null && previous != selection;
      unawaited(
        _checkActiveVideoTrack(
          player,
          selectionChanged: selectionChanged,
          generation: generation,
          sessionGeneration: _motionSessionGeneration[player] ?? 0,
        ),
      );
    });
  }

  static Future<void> _checkActiveVideoTrack(
    Player player, {
    required bool selectionChanged,
    required int generation,
    required int sessionGeneration,
  }) async {
    try {
      await _serializePlayerOperation(player, () async {
        if (_videoTrackMonitorGeneration[player] != generation ||
            _motionSessionGeneration[player] != sessionGeneration ||
            _sessionSelectedVersion[player] == null) {
          return;
        }
        final demuxer = await player.getProperty('current-demuxer');
        final streamIndex = int.tryParse(await player.getProperty('current-tracks/video/ff-index') ?? '');
        final interlaced = sourceInterlacedForPlayer(
          player,
          activeVideoStreamIndex: streamIndex,
          currentDemuxer: demuxer,
          allowSelectedTrackFallback: !selectionChanged,
        );
        if (interlaced != true && !(selectionChanged && interlaced == null)) return;
        if (_interlacedTrackSuppressed[player] == true) return;
        if (!_hasActiveMotionProcessing(player)) {
          // A title started in Off can still enable interpolation later.
          _interlacedTrackSuppressed[player] = true;
          return;
        }
        await _suspendMotionForUnsupportedTrack(player);
      });
    } catch (error, stackTrace) {
      appLogger.w(
        'MotionProcessingService: could not suspend motion processing after a video-track change',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static bool _hasActiveMotionProcessing(Player player) =>
      _desktopPmeActive[player] == true ||
      _androidAnvilActive[player] == true ||
      _androidMpvOutputActive[player] == true ||
      _appleMixerOriginalHwdec[player] != null ||
      _appleNeuralPreset[player] != null ||
      (_originals[player] != null && _interpolationBufferReady[player] == true);

  /// Stop generated frames after switching to an interlaced or unclassifiable
  /// alternate track. Keep the current renderer and decoder choice in place;
  /// motion can be configured again at the next media open.
  static Future<void> _suspendMotionForUnsupportedTrack(Player player) async {
    if (_desktopPmeActive[player] == true) {
      if (await _removeDesktopPmeFilter(player)) {
        _desktopPmeActive[player] = false;
        _desktopPmePreset[player] = null;
      }
    }
    if (_androidAnvilActive[player] == true) {
      if (await _removeAndroidAnvilFilter(player)) {
        _androidAnvilActive[player] = false;
        _androidAnvilPreset[player] = null;
      }
    }
    if (_appleMixerOriginalHwdec[player] != null) await _setAppleMixer(player, false);
    if (_appleNeuralPreset[player] != null) {
      await player.setProperty('avfoundation-motion-interpolation', 'no');
      _appleNeuralPreset[player] = null;
      _appleNeuralEligible[player] = false;
    }
    if (_originals[player] != null ||
        _desktopPmeActive[player] == true ||
        _androidAnvilActive[player] == true ||
        _androidMpvOutputActive[player] == true) {
      await player.setProperty('interpolation', 'no');
    }
    _interpolationBufferReady[player] = false;
    _neuralRequested[player] = false;
    await _stopPowerMonitoring(player);
    await _stopThermalMonitoring(player);
    _interlacedTrackSuppressed[player] = true;
    appLogger.w(
      'MotionProcessingService: motion processing stopped for an interlaced or unclassifiable video track; it will resume at the next media open.',
    );
  }

  static bool _supportsVideoOutput(String output) {
    if (Platform.isWindows) return output == 'gpu' || output == 'gpu-next';
    if (Platform.isLinux) return output == 'libmpv';
    if (Platform.isAndroid) return output == 'gpu' || output == 'gpu-next';
    return false;
  }

  /// Last platform thermal tier seen by the Neural governor. Null means the
  /// OS or device did not report a value.
  static String? thermalStatusForPlayer(Player player) => _thermalStatus[player];

  /// Configured model pack for a model-backed Neural session, when selected.
  /// This does not mean that the provider has produced output.
  static String? configuredNeuralModelIdForPlayer(Player player) => _configuredNeuralModelId[player];

  /// Resolve Android before `loadfile` from its active VO or configured chain.
  /// An explicit eligible MPV request may replace the default
  /// `mediacodec,gpu` priority with the GPU renderer for this session.
  static Future<String?> _videoOutputForConfiguration(Player player) async {
    final current = await player.getProperty('current-vo');
    if (current != null && current.isNotEmpty) return current;
    if (Platform.isAndroid || _isApplePlatform) return player.getProperty('vo');
    return null;
  }

  /// mpv's filter graph and native surface choice are shared by all motion
  /// paths for one player. Serialize async transitions so a slow provider setup
  /// cannot finish after a newer mode or lifecycle request.
  static Future<T> _serializePlayerOperation<T>(Player player, Future<T> Function() operation) {
    final previous = _operationTails[player] ?? Future<void>.value();
    final release = Completer<void>();
    _operationTails[player] = release.future;
    return () async {
      try {
        await previous;
        return await operation();
      } finally {
        if (identical(_operationTails[player], release.future)) {
          _operationTails[player] = null;
        }
        release.complete();
      }
    }();
  }

  /// Whether this session can enable motion processing or tear it down.
  /// Live streams may turn processing off but cannot start it.
  static bool canChangeLive(Player player, {required MotionProcessingMode mode, bool isLive = false}) {
    if (!supportsPlayer(player)) return false;
    if (mode == MotionProcessingMode.off) return true;
    if (isLive || _interlacedTrackSuppressed[player] == true) return false;
    if (player is PlayerSystem) return player.canChangeTvMotion;
    final version = _sessionSelectedVersion[player];
    if (_sessionIsLive[player] != false || _sessionIsTranscoding[player] != false) return false;
    if (_isDesktopPmePlatform && mode == MotionProcessingMode.mpv) {
      return _supportsDesktopMpvSource(version) &&
          (_interpolationBufferReady[player] == true ||
              MotionClarityService.forPlayer(player).desktopFramePoolPrepared);
    }
    if (version == null) return false;
    if (_isApplePlatform) return _appleNeuralEligible[player] == true;
    if (Platform.isAndroid) return _supportsMotionSource(version);
    return _isDesktopPmePlatform && _supportsMotionSource(version, allowDynamicRange: true);
  }

  /// Preset of the active TV mixer or neural processor.
  static NeuralInterpolationPreset? activeMotionPresetForPlayer(Player player) {
    if (player is PlayerSystem && player.playerType == 'tvmpv') return player.activeTvMotionPreset;
    if (_isApplePlatform && _appleNeuralEligible[player] == true) return _appleNeuralPreset[player];
    if (_isDesktopPmePlatform && _desktopPmeActive[player] == true) return _desktopPmePreset[player];
    if (Platform.isAndroid && _androidAnvilActive[player] == true) return _androidAnvilPreset[player];
    return null;
  }

  /// Configure interpolation before the first file opens so MPV can size its
  /// renderer references and any hardware-decoder surface pool.
  static Future<void> configureForPlayback(
    Player player,
    MotionProcessingMode mode, {
    bool isLive = false,
    bool isTranscoding = false,
    MediaVersion? selectedVersion,
    NeuralInterpolationPreset neuralPreset = NeuralInterpolationPreset.balanced,
  }) {
    _advanceAndroidAnvilRequestGeneration(player);
    _invalidateAndroidAnvilProviderWatch(player);
    return _serializePlayerOperation(
      player,
      () => _configureForPlayback(
        player,
        mode,
        isLive: isLive,
        isTranscoding: isTranscoding,
        selectedVersion: selectedVersion,
        neuralPreset: neuralPreset,
      ),
    );
  }

  static Future<void> _configureForPlayback(
    Player player,
    MotionProcessingMode mode, {
    bool isLive = false,
    bool isTranscoding = false,
    MediaVersion? selectedVersion,
    NeuralInterpolationPreset neuralPreset = NeuralInterpolationPreset.balanced,
  }) async {
    if (!supportsPlayer(player)) return;
    if (player is PlayerSystem && player.playerType == 'tvmpv') {
      player.prepareTvMotion(
        mode != MotionProcessingMode.off,
        eligible: !isLive && !isTranscoding && supportsTvMotionSource(selectedVersion),
        preset: neuralPreset,
      );
      return;
    }
    _sessionSelectedVersion[player] = selectedVersion;
    _sessionIsLive[player] = isLive;
    _sessionIsTranscoding[player] = isTranscoding;
    _motionSessionGeneration[player] = (_motionSessionGeneration[player] ?? 0) + 1;
    _interlacedTrackSuppressed[player] = false;
    _lastVideoTrackSelection[player] = null;
    _watchVideoTrackChanges(player);
    if (_isApplePlatform) {
      _appleFileLoaded[player] = false;
      _appleLoadSubscriptions[player] ??= player.streams.fileLoaded.listen((_) => _appleFileLoaded[player] = true);
    }
    _powerSuspendedForSession[player] = false;
    final powerLimited = await _preparePowerPolicy(player, mode);
    final thermalLimited = await _prepareThermalPolicy(player, mode);
    final effectiveMode = powerLimited || thermalLimited
        ? (_isApplePlatform ? MotionProcessingMode.off : MotionProcessingMode.mpv)
        : mode;
    await _configureForPlaybackImpl(
      player,
      effectiveMode,
      isLive: isLive,
      isTranscoding: isTranscoding,
      selectedVersion: selectedVersion,
      neuralPreset: neuralPreset,
    );
    // A power-source event can arrive while provider setup is awaiting a model
    // or runtime. Recheck the latch after setup so a late initialization never
    // re-enables inference on battery.
    if (mode.usesNeuralInterpolation && _powerLimited[player] == true) {
      if (!await _suspendNeuralForPower(player)) _powerLimited[player] = false;
    }
    if (mode.usesNeuralInterpolation && !powerLimited && !thermalLimited) {
      final androidNeuralActive = Platform.isAndroid && _androidAnvilActive[player] == true;
      final appleNeuralEligible = _isApplePlatform && _appleNeuralEligible[player] == true;
      if (androidNeuralActive && player is PlayerNative && selectedVersion != null) {
        _watchAndroidAnvilProvider(player, selectedVersion: selectedVersion, neuralPreset: neuralPreset);
      }
      if (androidNeuralActive || appleNeuralEligible) _watchPlatformThermalStatus(player);
    }
  }

  static Future<void> _configureForPlaybackImpl(
    Player player,
    MotionProcessingMode mode, {
    bool isLive = false,
    bool isTranscoding = false,
    MediaVersion? selectedVersion,
    NeuralInterpolationPreset neuralPreset = NeuralInterpolationPreset.balanced,
  }) async {
    if (!supportsPlayer(player)) return;
    _configuredNeuralModelId[player] = null;
    if (_isApplePlatform) {
      final output = await _videoOutputForConfiguration(player);
      final avfoundationOutput = output == null || output == 'avfoundation';
      final sourceEligible =
          avfoundationOutput &&
          !isLive &&
          !isTranscoding &&
          selectedVersion != null &&
          _supportsMotionSource(selectedVersion);
      _appleNeuralEligible[player] = sourceEligible;
      await configureAppleMotion(player, sourceEligible ? mode : MotionProcessingMode.off, neuralPreset);
      _interpolationBufferReady[player] = avfoundationOutput;
      return;
    }

    if (Platform.isAndroid && mode.usesMpvInterpolation) {
      final canKeepConfiguredRenderer =
          _androidMpvOutputActive[player] == true &&
          _androidAnvilActive[player] != true &&
          !isLive &&
          !isTranscoding &&
          selectedVersion != null &&
          _supportsMotionSource(selectedVersion);
      if (!canKeepConfiguredRenderer) {
        await _restoreAndroidMotionPath(player);
        final originalMpv = _originals[player];
        if (originalMpv != null) await _restoreOriginalProperties(player, originalMpv);
      }
      final configured = await _configureAndroidMpvRenderer(
        player,
        selectedVersion: selectedVersion,
        isLive: isLive,
        isTranscoding: isTranscoding,
      );
      if (configured) {
        try {
          await _applyMpvInterpolation(player);
          _interpolationBufferReady[player] = true;
          return;
        } catch (_) {
          await _restoreAndroidMotionPath(player);
          rethrow;
        }
      }
      _interpolationBufferReady[player] = false;
      return;
    }

    if (Platform.isAndroid && mode.usesNeuralInterpolation) {
      _interpolationBufferReady[player] = false;
      final originalMpv = _originals[player];
      if (originalMpv != null) await _restoreOriginalProperties(player, originalMpv);
      final configured = await _configureAndroidAnvil(
        player,
        selectedVersion: selectedVersion,
        neuralPreset: neuralPreset,
        isLive: isLive,
        isTranscoding: isTranscoding,
      );
      if (configured) {
        try {
          // ANVIL emits a midpoint frame per source pair; MPV's display-sync
          // scheduler paces those frames against the active refresh rate.
          await _applyMpvInterpolation(player);
          _interpolationBufferReady[player] = true;
          return;
        } catch (_) {
          await _restoreAndroidMotionPath(player);
          rethrow;
        }
      }
      await _restoreAndroidMotionPath(player);
      final fallbackOriginalMpv = _originals[player];
      if (fallbackOriginalMpv != null) await _restoreOriginalProperties(player, fallbackOriginalMpv);
      final fallbackRenderer = await _configureAndroidMpvRenderer(
        player,
        selectedVersion: selectedVersion,
        isLive: isLive,
        isTranscoding: isTranscoding,
      );
      if (fallbackRenderer) {
        try {
          await _applyMpvInterpolation(player);
          _interpolationBufferReady[player] = true;
          appLogger.i(
            'MotionProcessingService: Android Neural processing is unavailable for this session; using MPV smoothing.',
          );
        } catch (_) {
          await _restoreAndroidMotionPath(player);
          rethrow;
        }
        return;
      }
      appLogger.i(
        'MotionProcessingService: Android Neural processing is unavailable for this item; preserving its normal playback path.',
      );
      return;
    }
    if (Platform.isAndroid) await _restoreAndroidMotionPath(player);

    if (_isDesktopPmePlatform && mode.usesNeuralInterpolation) {
      _interpolationBufferReady[player] = false;
      final configured = await _configureDesktopPme(
        player,
        selectedVersion: selectedVersion,
        neuralPreset: neuralPreset,
        isLive: isLive,
        isTranscoding: isTranscoding,
      );
      if (configured) {
        try {
          await _applyMpvInterpolation(player);
          _interpolationBufferReady[player] = true;
          return;
        } catch (_) {
          await _restoreDesktopPme(player);
          rethrow;
        }
      }
      await _restoreDesktopPme(player);
      final output = await _videoOutputForConfiguration(player);
      final fallback = resolveForPlayer(player, mode, currentVideoOutput: output, isLive: isLive);
      final mpvFallbackEligible =
          !isLive &&
          !isTranscoding &&
          selectedVersion != null &&
          _supportsMotionSource(selectedVersion, allowDynamicRange: true);
      if (mpvFallbackEligible && fallback.usesMpvInterpolation) {
        await _applyMpvInterpolation(player);
        _interpolationBufferReady[player] = true;
        appLogger.i(
          'MotionProcessingService: desktop Neural path is preparing or unavailable; using MPV interpolation.',
        );
      } else {
        final original = _originals[player];
        if (original != null) await _restoreOriginalProperties(player, original);
      }
      return;
    }
    if (_isDesktopPmePlatform) await _restoreDesktopPme(player);

    if (_isDesktopPmePlatform &&
        mode != MotionProcessingMode.off &&
        (isLive || isTranscoding || !_supportsDesktopMpvSource(selectedVersion))) {
      final original = _originals[player];
      if (original != null) await _restoreOriginalProperties(player, original);
      _interpolationBufferReady[player] = false;
      return;
    }

    final currentVideoOutput = await _videoOutputForConfiguration(player);
    final resolution = resolveForPlayer(player, mode, currentVideoOutput: currentVideoOutput, isLive: isLive);
    _interpolationBufferReady[player] = false;

    // A reused player may still have interpolation enabled from the previous
    // VOD item. Live streams have no stable pair/cadence window, so always
    // restore MPV's original timing before opening one.
    if (isLive || !resolution.usesMpvInterpolation) {
      final original = _originals[player];
      if (original != null) await _restoreOriginalProperties(player, original);
      return;
    }

    try {
      await _applyMpvInterpolation(player, alwaysInterpolate: _isDesktopPmePlatform);
      _interpolationBufferReady[player] = true;
      if (resolution.fallback == MotionProcessingFallback.neuralUnavailable) {
        appLogger.i(
          'MotionProcessingService: Neural provider unavailable on this playback path; using MPV interpolation.',
        );
      }
    } catch (_) {
      // Do not record a failed startup configuration as prepared.
      _interpolationBufferReady[player] = false;
      rethrow;
    }
  }

  /// Applies [mode] to the current MPV player. When switching back to Off,
  /// restore the user's original MPV timing properties rather than assuming
  /// MPV's defaults.
  static Future<void> apply(
    Player player,
    MotionProcessingMode mode, {
    NeuralInterpolationPreset neuralPreset = NeuralInterpolationPreset.balanced,
  }) {
    appLogger.i('Motion smoothing requested: mode=${mode.name}, backend=${player.playerType}');
    _advanceAndroidAnvilRequestGeneration(player);
    return _serializePlayerOperation(player, () async {
      await _apply(player, mode, neuralPreset: neuralPreset);
      await _logLiveMotionChange(player, mode);
      final selectedVersion = _sessionSelectedVersion[player];
      if (Platform.isAndroid &&
          player is PlayerNative &&
          _androidAnvilActive[player] == true &&
          _androidAnvilPreset[player] != null &&
          selectedVersion != null) {
        _watchAndroidAnvilProvider(
          player,
          selectedVersion: selectedVersion,
          neuralPreset: _androidAnvilPreset[player]!,
        );
      }
    });
  }

  static Future<void> _apply(
    Player player,
    MotionProcessingMode mode, {
    NeuralInterpolationPreset neuralPreset = NeuralInterpolationPreset.balanced,
  }) async {
    if (!supportsPlayer(player)) throw UnsupportedError('MPV motion interpolation is unavailable on this player.');
    if (player is PlayerSystem && player.playerType == 'tvmpv') {
      await player.setTvMotion(mode != MotionProcessingMode.off, preset: neuralPreset);
      return;
    }
    if (mode != MotionProcessingMode.off && !canChangeLive(player, mode: mode)) {
      throw UnsupportedError('Motion processing is unavailable for the current video track.');
    }

    if (mode.usesNeuralInterpolation) {
      final powerLimited = await _preparePowerPolicy(player, mode);
      final thermalLimited = await _prepareThermalPolicy(player, mode);
      if (powerLimited || thermalLimited) {
        await _configureForPlaybackImpl(
          player,
          _isApplePlatform ? MotionProcessingMode.off : MotionProcessingMode.mpv,
          selectedVersion: _sessionSelectedVersion[player],
        );
        return;
      }
    } else {
      _neuralRequested[player] = false;
      await _stopPowerMonitoring(player);
      await _stopThermalMonitoring(player);
      _powerLimited[player] = false;
      _thermalLimited[player] = false;
      _thermalStatus[player] = null;
      _powerSuspendedForSession[player] = false;
    }

    if (_isApplePlatform) {
      final output = await _videoOutputForConfiguration(player);
      final avfoundationOutput = output == null || output == 'avfoundation';
      final eligible = avfoundationOutput && _appleNeuralEligible[player] == true;
      await configureAppleMotion(player, eligible ? mode : MotionProcessingMode.off, neuralPreset);
      _interpolationBufferReady[player] = avfoundationOutput;
      if (!eligible && mode != MotionProcessingMode.off) {
        throw UnsupportedError('The active Apple output cannot apply this motion mode.');
      }
      if (mode.usesNeuralInterpolation) _watchPlatformThermalStatus(player);
      return;
    }

    final currentVideoOutput = _isDesktopPmePlatform && mode.usesMpvInterpolation
        ? await _videoOutputForConfiguration(player)
        : null;
    if (mode.usesMpvInterpolation &&
        _isDesktopPmePlatform &&
        (currentVideoOutput == null || !_supportsVideoOutput(currentVideoOutput))) {
      throw UnsupportedError('The active video output does not support MPV interpolation.');
    }

    if (mode.usesNeuralInterpolation && _desktopPmeActive[player] == true) {
      if (!await _changeDesktopPmePreset(player, neuralPreset)) {
        throw StateError('The desktop Neural provider could not change presets.');
      }
      return;
    }
    if (mode.usesNeuralInterpolation && _androidAnvilActive[player] == true) {
      if (!await _changeAndroidAnvilPreset(player, neuralPreset)) {
        throw StateError('The Android Neural provider could not change presets.');
      }
      return;
    }
    // The same MPV core owns the demuxer and the audio clock across these
    // changes. Android's surface arbiter acknowledges the new output before
    // the provider is attached. MPV rebuilds video decode for vd-lavc-o/hwdec.
    if (mode.usesNeuralInterpolation || (Platform.isAndroid && mode.usesMpvInterpolation)) {
      await _configureForPlaybackImpl(
        player,
        mode,
        selectedVersion: _sessionSelectedVersion[player],
        neuralPreset: neuralPreset,
      );
      if (_interpolationBufferReady[player] != true) {
        throw UnsupportedError('No motion processor accepted this video.');
      }
      if (_androidAnvilActive[player] == true) _watchPlatformThermalStatus(player);
      return;
    }
    if (_isDesktopPmePlatform) await _restoreDesktopPme(player, requireFilterRemoval: true);
    if (Platform.isAndroid) await _restoreAndroidMotionPath(player, requireRestore: true);
    final resolution = resolveForPlayer(player, mode, currentVideoOutput: currentVideoOutput);
    if (!resolution.usesMpvInterpolation) {
      final original = _originals[player];
      if (original != null) await _restoreOriginalProperties(player, original);
      _interpolationBufferReady[player] = false;
      return;
    }

    await _applyMpvInterpolation(player, alwaysInterpolate: _isDesktopPmePlatform);
    _interpolationBufferReady[player] = true;
    if (resolution.fallback == MotionProcessingFallback.neuralUnavailable) {
      appLogger.i(
        'MotionProcessingService: Neural provider unavailable on this playback path; using MPV interpolation.',
      );
    }
  }

  @visibleForTesting
  static Future<void> configureAppleMotion(
    Player player,
    MotionProcessingMode mode,
    NeuralInterpolationPreset preset,
  ) async {
    var neural = false;
    if (mode.usesNeuralInterpolation) {
      try {
        neural = await player.getProperty('pleazyng-vt-motion-supported') == 'yes';
      } catch (error) {
        appLogger.d('VideoToolbox capability query failed, trying the Apple frame mixer', error: error);
      }
    }
    final useGpu = mode != MotionProcessingMode.off && !neural;
    if (!useGpu) await _setAppleMixer(player, false);
    await _applyAppleInterpolation(player, neural, preset);
    if (useGpu) await _setAppleMixer(player, true);
  }

  /// The AVFoundation VO can present CPU-readable YUV from libplacebo. The
  /// filter uploads to Vulkan (MoltenVK on Apple) and mixes at output cadence.
  static Future<void> _setAppleMixer(Player player, bool enable) async {
    final original = _appleMixerOriginalHwdec[player];
    if (enable == (original != null)) return;
    if (!enable) {
      if (_appleMixer[player] != null) {
        await player.command(['vf', 'remove', '@plezy-apple-motion']);
        _appleMixer[player] = null;
      }
      await player.setProperty('hwdec', original!);
      _appleMixerOriginalHwdec[player] = null;
      return;
    }
    final hwdec = await player.getProperty('hwdec') ?? 'auto';
    try {
      if (hwdec != 'no') await player.setProperty('hwdec', 'videotoolbox-copy');
      var gpuActive = false;
      try {
        if (await player.getProperty('pleazyng-apple-mixer-gpu-supported') == 'yes') {
          await player.command([
            'vf',
            'add',
            '@plezy-apple-motion:lavfi=[libplacebo=fps=60:frame_mixer=oversample:format=yuv420p]',
          ]);
          gpuActive = true;
        }
      } catch (error) {
        appLogger.i('Apple GPU mixer unavailable, trying FFmpeg blending', error: error);
      }
      if (!gpuActive) {
        await player.command(['vf', 'add', '@plezy-apple-motion:lavfi=[minterpolate=fps=60:mi_mode=blend]']);
      }
      _appleMixer[player] = gpuActive ? 'libplacebo GPU' : 'FFmpeg CPU';
      _appleMixerOriginalHwdec[player] = hwdec;
    } catch (_) {
      await player.setProperty('hwdec', hwdec);
      rethrow;
    }
  }

  static String? observedAppleMixer(Player player, double? inputFps, double? outputFps) {
    if (inputFps == null || inputFps <= 0 || inputFps > 30.1 || outputFps == null || (outputFps - 60).abs() > 1) {
      return null;
    }
    return _appleMixer[player];
  }

  static Future<void> _applyAppleInterpolation(Player player, bool enabled, NeuralInterpolationPreset preset) async {
    var original = _appleOriginals[player];
    if (original == null) {
      if (!enabled) return;
      original = _OriginalAppleMotionOptions(
        interpolation: await player.getProperty('avfoundation-motion-interpolation'),
        preset: await player.getProperty('avfoundation-motion-preset'),
        videoSync: await player.getProperty('video-sync'),
      );
      _appleOriginals[player] = original;
    }

    final presetName = switch (preset) {
      NeuralInterpolationPreset.performance => 'performance',
      NeuralInterpolationPreset.balanced => 'balanced',
      NeuralInterpolationPreset.quality => 'quality',
    };
    if (enabled) {
      // Apple frame synthesis follows mpv's display-resample schedule. The VO
      // passes each source frame's refresh-slot count to VideoToolbox, which
      // selects timestamps within the chosen preset's synthesis budget.
      await player.setProperty('video-sync', 'display-resample');
      await player.setProperty('avfoundation-motion-preset', presetName);
      await player.setProperty('avfoundation-motion-interpolation', 'yes');
      _appleNeuralPreset[player] = preset;
    } else {
      await player.setProperty('avfoundation-motion-interpolation', original.interpolation ?? 'no');
      await player.setProperty('avfoundation-motion-preset', original.preset ?? 'balanced');
      await player.setProperty('video-sync', original.videoSync ?? 'audio');
      _appleNeuralPreset[player] = null;
      _appleOriginals[player] = null;
    }
  }

  static Future<bool> _preparePowerPolicy(Player player, MotionProcessingMode requested) async {
    final settings = SettingsService.instanceOrNull;
    final limitToExternalPower = settings?.read(SettingsService.neuralOnlyWhenPluggedIn) ?? true;
    if (requested != MotionProcessingMode.neural || !limitToExternalPower) {
      _neuralRequested[player] = false;
      _powerLimited[player] = false;
      _powerSuspendedForSession[player] = false;
      await _stopPowerMonitoring(player);
      return false;
    }

    _neuralRequested[player] = true;
    final generation = _powerSourceGeneration[player] ?? 0;
    // Subscribe before sampling the current state so a battery transition
    // during provider/model setup cannot fall into the gap between the read
    // and listener registration. Keep any event delivered while the read is
    // in flight; the battery plugin may resolve its snapshot after that event.
    _watchPowerSource(player);
    final externalPower = await PowerSourceService.isConnected();
    if ((_powerSourceGeneration[player] ?? 0) == generation) {
      _powerLimited[player] = externalPower == false;
    }
    return _powerLimited[player] == true;
  }

  static Future<bool> _prepareThermalPolicy(Player player, MotionProcessingMode requested) async {
    if ((!Platform.isAndroid && !_isApplePlatform) ||
        requested != MotionProcessingMode.neural ||
        player is! PlayerNative) {
      _thermalLimited[player] = false;
      _thermalStatus[player] = null;
      await _stopThermalMonitoring(player);
      return false;
    }

    try {
      final status = await player.getMotionProcessingThermalStatus();
      _thermalStatus[player] = status;
      final limited = _thermalStatusRequiresFallback(status);
      _thermalLimited[player] = limited;
      if (limited) await _stopThermalMonitoring(player);
      return limited;
    } catch (error, stackTrace) {
      // Missing thermal reporting is unknown, not a reason to disable Neural.
      appLogger.d(
        'MotionProcessingService: platform thermal status is unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      _thermalStatus[player] = null;
      _thermalLimited[player] = false;
      return false;
    }
  }

  static bool _thermalStatusRequiresFallback(String? status) =>
      const {'moderate', 'severe', 'critical', 'emergency', 'shutdown'}.contains(status);

  static void _watchPlatformThermalStatus(Player player) {
    if ((!Platform.isAndroid && !_isApplePlatform) || player is! PlayerNative || _thermalTimers[player] != null) return;
    final generation = (_thermalGeneration[player] ?? 0) + 1;
    _thermalGeneration[player] = generation;

    Future<void> poll() async {
      if (_thermalPollInFlight[player] == true || player.disposed) return;
      _thermalPollInFlight[player] = true;
      try {
        final status = await player.getMotionProcessingThermalStatus();
        if (player.disposed || _thermalGeneration[player] != generation) return;
        if (status == null) {
          _thermalStatus[player] = null;
          _thermalLimited[player] = false;
          // API levels or devices without thermal reporting stay eligible and
          // should not pay for an unsupported poll every five seconds.
          await _stopThermalMonitoring(player);
          return;
        }
        _thermalStatus[player] = status;
        if (_isApplePlatform &&
            !_thermalStatusRequiresFallback(status) &&
            _appleFileLoaded[player] == true &&
            _appleNeuralPreset[player] != null &&
            player.state.playing) {
          final session = _motionSessionGeneration[player];
          await _serializePlayerOperation(player, () async {
            if (player.disposed ||
                _thermalGeneration[player] != generation ||
                _motionSessionGeneration[player] != session ||
                _appleNeuralPreset[player] == null ||
                _powerLimited[player] == true ||
                _interlacedTrackSuppressed[player] == true) {
              return;
            }
            if (await player.getProperty('video-out-interpolation') != 'unavailable') return;
            // VideoToolbox can advertise a processor but reject this frame size or format.
            // Require observed SDR before routing decoded pixels through an 8-bit mix.
            final transfer = await player.getProperty('video-params/gamma');
            if (!const {'bt.1886', 'srgb', 'gamma2.2', 'gamma2.4'}.contains(transfer)) return;
            await _applyAppleInterpolation(player, false, NeuralInterpolationPreset.performance);
            await _setAppleMixer(player, true);
          });
        }
        if (Platform.isAndroid && _androidAnvilActive[player] != true) {
          await _stopThermalMonitoring(player);
          return;
        }
        if (_thermalStatusRequiresFallback(status)) {
          final providerActive = Platform.isAndroid
              ? _androidAnvilActive[player] == true
              : _appleNeuralEligible[player] == true;
          if (!providerActive) {
            await _stopThermalMonitoring(player);
            return;
          }
          _thermalLimited[player] = true;
          await _serializePlayerOperation(player, () async {
            if (player.disposed || _thermalGeneration[player] != generation) return;
            final currentStatus = _thermalStatus[player];
            final currentProviderActive = Platform.isAndroid
                ? _androidAnvilActive[player] == true
                : _appleNeuralEligible[player] == true;
            if (!_thermalStatusRequiresFallback(currentStatus) || !currentProviderActive) return;
            if (await _suspendNeuralForThermal(player, currentStatus!)) {
              if (_thermalGeneration[player] == generation) await _stopThermalMonitoring(player);
            } else if (_thermalGeneration[player] == generation) {
              // Keep observing and retry while the provider remains active.
              // Report the limit only after the active provider has stopped.
              _thermalLimited[player] = false;
            }
          });
        }
      } catch (error, stackTrace) {
        appLogger.d('MotionProcessingService: platform thermal polling failed', error: error, stackTrace: stackTrace);
      } finally {
        if (_thermalGeneration[player] == generation) _thermalPollInFlight[player] = false;
      }
    }

    unawaited(poll());
    _thermalTimers[player] = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(poll()));
  }

  static Future<void> _stopThermalMonitoring(Player player) async {
    _thermalGeneration[player] = (_thermalGeneration[player] ?? 0) + 1;
    _thermalTimers[player]?.cancel();
    _thermalTimers[player] = null;
    _thermalPollInFlight[player] = false;
  }

  static Future<bool> _suspendNeuralForThermal(Player player, String status) async {
    if ((!Platform.isAndroid && !_isApplePlatform) || !supportsPlayer(player)) return false;
    try {
      var fallbackReady = true;
      if (_isApplePlatform) {
        await _setAppleMixer(player, false);
        await player.setProperty('avfoundation-motion-interpolation', 'no');
      } else {
        if (_androidAnvilActive[player] == true) {
          if (!await _removeAndroidAnvilFilter(player)) return false;
          _androidAnvilActive[player] = false;
        }
        try {
          await _applyMpvInterpolation(player);
        } catch (error, stackTrace) {
          fallbackReady = false;
          appLogger.w(
            'MotionProcessingService: MPV smoothing could not resume after thermal backoff',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      _thermalLimited[player] = true;
      _interpolationBufferReady[player] = fallbackReady;
      appLogger.i(
        _isApplePlatform
            ? 'MotionProcessingService: VideoToolbox interpolation paused at Apple thermal status $status.'
            : fallbackReady
            ? 'MotionProcessingService: Neural processing paused at Android thermal status $status; MPV smoothing remains available.'
            : 'MotionProcessingService: Neural processing paused at Android thermal status $status; playback continues without MPV smoothing.',
      );
      return true;
    } catch (error, stackTrace) {
      appLogger.w(
        'MotionProcessingService: could not pause Neural processing during thermal backoff',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  static void _watchPowerSource(Player player) {
    if (_powerSubscriptions[player] != null) return;
    try {
      _powerSubscriptions[player] = PowerSourceService.changes.listen(
        (externalPower) {
          if (externalPower == null || _neuralRequested[player] != true) return;
          _powerSourceGeneration[player] = (_powerSourceGeneration[player] ?? 0) + 1;
          final generation = _powerSourceGeneration[player]!;
          if (externalPower) {
            // Reconnection does not hot-start a model that was already
            // suspended, but it clears a stale limit during initial setup.
            if (_powerSuspendedForSession[player] != true) _powerLimited[player] = false;
            return;
          }
          final settings = SettingsService.instanceOrNull;
          if (settings?.read(SettingsService.neuralOnlyWhenPluggedIn) != true) return;
          _powerLimited[player] = true;
          _powerSuspendedForSession[player] = true;
          unawaited(
            _serializePlayerOperation(player, () async {
              if (player.disposed ||
                  _powerSourceGeneration[player] != generation ||
                  _neuralRequested[player] != true ||
                  (SettingsService.instanceOrNull?.read(SettingsService.neuralOnlyWhenPluggedIn) ?? true) != true) {
                return;
              }
              final disabled = await _suspendNeuralForPower(player);
              if (!disabled && _powerSourceGeneration[player] == generation) _powerLimited[player] = false;
            }),
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          appLogger.d('MotionProcessingService: power-source updates are unavailable', error: error);
        },
      );
    } on Object catch (error) {
      // A platform that has no battery plugin reports unknown power status;
      // it remains eligible and keeps the regular playback path.
      appLogger.d('MotionProcessingService: power-source monitoring is unavailable', error: error);
    }
  }

  static Future<void> _stopPowerMonitoring(Player player) async {
    final subscription = _powerSubscriptions[player];
    _powerSubscriptions[player] = null;
    await subscription?.cancel();
  }

  /// Stop Neural output promptly when a battery-backed device is unplugged.
  /// The already-selected MPV path remains available; model inference resumes
  /// at the next item boundary after external power is restored.
  static Future<bool> _suspendNeuralForPower(Player player) async {
    if (!supportsPlayer(player)) return false;
    _powerSuspendedForSession[player] = true;
    try {
      if (_isApplePlatform) {
        await _setAppleMixer(player, false);
        await player.setProperty('avfoundation-motion-interpolation', 'no');
      } else if (_isDesktopPmePlatform && _desktopPmeActive[player] == true) {
        if (!await _removeDesktopPmeFilter(player)) return false;
        _desktopPmeActive[player] = false;
        try {
          await _applyMpvInterpolation(player);
        } catch (error, stackTrace) {
          appLogger.w(
            'MotionProcessingService: MPV smoothing could not resume after Neural paused',
            error: error,
            stackTrace: stackTrace,
          );
        }
      } else if (Platform.isAndroid && _androidAnvilActive[player] == true) {
        if (!await _removeAndroidAnvilFilter(player)) return false;
        _androidAnvilActive[player] = false;
        try {
          await _applyMpvInterpolation(player);
        } catch (error, stackTrace) {
          appLogger.w(
            'MotionProcessingService: MPV smoothing could not resume after Neural paused',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      await _stopThermalMonitoring(player);
      _interpolationBufferReady[player] = true;
      appLogger.i(
        _isApplePlatform
            ? 'MotionProcessingService: Neural processing paused on battery.'
            : 'MotionProcessingService: Neural processing paused on battery; MPV smoothing remains available.',
      );
      return true;
    } catch (error, stackTrace) {
      appLogger.w(
        'MotionProcessingService: could not pause Neural processing on battery',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Releases the per-player power observer when its video route is disposed.
  static Future<void> stopPowerSourceMonitoring(Player player) async {
    await _serializePlayerOperation(player, () => _stopPowerSourceMonitoring(player));
  }

  static Future<void> _stopPowerSourceMonitoring(Player player) async {
    _videoTrackMonitorGeneration[player] = (_videoTrackMonitorGeneration[player] ?? 0) + 1;
    _motionSessionGeneration[player] = (_motionSessionGeneration[player] ?? 0) + 1;
    final appleLoadSubscription = _appleLoadSubscriptions[player];
    _appleLoadSubscriptions[player] = null;
    await appleLoadSubscription?.cancel();
    final trackSubscription = _videoTrackSubscriptions[player];
    _videoTrackSubscriptions[player] = null;
    await trackSubscription?.cancel();
    _lastVideoTrackSelection[player] = null;
    _neuralRequested[player] = false;
    await _stopPowerMonitoring(player);
    await _stopThermalMonitoring(player);
    _thermalStatus[player] = null;
  }

  static Future<bool> _configureDesktopPme(
    Player player, {
    required MediaVersion? selectedVersion,
    required NeuralInterpolationPreset neuralPreset,
    required bool isLive,
    required bool isTranscoding,
  }) async {
    if (!_isDesktopPmePlatform || player.playerType != 'mpv' || isLive || isTranscoding || selectedVersion == null) {
      return false;
    }
    if (!_supportsDesktopPmeSource(selectedVersion)) return false;

    final runtime = await _findDesktopPmeRuntime();
    if (runtime == null) {
      appLogger.w('MotionProcessingService: desktop PME runtime bundle is not installed.');
      return false;
    }

    late final File model;
    try {
      model = await NeuralModelPackService.ensureInstalled(neuralPreset);
    } catch (error, stackTrace) {
      appLogger.w(
        'MotionProcessingService: bundled Neural model is unavailable; playback remains on MPV smoothing.',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }

    try {
      var original = _desktopPmeOriginals[player];
      if (original == null) {
        original = _OriginalDesktopPmeOptions(
          hwdec: await player.getProperty('hwdec'),
          decoderOptions: await player.getProperty('vd-lavc-o'),
        );
        _desktopPmeOriginals[player] = original;
      }
      if (_desktopPmeActive[player] == true) {
        if (!await _removeDesktopPmeFilter(player)) return false;
        _desktopPmeActive[player] = false;
        _desktopPmePreset[player] = null;
      }

      // The filter requires FFmpeg motion-vector side data and CPU-readable
      // YUV420P frames. auto-copy may retain a hardware decoder that does not
      // export those vectors, so this route deliberately selects software
      // decode for the Neural session. Set the codec flags before changing
      // hwdec because MPV can reopen the decoder during that write.
      await player.setProperty('vd-lavc-o', _withExportMotionVectors(original.decoderOptions ?? ''));
      await player.setProperty('hwdec', 'no');
      final filterOptions = <String, String>{
        'model': model.path,
        'runtime': runtime.ortLibrary,
        'providers': runtime.providerManifest,
        'pme-library': runtime.pmeLibrary,
        'preset': neuralPreset.name,
        'allow-cpu': 'yes',
        'require-neural': 'yes',
      }.entries.map((entry) => '${entry.key}=${_escapeMpvFilterValue(entry.value)}').join(':');
      await player.command(['vf', 'add', '@plezy-pme:plezy-pme=$filterOptions']);
      _desktopPmeActive[player] = true;
      _desktopPmePreset[player] = neuralPreset;
      _configuredNeuralModelId[player] = NeuralModelPackService.modelIdForPreset(neuralPreset);
      return true;
    } catch (error, stackTrace) {
      appLogger.w(
        'MotionProcessingService: desktop PME filter could not be attached',
        error: error,
        stackTrace: stackTrace,
      );
      await _restoreDesktopPme(player);
      return false;
    }
  }

  static Future<bool> _changeDesktopPmePreset(Player player, NeuralInterpolationPreset neuralPreset) async {
    final previousPreset = _desktopPmePreset[player];
    final selectedVersion = _sessionSelectedVersion[player];
    if (_desktopPmeActive[player] != true || previousPreset == null || selectedVersion == null) return false;
    if (previousPreset == neuralPreset) return true;

    final configured = await _configureDesktopPme(
      player,
      selectedVersion: selectedVersion,
      neuralPreset: neuralPreset,
      isLive: _sessionIsLive[player] ?? false,
      isTranscoding: _sessionIsTranscoding[player] ?? false,
    );
    if (configured) return true;

    // Model/runtime preparation failures happen before removing the current
    // filter. If setup failed after removal, recreate the previous preset in
    // the same player session so A/B selection never reloads the media.
    if (_desktopPmeActive[player] != true || _desktopPmePreset[player] != previousPreset) {
      final restored = await _configureDesktopPme(
        player,
        selectedVersion: selectedVersion,
        neuralPreset: previousPreset,
        isLive: _sessionIsLive[player] ?? false,
        isTranscoding: _sessionIsTranscoding[player] ?? false,
      );
      if (!restored) {
        try {
          await _applyMpvInterpolation(player);
          _interpolationBufferReady[player] = true;
        } catch (error, stackTrace) {
          _interpolationBufferReady[player] = false;
          appLogger.w(
            'MotionProcessingService: MPV smoothing could not resume after a failed desktop preset change',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    }
    return false;
  }

  static bool _supportsDesktopPmeSource(MediaVersion version) {
    final supportedSourceShape =
        (version.width == 1280 && version.height == 720) || (version.width == 1920 && version.height == 1080);
    if (!supportedSourceShape) return false;
    final streams = version.parts
        .expand((part) => part.streams)
        .where((stream) => stream.kind == MediaStreamKind.video)
        .toList(growable: false);
    final video = streams.firstWhere(
      (stream) => stream.selected,
      orElse: () => streams.length == 1 ? streams.single : const MediaStream(id: '', kind: MediaStreamKind.unknown),
    );
    if (video.kind != MediaStreamKind.video || video.interlaced != false || video.hdr || video.dolbyVision) {
      return false;
    }
    final codec = (video.codec ?? version.videoCodec ?? '').toLowerCase();
    if (!const {'h264', 'avc', 'avc1'}.contains(codec)) return false;
    final fps = video.frameRate;
    return fps != null && ((fps - 24).abs() <= 0.1 || (fps - 30).abs() <= 0.1);
  }

  static Future<_DesktopPmeRuntime?> _findDesktopPmeRuntime() async {
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

  static String _escapeMpvFilterValue(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll(':', '\\:').replaceAll(',', '\\,');

  static Future<bool> _removeDesktopPmeFilter(Player player) async {
    try {
      await player.command(['vf', 'remove', '@plezy-pme']);
      _configuredNeuralModelId[player] = null;
      return true;
    } catch (error) {
      appLogger.d('MotionProcessingService: desktop PME filter was not active', error: error);
      return false;
    }
  }

  static Future<void> _restoreDesktopPme(Player player, {bool requireFilterRemoval = false}) async {
    _configuredNeuralModelId[player] = null;
    final original = _desktopPmeOriginals[player];
    if (original == null) return;
    if (_desktopPmeActive[player] == true && !await _removeDesktopPmeFilter(player) && requireFilterRemoval) {
      throw StateError('The desktop Neural filter could not be removed.');
    }
    for (final (property, value) in <(String, String?)>[
      ('vd-lavc-o', original.decoderOptions),
      ('hwdec', original.hwdec),
    ]) {
      if (value == null) continue;
      try {
        await player.setProperty(property, value);
      } catch (error, stackTrace) {
        appLogger.w(
          'MotionProcessingService: desktop PME option $property could not be restored',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    _desktopPmeActive[player] = false;
    _desktopPmePreset[player] = null;
    _desktopPmeOriginals[player] = null;
  }

  static MediaStream? _selectedMotionVideo(MediaVersion? version) {
    if (version == null) return null;
    final streams = version.parts
        .expand((part) => part.streams)
        .where((stream) => stream.kind == MediaStreamKind.video);
    return streams.where((stream) => stream.selected).firstOrNull ?? (streams.length == 1 ? streams.single : null);
  }

  // Desktop temporal blending uses the existing GPU output. It does not need
  // a provider-specific metadata match when the server omits track details.
  static bool _supportsDesktopMpvSource(MediaVersion? version) {
    final width = version?.width;
    final height = version?.height;
    if ((width != null && width > 1920) || (height != null && height > 1920)) return false;
    if (width != null && height != null && width * height > 1920 * 1080) return false;
    final video = _selectedMotionVideo(version);
    if (video?.interlaced == true) return false;
    final fps = video?.frameRate;
    return fps == null || (fps - 24).abs() <= 0.1 || (fps - 30).abs() <= 0.1;
  }

  static bool _supportsMotionSource(MediaVersion version, {bool allowDynamicRange = false}) {
    final width = version.width;
    final height = version.height;
    if (width == null || height == null || width < 1 || height < 1 || width > 1920 || height > 1920) return false;
    if (width * height > 1920 * 1080) return false;
    final video = _selectedMotionVideo(version);
    if (video == null || video.interlaced != false || (!allowDynamicRange && (video.hdr || video.dolbyVision))) {
      return false;
    }
    final fps = video.frameRate;
    return fps != null && ((fps - 24).abs() <= 0.1 || (fps - 30).abs() <= 0.1);
  }

  static Future<bool> _configureAndroidMpvRenderer(
    Player player, {
    required MediaVersion? selectedVersion,
    required bool isLive,
    required bool isTranscoding,
  }) async {
    if (isLive || isTranscoding || selectedVersion == null || !_supportsMotionSource(selectedVersion)) {
      return false;
    }

    if (player is! PlayerNative) return false;
    // Preserve the user's decoder choice while asking the native output policy
    // to select a GPU path and, on hardware sessions, transfer surface ownership.
    try {
      final installed = await player.setAndroidMotionProcessingRenderer('gpu');
      if (installed) {
        _androidMpvOutputActive[player] = true;
        return true;
      }
    } catch (error, stackTrace) {
      appLogger.w(
        'MotionProcessingService: Android GPU output could not be enabled for MPV smoothing.',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await _restoreAndroidMotionPath(player);
    return false;
  }

  static Future<bool> _configureAndroidAnvil(
    Player player, {
    required MediaVersion? selectedVersion,
    required NeuralInterpolationPreset neuralPreset,
    required bool isLive,
    required bool isTranscoding,
  }) async {
    if (player is! PlayerNative || isLive || isTranscoding || selectedVersion == null) {
      return false;
    }

    try {
      final capabilities = await player.getAndroidMotionRuntimeCapabilities();
      if (capabilities == null) return false;
      if (capabilities['qnnHtpAvailable'] == true) {
        try {
          if (await _configureAndroidAnvilQnn(
            player,
            capabilities: capabilities,
            selectedVersion: selectedVersion,
            neuralPreset: neuralPreset,
          )) {
            return true;
          }
        } catch (error, stackTrace) {
          appLogger.w(
            'MotionProcessingService: Qualcomm HTP setup failed; trying LiteRT providers',
            error: error,
            stackTrace: stackTrace,
          );
          await _restoreAndroidMotionPath(player);
        }
      }
      return await _configureAndroidAnvilLiteRt(
        player,
        capabilities: capabilities,
        selectedVersion: selectedVersion,
        neuralPreset: neuralPreset,
      );
    } catch (error, stackTrace) {
      appLogger.w(
        'MotionProcessingService: Android neural provider setup failed',
        error: error,
        stackTrace: stackTrace,
      );
      await _restoreAndroidMotionPath(player);
      return false;
    }
  }

  static int _advanceAndroidAnvilRequestGeneration(Player player) {
    final generation = (_androidAnvilRequestGeneration[player] ?? 0) + 1;
    _androidAnvilRequestGeneration[player] = generation;
    return generation;
  }

  static void _invalidateAndroidAnvilProviderWatch(Player player) {
    _androidAnvilProviderGeneration[player] = (_androidAnvilProviderGeneration[player] ?? 0) + 1;
    _androidAnvilBackend[player] = null;
  }

  static void _markAndroidAnvilProviderAttached(Player player, _AndroidAnvilBackend backend) {
    _androidAnvilProviderGeneration[player] = (_androidAnvilProviderGeneration[player] ?? 0) + 1;
    _androidAnvilBackend[player] = backend;
  }

  static bool _androidAnvilWatchIsCurrent(
    PlayerNative player, {
    required int providerGeneration,
    required int sessionGeneration,
    required int requestGeneration,
    required _AndroidAnvilBackend backend,
  }) =>
      !player.disposed &&
      _androidAnvilProviderGeneration[player] == providerGeneration &&
      _androidAnvilBackend[player] == backend &&
      _androidAnvilActive[player] == true &&
      _motionSessionGeneration[player] == sessionGeneration &&
      _androidAnvilRequestGeneration[player] == requestGeneration;

  static bool _androidAnvilRequestIsCurrent(
    PlayerNative player, {
    required int sessionGeneration,
    required int requestGeneration,
  }) =>
      !player.disposed &&
      _motionSessionGeneration[player] == sessionGeneration &&
      _androidAnvilRequestGeneration[player] == requestGeneration;

  static void _watchAndroidAnvilProvider(
    PlayerNative player, {
    required MediaVersion selectedVersion,
    required NeuralInterpolationPreset neuralPreset,
  }) {
    final providerGeneration = _androidAnvilProviderGeneration[player];
    final backend = _androidAnvilBackend[player];
    if (providerGeneration == null || backend == null || _androidAnvilActive[player] != true) return;
    final sessionGeneration = _motionSessionGeneration[player] ?? 0;
    final requestGeneration = _androidAnvilRequestGeneration[player] ?? 0;
    unawaited(
      _monitorAndroidAnvilProvider(
        player,
        providerGeneration: providerGeneration,
        sessionGeneration: sessionGeneration,
        requestGeneration: requestGeneration,
        backend: backend,
        selectedVersion: selectedVersion,
        neuralPreset: neuralPreset,
      ),
    );
  }

  static Future<void> _monitorAndroidAnvilProvider(
    PlayerNative player, {
    required int providerGeneration,
    required int sessionGeneration,
    required int requestGeneration,
    required _AndroidAnvilBackend backend,
    required MediaVersion selectedVersion,
    required NeuralInterpolationPreset neuralPreset,
  }) async {
    final monitor = AndroidAnvilProviderMonitor();
    final elapsed = Stopwatch()..start();
    var previousSample = Duration.zero;

    while (_androidAnvilWatchIsCurrent(
      player,
      providerGeneration: providerGeneration,
      sessionGeneration: sessionGeneration,
      requestGeneration: requestGeneration,
      backend: backend,
    )) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!_androidAnvilWatchIsCurrent(
        player,
        providerGeneration: providerGeneration,
        sessionGeneration: sessionGeneration,
        requestGeneration: requestGeneration,
        backend: backend,
      )) {
        return;
      }

      final currentSample = elapsed.elapsed;
      final activeDelta = currentSample - previousSample;
      previousSample = currentSample;
      final observation = await _readAndroidAnvilProviderObservation(player);
      if (!_androidAnvilWatchIsCurrent(
        player,
        providerGeneration: providerGeneration,
        sessionGeneration: sessionGeneration,
        requestGeneration: requestGeneration,
        backend: backend,
      )) {
        return;
      }

      final action = monitor.observe(observation, activeDelta: activeDelta);
      if (action == AndroidAnvilMonitorAction.pending) continue;

      try {
        await _serializePlayerOperation(player, () async {
          if (!_androidAnvilWatchIsCurrent(
            player,
            providerGeneration: providerGeneration,
            sessionGeneration: sessionGeneration,
            requestGeneration: requestGeneration,
            backend: backend,
          )) {
            return;
          }
          await _recoverAndroidAnvilProvider(
            player,
            backend: backend,
            action: action,
            selectedVersion: selectedVersion,
            neuralPreset: neuralPreset,
            sessionGeneration: sessionGeneration,
            requestGeneration: requestGeneration,
          );
        });
      } catch (error, stackTrace) {
        appLogger.w('MotionProcessingService: Android neural fallback failed', error: error, stackTrace: stackTrace);
      }
      return;
    }
  }

  static Future<AndroidAnvilProviderObservation> _readAndroidAnvilProviderObservation(PlayerNative player) async {
    Future<String?> read(String property) async {
      try {
        return await player.getProperty(property);
      } catch (_) {
        // Missing metadata stays unknown and must not start the output timeout.
        return null;
      }
    }

    final values = await Future.wait<String?>([
      read('vf-metadata/plezy-anvil/provider'),
      read('vf-metadata/plezy-anvil/source-frames'),
      read('vf-metadata/plezy-anvil/generated-frames'),
      read('vf-metadata/plezy-anvil/scene-cut-bypasses'),
      read('pause'),
      read('paused-for-cache'),
    ]);
    return AndroidAnvilProviderObservation(
      provider: values[0],
      sourceFrames: int.tryParse(values[1] ?? ''),
      generatedFrames: int.tryParse(values[2] ?? ''),
      sceneCutBypasses: int.tryParse(values[3] ?? ''),
      isPaused: _androidAnvilBoolean(values[4]),
      isPausedForCache: _androidAnvilBoolean(values[5]),
    );
  }

  static bool? _androidAnvilBoolean(String? value) => switch (value?.trim().toLowerCase()) {
    'yes' || 'true' || '1' => true,
    'no' || 'false' || '0' => false,
    _ => null,
  };

  static Future<void> _recoverAndroidAnvilProvider(
    PlayerNative player, {
    required _AndroidAnvilBackend backend,
    required AndroidAnvilMonitorAction action,
    required MediaVersion selectedVersion,
    required NeuralInterpolationPreset neuralPreset,
    required int sessionGeneration,
    required int requestGeneration,
  }) async {
    if (!_androidAnvilRequestIsCurrent(
      player,
      sessionGeneration: sessionGeneration,
      requestGeneration: requestGeneration,
    )) {
      return;
    }

    appLogger.w(
      action == AndroidAnvilMonitorAction.noOutputTimeout
          ? 'MotionProcessingService: Android ANVIL had source-frame progress without generated or scene-cut frames; starting provider fallback.'
          : 'MotionProcessingService: Android ANVIL provider reported a terminal failure; starting provider fallback.',
    );
    await _restoreAndroidMotionPath(player);
    if (!_androidAnvilRequestIsCurrent(
      player,
      sessionGeneration: sessionGeneration,
      requestGeneration: requestGeneration,
    )) {
      return;
    }

    if (backend == _AndroidAnvilBackend.qnn) {
      Map<Object?, Object?>? capabilities;
      try {
        capabilities = await player.getAndroidMotionRuntimeCapabilities();
      } catch (error, stackTrace) {
        appLogger.w(
          'MotionProcessingService: fresh Android capabilities could not be read for LiteRT recovery',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!_androidAnvilRequestIsCurrent(
        player,
        sessionGeneration: sessionGeneration,
        requestGeneration: requestGeneration,
      )) {
        return;
      }
      if (capabilities != null) {
        try {
          if (await _configureAndroidAnvilLiteRt(
            player,
            capabilities: capabilities,
            selectedVersion: selectedVersion,
            neuralPreset: neuralPreset,
          )) {
            if (!_androidAnvilRequestIsCurrent(
              player,
              sessionGeneration: sessionGeneration,
              requestGeneration: requestGeneration,
            )) {
              return;
            }
            await _applyMpvInterpolation(player);
            if (!_androidAnvilRequestIsCurrent(
              player,
              sessionGeneration: sessionGeneration,
              requestGeneration: requestGeneration,
            )) {
              return;
            }
            _interpolationBufferReady[player] = true;
            _watchAndroidAnvilProvider(player, selectedVersion: selectedVersion, neuralPreset: neuralPreset);
            appLogger.i('MotionProcessingService: Qualcomm HTP failed asynchronously; LiteRT is being tried.');
            return;
          }
        } catch (error, stackTrace) {
          appLogger.w(
            'MotionProcessingService: LiteRT fallback after Qualcomm HTP failure could not be configured',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    }

    if (!_androidAnvilRequestIsCurrent(
      player,
      sessionGeneration: sessionGeneration,
      requestGeneration: requestGeneration,
    )) {
      return;
    }
    await _restoreAndroidMotionPath(player);
    final original = _originals[player];
    if (original != null) await _restoreOriginalProperties(player, original);
    if (!_androidAnvilRequestIsCurrent(
      player,
      sessionGeneration: sessionGeneration,
      requestGeneration: requestGeneration,
    )) {
      return;
    }
    try {
      if (await _configureAndroidMpvRenderer(
        player,
        selectedVersion: selectedVersion,
        isLive: false,
        isTranscoding: false,
      )) {
        await _applyMpvInterpolation(player);
        if (!_androidAnvilRequestIsCurrent(
          player,
          sessionGeneration: sessionGeneration,
          requestGeneration: requestGeneration,
        )) {
          return;
        }
        _interpolationBufferReady[player] = true;
        appLogger.i('MotionProcessingService: Android Neural provider failed; using MPV smoothing.');
        return;
      }
    } catch (error, stackTrace) {
      appLogger.w(
        'MotionProcessingService: Android MPV smoothing fallback could not be applied',
        error: error,
        stackTrace: stackTrace,
      );
      await _restoreAndroidMotionPath(player);
      if (original != null) await _restoreOriginalProperties(player, original);
    }
    if (_androidAnvilRequestIsCurrent(
      player,
      sessionGeneration: sessionGeneration,
      requestGeneration: requestGeneration,
    )) {
      _interpolationBufferReady[player] = false;
    }
  }

  static Future<bool> _changeAndroidAnvilPreset(Player player, NeuralInterpolationPreset neuralPreset) async {
    final previousPreset = _androidAnvilPreset[player];
    final selectedVersion = _sessionSelectedVersion[player];
    if (_androidAnvilActive[player] != true || previousPreset == null || selectedVersion == null) return false;
    if (previousPreset == neuralPreset) return true;

    final configured = await _configureAndroidAnvil(
      player,
      selectedVersion: selectedVersion,
      neuralPreset: neuralPreset,
      isLive: _sessionIsLive[player] ?? false,
      isTranscoding: _sessionIsTranscoding[player] ?? false,
    );
    if (configured) {
      try {
        await _applyMpvInterpolation(player);
        _interpolationBufferReady[player] = true;
        return true;
      } catch (error, stackTrace) {
        appLogger.w(
          'MotionProcessingService: Android MPV timing could not be restored after Neural preset replacement',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // Runtime/model preparation normally happens before touching the active
    // provider. If a later setup step removed it, rebuild the previous model
    // in place before giving up on Neural processing for this open file.
    if (_androidAnvilActive[player] != true || _androidAnvilPreset[player] != previousPreset) {
      final restored = await _configureAndroidAnvil(
        player,
        selectedVersion: selectedVersion,
        neuralPreset: previousPreset,
        isLive: _sessionIsLive[player] ?? false,
        isTranscoding: _sessionIsTranscoding[player] ?? false,
      );
      if (restored) {
        try {
          await _applyMpvInterpolation(player);
          _interpolationBufferReady[player] = true;
          return false;
        } catch (error, stackTrace) {
          appLogger.w(
            'MotionProcessingService: Android MPV timing could not be restored with the previous Neural preset',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }

      await _restoreAndroidMotionPath(player);
      final fallbackRenderer = await _configureAndroidMpvRenderer(
        player,
        selectedVersion: selectedVersion,
        isLive: _sessionIsLive[player] ?? false,
        isTranscoding: _sessionIsTranscoding[player] ?? false,
      );
      if (fallbackRenderer) {
        try {
          await _applyMpvInterpolation(player);
          _interpolationBufferReady[player] = true;
        } catch (error, stackTrace) {
          _interpolationBufferReady[player] = false;
          appLogger.w(
            'MotionProcessingService: Android MPV smoothing could not resume after a failed Neural preset change',
            error: error,
            stackTrace: stackTrace,
          );
        }
      } else {
        _interpolationBufferReady[player] = false;
      }
    }
    return false;
  }

  static Future<bool> _configureAndroidAnvilQnn(
    PlayerNative player, {
    required Map<Object?, Object?> capabilities,
    required MediaVersion selectedVersion,
    required NeuralInterpolationPreset neuralPreset,
  }) async {
    final architecture = capabilities['qnnHtpArchitecture'] as String?;
    final resolution = capabilities['qnnHtpResolution'] as String?;
    if (architecture == null || resolution == null || !_supportsAndroidAnvilSource(selectedVersion, resolution)) {
      return false;
    }

    final modelId = NeuralModelPackService.androidContextModelId(resolution, neuralPreset);
    final packagedContextIds = capabilities['anvilContextIds'];
    final packagedContext = packagedContextIds is List && packagedContextIds.contains(modelId);
    final publishedV75Context = architecture == 'v75' && modelId == 'anvil-s-1080p';
    if (!publishedV75Context && !packagedContext) return false;

    final context = packagedContext
        ? null
        : await NeuralModelPackService.installedOrStartAndroidHtpContext(architecture, modelId);
    if (publishedV75Context && !packagedContext && context == null) {
      appLogger.i(
        'MotionProcessingService: verified V75 ANVIL context is downloading; checking the LiteRT provider for this open.',
      );
      return false;
    }
    final qnnDirectory = await player.prepareAndroidAnvilRuntime(contextPath: context?.path, modelId: modelId);
    if (qnnDirectory == null || qnnDirectory.isEmpty) return false;

    final original = await _captureAndroidMotionOptions(player);
    if (_androidAnvilActive[player] == true) {
      if (!await _removeAndroidAnvilFilter(player)) return false;
      _androidAnvilActive[player] = false;
      _androidAnvilPreset[player] = null;
    }

    await player.setProperty('vd-lavc-o', _withExportMotionVectors(original.decoderOptions ?? ''));
    await player.setProperty('hwdec', 'no');
    final rendererInstalled = await player.setAndroidMotionProcessingRenderer('gpu-next');
    if (!rendererInstalled) {
      await _restoreAndroidMotionPath(player);
      return false;
    }

    final htpPerformance = switch (neuralPreset) {
      NeuralInterpolationPreset.performance => 'burst',
      NeuralInterpolationPreset.balanced => 'sustained',
      NeuralInterpolationPreset.quality => 'sustained',
    };
    try {
      await player.command([
        'vf',
        'add',
        '@plezy-anvil:anvil=qnn-dir=$qnnDirectory:qnn-perf=$htpPerformance:require-qnn=yes',
      ]);
      _androidAnvilActive[player] = true;
      _androidAnvilPreset[player] = neuralPreset;
      _markAndroidAnvilProviderAttached(player, _AndroidAnvilBackend.qnn);
      _configuredNeuralModelId[player] = modelId;
      _androidMpvOutputActive[player] = false;
      return true;
    } catch (error, stackTrace) {
      appLogger.w(
        'MotionProcessingService: Android QNN filter could not be attached',
        error: error,
        stackTrace: stackTrace,
      );
      await _restoreAndroidMotionPath(player);
      return false;
    }
  }

  static Future<bool> _configureAndroidAnvilLiteRt(
    PlayerNative player, {
    required Map<Object?, Object?> capabilities,
    required MediaVersion selectedVersion,
    required NeuralInterpolationPreset neuralPreset,
  }) async {
    if (capabilities['litertAvailable'] != true) return false;

    final resolution = selectedVersion.width == 1280 ? '720p' : '1080p';
    if (!_supportsAndroidAnvilSource(selectedVersion, resolution)) return false;
    final modelId = NeuralModelPackService.androidContextModelId(resolution, neuralPreset);
    final runtime = await player.prepareAndroidLiteRtMotionRuntime(modelId: modelId);
    if (runtime == null) return false;
    if (runtime['modelDownloadPending'] == true) {
      final pendingFiles = runtime['pendingModelFiles'] as List<Object?>? ?? const [];
      appLogger.i(
        'MotionProcessingService: Android Neural model packs are downloading '
        '(${pendingFiles.map((file) => file.toString()).join(', ')}); '
        'this playback will use the available non-neural motion path.',
      );
      return false;
    }
    final npuModel = runtime['npuModelPath'] as String?;
    final gpuModel = runtime['gpuModelPath'] as String?;
    final npuModelBackend = runtime['npuModelBackend'] as String?;
    final npuModelExecution = runtime['npuModelExecution'] as String?;
    final npuModelTarget = runtime['npuModelTarget'] as String?;
    final libraryDir = runtime['libraryDir'] as String?;
    final cacheDir = runtime['cacheDir'] as String?;
    if ((npuModel == null && gpuModel == null) || libraryDir == null || cacheDir == null) return false;

    final original = await _captureAndroidMotionOptions(player);
    if (_androidAnvilActive[player] == true) {
      if (!await _removeAndroidAnvilFilter(player)) return false;
      _androidAnvilActive[player] = false;
      _androidAnvilPreset[player] = null;
    }
    await player.setProperty('vd-lavc-o', _withExportMotionVectors(original.decoderOptions ?? ''));
    await player.setProperty('hwdec', 'no');
    final rendererInstalled = await player.setAndroidMotionProcessingRenderer('gpu-next');
    if (!rendererInstalled) {
      await _restoreAndroidMotionPath(player);
      return false;
    }

    final options = <String>[
      'litert-library-dir=$libraryDir',
      'litert-cache-dir=$cacheDir',
      if (npuModel != null) 'litert-model=$npuModel',
      if (gpuModel != null) 'litert-gpu-model=$gpuModel',
      if (npuModel != null && npuModelBackend != null && RegExp(r'^[a-z0-9_-]{1,32}$').hasMatch(npuModelBackend))
        'litert-npu-backend=$npuModelBackend',
      if (npuModel != null && const {'aot', 'jit'}.contains(npuModelExecution))
        'litert-npu-execution=$npuModelExecution',
      if (npuModel != null && npuModelTarget != null && RegExp(r'^[A-Z0-9_-]{1,32}$').hasMatch(npuModelTarget))
        'litert-npu-target=$npuModelTarget',
      'require-neural=yes',
    ].join(':');
    try {
      await player.command(['vf', 'add', '@plezy-anvil:anvil=$options']);
      _androidAnvilActive[player] = true;
      _androidAnvilPreset[player] = neuralPreset;
      _markAndroidAnvilProviderAttached(player, _AndroidAnvilBackend.liteRt);
      _configuredNeuralModelId[player] = modelId;
      _androidMpvOutputActive[player] = false;
      return true;
    } catch (error, stackTrace) {
      appLogger.w(
        'MotionProcessingService: Android LiteRT filter could not be attached',
        error: error,
        stackTrace: stackTrace,
      );
      await _restoreAndroidMotionPath(player);
      return false;
    }
  }

  static Future<_OriginalAndroidMotionOptions> _captureAndroidMotionOptions(PlayerNative player) async {
    var original = _androidOriginals[player];
    if (original == null) {
      original = _OriginalAndroidMotionOptions(
        hwdec: await player.getProperty('hwdec'),
        decoderOptions: await player.getProperty('vd-lavc-o'),
      );
      _androidOriginals[player] = original;
    }
    return original;
  }

  static bool _supportsAndroidAnvilSource(MediaVersion version, String resolution) {
    final expectedWidth = resolution == '720p' ? 1280 : 1920;
    final expectedHeight = resolution == '720p' ? 720 : 1080;
    if (version.width != expectedWidth || version.height != expectedHeight) return false;
    final streams = version.parts
        .expand((part) => part.streams)
        .where((stream) => stream.kind == MediaStreamKind.video);
    final videoStreams = streams.toList(growable: false);
    final video = videoStreams.firstWhere(
      (stream) => stream.selected,
      orElse: () =>
          videoStreams.length == 1 ? videoStreams.single : const MediaStream(id: '', kind: MediaStreamKind.unknown),
    );
    if (video.kind != MediaStreamKind.video || video.interlaced != false || video.hdr || video.dolbyVision) {
      return false;
    }
    final codec = (video.codec ?? version.videoCodec ?? '').toLowerCase();
    if (!const {'h264', 'avc', 'avc1'}.contains(codec)) return false;
    final fps = video.frameRate;
    return fps != null && ((fps - 24).abs() <= 0.1 || (fps - 30).abs() <= 0.1);
  }

  static String _withExportMotionVectors(String decoderOptions) {
    final options = <String>[];
    var current = StringBuffer();
    var escaped = false;
    for (final unit in decoderOptions.runes) {
      final character = String.fromCharCode(unit);
      if (escaped) {
        current.write(character);
        escaped = false;
      } else if (character == r'\') {
        current.write(character);
        escaped = true;
      } else if (character == ',') {
        options.add(current.toString());
        current = StringBuffer();
      } else {
        current.write(character);
      }
    }
    if (current.isNotEmpty) options.add(current.toString());

    final flagsIndex = options.indexWhere((option) => option.trimLeft().startsWith('flags2='));
    if (flagsIndex < 0) {
      options.add('flags2=+export_mvs');
    } else {
      final prefixLength = options[flagsIndex].indexOf('flags2=') + 'flags2='.length;
      final value = options[flagsIndex].substring(prefixLength);
      // FFmpeg flag strings allow both `+flag` and `-flag`; a negative entry
      // must not suppress enabling export_mvs for the ANVIL decoder path.
      final exportIsEnabled = RegExp(r'(^|\+)export_mvs($|[+-])').hasMatch(value);
      if (!exportIsEnabled) {
        final separator = value.isEmpty || value.endsWith('+') || value.endsWith('-') ? '' : '+';
        options[flagsIndex] = '${options[flagsIndex]}${separator}export_mvs';
      }
    }
    return options.where((option) => option.isNotEmpty).join(',');
  }

  static Future<bool> _removeAndroidAnvilFilter(Player player) async {
    try {
      await player.command(['vf', 'remove', '@plezy-anvil']);
      _invalidateAndroidAnvilProviderWatch(player);
      _configuredNeuralModelId[player] = null;
      return true;
    } catch (error) {
      appLogger.d('MotionProcessingService: Android ANVIL filter was not active', error: error);
      return false;
    }
  }

  static Future<void> _restoreAndroidMotionPath(Player player, {bool requireRestore = false}) async {
    _invalidateAndroidAnvilProviderWatch(player);
    _configuredNeuralModelId[player] = null;
    final original = _androidOriginals[player];
    final hadMotionOutput =
        _androidMpvOutputActive[player] == true || _androidAnvilActive[player] == true || original != null;
    if (_androidAnvilActive[player] == true) {
      if (await _removeAndroidAnvilFilter(player)) {
        _androidAnvilActive[player] = false;
        _androidAnvilPreset[player] = null;
      } else if (requireRestore) {
        throw StateError('The Android Neural filter could not be removed.');
      }
    }
    if (player is PlayerNative) {
      try {
        final restored = await player.setAndroidMotionProcessingRenderer(null);
        if (!restored) {
          if (requireRestore && hadMotionOutput) throw StateError('The Android video output could not be restored.');
          appLogger.w('MotionProcessingService: Android motion renderer did not return to its requested output.');
        }
      } catch (error, stackTrace) {
        if (requireRestore && hadMotionOutput) rethrow;
        appLogger.w(
          'MotionProcessingService: Android motion renderer could not be restored',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    _androidMpvOutputActive[player] = false;
    if (original == null) {
      _androidAnvilActive[player] = false;
      return;
    }
    final restore = <(String, String?)>[('vd-lavc-o', original.decoderOptions), ('hwdec', original.hwdec)];
    for (final (property, value) in restore) {
      if (value == null) continue;
      try {
        await player.setProperty(property, value);
      } catch (error, stackTrace) {
        appLogger.w(
          'MotionProcessingService: Android motion option $property could not be restored',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    _androidAnvilActive[player] = false;
    _androidAnvilPreset[player] = null;
    _androidOriginals[player] = null;
  }
}

final class _OriginalAppleMotionOptions {
  final String? interpolation;
  final String? preset;
  final String? videoSync;

  const _OriginalAppleMotionOptions({required this.interpolation, required this.preset, required this.videoSync});
}

enum _AndroidAnvilBackend { qnn, liteRt }

final class _OriginalAndroidMotionOptions {
  final String? hwdec;
  final String? decoderOptions;

  const _OriginalAndroidMotionOptions({required this.hwdec, required this.decoderOptions});
}

final class _DesktopPmeRuntime {
  final String providerManifest;
  final String pmeLibrary;
  final String ortLibrary;

  const _DesktopPmeRuntime({required this.providerManifest, required this.pmeLibrary, required this.ortLibrary});
}

final class _OriginalDesktopPmeOptions {
  final String? hwdec;
  final String? decoderOptions;

  const _OriginalDesktopPmeOptions({required this.hwdec, required this.decoderOptions});
}

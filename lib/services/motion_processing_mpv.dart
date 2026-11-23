part of 'motion_processing_service.dart';

Future<String?> _readMpvMotionProperty(Player player, String name) {
  final read = player.getProperty(name);
  return MotionProcessingService._isDesktopPmePlatform ? read.timeout(const Duration(seconds: 3)) : read;
}

Future<void> _writeMpvMotionProperty(Player player, String name, String value) {
  final write = player.setProperty(name, value);
  return MotionProcessingService._isDesktopPmePlatform ? write.timeout(const Duration(seconds: 3)) : write;
}

Future<void> _logLiveMotionChange(Player player, MotionProcessingMode requested) async {
  final properties = [
    'current-vo',
    'container-fps',
    'display-fps',
    'video-sync',
    'display-sync-active',
    'interpolation',
    'interpolation-threshold',
    'video-out-interpolation',
    'mistimed-frame-count',
    'vo-delayed-frame-count',
    'frame-drop-count',
    if (MotionProcessingService._isApplePlatform) 'avfoundation-motion-interpolation',
  ];
  final prefix = 'Motion smoothing accepted: requested=${requested.name}, backend=${player.playerType}';
  try {
    final values = await Future.wait(properties.map(player.getProperty)).timeout(const Duration(seconds: 1));
    final observed = [
      for (var i = 0; i < properties.length; i++)
        if (values[i] case final String value when value.isNotEmpty) '${properties[i]}=$value',
    ];
    final activePreset = MotionProcessingService.activeMotionPresetForPlayer(player);
    appLogger.i(
      [
        prefix,
        if (activePreset != null) 'configured-preset=${activePreset.name}',
        if (MotionProcessingService._appleMixer[player] case final String mixer) 'configured-mixer=$mixer',
        if (MotionProcessingService._powerLimited[player] == true) 'power-limited',
        if (MotionProcessingService._thermalLimited[player] == true) 'thermal-limited',
        ...observed,
      ].join(', '),
    );
  } catch (_) {
    // Diagnostic reads cannot turn an accepted renderer change into an error.
    appLogger.i('$prefix, renderer telemetry unavailable');
  }
}

Future<void> _applyMpvInterpolation(Player player, {bool alwaysInterpolate = false}) async {
  var original = MotionProcessingService._originals[player];
  if (original == null) {
    original = _OriginalMotionProperties(
      videoSync: await _readMpvMotionProperty(player, 'video-sync'),
      interpolation: await _readMpvMotionProperty(player, 'interpolation'),
      interpolationThreshold: MotionProcessingService._isDesktopPmePlatform
          ? await _readMpvMotionProperty(player, 'interpolation-threshold')
          : null,
      tscale: await _readMpvMotionProperty(player, 'tscale'),
      tscaleBlur: await _readMpvMotionProperty(player, 'tscale-blur'),
      tscaleClamp: await _readMpvMotionProperty(player, 'tscale-clamp'),
    );
    MotionProcessingService._originals[player] = original;
  }

  try {
    // `interpolation` is ignored unless the VO synchronizes to the
    // display. Keep these writes before the first file during startup so
    // MPV can size its frame references and decoder surface pool.
    await _writeMpvMotionProperty(
      player,
      'video-sync',
      player.audioPassthroughActive ? 'display-vdrop' : 'display-resample',
    );
    // Oversample blends fewer neighbors and preserves more of the source
    // image on desktop. The Motion Clarity controls still offer other kernels.
    await _writeMpvMotionProperty(
      player,
      'tscale',
      MotionProcessingService._isDesktopPmePlatform ? 'oversample' : 'mitchell',
    );
    await _writeMpvMotionProperty(player, 'tscale-blur', '1.0');
    await _writeMpvMotionProperty(player, 'tscale-clamp', '1.0');
    // The explicit desktop MPV choice should interpolate at any cadence
    // supported by the renderer. mpv uses -1 to disable its threshold.
    if (alwaysInterpolate) await _writeMpvMotionProperty(player, 'interpolation-threshold', '-1');
    await _writeMpvMotionProperty(player, 'interpolation', 'yes');
  } catch (error, stackTrace) {
    MotionProcessingService._interpolationBufferReady[player] = false;
    appLogger.w('MotionProcessingService: Failed to apply MPV interpolation', error: error, stackTrace: stackTrace);
    try {
      await _restoreOriginalProperties(player, original);
    } catch (restoreError, restoreStackTrace) {
      appLogger.w(
        'MotionProcessingService: Failed to restore MPV timing after an interpolation error',
        error: restoreError,
        stackTrace: restoreStackTrace,
      );
    }
    rethrow;
  }
}

Future<void> _restoreOriginalProperties(Player player, _OriginalMotionProperties original) async {
  // Return to the original cadence even if a renderer refuses an optional
  // filter control. Try both playback-critical properties before tuning.
  try {
    await _writeMpvMotionProperty(player, 'interpolation', original.interpolation ?? 'no');
  } finally {
    await _writeMpvMotionProperty(player, 'video-sync', original.videoSync ?? 'audio');
  }
  for (final (name, value) in [
    ('interpolation-threshold', original.interpolationThreshold),
    ('tscale', original.tscale),
    ('tscale-blur', original.tscaleBlur),
    ('tscale-clamp', original.tscaleClamp),
  ]) {
    if (value == null) continue;
    try {
      await _writeMpvMotionProperty(player, name, value);
    } catch (error, stackTrace) {
      appLogger.w('Could not restore MPV motion property $name', error: error, stackTrace: stackTrace);
    }
  }
  MotionProcessingService._originals[player] = null;
}

final class _OriginalMotionProperties {
  final String? videoSync;
  final String? interpolation;
  final String? interpolationThreshold;
  final String? tscale;
  final String? tscaleBlur;
  final String? tscaleClamp;

  const _OriginalMotionProperties({
    required this.videoSync,
    required this.interpolation,
    required this.interpolationThreshold,
    required this.tscale,
    required this.tscaleBlur,
    required this.tscaleClamp,
  });
}

enum AndroidAnvilProviderState { initializing, ready, active, failed }

AndroidAnvilProviderState androidAnvilProviderState(String? provider) {
  final status = provider?.trim().toLowerCase();
  if (status == null || status.isEmpty || status == 'initializing') {
    return AndroidAnvilProviderState.initializing;
  }

  if (status == 'litert-cpu-ready') return AndroidAnvilProviderState.ready;
  if (status == 'litert-cpu') return AndroidAnvilProviderState.active;

  if (const {'off', 'unavailable', 'failed', 'error', 'cpu', 'cpu-fallback', 'cpuexecutionprovider'}.contains(status) ||
      status.endsWith('-unavailable') ||
      status.endsWith('-failed') ||
      status.endsWith('-error') ||
      status.endsWith('-cpu')) {
    return AndroidAnvilProviderState.failed;
  }

  if (status == 'ready' || status.endsWith('-ready')) return AndroidAnvilProviderState.ready;

  if (status == 'active' ||
      RegExp(r'^qnn-htp-v\d+$').hasMatch(status) ||
      const {'litert-npu', 'litert-gpu'}.contains(status)) {
    return AndroidAnvilProviderState.active;
  }

  return AndroidAnvilProviderState.initializing;
}

enum AndroidAnvilMonitorAction { pending, providerFailed, noOutputTimeout }

final class AndroidAnvilProviderObservation {
  const AndroidAnvilProviderObservation({
    this.provider,
    this.sourceFrames,
    this.generatedFrames,
    this.sceneCutBypasses,
    this.isPaused,
    this.isPausedForCache,
  });

  final String? provider;
  final int? sourceFrames;
  final int? generatedFrames;
  final int? sceneCutBypasses;
  final bool? isPaused;
  final bool? isPausedForCache;
}

/// Deterministic state for Android ANVIL initialization and output monitoring.
/// Unknown metadata is pending. Timeouts accrue only while playback state is
/// known to be active and source-frame counters advance without output or
/// scene-cut bypass progress.
final class AndroidAnvilProviderMonitor {
  static const outputStallTimeout = Duration(seconds: 45);
  static const _maximumSampleDelta = Duration(seconds: 2);

  int? _previousSourceFrames;
  int? _previousGeneratedFrames;
  int? _previousSceneCutBypasses;
  Duration _withoutOutput = Duration.zero;

  Duration get activeSourceStallDuration => _withoutOutput;

  AndroidAnvilMonitorAction observe(AndroidAnvilProviderObservation observation, {required Duration activeDelta}) {
    final providerState = androidAnvilProviderState(observation.provider);
    if (providerState == AndroidAnvilProviderState.failed) {
      return AndroidAnvilMonitorAction.providerFailed;
    }
    if (providerState == AndroidAnvilProviderState.initializing) return AndroidAnvilMonitorAction.pending;

    final sourceFrames = observation.sourceFrames;
    final generatedFrames = observation.generatedFrames;
    final sceneCutBypasses = observation.sceneCutBypasses;
    var sourceCounterReset = false;
    var generatedCounterReset = false;
    var sceneCutCounterReset = false;
    var sourceProgress = false;
    var generatedProgress = false;
    var sceneCutProgress = false;

    if (sourceFrames != null) {
      sourceCounterReset = _previousSourceFrames != null && sourceFrames < _previousSourceFrames!;
      sourceProgress = _previousSourceFrames != null && sourceFrames > _previousSourceFrames!;
      _previousSourceFrames = sourceFrames;
    }
    if (generatedFrames != null) {
      generatedCounterReset = _previousGeneratedFrames != null && generatedFrames < _previousGeneratedFrames!;
      generatedProgress = _previousGeneratedFrames != null && generatedFrames > _previousGeneratedFrames!;
      _previousGeneratedFrames = generatedFrames;
    }
    if (sceneCutBypasses != null) {
      sceneCutCounterReset = _previousSceneCutBypasses != null && sceneCutBypasses < _previousSceneCutBypasses!;
      sceneCutProgress = _previousSceneCutBypasses != null && sceneCutBypasses > _previousSceneCutBypasses!;
      _previousSceneCutBypasses = sceneCutBypasses;
    }

    if (sourceCounterReset || generatedCounterReset || sceneCutCounterReset) {
      _withoutOutput = Duration.zero;
      sourceProgress = false;
    }

    final playbackStateKnownActive = observation.isPaused == false && observation.isPausedForCache == false;
    if (!playbackStateKnownActive) return AndroidAnvilMonitorAction.pending;

    if (generatedProgress || sceneCutProgress) {
      _withoutOutput = Duration.zero;
    } else if (sourceProgress) {
      final boundedDelta = activeDelta > _maximumSampleDelta ? _maximumSampleDelta : activeDelta;
      if (boundedDelta > Duration.zero) _withoutOutput += boundedDelta;
    }

    return _withoutOutput >= outputStallTimeout
        ? AndroidAnvilMonitorAction.noOutputTimeout
        : AndroidAnvilMonitorAction.pending;
  }
}

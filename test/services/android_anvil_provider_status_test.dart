import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/android_anvil_provider_status.dart';

void main() {
  group('androidAnvilProviderState', () {
    test('keeps missing, unknown, and initializing providers pending', () {
      expect(androidAnvilProviderState(null), AndroidAnvilProviderState.initializing);
      expect(androidAnvilProviderState(''), AndroidAnvilProviderState.initializing);
      expect(androidAnvilProviderState('initializing'), AndroidAnvilProviderState.initializing);
      expect(androidAnvilProviderState('new-provider-state'), AndroidAnvilProviderState.initializing);
    });

    test('distinguishes readiness from successful provider inference', () {
      expect(androidAnvilProviderState('qnn-htp-v73-ready'), AndroidAnvilProviderState.ready);
      expect(androidAnvilProviderState('litert-npu-ready'), AndroidAnvilProviderState.ready);
      expect(androidAnvilProviderState('litert-gpu-ready'), AndroidAnvilProviderState.ready);
      expect(androidAnvilProviderState('qnn-htp-v73'), AndroidAnvilProviderState.active);
      expect(androidAnvilProviderState('litert-npu'), AndroidAnvilProviderState.active);
      expect(androidAnvilProviderState('litert-gpu'), AndroidAnvilProviderState.active);
      expect(androidAnvilProviderState('litert-cpu-ready'), AndroidAnvilProviderState.ready);
      expect(androidAnvilProviderState('litert-cpu'), AndroidAnvilProviderState.active);
    });

    test('recognizes terminal failures and CPU fallback', () {
      for (final status in [
        'off',
        'unavailable',
        'failed',
        'litert-npu-failed',
        'error',
        'qnn-htp-error',
        'cpu',
        'cpu-fallback',
      ]) {
        expect(androidAnvilProviderState(status), AndroidAnvilProviderState.failed, reason: status);
      }
    });
  });

  group('AndroidAnvilProviderMonitor', () {
    AndroidAnvilProviderObservation observation({
      String? provider = 'litert-npu-ready',
      int? sourceFrames = 0,
      int? generatedFrames = 0,
      int? sceneCutBypasses = 0,
      bool? isPaused = false,
      bool? isPausedForCache = false,
    }) => AndroidAnvilProviderObservation(
      provider: provider,
      sourceFrames: sourceFrames,
      generatedFrames: generatedFrames,
      sceneCutBypasses: sceneCutBypasses,
      isPaused: isPaused,
      isPausedForCache: isPausedForCache,
    );

    test('does not timeout until source frames progress without generated output', () {
      final monitor = AndroidAnvilProviderMonitor();
      expect(
        monitor.observe(observation(), activeDelta: const Duration(seconds: 45)),
        AndroidAnvilMonitorAction.pending,
      );
      expect(
        monitor.observe(observation(sourceFrames: 1), activeDelta: const Duration(seconds: 1)),
        AndroidAnvilMonitorAction.pending,
      );
      expect(monitor.activeSourceStallDuration, const Duration(seconds: 1));
    });

    test('keeps missing or unknown provider states pending despite source progress', () {
      for (final provider in [null, 'initializing', 'new-provider-state']) {
        final monitor = AndroidAnvilProviderMonitor();
        for (var frame = 0; frame <= 60; frame++) {
          expect(
            monitor.observe(
              observation(provider: provider, sourceFrames: frame),
              activeDelta: const Duration(seconds: 1),
            ),
            AndroidAnvilMonitorAction.pending,
            reason: provider,
          );
        }
        expect(monitor.activeSourceStallDuration, Duration.zero, reason: provider);
      }
    });

    test('uses active playback time and clamps delayed sample intervals', () {
      final monitor = AndroidAnvilProviderMonitor();
      monitor.observe(observation(), activeDelta: Duration.zero);

      expect(
        monitor.observe(observation(sourceFrames: 1), activeDelta: const Duration(hours: 1)),
        AndroidAnvilMonitorAction.pending,
      );
      expect(monitor.activeSourceStallDuration, const Duration(seconds: 2));

      for (var frame = 2; frame <= 22; frame++) {
        expect(
          monitor.observe(observation(sourceFrames: frame), activeDelta: const Duration(seconds: 2)),
          AndroidAnvilMonitorAction.pending,
        );
      }
      expect(
        monitor.observe(observation(sourceFrames: 23), activeDelta: const Duration(seconds: 2)),
        AndroidAnvilMonitorAction.noOutputTimeout,
      );
    });

    test('pauses timeout accounting while paused, cache-paused, or state is unknown', () {
      final monitor = AndroidAnvilProviderMonitor();
      monitor.observe(observation(), activeDelta: Duration.zero);
      for (var frame = 1; frame <= 50; frame++) {
        expect(
          monitor.observe(observation(sourceFrames: frame, isPaused: true), activeDelta: const Duration(seconds: 1)),
          AndroidAnvilMonitorAction.pending,
        );
      }
      expect(monitor.activeSourceStallDuration, Duration.zero);
      for (var frame = 51; frame <= 70; frame++) {
        expect(
          monitor.observe(
            observation(sourceFrames: frame, isPaused: false, isPausedForCache: true),
            activeDelta: const Duration(seconds: 1),
          ),
          AndroidAnvilMonitorAction.pending,
        );
      }
      expect(monitor.activeSourceStallDuration, Duration.zero);
      expect(
        monitor.observe(observation(sourceFrames: 71, isPaused: null), activeDelta: const Duration(seconds: 1)),
        AndroidAnvilMonitorAction.pending,
      );
      expect(monitor.activeSourceStallDuration, Duration.zero);
    });

    test('generated frames and scene-cut bypasses reset the output deadline', () {
      final monitor = AndroidAnvilProviderMonitor();
      monitor.observe(observation(), activeDelta: Duration.zero);
      for (var frame = 1; frame <= 40; frame++) {
        monitor.observe(observation(sourceFrames: frame), activeDelta: const Duration(seconds: 1));
      }
      expect(
        monitor.observe(observation(sourceFrames: 41, generatedFrames: 1), activeDelta: const Duration(seconds: 1)),
        AndroidAnvilMonitorAction.pending,
      );
      expect(monitor.activeSourceStallDuration, Duration.zero);
      for (var frame = 42; frame <= 81; frame++) {
        monitor.observe(observation(sourceFrames: frame), activeDelta: const Duration(seconds: 1));
      }
      expect(
        monitor.observe(observation(sourceFrames: 82, sceneCutBypasses: 1), activeDelta: const Duration(seconds: 1)),
        AndroidAnvilMonitorAction.pending,
      );
      expect(monitor.activeSourceStallDuration, Duration.zero);
    });

    test('counter resets after a seek restart the no-output window', () {
      final monitor = AndroidAnvilProviderMonitor();
      monitor.observe(observation(sourceFrames: 100), activeDelta: Duration.zero);
      for (var frame = 101; frame <= 140; frame++) {
        monitor.observe(observation(sourceFrames: frame), activeDelta: const Duration(seconds: 1));
      }
      expect(
        monitor.observe(
          observation(sourceFrames: 2, generatedFrames: 0, sceneCutBypasses: 0),
          activeDelta: Duration.zero,
        ),
        AndroidAnvilMonitorAction.pending,
      );
      expect(monitor.activeSourceStallDuration, Duration.zero);
    });

    test('terminal failure is immediate even when playback is paused', () {
      final monitor = AndroidAnvilProviderMonitor();
      expect(
        monitor.observe(observation(provider: 'litert-npu-failed', isPaused: true), activeDelta: Duration.zero),
        AndroidAnvilMonitorAction.providerFailed,
      );
    });

    test('keeps watching after first inference and detects a later output stall', () {
      final monitor = AndroidAnvilProviderMonitor();
      monitor.observe(observation(), activeDelta: Duration.zero);
      expect(
        monitor.observe(
          observation(provider: 'litert-npu', sourceFrames: 1, generatedFrames: 1),
          activeDelta: const Duration(seconds: 1),
        ),
        AndroidAnvilMonitorAction.pending,
      );
      for (var frame = 2; frame <= 45; frame++) {
        expect(
          monitor.observe(
            observation(provider: 'litert-npu', sourceFrames: frame, generatedFrames: 1),
            activeDelta: const Duration(seconds: 1),
          ),
          AndroidAnvilMonitorAction.pending,
        );
      }
      expect(
        monitor.observe(
          observation(provider: 'litert-npu', sourceFrames: 46, generatedFrames: 1),
          activeDelta: const Duration(seconds: 1),
        ),
        AndroidAnvilMonitorAction.noOutputTimeout,
      );
    });
  });
}

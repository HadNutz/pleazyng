import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_stream.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/models/motion_clarity.dart';
import 'package:plezy/models/motion_processing_mode.dart';
import 'package:plezy/mpv/player/player_stream_controllers.dart';
import 'package:plezy/services/motion_processing_service.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/motion_clarity_service.dart';

void main() {
  test('Apple uses software without starting GPU readback on an incompatible Metal driver', () async {
    final player = _RecordingPlayer(60);
    player._properties['pleazyng-apple-mixer-gpu-supported'] = 'no';
    await MotionProcessingService.configureAppleMotion(
      player,
      MotionProcessingMode.mpv,
      NeuralInterpolationPreset.balanced,
    );
    expect(player.commands.single.last, contains('minterpolate'));
    expect(MotionProcessingService.observedAppleMixer(player, 24, 60), 'FFmpeg CPU');
  });

  for (final gpuAvailable in [true, false]) {
    test('Apple falls back on the open stream when the VideoToolbox probe is missing (GPU $gpuAvailable)', () async {
      final player = _RecordingPlayer(60)..rejectGpuMixer = !gpuAvailable;
      player._properties['hwdec'] = 'auto';
      player._properties['pleazyng-apple-mixer-gpu-supported'] = 'yes';
      Future<void> setMode(MotionProcessingMode mode) =>
          MotionProcessingService.configureAppleMotion(player, mode, NeuralInterpolationPreset.balanced);

      await setMode(MotionProcessingMode.neural);
      final filters = player.commands.where((command) => command.first == 'vf').toList();
      expect(filters.first.last, contains('libplacebo'));
      expect(filters.last.last, contains(gpuAvailable ? 'libplacebo' : 'minterpolate'));
      expect(
        MotionProcessingService.observedAppleMixer(player, 24, 60),
        gpuAvailable ? 'libplacebo GPU' : 'FFmpeg CPU',
      );
      expect(player._properties.containsKey('avfoundation-motion-interpolation'), isFalse);
      await setMode(MotionProcessingMode.off);
      expect(player.commands.last, ['vf', 'remove', '@plezy-apple-motion']);
      expect(player._properties['hwdec'], 'auto');
      expect(player.commands.any((args) => args.first == 'loadfile'), isFalse);
    });
  }

  test('Apple keeps track of a mixer when Off cannot remove it yet', () async {
    final player = _RecordingPlayer(60);
    player._properties['hwdec'] = 'auto';
    Future<void> setMode(MotionProcessingMode mode) =>
        MotionProcessingService.configureAppleMotion(player, mode, NeuralInterpolationPreset.balanced);
    await setMode(MotionProcessingMode.mpv);
    player.rejectFilterRemoval = true;
    await expectLater(setMode(MotionProcessingMode.off), throwsUnsupportedError);
    expect(MotionProcessingService.observedAppleMixer(player, 24, 60), 'FFmpeg CPU');
    expect(player._properties['hwdec'], 'videotoolbox-copy');
    player.rejectFilterRemoval = false;
    await setMode(MotionProcessingMode.off);
    expect(MotionProcessingService.observedAppleMixer(player, 24, 60), isNull);
    expect(player._properties['hwdec'], 'auto');
  });

  test('a desktop movie opened in Original can toggle and change presets in place', () async {
    final player = _RecordingPlayer(60);
    player._properties.addAll({
      'current-vo': Platform.isLinux ? 'libmpv' : 'gpu-next',
      'interpolation': 'no',
      'video-sync': 'audio',
      'tscale': 'mitchell',
      'hwdec-extra-frames': 'auto',
    });
    final service = MotionClarityService.forPlayer(player);
    Future<MotionClarityApplyResult> preset(MotionClarityPreset preset, {bool beforeOpen = false}) => service.configure(
      preset: preset,
      kernel: MotionTemporalKernel.linear,
      thresholdPercent: 1,
      beforeSourceOpen: beforeOpen,
    );
    await preset(MotionClarityPreset.original, beforeOpen: true);
    expect(await player.getProperty('interpolation'), 'no');
    expect(await player.getProperty('hwdec-extra-frames'), '8');
    const version = MediaVersion(
      id: 'file',
      width: 1280,
      height: 720,
      parts: [
        MediaPart(
          id: 'part',
          streams: [MediaStream(id: 'video', kind: MediaStreamKind.video, interlaced: false, frameRate: 24)],
        ),
      ],
    );
    await MotionProcessingService.configureForPlayback(player, MotionProcessingMode.off, selectedVersion: version);
    addTearDown(() => MotionProcessingService.stopPowerSourceMonitoring(player));
    service.markSourceOpened();
    expect(MotionProcessingService.canChangeLive(player, mode: MotionProcessingMode.neural), isTrue);
    for (var i = 0; i < 2; i++) {
      expect(MotionProcessingService.canChangeLive(player, mode: MotionProcessingMode.mpv), isTrue);
      await MotionProcessingService.apply(player, MotionProcessingMode.mpv);
      expect(await player.getProperty('interpolation'), 'yes');
      expect(await player.getProperty('tscale'), 'oversample');
      player.rejectedProperty = 'tscale';
      await MotionProcessingService.apply(player, MotionProcessingMode.off);
      expect(await player.getProperty('interpolation'), 'no');
      expect(await player.getProperty('video-sync'), 'audio');
      player.rejectedProperty = null;
    }
    for (final selected in [MotionClarityPreset.balanced, MotionClarityPreset.oled, MotionClarityPreset.original]) {
      final result = await preset(selected);
      expect(result.isSupported, isTrue);
      expect(result.requiresSourceReload, isFalse);
      expect(await player.getProperty('hwdec-extra-frames'), '8');
    }
    expect(player.commands.map((args) => args.first), everyElement('vf'));
    await MotionProcessingService.configureForPlayback(
      player,
      MotionProcessingMode.off,
      selectedVersion: version,
      isTranscoding: true,
    );
    expect(MotionProcessingService.canChangeLive(player, mode: MotionProcessingMode.mpv), isFalse);
  }, skip: !(Platform.isLinux || Platform.isWindows));

  test('explicit desktop MPV smoothing applies at an even display cadence and restores the threshold', () async {
    final player = _RecordingPlayer(119.956);
    player._properties.addAll({
      'current-vo': Platform.isLinux ? 'libmpv' : 'gpu-next',
      'video-sync': 'audio',
      'interpolation': 'no',
      'interpolation-threshold': '0.04',
      'container-fps': '23.976',
    });
    final service = MotionClarityService.forPlayer(player);
    await service.configure(
      preset: MotionClarityPreset.original,
      kernel: MotionTemporalKernel.linear,
      thresholdPercent: 1,
      beforeSourceOpen: true,
    );
    await MotionProcessingService.configureForPlayback(player, MotionProcessingMode.mpv);
    addTearDown(() => MotionProcessingService.stopPowerSourceMonitoring(player));
    expect(await player.getProperty('interpolation'), 'yes');
    expect(await player.getProperty('interpolation-threshold'), '-1');
    service.markSourceOpened();
    expect(MotionProcessingService.canChangeLive(player, mode: MotionProcessingMode.mpv), isTrue);
    expect(MotionProcessingService.canChangeLive(player, mode: MotionProcessingMode.neural), isFalse);
    await MotionProcessingService.apply(player, MotionProcessingMode.off);
    expect(await player.getProperty('interpolation'), 'no');
    expect(await player.getProperty('interpolation-threshold'), '0.04');

    await MotionProcessingService.apply(player, MotionProcessingMode.mpv);
    expect(await player.getProperty('interpolation'), 'yes');
    expect(await player.getProperty('interpolation-threshold'), '-1');
    expect(await player.getProperty('video-sync'), 'display-resample');
    await MotionProcessingService.apply(player, MotionProcessingMode.off);
    expect(await player.getProperty('interpolation'), 'no');
    expect(await player.getProperty('interpolation-threshold'), '0.04');
    expect(await player.getProperty('video-sync'), 'audio');
    expect(player.commands, isEmpty);
  }, skip: !(Platform.isLinux || Platform.isWindows));

  test('motion compensation passes fractional display cadences to FFmpeg exactly', () async {
    for (final (displayRate, exactRate) in <(double, String)>[
      (48 * 1000 / 1001, '48000/1001'),
      (60 * 1000 / 1001, '60000/1001'),
      (120 * 1000 / 1001, '120000/1001'),
    ]) {
      final player = _RecordingPlayer(displayRate);
      final service = MotionClarityService.forPlayer(player);

      final result = await service.configure(
        preset: MotionClarityPreset.balanced,
        kernel: MotionTemporalKernel.linear,
        thresholdPercent: 1,
        beforeSourceOpen: true,
        engine: MotionClarityEngine.motionCompensated,
        sourceFps: 24,
      );

      expect(result.isConfigured, isTrue, reason: 'display rate $displayRate');
      expect(result.targetFps, closeTo(displayRate, 1e-9));
      expect(player.commands.single[2], contains('minterpolate=fps=$exactRate:'), reason: 'display rate $displayRate');
    }
  });

  test('non-finite display rate falls back without constructing an MCI filter', () async {
    final player = _RecordingPlayer(double.nan);
    final service = MotionClarityService.forPlayer(player);

    final result = await service.configure(
      preset: MotionClarityPreset.balanced,
      kernel: MotionTemporalKernel.linear,
      thresholdPercent: 1,
      beforeSourceOpen: true,
      engine: MotionClarityEngine.motionCompensated,
      sourceFps: 24,
    );

    expect(result.isConfigured, isTrue);
    expect(result.effectiveEngine, MotionClarityEngine.temporalBlend);
    expect(player.commands, isEmpty);
  });
}

class _RecordingPlayer with PlayerStreamControllersMixin implements Player {
  @override
  late final streams = createStreams();
  _RecordingPlayer(double displayRate) : _properties = {'display-fps': displayRate.toString(), 'vo': 'gpu-next'};

  final Map<String, String> _properties;
  final commands = <List<String>>[];
  bool rejectGpuMixer = false;
  bool rejectFilterRemoval = false;
  String? rejectedProperty;
  @override
  final String playerType = 'mpv';
  @override
  final bool audioPassthroughActive = false;

  @override
  Future<String?> getProperty(String name) async => _properties[name];

  @override
  Future<void> setProperty(String name, String value) async {
    if (name == rejectedProperty) throw UnsupportedError(name);
    _properties[name] = value;
  }

  @override
  Future<void> command(List<String> args) async {
    commands.add(args);
    if (rejectFilterRemoval && args.take(2).join(' ') == 'vf remove') {
      throw UnsupportedError('Filter could not be removed');
    }
    if (rejectGpuMixer && args.last.contains('libplacebo')) throw UnsupportedError('GPU mixer unavailable');
  }

  @override
  PlayerState get state => const PlayerState();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

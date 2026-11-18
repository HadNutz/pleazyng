import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:os_media_controls/os_media_controls.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_server_client.dart';
import '../../media/media_source_info.dart';
import '../../mpv/mpv.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/companion_remote_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/companion_remote/listening_clock.dart';
import '../../services/music/music_system_audio_route_monitor.dart';
import '../../services/playback_coordinator.dart';
import '../../utils/serial_future_queue.dart';
import '../../utils/language_codes.dart';
import '../video_player/wakelock_controller.dart';

class PhoneListeningScreen extends StatefulWidget {
  const PhoneListeningScreen({super.key, this.createPlayer});

  @visibleForTesting
  final Player Function()? createPlayer;
  @override
  State<PhoneListeningScreen> createState() => _PhoneListeningScreenState();
}

typedef _Track = ({String id, String label, bool described});

class _PhoneListeningScreenState extends State<PhoneListeningScreen> with WidgetsBindingObserver {
  final _wakelock = WakelockController();
  final _operations = SerialFutureQueue();
  final _clock = Stopwatch()..start();
  late final _remote = context.read<CompanionRemoteProvider>();
  late final _profile = context.read<ActiveProfileProvider>().activeId;
  late final _routes = MusicSystemAudioRouteMonitor(current: () => mounted);
  Timer? _timer;
  StreamSubscription<MediaControlEvent>? _interruptions;
  StreamSubscription<dynamic>? _androidHeadphones;
  bool _interrupted = false;
  Player? _player;
  ListeningFile? _file;
  MediaServerClient? _client;
  List<_Track> _tracks = const [];
  String? _selected, _applied, _title, _bluetooth;
  bool _routeHeld = false, _busy = false, _closed = false, _resync = true, _failed = false, _foreground = true;
  int _adjustMs = 0, _missedSamples = 0;
  double? _appliedRate;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _routes.addListener(_routeChanged);
      if (Platform.isAndroid) {
        _androidHeadphones = const EventChannel('com.pleazyng/phone_listening/headphones')
            .receiveBroadcastStream()
            .listen((available) {
              if (_closed || available is! bool) return;
              _routeHeld = !available;
              if (!available) unawaited(_player?.pause());
              _resync = true;
              setState(() {});
            }, onError: (Object _) {});
      }
      _interruptions = OsMediaControls.controlEvents.listen((event) {
        if (_closed) return;
        if (event is AudioRouteOldDeviceUnavailableEvent || event is AudioInterruptionBeganEvent) {
          if (event is AudioInterruptionBeganEvent) _interrupted = true;
          if (event is AudioRouteOldDeviceUnavailableEvent) _routeHeld = true;
          unawaited(_player?.pause());
        } else if (event is AudioRouteNewDeviceAvailableEvent) {
          _routeHeld = false;
        } else if (event is AudioInterruptionEndedEvent) {
          _interrupted = false;
          if (!event.shouldResume) _routeHeld = true;
        } else {
          return;
        }
        _resync = true;
        setState(() {});
      }, onError: (Object _) {});

      _timer = Timer.periodic(const Duration(milliseconds: 300), (_) => _tick());
      _tick();
    });
  }

  bool get _active =>
      mounted &&
      !_closed &&
      _foreground &&
      _remote.supportsPhoneListening &&
      _remote.isPlayerActive &&
      context.read<ActiveProfileProvider>().activeId == _profile;

  MediaServerClient? _visibleClient(String server) {
    final manager = context.read<MultiServerProvider>().serverManager;
    final client = manager.visibleOnlineClients[server];
    return client != null && !manager.isRemoteConnection(client.serverId) ? client : null;
  }

  void _routeChanged() {
    if (_closed || !_foreground) return;
    final route = _routes.value;
    final bluetooth = route?.outputs.where((o) => o.bluetooth).firstOrNull?.id;
    if (_bluetooth != null && bluetooth == null) {
      _routeHeld = true;
      unawaited(_player?.pause());
    }
    if (bluetooth != null) _routeHeld = false;
    _bluetooth = bluetooth;
    _resync = true;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _resync = true;
    if (!_foreground) unawaited(_player?.pause());
  }

  void _tick() {
    if (_busy || _closed || _failed) return;
    _busy = true;
    unawaited(
      _operations.run(() async {
        try {
          if (!_active) {
            await _player?.pause();
            _resync = true;
            if (mounted && !_closed && _foreground) {
              await _releasePlayer();
              if (mounted && !_closed) setState(() => _failed = true);
            }
            return;
          }
          final start = _clock.elapsed;
          final sample = await _remote.sampleListeningClock();
          final received = _clock.elapsed;
          if (!_active || sample == null) {
            await _player?.pause();
            if (mounted && !_closed && _foreground) {
              // A single lost reply may recover on the next sample. Keep the
              // audio paused until the TV clock is current again.
              _resync = true;
              if (++_missedSamples >= 3 || !_active) {
                await _releasePlayer();
                if (mounted && !_closed) setState(() => _failed = true);
              }
            }
            return;
          }
          _missedSamples = 0;
          if (_file != sample.file || (_client != null && !identical(_visibleClient(sample.file.server), _client))) {
            await _releasePlayer();
            if (_active) await _open(sample);
            // Read a fresh clock after opening; resolution and buffering may take seconds.
            return;
          }
          final player = _player;
          final id = _selected;
          if (player == null || id == null || _routeHeld || _interrupted) return;
          if (id != _applied) {
            await player.selectAudioTrack(AudioTrack(id: id));
            if (await player.getProperty('aid') != id) throw StateError('Track unavailable');
            _applied = id;
            _resync = true;
          }
          final elapsed = _clock.elapsed - received + (received - start) ~/ 2;
          final target = sample.target(elapsed, Duration(milliseconds: _adjustMs));
          final action = listeningCorrection(
            target - player.currentPosition,
            playing: sample.playing,
            rate: sample.rate,
            resync: _resync,
          );
          _resync = false;
          if (!sample.playing && player.state.playing) await player.pause();
          if (action.seek) await player.seek(target);
          if (_appliedRate == null || (_appliedRate! - action.speed).abs() > .003) {
            await player.setRate(action.speed);
            _appliedRate = action.speed;
          }
          if (_active && !_routeHeld && !_interrupted && sample.playing && !player.state.playing) await player.play();
        } catch (_) {
          await _releasePlayer();
          if (mounted && !_closed) setState(() => _failed = true);
        } finally {
          _busy = false;
        }
      }),
    );
  }

  Future<void> _open(ListeningClock sample) async {
    final client = _visibleClient(sample.file.server);
    if (client == null) throw StateError('Server unavailable');
    final item = await client.fetchItem(sample.file.item);
    if (!_active) return;
    if (item == null || item.id != sample.file.item || !item.kind.isVideo) throw StateError('Item unavailable');
    final target = await client.resolveExternalPlayback(
      item,
      mediaSourceId: sample.file.source,
      position: sample.position,
      registerPlayback: false,
    );
    if (!_active) return;
    final info = target?.mediaInfo;
    if (target == null ||
        info == null ||
        info.mediaSourceId != sample.file.source ||
        info.partId != sample.file.part ||
        !identical(client, _visibleClient(sample.file.server))) {
      throw StateError('Edition unavailable');
    }
    final coordinator = PlaybackCoordinator.instance;
    await coordinator.claimPhoneListening();
    if (!_active) return;
    coordinator.registerNarrationSession(_stopListening);
    final player = _player = widget.createPlayer?.call() ?? Player.audio();
    final loaded = Completer<bool>();
    final ready = player.streams.fileLoaded.listen((_) {
      if (!loaded.isCompleted) loaded.complete(true);
    });
    final failure = player.streams.fileLoadFailed.listen((_) {
      if (!loaded.isCompleted) loaded.complete(false);
    });
    try {
      await player.open(
        Media(target.url, start: sample.position),
        play: false,
        timelineOffset: target.partTimeline?.current.start ?? Duration.zero,
        timelineDuration: target.partTimeline?.duration,
      );
      if (!await loaded.future.timeout(const Duration(seconds: 12))) throw StateError('File could not be opened');
    } finally {
      unawaited(ready.cancel());
      unawaited(failure.cancel());
    }
    if (!_active) return;
    final tracks = await _embeddedTracks(player, info);
    if (tracks.isEmpty) throw StateError('No embedded audio');
    if (!_active) return;
    _client = client;
    _file = sample.file;
    _tracks = tracks;
    _selected = tracks.where((t) => t.described).singleOrNull?.id;
    _title = item.title;
    unawaited(_wakelock.setEnabled(true));
    setState(() {});
  }

  Future<List<_Track>> _embeddedTracks(Player player, MediaSourceInfo info) async {
    final count = int.tryParse(await player.getProperty('track-list/count') ?? '') ?? 0;
    final tracks = <_Track>[];
    for (int i = 0; i < count.clamp(0, 512); i++) {
      final key = 'track-list/$i';
      if (await player.getProperty('$key/type') != 'audio') continue;
      final id = await player.getProperty('$key/id');
      if (id == null || int.tryParse(id) == null) continue;
      final ffIndex = int.tryParse(await player.getProperty('$key/ff-index') ?? '');
      final row = ffIndex == null
          ? null
          : info.audioTracks.where((t) => t.index == ffIndex && !t.external).singleOrNull;
      final title = row?.title ?? await player.getProperty('$key/title');
      final lang = row?.languageCode ?? await player.getProperty('$key/lang');
      final described = row?.described == true || await player.getProperty('$key/visual-impaired') == 'yes';
      final label = [
        if (title != null && title.isNotEmpty) title,
        if (lang != null && lang.isNotEmpty) LanguageCodes.getDisplayName(lang),
        if (described) t.fileInfo.audioDescription,
      ].join(' · ');
      tracks.add((
        id: id,
        label: label.isEmpty ? t.audioTracks.track(n: tracks.length + 1) : label,
        described: described,
      ));
    }
    return tracks;
  }

  Future<void> _releasePlayer() async {
    final player = _player;
    _player = null;
    _file = null;
    _client = null;
    _tracks = const [];
    _selected = _applied = null;
    _appliedRate = null;
    _resync = true;
    try {
      if (player != null) {
        unawaited(_wakelock.setEnabled(false));
        try {
          await player.pause();
        } finally {
          await player.dispose();
        }
      }
    } finally {
      PlaybackCoordinator.instance.unregisterNarrationSession(_stopListening);
    }
  }

  Future<void> _stopListening() {
    _closed = true;
    _timer?.cancel();
    if (mounted) setState(() => _failed = true);
    return _operations.run(_releasePlayer);
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_interruptions?.cancel());
    unawaited(_androidHeadphones?.cancel());
    _routes.dispose();
    unawaited(_operations.run(_releasePlayer));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t.viewing.listenPhone)),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_failed) ...[
          Text(t.viewing.audioUnavailable),
          TextButton(
            onPressed: () {
              setState(() {
                _closed = false;
                _failed = false;
                _resync = true;
              });
              if (_timer?.isActive != true) _timer = Timer.periodic(const Duration(milliseconds: 300), (_) => _tick());
              _tick();
            },
            child: Text(t.common.retry),
          ),
        ] else if (_tracks.isEmpty)
          const Center(child: CircularProgressIndicator())
        else ...[
          Text(_title ?? '', style: Theme.of(context).textTheme.titleLarge),
          RadioGroup<String>(
            groupValue: _selected,
            onChanged: (id) => setState(() {
              _selected = id;
              _routeHeld = false;
              _resync = true;
            }),
            child: Column(
              children: [for (final track in _tracks) RadioListTile(value: track.id, title: Text(track.label))],
            ),
          ),
          if (_routeHeld)
            TextButton(
              onPressed: () => setState(() {
                _routeHeld = false;
                _resync = true;
              }),
              child: Text(t.videoControls.playButton),
            ),
          Text('${t.videoSettings.audioSync} · ${_adjustMs > 0 ? '+' : ''}$_adjustMs ms'),
          Slider(
            value: _adjustMs.toDouble(),
            min: -1000,
            max: 1000,
            divisions: 80,
            label: '$_adjustMs ms',
            onChanged: (v) => setState(() {
              _adjustMs = v.round();
              _resync = true;
            }),
          ),
        ],
      ],
    ),
  );
}

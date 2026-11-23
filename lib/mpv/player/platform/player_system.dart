import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_drm/video_player.dart' as captions;
import 'package:video_player_drm/webos_video_plane.dart';

import '../../../utils/platform_detector.dart';

import 'package:video_player_win/video_player_win.dart' as win;

import '../../../models/audio_channel_limit.dart';
import '../../../models/motion_processing_mode.dart';
import '../../../utils/serial_future_queue.dart';
import '../../models.dart';
import '../player_base.dart';
import '../video_rect_support.dart';
import '../subtitle_pcm_capture_source.dart';
import 'webos_media_proxy.dart';
import 'native_tv_video_framing.dart';
import 'webos_video_layout.dart';
import 'system_subtitles.dart';
import '../../font_loader.dart';

/// One native session per source. Its ID also identifies the video surface:
/// a delayed prepare, poll or dispose cannot target a replacement source.
class PlayerSystem extends PlayerBase
    with NativeTvVideoFraming
    implements PlayerMediaSessionIdentity, VideoRectSupport {
  PlayerSystem(this.playerType, {this.hardwareDecoding = true}) : super(listenToNativeEvents: false);

  @override
  final String playerType;
  final bool hardwareDecoding;
  bool _nextTvMotion = false;
  bool _tvMotionRequested = false;
  bool get tvMotionRequested => _tvMotionRequested;
  String? _motionProvider;

  bool _nextTvEligible = false;
  bool _tvEligible = false;
  NeuralInterpolationPreset _nextTvPreset = NeuralInterpolationPreset.balanced;
  NeuralInterpolationPreset? _activeTvMotionPreset;
  NeuralInterpolationPreset? get activeTvMotionPreset => _activeTvMotionPreset;
  bool get canChangeTvMotion => _tvEligible && _ready && !_live && !_ended && !_closing;

  void prepareTvMotion(
    bool requested, {
    bool eligible = true,
    NeuralInterpolationPreset preset = NeuralInterpolationPreset.balanced,
  }) {
    _nextTvEligible = eligible;
    _nextTvMotion = requested && eligible;
    _nextTvPreset = preset;
  }

  Future<void> disableTvMotion() => setTvMotion(false);

  Future<void> setTvMotion(bool enable, {NeuralInterpolationPreset preset = NeuralInterpolationPreset.balanced}) {
    final generation = _generation;
    return _sources.run(() async {
      if (!_current(generation) || !_ready || _id == null) throw StateError('TV playback changed');
      if (enable && !canChangeTvMotion) throw UnsupportedError('Motion processing is unavailable for this source');
      if (enable && _texture == -2) {
        await _switchPlaneToMotionTexture(generation, _id!, preset);
      } else {
        await _control(enable ? 'enableMotion' : 'disableMotion', preset.name);
      }
      if (!_current(generation)) throw StateError('TV playback changed');
      _activeTvMotionPreset = enable ? preset : null;
      _tvMotionRequested = enable;
      _motionProvider = null;
    });
  }

  Future<void> _switchPlaneToMotionTexture(int generation, int id, NeuralInterpolationPreset preset) async {
    final candidate = ++_nextId;
    final args = {'id': id, 'candidate': candidate, 'value': preset.name};
    final texture = await methodChannel.invokeMethod<int>('prepareMotionTexture', args);
    try {
      if (texture == null || texture < 0) throw StateError('Motion texture unavailable');
      final wait = Stopwatch()..start();
      while (_current(generation) && !_ended) {
        final snapshot = await _snapshot(candidate);
        if (!_current(generation) || _ended) break;
        if (snapshot['failed'] == true) throw StateError('Motion texture failed');
        if (snapshot['ready'] == true && snapshot['frame'] == true) {
          await methodChannel.invokeMethod<void>('commitMotionTexture', args);
          if (!_current(generation)) break;
          _texture = texture;
          _overlayTexture = null;
          _updateSurfaceGeometry(snapshot);
          surfaceRevision.value++;
          await _closeWindow();
          return;
        }
        if (wait.elapsed >= const Duration(seconds: 10)) throw TimeoutException('Motion texture preroll');
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      throw StateError('TV playback changed');
    } finally {
      // After the atomic swap the candidate ID owns the outgoing plane.
      await methodChannel.invokeMethod<void>('dispose', {'id': candidate});
    }
  }

  String? _window;
  String? _output, _decoder, _displayMode;
  int? _outputWidth, _outputHeight;
  @override
  String get logPrefix => playerType;
  @override
  MethodChannel get methodChannel => const MethodChannel('org.snapetech.pleazyng/system_video');
  @override
  EventChannel get eventChannel => const EventChannel('org.snapetech.pleazyng/system_video/events');
  @override
  bool get supportsSecondarySubtitles => false;

  @override
  Set<String> get supportedLocalSubtitleExtensions => const {'srt', 'vtt'};
  final _caption = ValueNotifier<String>('');
  SystemSubtitleTimeline? _cues;
  List<SubtitleTrack> _sidecars = const [];
  Media? _media;
  int _subtitleSelection = 0;
  Duration _subtitleDelay = Duration.zero;
  int _audioDelayUs = 0;
  @override
  bool get supportsAudioDelay => playerType == 'gstreamer' || playerType == 'tvmpv';
  bool _subtitlesVisible = true;
  @override
  final surfaceRevision = ValueNotifier<int>(0);
  final _sources = SerialFutureQueue();
  static int _nextId = 0;
  int? _id;
  int? _texture;
  Size _size = Size.zero;
  bool _visible = true;
  bool _live = false;
  bool _rendered = false;
  bool _ended = false;
  bool _closing = false;
  bool _ready = false;
  static const _windowsChannel = MethodChannel('video_player_win');
  int? _trackRevision;
  int? _overlayTexture;
  int _generation = 0;
  Completer<void>? _opening;
  bool _desktopPlane = false;
  bool get usesDesktopPlane => _desktopPlane && _visible;
  int _newGeneration() {
    _opening?.complete();
    _opening = null;
    return ++_generation;
  }

  @override
  Future<void> setVideoRect({
    required int left,
    required int top,
    required int right,
    required int bottom,
    required double devicePixelRatio,
  }) async {
    if (!_desktopPlane || !_visible || _id == null) return;
    final windows = _windows;
    await (windows == null ? methodChannel : _windowsChannel).invokeMethod<void>('planeRect', {
      'id': _id,
      'textureId': windows?.value.textureId,
      'left': left,
      'top': top,
      'width': right - left,
      'height': bottom - top,
      'scale': devicePixelRatio.round(),
    });
  }

  @override
  int get mediaSessionGeneration => _generation;
  Timer? _poll;
  WebOSMediaProxy? _proxy;
  win.WinVideoPlayerController? _windows;
  StreamSubscription<dynamic>? _windowsEvents;
  Future<void>? _disposal;
  bool _current(int generation) => !_closing && generation == _generation;

  Widget videoSurface({Widget? desktopPlane}) => Stack(
    fit: StackFit.expand,
    children: [
      if (usesDesktopPlane && desktopPlane != null && !_size.isEmpty)
        Center(
          child: AspectRatio(aspectRatio: _size.aspectRatio, child: desktopPlane),
        )
      else
        _surface(),
      if (_visible)
        IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 36),
              child: ValueListenableBuilder<String>(
                valueListenable: _caption,
                builder: (context, text, _) =>
                    text.isEmpty ? const SizedBox.shrink() : captions.ClosedCaption(text: text),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _surface() {
    final id = _id;
    if (!_visible || id == null) return const SizedBox.expand();
    if (playerType == 'avplayer') {
      const type = 'org.snapetech.pleazyng/avplayer';
      final view = Platform.isMacOS
          ? AppKitView(
              key: ValueKey(id),
              viewType: type,
              creationParams: id,
              creationParamsCodec: const StandardMessageCodec(),
            )
          : UiKitView(
              key: ValueKey(id),
              viewType: type,
              creationParams: id,
              creationParamsCodec: const StandardMessageCodec(),
            );
      return IgnorePointer(child: view);
    }
    if (playerType == 'tvmpv' && !_size.isEmpty) {
      final plane = _texture == -2 && _window != null;
      final texture = _texture;
      if (!plane && (texture == null || texture < 0)) return const SizedBox.expand();
      return LayoutBuilder(
        builder: (context, constraints) {
          final frame = nativeTvVideoLayout(constraints.biggest, _size.aspectRatio, cover: coverVideo, zoom: videoZoom);
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // The texture covers only the picture. Fill the rest of the
              // viewport while leaving the native webOS plane unobstructed.
              if (!plane) const Positioned.fill(child: ColoredBox(color: Color(0xff000000))),
              if (plane)
                Positioned.fromRect(
                  rect: frame.destination,
                  child: WebOSVideoPlane(
                    key: ValueKey(_window),
                    window: _window!,
                    source: _size,
                    crop: frame.source,
                    onError: () {
                      if (_id == id && _texture == -2) _fail(id);
                    },
                  ),
                )
              else
                Positioned.fromRect(
                  rect: frame.fullPicture,
                  child: Texture(textureId: texture!),
                ),
              if (plane && _overlayTexture != null && _overlayTexture! >= 0)
                Positioned.fromRect(
                  rect: frame.fullPicture,
                  child: IgnorePointer(child: Texture(textureId: _overlayTexture!)),
                ),
            ],
          );
        },
      );
    }
    final texture = _texture;
    if (texture == null || texture < 0 || _size.isEmpty) return const SizedBox.expand();
    return Center(
      child: AspectRatio(
        aspectRatio: _size.aspectRatio,
        child: Texture(textureId: texture),
      ),
    );
  }

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) {
    final generation = _newGeneration();
    final motion = _nextTvMotion && !isLive;
    final eligible = _nextTvEligible && !isLive;
    final preset = _nextTvPreset;
    _nextTvEligible = false;
    _nextTvMotion = false;
    return _sources.run(() async {
      if (!_current(generation)) return;
      await _release();
      if (!_current(generation)) return;
      final id = ++_nextId;
      _id = id;
      _media = media;
      _tvMotionRequested = motion;
      _tvEligible = eligible;
      _activeTvMotionPreset = null;
      _sidecars = externalSubtitles?.where((t) => t.uri != null).toList() ?? const [];
      _cues = null;
      _caption.value = '';
      _subtitlesVisible = true;
      _live = isLive;
      _rendered = _ended = _ready = false;
      configureTimeline(duration: timelineDuration, offset: timelineOffset);
      final start = media.start ?? timelineOffset;
      resetPlaybackProgress(start);
      clearTracks();
      setSeekable(false);
      handlePlayerEvent('start-file', {'sourceId': id});
      try {
        var uri = File(media.uri).isAbsolute ? File(media.uri).uri : Uri.parse(media.uri);
        if ((uri.scheme == 'http' || uri.scheme == 'https') &&
            (media.mediaBrowserAuthentication || (media.headers?.isNotEmpty ?? false))) {
          final proxy = _proxy = await WebOSMediaProxy.bind();
          uri = proxy.register(
            uri,
            headers: media.headers,
            mediaBrowserAuthentication: media.mediaBrowserAuthentication,
          );
        }
        if (!_current(generation)) return;
        if (playerType == 'mediafoundation') {
          final interrupted = _opening = Completer<void>();
          final deadline = Stopwatch()..start();
          try {
            for (final nativeSurface in [true, false]) {
              if (!_current(generation)) return;
              final controller = _windows = uri.scheme == 'file'
                  ? win.WinVideoPlayerController.file(File.fromUri(uri))
                  : win.WinVideoPlayerController.networkUrl(uri);
              controller.nativeSurface = nativeSurface;
              _windowsEvents = controller.videoEventStream.listen((_) {}, onError: (Object _) {});
              await Future.any([
                controller.initialize(),
                interrupted.future,
              ]).timeout(const Duration(seconds: 35) - deadline.elapsed);
              if (!_current(generation)) return;
              if (controller.value.isInitialized) {
                _texture = controller.value.textureId;
                break;
              }
              if (!nativeSurface) throw StateError('Media Foundation could not prepare the source');
              await _windowsEvents?.cancel();
              await controller.dispose();
              _windows = null;
            }
          } finally {
            if (identical(_opening, interrupted)) _opening = null;
          }
        } else {
          if (playerType == 'tvmpv' && !motion && hardwareDecoding && PlatformDetector.isWebOSBuild()) {
            try {
              _window = await WebOSVideoPlane.windows.invokeMethod<String>('create', {});
            } on PlatformException {
              /* An unavailable plane can still use a texture. */
            }
          }
          if (!motion) await _create(id, uri);
        }
        if (!_current(generation)) return;
        try {
          if (motion) await _create(id, uri, motion: true, preset: preset);
          await _prepare(generation, id, canRetry: motion || _texture == -2);
          if (motion) _activeTvMotionPreset = preset;
        } catch (_) {
          if (!_current(generation) || (!motion && _texture != -2 && _texture != -3)) rethrow;
          // A failed hardware plane or motion filter gets one clean, unfiltered texture open.
          await methodChannel.invokeMethod<void>('dispose', {'id': id});
          await _closeWindow();
          if (!_current(generation)) return;
          await _create(id, uri, nativeSurface: false);
          await _prepare(generation, id);
        }
        if (!_current(generation)) return;
        if (_audioDelayUs != 0 && supportsAudioDelay) {
          await _control('audioDelay', _audioDelayUs);
          if (!_current(generation)) return;
        }
        await _readTracks(id);
        if (!_current(generation)) return;
        if (sourcePositionFor(start) > Duration.zero) await seek(start);
        if (!_current(generation)) return;
        await setVolume(state.volume);
        if (!_current(generation)) return;
        if (state.rate != 1) await setRate(state.rate);
        if (!_current(generation)) return;
        if (play) await this.play();
        _schedulePoll(generation, id);
      } catch (_) {
        if (!_current(generation)) return;
        await _release();
        throw PlatformException(code: 'system-video-open', message: '$playerType could not open this media.');
      }
    });
  }

  Future<void> _create(
    int id,
    Uri uri, {
    bool nativeSurface = true,
    bool motion = false,
    NeuralInterpolationPreset preset = NeuralInterpolationPreset.balanced,
  }) async {
    final fonts = playerType == 'tvmpv' ? await SubtitleFontLoader.loadSubtitleFont() : null;
    _texture = await methodChannel.invokeMethod<int>('create', {
      'id': id,
      if (motion) ...{'motion': true, 'motionPreset': preset.name},
      'nativeSurface': nativeSurface,
      'uri': uri.toString(),
      'hardwareDecoding': hardwareDecoding,
      if (_window != null) 'windowId': _window,
      'fontDir': ?fonts,
    });
    if (_texture != -2) await _closeWindow();
  }

  Future<void> _closeWindow() async {
    final window = _window;
    _window = null;
    if (window != null) await WebOSVideoPlane.windows.invokeMethod<void>('dispose', {'windowId': window});
  }

  Future<void> _prepare(int generation, int id, {bool canRetry = false}) async {
    surfaceRevision.value++;
    final elapsed = Stopwatch()..start();
    Duration? firstFrameWait;
    while (_current(generation)) {
      final info = await _snapshot(id);
      if (!_current(generation)) return;
      if (info['failed'] == true) throw StateError('Could not prepare media');
      if (playerType == 'tvmpv') _updateSurfaceGeometry(info);
      if (info['ready'] == true) {
        _ready = true;
        _trackRevision = info['trackRevision'] as int?;
        handlePlayerEvent('file-loaded', {'sourceId': id});
        primaryMediaReadyController.add(null);
        _update(info, id);
        return;
      }
      if (canRetry && info['loaded'] == true && info['buffering'] != true) {
        firstFrameWait ??= elapsed.elapsed;
        if (elapsed.elapsed - firstFrameWait > const Duration(seconds: 5)) {
          throw TimeoutException('TV player produced no first frame');
        }
      } else {
        firstFrameWait = null;
      }
      if (elapsed.elapsed > const Duration(seconds: 35)) throw TimeoutException('Native player preparation');
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<Map<dynamic, dynamic>> _snapshot(int id) async {
    final windows = _windows;
    if (windows == null) {
      return await methodChannel.invokeMapMethod<dynamic, dynamic>('state', {'id': id}) ?? const {'failed': true};
    }
    final v = windows.value;
    return {
      ...?await _windowsChannel.invokeMapMethod<String, dynamic>('trackState', {'textureId': v.textureId}),
      'ready': v.isInitialized,
      'failed': v.hasError,
      'playing': v.isPlaying && !v.isCompleted,
      'buffering': v.isBuffering,
      'ended': v.isCompleted,
      'frame': v.isPlaying && v.position > Duration.zero,
      'position': v.position.inMilliseconds,
      'duration': v.duration.inMilliseconds,
      'width': v.size.width,
      'height': v.size.height,
    };
  }

  void _schedulePoll(int generation, int id) {
    if (!_current(generation) || _ended) return;
    _poll = Timer(const Duration(milliseconds: 200), () async {
      try {
        final info = await _snapshot(id);
        if (!_current(generation)) return;
        final revision = info['trackRevision'] as int?;
        if (revision != null && revision != _trackRevision) {
          await _readTracks(id);
          if (!_current(generation)) return;
          _trackRevision = revision;
        }
        _update(info, id);
        _schedulePoll(generation, id);
      } catch (_) {
        if (_current(generation)) _fail(id);
      }
    });
  }

  void _fail(int id) {
    if (_ended) return;
    _ended = true;
    handlePlayerEvent('end-file', {
      'reason': 'error',
      'sourceId': id,
      'message': '$playerType could not play this media. Try another engine in Playback settings.',
    });
  }

  void _update(Map<dynamic, dynamic> info, int id) {
    if (info['failed'] == true) {
      _fail(id);
      return;
    }
    final plane = info['nativePlane'] == true;
    if (plane != _desktopPlane) {
      _desktopPlane = plane;
      surfaceRevision.value++;
    }
    _motionProvider = info['motionProvider'] as String?;
    _output = info['output'] as String?;
    _decoder = info['hardwareDecoder'] as String?;
    _displayMode = info['displayMode'] as String?;
    _outputWidth = (info['outputWidth'] as num?)?.toInt();
    _outputHeight = (info['outputHeight'] as num?)?.toInt();
    final duration = (info['duration'] as num?) ?? 0;
    final position = (info['position'] as num?) ?? 0;
    _caption.value = !_subtitlesVisible
        ? ''
        : _cues?.at(Duration(milliseconds: position.toInt()) - _subtitleDelay) ?? (info['caption'] as String? ?? '');
    setSeekable(!_live && duration > 0);
    handlePropertyChange('duration', duration / 1000);
    handlePropertyChange('time-pos', position / 1000);
    handlePropertyChange('pause', info['playing'] != true);
    handlePropertyChange('paused-for-cache', info['buffering'] == true);
    _updateSurfaceGeometry(info);
    if (!_rendered && info['frame'] == true) {
      _rendered = true;
      handlePlayerEvent('playback-restart', {'sourceId': id, 'positionSeconds': position / 1000});
    }
    if (!_ended && info['ended'] == true) {
      _ended = true;
      handlePropertyChange('eof-reached', true);
    }
  }

  void _updateSurfaceGeometry(Map<dynamic, dynamic> info) {
    final size = Size((info['width'] as num?)?.toDouble() ?? 0, (info['height'] as num?)?.toDouble() ?? 0);
    final overlay = info['overlayTexture'] as int?;
    if (_size != size || _overlayTexture != overlay) {
      _overlayTexture = overlay;
      _size = size;
      surfaceRevision.value++;
    }
  }

  Future<void> _readTracks(int id) async {
    final tracks = _windows == null
        ? await methodChannel.invokeListMethod<dynamic>('tracks', {'id': id}) ?? const []
        : await _windowsChannel.invokeListMethod<dynamic>('tracks', {'textureId': _windows!.value.textureId}) ??
              const [];
    if (id != _id || _closing) return;
    final audio = <AudioTrack>[];
    final subs = <SubtitleTrack>[SubtitleTrack.off];
    String? aid, sid;
    for (final row in tracks.whereType<Map>()) {
      final key = row['id'].toString();
      final lang = row['language'] as String?;
      final title = row['title'] as String?;
      if (row['type'] == 'audio') {
        audio.add(AudioTrack(id: key, language: lang, title: title));
        if (row['selected'] == true) aid = key;
      } else if (row['type'] == 'subtitle') {
        subs.add(SubtitleTrack(id: key, language: lang, title: title, isContainer: true));
        if (row['selected'] == true) sid = key;
      }
    }
    updateTracks(Tracks(audio: audio, subtitle: [...subs, ..._sidecars]));
    updateSelectedAudioTrack(aid);
    final external = state.track.subtitle;
    updateSelectedSubtitleTrack(sid ?? (external?.uri != null ? external!.id : SubtitleTrack.off.id));
  }

  Future<void> _control(String method, [Object? value]) async {
    if (_closing || !_ready || _id == null) return;
    final windows = _windows;
    if (windows == null) {
      await methodChannel.invokeMethod<void>(method, {'id': _id, 'value': value});
      return;
    }
    switch (method) {
      case 'audio':
      case 'subtitle':
        final track = value == SubtitleTrack.off.id ? -1 : int.parse(value as String);
        await _windowsChannel.invokeMethod<void>(method, {'textureId': windows.value.textureId, 'track': track});
      case 'play':
        await windows.play();
      case 'pause':
        await windows.pause();
      case 'seek':
        await windows.seekTo(Duration(milliseconds: value as int));
      case 'volume':
        await windows.setVolume(value as double);
      case 'rate':
        await windows.setPlaybackSpeed(value as double);
    }
  }

  @override
  Future<void> play() => _control('play');
  @override
  Future<void> pause() => _control('pause');
  @override
  Future<void> seek(Duration position) async {
    await runSeek(position, () => _control('seek', sourcePositionFor(position).inMilliseconds));
    if (_ended && _ready && _id != null) {
      _ended = false;
      handlePropertyChange('eof-reached', false);
      _schedulePoll(_generation, _id!);
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0, 100).toDouble();
    await _control('volume', clamped / 100);
    setVolumeState(clamped);
  }

  @override
  Future<void> setRate(double rate) async {
    await _control('rate', rate);
    setRateState(rate);
  }

  @override
  Future<void> selectAudioTrack(AudioTrack track) async {
    if (!_ready || track.id == 'auto') return;
    final generation = _generation;
    await _control('audio', track.id);
    if (_current(generation)) updateSelectedAudioTrack(track.id);
  }

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {
    if (!_ready || track.id == 'auto') return;
    final selection = ++_subtitleSelection;
    final generation = _generation;
    final cues = track.uri != null ? await loadSystemSubtitles(track, _media!, _proxy) : null;
    if (!_current(generation) || selection != _subtitleSelection) return;
    await _control('subtitle', track.uri == null ? track.id : SubtitleTrack.off.id);
    if (!_current(generation) || selection != _subtitleSelection) return;
    _cues = cues;
    _subtitlesVisible = track.id != SubtitleTrack.off.id;
    _caption.value = '';
    updateSelectedSubtitleTrack(track.id);
  }

  @override
  Future<void> setProperty(String name, String value) async {
    switch (name) {
      case 'pause':
        await (value == 'yes' ? pause() : play());
      case 'audio-delay':
        if (!supportsAudioDelay) throw UnsupportedError('Audio delay is unavailable on $playerType');
        if (!_ready || _closing || _id == null) throw StateError('No active playback session for audio delay.');
        final generation = _generation;
        final delayUs = (double.parse(value) * Duration.microsecondsPerSecond).round();
        await _control('audioDelay', delayUs);
        if (!_current(generation)) throw StateError('Playback session changed during audio adjustment.');
        _audioDelayUs = delayUs;
      case 'sub-delay':
        if (playerType == 'tvmpv' && _ready) await _control('subtitleDelay', value);
        _subtitleDelay = Duration(milliseconds: ((double.tryParse(value) ?? 0) * 1000).round());
      case 'sub-visibility':
        if (playerType == 'tvmpv' && _ready) await _control('subtitleVisible', value);
        _subtitlesVisible = value == 'yes';
        if (!_subtitlesVisible) _caption.value = '';
      case 'volume':
        await setVolume(double.parse(value));
      case 'speed':
        await setRate(double.parse(value));
    }
  }

  @override
  Future<String?> getProperty(String name) async => switch (name) {
    'current-vo' => [_output ?? playerType, if (_displayMode?.isNotEmpty == true) _displayMode!].join(' · '),
    'video-params/w' => _size.width > 0 ? _size.width.round().toString() : null,
    'video-params/h' => _size.height > 0 ? _size.height.round().toString() : null,
    'interpolation' when playerType == 'tvmpv' => _motionProvider?.isNotEmpty == true ? 'yes' : 'no',
    'video-out-interpolation' when playerType == 'tvmpv' => _motionProvider,
    'hwdec-current' => _decoder,
    'width' || 'dwidth' => _size.width.toInt().toString(),
    'height' || 'dheight' => _size.height.toInt().toString(),
    'seekable' => state.seekable ? 'yes' : 'no',
    'time-pos' => (sourcePositionFor(currentPosition).inMilliseconds / 1000).toString(),
    _ => null,
  };
  @override
  Future<Map<String, dynamic>> getStats() async => {
    'player': playerType,
    if (_output != null) 'videoOutput': _output,
    if (_displayMode?.isNotEmpty == true) 'displayMode': _displayMode,
    if (_decoder != null && _decoder!.isNotEmpty) 'hwdec': _decoder,
    if (_outputWidth != null) 'outputWidth': _outputWidth,
    if (_outputHeight != null) 'outputHeight': _outputHeight,
  };

  @override
  Future<void> configureSubtitleFonts() async {}
  @override
  Future<void> setLogLevel(String level) async {}
  @override
  Future<void> command(List<String> args) async {
    if (args.isEmpty || args.first != 'sub-add') return;
    if (!_ready || args.length < 2) throw StateError('No source for the subtitle');
    final uri = File(args[1]).uri;
    final title = uri.pathSegments.last;
    final ext = title.split('.').last.toLowerCase();
    if (!supportedLocalSubtitleExtensions.contains(ext)) throw UnsupportedError('Unsupported subtitle format');
    final track = SubtitleTrack.uri(uri.toString(), title: title, codec: ext);
    if (!_sidecars.any((s) => s.uri == track.uri)) {
      _sidecars = [..._sidecars, track];
      updateTracks(Tracks(audio: state.tracks.audio, subtitle: [...state.tracks.subtitle, track]));
    }
    if (args.length < 3 || args[2] == 'select') await selectSubtitleTrack(track);
  }

  @override
  Future<void> setAudioNormalization(bool enabled) async {}
  @override
  Future<void> setAudioChannelLimit(
    AudioChannelLimit limit, {
    required int centerBoostDb,
    required bool normalize,
  }) async {}
  @override
  Future<bool> setVisible(bool visible, {bool restoreOnWindowVisible = false}) async {
    if (!_closing && _visible != visible) {
      if (!visible && _desktopPlane && _id != null) {
        await (_windows == null ? methodChannel : _windowsChannel).invokeMethod<void>('hidePlane', {
          'id': _id,
          'textureId': _windows?.value.textureId,
        });
      }
      _visible = visible;
      surfaceRevision.value++;
    }
    return !_closing;
  }

  Future<void> _release() async {
    _poll?.cancel();
    final id = _id;
    _id = null;
    _ready = false;
    _tvEligible = false;
    _activeTvMotionPreset = null;
    _desktopPlane = false;
    _texture = null;
    _overlayTexture = null;
    _trackRevision = null;
    _size = Size.zero;
    _motionProvider = _decoder = _output = _displayMode = null;
    _outputWidth = _outputHeight = null;
    final windows = _windows;
    _windows = null;
    try {
      if (windows != null) {
        await _windowsEvents?.cancel();
        await windows.dispose();
      } else if (id != null && playerType != 'mediafoundation') {
        await methodChannel.invokeMethod<void>('dispose', {'id': id});
      }
    } finally {
      try {
        await _closeWindow();
      } finally {
        await _proxy?.close();
      }
      _proxy = null;
      if (!_closing && id != null) surfaceRevision.value++;
    }
  }

  @override
  Future<void> stop() {
    _newGeneration();
    return _sources.run(() async {
      final id = _id;
      await _release();
      if (_closing) return;
      if (id != null) handlePlayerEvent('end-file', {'sourceId': id, 'reason': 'stop'});
      resetPlaybackProgress(Duration.zero);
      setSeekable(false);
      handlePropertyChange('pause', true);
      clearTracks();
    });
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) => _disposal ??= _disposeSystem();

  Future<void> _disposeSystem() async {
    _closing = true;
    _newGeneration();
    try {
      await _sources.run(_release);
    } finally {
      _caption.dispose();
      surfaceRevision.dispose();
      await super.dispose();
    }
  }
}

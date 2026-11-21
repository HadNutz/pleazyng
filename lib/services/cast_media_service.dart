import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../i18n/strings.g.dart';
import '../media/media_item.dart';
import '../media/media_server_client.dart';
import '../widgets/app_icon.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import '../utils/watch_state_notifier.dart';
import '../utils/serial_future_queue.dart';
import '../utils/session_identifier.dart';
import 'cast_playback_ownership.dart';
import 'cast_video_transfer.dart';
import 'cast_video_queue.dart';
import 'music/cast_music_output.dart';
import 'music/cast_music_queue.dart';
import 'music/cast_music_recovery.dart';
import 'music/music_library_store.dart';
import 'music/music_device_session.dart';
import 'music/music_transfer_snapshot.dart';
import 'multi_server_manager.dart';
import 'playback_report_session.dart';
import 'trackers/tracker_coordinator.dart';

/// Google Cast handoff for server-resolved streams.
///
/// Plex, Jellyfin and Emby URLs are resolved by their existing client adapters;
/// credentials stay in the self-contained stream URL, so the default Cast
/// receiver does not need custom request headers or a fork-specific receiver.
class CastMediaService extends ChangeNotifier {
  CastMediaService._();

  static final CastMediaService instance = CastMediaService._();

  static bool get isSupportedPlatform => Platform.isAndroid || (Platform.isIOS && !PlatformDetector.isAppleTV());

  final _discovery = GoogleCastDiscoveryManager.instance;
  final _sessions = GoogleCastSessionManager.instance;
  final _remote = GoogleCastRemoteMediaClient.instance;

  bool _initialized = false;
  String? _deviceName;
  MediaItem? _activeItem;
  MediaServerClient? _activeClient;
  String? _playSessionId;
  Duration _partStart = Duration.zero;
  Duration? _partEnd;
  Duration? _duration;
  List<CastVideoPart> _parts = const [];
  int _partIndex = 0;
  bool _replacingReceiver = false;
  bool _reporting = false;
  Timer? _nextPartTimer;
  Future<void>? _previousPartStopped;
  PlaybackReportSession? _reportSession;
  Timer? _progressTimer;
  StreamSubscription<GoogleCastSession?>? _sessionSubscription;
  StreamSubscription<GoggleCastMediaStatus?>? _statusSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<List<GoogleCastQueueItem>>? _queueSubscription;
  bool _finishingPlayback = false;
  bool? _lastPausedState;
  final _loads = SerialFutureQueue();
  final _ownership = CastPlaybackOwnership();
  CastReceiverKey? _receiverKey;
  int _loadIntent = 0;
  int _profileRevision = 0;
  String? _profileId;
  Duration _lastOwnedPosition = Duration.zero;
  _DetachedMusicQueue? _detached;
  Timer? _detachedTimer;
  bool _returningDetached = false;
  CastMusicRecovery? _musicRecovery;
  StreamSubscription<Object?>? _recoveryConnections;
  bool _recoveringDetached = false;

  void bindMusicRecovery(MusicLibraryStore store, MultiServerManager manager) {
    if (store.profileId != _profileId || identical(_musicRecovery?.store, store)) return;
    unawaited(_recoveryConnections?.cancel());
    _musicRecovery = CastMusicRecovery(store, manager);
    _recoveryConnections = manager.statusStream.listen((_) => _tryRecoverDetached());
    if (isSupportedPlatform) {
      unawaited(
        initialize().then((_) => _tryRecoverDetached()).catchError((Object error) {
          appLogger.d('Cast queue recovery initialization failed (${error.runtimeType})');
        }),
      );
    }
  }

  void unbindMusicRecovery(MusicLibraryStore store) {
    if (!identical(_musicRecovery?.store, store)) return;
    _musicRecovery = null;
    unawaited(_recoveryConnections?.cancel());
    _recoveryConnections = null;
  }

  void _tryRecoverDetached() {
    final recovery = _musicRecovery;
    if (!isSupportedPlatform || recovery == null || _recoveringDetached || _detached != null || _activeItem != null) {
      return;
    }
    _recoveringDetached = true;
    unawaited(
      _loads.run(() async {
        try {
          final document = await recovery.read();
          final connection = castReceiverKey(_sessions.currentSession);
          if (!identical(_musicRecovery, recovery) ||
              document == null ||
              connection == null ||
              _detached != null ||
              _activeItem != null ||
              !recovery.store.active) {
            return;
          }
          final queue = CastMusicQueue.recover(
            document,
            manager: recovery.manager,
            connection: connection,
            status: _remote.mediaStatus,
          );
          if (queue == null) return;
          _detached = _DetachedMusicQueue(queue, connection)..committed = true;
          _detachedTimer?.cancel();
          _detachedTimer = Timer.periodic(const Duration(seconds: 2), (_) => _checkDetached());
          _checkDetached();
          notifyListeners();
        } catch (error) {
          appLogger.d('Cast queue recovery unavailable (${error.runtimeType})');
        } finally {
          _recoveringDetached = false;
        }
      }),
    );
  }

  void _forgetRecovery({String? token}) {
    final recovery = _musicRecovery;
    if (recovery == null) return;
    unawaited(
      recovery.clear(token: token).catchError((Object error) {
        appLogger.d('Cast queue recovery removal failed (${error.runtimeType})');
      }),
    );
  }

  void bindProfile(String? profileId) {
    if (_profileId == profileId) return;
    _forgetRecovery();
    _musicRecovery = null;
    unawaited(_recoveryConnections?.cancel());
    _recoveryConnections = null;
    unawaited(_stopMatchedReceiver());
    _profileId = profileId;
    _profileRevision++;
    _loadIntent++;
    _detached?.retire();
    _checkDetached();
    _ownership.clear();
    _receiverKey = null;
    _progressTimer?.cancel();
    _retirePlayback();
  }

  void _retirePlayback() {
    if (_activeItem == null) return;
    final revision = _ownership.revision;
    final position = _lastOwnedPosition;
    unawaited(
      _loads.run(() async {
        if (_ownership.revision == revision) await _finishPlayback(position);
      }),
    );
  }

  bool _matchesReceiver() {
    if (_receiverKey == null || _receiverKey != castReceiverKey(_sessions.currentSession)) return false;
    final status = _remote.mediaStatus;
    return status != null && _ownership.matches(_ownerToken(status), status.mediaSessionID);
  }

  bool _ownsReceiver() => _ownership.authorized && _matchesReceiver();

  bool get hasDetachedMusicQueue {
    final detached = _detached;
    return detached != null &&
        detached.committed &&
        detached.retiredAt == null &&
        detached.queue.authorized() &&
        _matchesDetached(detached);
  }

  bool get canReturnDetachedMusicQueue =>
      !_returningDetached &&
      hasDetachedMusicQueue &&
      _detached!.queue.canReturn(_remote.mediaStatus, _remote.queueItems);

  bool _matchesDetached(_DetachedMusicQueue detached) =>
      detached.queue.matches(detached.connection, castReceiverKey(_sessions.currentSession), _remote.mediaStatus);

  void _clearDetached(_DetachedMusicQueue detached) {
    if (!identical(_detached, detached)) return;
    _forgetRecovery(token: detached.queue.token);
    _detached = null;
    _detachedTimer?.cancel();
    _detachedTimer = null;
  }

  void _checkDetached() {
    final detached = _detached;
    if (detached == null) return;
    if (!detached.queue.authorized()) detached.retire();
    final status = _remote.mediaStatus;
    final connection = castReceiverKey(_sessions.currentSession);
    final matches = _matchesDetached(detached);
    if (detached.retiredAt case final retired?) {
      if ((connection == detached.connection && detached.queue.stopAcknowledged(status)) ||
          DateTime.now().difference(retired) >= const Duration(minutes: 1)) {
        _clearDetached(detached);
      } else if (matches && status?.playerState != CastMediaPlayerState.idle && !detached.stopping) {
        unawaited(_stopDetached(detached));
      }
    } else if (detached.committed &&
        connection != null &&
        (connection != detached.connection ||
            (status?.playerState == CastMediaPlayerState.idle &&
                status?.idleReason != null &&
                status?.idleReason != GoogleCastMediaIdleReason.none &&
                (status?.idleReason != GoogleCastMediaIdleReason.finished ||
                    !matches ||
                    detached.queue.isFinalOccurrence(status))) ||
            (!matches && status?.mediaInformation != null && status?.playerState != CastMediaPlayerState.idle))) {
      _clearDetached(detached);
    }
  }

  Future<void> _stopDetached(_DetachedMusicQueue detached) async {
    if (!_matchesDetached(detached) || detached.stopping) return;
    detached.stopping = true;
    try {
      await _remote.stop().timeout(const Duration(seconds: 5));
    } catch (error) {
      appLogger.d('Google Cast queue stop failed (${error.runtimeType})');
    } finally {
      detached.stopping = false;
    }
  }

  Future<bool> _stopMatchedReceiver({bool confirm = false}) async {
    if (!_matchesReceiver()) return false;
    if (_remote.mediaStatus?.playerState == CastMediaPlayerState.idle) return true;
    try {
      if (confirm) {
        final connection = _receiverKey;
        await loadAcknowledgedCastMedia(
          statuses: _remote.mediaStatusStream,
          acknowledge: (status) => status == null || status.playerState == CastMediaPlayerState.idle,
          invalidated: _sessions.currentSessionStream
              .where((session) => castReceiverKey(session) != connection)
              .map<void>((_) {}),
          load: _remote.stop,
          timeout: const Duration(seconds: 5),
        );
      } else {
        await _remote.stop().timeout(const Duration(seconds: 5));
      }
      return true;
    } catch (error) {
      appLogger.d('Google Cast stop failed (${error.runtimeType})');
      return false;
    }
  }

  String? _ownerToken(GoggleCastMediaStatus status) {
    final value = status.mediaInformation?.customData?['pleazyngOwner'];
    return value == null
        ? null
        : value is String
        ? value
        : '';
  }

  bool get isConnected => isSupportedPlatform && _sessions.hasConnectedSession;
  String? get deviceName => _deviceName ?? _sessions.currentSession?.device?.friendlyName;
  MediaItem? get activeItem => _activeItem;
  GoggleCastMediaStatus? get mediaStatus => _remote.mediaStatus;
  Duration get playerPosition => _remote.playerPosition;

  Future<void> initialize() async {
    if (_initialized || !isSupportedPlatform) return;
    const applicationId = GoogleCastDiscoveryCriteria.kDefaultApplicationId;
    final options = Platform.isAndroid
        ? GoogleCastOptionsAndroid(appId: applicationId, stopCastingOnAppTerminated: false)
        : IOSGoogleCastOptions(
            GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(applicationId),
            stopCastingOnAppTerminated: false,
          );
    await GoogleCastContext.instance.setSharedInstanceWithOptions(options);
    _sessionSubscription = _sessions.currentSessionStream.listen(_onSessionChanged);
    _statusSubscription = _remote.mediaStatusStream.listen(_onMediaStatusChanged);
    _queueSubscription = _remote.queueItemsStream.listen((_) => notifyListeners());
    _positionSubscription = _remote.playerPositionStream.listen((_) {
      if (!_replacingReceiver && _ownsReceiver() && _remote.mediaStatus?.playerState != CastMediaPlayerState.idle) {
        _lastOwnedPosition = _currentItemPosition();
      }
      notifyListeners();
    });
    _initialized = true;
  }

  Future<CastVideoPlayback?> moveActiveVideo(
    BuildContext context, {
    required MediaServerClient client,
    required MediaItem item,
    required int mediaIndex,
    required CastVideoSource source,
    String? mediaSourceId,
  }) async {
    if (!isSupportedPlatform || !source.isCurrent()) return null;
    await initialize();
    if (!context.mounted || !source.isCurrent()) return null;
    final device = await _pickDevice(context);
    if (device == null || !context.mounted || !source.isCurrent()) return null;
    return _startSessionAndLoad(
      device,
      client: client,
      item: item,
      mediaIndex: mediaIndex,
      mediaSourceId: mediaSourceId,
      source: source,
    );
  }

  Future<CastMusicOutput?> connectMusicOutput(BuildContext context, MultiServerManager serverManager) async {
    await initialize();
    final profile = _profileRevision;
    final intent = ++_loadIntent;
    bool current() => profile == _profileRevision && intent == _loadIntent;
    final device = _sessions.hasConnectedSession || !context.mounted ? null : await _pickDevice(context);
    if (!current() || !context.mounted || (device == null && !_sessions.hasConnectedSession)) return null;
    return _loads.run(() async {
      if (!current()) return null;
      if (device != null) {
        if (_activeItem != null && _matchesReceiver()) {
          if (!await _stopMatchedReceiver(confirm: true)) return null;
          await _finishPlayback(_lastOwnedPosition);
        }
        if (!current()) return null;
        if (!await _sessions.startSessionWithDevice(device)) {
          throw const CastPlaybackException('Could not connect to that Cast device.');
        }
        await _waitForConnection();
      }
      if (!current() || !_sessions.hasConnectedSession) return null;
      if (device != null && _sessions.currentSession?.device?.deviceID != device.deviceID) return null;
      final receiver = GoogleMusicCastReceiver();
      if (!receiver.connected) return null;
      return CastMusicOutput(
        name: device?.friendlyName ?? _sessions.currentSession?.device?.friendlyName ?? t.cast.chooseDevice,
        serverManager: serverManager,
        authorized: current,
        receiver: receiver,
      );
    });
  }

  Future<MusicTransferResult> transferMusicQueue(
    BuildContext context, {
    required MusicTransferSession session,
    required MultiServerManager manager,
    required bool Function() available,
  }) async {
    final profile = _profileRevision;
    await initialize();
    if (!context.mounted || !isSupportedPlatform || profile != _profileRevision || _profileId == null || !available()) {
      return MusicTransferResult.unavailable;
    }
    final intent = _loadIntent;
    bool selected() => profile == _profileRevision && intent == _loadIntent && available();
    final device = _sessions.hasConnectedSession ? null : await _pickDevice(context);
    if (!selected() || !context.mounted || (device == null && !_sessions.hasConnectedSession)) {
      return MusicTransferResult.unavailable;
    }
    return _loads.run(() async {
      _checkDetached();
      if (!selected() || _detached != null || _activeItem != null) return MusicTransferResult.unavailable;
      _DetachedMusicQueue? binding;
      var admitted = false;
      var abandoned = false;
      try {
        if (device != null) {
          if (!await _sessions.startSessionWithDevice(device).timeout(const Duration(seconds: 10))) {
            return MusicTransferResult.rejected;
          }
          await _waitForConnection();
        }
        final connection = castReceiverKey(_sessions.currentSession);
        if (!selected() || connection == null || (device != null && device.deviceID != connection.device)) {
          return MusicTransferResult.superseded;
        }
        bool idle() => _remote.mediaStatus == null || _remote.mediaStatus?.playerState == CastMediaPlayerState.idle;
        bool connected() => connection == castReceiverKey(_sessions.currentSession);
        final original = session.offerTransfer();
        if (!idle() || original == null) return MusicTransferResult.unavailable;

        MusicTransferOffer? latest() {
          if (abandoned || !selected() || !connected()) return null;
          final offer = session.offerTransfer();
          return offer != null &&
                  offer.session == original.session &&
                  offer.generation == original.generation &&
                  offer.edit == original.edit &&
                  offer.transport == original.transport &&
                  offer.snapshot.playing == original.snapshot.playing
              ? offer
              : null;
        }

        final queue = await CastMusicQueue.prepare(
          original.snapshot,
          manager: manager,
          token: generateSessionIdentifier(),
          current: () => latest() != null && idle(),
        ).timeout(const Duration(seconds: 25));
        final offer = latest();
        if (offer == null || !idle()) return MusicTransferResult.superseded;
        final prepared = _DetachedMusicQueue(queue, connection);
        binding = prepared;
        _detached = prepared;
        _detachedTimer = Timer.periodic(const Duration(seconds: 2), (_) => _checkDetached());
        admitted = await queue.handoff(
          offer: offer,
          current: () => prepared.retiredAt == null && latest() != null,
          status: () => _remote.mediaStatus,
          statuses: _remote.mediaStatusStream,
          invalidated: _sessions.currentSessionStream
              .where((value) => castReceiverKey(value) != connection)
              .map<void>((_) {}),
          load: (items, options) => dispatchCastQueue(items, options, android: Platform.isAndroid),
          play: _remote.play,
          armRepeat: (status) => queue.armRepeat(connection, status),
          finish: session.finishTransfer,
        );
        if (!admitted || prepared.retiredAt != null || !queue.authorized() || !_matchesDetached(prepared)) {
          admitted = false;
          return MusicTransferResult.superseded;
        }
        prepared.committed = true;
        final recovery = _musicRecovery;
        if (recovery != null && recovery.store.profileId == _profileId) {
          try {
            await recovery.save(queue, connection);
            if (!identical(_musicRecovery, recovery) || prepared.retiredAt != null) {
              await recovery.clear(token: queue.token);
            }
          } catch (error) {
            appLogger.d('Cast queue recovery save failed (${error.runtimeType})');
          }
        }
        notifyListeners();
        return MusicTransferResult.completed;
      } catch (error) {
        appLogger.d('Google Cast music queue handoff failed (${error.runtimeType})');
        return MusicTransferResult.rejected;
      } finally {
        abandoned = true;
        if (!admitted && binding != null) {
          binding.retire();
          _checkDetached();
        }
      }
    });
  }

  Future<MusicTransferResult> returnDetachedMusicQueue({
    required MusicDeviceSession session,
    required bool Function() available,
  }) => _loads.run(() async {
    final detached = _detached;
    if (detached == null || !canReturnDetachedMusicQueue || !available() || session.playback.isPlaying) {
      return MusicTransferResult.unavailable;
    }
    _returningDetached = true;
    notifyListeners();
    bool current() =>
        identical(_detached, detached) &&
        detached.retiredAt == null &&
        castReceiverKey(_sessions.currentSession) == detached.connection &&
        available();
    try {
      final accepted = await detached.queue.returnToLocal(
        current: current,
        status: () => _remote.mediaStatus,
        statuses: _remote.mediaStatusStream,
        invalidated: _sessions.currentSessionStream
            .where((value) => castReceiverKey(value) != detached.connection)
            .map<void>((_) {}),
        receiverItems: () => _remote.queueItems,
        position: () => _remote.playerPosition,
        pause: _remote.pause,
        resume: () async {
          if (!session.playback.isPlaying) await _remote.play();
        },
        prepare: (snapshot, current) => session.prepareMusicDeviceTransfer(snapshot, current: current),
      );
      if (!accepted) return MusicTransferResult.rejected;
      detached.retire();
      _checkDetached();
      return MusicTransferResult.completed;
    } catch (error) {
      appLogger.d('Google Cast queue return failed (${error.runtimeType})');
      return MusicTransferResult.rejected;
    } finally {
      _returningDetached = false;
      notifyListeners();
    }
  });

  Future<GoogleCastDevice?> _pickDevice(BuildContext context) async {
    await _discovery.startDiscovery(activeScan: Platform.isAndroid);
    try {
      if (!context.mounted) return null;
      return await showModalBottomSheet<GoogleCastDevice>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: SizedBox(
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                  child: Text(t.cast.chooseDevice, style: Theme.of(sheetContext).textTheme.titleLarge),
                ),
                Expanded(
                  child: StreamBuilder<List<GoogleCastDevice>>(
                    stream: _discovery.devicesStream,
                    initialData: _discovery.devices,
                    builder: (context, snapshot) {
                      final connected = _sessions.currentSession?.device;
                      final devices = [
                        if (connected != null && _sessions.hasConnectedSession) connected,
                        for (final device in snapshot.data ?? const <GoogleCastDevice>[])
                          if (device.deviceID != connected?.deviceID || !_sessions.hasConnectedSession) device,
                      ];
                      if (devices.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 16),
                              Text(t.cast.searching),
                            ],
                          ),
                        );
                      }
                      return ListView.builder(
                        itemCount: devices.length,
                        itemBuilder: (context, index) {
                          final device = devices[index];
                          return ListTile(
                            leading: const AppIcon(Symbols.cast_rounded),
                            title: Text(device.friendlyName),
                            subtitle: device.modelName == null ? null : Text(device.modelName!),
                            onTap: () => Navigator.of(context).pop(device),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      await _discovery.stopDiscovery();
    }
  }

  Future<CastVideoPlayback?> _startSessionAndLoad(
    GoogleCastDevice device, {
    required MediaServerClient client,
    required MediaItem item,
    required int mediaIndex,
    required CastVideoSource source,
    String? mediaSourceId,
  }) {
    final intent = ++_loadIntent;
    final profile = _profileRevision;
    final authentication = client.authenticationSessionId;
    bool accountCurrent() => profile == _profileRevision && identical(authentication, client.authenticationSessionId);
    bool current() => accountCurrent() && intent == _loadIntent && source.isCurrent();
    return _loads.run(() async {
      if (!current()) return null;
      final token = generateSessionIdentifier();
      final initialPosition = source.position();
      final parts = await prepareCastVideoParts(
        client: client,
        item: item,
        mediaIndex: mediaIndex,
        mediaSourceId: mediaSourceId,
        position: initialPosition,
        token: token,
        selectedSubtitle: source.selectedSubtitle,
        current: current,
      );
      if (!current()) return null;
      final previousDevice = _matchesReceiver() ? _sessions.currentSession?.device : null;
      final needsConnection = castReceiverKey(_sessions.currentSession)?.device != device.deviceID;
      late CastReceiverKey connection;
      var opened = false;
      var previousStopped = false;
      bool connected() => opened && castReceiverKey(_sessions.currentSession) == connection;
      final candidate = CastPlaybackOwnership()..begin(token, accountCurrent);
      final replacedAt = _ownsReceiver() ? _currentItemPosition() : _lastOwnedPosition;
      final previousPlaying =
          _remote.mediaStatus?.playerState == CastMediaPlayerState.playing ||
          _remote.mediaStatus?.playerState == CastMediaPlayerState.buffering;
      bool candidateMatches() {
        final status = _remote.mediaStatus;
        return connected() && status != null && candidate.matches(_ownerToken(status), status.mediaSessionID);
      }

      void checkCurrent() {
        if (!current() || !candidateMatches()) throw CastPlaybackException(t.cast.startFailed);
      }

      Future<bool> stopCandidate() async {
        if (!candidateMatches()) return false;
        try {
          await loadAcknowledgedCastMedia(
            statuses: _remote.mediaStatusStream,
            acknowledge: (status) => status == null || status.playerState == CastMediaPlayerState.idle,
            invalidated: _disconnected(connection),
            load: _remote.stop,
            timeout: const Duration(seconds: 5),
          );
          return true;
        } catch (_) {
          return false;
        }
      }

      _replacingReceiver = true;
      CastVideoPoint? committed;
      try {
        if (needsConnection) {
          // A sender controls a single receiver connection. Keep the reporting
          // session and prior queue while switching, so a failed B can restore A.
          if (_activeItem != null && previousDevice != null) {
            if (!await _stopMatchedReceiver(confirm: true)) throw CastPlaybackException(t.cast.startFailed);
            previousStopped = true;
          }
          if (!current() || !await _sessions.startSessionWithDevice(device)) {
            throw CastPlaybackException(t.cast.startFailed);
          }
          await _waitForConnection(device.deviceID);
        }
        final key = castReceiverKey(_sessions.currentSession);
        if (!current() || key == null || key.device != device.deviceID) throw CastPlaybackException(t.cast.startFailed);
        connection = key;
        opened = true;
        await _loadVideoQueue(parts, 0, initialPosition, candidate, connection);
        checkCurrent();
        final frozen = await commitPreparedCastVideo(
          source: source,
          positionReceiver: (position) async {
            checkCurrent();
            if (parts.first.target.partTimeline?.covers(position) == false) {
              throw CastPlaybackException(t.cast.startFailed);
            }
            if (position != initialPosition) {
              await _remote
                  .seek(GoogleCastMediaSeekOption(position: position - parts.first.start))
                  .timeout(const Duration(seconds: 10));
            }
            checkCurrent();
            if (_remote.mediaStatus?.playerState != CastMediaPlayerState.paused) {
              throw CastPlaybackException(t.cast.startFailed);
            }
          },
          playReceiver: () async {
            await loadAcknowledgedCastMedia(
              statuses: _remote.mediaStatusStream,
              invalidated: _disconnected(connection),
              acknowledge: (status) =>
                  current() &&
                  status != null &&
                  candidate.owns(_ownerToken(status), status.mediaSessionID) &&
                  status.playerState == CastMediaPlayerState.playing,
              load: _remote.play,
            );
            checkCurrent();
          },
          stopReceiver: stopCandidate,
        );
        committed = frozen;
        checkCurrent();
        // The current movie owns its reporting identity until the receiver acknowledges the replacement.
        await _ownership.replaceWith(
          candidate,
          finishPrevious: () => _finishPlayback(replacedAt),
          current: () => current() && candidateMatches(),
        );
        _receiverKey = connection;
        _deviceName = device.friendlyName;
        _activeItem = item;
        _activeClient = client;
        _parts = parts;
        _adoptPart(0);
        _duration = parts.first.target.partTimeline?.duration ?? parts.first.end;
        _lastPausedState = null;
        _lastOwnedPosition = frozen.position;
        notifyListeners();
        return CastVideoPlayback._(this, _ownership.revision, item.displayTitle, device.friendlyName, connection);
      } catch (_) {
        final candidateStopped = !candidateMatches() || await stopCandidate();
        if (committed?.playing == true && candidateStopped && source.isCurrent()) await source.restore();
        // A rejected LOAD may leave A running untouched. If the receiver
        // actually displaced A, restore it only on a receiver still ours/idle.
        if (_activeItem != null && (previousStopped || !_matchesReceiver())) {
          try {
            if (!_ownership.authorized || !candidateStopped || _parts.isEmpty) {
              throw StateError('The previous Cast session cannot be restored');
            }
            if (previousStopped && previousDevice != null) {
              if (castReceiverKey(_sessions.currentSession)?.device != previousDevice.deviceID) {
                if (!await _sessions.startSessionWithDevice(previousDevice)) throw StateError('Receiver unavailable');
                await _waitForConnection(previousDevice.deviceID);
              }
              final key = castReceiverKey(_sessions.currentSession);
              if (key == null || key.device != previousDevice.deviceID) throw StateError('Receiver changed');
              connection = key;
              opened = true;
            }
            final status = _remote.mediaStatus;
            final idle = status == null || status.playerState == CastMediaPlayerState.idle;
            if (!_ownership.authorized || !connected() || (!idle && !_matchesReceiver() && !candidateMatches())) {
              throw StateError('The receiver changed owners');
            }
            await _loadVideoQueue(_parts, _partIndex, replacedAt, _ownership, connection);
            _receiverKey = connection;
            if (previousPlaying && _ownsReceiver()) await _remote.play();
          } catch (_) {
            await _finishPlayback(replacedAt);
          }
        }
        rethrow;
      } finally {
        _replacingReceiver = false;
        notifyListeners();
      }
    });
  }

  Stream<void> _disconnected(CastReceiverKey connection) =>
      _sessions.currentSessionStream.where((session) => castReceiverKey(session) != connection).map<void>((_) {});

  Future<void> _loadVideoQueue(
    List<CastVideoPart> parts,
    int index,
    Duration position,
    CastPlaybackOwnership owner,
    CastReceiverKey connection,
  ) async {
    final part = parts[index];
    final offset = position - part.start;
    final items = [
      for (final (i, entry) in parts.indexed)
        GoogleCastQueueItem(
          mediaInformation: entry.item.mediaInformation,
          activeTrackIds: entry.item.activeTrackIds,
          autoPlay: i != index,
        ),
    ];
    await loadAcknowledgedCastMedia(
      statuses: _remote.mediaStatusStream,
      invalidated: _disconnected(connection),
      acknowledge: (status) =>
          status != null &&
          _statusPart(status) == index &&
          owner.acknowledgeQueueItem(_ownerToken(status), status.mediaSessionID) &&
          status.playerState == CastMediaPlayerState.paused,
      load: () => dispatchCastQueue(
        items,
        GoogleCastQueueLoadOptions(startIndex: index, playPosition: offset, repeatMode: GoogleCastMediaRepeatMode.off),
        android: Platform.isAndroid,
      ),
    );
  }

  int? _statusPart(GoggleCastMediaStatus? status) =>
      int.tryParse(status?.mediaInformation?.customData?['pleazyngPart']?.toString() ?? '');

  void _adoptPart(int index) {
    _nextPartTimer?.cancel();
    _nextPartTimer = null;
    _partIndex = index;
    final part = _parts[index];
    _partStart = part.start;
    _partEnd = part.end;
    _playSessionId = part.target.playSessionId ?? _parts.first.target.playSessionId;
  }

  Future<void> _waitForConnection([String? deviceId]) async {
    bool matches(GoogleCastSession? session) {
      final key = castReceiverKey(session);
      return key != null && (deviceId == null || key.device == deviceId);
    }

    if (matches(_sessions.currentSession)) return;
    await _sessions.currentSessionStream.firstWhere(matches).timeout(const Duration(seconds: 30));
  }

  void _beginProgressReporting() {
    final item = _activeItem;
    final client = _activeClient;
    final duration = _duration;
    if (item == null || client == null || !_ownership.authorized || _reporting) return;
    _reporting = true;

    if (duration != null && duration > Duration.zero) {
      _reportSession = PlaybackReportSession(
        client: client,
        itemId: item.id,
        playMethod: 'DirectPlay',
        playSessionId: _playSessionId,
      );
      if (_ownsReceiver()) unawaited(_reportPosition(_currentItemPosition(), isStopped: false));
    }
    unawaited(TrackerCoordinator.instance.startPlayback(item, client));
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_replacingReceiver || _nextPartTimer != null) return;
      if (_ownsReceiver()) {
        unawaited(_reportPosition(_currentItemPosition(), isStopped: false));
      } else {
        unawaited(_stopMatchedReceiver());
        _retirePlayback();
      }
    });
  }

  Duration _currentItemPosition() {
    return _parts.isEmpty ? _lastOwnedPosition : _parts[_partIndex].itemPosition(_remote.playerPosition);
  }

  CastVideoState? _videoState(int revision) {
    if (revision != _ownership.revision || _activeItem == null || _finishingPlayback || !_ownsReceiver()) return null;
    final status = _remote.mediaStatus!;
    if (status.playerState == CastMediaPlayerState.idle) return null;
    final duration = _duration ?? status.mediaInformation?.duration;
    return (
      position: _currentItemPosition(),
      duration: duration,
      seekStart: _partStart,
      seekEnd: _partEnd ?? duration,
      paused: status.playerState == CastMediaPlayerState.paused,
    );
  }

  Future<void> _controlVideo(int revision, Future<void> Function(CastVideoState) control) => _loads.run(() async {
    final state = _videoState(revision);
    if (state != null) await control(state).timeout(const Duration(seconds: 10));
  });

  Future<void> _reportPosition(Duration position, {required bool isStopped}) async {
    final item = _activeItem;
    final client = _activeClient;
    final duration = _duration;
    final reportSession = _reportSession;
    final sourceId = _parts.isEmpty ? null : _parts[_partIndex].target.mediaInfo?.mediaSourceId;
    final terminalPart = _partIndex == _parts.length - 1;
    final barrier = _previousPartStopped;
    if (barrier != null) {
      await barrier;
      if (!identical(_reportSession, reportSession) || !_ownership.authorized) return;
    }

    if (item == null || client == null || !_ownership.authorized) return;
    if (!isStopped && !_ownsReceiver()) return;
    final revision = _ownership.revision;
    bool current() => revision == _ownership.revision && _ownership.authorized;

    final clampedPosition = duration == null
        ? position
        : Duration(milliseconds: position.inMilliseconds.clamp(0, duration.inMilliseconds).toInt());
    final status = _remote.mediaStatus;
    final paused = status?.playerState == CastMediaPlayerState.paused;
    var stoppedReportSucceeded = false;
    if (_lastPausedState != null && _lastPausedState != paused) {
      if (paused) {
        unawaited(TrackerCoordinator.instance.pausePlayback());
      } else {
        unawaited(TrackerCoordinator.instance.resumePlayback());
      }
    }
    _lastPausedState = paused;
    TrackerCoordinator.instance.updatePosition(clampedPosition);

    if (reportSession != null && duration != null) {
      try {
        final delivered = await reportSession.report(
          PlaybackReportSnapshot(
            state: isStopped
                ? 'stopped'
                : paused
                ? 'paused'
                : 'playing',
            position: clampedPosition,
            duration: duration,
            resolveStreamSelection: () => PlaybackStreamSelection(mediaSourceId: sourceId),
          ),
        );
        if (isStopped) stoppedReportSucceeded = delivered;
        if (!isStopped && current() && delivered) {
          WatchStateNotifier().notifyProgress(
            item: item,
            cacheServerId: client.cacheServerId,
            viewOffset: clampedPosition.inMilliseconds,
            duration: duration.inMilliseconds,
            watchedThreshold: client.watchedThreshold,
            serverAcknowledged: true,
          );
        }
      } catch (error) {
        appLogger.d('Google Cast progress report failed (${error.runtimeType})');
      }
    }

    if (!isStopped ||
        !current() ||
        !stoppedReportSucceeded ||
        !terminalPart ||
        duration == null ||
        clampedPosition.inMilliseconds < duration.inMilliseconds * client.watchedThreshold) {
      return;
    }
    try {
      await client.markWatchedFromPlaybackStop(item);
      WatchStateNotifier().notifyWatched(item: item, cacheServerId: client.cacheServerId, serverAcknowledged: true);
      await TrackerCoordinator.instance.markWatched(item, client);
    } catch (error) {
      appLogger.d('Google Cast watched-state update failed (${error.runtimeType})');
    }
  }

  void _onSessionChanged(GoogleCastSession? session) {
    _checkDetached();
    _tryRecoverDetached();
    if (!_replacingReceiver && castReceiverKey(session) != _receiverKey && _activeItem != null && !_finishingPlayback) {
      _retirePlayback();
    }
    if (session?.device?.friendlyName case final String name) _deviceName = name;
    notifyListeners();
  }

  void _awaitNextPart() {
    _nextPartTimer ??= Timer(const Duration(seconds: 15), () {
      _nextPartTimer = null;
      if (_remote.mediaStatus?.playerState == CastMediaPlayerState.idle || !_ownsReceiver()) _retirePlayback();
    });
  }

  void _onMediaStatusChanged(GoggleCastMediaStatus? status) {
    _checkDetached();
    _tryRecoverDetached();
    if (_replacingReceiver) return;
    if (_activeItem != null) {
      if (status == null && _parts[_partIndex].hasNext && castReceiverKey(_sessions.currentSession) == _receiverKey) {
        _awaitNextPart();
        return;
      }
      final index = _statusPart(status);
      if (status != null &&
          index != null &&
          index >= 0 &&
          index < _parts.length &&
          _receiverKey == castReceiverKey(_sessions.currentSession) &&
          _ownership.acknowledgeQueueItem(_ownerToken(status), status.mediaSessionID) &&
          index != _partIndex) {
        final previous = _reportSession;
        final oldPart = _parts[_partIndex];
        final duration = _duration;
        final changesServerItem = _activeClient!.backend.usesMediaBrowserApi;
        if (changesServerItem && previous != null && duration != null) {
          final snapshot = PlaybackReportSnapshot(
            state: 'stopped',
            position: _lastOwnedPosition,
            duration: duration,
            resolveStreamSelection: () =>
                PlaybackStreamSelection(mediaSourceId: oldPart.target.mediaInfo?.mediaSourceId),
          );
          final revision = _ownership.revision;
          final pending = _previousPartStopped ?? Future<void>.value();
          _previousPartStopped = pending
              .then((_) async {
                if (_ownership.revision == revision && _ownership.authorized) await previous.report(snapshot);
              })
              .catchError((Object error) => appLogger.d('Cast part stop failed (${error.runtimeType})'));
        }
        _adoptPart(index);
        _lastOwnedPosition = _partStart;
        _lastPausedState = null;
        if (changesServerItem && _reporting) {
          _reportSession = PlaybackReportSession(
            client: _activeClient!,
            itemId: _activeItem!.id,
            playMethod: 'DirectPlay',
            playSessionId: _playSessionId,
          );
        }
      }
      if (!_ownsReceiver()) {
        _progressTimer?.cancel();
        unawaited(_stopMatchedReceiver());
        _retirePlayback();
        return;
      }
      if (status?.playerState != CastMediaPlayerState.idle) {
        _nextPartTimer?.cancel();
        _nextPartTimer = null;
        _lastOwnedPosition = _currentItemPosition();
      }
      if (status?.playerState == CastMediaPlayerState.idle &&
          status?.idleReason != null &&
          status?.idleReason != GoogleCastMediaIdleReason.none) {
        if (status?.idleReason == GoogleCastMediaIdleReason.finished && _partEnd != null) {
          _lastOwnedPosition = _partEnd!;
          if (_parts[_partIndex].hasNext) {
            // The receiver queue advances by itself. Its FINISHED belongs to
            // the current file. Keep the item session for the next status.
            _awaitNextPart();
            notifyListeners();
            return;
          }
        }
        _retirePlayback();
      } else if ((status?.playerState == CastMediaPlayerState.playing ||
              status?.playerState == CastMediaPlayerState.paused) &&
          _lastPausedState != (status?.playerState == CastMediaPlayerState.paused)) {
        unawaited(_reportPosition(_currentItemPosition(), isStopped: false));
      }
    }
    notifyListeners();
  }

  Future<void> _finishPlayback(Duration position) async {
    if (_finishingPlayback || _activeItem == null) return;
    _finishingPlayback = true;
    try {
      _progressTimer?.cancel();
      _progressTimer = null;
      if (_ownership.authorized) await _reportPosition(position, isStopped: true);
      await TrackerCoordinator.instance.stopPlayback();
      _reportSession = null;
      _reporting = false;
      _parts = const [];
      _partIndex = 0;
      _nextPartTimer?.cancel();
      _nextPartTimer = null;
      _previousPartStopped = null;
      _activeItem = null;
      _activeClient = null;
      _playSessionId = null;
      _partStart = Duration.zero;
      _partEnd = null;
      _duration = null;
      _lastPausedState = null;
      _ownership.clear();
      _receiverKey = null;
      notifyListeners();
    } finally {
      _finishingPlayback = false;
    }
  }

  Future<void> showControls(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => AnimatedBuilder(
        animation: this,
        builder: (context, _) {
          final status = _remote.mediaStatus;
          final detached = hasDetachedMusicQueue;
          final metadata = status?.mediaInformation?.metadata;
          final isPaused = status?.playerState == CastMediaPlayerState.paused;
          final isPlaying =
              status?.playerState == CastMediaPlayerState.playing ||
              status?.playerState == CastMediaPlayerState.buffering;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.cast.connectedTo(device: deviceName ?? t.cast.device),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _activeItem?.displayTitle ??
                        (detached && metadata is GoogleCastGenericMediaMetadata ? metadata.title : null) ??
                        t.cast.readyToCast,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 18),
                  StreamBuilder<Duration>(
                    stream: _remote.playerPositionStream,
                    initialData: _remote.playerPosition,
                    builder: (context, snapshot) {
                      final position = _partStart + (snapshot.data ?? Duration.zero);
                      final duration = detached ? status?.mediaInformation?.duration : _duration;
                      return Text(
                        duration == null
                            ? _formatDuration(position)
                            : '${_formatDuration(position)} / ${_formatDuration(duration)}',
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      IconButton.filledTonal(
                        tooltip: isPaused ? t.common.resume : t.common.pause,
                        onPressed: !(_ownsReceiver() || detached && !_returningDetached) || !isPaused && !isPlaying
                            ? null
                            : () {
                                if (_ownsReceiver() || canReturnDetachedMusicQueue) {
                                  unawaited(isPaused ? _remote.play() : _remote.pause());
                                }
                              },
                        icon: AppIcon(isPaused ? Symbols.play_arrow_rounded : Symbols.pause_rounded),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: t.cast.stopCasting,
                        onPressed: () async {
                          final queue = _detached;
                          if (canReturnDetachedMusicQueue && queue != null) {
                            queue.retire();
                            await _stopDetached(queue);
                            if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                            return;
                          }
                          if (!_ownsReceiver()) return;
                          final status = _remote.mediaStatus!;
                          final token = _ownerToken(status);
                          final profile = _profileRevision;
                          await _remote.stop();
                          final current = _remote.mediaStatus;
                          if (profile == _profileRevision &&
                              current != null &&
                              current.mediaSessionID == status.mediaSessionID &&
                              _ownerToken(current) == token) {
                            await _sessions.endSessionAndStopCasting();
                          }
                          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                        },
                        icon: const AppIcon(Symbols.stop_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static String _formatDuration(Duration value) {
    String two(int number) => number.toString().padLeft(2, '0');
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    return hours > 0 ? '$hours:${two(minutes)}:${two(seconds)}' : '$minutes:${two(seconds)}';
  }

  @override
  void dispose() {
    _loadIntent++;
    _ownership.clear();
    _progressTimer?.cancel();
    _detachedTimer?.cancel();
    _detached = null;
    unawaited(_recoveryConnections?.cancel());
    unawaited(_sessionSubscription?.cancel());
    unawaited(_statusSubscription?.cancel());
    unawaited(_queueSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    super.dispose();
  }
}

typedef CastVideoState = ({Duration position, Duration? duration, Duration seekStart, Duration? seekEnd, bool paused});

/// A controller for the one receiver session acknowledged during handoff.
/// Receiver changes are observed by both the phone and the receiver's UI.
class CastVideoPlayback {
  const CastVideoPlayback._(this._service, this._revision, this.title, this.deviceName, this._connection);

  final CastMediaService _service;
  final int _revision;
  final CastReceiverKey _connection;
  final String title;
  final String deviceName;

  Listenable get changes => _service;
  CastVideoState? get state => _service._videoState(_revision);
  bool get connected => _revision == _service._ownership.revision
      ? (_service._replacingReceiver ||
            (_service._receiverKey != null &&
                castReceiverKey(_service._sessions.currentSession) == _service._receiverKey))
      : castReceiverKey(_service._sessions.currentSession) == _connection;

  void startReporting() {
    if (_revision == _service._ownership.revision && _service._activeItem != null) _service._beginProgressReporting();
  }

  Future<void> toggle() =>
      _service._controlVideo(_revision, (state) => state.paused ? _service._remote.play() : _service._remote.pause());

  Future<void> seek(Duration position) => _service._controlVideo(_revision, (state) async {
    final end = state.seekEnd;
    if (end == null) return;
    final offset = (position - state.seekStart).inMilliseconds.clamp(0, (end - state.seekStart).inMilliseconds);
    await _service._remote.seek(GoogleCastMediaSeekOption(position: Duration(milliseconds: offset.toInt())));
  });

  Future<void> stop() => _service._controlVideo(_revision, (_) async {
    if (!await _service._stopMatchedReceiver(confirm: true)) throw CastPlaybackException(t.cast.startFailed);
  });
}

class _DetachedMusicQueue {
  _DetachedMusicQueue(this.queue, this.connection);

  final CastMusicQueue queue;
  final CastReceiverKey connection;
  DateTime? retiredAt;
  bool committed = false;
  bool stopping = false;

  void retire() => retiredAt ??= DateTime.now();
}

class CastPlaybackException implements Exception {
  const CastPlaybackException(this.message);
  final String message;
}

part of '../music_playback_service_impl.dart';

extension _MusicPlaybackOverlap on MusicPlaybackServiceImpl {
  bool get _sweetFadesEnabled =>
      _playbackOutput == null && (SettingsService.instanceOrNull?.read(SettingsService.musicSweetFades) ?? false);

  bool _overlapCurrent(Player outgoing, _ArmedTrack incoming, int generation, int revision) =>
      !_disposed &&
      _sweetFadesEnabled &&
      _player == outgoing &&
      _generation == generation &&
      _queueEditRevision == revision &&
      identical(_armed, incoming) &&
      _status == MusicPlaybackStatus.playing &&
      !_sleepTimerEndOfTrack &&
      automotiveMusicPlaybackAllowedNow();

  void _tryStartOverlap(Duration position, Duration trackDuration) {
    final outgoing = _player;
    final incoming = _armed;
    if (outgoing == null ||
        incoming == null ||
        (outgoing is! PlayerNative && _overlapPlayerFactory == null) ||
        _overlap != null ||
        _overlapStartingPlayer != null ||
        _overlapAttemptedGeneration == _generation ||
        _status != MusicPlaybackStatus.playing ||
        !outgoing.state.isActive ||
        _sleepTimerEndOfTrack ||
        outgoing.audioPassthroughActive ||
        !_workspaceAudioEnabled ||
        trackDuration - position > const Duration(milliseconds: 1800)) {
      return;
    }
    final nextDuration = incoming.track.durationMs;
    final key = _loudnessProfileCacheKey(incoming.source, incoming.track);
    final nextProfile = key == null ? null : _loadedLoudnessProfiles[key];
    if (nextProfile == null ||
        nextDuration == null ||
        nextDuration < 6000 ||
        (nextProfile.levelAt(const Duration(milliseconds: 300), Duration(milliseconds: nextDuration)) ?? -100) <= -48) {
      return;
    }
    _overlapAttemptedGeneration = _generation;
    unawaited(
      _startOverlap(outgoing, incoming, _generation, _queueEditRevision).catchError((Object error) {
        appLogger.d('Music overlap decoder unavailable', error: error);
      }),
    );
  }

  Future<void> _startOverlap(Player outgoing, _ArmedTrack incoming, int generation, int editRevision) async {
    final revision = _overlapRevision;
    final useOverlapCore = !_primaryUsesOverlapCore;
    final player =
        _overlapPlayerFactory?.call(useOverlapCore) ??
        (useOverlapCore ? PlayerNative.audio(overlap: true, exclusiveAudio: Platform.isIOS) : _audioPlayerFactory());
    _overlapStartingPlayer = player;
    bool current() => revision == _overlapRevision && _overlapCurrent(outgoing, incoming, generation, editRevision);
    try {
      await player.setWorkspaceAudioFocusEnabled(false);
      await player.setVolume(0);
      if (!Platform.isIOS) await player.setProperty('audio-exclusive', 'no');
      await _applyAudioOutputDevice(player);
      // Each decoder owns its own processing state. Do not let the spare core
      // update the primary core's output EQ signature while it is loading.
      final policy = _audioPolicy;
      if (policy != null) {
        await policy.apply(
          player,
          albumContext: _albumLevelingContext,
          source: incoming.source.mediaInfo,
          isCurrent: current,
        );
      } else {
        final settings = SettingsService.instanceOrNull;
        if (settings != null) {
          await player.setAudioNormalization(settings.read(SettingsService.audioNormalization));
          if (player is AudioEqualizerCapable) {
            await (player as AudioEqualizerCapable).setAudioEqualizer([
              for (final pref in SettingsService.audioEqualizerBandPrefs) settings.read(pref),
            ]);
          }
        }
      }
      if (_libraryStore != null && _calderaSource == null && player is AudioEqualizerCapable) {
        final output = await player.getProperty('audio-device') ?? 'auto';
        final eq = await outputEqualizer(output);
        if (eq != null) {
          await player.setAudioPassthrough(false);
          await (player as AudioEqualizerCapable).setAudioEqualizer(eq.bands);
        }
      }
      if (!current()) return;
      await _restoreNativeEqualizerForPlayback(player);
      if (!current()) return;
      final nativeSource = _calderaSource;
      if (nativeSource != null) {
        await nativeSource.prepareFeed(_nativePcmFeed(player, nativeSource, primary: false));
        if (!current()) return;
      }
      await player.open(_musicMedia(incoming.source));
      if (!current()) return;
      // The outgoing playlist must stop at this file. Keep its arm until the
      // second source has opened, so a slow/failed decoder stays gapless.
      if (!await _trySetNext(outgoing, null)) return;
      if (!current()) {
        if (_player == outgoing && _generation == generation) {
          _rememberStaleArm();
          _requestArmNext();
        }
        return;
      }
      _rememberStaleArm();
      _overlap = _MusicOverlap(player, incoming, generation, editRevision, useOverlapCore);
      _overlapStartingPlayer = null;
      _updateSweetFade(outgoing.currentPosition);
    } catch (error, stackTrace) {
      appLogger.w('Music overlap unavailable; keeping gapless playback', error: error, stackTrace: stackTrace);
    } finally {
      if (identical(_overlapStartingPlayer, player)) {
        _overlapStartingPlayer = null;
        unawaited(_disposeOverlapPlayer(player));
      }
    }
  }

  Future<void> _disposeOverlapPlayer(Player player) async {
    try {
      await player.setVolume(0);
      await player.stop();
      await player.abandonAudioFocus();
      await player.dispose();
    } catch (error) {
      appLogger.d('Music overlap decoder teardown failed', error: error);
      if (!player.disposed) unawaited(player.dispose());
    }
  }

  void _cancelOverlap() {
    _overlapRevision++;
    final starting = _overlapStartingPlayer;
    _overlapStartingPlayer = null;
    final active = _overlap;
    _overlap = null;
    if (starting != null) unawaited(_disposeOverlapPlayer(starting));
    if (active != null) {
      unawaited(_disposeOverlapPlayer(active.player));
      _setMusicGain(1, force: true);
      _requestArmNext();
    }
  }

  void _promoteOverlap(_MusicOverlap overlap) {
    final outgoing = _player;
    if (!identical(_overlap, overlap) || outgoing == null) return;
    _overlap = null;
    _overlapRevision++;
    if (_disposed ||
        _generation != overlap.generation ||
        _queueEditRevision != overlap.editRevision ||
        !automotiveMusicPlaybackAllowedNow() ||
        !overlap.player.state.isActive) {
      unawaited(_disposeOverlapPlayer(overlap.player));
      _setMusicGain(1, force: true);
      _requestArmNext();
      return;
    }
    final nextIndex = _queue.nextIndex();
    if (nextIndex == null || _queue.trackAt(nextIndex)?.globalKey != overlap.incoming.track.globalKey) {
      unawaited(_disposeOverlapPlayer(overlap.player));
      _setMusicGain(1, force: true);
      _requestArmNext();
      return;
    }
    _generation++;
    _invalidateArmRequests();
    _launchObserver?.detach();
    final finishedMs = _currentTrack?.durationMs;
    _finalizeCurrentTrack(
      positionOverride: finishedMs == null ? outgoing.currentPosition : Duration(milliseconds: finishedMs),
    );
    _queue.jumpTo(nextIndex);
    _player = overlap.player;
    _primaryUsesOverlapCore = overlap.usesOverlapCore;
    _outputEqSignature = null;
    _outputEqualizer = null;
    _wirePlayerStreams(overlap.player);
    _currentTrack = _queue.current;
    _currentSource = overlap.incoming.source;
    _armed = null;
    _staleArm = null;
    _musicGain = 0;
    _setMusicGain(1, force: true);
    _persistSessionProgress(positionOverride: overlap.player.currentPosition);
    _setStatus(MusicPlaybackStatus.playing, forceNotify: true);
    _bindTrackServices(_currentTrack!, overlap.incoming.source);
    _requestArmNext();
    unawaited(() async {
      try {
        await overlap.player.setWorkspaceAudioFocusEnabled(_workspaceAudioEnabled);
        if (_player == overlap.player && !_disposed && _workspaceAudioEnabled) {
          await overlap.player.requestAudioFocus();
        }
      } catch (error) {
        appLogger.w('Music overlap focus handoff failed', error: error);
      } finally {
        await _disposeOverlapPlayer(outgoing);
      }
    }());
  }

  void _onSweetFadesPreferenceChanged() {
    if (_disposed) {
      return;
    }
    if (!_sweetFadesEnabled) {
      _cancelOverlap();
      _fadeCurrentTrackIn = false;
      _setMusicGain(1, force: true);
    } else {
      final currentPlayer = _player;
      if (currentPlayer != null && !Platform.isIOS) {
        unawaited(
          currentPlayer.setProperty('audio-exclusive', 'no').catchError((Object error) {
            appLogger.d('Music output cannot enable decoded overlap', error: error);
          }),
        );
      }
      final source = _currentSource;
      final track = _currentTrack;
      if (source != null && track != null) {
        unawaited(
          _loadLoudnessProfile(source, track).then((profile) {
            if (_disposed || !identical(_currentSource, source)) {
              return;
            }
            _currentLoudnessProfile = profile;
            _updateSweetFade(_player?.currentPosition ?? Duration.zero);
          }),
        );
      }
      final armed = _armed;
      if (armed != null) {
        unawaited(_loadLoudnessProfile(armed.source, armed.track));
      }
      _updateSweetFade(_player?.currentPosition ?? Duration.zero);
    }
  }

  void _updateSweetFade(Duration position) {
    final source = _currentSource;
    final profile = _currentLoudnessProfile;
    if (!_sweetFadesEnabled ||
        _preserveAlbumGapless ||
        source == null ||
        _player?.audioPassthroughActive == true ||
        profile == null) {
      _fadeCurrentTrackIn = false;
      _setMusicGain(1);
      return;
    }

    final trackDuration = duration ?? Duration.zero;
    const fadeDuration = Duration(milliseconds: 1800);
    if (trackDuration < const Duration(seconds: 6)) {
      _fadeCurrentTrackIn = false;
      _setMusicGain(1);
      return;
    }

    final overlap = _overlap;
    if (overlap != null) {
      final remaining = trackDuration - position;
      final progress = (1 - remaining.inMicroseconds / fadeDuration.inMicroseconds).clamp(0.0, 1.0).toDouble();
      _setMusicGain(cos(progress * pi / 2));
      unawaited(overlap.player.setVolume(_musicVolume(overlap.player, gain: _outputGain * sin(progress * pi / 2))));
      return;
    }
    _tryStartOverlap(position, trackDuration);
    if (_overlapStartingPlayer != null) {
      _setMusicGain(1);
      return;
    }

    final headLevel = profile.levelAt(const Duration(milliseconds: 300), trackDuration);
    final tailPosition = trackDuration - const Duration(milliseconds: 300);
    final tailLevel = profile.levelAt(tailPosition, trackDuration);
    var gain = 1.0;

    if (_fadeCurrentTrackIn) {
      if (headLevel == null || headLevel <= -48) {
        _fadeCurrentTrackIn = false;
      } else if (position < fadeDuration) {
        final progress = (position.inMicroseconds / fadeDuration.inMicroseconds).clamp(0.0, 1.0).toDouble();
        gain = sin(progress * pi / 2);
      } else {
        _fadeCurrentTrackIn = false;
      }
    }

    final hasNextTrack = !_sleepTimerEndOfTrack && _queue.nextIndex() != null;
    if (hasNextTrack && tailLevel != null && tailLevel > -48) {
      final remaining = trackDuration - position;
      if (remaining < fadeDuration) {
        final progress = (remaining.inMicroseconds / fadeDuration.inMicroseconds).clamp(0.0, 1.0).toDouble();
        gain = min(gain, sin(progress * pi / 2));
      }
    }
    _setMusicGain(gain);
  }
}

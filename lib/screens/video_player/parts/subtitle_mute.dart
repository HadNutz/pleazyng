part of '../../video_player_screen.dart';

extension _VideoSubtitleMuteMethods on VideoPlayerScreenState {
  /// Announce an accepted user volume command with the top pill, whatever the
  /// chrome state. The visible chrome does render volume, but as a 100 px
  /// slider that moves 3 % per wheel notch: a viewer on a handheld scrolled
  /// themselves to silence without noticing (#2357). Every input reaches
  /// here — wheel, shortcut keys, the OSD slider, companion remote — while
  /// volume the player reports on its own never does.
  void _handleSubtitleMuteVolume(double volume) {
    if (!volume.isFinite) {
      return;
    }
    final generation = ++_subtitleMuteGeneration;
    if (volume <= 0) {
      if (SettingsService.instance.read(SettingsService.subtitleOnMute)) {
        unawaited(_selectSubtitleForMute(generation));
      }
    } else {
      unawaited(_restoreSubtitleAfterMute(generation));
    }
  }

  Future<void> _selectSubtitleForMute(int generation) async {
    if (_subtitleMuteRestore != null || !mounted || generation != _subtitleMuteGeneration) {
      return;
    }
    final currentPlayer = player;
    final manager = _trackManager;
    if (currentPlayer == null ||
        manager == null ||
        !manager.isActive() ||
        !identical(manager.player, currentPlayer) ||
        manager.primarySubtitleIsServerRendered) {
      return;
    }

    final state = currentPlayer.state;
    final previouslySelected = state.track.subtitle;
    if (previouslySelected != null && previouslySelected.id != SubtitleTrack.off.id) {
      return;
    }

    final tracks = state.tracks.subtitle;
    if (tracks.isEmpty) {
      return;
    }
    final settings = SettingsService.instance;
    final profile = manager.getProfileSettings();
    if (profile?.subtitleMode == SubtitlePlaybackMode.none) {
      return;
    }

    final resolver = TrackSelectionService(
      player: currentPlayer,
      profileSettings: profile,
      metadata: manager.metadata,
      plexMediaInfo: manager.mediaInfo,
      alwaysShowSubtitlesOnDevice: settings.read(SettingsService.alwaysShowSubtitlesOnDevice),
    );
    var candidate = resolver
        .selectSubtitleTrack(tracks, manager.preferredSubtitleTrack, state.track.audio, waitForPendingSource: false)
        ?.track;

    if (candidate == null || candidate.id == SubtitleTrack.off.id || candidate.id == SubtitleTrack.auto.id) {
      final selectable = tracks
          .where((track) => track.id != SubtitleTrack.off.id && track.id != SubtitleTrack.auto.id)
          .where((track) => profile?.subtitleMode != SubtitlePlaybackMode.onlyForced || track.effectiveForced)
          .toList(growable: false);
      if (selectable.isEmpty) {
        return;
      }

      final preferredLanguage = profile?.defaultSubtitleLanguage?.trim();
      final audioLanguage = state.track.audio?.language?.trim();
      final language = preferredLanguage?.isNotEmpty == true ? preferredLanguage : audioLanguage;
      if (language?.isNotEmpty == true) {
        for (final track in selectable) {
          if (resolver.languageMatches(track.language, language)) {
            candidate = track;
            break;
          }
        }
      }
      candidate ??= selectable.where((track) => track.isDefault && !track.effectiveForced).firstOrNull;
      candidate ??= selectable.where((track) => !track.effectiveForced).firstOrNull;
      candidate ??= selectable.first;
    }

    if (candidate.id == previouslySelected?.id ||
        !mounted ||
        generation != _subtitleMuteGeneration ||
        !identical(player, currentPlayer)) {
      return;
    }

    final restore = _SubtitleMuteRestore(
      player: currentPlayer,
      mediaIdentity: manager.metadata.globalKey,
      previousTrack: previouslySelected ?? SubtitleTrack.off,
      temporaryTrackId: candidate.id,
    );
    _subtitleMuteRestore = restore;
    await _queueSubtitleMuteTrack(currentPlayer, candidate, generation);
    if (generation != _subtitleMuteGeneration && identical(_subtitleMuteRestore, restore)) {
      _subtitleMuteRestore = null;
    }
  }

  Future<void> _restoreSubtitleAfterMute(int generation) async {
    final restore = _subtitleMuteRestore;
    if (restore == null) {
      return;
    }
    _subtitleMuteRestore = null;
    final manager = _trackManager;
    if (!mounted ||
        generation != _subtitleMuteGeneration ||
        !identical(player, restore.player) ||
        manager == null ||
        manager.metadata.globalKey != restore.mediaIdentity) {
      return;
    }
    await _queueSubtitleMuteTrack(
      restore.player,
      restore.previousTrack,
      generation,
      expectedCurrentTrackId: restore.temporaryTrackId,
    );
  }

  Future<void> _queueSubtitleMuteTrack(
    Player targetPlayer,
    SubtitleTrack track,
    int generation, {
    String? expectedCurrentTrackId,
  }) async {
    _subtitleMuteSelectionPending = true;
    final previous = _subtitleMuteSelectionQueue;
    final operation = previous.catchError((Object _, StackTrace _) {}).then((_) async {
      if (!mounted || generation != _subtitleMuteGeneration || !identical(player, targetPlayer)) {
        return;
      }
      if (expectedCurrentTrackId != null && targetPlayer.state.track.subtitle?.id != expectedCurrentTrackId) {
        return;
      }
      await targetPlayer.selectSubtitleTrack(track);
    });
    _subtitleMuteSelectionQueue = operation.catchError((Object error, StackTrace stackTrace) {
      appLogger.w('Temporary subtitle selection failed', error: error, stackTrace: stackTrace);
    });
    await _subtitleMuteSelectionQueue;
    if (generation == _subtitleMuteGeneration) {
      _subtitleMuteSelectionPending = false;
    }
  }

  void _attachSubtitleMuteVolumeListener(VideoVolumeController controller) {
    _detachSubtitleMuteVolumeListener(controller);
    void listener() => _handleSubtitleMuteVolume(controller.value);
    _subtitleMuteVolumeListener = listener;
    controller.addListener(listener);
    final currentPlayer = player;
    if (currentPlayer != null && controller.ownsPlayer(currentPlayer)) {
      _attachSubtitleMuteTrackCatalogListener(currentPlayer);
    }
    _handleSubtitleMuteVolume(controller.value);
  }

  void _attachSubtitleMuteTrackCatalogListener(Player currentPlayer) {
    if (identical(_subtitleMuteTrackCatalogPlayer, currentPlayer)) {
      return;
    }
    _detachSubtitleMuteTrackCatalogListener();
    _subtitleMuteTrackCatalogPlayer = currentPlayer;
    _subtitleMuteTrackCatalogSubscription = currentPlayer.streams.tracks.listen((tracks) {
      final volume = _volumeController?.value;
      if (tracks.subtitle.isEmpty ||
          volume == null ||
          volume > 0 ||
          !SettingsService.instance.read(SettingsService.subtitleOnMute)) {
        return;
      }
      _handleSubtitleMuteVolume(volume);
    });
  }

  void _detachSubtitleMuteTrackCatalogListener([Player? expectedPlayer]) {
    if (expectedPlayer != null && !identical(_subtitleMuteTrackCatalogPlayer, expectedPlayer)) {
      return;
    }
    _subtitleMuteTrackCatalogPlayer = null;
    unawaited(_subtitleMuteTrackCatalogSubscription?.cancel());
    _subtitleMuteTrackCatalogSubscription = null;
  }

  void _detachSubtitleMuteVolumeListener(VideoVolumeController controller) {
    final listener = _subtitleMuteVolumeListener;
    if (listener == null) {
      return;
    }
    controller.removeListener(listener);
    _subtitleMuteVolumeListener = null;
  }

  void _cancelSubtitleMuteRestoreForUserChoice(SubtitleTrack track) {
    final shouldReapply = _subtitleMuteSelectionPending;
    final targetPlayer = player;
    final generation = ++_subtitleMuteGeneration;
    _subtitleMuteRestore = null;
    if (shouldReapply && targetPlayer != null) {
      unawaited(_queueSubtitleMuteTrack(targetPlayer, track, generation));
    }
  }
}

part of '../source_playback.dart';

extension _SourceExternalSubtitles on SourcePlayback {
  String _subtitleAudioIdentity(Player native) {
    final audio = native.state.track.audio;
    final descriptor = audio == null
        ? const ['no-selected-audio']
        : [
            audio.id,
            audio.language?.trim().toLowerCase() ?? '',
            audio.title?.trim() ?? '',
            audio.codec?.trim().toLowerCase() ?? '',
            audio.channels ?? 0,
            audio.sampleRate ?? 0,
          ];
    return sha256.convert(utf8.encode(jsonEncode(descriptor))).toString();
  }

  ({int delayMs, double rate}) _subtitleSyncForAudio(Map<String, dynamic> syncByAudio, String audioIdentity) {
    final raw = syncByAudio[audioIdentity] ?? syncByAudio['legacy'];
    if (raw is! Map) {
      return (delayMs: 0, rate: 1.0);
    }
    final values = Map<String, dynamic>.from(raw);
    final rawDelay = values['delayMs'];
    final rawRate = values['rate'];
    if (rawDelay is! int || rawRate is! num) {
      return (delayMs: 0, rate: 1.0);
    }
    final delayMs = rawDelay;
    final rate = rawRate.toDouble();
    if (delayMs < ScopedPlayerPrefs.minimumSyncOffsetMs ||
        delayMs > ScopedPlayerPrefs.maximumSyncOffsetMs ||
        !rate.isFinite ||
        rate < ScopedPlayerPrefs.minimumSubtitleSyncRate ||
        rate > ScopedPlayerPrefs.maximumSubtitleSyncRate) {
      return (delayMs: 0, rate: 1.0);
    }
    return (delayMs: delayMs, rate: rate);
  }

  String _externalSubtitleSyncBinding(Player native, String path) =>
      '${_subtitleAudioIdentity(native)}|${native.state.track.subtitle?.id ?? 'off'}|$path';

  Future<void> _reapplySelectedExternalSubtitleSyncForCurrentTrack() async {
    await _commands;
    if (opening) {
      return;
    }
    final native = player;
    final item = entry;
    final profile = _profile;
    if (native == null ||
        item == null ||
        profile == null ||
        _fileIndex < 0 ||
        _fileIndex >= files.length ||
        _selectedExternalSubtitlePath == null) {
      return;
    }
    await _reapplyExternalSubtitleSyncForTrackChange(
      native: native,
      item: item,
      publicationFile: files[_fileIndex],
      fileIndex: _fileIndex,
      profile: profile,
      edition: progress?.edition,
      generation: _generation,
      fileEpoch: _fileEpoch,
    );
  }

  Future<void> _reapplyExternalSubtitleSyncForTrackChange({
    required Player native,
    required SourceEntry item,
    required PublicationFile publicationFile,
    required int fileIndex,
    required String profile,
    required String? edition,
    required int generation,
    required int fileEpoch,
  }) async {
    final path = _selectedExternalSubtitlePath;
    if (path == null ||
        !_isSelectedExternalSubtitlePath(native.state.track.subtitle, path) ||
        !_isCurrentExternalSubtitleScope(
          native: native,
          item: item,
          publicationFile: publicationFile,
          fileIndex: fileIndex,
          profile: profile,
          edition: edition,
          generation: generation,
          fileEpoch: fileEpoch,
        )) {
      return;
    }
    final binding = _externalSubtitleSyncBinding(native, path);
    if (binding == _activeExternalSubtitleSyncBinding || edition == null) {
      return;
    }
    final directory = _externalSubtitleAssetDirectory(
      profile: profile,
      item: item,
      edition: edition,
      publicationFile: publicationFile,
    );
    final manifest = await _readExternalSubtitleManifest(
      directory: directory,
      item: item,
      edition: edition,
      publicationFile: publicationFile,
    );
    if (manifest == null) {
      return;
    }
    final selected = manifest['selected'];
    for (final asset in manifest['assets'] as List<Map<String, dynamic>>) {
      if (asset['slot'] != selected || asset['file'] != p.basename(path)) {
        continue;
      }
      final sync = _subtitleSyncForAudio(asset['syncByAudio'] as Map<String, dynamic>, _subtitleAudioIdentity(native));
      if (!_isCurrentExternalSubtitleScope(
            native: native,
            item: item,
            publicationFile: publicationFile,
            fileIndex: fileIndex,
            profile: profile,
            edition: edition,
            generation: generation,
            fileEpoch: fileEpoch,
          ) ||
          !_isSelectedExternalSubtitlePath(native.state.track.subtitle, path)) {
        return;
      }
      try {
        await _applyExternalSubtitleSync(native, delayMs: sync.delayMs, rate: sync.rate);
        _activeExternalSubtitleSyncBinding = binding;
        _notify();
      } on Object catch (error, stackTrace) {
        appLogger.w(
          'Could not apply saved subtitle timing for the selected audio',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return;
    }
  }

  bool _isSelectedExternalSubtitlePath(SubtitleTrack? track, String? path) {
    if (track == null || !track.isExternal || path == null || track.uri == null) {
      return false;
    }
    final actual = track.uri!;
    if (actual == path || actual == File(path).uri.toString()) {
      return true;
    }
    final uri = Uri.tryParse(actual);
    return uri != null && uri.scheme == 'file' && File.fromUri(uri).absolute.path == path;
  }

  Future<void> _applyExternalSubtitleSync(Player native, {required int delayMs, required double rate}) async {
    if (native.playerType != 'mpv' ||
        delayMs < ScopedPlayerPrefs.minimumSyncOffsetMs ||
        delayMs > ScopedPlayerPrefs.maximumSyncOffsetMs ||
        !rate.isFinite ||
        rate < ScopedPlayerPrefs.minimumSubtitleSyncRate ||
        rate > ScopedPlayerPrefs.maximumSubtitleSyncRate) {
      throw const SourceException(SourceFailure.unsupported);
    }
    await native.setProperty(PlayerSyncOffsets.subtitleRateProperty, rate.toStringAsFixed(6));
    await native.setProperty(PlayerSyncOffsets.subtitleProperty, (delayMs / 1000.0).toString());
    final appliedRate = double.tryParse(await native.getProperty(PlayerSyncOffsets.subtitleRateProperty) ?? '');
    final appliedDelay = double.tryParse(await native.getProperty(PlayerSyncOffsets.subtitleProperty) ?? '');
    if (appliedRate == null ||
        !appliedRate.isFinite ||
        appliedDelay == null ||
        !appliedDelay.isFinite ||
        (appliedRate - rate).abs() > 0.001 ||
        (appliedDelay * 1000 - delayMs).abs() > 2) {
      throw StateError('The player did not apply the external subtitle timing.');
    }
    final offsets = PlayerSyncOffsets.of(native);
    offsets.recordSubtitleRate(appliedRate);
    offsets.recordApplied(PlayerSyncOffsets.subtitleProperty, (appliedDelay * 1000).round());
  }

  bool _isCurrentExternalSubtitleScope({
    required Player native,
    required SourceEntry item,
    required PublicationFile publicationFile,
    required int fileIndex,
    required String profile,
    required String? edition,
    required int generation,
    required int fileEpoch,
  }) =>
      _valid &&
      player == native &&
      entry == item &&
      _profile == profile &&
      _generation == generation &&
      _fileEpoch == fileEpoch &&
      _fileIndex == fileIndex &&
      fileIndex >= 0 &&
      fileIndex < files.length &&
      files[fileIndex].fingerprint == publicationFile.fingerprint &&
      progress?.edition == edition;

  Directory _externalSubtitleAssetDirectory({
    required String profile,
    required SourceEntry item,
    required String edition,
    required PublicationFile publicationFile,
  }) {
    final digestPattern = RegExp(r'^[0-9a-f]{64}$');
    if (!digestPattern.hasMatch(edition) || !digestPattern.hasMatch(publicationFile.fingerprint)) {
      throw const SourceException(SourceFailure.invalidData);
    }
    return Directory(
      p.join(
        sources.downloads.directory.path,
        sourceDigest(profile),
        'external-subtitles',
        sourceDigest(item.key),
        edition,
        publicationFile.fingerprint,
      ),
    );
  }

  String _normalizeSubtitleLanguage(String value) {
    final normalized = value.trim().toLowerCase().replaceAll('_', '-');
    return RegExp(r'^[a-z]{2,3}(?:-[a-z0-9]{2,8})?$').hasMatch(normalized) ? normalized : '';
  }

  List<String> _externalSubtitleCommand({
    required String path,
    required String language,
    required bool forced,
    required bool hearingImpaired,
  }) {
    final flags = ['select', if (forced) 'forced', if (hearingImpaired) 'hearing-impaired'].join(' ');
    final title = language.isEmpty ? 'External subtitle' : language;
    return ['sub-add', path, flags, title, if (language.isNotEmpty) language];
  }

  Map<String, dynamic>? _safeExternalSubtitleAsset(Object? value) {
    if (value is! Map) {
      return null;
    }
    final asset = Map<String, dynamic>.from(value);
    final slot = asset['slot'];
    final checksum = asset['sha256'];
    final fileName = asset['file'];
    final size = asset['size'];
    final language = asset['language'];
    final forced = asset['forced'];
    final hearingImpaired = asset['hearingImpaired'];
    final rawSyncByAudio = asset['syncByAudio'];
    final rawSyncByAudioMap = rawSyncByAudio is Map ? Map<String, dynamic>.from(rawSyncByAudio) : null;
    final legacyDelay = asset['syncDelayMs'] ?? 0;
    final legacyRate = asset['syncRate'] ?? 1.0;
    final syncByAudio =
        rawSyncByAudioMap ??
        <String, dynamic>{
          'legacy': {'delayMs': legacyDelay, 'rate': legacyRate},
        };

    if (syncByAudio.length > 16) {
      return null;
    }
    for (final entry in syncByAudio.entries) {
      if (entry.key != 'legacy' && !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.key)) {
        return null;
      }
      if (entry.value is! Map) {
        return null;
      }
      final values = Map<String, dynamic>.from(entry.value as Map);
      final rawDelay = values['delayMs'];
      final rawRate = values['rate'];
      if (rawDelay is! int || rawRate is! num) {
        return null;
      }
      final rate = rawRate.toDouble();
      if (rawDelay < ScopedPlayerPrefs.minimumSyncOffsetMs ||
          rawDelay > ScopedPlayerPrefs.maximumSyncOffsetMs ||
          !rate.isFinite ||
          rate < ScopedPlayerPrefs.minimumSubtitleSyncRate ||
          rate > ScopedPlayerPrefs.maximumSubtitleSyncRate) {
        return null;
      }
    }

    if (slot is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(slot) ||
        checksum is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum) ||
        fileName is! String ||
        p.basename(fileName) != fileName ||
        size is! int ||
        size <= 0 ||
        size > 5 * 1024 * 1024 ||
        language is! String ||
        _normalizeSubtitleLanguage(language) != language ||
        forced is! bool ||
        hearingImpaired is! bool) {
      return null;
    }
    final extension = p.extension(fileName).toLowerCase();
    if (!const {'.srt', '.ass', '.ssa', '.vtt', '.sub'}.contains(extension) ||
        fileName != '$checksum$extension' ||
        slot != sha256.convert(utf8.encode(jsonEncode([language, forced, hearingImpaired]))).toString()) {
      return null;
    }
    return {
      'slot': slot,
      'sha256': checksum,
      'file': fileName,
      'size': size,
      'language': language,
      'forced': forced,
      'hearingImpaired': hearingImpaired,
      'syncByAudio': syncByAudio,
    };
  }

  Future<Map<String, dynamic>?> _readExternalSubtitleManifest({
    required Directory directory,
    required SourceEntry item,
    required String edition,
    required PublicationFile publicationFile,
  }) async {
    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    final backupFile = File('${manifestFile.path}.backup');
    try {
      if (!await manifestFile.exists() && await backupFile.exists()) {
        await backupFile.rename(manifestFile.path);
      } else if (await manifestFile.exists() && await backupFile.exists()) {
        await backupFile.delete();
      }
      if (!await manifestFile.exists() || await manifestFile.length() > 64 * 1024) {
        return null;
      }
      final decoded = jsonDecode(await manifestFile.readAsString());
      if (decoded is! Map) {
        return null;
      }
      final manifest = Map<String, dynamic>.from(decoded);
      if ((manifest['version'] != 1 && manifest['version'] != 2) ||
          manifest['entry'] != sourceDigest(item.key) ||
          manifest['edition'] != edition ||
          manifest['fileFingerprint'] != publicationFile.fingerprint ||
          manifest['assets'] is! List) {
        return null;
      }
      final rawAssets = manifest['assets'] as List;
      if (rawAssets.length > 8) {
        return null;
      }
      final assets = rawAssets.map(_safeExternalSubtitleAsset).whereType<Map<String, dynamic>>().toList();
      final selected = manifest['selected'];
      return {
        'version': 2,
        'entry': sourceDigest(item.key),
        'edition': edition,
        'fileFingerprint': publicationFile.fingerprint,
        'selected': selected is String && assets.any((asset) => asset['slot'] == selected) ? selected : '',
        'assets': assets,
      };
    } on Object {
      return null;
    }
  }

  Future<void> _writeExternalSubtitleManifest(File manifestFile, Map<String, dynamic> manifest) async {
    final staged = File('${manifestFile.path}.${const Uuid().v4()}.pending');
    final backup = File('${manifestFile.path}.backup');
    try {
      await staged.writeAsString(jsonEncode(manifest), flush: true);
      if (await backup.exists()) {
        await backup.delete();
      }
      if (await manifestFile.exists()) {
        await manifestFile.rename(backup.path);
      }
      try {
        await staged.rename(manifestFile.path);
        if (await backup.exists()) {
          try {
            await backup.delete();
          } on Object {
            // The main manifest is already committed; recover by preferring it next time.
          }
        }
      } catch (_) {
        if (!await manifestFile.exists() && await backup.exists()) {
          await backup.rename(manifestFile.path);
        }
        rethrow;
      }
    } finally {
      if (await staged.exists()) {
        await staged.delete();
      }
    }
  }

  Future<void> _pruneExternalSubtitleAssets(Directory directory, List<Map<String, dynamic>> assets) async {
    final keep = assets.map((asset) => asset['file'] as String).toSet();
    final ownedAsset = RegExp(r'^[0-9a-f]{64}\.(?:srt|ass|ssa|vtt|sub)$');
    for (final entity in await directory.list(followLinks: false).toList()) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (ownedAsset.hasMatch(name) && !keep.contains(name)) {
        try {
          await entity.delete();
        } on Object {
          // Stale, unreferenced cache cleanup is best effort.
        }
      } else if (name.endsWith('.pending')) {
        try {
          await entity.delete();
        } on Object {
          // Stale, unreferenced cache cleanup is best effort.
        }
      }
    }
  }

  Future<void> _restoreExternalSubtitleAssets({
    required Player native,
    required SourceEntry item,
    required PublicationFile publicationFile,
    required int fileIndex,
    required String profile,
    required String edition,
    required int generation,
    required int fileEpoch,
  }) async {
    if (!_persistProgress || _liveInput || !video || native.playerType != 'mpv') {
      return;
    }
    final directory = _externalSubtitleAssetDirectory(
      profile: profile,
      item: item,
      edition: edition,
      publicationFile: publicationFile,
    );
    final manifest = await _readExternalSubtitleManifest(
      directory: directory,
      item: item,
      edition: edition,
      publicationFile: publicationFile,
    );
    if (manifest == null) {
      return;
    }
    final assets = (manifest['assets'] as List<Map<String, dynamic>>)
        .where(
          (asset) =>
              native.supportedLocalSubtitleExtensions.contains(p.extension(asset['file'] as String).substring(1)),
        )
        .toList();
    final selected = manifest['selected'];
    assets.sort((a, b) => (a['slot'] == selected ? 1 : 0).compareTo(b['slot'] == selected ? 1 : 0));
    for (final asset in assets) {
      if (!_isCurrentExternalSubtitleScope(
        native: native,
        item: item,
        publicationFile: publicationFile,
        fileIndex: fileIndex,
        profile: profile,
        edition: edition,
        generation: generation,
        fileEpoch: fileEpoch,
      )) {
        return;
      }
      final fileName = asset['file'] as String;
      final file = File(p.join(directory.path, fileName));
      try {
        if (!await file.exists() || await file.length() != asset['size']) {
          continue;
        }
        final contents = await file.readAsBytes();
        if (sha256.convert(contents).toString() != asset['sha256']) {
          continue;
        }
        if (!_isCurrentExternalSubtitleScope(
          native: native,
          item: item,
          publicationFile: publicationFile,
          fileIndex: fileIndex,
          profile: profile,
          edition: edition,
          generation: generation,
          fileEpoch: fileEpoch,
        )) {
          return;
        }
        await native.command(
          _externalSubtitleCommand(
            path: file.path,
            language: asset['language'] as String,
            forced: asset['forced'] as bool,
            hearingImpaired: asset['hearingImpaired'] as bool,
          ),
        );
        if (asset['slot'] == selected) {
          final sync = _subtitleSyncForAudio(
            asset['syncByAudio'] as Map<String, dynamic>,
            _subtitleAudioIdentity(native),
          );
          await _applyExternalSubtitleSync(native, delayMs: sync.delayMs, rate: sync.rate);
          _selectedExternalSubtitlePath = file.absolute.path;
          _activeExternalSubtitleSyncBinding = _externalSubtitleSyncBinding(native, file.absolute.path);
        }
      } on Object {
        appLogger.w('Saved external subtitle could not be restored');
      }
    }
  }
}

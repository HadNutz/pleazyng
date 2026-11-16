import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'subtitle_sync_calibration.dart';

/// Exact device-local scope for one selected text sidecar and playback lane.
/// The raw URL is deliberately absent; the content digest supplements server
/// catalog identity so a replaced file does not inherit an older correction.
final class SubtitleCalibrationIdentity {
  const SubtitleCalibrationIdentity({
    required this.profileId,
    required this.serverId,
    required this.ratingKey,
    required this.mediaIndex,
    required this.partId,
    required this.partOffsetMs,
    required this.audioTrackIdentity,
    required this.subtitleTrackIdentity,
    required this.lane,
    required this.sourceBytesDigest,
  });

  final String profileId;
  final String serverId;
  final String ratingKey;
  final int mediaIndex;
  final String partId;
  final int partOffsetMs;
  final String audioTrackIdentity;
  final String subtitleTrackIdentity;
  final String lane;
  final String sourceBytesDigest;

  String get profileKey => _digest(profileId.trim());

  String get storageKey => _digest(
    jsonEncode([
      profileId.trim(),
      serverId.trim(),
      ratingKey.trim(),
      mediaIndex,
      partId.trim(),
      partOffsetMs,
      audioTrackIdentity.trim(),
      subtitleTrackIdentity.trim(),
      lane,
      sourceBytesDigest,
    ]),
  );

  void validate() {
    bool boundedLabel(String value) => value.trim().isNotEmpty && value.length <= 4096;
    if (!boundedLabel(profileId) ||
        !boundedLabel(serverId) ||
        !boundedLabel(ratingKey) ||
        mediaIndex < 0 ||
        mediaIndex > 1000000 ||
        !boundedLabel(partId) ||
        partOffsetMs < 0 ||
        partOffsetMs > SubtitleSyncCalibration.maximumTimeMs ||
        !boundedLabel(audioTrackIdentity) ||
        !boundedLabel(subtitleTrackIdentity) ||
        !const {'primary', 'secondary'}.contains(lane) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceBytesDigest)) {
      throw const FormatException('Subtitle calibration identity is incomplete.');
    }
  }

  Map<String, Object> toSafeJson() => {
    'scopeKey': storageKey,
    'profileKey': profileKey,
    'serverKey': _digest(serverId.trim()),
    'itemKey': _digest(ratingKey.trim()),
    'mediaIndex': mediaIndex,
    'partKey': _digest(partId.trim()),
    'partOffsetMs': partOffsetMs,
    'audioKey': _digest(audioTrackIdentity.trim()),
    'subtitleKey': _digest(subtitleTrackIdentity.trim()),
    'lane': lane,
    'sourceBytesDigest': sourceBytesDigest,
    'clock': 'opened-media-part-ms',
  };

  static String digestBytes(List<int> bytes) => _digestBytes(bytes);

  static String _digest(String value) => _digestBytes(utf8.encode(value));

  static String _digestBytes(List<int> value) => sha256.convert(value).toString();
}

/// A saved, manually reviewed timing fit. Opening history never applies it;
/// callers must explicitly preview or save it into current player settings.
final class SubtitleCalibrationRecord {
  const SubtitleCalibrationRecord({
    required this.id,
    required this.createdAt,
    required this.scopeKey,
    required this.observations,
    required this.fit,
    required this.previousRate,
    required this.previousDelayMs,
  });

  final String id;
  final DateTime createdAt;
  final String scopeKey;
  final List<SubtitleSyncObservation> observations;
  final SubtitleSyncCalibrationFit? fit;
  final double previousRate;
  final int previousDelayMs;

  Map<String, Object> toJson() => {
    'schema': 'plezyng.subtitle-calibration.v1',
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'scopeKey': scopeKey,
    'observations': observations.map((value) => value.toJson()).toList(growable: false),
    if (fit != null) 'fit': fit!.toJson(),
    'previousRate': previousRate,
    'previousDelayMs': previousDelayMs,
  };

  static SubtitleCalibrationRecord fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['schema'] != 'plezyng.subtitle-calibration.v1') {
      throw const FormatException('Subtitle calibration history record is invalid.');
    }
    final id = value['id'];
    final createdAt = DateTime.tryParse(value['createdAt'] as String? ?? '');
    final scopeKey = value['scopeKey'];
    final rawFit = value['fit'];
    final rawObservations = value['observations'];
    final previousRate = value['previousRate'];
    final previousDelayMs = value['previousDelayMs'];
    if (id is! String ||
        !RegExp(r'^\d+_[0-9a-f]{8}$').hasMatch(id) ||
        createdAt == null ||
        scopeKey is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(scopeKey) ||
        rawObservations is! List ||
        rawObservations.length < 2 ||
        rawObservations.length > SubtitleSyncCalibrationFit.maximumObservations ||
        (rawFit != null && rawFit is! Map<String, dynamic>) ||
        previousRate is! num ||
        !previousRate.toDouble().isFinite ||
        previousRate < SubtitleSyncCalibration.minimumTimestampMultiplier ||
        previousRate > SubtitleSyncCalibration.maximumTimestampMultiplier ||
        previousDelayMs is! int ||
        previousDelayMs < SubtitleSyncCalibration.minimumDelayMs ||
        previousDelayMs > SubtitleSyncCalibration.maximumDelayMs) {
      throw const FormatException('Subtitle calibration history fields are outside their bounds.');
    }
    final observations = rawObservations.map(SubtitleSyncObservation.fromJson).toList(growable: false);
    final rawFitMap = rawFit as Map<String, dynamic>?;
    SubtitleSyncCalibrationFit? fit;
    if (rawFitMap != null) {
      final fitObservations = rawFitMap['observations'];
      final rate = rawFitMap['rate'];
      final delayMs = rawFitMap['delayMs'];
      if (fitObservations is! List || rate is! num || delayMs is! int) {
        throw const FormatException('Subtitle calibration fit is invalid.');
      }
      fit = SubtitleSyncCalibrationFit.fromObservations(
        fitObservations.map(SubtitleSyncObservation.fromJson).toList(growable: false),
      );
      if ((fit.calibration.timestampMultiplier - rate.toDouble()).abs() > 1e-6 ||
          fit.calibration.delayMs != delayMs ||
          fit.observations.length != observations.length ||
          fit.observations.asMap().entries.any(
            (entry) =>
                entry.value.cueId != observations[entry.key].cueId ||
                entry.value.subtitleTimeMs != observations[entry.key].subtitleTimeMs ||
                entry.value.playbackTimeMs != observations[entry.key].playbackTimeMs ||
                entry.value.startsNewSegmentBefore != observations[entry.key].startsNewSegmentBefore,
          )) {
        throw const FormatException('Stored subtitle calibration does not match its cue observations.');
      }
    }
    return SubtitleCalibrationRecord(
      id: id,
      createdAt: createdAt.toUtc(),
      scopeKey: scopeKey,
      observations: List.unmodifiable(observations),
      fit: fit,
      previousRate: previousRate.toDouble(),
      previousDelayMs: previousDelayMs,
    );
  }
}

/// Bounded history for native subtitle calibration. Records are profile-local,
/// contain no URLs or raw server identifiers, and are keyed by exact source
/// bytes as well as catalog/item/audio/lane/part identity.
abstract final class SubtitleCalibrationHistoryService {
  static const int maximumRecordsPerScope = 8;
  static const int maximumRecordBytes = 64 * 1024;
  static const int maximumHistoryBytesPerScope = 512 * 1024;
  static const int maximumTotalRecordFiles = 512;
  static const int maximumTotalHistoryBytes = 64 * 1024 * 1024;
  static const int maximumDirectoryEntriesScanned = 1024;

  static Future<void> _writeTail = Future<void>.value();

  static Future<void> _exclusive(Future<void> Function() action) async {
    final previous = _writeTail;
    final released = Completer<void>();
    _writeTail = released.future;
    await previous;
    try {
      await action();
    } finally {
      released.complete();
    }
  }

  static Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'subtitle-calibration-history'));
    await root.create(recursive: true);
    return root;
  }

  static Future<Directory> _directory(SubtitleCalibrationIdentity identity, {bool create = false}) async {
    identity.validate();
    final directory = Directory(p.join((await _root()).path, identity.profileKey, identity.storageKey));
    if (create) await directory.create(recursive: true);
    return directory;
  }

  static Future<SubtitleCalibrationRecord> save({
    required SubtitleCalibrationIdentity identity,
    required List<SubtitleSyncObservation> observations,
    required SubtitleSyncCalibrationFit? fit,
    required double previousRate,
    required int previousDelayMs,
  }) async {
    identity.validate();
    if (observations.length < 2 ||
        observations.length > SubtitleSyncCalibrationFit.maximumObservations ||
        !previousRate.isFinite ||
        previousRate < SubtitleSyncCalibration.minimumTimestampMultiplier ||
        previousRate > SubtitleSyncCalibration.maximumTimestampMultiplier ||
        previousDelayMs < SubtitleSyncCalibration.minimumDelayMs ||
        previousDelayMs > SubtitleSyncCalibration.maximumDelayMs) {
      throw const FormatException('Subtitle calibration cannot be saved outside its validated bounds.');
    }
    final validatedMapping = SubtitlePiecewiseClockMap.fromObservations(observations);
    if (validatedMapping.anchors.length != observations.length ||
        (fit != null &&
            (fit.observations.length != observations.length ||
                fit.observations.asMap().entries.any(
                  (entry) =>
                      entry.value.cueId != observations[entry.key].cueId ||
                      entry.value.subtitleTimeMs != observations[entry.key].subtitleTimeMs ||
                      entry.value.playbackTimeMs != observations[entry.key].playbackTimeMs ||
                      entry.value.startsNewSegmentBefore != observations[entry.key].startsNewSegmentBefore,
                )))) {
      throw const FormatException('Subtitle calibration history does not match the selected cue anchors.');
    }
    late SubtitleCalibrationRecord saved;
    await _exclusive(() async {
      final directory = await _directory(identity, create: true);
      final now = DateTime.now().toUtc();
      var timestamp = now.microsecondsSinceEpoch;
      var id = '${timestamp}_${identity.storageKey.substring(0, 8)}';
      while (await File(p.join(directory.path, '$id.json')).exists()) {
        timestamp++;
        id = '${timestamp}_${identity.storageKey.substring(0, 8)}';
      }
      saved = SubtitleCalibrationRecord(
        id: id,
        createdAt: now,
        scopeKey: identity.storageKey,
        observations: List.unmodifiable(observations),
        fit: fit,
        previousRate: previousRate,
        previousDelayMs: previousDelayMs,
      );
      final bytes = utf8.encode(jsonEncode(saved.toJson()));
      if (bytes.length > maximumRecordBytes) throw const FormatException('Subtitle calibration record exceeds 64 KiB.');
      final target = File(p.join(directory.path, '$id.json'));
      final temporary = File(p.join(directory.path, '.tmp-$id'));
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        await _ensureGlobalCapacity(await _root(), bytes.length);
        await temporary.rename(target.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      await _pruneScope(directory);
    });
    return saved;
  }

  /// Requires durable history to succeed before applying player settings or
  /// writing an export, so history I/O failure cannot follow a completed
  /// output action.
  static Future<T> saveBeforeAction<T>({
    required SubtitleCalibrationIdentity identity,
    required List<SubtitleSyncObservation> observations,
    required SubtitleSyncCalibrationFit? fit,
    required double previousRate,
    required int previousDelayMs,
    required Future<T> Function() action,
  }) async {
    await save(
      identity: identity,
      observations: observations,
      fit: fit,
      previousRate: previousRate,
      previousDelayMs: previousDelayMs,
    );
    return action();
  }

  static Future<bool> saveBeforeApply({
    required SubtitleCalibrationIdentity identity,
    required List<SubtitleSyncObservation> observations,
    required SubtitleSyncCalibrationFit? fit,
    required double previousRate,
    required int previousDelayMs,
    required Future<bool> Function() apply,
  }) => saveBeforeAction<bool>(
    identity: identity,
    observations: observations,
    fit: fit,
    previousRate: previousRate,
    previousDelayMs: previousDelayMs,
    action: apply,
  );

  static Future<List<SubtitleCalibrationRecord>> load(SubtitleCalibrationIdentity identity) async {
    identity.validate();
    await _writeTail;
    final directory = await _directory(identity);
    if (!await directory.exists()) return const [];
    final files = await _boundedRecordFiles(directory, limit: maximumDirectoryEntriesScanned);
    files.sort((left, right) => _timestamp(right).compareTo(_timestamp(left)));
    final records = <SubtitleCalibrationRecord>[];
    var totalBytes = 0;
    for (final file in files.take(maximumRecordsPerScope)) {
      final length = await file.length();
      if (length <= 0 || length > maximumRecordBytes || totalBytes + length > maximumHistoryBytesPerScope) continue;
      try {
        final bytes = await file.readAsBytes();
        if (bytes.length != length || bytes.length > maximumRecordBytes) continue;
        final record = SubtitleCalibrationRecord.fromJson(jsonDecode(utf8.decode(bytes)));
        if (record.id != p.basenameWithoutExtension(file.path) || record.scopeKey != identity.storageKey) continue;
        records.add(record);
        totalBytes += length;
      } on Object {
        // A malformed or interrupted record is ignored and never applied.
      }
    }
    return List.unmodifiable(records);
  }

  static Future<void> delete(SubtitleCalibrationIdentity identity, String id) async {
    identity.validate();
    if (!RegExp(r'^\d+_[0-9a-f]{8}$').hasMatch(id)) throw const FormatException('Calibration record ID is invalid.');
    await _exclusive(() async {
      final file = File(p.join((await _directory(identity)).path, '$id.json'));
      if (await file.exists()) await file.delete();
    });
  }

  static Future<List<File>> _boundedRecordFiles(Directory directory, {required int limit}) async {
    final files = <File>[];
    var scanned = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (++scanned > limit) break;
      if (entity is File && p.extension(entity.path) == '.json') files.add(entity);
    }
    return files;
  }

  static int _timestamp(File file) => int.tryParse(p.basenameWithoutExtension(file.path).split('_').first) ?? 0;

  static Future<void> _pruneScope(Directory directory) async {
    final files = await _boundedRecordFiles(directory, limit: maximumDirectoryEntriesScanned);
    files.sort((left, right) => _timestamp(right).compareTo(_timestamp(left)));
    var bytes = 0;
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      final length = await file.length();
      if (length <= 0 ||
          length > maximumRecordBytes ||
          index >= maximumRecordsPerScope ||
          bytes + length > maximumHistoryBytesPerScope) {
        await file.delete();
      } else {
        bytes += length;
      }
    }
  }

  static Future<void> _ensureGlobalCapacity(Directory root, int additionalBytes) async {
    final files = <File>[];
    var scanned = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (++scanned > maximumDirectoryEntriesScanned) {
        throw const FormatException('Subtitle calibration history exceeded its bounded directory scan.');
      }
      if (entity is File && p.extension(entity.path) == '.json') files.add(entity);
    }
    files.sort((left, right) => _timestamp(left).compareTo(_timestamp(right)));
    var totalBytes = 0;
    var remainingCount = files.length;
    for (final file in files) {
      final length = await file.length();
      if (length <= 0 || length > maximumRecordBytes) {
        await file.delete();
        remainingCount--;
        continue;
      }
      totalBytes += length;
    }
    for (final file in files) {
      if (remainingCount + 1 <= maximumTotalRecordFiles && totalBytes + additionalBytes <= maximumTotalHistoryBytes) {
        break;
      }
      if (!await file.exists()) continue;
      final length = await file.length();
      await file.delete();
      remainingCount--;
      totalBytes -= length;
    }
    if (remainingCount + 1 > maximumTotalRecordFiles || totalBytes + additionalBytes > maximumTotalHistoryBytes) {
      throw const FormatException('Subtitle calibration history reached its storage bound.');
    }
  }
}

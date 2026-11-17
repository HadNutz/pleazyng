import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../sources/source_database.dart';
import '../sources/source_models.dart';
import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';

/// Profile and media scope for one playback-capture journal entry.
/// Only digests leave this constructor; raw profile and source identifiers are
/// never written to the journal or checkpoint files.
@immutable
final class SubtitleCaptureJobIdentity {
  const SubtitleCaptureJobIdentity._({required this.profileHash, required this.mediaHash, required this.audioHash});

  factory SubtitleCaptureJobIdentity.fromSource({
    required String profileId,
    required String sourceIdentity,
    String? stableAudioIdentity,
  }) {
    final profile = profileId.trim(), source = sourceIdentity.trim();
    if (profile.isEmpty || profile.length > 512 || source.isEmpty || source.length > 4096) {
      throw ArgumentError('A bounded profile and stable media identity are required.');
    }
    final audio = stableAudioIdentity?.trim() ?? '';
    if (audio.length > 2048) {
      throw ArgumentError.value(stableAudioIdentity, 'stableAudioIdentity', 'Audio identity is too long.');
    }
    return SubtitleCaptureJobIdentity._(
      profileHash: sourceDigest(profile),
      mediaHash: sourceDigest(source),
      audioHash: audio.isEmpty ? '' : sourceDigest(audio),
    );
  }

  /// A short hash of the profile ID. No profile name or raw ID is persisted.
  final String profileHash;

  /// A short hash of the source/media identity. No title or URL is persisted.
  final String mediaHash;

  /// Empty when the selected audio stream could not be identified stably.
  final String audioHash;

  bool get hasStableAudioIdentity => audioHash.isNotEmpty;
}

enum SubtitleCaptureJobState { capturing, interrupted, captured }

@immutable
final class SubtitleCaptureJob {
  const SubtitleCaptureJob({
    required this.profileHash,
    required this.jobId,
    required this.mediaHash,
    required this.audioHash,
    required this.state,
    required this.attemptGeneration,
    required this.checkpointRevision,
    required this.checkpointPath,
    required this.checkpointSha256,
    required this.checkpointBytes,
    required this.checkpointVersion,
    required this.cueCount,
    required this.wordCount,
    required this.startedAtMs,
    required this.updatedAtMs,
    required this.startedPositionMs,
    required this.playbackPositionMs,
    required this.timelineOffsetMs,
    required this.interruptedAtMs,
    required this.interruptionReason,
    required this.gapStartMs,
    required this.gapEndMs,
    required this.gapCount,
    required this.audioMatches,
  });

  final String profileHash;
  final String jobId;
  final String mediaHash;
  final String audioHash;
  final SubtitleCaptureJobState state;
  final int attemptGeneration;
  final int checkpointRevision;
  final String checkpointPath;
  final String checkpointSha256;
  final int checkpointBytes;
  final int checkpointVersion;
  final int cueCount;
  final int wordCount;
  final int startedAtMs;
  final int updatedAtMs;
  final int startedPositionMs;
  final int playbackPositionMs;

  /// Maps the player's current position onto the absolute capture timeline.
  /// This is non-zero when a live DVR reopen rebased its local clock.
  final int timelineOffsetMs;
  final int? interruptedAtMs;
  final String interruptionReason;
  final int? gapStartMs;
  final int? gapEndMs;
  final int gapCount;
  final bool audioMatches;

  bool get audioIdentityNeedsRevalidation => audioHash.isEmpty;
  bool get hasCheckpoint => checkpointPath.isNotEmpty && cueCount > 0;
  bool get wasRecoveredAfterRestart => interruptionReason == 'app_restart';
}

@immutable
final class SubtitleCaptureCheckpoint {
  const SubtitleCaptureCheckpoint({required this.cues, required this.wordTimings});

  final List<SubtitleCue> cues;
  final List<SubtitleWordTiming> wordTimings;
}

/// Bounded journal for live decoded-PCM subtitle capture. Checkpoints contain
/// recognized cues and word timings only; decoded audio is never written.
final class SubtitleCaptureJobStore {
  SubtitleCaptureJobStore.forTesting(
    GeneratedDatabase database, {
    required Directory checkpointRoot,
    required this._workerToken,
  }) : _database = database,
       _root = checkpointRoot;

  SubtitleCaptureJobStore._(this._database, this._root) : _workerToken = _processWorkerToken;

  static const int maximumJobsPerProfile = 12;
  static const int maximumCheckpointBytes = 16 * 1024 * 1024;
  static const int maximumProfileCheckpointBytes = 64 * 1024 * 1024;
  static const int _maximumCueCount = 50000;
  static const int _maximumWordCount = 250000;
  static const int _checkpointVersion = 1;
  static const _uuid = Uuid();
  static final String _processWorkerToken = _uuid.v4();
  static final Future<SubtitleCaptureJobStore> _shared = _open();

  // Serialize filesystem reconciliation with all checkpoint writers, including
  // separate store handles sharing a root. No in-flight temporary file can be
  // mistaken for a crash orphan.
  static final Map<String, Future<void>> _rootOperations = {};

  static Future<T> _serialized<T>(String root, Future<T> Function() action) async {
    final key = p.normalize(p.absolute(root));
    final previous = _rootOperations[key];
    final completion = Completer<void>();
    _rootOperations[key] = completion.future;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      completion.complete();
      if (identical(_rootOperations[key], completion.future)) unawaited(_rootOperations.remove(key));
    }
  }

  final GeneratedDatabase _database;
  final Directory _root;
  final String _workerToken;

  static Future<SubtitleCaptureJobStore> open() => _shared;

  static Future<SubtitleCaptureJobStore> _open() async {
    final support = await getApplicationSupportDirectory();
    final database = await SourceDatabase.open();
    return SubtitleCaptureJobStore._(database, Directory(p.join(support.path, 'subtitle-capture-jobs')));
  }

  Future<SubtitleCaptureJob> beginCapture(SubtitleCaptureJobIdentity identity, {required int playbackPositionMs}) =>
      _serialized(_root.path, () => _beginCapture(identity, playbackPositionMs: playbackPositionMs));

  Future<SubtitleCaptureJob> _beginCapture(
    SubtitleCaptureJobIdentity identity, {
    required int playbackPositionMs,
  }) async {
    _validateIdentity(identity);
    _validatePosition(playbackPositionMs);
    if (await _isProfileDeleted(identity.profileHash)) {
      throw StateError('The profile was removed; this capture cannot be saved.');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final jobId = _uuid.v4();
    await _database.transaction(() async {
      if (await _isProfileDeleted(identity.profileHash)) {
        throw StateError('The profile was removed; this capture cannot be saved.');
      }
      final oldCaptures = await _database
          .customSelect(
            'SELECT job_id,attempt_generation,worker_token,playback_position_ms FROM subtitle_capture_jobs '
            'WHERE profile_hash=? AND state=\'capturing\'',
            variables: [Variable.withString(identity.profileHash)],
          )
          .get();
      for (final row in oldCaptures) {
        if (row.read<String>('worker_token') == _workerToken) {
          throw StateError('A subtitle playback capture is already active for this profile.');
        }
        await _database.customStatement(
          'UPDATE subtitle_capture_jobs SET state=\'interrupted\',attempt_generation=attempt_generation+1,'
          'interrupted_at_ms=playback_position_ms,interruption_reason=\'superseded_worker\',updated=? '
          'WHERE profile_hash=? AND job_id=? AND state=\'capturing\' AND attempt_generation=?',
          [now, identity.profileHash, row.read<String>('job_id'), row.read<int>('attempt_generation')],
        );
      }
      await _database.customStatement(
        'INSERT INTO subtitle_capture_jobs('
        'profile_hash,job_id,media_hash,audio_hash,state,checkpoint_path,checkpoint_sha256,checkpoint_bytes,'
        'checkpoint_version,cue_count,word_count,checkpoint_revision,attempt_generation,worker_token,'
        'started_at,updated,started_position_ms,playback_position_ms,interruption_reason,gap_count) '
        'VALUES(?,?,?,?,\'capturing\',\'\',\'\',0,?,0,0,0,1,?,?,?,?,?,\'\',0)',
        [
          identity.profileHash,
          jobId,
          identity.mediaHash,
          identity.audioHash,
          _checkpointVersion,
          _workerToken,
          now,
          now,
          playbackPositionMs,
          playbackPositionMs,
        ],
      );
    });
    await _reconcileProfileFiles(identity.profileHash);
    await _enforceProfileBounds(identity.profileHash, protectedJobId: jobId);
    return (await _readJob(identity.profileHash, jobId))!;
  }

  /// Writes a complete cue snapshot before swapping the database pointer. The
  /// compare-and-swap guard prevents an old attempt or older cue revision from
  /// replacing the current checkpoint.
  Future<int?> saveCheckpoint({
    required SubtitleCaptureJobIdentity identity,
    required SubtitleCaptureJob job,
    required int expectedAttemptGeneration,
    required int expectedCheckpointRevision,
    required SubtitleCaptureCheckpoint checkpoint,
    required int playbackPositionMs,
    int timelineOffsetMs = 0,
    required int gapCount,
    required int? gapStartMs,
    required int? gapEndMs,
  }) => _serialized(
    _root.path,
    () => _saveCheckpoint(
      identity: identity,
      job: job,
      expectedAttemptGeneration: expectedAttemptGeneration,
      expectedCheckpointRevision: expectedCheckpointRevision,
      checkpoint: checkpoint,
      playbackPositionMs: playbackPositionMs,
      timelineOffsetMs: timelineOffsetMs,
      gapCount: gapCount,
      gapStartMs: gapStartMs,
      gapEndMs: gapEndMs,
    ),
  );

  Future<int?> _saveCheckpoint({
    required SubtitleCaptureJobIdentity identity,
    required SubtitleCaptureJob job,
    required int expectedAttemptGeneration,
    required int expectedCheckpointRevision,
    required SubtitleCaptureCheckpoint checkpoint,
    required int playbackPositionMs,
    int timelineOffsetMs = 0,
    required int gapCount,
    required int? gapStartMs,
    required int? gapEndMs,
  }) async {
    _validateIdentity(identity);
    _validatePosition(playbackPositionMs);
    _validateTimelineOffset(timelineOffsetMs);
    if (gapStartMs != null) _validatePosition(gapStartMs);
    if (gapEndMs != null) _validatePosition(gapEndMs);
    if (job.profileHash != identity.profileHash ||
        job.mediaHash != identity.mediaHash ||
        job.audioHash != identity.audioHash) {
      throw StateError('Capture identity changed before the subtitle checkpoint was saved.');
    }
    _validateCheckpoint(checkpoint);
    if (gapCount < 0 || gapCount > 100000) {
      throw const FormatException('Subtitle capture gap metadata exceeds its bound.');
    }
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(_checkpointJson(checkpoint))));
    if (bytes.length > maximumCheckpointBytes) {
      throw const FormatException('Subtitle capture checkpoint exceeds the 16 MiB limit.');
    }
    if (await _isProfileDeleted(identity.profileHash)) return null;
    await _reconcileProfileFiles(identity.profileHash);
    await _enforceProfileBounds(identity.profileHash, protectedJobId: job.jobId, reserveBytes: bytes.length);

    final nextRevision = expectedCheckpointRevision + 1;
    final relativePath = p.join(job.jobId, '$expectedAttemptGeneration-$nextRevision-${_uuid.v4()}.json');
    final finalFile = _fileFor(identity.profileHash, relativePath, jobId: job.jobId);
    final temporaryFile = File('${finalFile.path}.${_uuid.v4()}.tmp');
    await _ensureSafeDirectories(identity.profileHash, job.jobId);
    await finalFile.parent.create(recursive: true);
    try {
      await temporaryFile.writeAsBytes(bytes, flush: true);
      await temporaryFile.rename(finalFile.path);
    } catch (_) {
      if (await temporaryFile.exists()) await temporaryFile.delete();
      rethrow;
    }

    var previousPath = '';
    var committed = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      await _database.transaction(() async {
        if (await _isProfileDeleted(identity.profileHash)) return;
        final current = await _database
            .customSelect(
              'SELECT checkpoint_path FROM subtitle_capture_jobs WHERE profile_hash=? AND job_id=? '
              'AND attempt_generation=? AND checkpoint_revision=? AND worker_token=? AND state=\'capturing\'',
              variables: [
                Variable.withString(identity.profileHash),
                Variable.withString(job.jobId),
                Variable.withInt(expectedAttemptGeneration),
                Variable.withInt(expectedCheckpointRevision),
                Variable.withString(_workerToken),
              ],
            )
            .getSingleOrNull();
        if (current == null) return;
        previousPath = current.read<String>('checkpoint_path');
        final changed = await _database.customUpdate(
          'UPDATE subtitle_capture_jobs SET checkpoint_path=?,checkpoint_sha256=?,checkpoint_bytes=?,'
          'checkpoint_version=?,cue_count=?,word_count=?,checkpoint_revision=checkpoint_revision+1,'
          'updated=?,playback_position_ms=?,timeline_offset_ms=?,gap_count=?,gap_start_ms=?,gap_end_ms=? '
          'WHERE profile_hash=? AND job_id=? AND attempt_generation=? AND checkpoint_revision=? '
          'AND worker_token=? AND state=\'capturing\'',
          variables: [
            Variable.withString(relativePath),
            Variable.withString(sha256.convert(bytes).toString()),
            Variable.withInt(bytes.length),
            Variable.withInt(_checkpointVersion),
            Variable.withInt(checkpoint.cues.length),
            Variable.withInt(checkpoint.wordTimings.length),
            Variable.withInt(now),
            Variable.withInt(playbackPositionMs),
            Variable.withInt(timelineOffsetMs),
            Variable.withInt(gapCount),
            gapStartMs == null ? const Variable<int>(null) : Variable.withInt(gapStartMs),
            gapEndMs == null ? const Variable<int>(null) : Variable.withInt(gapEndMs),
            Variable.withString(identity.profileHash),
            Variable.withString(job.jobId),
            Variable.withInt(expectedAttemptGeneration),
            Variable.withInt(expectedCheckpointRevision),
            Variable.withString(_workerToken),
          ],
          updates: const {},
        );
        committed = changed == 1;
      });
    } catch (_) {
      if (await finalFile.exists()) await finalFile.delete();
      rethrow;
    }
    if (!committed) {
      if (await finalFile.exists()) await finalFile.delete();
      return null;
    }
    try {
      await _deleteRelativeFile(identity.profileHash, previousPath);
      await _cleanJobDirectory(identity.profileHash, job.jobId, keepRelativePath: relativePath);
      await _enforceProfileBounds(identity.profileHash, protectedJobId: job.jobId);
    } on Object {
      // The new pointer is already committed; cleanup failure must not make the
      // caller reuse an obsolete CAS revision for its next checkpoint.
    }
    return nextRevision;
  }

  /// Supplying gapCount replaces the gap envelope, including an unknown end.
  Future<SubtitleCaptureJob?> finishCapture({
    required SubtitleCaptureJob job,
    required int expectedAttemptGeneration,
    required bool interrupted,
    required String reason,
    int? interruptedAtMs,
    int? timelineOffsetMs,
    int? gapStartMs,
    int? gapEndMs,
    int? gapCount,
  }) => _serialized(
    _root.path,
    () => _finishCapture(
      job: job,
      expectedAttemptGeneration: expectedAttemptGeneration,
      interrupted: interrupted,
      reason: reason,
      interruptedAtMs: interruptedAtMs,
      timelineOffsetMs: timelineOffsetMs,
      gapStartMs: gapStartMs,
      gapEndMs: gapEndMs,
      gapCount: gapCount,
    ),
  );

  Future<SubtitleCaptureJob?> _finishCapture({
    required SubtitleCaptureJob job,
    required int expectedAttemptGeneration,
    required bool interrupted,
    required String reason,
    int? interruptedAtMs,
    int? timelineOffsetMs,
    int? gapStartMs,
    int? gapEndMs,
    int? gapCount,
  }) async {
    if (!RegExp(r'^[a-z_]{1,40}$').hasMatch(reason)) {
      throw ArgumentError.value(reason, 'reason', 'Use a bounded reason code.');
    }
    if (interruptedAtMs != null) _validatePosition(interruptedAtMs);
    if (timelineOffsetMs != null) _validateTimelineOffset(timelineOffsetMs);
    if (gapStartMs != null) _validatePosition(gapStartMs);
    if (gapEndMs != null) _validatePosition(gapEndMs);
    final now = DateTime.now().millisecondsSinceEpoch;
    await _database.transaction(() async {
      if (await _isProfileDeleted(job.profileHash)) return;
      await _database.customUpdate(
        'UPDATE subtitle_capture_jobs SET state=?,attempt_generation=attempt_generation+1,'
        'interrupted_at_ms=?,timeline_offset_ms=COALESCE(?,timeline_offset_ms),interruption_reason=?,gap_start_ms=COALESCE(?,gap_start_ms),'
        'gap_end_ms=CASE WHEN ? THEN ? ELSE COALESCE(?,gap_end_ms) END,gap_count=COALESCE(?,gap_count),updated=? '
        'WHERE profile_hash=? AND job_id=? AND state=\'capturing\' AND attempt_generation=? AND worker_token=?',
        variables: [
          Variable.withString(interrupted ? 'interrupted' : 'captured'),
          interruptedAtMs == null ? const Variable<int>(null) : Variable.withInt(interruptedAtMs),
          timelineOffsetMs == null ? const Variable<int>(null) : Variable.withInt(timelineOffsetMs),
          Variable.withString(reason),
          gapStartMs == null ? const Variable<int>(null) : Variable.withInt(gapStartMs),
          Variable.withInt(gapCount == null ? 0 : 1),
          gapEndMs == null ? const Variable<int>(null) : Variable.withInt(gapEndMs),
          gapEndMs == null ? const Variable<int>(null) : Variable.withInt(gapEndMs),
          gapCount == null ? const Variable<int>(null) : Variable.withInt(gapCount),
          Variable.withInt(now),
          Variable.withString(job.profileHash),
          Variable.withString(job.jobId),
          Variable.withInt(expectedAttemptGeneration),
          Variable.withString(_workerToken),
        ],
        updates: const {},
      );
    });
    return _readJob(job.profileHash, job.jobId);
  }

  Future<List<SubtitleCaptureJob>> browse(SubtitleCaptureJobIdentity identity) =>
      _serialized(_root.path, () => _browse(identity));

  Future<List<SubtitleCaptureJob>> _browse(SubtitleCaptureJobIdentity identity) async {
    _validateIdentity(identity);
    if (await _isProfileDeleted(identity.profileHash)) return const [];
    await _recoverStaleJobs(identity.profileHash);
    await _reconcileProfileFiles(identity.profileHash);
    await _enforceProfileBounds(identity.profileHash, protectedJobId: '');
    if (await _isProfileDeleted(identity.profileHash)) return const [];
    final rows = await _database
        .customSelect(
          'SELECT * FROM subtitle_capture_jobs WHERE profile_hash=? AND media_hash=? AND checkpoint_path<>\'\' '
          'AND cue_count>0 ORDER BY updated DESC LIMIT ?',
          variables: [
            Variable.withString(identity.profileHash),
            Variable.withString(identity.mediaHash),
            Variable.withInt(maximumJobsPerProfile),
          ],
        )
        .get();
    final jobs = rows
        .map(
          (row) => _jobFromRow(
            row,
            audioMatches: identity.audioHash.isNotEmpty && row.read<String>('audio_hash') == identity.audioHash,
          ),
        )
        .toList();
    for (final job in jobs.where((item) => item.state != SubtitleCaptureJobState.capturing)) {
      await _cleanJobDirectory(identity.profileHash, job.jobId, keepRelativePath: job.checkpointPath);
    }
    return jobs;
  }

  Future<SubtitleCaptureCheckpoint> restore(
    SubtitleCaptureJob job,
    SubtitleCaptureJobIdentity identity, {
    required bool audioRevalidated,
  }) => _serialized(_root.path, () => _restore(job, identity, audioRevalidated: audioRevalidated));

  Future<SubtitleCaptureCheckpoint> _restore(
    SubtitleCaptureJob job,
    SubtitleCaptureJobIdentity identity, {
    required bool audioRevalidated,
  }) async {
    _validateIdentity(identity);
    if (job.profileHash != identity.profileHash || job.mediaHash != identity.mediaHash) {
      throw StateError('This captured transcript belongs to a different profile or media item.');
    }
    if (await _isProfileDeleted(identity.profileHash)) {
      throw StateError('The profile was removed; this captured transcript is unavailable.');
    }
    final current = await _readJob(identity.profileHash, job.jobId);
    if (current == null ||
        current.mediaHash != identity.mediaHash ||
        current.checkpointRevision != job.checkpointRevision ||
        current.attemptGeneration != job.attemptGeneration ||
        !current.hasCheckpoint ||
        current.state == SubtitleCaptureJobState.capturing ||
        current.checkpointVersion != _checkpointVersion) {
      throw StateError('This captured transcript changed or is no longer available. Browse again.');
    }
    final bothStable = identity.hasStableAudioIdentity && current.audioHash.isNotEmpty;
    if (bothStable && identity.audioHash != current.audioHash) {
      throw StateError('The selected audio track does not match this captured transcript.');
    }
    if (!bothStable && !audioRevalidated) {
      throw StateError('Recheck the selected audio track before restoring this partial capture.');
    }
    final file = _fileFor(identity.profileHash, current.checkpointPath, jobId: current.jobId);
    await _ensureSafeDirectories(identity.profileHash, current.jobId);
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file ||
        current.checkpointBytes < 1 ||
        current.checkpointBytes > maximumCheckpointBytes) {
      throw const FormatException('The saved subtitle checkpoint is missing or outside its size limit.');
    }
    if (await file.length() != current.checkpointBytes) {
      throw const FormatException('The saved subtitle checkpoint length does not match its journal record.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != current.checkpointBytes || sha256.convert(bytes).toString() != current.checkpointSha256) {
      throw const FormatException('The saved subtitle checkpoint did not pass its integrity check.');
    }
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    final checkpoint = _checkpointFromJson(decoded);
    if (await _isProfileDeleted(identity.profileHash)) {
      throw StateError('The profile was removed while the captured transcript was being restored.');
    }
    final confirmed = await _readJob(identity.profileHash, job.jobId);
    if (confirmed == null ||
        confirmed.attemptGeneration != current.attemptGeneration ||
        confirmed.checkpointRevision != current.checkpointRevision) {
      throw StateError('The captured transcript changed while it was being restored. Browse again.');
    }
    return checkpoint;
  }

  Future<SubtitleCaptureJob?> _readJob(String profileHash, String jobId) async {
    final row = await _database
        .customSelect(
          'SELECT * FROM subtitle_capture_jobs WHERE profile_hash=? AND job_id=?',
          variables: [Variable.withString(profileHash), Variable.withString(jobId)],
        )
        .getSingleOrNull();
    return row == null ? null : _jobFromRow(row, audioMatches: false);
  }

  SubtitleCaptureJob _jobFromRow(QueryRow row, {required bool audioMatches}) => SubtitleCaptureJob(
    profileHash: row.read<String>('profile_hash'),
    jobId: row.read<String>('job_id'),
    mediaHash: row.read<String>('media_hash'),
    audioHash: row.read<String>('audio_hash'),
    state: SubtitleCaptureJobState.values.byName(row.read<String>('state')),
    attemptGeneration: row.read<int>('attempt_generation'),
    checkpointRevision: row.read<int>('checkpoint_revision'),
    checkpointPath: row.read<String>('checkpoint_path'),
    checkpointSha256: row.read<String>('checkpoint_sha256'),
    checkpointBytes: row.read<int>('checkpoint_bytes'),
    checkpointVersion: row.read<int>('checkpoint_version'),
    cueCount: row.read<int>('cue_count'),
    wordCount: row.read<int>('word_count'),
    startedAtMs: row.read<int>('started_at'),
    updatedAtMs: row.read<int>('updated'),
    startedPositionMs: row.read<int>('started_position_ms'),
    playbackPositionMs: row.read<int>('playback_position_ms'),
    timelineOffsetMs: row.read<int>('timeline_offset_ms'),
    interruptedAtMs: row.readNullable<int>('interrupted_at_ms'),
    interruptionReason: row.read<String>('interruption_reason'),
    gapStartMs: row.readNullable<int>('gap_start_ms'),
    gapEndMs: row.readNullable<int>('gap_end_ms'),
    gapCount: row.read<int>('gap_count'),
    audioMatches: audioMatches,
  );

  Future<void> _recoverStaleJobs(String profileHash) async {
    if (await _isProfileDeleted(profileHash)) return;
    final stale = await _database
        .customSelect(
          'SELECT job_id,attempt_generation,playback_position_ms FROM subtitle_capture_jobs '
          'WHERE profile_hash=? AND state=\'capturing\' AND worker_token<>?',
          variables: [Variable.withString(profileHash), Variable.withString(_workerToken)],
        )
        .get();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in stale) {
      await _database.customUpdate(
        'UPDATE subtitle_capture_jobs SET state=\'interrupted\',attempt_generation=attempt_generation+1,'
        'interrupted_at_ms=playback_position_ms,interruption_reason=\'app_restart\',updated=? '
        'WHERE profile_hash=? AND job_id=? AND state=\'capturing\' AND attempt_generation=? AND worker_token<>?',
        variables: [
          Variable.withInt(now),
          Variable.withString(profileHash),
          Variable.withString(row.read<String>('job_id')),
          Variable.withInt(row.read<int>('attempt_generation')),
          Variable.withString(_workerToken),
        ],
        updates: const {},
      );
    }
  }

  Future<void> _ensureSafeDirectories(String profileHash, String jobId) async {
    for (final path in [_root.path, p.join(_root.path, profileHash), p.join(_root.path, profileHash, jobId)]) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.directory) {
        throw const FormatException('Subtitle checkpoint directories must not be symbolic links.');
      }
    }
  }

  Future<void> _reconcileProfileFiles(String profileHash) async {
    if (await FileSystemEntity.type(_root.path, followLinks: false) == FileSystemEntityType.link) {
      throw const FormatException('The subtitle checkpoint root is a symbolic link.');
    }
    final directory = Directory(p.join(_root.path, profileHash));
    if (await FileSystemEntity.type(directory.path, followLinks: false) == FileSystemEntityType.link) {
      throw const FormatException('The subtitle checkpoint profile directory is a symbolic link.');
    }
    if (!await directory.exists()) return;
    final rows = await _database
        .customSelect(
          'SELECT job_id,checkpoint_path FROM subtitle_capture_jobs WHERE profile_hash=?',
          variables: [Variable.withString(profileHash)],
        )
        .get();
    final retained = <String>{
      for (final row in rows)
        if (row.read<String>('checkpoint_path').isNotEmpty)
          p.normalize(
            _fileFor(profileHash, row.read<String>('checkpoint_path'), jobId: row.read<String>('job_id')).path,
          ),
    };
    // Only this journal's checkpoint namespace is eligible for reconciliation.
    // Symlinks and unrelated files are never followed or removed.
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! Directory || !_isJobId(p.basename(entity.path))) continue;
      await for (final child in entity.list(followLinks: false)) {
        if (child is! File || !{'.json', '.tmp'}.contains(p.extension(child.path))) continue;
        if (!retained.contains(p.normalize(child.path))) await child.delete();
      }
    }
  }

  Future<void> _enforceProfileBounds(String profileHash, {required String protectedJobId, int reserveBytes = 0}) async {
    final rows = await _database
        .customSelect(
          'SELECT job_id,state,checkpoint_path,checkpoint_bytes FROM subtitle_capture_jobs '
          'WHERE profile_hash=? ORDER BY updated DESC',
          variables: [Variable.withString(profileHash)],
        )
        .get();
    var retainedCount = rows.length;
    var retainedBytes = reserveBytes;
    final actualBytes = <String, int>{};
    for (final row in rows) {
      final path = row.read<String>('checkpoint_path');
      final file = path.isEmpty ? null : _fileFor(profileHash, path, jobId: row.read<String>('job_id'));
      final size = file != null && await file.exists() ? await file.length() : 0;
      actualBytes[row.read<String>('job_id')] = size;
      retainedBytes += size;
    }
    for (final row in rows.reversed) {
      final id = row.read<String>('job_id');
      if (id == protectedJobId || row.read<String>('state') == 'capturing') continue;
      if (retainedCount <= maximumJobsPerProfile && retainedBytes <= maximumProfileCheckpointBytes) break;
      final changed = await _database.customUpdate(
        'DELETE FROM subtitle_capture_jobs WHERE profile_hash=? AND job_id=? AND state<>\'capturing\'',
        variables: [Variable.withString(profileHash), Variable.withString(id)],
        updates: const {},
      );
      if (changed == 0) continue;
      retainedCount--;
      retainedBytes -= actualBytes[id] ?? 0;
      await _deleteJobDirectory(profileHash, id);
    }
    if (retainedCount > maximumJobsPerProfile || retainedBytes > maximumProfileCheckpointBytes) {
      throw StateError('The subtitle checkpoint quota cannot admit another snapshot.');
    }
  }

  Future<bool> _isProfileDeleted(String profileHash) async {
    final row = await _database
        .customSelect(
          'SELECT 1 FROM subtitle_capture_deleted_profiles WHERE profile_hash=? LIMIT 1',
          variables: [Variable.withString(profileHash)],
        )
        .getSingleOrNull();
    return row != null;
  }

  static Future<void> deleteProfileCheckpointFiles(String profileId) async {
    final profileHash = sourceDigest(profileId.trim());
    final support = await getApplicationSupportDirectory();
    await deleteProfileCheckpointFilesAt(Directory(p.join(support.path, 'subtitle-capture-jobs')), profileHash);
  }

  @visibleForTesting
  static Future<void> deleteProfileCheckpointFilesAt(Directory root, String profileHash) =>
      _serialized(root.path, () => _deleteProfileCheckpointFilesAt(root, profileHash));

  static Future<void> _deleteProfileCheckpointFilesAt(Directory root, String profileHash) async {
    if (!_isDigest(profileHash)) return;
    if (await FileSystemEntity.type(root.path, followLinks: false) == FileSystemEntityType.link) return;
    final directory = Directory(p.join(root.path, profileHash));
    if (await FileSystemEntity.type(directory.path, followLinks: false) == FileSystemEntityType.directory) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _deleteJobDirectory(String profileHash, String jobId) async {
    if (!_isJobId(jobId)) return;
    final directory = Directory(p.join(_root.path, profileHash, jobId));
    if (await FileSystemEntity.type(directory.path, followLinks: false) == FileSystemEntityType.directory) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _deleteRelativeFile(String profileHash, String relativePath) async {
    if (relativePath.isEmpty) return;
    try {
      final file = _fileFor(profileHash, relativePath, jobId: p.basename(p.dirname(relativePath)));
      if (await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.file) await file.delete();
    } on Object {
      // A stale/corrupt pointer never authorizes deletion outside the job root.
    }
  }

  Future<void> _cleanJobDirectory(String profileHash, String jobId, {required String keepRelativePath}) async {
    if (!_isJobId(jobId)) return;
    final directory = Directory(p.join(_root.path, profileHash, jobId));
    if (!await directory.exists()) return;
    final keep = keepRelativePath.isEmpty ? '' : p.basename(keepRelativePath);
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || p.basename(entity.path) == keep) continue;
      if (p.extension(entity.path) == '.json' || p.extension(entity.path) == '.tmp') {
        await entity.delete();
      }
    }
  }

  File _fileFor(String profileHash, String relativePath, {required String jobId}) {
    if (!_isDigest(profileHash) || !_isJobId(jobId)) {
      throw const FormatException('Subtitle capture checkpoint scope is invalid.');
    }
    final normalizedRelative = p.normalize(relativePath);
    if (p.isAbsolute(normalizedRelative) ||
        normalizedRelative.startsWith('..') ||
        p.split(normalizedRelative).first != jobId) {
      throw const FormatException('Subtitle capture checkpoint path is invalid.');
    }
    final path = p.normalize(p.join(_root.path, profileHash, normalizedRelative));
    if (!p.isWithin(_root.path, path)) throw const FormatException('Subtitle capture checkpoint escaped its root.');
    return File(path);
  }

  static Map<String, Object?> _checkpointJson(SubtitleCaptureCheckpoint checkpoint) => {
    'cues': [
      for (final cue in checkpoint.cues)
        {'id': cue.id, 'index': cue.index, 'startMs': cue.startMs, 'endMs': cue.endMs, 'text': cue.text},
    ],
    'wordTimings': [
      for (final word in checkpoint.wordTimings)
        {
          'startMs': word.startMs,
          'endMs': word.endMs,
          'text': word.text,
          if (word.confidence != null) 'confidence': word.confidence,
          'unit': word.unit.name,
          if (word.cueId != null) 'cueId': word.cueId,
          if (word.cueIndex != null) 'cueIndex': word.cueIndex,
        },
    ],
  };

  static SubtitleCaptureCheckpoint _checkpointFromJson(Object? value) {
    if (value is! Map<String, dynamic> || value.keys.toSet().difference({'cues', 'wordTimings'}).isNotEmpty) {
      throw const FormatException('Subtitle capture checkpoint envelope is invalid.');
    }
    final rawCues = value['cues'], rawWords = value['wordTimings'];
    if (rawCues is! List || rawWords is! List) {
      throw const FormatException('Subtitle capture checkpoint arrays are missing.');
    }
    if (rawCues.length > _maximumCueCount || rawWords.length > _maximumWordCount) {
      throw const FormatException('Subtitle capture checkpoint exceeds its cue bound.');
    }
    final cues = <SubtitleCue>[];
    final cueIds = <String>{};
    for (final raw in rawCues) {
      if (raw is! Map<String, dynamic>) throw const FormatException('Subtitle capture cue is invalid.');
      final id = raw['id'], index = raw['index'], start = raw['startMs'], end = raw['endMs'], text = raw['text'];
      if (raw.keys.toSet().difference({'id', 'index', 'startMs', 'endMs', 'text'}).isNotEmpty ||
          id is! String ||
          !SubtitleCue.isValidId(id) ||
          !cueIds.add(id) ||
          index is! int ||
          index < 1 ||
          start is! int ||
          end is! int ||
          text is! String ||
          text.length > 4096 ||
          start < 0 ||
          end <= start ||
          end > SubtitleRetimer.maximumTimeMs) {
        throw const FormatException('Subtitle capture cue fields are invalid.');
      }
      cues.add(SubtitleCue(id: id, index: index, startMs: start, endMs: end, text: text));
    }
    final words = <SubtitleWordTiming>[];
    for (final raw in rawWords) {
      if (raw is! Map<String, dynamic>) throw const FormatException('Subtitle capture word timing is invalid.');
      final start = raw['startMs'], end = raw['endMs'], text = raw['text'], confidence = raw['confidence'];
      final unitName = raw['unit'], cueId = raw['cueId'], cueIndex = raw['cueIndex'];
      final unit = SubtitleWordTimingUnit.values.where((candidate) => candidate.name == unitName);
      if (raw.keys.toSet().difference({
            'startMs',
            'endMs',
            'text',
            'confidence',
            'unit',
            'cueId',
            'cueIndex',
          }).isNotEmpty ||
          start is! int ||
          end is! int ||
          text is! String ||
          text.length > 4096 ||
          (confidence != null && confidence is! num) ||
          (confidence is num && (!confidence.isFinite || confidence < 0 || confidence > 1)) ||
          unit.isEmpty ||
          (cueId != null && (cueId is! String || !cueIds.contains(cueId))) ||
          (cueIndex != null && (cueIndex is! int || cueIndex < 1 || cueIndex > cues.length)) ||
          start < 0 ||
          end <= start ||
          end > SubtitleRetimer.maximumTimeMs) {
        throw const FormatException('Subtitle capture word timing fields are invalid.');
      }
      words.add(
        SubtitleWordTiming(
          startMs: start,
          endMs: end,
          text: text,
          confidence: (confidence as num?)?.toDouble(),
          unit: unit.first,
          cueId: cueId as String?,
          cueIndex: cueIndex as int?,
        ),
      );
    }
    return SubtitleCaptureCheckpoint(cues: List.unmodifiable(cues), wordTimings: List.unmodifiable(words));
  }

  static void _validateCheckpoint(SubtitleCaptureCheckpoint checkpoint) {
    if (checkpoint.cues.isEmpty ||
        checkpoint.cues.length > _maximumCueCount ||
        checkpoint.wordTimings.length > _maximumWordCount) {
      throw const FormatException('Subtitle capture checkpoint is empty or exceeds its cue bound.');
    }
    _checkpointFromJson(_checkpointJson(checkpoint));
  }

  static void _validateIdentity(SubtitleCaptureJobIdentity identity) {
    if (!_isDigest(identity.profileHash) ||
        !_isDigest(identity.mediaHash) ||
        (identity.audioHash.isNotEmpty && !_isDigest(identity.audioHash))) {
      throw const FormatException('Subtitle capture identity hash is invalid.');
    }
  }

  static void _validatePosition(int positionMs) {
    if (positionMs < 0 || positionMs > SubtitleRetimer.maximumTimeMs) {
      throw ArgumentError.value(positionMs, 'positionMs', 'Playback position is outside the supported range.');
    }
  }

  static void _validateTimelineOffset(int offsetMs) {
    if (offsetMs < -SubtitleRetimer.maximumTimeMs || offsetMs > SubtitleRetimer.maximumTimeMs) {
      throw ArgumentError.value(offsetMs, 'offsetMs', 'Capture timeline offset is outside the supported range.');
    }
  }

  static bool _isDigest(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
  static bool _isJobId(String value) => RegExp(r'^[0-9a-f-]{36}$').hasMatch(value);
}

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/subtitle_capture_job_store.dart';
import 'package:plezy/services/subtitle_retimer.dart';
import 'package:plezy/services/subtitle_word_timing.dart';
import 'package:plezy/sources/source_database.dart';

SubtitleCaptureCheckpoint _checkpoint() {
  final cue = SubtitleCue(
    id: SubtitleCue.idFor('durable-capture-test', 1),
    index: 1,
    startMs: 1200,
    endMs: 2600,
    text: 'Checkpointed speech',
  );
  return SubtitleCaptureCheckpoint(
    cues: [cue],
    wordTimings: [
      SubtitleWordTiming(
        startMs: 1300,
        endMs: 1800,
        text: 'Checkpointed',
        confidence: 0.8,
        unit: SubtitleWordTimingUnit.word,
        cueId: cue.id,
        cueIndex: 1,
      ),
    ],
  );
}

SubtitleCaptureJobIdentity _identity({String profile = 'alice', String? audio = 'aac|eng|2|48000'}) =>
    SubtitleCaptureJobIdentity.fromSource(
      profileId: profile,
      sourceIdentity: 'server-id\u0000item-id\u0000edition-fingerprint\u0000media-0',
      stableAudioIdentity: audio,
    );

void main() {
  test('checkpoint writes and cleanup never follow a linked journal root', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle-root-safety-');
    addTearDown(() => directory.delete(recursive: true));
    final outside = Directory('${directory.path}/outside');
    await outside.create();
    final identity = _identity();
    final outsideProfile = Directory('${outside.path}/${identity.profileHash}');
    await outsideProfile.create();
    final marker = File('${outsideProfile.path}/keep.json');
    await marker.writeAsString('not journal-owned');
    final root = Directory('${directory.path}/linked');
    await Link(root.path).create(outside.path);
    await SubtitleCaptureJobStore.deleteProfileCheckpointFilesAt(root, identity.profileHash);
    expect(await marker.readAsString(), 'not journal-owned');
    final database = SourceDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final store = SubtitleCaptureJobStore.forTesting(database, checkpointRoot: root, workerToken: 'owner');
    await expectLater(store.beginCapture(identity, playbackPositionMs: 0), throwsFormatException);
    expect(await marker.readAsString(), 'not journal-owned');
  });

  test('reconciles crash orphans before write and counts actual protected bytes', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle-quota-');
    addTearDown(() => directory.delete(recursive: true));
    final database = SourceDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final store = SubtitleCaptureJobStore.forTesting(database, checkpointRoot: directory, workerToken: 'owner');
    final identity = _identity();
    final job = await store.beginCapture(identity, playbackPositionMs: 0);
    Future<int?> save(int revision) => store.saveCheckpoint(
      identity: identity,
      job: job,
      expectedAttemptGeneration: job.attemptGeneration,
      expectedCheckpointRevision: revision,
      checkpoint: _checkpoint(),
      playbackPositionMs: 3000,
      gapCount: 0,
      gapStartMs: null,
      gapEndMs: null,
    );
    expect(await save(0), 1);
    final jobDirectory = Directory('${directory.path}/${identity.profileHash}/${job.jobId}');
    final orphan = File('${jobDirectory.path}/abandoned.json');
    final temporary = File('${jobDirectory.path}/abandoned.json.tmp');
    await orphan.writeAsString('crash orphan');
    await temporary.writeAsString('interrupted write');
    // Two operations sharing a root must not delete another active write.
    final results = await Future.wait([save(1), store.browse(identity)]);
    expect(results.first, 2);
    expect(await orphan.exists(), isFalse);
    expect(await temporary.exists(), isFalse);
    final row = await database.customSelect('SELECT checkpoint_path FROM subtitle_capture_jobs').getSingle();
    final checkpoint = File('${directory.path}/${identity.profileHash}/${row.read<String>('checkpoint_path')}');
    expect(await checkpoint.exists(), isTrue);
    final handle = await checkpoint.open(mode: FileMode.append);
    await handle.truncate(SubtitleCaptureJobStore.maximumProfileCheckpointBytes + 1);
    await handle.close();
    await expectLater(save(2), throwsStateError);
    expect(await checkpoint.length(), SubtitleCaptureJobStore.maximumProfileCheckpointBytes + 1);
    expect(await jobDirectory.list().length, 1);
  });

  test('checkpoints contain cues only and stale workers cannot replace a recovered prefix', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle-capture-journal-');
    addTearDown(() => directory.delete(recursive: true));
    final database = SourceDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final identity = _identity();
    final firstStore = SubtitleCaptureJobStore.forTesting(
      database,
      checkpointRoot: directory,
      workerToken: 'worker-first',
    );
    final job = await firstStore.beginCapture(identity, playbackPositionMs: 9000);
    final revision = await firstStore.saveCheckpoint(
      identity: identity,
      job: job,
      expectedAttemptGeneration: job.attemptGeneration,
      expectedCheckpointRevision: 0,
      checkpoint: _checkpoint(),
      playbackPositionMs: 12000,
      gapCount: 1,
      gapStartMs: 7000,
      gapEndMs: 9000,
    );
    expect(revision, 1);

    final records = await database
        .customSelect(
          'SELECT * FROM subtitle_capture_jobs WHERE profile_hash=?',
          variables: [Variable.withString(identity.profileHash)],
        )
        .get();
    expect(records, hasLength(1));
    expect(records.single.read<String>('profile_hash'), identity.profileHash);
    expect(records.single.read<String>('media_hash'), identity.mediaHash);
    expect(records.single.read<String>('audio_hash'), identity.audioHash);
    expect(records.single.read<int>('checkpoint_version'), 1);
    expect(records.single.toString(), isNot(contains('alice')));
    final files = await directory.list(recursive: true).where((entity) => entity is File).cast<File>().toList();
    expect(files, hasLength(1));
    final envelope = jsonDecode(await files.single.readAsString()) as Map<String, dynamic>;
    expect(envelope.keys.toSet(), {'cues', 'wordTimings'});
    expect(envelope.toString(), isNot(contains('server-id')));
    expect(envelope.toString(), isNot(contains('pcm')));

    final recoveredStore = SubtitleCaptureJobStore.forTesting(
      database,
      checkpointRoot: directory,
      workerToken: 'worker-after-restart',
    );
    final jobs = await recoveredStore.browse(identity);
    expect(jobs, hasLength(1));
    final recovered = jobs.single;
    expect(recovered.state, SubtitleCaptureJobState.interrupted);
    expect(recovered.attemptGeneration, job.attemptGeneration + 1);
    expect(recovered.wasRecoveredAfterRestart, isTrue);
    expect(recovered.gapCount, 1);
    expect(recovered.gapStartMs, 7000);
    expect(recovered.gapEndMs, 9000);

    final staleRevision = await firstStore.saveCheckpoint(
      identity: identity,
      job: job,
      expectedAttemptGeneration: job.attemptGeneration,
      expectedCheckpointRevision: 1,
      checkpoint: _checkpoint(),
      playbackPositionMs: 15000,
      gapCount: 1,
      gapStartMs: 7000,
      gapEndMs: 9000,
    );
    expect(staleRevision, isNull);
    final restored = await recoveredStore.restore(recovered, identity, audioRevalidated: false);
    expect(restored.cues.single.text, 'Checkpointed speech');
    expect(restored.wordTimings.single.cueId, restored.cues.single.id);
  });

  test('unstable audio identity requires explicit revalidation before restore', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle-capture-revalidation-');
    addTearDown(() => directory.delete(recursive: true));
    final database = SourceDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final identity = _identity(profile: 'bob', audio: null);
    final store = SubtitleCaptureJobStore.forTesting(database, checkpointRoot: directory, workerToken: 'worker-one');
    final job = await store.beginCapture(identity, playbackPositionMs: 0);
    await store.saveCheckpoint(
      identity: identity,
      job: job,
      expectedAttemptGeneration: job.attemptGeneration,
      expectedCheckpointRevision: 0,
      checkpoint: _checkpoint(),
      playbackPositionMs: 4000,
      gapCount: 0,
      gapStartMs: null,
      gapEndMs: null,
    );
    await store.finishCapture(
      job: job,
      expectedAttemptGeneration: job.attemptGeneration,
      interrupted: true,
      reason: 'user_stopped',
      interruptedAtMs: 4000,
    );
    final listed = await store.browse(identity);
    expect(listed.single.audioIdentityNeedsRevalidation, isTrue);
    await expectLater(store.restore(listed.single, identity, audioRevalidated: false), throwsStateError);
    expect((await store.restore(listed.single, identity, audioRevalidated: true)).cues, hasLength(1));
  });

  test('profile tombstones fence later writes and profile cleanup removes its checkpoint files', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle-capture-deletion-');
    addTearDown(() => directory.delete(recursive: true));
    final database = SourceDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final identity = _identity(profile: 'carol');
    final store = SubtitleCaptureJobStore.forTesting(database, checkpointRoot: directory, workerToken: 'worker-one');
    final job = await store.beginCapture(identity, playbackPositionMs: 0);
    await store.saveCheckpoint(
      identity: identity,
      job: job,
      expectedAttemptGeneration: job.attemptGeneration,
      expectedCheckpointRevision: 0,
      checkpoint: _checkpoint(),
      playbackPositionMs: 4000,
      gapCount: 0,
      gapStartMs: null,
      gapEndMs: null,
    );

    await SourceRepository(database).forgetProfile('carol');
    expect(await store.browse(identity), isEmpty);
    expect(
      await store.saveCheckpoint(
        identity: identity,
        job: job,
        expectedAttemptGeneration: job.attemptGeneration,
        expectedCheckpointRevision: 1,
        checkpoint: _checkpoint(),
        playbackPositionMs: 5000,
        gapCount: 0,
        gapStartMs: null,
        gapEndMs: null,
      ),
      isNull,
    );
    await SubtitleCaptureJobStore.deleteProfileCheckpointFilesAt(directory, identity.profileHash);
    expect(await Directory('${directory.path}/${identity.profileHash}').exists(), isFalse);
  });

  test('terminal job metadata stays within the per-profile journal bound', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle-capture-bound-');
    addTearDown(() => directory.delete(recursive: true));
    final database = SourceDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final identity = _identity(profile: 'bounded');
    final store = SubtitleCaptureJobStore.forTesting(
      database,
      checkpointRoot: directory,
      workerToken: 'bounded-worker',
    );
    for (var index = 0; index < SubtitleCaptureJobStore.maximumJobsPerProfile + 1; index++) {
      final job = await store.beginCapture(identity, playbackPositionMs: index * 1000);
      await store.finishCapture(
        job: job,
        expectedAttemptGeneration: job.attemptGeneration,
        interrupted: true,
        reason: 'user_stopped',
        interruptedAtMs: index * 1000,
      );
    }
    final count = await database
        .customSelect(
          'SELECT COUNT(*) AS count FROM subtitle_capture_jobs WHERE profile_hash=?',
          variables: [Variable.withString(identity.profileHash)],
        )
        .getSingle();
    expect(count.read<int>('count'), SubtitleCaptureJobStore.maximumJobsPerProfile);
  });
}

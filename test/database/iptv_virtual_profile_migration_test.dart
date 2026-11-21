import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/iptv/iptv_models.dart';
import 'package:plezy/iptv/iptv_source_repository.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';

void main() {
  test('v38 schedules and recordings survive migration and virtual Home users can record', () async {
    final folder = await Directory.systemTemp.createTemp('iptv-dvr-v39');
    final file = File('${folder.path}/before.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    Future<void> createSource(String owner, String source) => db.customStatement(
      "INSERT INTO iptv_sources(id,profile_id,display_name,kind,config_ciphertext,created_at) VALUES (?,?,'TV','m3u','x',1)",
      [source, owner],
    );
    Future<void> record(String owner, String source) async {
      final repo = IptvSourceRepository(db);
      final channel = LiveTvChannel(key: 'news', title: 'News', iptvSourceId: source, iptvChannelId: '42');
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final program = LiveTvProgram(title: 'News', beginsAt: now + 1000, endsAt: now + 2000);
      final schedule = await repo.scheduleLocalRecording(owner, channel, program);
      expect(schedule, isNotEmpty);
      await expectLater(
        repo.scheduleLocalRecording(owner, channel, program),
        throwsA(isA<IptvImportException>().having((e) => e.code, 'reason', 'recording_schedule_exists')),
      );
      await repo.beginLocalRecording(
        IptvLocalRecording(
          id: owner,
          profileId: owner,
          sourceId: source,
          channelId: '42',
          title: 'News',
          filePath: 'live.ts',
          startedAt: DateTime.now(),
          state: 'recording',
        ),
      );
    }

    try {
      await db.customSelect('SELECT 1').get();
      for (final table in ['iptv_recording_schedules', 'iptv_recordings']) {
        final ddl = (await db.customSelect("SELECT sql FROM sqlite_master WHERE name='$table'").getSingle())
            .read<String>('sql');
        await db.customStatement('DROP TABLE $table');
        await db.customStatement(
          ddl.replaceFirst(
            'profile_id TEXT NOT NULL,',
            'profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,',
          ),
        );
      }
      await db.customStatement(
        "INSERT INTO profiles(id,kind,display_name,config_json,created_at) VALUES ('local','local','Local','{}',1)",
      );
      await createSource('local', 'local-source');
      await record('local', 'local-source');
      await db.customStatement('ALTER TABLE offline_watch_progress DROP COLUMN account_scope');
      await db.customStatement('PRAGMA user_version=38');
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      const home = 'plex-home-account-virtual-user';
      await createSource(home, 'virtual-source');
      await record(home, 'virtual-source');
      for (final table in ['iptv_recording_schedules', 'iptv_recordings']) {
        final owners = await db.customSelect('SELECT profile_id FROM $table').get();
        expect(owners.map((r) => r.read<String>('profile_id')), unorderedEquals(['local', home]));
        expect(await db.customSelect('PRAGMA foreign_key_check($table)').get(), isEmpty);
      }
    } finally {
      await db.close();
      await folder.delete(recursive: true);
    }
  });
}

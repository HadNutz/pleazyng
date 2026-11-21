import 'package:drift/drift.dart';

import '../media/download_resolution.dart';
import '../models/download_models.dart';
import 'app_database.dart';

Future<void> createDownloadConversionTable(AppDatabase db) => db.customStatement('''
  CREATE TABLE IF NOT EXISTS download_conversions (
    global_key TEXT NOT NULL, server_id TEXT NOT NULL, scope_id TEXT NOT NULL, owner TEXT NOT NULL,
    queue_id INTEGER NOT NULL, item_id INTEGER NOT NULL, cancelled INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(global_key, server_id, scope_id, owner, queue_id, item_id)
  )
''');

extension DownloadConversionOperations on AppDatabase {
  Future<void> recordDownloadConversion(
    String key,
    String server,
    String scope,
    String owner,
    DownloadConversionHandle job,
  ) => customStatement(
    '''
    INSERT OR IGNORE INTO download_conversions(global_key,server_id,scope_id,owner,queue_id,item_id)
    VALUES(?,?,?,?,?,?)
  ''',
    [key, server, scope, owner, job.queueId, job.itemId],
  );

  Future<void> retireDownloadConversions(String key) =>
      customStatement('UPDATE download_conversions SET cancelled=1 WHERE global_key=?', [key]);

  Future<List<QueryRow>> cancelledDownloadConversions({String? server, String? key}) => customSelect(
    '''
    SELECT c.* FROM download_conversions c LEFT JOIN downloaded_media d ON d.global_key=c.global_key
    WHERE (c.cancelled=1 OR d.global_key IS NULL OR d.status=?)
      ${server == null ? '' : 'AND c.server_id=?'} ${key == null ? '' : 'AND c.global_key=?'}
  ''',
    variables: [
      Variable(DownloadStatus.cancelled.index),
      if (server != null) Variable(server),
      if (key != null) Variable(key),
    ],
  ).get();

  Future<void> forgetDownloadConversion(QueryRow job) => customStatement(
    '''
    DELETE FROM download_conversions WHERE global_key=? AND server_id=? AND scope_id=? AND owner=? AND queue_id=? AND item_id=?
  ''',
    [
      for (final column in ['global_key', 'server_id', 'scope_id', 'owner', 'queue_id', 'item_id']) job.data[column],
    ],
  );
}

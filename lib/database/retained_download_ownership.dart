import 'package:drift/drift.dart';

import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../profiles/profile_connection_registry.dart';
import '../utils/active_client_scope.dart';
import 'app_database.dart';
import 'download_operations.dart';

/// Signed-out files stay on disk with their original owner and cache namespace.
/// An empty owner marks an old file for which no identity can be established.
extension RetainedDownloadOwnership on AppDatabase {
  Future<bool> requiresFreshDownloadAuthorization(String globalKey) async {
    final record = await customSelect(
      'SELECT 1 FROM retained_download_owners WHERE global_key=? LIMIT 1',
      variables: [Variable(globalKey)],
    ).getSingleOrNull();
    if (record != null) return true;
    final row = await getDownloadedMedia(globalKey);
    if (row == null) return false;
    if (PlexTransferScopeId.tryParse(row.clientScopeId ?? '') != null) return true;
    return (await getValidDownloadOwnersForKey(globalKey)).isEmpty;
  }

  Future<void> retainDownloadOwnershipForLogout() => transaction(() async {
    await customStatement('''
      INSERT OR IGNORE INTO retained_download_owners (global_key, owner_id)
      SELECT global_key, '' FROM downloaded_media
    ''');
    await customStatement('''
      INSERT OR REPLACE INTO retained_download_owners (global_key, owner_id, backend, client_scope_id)
      SELECT o.global_key, o.profile_id, o.backend, o.client_scope_id
      FROM download_owners o JOIN downloaded_media d ON d.global_key=o.global_key
    ''');
    await clearAllDownloadOwners();
  });

  Future<void> restoreRetainedDownloads(String profileId, {required bool Function() isCurrent}) async {
    final anyRetained = await customSelect(
      "SELECT 1 FROM retained_download_owners WHERE owner_id <> '' LIMIT 1",
    ).getSingleOrNull();
    if (anyRetained == null || !isCurrent()) return;

    // Jellyfin/Emby cache namespaces identify the signed-in server user.
    // A Direct Plex namespace contains only a local profile ID. If that ID
    // changed, a fresh server lookup on an explicit download proves access.
    final scopes = <(String, String)>{};
    final registry = ConnectionRegistry(this);
    for (final binding in await ProfileConnectionRegistry(this).listForProfile(profileId)) {
      if (!binding.hasToken) continue;
      final connection = await registry.get(binding.connectionId);
      if (connection is JellyfinConnection && connection.userId == binding.userIdentifier) {
        scopes.add((connection.kind.id, '${connection.serverMachineId}/${connection.userId}'));
      }
    }
    await transaction(() async {
      final rows = await customSelect(
        "SELECT global_key, owner_id, backend, client_scope_id FROM retained_download_owners WHERE owner_id <> ''",
      ).get();
      for (final row in rows) {
        if (!isCurrent()) return;
        final owner = row.read<String>('owner_id');
        final key = row.read<String>('global_key');
        final backend = row.readNullable<String>('backend');
        final scope = row.readNullable<String>('client_scope_id');
        if (owner != profileId && (backend == null || scope == null || !scopes.contains((backend, scope)))) continue;
        await addDownloadOwner(profileId: profileId, globalKey: key, backendId: backend, clientScopeId: scope);
        await customStatement('DELETE FROM retained_download_owners WHERE global_key=? AND owner_id=?', [key, owner]);
      }
    });
  }
}

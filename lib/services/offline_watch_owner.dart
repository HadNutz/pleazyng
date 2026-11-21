import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../database/app_database.dart';
import '../database/download_operations.dart';
import '../media/ids.dart';
import '../media/media_server_client.dart';
import '../profiles/profile.dart';
import '../profiles/profile_connection_registry.dart';
import '../utils/active_client_scope.dart';
import '../utils/global_key_utils.dart';
import 'music/music_account_scope.dart';
import 'plex_client.dart';

Future<({String? scope, String? account})> resolveOfflineWatchOwner(
  AppDatabase database,
  MediaServerClient? client,
  ServerId serverId,
  String itemId,
  String? profileId,
) async {
  final liveScope = resolveActiveClientScopeId(serverId: serverId, cacheServerId: client?.cacheServerId);
  if (liveScope != null) {
    final account = client is PlexClient
        ? musicAccountScope(client)
        : client?.backend.usesMediaBrowserApi == true
        ? liveScope
        : null;
    return (scope: liveScope, account: account);
  }
  if (profileId == null || profileId.isEmpty) return (scope: null, account: null);

  // A shared physical row can belong to several different server users.
  // Only this profile's own ownership row can identify its offline scope.
  final owner = await database.getDownloadOwner(profileId: profileId, globalKey: buildGlobalKey(serverId, itemId));
  final ownedScope = resolveActiveClientScopeId(serverId: serverId, cacheServerId: owner?.clientScopeId);
  if (ownedScope != null && isJellyfinUserScopeId(serverId: serverId, cacheServerId: ownedScope)) {
    return (scope: ownedScope, account: ownedScope);
  }
  final plexScope = buildPlexProfileScopeId(serverId: serverId, profileId: profileId);
  final candidates = <({String scope, String? account})>{};
  final registry = ConnectionRegistry(database);
  for (final binding in await ProfileConnectionRegistry(database).listForProfile(profileId)) {
    final connection = await registry.get(binding.connectionId);
    if (connection is PlexDirectConnection && connection.serverMachineId == serverId) {
      candidates.add((
        scope: plexScope,
        account: plexMusicAccountScope(
          server: plexScope,
          account: connection.id,
          token: binding.userToken?.isNotEmpty == true ? binding.userToken : null,
        ),
      ));
    } else if (connection is PlexAccountConnection &&
        binding.hasToken &&
        binding.userIdentifier.isNotEmpty &&
        binding.userIdentifier != connection.clientIdentifier &&
        connection.servers.any((server) => server.clientIdentifier == serverId)) {
      candidates.add((
        scope: plexScope,
        account: plexMusicAccountScope(server: plexScope, account: connection.id, user: binding.userIdentifier),
      ));
    } else if (connection is JellyfinConnection &&
        connection.serverMachineId == serverId &&
        connection.userId == binding.userIdentifier &&
        binding.hasToken) {
      candidates.add((scope: connection.id, account: connection.id));
    }
  }
  if (candidates.length == 1) return candidates.single;
  return (scope: ownedScope, account: null);
}

bool offlineWatchAccountMatches(OfflineWatchProgressItem action, MediaServerClient client) {
  if (client is! PlexClient) {
    return action.accountScope == null ||
        client.backend.usesMediaBrowserApi && action.accountScope == client.cacheServerId;
  }
  if (action.accountScope != null) return action.accountScope == musicAccountScope(client);
  // Pre-v39 intents have no credential fingerprint. A virtual Home profile
  // has a durable user identity; local profiles may have changed accounts.
  final previous = parsePlexHomeProfileId(action.profileId ?? '');
  return previous != null &&
      previous.accountConnectionId == client.plexAccountId &&
      previous.homeUserUuid == client.plexMusicUserIdentifier;
}

/// Read-side filtering uses the same principal as replay. The physical file
/// and the local profile may survive replacement of its Direct Plex account.
Future<List<OfflineWatchProgressItem>> visibleWatchActions(
  AppDatabase database,
  MediaServerClient? client,
  List<OfflineWatchProgressItem> rows,
) async {
  if (rows.isEmpty) return rows;
  if (client != null) return rows.where((row) => offlineWatchAccountMatches(row, client)).toList();
  if (!rows.any((row) => row.accountScope != null)) return rows;
  final first = rows.first;
  final owner = await resolveOfflineWatchOwner(
    database,
    null,
    ServerId(first.serverId),
    first.ratingKey,
    first.profileId,
  );
  return rows.where((row) => row.accountScope == owner.account).toList();
}

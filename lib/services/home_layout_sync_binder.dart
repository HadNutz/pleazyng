import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;

import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../profiles/active_plex_identity.dart';
import '../profiles/active_plex_token.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/profile.dart';
import '../profiles/profile_connection_registry.dart';
import '../utils/app_logger.dart';
import 'home_layout_sync_service.dart';

/// Resolves the credential and layout owner from the same profile connection.
Future<ActivePlexToken?> resolveHomeLayoutAccount({
  required Profile profile,
  required ConnectionRegistry connections,
  required ProfileConnectionRegistry profileConnections,
}) async {
  if (profile.kind == ProfileKind.plexHome) {
    final parent = profile.parentConnectionId, user = profile.plexHomeUserUuid;
    if (parent == null || user == null || user.isEmpty) return null;
    final account = await connections.getPlexAccount(parent);
    if (account == null) return null;
    final link = await profileConnections.get(profile.id, parent);
    if (link == null || link.userIdentifier != user || !link.hasToken) return null;
    return ActivePlexToken(
      identity: ActivePlexIdentity(account: account, userUuid: user),
      token: link.userToken!,
    );
  }

  for (final link in await profileConnections.listForProfile(profile.id)) {
    final account = await connections.getPlexAccount(link.connectionId);
    if (account == null) continue;
    final user = link.userIdentifier.isEmpty ? null : link.userIdentifier;
    // A named link borrows a Plex Home user. Its token may be cleared for
    // reauthentication while the account owner's credential remains valid.
    final token = link.hasToken ? link.userToken : (user == null ? account.accountToken : null);
    if (token == null || token.isEmpty) return null;
    return ActivePlexToken(
      identity: ActivePlexIdentity(account: account, userUuid: user),
      token: token,
    );
  }
  return null;
}

/// Hands [HomeLayoutSyncService] the active profile's own Plex token whenever
/// the profile settles (startup, a switch, a freshly minted Home-user token),
/// and null for a profile without one (Jellyfin-only, not yet minted).
///
/// Home profiles never fall back to the owner's token: the layout is stored
/// on the account that token belongs to, and the owner's copy is not this
/// profile's layout.
class HomeLayoutSyncBinder {
  HomeLayoutSyncBinder({
    required ActiveProfileProvider activeProfile,
    required ConnectionRegistry connections,
    required ProfileConnectionRegistry profileConnections,
  }) : this._(activeProfile, connections, profileConnections);

  HomeLayoutSyncBinder._(this._activeProfile, this._connections, this._profileConnections) {
    _activeProfile.addListener(_onProfileChanged);
    _accounts = _connections
        .watchConnections()
        .map(
          (rows) => [for (final account in rows.whereType<PlexAccountConnection>()) (account.id, account.accountToken)],
        )
        .distinct(listEquals)
        .listen((_) => _onCredentialsChanged(), onError: _onCredentialError);
    _links = _profileConnections
        .watchAll()
        .map(
          (rows) => [
            for (final link in rows.where((row) => row.profileId == _activeProfile.activeId))
              (link.connectionId, link.userIdentifier, link.userToken, link.isDefault),
          ],
        )
        .distinct(listEquals)
        .listen((_) => _onCredentialsChanged(), onError: _onCredentialError);
    _onProfileChanged();
  }

  final ActiveProfileProvider _activeProfile;
  final ConnectionRegistry _connections;
  final ProfileConnectionRegistry _profileConnections;
  late final StreamSubscription<Object?> _accounts, _links;
  String? _lastProfileId;
  int _generation = 0;
  bool _disposed = false;

  void _onCredentialsChanged() {
    if (_disposed) return;
    HomeLayoutSyncService.instance.bind(null);
    _onProfileChanged();
  }

  void _onCredentialError(Object error, StackTrace stack) {
    if (_disposed) return;
    _generation++;
    HomeLayoutSyncService.instance.bind(null);
    appLogger.w('HomeLayoutSync: account subscription failed', error: error, stackTrace: stack);
  }

  void _onProfileChanged() {
    if (_disposed) return;
    final generation = ++_generation;
    final profile = _activeProfile.active;
    if (_lastProfileId != profile?.id) HomeLayoutSyncService.instance.bind(null);
    _lastProfileId = profile?.id;
    if (_activeProfile.isBinding || !_activeProfile.lastBindingSucceeded || profile == null) {
      HomeLayoutSyncService.instance.bind(null);
      return;
    }
    unawaited(() async {
      try {
        final resolved = await resolveHomeLayoutAccount(
          profile: profile,
          connections: _connections,
          profileConnections: _profileConnections,
        );
        if (_disposed || generation != _generation) return;
        HomeLayoutSyncService.instance.bind(
          resolved?.token,
          accountId: resolved?.identity.account.id,
          userUuid: resolved?.identity.userUuid,
          localProfileId: profile.id,
        );
      } catch (e, s) {
        if (_disposed || generation != _generation) return;
        HomeLayoutSyncService.instance.bind(null);
        appLogger.w('HomeLayoutSync: token resolve failed', error: e, stackTrace: s);
      }
    }());
  }

  void dispose() {
    _disposed = true;
    HomeLayoutSyncService.instance.bind(null);
    _activeProfile.removeListener(_onProfileChanged);
    unawaited(_accounts.cancel());
    unawaited(_links.cancel());
  }
}

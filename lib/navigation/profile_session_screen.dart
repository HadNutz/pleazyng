import 'dart:io' show Platform;
import '../utils/iphone_duo.dart';
import '../utils/platform_detector.dart';
import '../providers/download_provider.dart';
import '../services/playback_coordinator.dart';
import '../utils/global_key_utils.dart';
import '../utils/video_player_navigation.dart';
import 'video_task_restoration.dart';
import '../iptv/iptv_source_repository.dart';
import '../models/livetv_channel.dart';
import '../models/livetv_program.dart';
import '../screens/video_player/live_tv_session_args.dart';
import '../utils/live_tv_player_navigation.dart';
import '../services/music/music_car_host.dart';
import '../services/music/music_experience.dart';
import '../services/music/music_offline_rating_account.dart';
import '../services/music/music_guest_dj.dart';
import '../media/media_backend.dart';
import '../media/media_kind.dart';
import '../services/music/music_library_store.dart';
import '../karaoke/karaoke_session.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../connection/connection_registry.dart';
import '../focus/covered_route_focus_boundary.dart';
import '../focus/navigator_back_handler.dart';
import '../games/game_library_controller.dart';
import '../games/game_models.dart';
import '../media/ids.dart';
import '../media/media_server_client.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/plex_home_service.dart';
import '../profiles/profile_connection_registry.dart';
import '../profiles/profile_selection_policy.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/companion_remote_provider.dart';
import '../providers/discover_provider.dart';
import '../providers/explore_provider.dart';
import '../providers/hidden_libraries_provider.dart';
import '../providers/libraries_provider.dart';
import '../providers/multi_server_provider.dart';
import '../providers/playback_state_provider.dart';
import '../providers/seerr_account_provider.dart';
import '../providers/trackers_provider.dart';
import '../providers/watch_state_store.dart';
import '../services/credential_vault.dart';
import '../sources/source_controller.dart';
import '../sources/source_playback.dart';
import '../multiview/source_recovery_binder.dart';
import '../database/app_database.dart';
import '../multiview/workspace_controller.dart';
import '../multiview/workspace_overlay.dart';
import '../multiview/workspace_persistence.dart';
import '../screens/main_screen.dart';
import '../screens/music/music_home_screen.dart';
import '../screens/sources/source_player_screen.dart';
import '../screens/video_player_screen.dart';
import '../services/api_cache.dart';
import '../services/agent_control_service.dart';
import '../services/catalog/catalog_library_matcher.dart';
import '../services/home_layout_sync_binder.dart';
import '../services/music/music_playback_service.dart';
import '../services/music/guest_jukebox.dart';
import '../services/music/music_playback_service_impl.dart';
import '../services/music/music_session_store.dart';
import '../services/offline_watch_sync_service.dart';
import '../services/remote_streams/remote_streaming_provider.dart';
import '../services/storage_service.dart';
import '../services/settings_service.dart';
import '../services/system_shelf_service.dart';
import '../services/cast_media_service.dart';
import '../utils/app_logger.dart';
import '../watch_together/providers/watch_together_provider.dart';
import '../watch_together/watch_together.dart' show WatchNoticeListener;
import '../widgets/music/mini_player.dart';
import '../widgets/agent_control_scope.dart';
import 'profile_navigation_scope.dart';
import 'settings_shortcut.dart';

CatalogSourcesProvider _createCatalogSourcesProvider(BuildContext context) {
  return CatalogSourcesProvider(
    plexSessionSupplier: () => resolvePlexDiscoverSession(
      activeProfile: context.read<ActiveProfileProvider>(),
      connections: context.read<ConnectionRegistry>(),
      profileConnections: context.read<ProfileConnectionRegistry>(),
    ),
  );
}

/// Root route for an active profile session.
///
/// The root app navigator owns setup/auth/profile-picking. This route owns the
/// profile-scoped provider tree and a nested navigator for all content routes.
/// Changing the active profile changes the keyed boundary below, disposing the
/// old nested navigator, MainScreen, tab state, and profile-scoped providers.
///
/// Keep profile-owned routes, dialogs, sheets, and virtual keyboards on the
/// nearest navigator from this subtree. Keep setup/auth/PIN/profile-picker flows
/// on the root navigator so they survive this subtree being replaced. While one
/// of those covers this route, [CoveredRouteFocusBoundary] keeps the subtree
/// from taking focus: nested routes still read as current, so their focus
/// self-heals would otherwise pull the remote behind the covering route.
class ProfileSessionScreen extends StatefulWidget {
  const ProfileSessionScreen({
    super.key,
    this.isOfflineMode = false,
    this.initialPromptHandled = false,
    this.initialSourceLibrary = false,
  }) : profileShellBuilder = null,
       trackerHttpClientFactory = null;

  @visibleForTesting
  const ProfileSessionScreen.forTesting({
    super.key,
    this.isOfflineMode = false,
    this.initialPromptHandled = false,
    this.initialSourceLibrary = false,
    required this.profileShellBuilder,
    required http.Client Function() httpClientFactory,
  }) : trackerHttpClientFactory = httpClientFactory;

  final bool isOfflineMode;
  final bool initialPromptHandled;
  final bool initialSourceLibrary;
  final WidgetBuilder? profileShellBuilder;
  final http.Client Function()? trackerHttpClientFactory;

  @override
  State<ProfileSessionScreen> createState() => _ProfileSessionScreenState();
}

class _ProfileSessionScreenState extends State<ProfileSessionScreen> {
  // Profile changes remount the inner session, but the root route survives.
  // Treat the initial launch/profile prompt as handled after the first session
  // frame so switching profiles from the root picker does not immediately open
  // another required-selection picker underneath it. Flipped via a post-frame
  // callback rather than during build to avoid mutating state mid-build.
  bool _hasBuiltSession = false;

  bool _seenFirstActiveId = false;
  String? _lastSessionActiveId;

  final SystemShelfService _shelf = SystemShelfService();
  bool Function(String profileId)? _shelfPolicy;
  ActiveProfileProvider? _shelfPolicyProfiles;
  ValueNotifier<bool>? _shelfPolicySelectionOnOpen;

  @override
  void initState() {
    super.initState();
    _installShelfPolicy();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _hasBuiltSession = true;
      }
    });
  }

  @override
  void dispose() {
    _shelfPolicyProfiles?.removeListener(_shelf.refreshPublicationPolicy);
    _shelfPolicySelectionOnOpen?.removeListener(_shelf.refreshPublicationPolicy);
    if (identical(_shelf.publicationPolicy, _shelfPolicy)) _shelf.publicationPolicy = null;
    super.dispose();
  }

  /// Keep PIN-protected profile content off launcher shelves while startup
  /// requires the viewer to choose and authenticate a profile.
  void _installShelfPolicy() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return;
    final activeProfile = context.read<ActiveProfileProvider>();
    bool policy(String profileId) => activeProfile.mayPublishToSystemShelf(profileId, settings);
    _shelfPolicy = policy;
    _shelf.publicationPolicy = policy;
    _shelfPolicyProfiles = activeProfile..addListener(_shelf.refreshPublicationPolicy);
    _shelfPolicySelectionOnOpen = settings.listenable(SettingsService.requireProfileSelectionOnOpen)
      ..addListener(_shelf.refreshPublicationPolicy);
    _shelf.refreshPublicationPolicy();
  }

  /// The keyed remount below recreates every session-scoped provider on a
  /// profile switch, but [ApiCache] is app-global and its Plex rows are
  /// keyed by server only — one home user's cached responses would serve
  /// the next user's session. Clear the volatile rows at the seam itself;
  /// doing it from inside MainScreen can't work, the remount unmounts it
  /// before any settle-await completes.
  void _onSessionProfileChanged(String? activeId) {
    CastMediaService.instance.bindProfile(activeId);
    final shelf = _shelf;
    if (!_seenFirstActiveId) {
      _seenFirstActiveId = true;
      _lastSessionActiveId = activeId;
      if (activeId != null) {
        shelf.beginProfileSession(activeId);
      }
      return;
    }
    final oldOwner = _lastSessionActiveId;
    if (oldOwner == activeId) {
      return;
    }
    if (oldOwner != null) {
      // endProfileSession invalidates synchronously and queues its clear before
      // the new owner is admitted below.
      unawaited(shelf.endProfileSession(oldOwner));
    }
    _lastSessionActiveId = activeId;
    if (activeId != null) {
      shelf.beginProfileSession(activeId);
    }
    unawaited(ApiCache.clearRegisteredVolatile());
  }

  @override
  Widget build(BuildContext context) {
    return Selector<ActiveProfileProvider, String?>(
      selector: (_, activeProfile) => activeProfile.activeId,
      builder: (context, activeId, _) {
        _onSessionProfileChanged(activeId);
        final initialPromptHandled = widget.initialPromptHandled || _hasBuiltSession;
        // A CarPlay-only launch has no view controller to complete native
        // state restoration. Let the audio catalog start immediately.
        final canRestore = !Platform.isIOS || IphoneDuo.of(context).phoneWindowAttached;
        return RootRestorationScope(
          key: ValueKey<String?>('profile-session:$activeId'),
          restorationId: activeId == null || !canRestore ? null : 'profile-session:$activeId',
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<MultiviewWorkspaceController>(
                create: (_) {
                  final workspace = MultiviewWorkspaceController(
                    persistence: const SharedPreferencesWorkspaceSnapshotPersistence(),
                    profileId: activeId,
                  );
                  unawaited(workspace.hydrate());
                  return workspace;
                },
              ),
              Provider<SourceRecoveryBinder?>(
                lazy: false,
                create: (context) {
                  final playback = context.read<SourcePlayback?>();
                  return playback == null
                      ? null
                      : SourceRecoveryBinder(
                          workspace: context.read<MultiviewWorkspaceController>(),
                          playback: playback,
                          profileId: activeId,
                        );
                },
                dispose: (_, binder) => binder?.dispose(),
              ),
              ChangeNotifierProxyProvider<MultiServerProvider, WatchStateStore>(
                create: (_) => WatchStateStore(),
                update: (_, multiServer, previous) {
                  final provider = previous ?? WatchStateStore();
                  provider.setActiveProfileId(activeId);
                  provider.setActiveClientScopesByServer({
                    for (final serverId in multiServer.serverManager.serverIds)
                      serverId: multiServer.serverManager.getClient(ServerId(serverId))?.cacheServerId,
                  });
                  return provider;
                },
              ),
              // Home layout sync follows the active profile's own Plex
              // account (see HomeLayoutSyncBinder).
              Provider<HomeLayoutSyncBinder>(
                lazy: false,
                create: (context) => HomeLayoutSyncBinder(
                  activeProfile: context.read<ActiveProfileProvider>(),
                  connections: context.read<ConnectionRegistry>(),
                  profileConnections: context.read<ProfileConnectionRegistry>(),
                ),
                dispose: (_, binder) => binder.dispose(),
              ),
              ChangeNotifierProvider(
                create: (context) {
                  final provider = TrackersProvider(httpClientFactory: widget.trackerHttpClientFactory);
                  unawaited(
                    provider.onActiveProfileChanged(activeId).catchError((Object e, StackTrace s) {
                      appLogger.w('Trackers profile hydrate failed', error: e, stackTrace: s);
                    }),
                  );
                  return provider;
                },
              ),
              ChangeNotifierProvider(
                create: (context) {
                  final provider = SeerrAccountProvider();
                  provider.bindPlexTokenSupplier(
                    buildSeerrPlexTokenSupplier(
                      activeProfile: context.read<ActiveProfileProvider>(),
                      connections: context.read<ConnectionRegistry>(),
                      profileConnections: context.read<ProfileConnectionRegistry>(),
                    ),
                  );
                  unawaited(
                    provider.onActiveProfileChanged(activeId).catchError((Object e, StackTrace s) {
                      appLogger.w('Seerr profile hydrate failed', error: e, stackTrace: s);
                    }),
                  );
                  return provider;
                },
              ),
              ChangeNotifierProxyProvider4<
                TrackersProvider,
                SeerrAccountProvider,
                ActiveProfileProvider,
                RemoteStreamingProvider,
                CatalogSourcesProvider
              >(
                create: (context) {
                  final provider = _createCatalogSourcesProvider(context);
                  unawaited(
                    provider.onActiveProfileChanged(activeId).catchError((Object e, StackTrace s) {
                      appLogger.w('Catalog sources profile hydrate failed', error: e, stackTrace: s);
                    }),
                  );
                  return provider;
                },
                update: (context, trackers, seerr, activeProfile, streaming, previous) {
                  final provider = previous ?? _createCatalogSourcesProvider(context);
                  provider.update(trackers, seerr, streaming);
                  unawaited(provider.onProfileBindingStateChanged(activeProfile.isBinding));
                  return provider;
                },
              ),
              ChangeNotifierProvider(
                create: (context) => ExploreProvider(context.read<CatalogSourcesProvider>()),
                lazy: true,
              ),
              Provider(
                create: (context) => CatalogLibraryMatcher(context.read<MultiServerProvider>()),
                dispose: (_, matcher) => matcher.dispose(),
                lazy: true,
              ),
              ChangeNotifierProvider(
                create: (context) =>
                    HiddenLibrariesProvider(storageService: context.read<StorageService>(), profileId: activeId),
                lazy: true,
              ),
              ChangeNotifierProvider(
                create: (context) {
                  final activeProfile = context.read<ActiveProfileProvider>();
                  return LibrariesProvider(
                    storageService: context.read<StorageService>(),
                    multiServer: context.read<MultiServerProvider>(),
                    isProfileBinding: () => activeProfile.isBinding,
                  );
                },
              ),
              ChangeNotifierProvider(
                create: (context) {
                  final activeProfile = context.read<ActiveProfileProvider>();
                  return DiscoverProvider(
                    context.read<MultiServerProvider>(),
                    context.read<HiddenLibrariesProvider>(),
                    context.read<LibrariesProvider>(),
                    // Created above in this same subtree, so its lifetime
                    // matches; the proxy reuses `previous`, so the reference
                    // stays valid for as long as this provider does.
                    watchStateStore: context.read<WatchStateStore>(),
                    isProfileBinding: () => activeProfile.isBinding,
                    // Defers push-triggered hub refetches while the player is
                    // up — same playback-quiet policy as the resume gate.
                    isRefreshBlocked: () => VideoPlayerScreenState.activeGlobalKey != null,
                    profileId: activeId,
                  );
                },
              ),
              ChangeNotifierProvider(create: (context) => PlaybackStateProvider()),
              // The paired channel lives for the profile and must be available
              // before the music session binds its transfer endpoint.
              ChangeNotifierProvider(
                create: (context) {
                  final provider = CompanionRemoteProvider();
                  provider.bindSteamAdmission((profileId) async {
                    if (!context.mounted) return null;
                    final sources = context.read<SourceController>();
                    await sources.ready;
                    if (!context.mounted || sources.profileId != profileId) return null;
                    final generation = sources.generation;
                    final data = await sources.repository.preference(profileId, GameLibraryController.preferenceKey);
                    final credential = GameLibrary.fromJson(data).steamCatalogCredential;
                    if (credential == null || !context.mounted || sources.generation != generation) return null;
                    final clear = await CredentialVault.reveal(credential);
                    return context.mounted && sources.generation == generation && sources.profileId == profileId
                        ? clear
                        : null;
                  });
                  provider.bindGameWorkspace(context.read<MultiviewWorkspaceController>());
                  provider.bindProfileServices(
                    connections: context.read<ConnectionRegistry>(),
                    activeProfile: context.read<ActiveProfileProvider>(),
                    profileConnections: context.read<ProfileConnectionRegistry>(),
                    plexHome: context.read<PlexHomeService>(),
                  );
                  return provider;
                },
              ),
              // Profile-session scope so a profile switch tears the music
              // session down (dispose stops playback + releases the audio
              // core).
              ChangeNotifierProvider<MusicPlaybackService>(
                lazy: false,
                create: (context) {
                  final companion = context.read<CompanionRemoteProvider>();
                  final music = MusicPlaybackServiceImpl(
                    serverManager: context.read<MultiServerProvider>().serverManager,
                    database: context.read<AppDatabase>(),
                    offlineWatchService: context.read<OfflineWatchSyncService>(),
                    libraryStore: activeId == null ? null : MusicLibraryStore(context.read<AppDatabase>(), activeId),
                    // Last-session restore (#2148) is per profile; no profile,
                    // nothing to restore.
                    sessionStore: activeId == null
                        ? null
                        : MusicSessionStore(database: context.read<AppDatabase>(), profileId: activeId),
                    onDispose: companion.unbindMusicSession,
                  );
                  companion.bindMusicSession(music);
                  return music;
                },
              ),
              ChangeNotifierProvider(
                create: (context) {
                  final music = context.read<MusicPlaybackService>();
                  final libraries = context.read<LibrariesProvider>();
                  final servers = context.read<MultiServerProvider>();
                  final hidden = context.read<HiddenLibrariesProvider>();
                  return GuestJukebox(music, (library) {
                    final id = serverIdOrNull(library.serverId);
                    if (id == null ||
                        !hidden.isInitialized ||
                        hidden.hiddenLibraryKeys.contains(library.globalKey) ||
                        !libraries.libraries.any((l) => l.globalKey == library.globalKey && !l.hidden) ||
                        !servers.isServerOnline(id)) {
                      return null;
                    }
                    return servers.getClientForServer(id);
                  });
                },
              ),
              ChangeNotifierProvider(
                create: (context) => KaraokeSession(
                  music: context.read<MusicPlaybackService>(),
                  profileId: activeId ?? 'local',
                  profileDisplayName: context.read<ActiveProfileProvider>().active?.displayName,
                ),
              ),
              if (activeId != null)
                ChangeNotifierProvider<MusicExperience>(
                  lazy: false,
                  create: (context) {
                    final manager = context.read<MultiServerProvider>().serverManager;
                    final libraries = context.read<LibrariesProvider>();
                    final hidden = context.read<HiddenLibrariesProvider>();
                    final companion = context.read<CompanionRemoteProvider>();
                    final active = context.read<ActiveProfileProvider>();
                    final offlineRatings = MusicOfflineRatingAccounts(
                      store: MusicLibraryStore(context.read<AppDatabase>(), activeId),
                      connections: context.read<ConnectionRegistry>(),
                      profiles: context.read<ProfileConnectionRegistry>(),
                      current: () => active.activeId == activeId,
                    );
                    final experience = MusicExperience(
                      music: context.read<MusicPlaybackService>(),
                      store: MusicLibraryStore(context.read<AppDatabase>(), activeId),
                      connectionChanges: manager.statusStream,
                      offlineRatingAccountFor: offlineRatings.forItem,
                      pinReady: hidden.ensureInitialized,
                      pinVisible: (item) =>
                          !libraries.isDisposed &&
                          !hidden.isDisposed &&
                          hidden.isInitialized &&
                          item.libraryId != null &&
                          libraries.libraries.any(
                            (library) =>
                                library.kind == MediaKind.artist &&
                                library.serverId == item.serverId &&
                                library.id == item.libraryId &&
                                !library.hidden &&
                                !hidden.hiddenLibraryKeys.contains(library.globalKey),
                          ),
                      syncClients: () => manager.visibleOnlineClients.values,
                      onDispose: (value) {
                        companion.unbindMusicHistory(value.history);
                        CastMediaService.instance.unbindMusicRecovery(value.store);
                      },
                      sharedSources: () async {
                        await hidden.ensureInitialized();
                        return [
                          for (final library in libraries.libraries)
                            if (library.backend == MediaBackend.plex &&
                                library.kind == MediaKind.artist &&
                                library.serverId != null &&
                                !library.hidden &&
                                !hidden.hiddenLibraryKeys.contains(library.globalKey) &&
                                manager.isServerVisible(ServerId(library.serverId!)) &&
                                !manager.isOwnerOrAdmin(ServerId(library.serverId!)))
                              if (manager.getClient(ServerId(library.serverId!)) case final client?)
                                MusicDjSource(
                                  client: client,
                                  libraryId: library.id,
                                  isCurrent: () =>
                                      manager.isServerVisible(ServerId(library.serverId!)) &&
                                      identical(manager.getClient(ServerId(library.serverId!)), client) &&
                                      !manager.isOwnerOrAdmin(ServerId(library.serverId!)) &&
                                      !hidden.hiddenLibraryKeys.contains(library.globalKey) &&
                                      libraries.libraries.any(
                                        (current) => current.globalKey == library.globalKey && !current.hidden,
                                      ),
                                ),
                        ];
                      },
                      clientFor: (item) => item.serverId == null || !manager.isServerVisible(ServerId(item.serverId!))
                          ? null
                          : manager.getClient(ServerId(item.serverId!)),
                    );
                    companion.bindMusicHistory(experience.history);
                    CastMediaService.instance.bindMusicRecovery(experience.store, manager);
                    return experience;
                  },
                ),
              // Per profile: a profile switch disposes of it, which leaves the
              // room and closes the party.
              ChangeNotifierProvider(
                create: (context) {
                  final multiServer = context.read<MultiServerProvider>();
                  final activeProfile = context.read<ActiveProfileProvider>();
                  return WatchTogetherProvider(
                    clientFor: (serverId) => multiServer.getClientForServer(ServerId(serverId)),
                    findCopies: multiServer.aggregationService.findTitleCopiesAcrossServers,
                    displayName: () => activeProfile.active?.displayName ?? 'Pleazyng',
                    profileId: () => activeProfile.activeId,
                  );
                },
              ),
            ],
            child: WatchNoticeListener(
              child: CoveredRouteFocusBoundary(
                child: _ProfileSessionNavigator(
                  isOfflineMode: widget.isOfflineMode,
                  initialPromptHandled: initialPromptHandled,
                  initialSourceLibrary: widget.initialSourceLibrary,
                  profileShellBuilder: widget.profileShellBuilder,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProfileSessionNavigator extends StatefulWidget {
  const _ProfileSessionNavigator({
    required this.isOfflineMode,
    required this.initialPromptHandled,
    required this.initialSourceLibrary,
    required this.profileShellBuilder,
  });

  final bool isOfflineMode;
  final bool initialPromptHandled;
  final bool initialSourceLibrary;
  final WidgetBuilder? profileShellBuilder;

  @override
  State<_ProfileSessionNavigator> createState() => _ProfileSessionNavigatorState();
}

class _ProfileSessionNavigatorState extends State<_ProfileSessionNavigator> with RestorationMixin {
  final _savedVideo = RestorableStringN(null);
  late final _videoTasks = VideoTaskObserver((value) {
    if (mounted && !restorePending) _savedVideo.value = value;
  });
  final _savedRoom = RestorableStringN(null);
  WatchTogetherProvider? _room;
  String? _lastMembership;
  bool _restoringRoom = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final room = context.read<WatchTogetherProvider?>();
    if (identical(room, _room)) return;
    _room?.removeListener(_roomChanged);
    _room = room;
    room?.addListener(_roomChanged);
  }

  void _roomChanged() {
    if (!mounted || restorePending || bucket == null) return;
    final data = _room?.membershipForRestoration;
    if (data == _lastMembership) return;
    _lastMembership = data;
    _savedRoom.value = null;
    if (data == null) return;
    _savedVideo.value = null;
    unawaited(_saveRoom(data));
  }

  Future<void> _saveRoom(String data) async {
    try {
      final protected = await CredentialVault.protect(data);
      if (mounted && !restorePending && _lastMembership == data) _savedRoom.value = protected;
    } catch (_) {
      if (mounted && !restorePending && _lastMembership == data) _savedRoom.value = null; // Discard unsealed tokens.
    }
  }

  Future<void> _restoreRoom(String encrypted, int attempt) async {
    final room = _room;
    final owner = context.read<ActiveProfileProvider>().activeId;
    if (room == null || owner == null || !CredentialVault.isProtected(encrypted)) return;
    final generation = _videoTasks.navigationGeneration;
    bool current() =>
        mounted &&
        attempt == _restoreAttempt &&
        room.profileId == owner &&
        generation == _videoTasks.navigationGeneration &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        context.read<MusicPlaybackService?>()?.currentTrack == null &&
        (_navigatorKey.currentState?.canPop() == false) &&
        (WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
    try {
      final data = await CredentialVault.reveal(encrypted);
      if (data == null || !current() || room.isInSession || PlaybackCoordinator.instance.hasVideoSession) return;
      _restoringRoom = true;
      await room.restoreMembership(data, current: current);
    } catch (error) {
      appLogger.d('Watch Together membership restoration ended', error: error.runtimeType);
    } finally {
      _restoringRoom = false;
      if (mounted && !restorePending && _savedRoom.value == encrypted && !room.isInSession) _savedRoom.value = null;
    }
  }

  int _restoreAttempt = 0;
  @override
  String get restorationId => 'playback-task';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_savedVideo, 'video');
    registerForRestoration(_savedRoom, 'room');
    final room = _savedRoom.value;
    final task = SavedPlaybackTask.decode(_savedVideo.value);
    final attempt = ++_restoreAttempt;
    if (room != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && attempt == _restoreAttempt) unawaited(_restoreRoom(room, attempt));
      });
    } else if (task != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && attempt == _restoreAttempt) unawaited(_restoreVideo(task, attempt));
      });
    }
  }

  Future<void> _restoreVideo(SavedPlaybackTask task, int attempt) async {
    final nav = _navigatorKey.currentState;
    if (nav == null || nav.canPop()) return;
    final profile = context.read<ActiveProfileProvider>();
    final owner = profile.activeId;
    final revision = profile.identityMutationGeneration;
    final routeGeneration = _videoTasks.navigationGeneration;
    bool current() =>
        mounted &&
        owner != null &&
        profile.activeId == owner &&
        profile.identityMutationGeneration == revision &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        (WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) &&
        attempt == _restoreAttempt &&
        routeGeneration == _videoTasks.navigationGeneration &&
        !nav.canPop() &&
        !PlaybackCoordinator.instance.hasVideoSession &&
        context.read<MusicPlaybackService?>()?.currentTrack == null &&
        context.read<WatchTogetherProvider?>()?.isInSession != true;
    if (!current()) return;
    final servers = context.read<MultiServerProvider>();
    final hidden = context.read<HiddenLibrariesProvider>();
    final downloads = context.read<DownloadProvider?>();
    if (task is SavedLiveTask) {
      final playlists = context.read<IptvSourceRepository?>();
      try {
        List<LiveTvChannel> channels = [];
        if (task.iptv) {
          if (playlists == null) return;
          channels = await playlists.channels(owner!);
        } else {
          final id = ServerId(task.ownerId);
          for (var i = 0; i < 24 && current(); i++) {
            final client = servers.getClientForServer(id);
            if (client != null && servers.serverManager.isServerVisible(id)) {
              await servers.checkLiveTvAvailability();
              if (!current()) return;
              for (final source in servers.liveTvServers.where((s) => s.serverId == id)) {
                final rows = await client.liveTv.fetchChannels(lineup: source.lineup);
                if (!current() ||
                    !identical(servers.getClientForServer(id), client) ||
                    !servers.serverManager.isServerVisible(id)) {
                  return;
                }
                channels.addAll(rows.map((c) => c.copyWith(serverId: id, liveDvrKey: source.dvrKey)));
              }
              if (channels.isNotEmpty) break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
        if (!current()) return;
        final channel = channels
            .where(
              (c) =>
                  (c.iptvSourceId ?? c.serverId) == task.ownerId &&
                  SavedLiveTask.digest(liveTvChannelScopeKey(c)) == task.channelDigest,
            )
            .firstOrNull;
        if (channel == null || channel.iptvParentalLocked || channel.drm == true) {
          _savedVideo.value = null;
          return;
        }
        LiveTvProgram? program;
        final epoch = task.epoch;
        if (task.iptv &&
            epoch != null &&
            channel.iptvCatchupAvailable &&
            playlists != null &&
            (channel.iptvCatchupDays == null ||
                DateTime.now().millisecondsSinceEpoch ~/ 1000 - epoch <= channel.iptvCatchupDays! * 86400)) {
          final at = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
          final rows = await playlists.schedule(
            owner!,
            at,
            at.add(const Duration(seconds: 1)),
            sourceId: channel.iptvSourceId,
            channelId: channel.iptvChannelId,
          );
          final airing = rows.firstOrNull;
          if (airing?.endsAt case final end? when end > epoch) {
            program = LiveTvProgram(title: airing!.title, beginsAt: epoch, endsAt: end);
          }
        }
        final routeContext = nav.overlay?.context;
        if (!current() || routeContext == null || !routeContext.mounted) return;
        _savedVideo.value = null;
        await navigateToLiveTv(
          routeContext,
          multiServer: servers,
          channel: channel,
          channels: channels,
          canPresent: current,
          startPosition: LiveTvStartPosition.live,
          initiallyPaused: task.paused,
          restoredBroadcastEpoch: task.epoch,
          program: program,
        );
      } catch (error) {
        appLogger.d('Could not retune restored live channel', error: error.runtimeType);
      }
      return;
    }
    if (task is! SavedVideoTask) return;
    final id = ServerId(task.server);
    final key = buildGlobalKey(id, task.item);
    try {
      await hidden.ensureInitialized();
      // Profile binding, download hydration and server discovery can complete
      // after the shell has already painted. Yield to any new user action.
      for (var i = 0; i < 24 && current(); i++) {
        final client = servers.serverManager.isServerVisible(id) ? servers.getClientForServer(id) : null;
        final local = downloads != null && downloads.activeProfileId == owner && downloads.isDownloaded(key);
        if ((task.offline && local) || (!task.offline && client != null)) {
          final item = task.offline ? downloads!.metadata[key] : await client!.fetchItem(task.item);
          if (!current() ||
              (!task.offline &&
                  (!servers.serverManager.isServerVisible(id) || !identical(servers.getClientForServer(id), client)))) {
            return;
          }
          if (item == null ||
              item.globalKey != key ||
              item.backend.name != task.backend ||
              (item.libraryGlobalKey != null && hidden.isLibraryHidden(item.libraryGlobalKey!))) {
            _savedVideo.value = null;
            return;
          }
          var edition = task.edition;
          final versions = item.mediaVersions;
          if (task.source != null && versions != null && versions.isNotEmpty) {
            edition = versions.indexWhere((version) => version.id == task.source);
            if (edition < 0) {
              _savedVideo.value = null;
              return;
            }
          }
          _savedVideo.value = null;
          final route = VideoPlayerRoute(
            joinsWatchTogether: true,
            builder: (_) => VideoPlayerScreen(
              metadata: item,
              isOffline: task.offline,
              selectedMediaIndex: edition,
              selectedMediaSourceId: task.source,
              initialPosition: Duration(milliseconds: task.positionMs),
              initiallyPaused: task.paused,
              strictMediaSelection: true,
            ),
          );
          unawaited(route.push(nav));
          _videoTasks.record(route, task);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (error) {
      appLogger.d('Could not reopen restored video task', error: error);
    }
  }

  final _navigatorKey = GlobalKey<NavigatorState>();
  final _workspaceOverlayKey = GlobalKey<OverlayState>();
  final _mainScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final _routeObserver = RouteObserver<PageRoute<dynamic>>();

  // Music mini-player wiring: the route observer hides the overlay while the
  // video player / now-playing screen is up; the inset controller lets
  // MainScreen report its bottom-bar height so the overlay floats above it.
  final _musicRouteObserver = MusicUiRouteObserver();
  final _miniPlayerInsets = MiniPlayerInsetController();
  final _settingsRouteTracker = SettingsRouteTracker();

  @override
  void initState() {
    super.initState();
    profileNavigationRegistry.attachNavigator(_navigatorKey);
    profileNavigationRegistry.attachMainScaffoldMessenger(_mainScaffoldMessengerKey);
  }

  @override
  void dispose() {
    profileNavigationRegistry.detachNavigator(_navigatorKey);
    profileNavigationRegistry.detachMainScaffoldMessenger(_mainScaffoldMessengerKey);
    _room?.removeListener(_roomChanged);
    _savedRoom.dispose();
    _savedVideo.dispose();
    _miniPlayerInsets.dispose();
    _musicRouteObserver.suppress.dispose();
    super.dispose();
  }

  Widget _withAgentControls(Widget child) {
    child = MusicCarHost(navigatorKey: _navigatorKey, child: child);
    if (!agentControlEnabled) {
      return child;
    }
    return AgentControlScope(
      profile: true,
      commandContext: () => _navigatorKey.currentState?.overlay?.context,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ProfileNavigationScope(
      navigatorKey: _navigatorKey,
      routeObserver: _routeObserver,
      mainScaffoldMessengerKey: _mainScaffoldMessengerKey,
      child: _withAgentControls(
        PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              return;
            }
            unawaited(_navigatorKey.currentState?.maybePop());
          },
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<MiniPlayerInsetController>.value(value: _miniPlayerInsets),
              Provider<VideoTaskObserver>.value(value: _videoTasks),
              Provider<MusicUiRouteObserver>.value(value: _musicRouteObserver),
            ],
            // The mini-player mounts ABOVE the nested navigator so it persists
            // across content routes (but inside the profile provider scope so
            // it dies with the session). SettingsShortcut wraps both so the
            // desktop open-settings chord also works with mini-player focus.
            child: SettingsShortcut(
              navigatorKey: _navigatorKey,
              settingsRoutes: _settingsRouteTracker,
              child: NavigatorBackHandler(
                navigatorKey: _navigatorKey,
                child: Stack(
                  children: [
                    Listener(
                      onPointerDown: (_) {
                        _restoreAttempt++;
                        if (_restoringRoom && _room?.isReconnecting == true) _room?.leave();
                        if (!_videoTasks.hasOwner && !restorePending) _savedVideo.value = null;
                      },
                      child: Navigator(
                        key: _navigatorKey,
                        restorationScopeId: 'navigation',
                        observers: [_routeObserver, _musicRouteObserver, _settingsRouteTracker, _videoTasks],
                        onGenerateRoute: _onGenerateRoute,
                      ),
                    ),
                    const Positioned.fill(child: MusicMiniPlayerOverlay()),
                    Positioned.fill(
                      child: SourceMiniPlayer(
                        onOpen: () {
                          _navigatorKey.currentState?.push(
                            MaterialPageRoute(
                              settings: const RouteSettings(name: 'source-player'),
                              builder: (_) => const SourcePlayerScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    Overlay(key: _workspaceOverlayKey, initialEntries: const []),
                    MultiviewOverlayHost(
                      controller: context.read<MultiviewWorkspaceController>(),
                      overlayKey: _workspaceOverlayKey,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Route<dynamic> _onGenerateRoute(RouteSettings settings) {
    // This navigator's initial route is the profile shell. Content routes are
    // pushed imperatively from inside the shell, so named routes belong to the
    // root navigator unless this method is expanded intentionally.
    final routeName = settings.name;
    if (routeName != null && routeName != Navigator.defaultRouteName) {
      throw FlutterError('ProfileSessionNavigator does not handle named route "$routeName".');
    }

    return MaterialPageRoute<void>(
      settings: settings,
      builder: (context) =>
          widget.profileShellBuilder?.call(context) ??
          (PlatformDetector.isAutomotiveMedia()
              ? const MusicHomeScreen()
              : MainScreen(
                  isOfflineMode: widget.isOfflineMode,
                  initialPromptHandled: widget.initialPromptHandled,
                  initialSourceLibrary: widget.initialSourceLibrary,
                )),
    );
  }
}

part of '../main.dart';

/// Applies the profile a deep link names once the app is running, from the
/// root navigator so the PIN dialog and the switch outlive the profile
/// session they replace.
class _RootDeepLinkProfileHost implements DeepLinkProfileHost {
  const _RootDeepLinkProfileHost();

  BuildContext? get _context => rootNavigatorKey.currentState?.overlay?.context;

  @override
  List<Profile> get profiles => _context?.read<ActiveProfileProvider>().profiles ?? const [];

  @override
  String? get activeProfileId => _context?.read<ActiveProfileProvider>().activeId;

  @override
  Future<bool> switchTo(Profile profile) async {
    // Playback leaves first so its final progress report still carries the
    // outgoing profile's token.
    final coordinator = PlaybackCoordinator.instance;
    if (!await coordinator.stopVideoAndExit()) {
      await coordinator.shutdownVideo();
    }
    final context = _context;
    if (context == null || !context.mounted) {
      return false;
    }
    return switchProfileFromUi(context, profile);
  }
}

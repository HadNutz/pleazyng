import 'package:collection/collection.dart';

import '../services/settings_service.dart';
import 'active_profile_provider.dart';

extension ProfileSelectionPolicy on ActiveProfileProvider {
  /// The "ask for a profile every time the app opens" rule: the pref only bites
  /// when there is more than one profile to pick from.
  ///
  /// Stated once because the sites must agree — ActiveProfileBinder defers its
  /// cold-start bind exactly when this holds, and SetupScreen/MainScreen pop the
  /// picker exactly when it holds. If they drifted, the binder would defer a bind
  /// that nothing ever prompts for and the user would land on an unbound screen.
  bool requiresSelectionOnOpen(SettingsService settings) =>
      settings.read(SettingsService.requireProfileSelectionOnOpen) && hasMultipleProfiles;

  /// Whether this profile may publish Continue Watching to a launcher shelf
  /// that is visible without opening the app. When startup asks the viewer to
  /// select a profile, a PIN-protected profile must stay behind that gate.
  /// Unknown profiles are withheld until the registry resolves them.
  bool mayPublishToSystemShelf(String profileId, SettingsService settings) {
    final profile = profiles.firstWhereOrNull((candidate) => candidate.id == profileId);
    if (profile == null) return false;
    return !profile.isPinProtected || !requiresSelectionOnOpen(settings);
  }
}

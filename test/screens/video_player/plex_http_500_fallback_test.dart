import 'package:plezy/media/media_backend.dart';

import 'player_startup_failure_test.dart';

void main() {
  runStartupFailureScenario(
    label: 'Plex startup automatically converts after HTTP 500',
    backend: MediaBackend.plex,
    recovered: true,
  );
}

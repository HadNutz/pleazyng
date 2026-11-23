import 'package:plezy/media/media_backend.dart';

import 'player_startup_failure_test.dart';

void main() {
  runStartupFailureScenario(
    label: 'Plex startup reports HTTP 500 after one failed conversion',
    backend: MediaBackend.plex,
  );
}

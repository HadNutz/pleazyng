import unittest

from aerynos.qualify import initial_setup_action


class InitialSetupActionTests(unittest.TestCase):
    def test_fresh_desktop_chooses_start_fresh_before_server_sign_in(self):
        self.assertEqual(
            initial_setup_action({'Import an existing media library?', 'Start fresh', 'Choose a database'}),
            'Start fresh',
        )

    def test_existing_setup_does_not_choose_start_fresh(self):
        self.assertIsNone(initial_setup_action({'Connect to Jellyfin'}))

    def test_unknown_setup_fails_closed_to_existing_timeout_diagnostic(self):
        self.assertIsNone(initial_setup_action({'Something unexpected'}))


if __name__ == '__main__':
    unittest.main()

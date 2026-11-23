"""Publication bootstrap gates and supported public runner dispatch routes."""
import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_all_platforms as release


class PublicationReadinessTests(unittest.TestCase):
    def run_channels(self, settings):
        assets = [
            'pleazyng-android-play.aab', 'SHA256SUMS.txt',
            'pleazyng-amazon-firetv.apk', 'pleazyng-ios-appstore.ipa',
            'pleazyng-tvos-appstore.ipa', 'pleazyng-macos.dmg', 'appcast.xml',
        ]
        secrets = {'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON', 'AMAZON_APPSTORE_CLIENT_ID',
                   'AMAZON_APPSTORE_CLIENT_SECRET', 'APPLE_API_KEY_ID',
                   'APPLE_API_ISSUER_ID', 'APPLE_API_PRIVATE_KEY'}
        calls = []

        def dispatch(workflow, title, fields, purpose, **kwargs):
            calls.append((workflow, title, fields))
            return {'databaseId': 1, 'url': 'https://example.test/run'}

        with contextlib.redirect_stdout(io.StringIO()), patch.object(release, 'release_metadata', return_value={'assets': [{'name': x} for x in assets]}), \
             patch.object(release, 'configured_repo_names', return_value=secrets), \
             patch.object(release, 'configured_repo_variables', return_value=settings), \
             patch.object(release, 'ensure_channel_run', side_effect=dispatch):
            result = release.publish_configured_channels('v3.0.1', '3.0.1', release_sha='a' * 40, include_webos_release=False)
        return calls, result

    def test_unbootstrapped_stores_skip_even_when_secrets_and_assets_exist(self):
        calls, (_, skipped, _) = self.run_channels({})
        self.assertFalse(any(x[0] == 'publish-app-stores.yml' for x in calls))
        self.assertTrue(any('GOOGLE_PLAY_BOOTSTRAP_COMPLETE' in x['reason'] for x in skipped))
        for platform in ('IOS', 'TVOS'):
            self.assertTrue(any(f'APPLE_{platform}_STORE_UPLOAD_READY' in x['reason'] for x in skipped))

    def test_apple_platform_readiness_is_independent(self):
        for platform in ('ios', 'tvos'):
            with self.subTest(platform=platform):
                calls, _ = self.run_channels({
                    'APPLE_STORE_UPLOAD_READY': 'true',
                    f'APPLE_{platform.upper()}_STORE_UPLOAD_READY': 'true',
                })
                channels = [fields['channel'] for workflow, _, fields in calls
                            if workflow == 'publish-app-stores.yml']
                self.assertEqual(channels, [f'app-store-{platform}'])

    def test_closed_beta_activation_uses_public_runner_and_configured_track(self):
        calls, _ = self.run_channels({
            'GOOGLE_PLAY_BOOTSTRAP_COMPLETE': 'true',
            'GOOGLE_PLAY_TRACK': 'alpha', 'GOOGLE_PLAY_RELEASE_STATUS': 'completed',
        })
        play = next(x for x in calls if x[2].get('channel') == 'google-play')
        self.assertEqual(play[2]['runner_pool'], 'public')
        self.assertEqual(play[2]['play_track'], 'alpha')
        self.assertEqual(play[2]['play_release_status'], 'completed')
        self.assertIn('pool:public:', play[1])

    def test_appcast_remains_in_core_release_without_a_cask_candidate(self):
        calls, (_, skipped, failures) = self.run_channels({})
        self.assertFalse(any(x[0] == 'update-packages.yml' for x in calls))
        self.assertFalse(failures)
        self.assertTrue(any(
            item['channel'] == 'Homebrew Cask'
            and 'appcast remains a core GitHub Release asset' in item['reason']
            for item in skipped
        ))

    def test_blocked_apple_signing_skips_store_channels_without_failing_core_delivery(self):
        calls = []
        settings = {
            'APPLE_IOS_STORE_UPLOAD_READY': 'true',
            'APPLE_TVOS_STORE_UPLOAD_READY': 'true',
            'GOOGLE_PLAY_BOOTSTRAP_COMPLETE': 'true',
            'GOOGLE_PLAY_TRACK': 'internal',
        }
        secrets = {
            'APPLE_API_KEY_ID', 'APPLE_API_ISSUER_ID', 'APPLE_API_PRIVATE_KEY',
            'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON',
        }
        assets = {'SHA256SUMS.txt', 'pleazyng-android-play.aab'}
        def dispatch(workflow, title, fields, purpose, **kwargs):
            calls.append(fields)
            return {'databaseId': 1}

        with contextlib.redirect_stdout(io.StringIO()), \
                patch.object(release, 'release_metadata', return_value={'assets': [{'name': x} for x in assets]}), \
                patch.object(release, 'configured_repo_names', return_value=secrets), \
                patch.object(release, 'configured_repo_variables', return_value=settings), \
                patch.object(release, 'ensure_channel_run', side_effect=dispatch):
            _, skipped, failures = release.publish_configured_channels(
                'v3.0.1', '3.0.1', release_sha='a' * 40, include_webos_release=False
            )

        self.assertFalse(failures)
        self.assertFalse(any(x.get('channel', '').startswith('app-store-') for x in calls))
        for channel, asset in (
            ('Apple App Store Connect iOS upload', 'pleazyng-ios-appstore.ipa'),
            ('Apple App Store Connect tvOS upload', 'pleazyng-tvos-appstore.ipa'),
        ):
            entry = next(item for item in skipped if item['channel'] == channel)
            self.assertIn(asset, entry['reason'])
            self.assertIn('unsigned developer package', entry['reason'])

    def test_explicit_production_delivery_skips_the_testing_controller(self):
        calls, _ = self.run_channels({
            'GOOGLE_PLAY_BOOTSTRAP_COMPLETE': 'true',
            'GOOGLE_PLAY_AUTOMATIC_RELEASES': 'false',
            'GOOGLE_PLAY_TRACK': 'production',
            'GOOGLE_PLAY_RELEASE_STATUS': 'completed',
        })
        play = next(fields for _, _, fields in calls if fields.get('channel') == 'google-play')
        self.assertEqual(play['play_track'], 'production')
        self.assertEqual(play['play_release_status'], 'completed')

    def test_production_and_unrecognized_settings_are_rejected(self):
        for settings in [{'GOOGLE_PLAY_TRACK': 'production'}, {'GOOGLE_PLAY_RELEASE_STATUS': 'inProgress'}]:
            with self.assertRaises(release.ReleaseError):
                release.play_publication_settings(settings)


if __name__ == '__main__':
    unittest.main()

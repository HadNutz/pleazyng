#!/usr/bin/env python3
"""Guard the prerequisite order that caused exact-head native CI failures."""
from pathlib import Path
import re
import shlex
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/ci.yml'
APPLE_SUITE = ROOT / '.github/actions/apple-native-reliability/action.yml'


def job(text: str, name: str) -> str:
    match = re.search(rf'^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:|\Z)', text, re.M | re.S)
    if match is None:
        raise AssertionError(f'Missing CI job: {name}')
    return match.group(1)


def step(text: str, name: str) -> str:
    match = re.search(rf'^(?P<indent> +)- name: {re.escape(name)}\n.*?(?=^(?P=indent)- |\Z)', text, re.M | re.S)
    if match is None:
        raise AssertionError(f'Missing preparation step: {name}')
    return match.group(0)


class NativePreparationOrderTests(unittest.TestCase):
    def test_independent_ci_jobs_can_start_without_waiting_for_other_suites(self):
        workflow = WORKFLOW.read_text()
        for name in ('android-test', 'linux-native-test', 'server'):
            with self.subTest(job=name):
                self.assertNotRegex(job(workflow, name), r'(?m)^    needs:')
                self.assertNotIn('${{ needs.', job(workflow, name))

    def test_desktop_native_builds_use_the_current_application_target(self):
        workflow = WORKFLOW.read_text()
        for platform in ('linux', 'windows'):
            with self.subTest(platform=platform):
                cmake = (ROOT / f'{platform}/CMakeLists.txt').read_text()
                binary = re.search(r'set\(BINARY_NAME "([^"]+)"\)', cmake)
                self.assertIsNotNone(binary)
                build = step(job(workflow, f'{platform}-native-test'),
                             f'Build {platform.title()} native reliability tests')
                self.assertRegex(build, rf'(?m)^\s+{re.escape(binary[1])} [\\`]\s*$')

    def test_desktop_runtime_is_ready_before_flutter_and_cmake(self):
        text = WORKFLOW.read_text()
        for job_name, platform, architectures in (
            ('linux-native-test', 'linux', ['x64']),
            ('linux-packages', 'linux', ['x64']),
            ('windows-native-test', 'windows', ['x64', 'arm64']),
        ):
            with self.subTest(job=job_name):
                body = job(text, job_name)
                prepare = step(body, f'Build bundled MilkRust for {platform.title()}')
                # Runtime staging cannot depend on cache misses or optional flags.
                self.assertNotRegex(prepare, r'(?m)^        if:', msg=prepare)
                self.assertNotIn('continue-on-error', prepare)
                commands = re.findall(r'flutter build (?:linux|windows)\b|cmake -S (?:linux|windows)\b', body)
                self.assertTrue(commands, 'The job must configure the actual app/native targets')
                for command in commands:
                    self.assertLess(body.index(prepare), body.index(command))
                command = prepare.split('        run: ', 1)[1].strip()
                for arch in architectures:
                    args = shlex.split(command.replace('${{ matrix.arch }}', arch))
                    self.assertEqual(args[1], 'scripts/visualizer/build_runtime.py')
                    self.assertEqual(args[args.index('--platform') + 1], platform)
                    self.assertEqual(args[args.index('--architectures') + 1], arch)
                    self.assertEqual(args[args.index('--output') + 1], 'build/visualizer-native')
                if platform == 'windows':
                    self.assertIn('shell: pwsh', prepare)
                    self.assertIn('--architectures "${{ matrix.arch }}"', prepare)

    def test_apple_refresh_follows_pub_get_and_precedes_every_flutter_config(self):
        body = APPLE_SUITE.read_text()
        dependencies = step(body, 'Install locked Dart dependencies')
        self.assertIn('flutter pub get --enforce-lockfile --no-example', dependencies)
        for platform, slug in (('iOS', 'ios'), ('macOS', 'macos')):
            with self.subTest(platform=platform):
                refresh = step(body, f'Refresh pinned {platform} Swift packages')
                configure = step(body, f'Prepare {platform} Flutter build settings')
                self.assertIn(f"inputs.platform == '{platform}'", refresh)
                self.assertIn(f'run: scripts/refresh_apple_spm.sh {slug}', refresh)
                self.assertNotIn('--reset', refresh, 'Refresh must preserve the existing package cache')
                self.assertLess(body.index(dependencies), body.index(refresh))
                self.assertLess(body.index(refresh), body.index(configure))
                for match in re.finditer(rf'flutter build {slug}\b', body):
                    self.assertLess(body.index(refresh), match.start())

    def test_one_apple_job_requires_all_three_suite_outcomes(self):
        apple = yaml.safe_load(WORKFLOW.read_text())['jobs']['apple-native-test']
        self.assertEqual(apple['name'], 'Apple native reliability')
        self.assertNotIn('strategy', apple)
        self.assertFalse(apple.get('continue-on-error'))
        suite_steps = [s for s in apple['steps'] if s.get('uses') == './.github/actions/apple-native-reliability']
        self.assertCountEqual([(s['id'], s['with']['platform']) for s in suite_steps],
                              [('ios', 'iOS'), ('macos', 'macOS'), ('tvos', 'tvOS')])
        gate = next(s for s in apple['steps'] if s.get('name') == 'Require every Apple native suite')
        self.assertEqual(gate.get('if'), '${{ !cancelled() }}')
        self.assertFalse(gate.get('continue-on-error'))
        shared_tools = next(s for s in apple['steps'] if s.get('id') == 'apple_tools')
        for suite in suite_steps:
            self.assertFalse(suite.get('continue-on-error'))
            self.assertEqual(suite.get('if'), "${{ !cancelled() && steps.apple_tools.outcome == 'success' }}")
            self.assertLess(apple['steps'].index(shared_tools), apple['steps'].index(suite))
            self.assertLess(apple['steps'].index(suite), apple['steps'].index(gate))
        # Exercise the checked-in shell gate with the actual step-outcome bindings.
        bindings = {}
        for key, value in gate['env'].items():
            match = re.fullmatch(r'\$\{\{ steps\.(ios|macos|tvos)\.outcome \}\}', value)
            if match:
                bindings[match[1]] = key
        self.assertEqual(set(bindings), {'ios', 'macos', 'tvos'})
        outcomes = {**dict.fromkeys(bindings.values(), 'success'), 'GITHUB_STEP_SUMMARY': '/dev/null'}

        def status(env):
            return subprocess.run(['bash', '-euo', 'pipefail', '-c', gate['run']], env=env,
                                  capture_output=True, text=True).returncode

        self.assertEqual(status(outcomes), 0)
        for platform, key in bindings.items():
            for outcome in ('failure', 'skipped', 'cancelled'):
                with self.subTest(platform=platform, outcome=outcome):
                    self.assertNotEqual(status({**outcomes, key: outcome}), 0)

    def test_apple_native_job_installs_required_runtime_generators(self):
        body = job(WORKFLOW.read_text(), 'apple-native-test')
        tools = step(body, 'Ensure CMake for the embedded Steam receiver')
        self.assertIn('command -v xcodegen >/dev/null || brew install xcodegen', tools)
        self.assertIn('command -v git-lfs >/dev/null || brew install git-lfs', tools)

    def test_private_apple_suites_verify_their_selected_sdk_before_allocating_scratch(self):
        prepare = yaml.safe_load(APPLE_SUITE.read_text())['runs']['steps'][0]['run']
        probes = """
            xcodebuild() { [[ "$*" == '-version' ]] && echo "Xcode $XCODE_VERSION"; }
            xcrun() { [[ "$*" == "--sdk $EXPECTED_SDK --show-sdk-version" ]] && echo "$SDK_VERSION"; }
            bash() { [[ "$1" == scripts/prepare_apple_jit_scratch.sh ]]; }
        """
        for platform, sdk in [('iOS', 'iphonesimulator'), ('macOS', 'macosx'), ('tvOS', 'appletvsimulator')]:
            for runner, xcode, actual_sdk, ok in [
                ('self-hosted', '27.0', '27.0', True),
                ('self-hosted', '26.5', '27.0', False),
                ('self-hosted', '27.0', '26.5', False),
                ('github-hosted', '26.5', '26.5', True),
            ]:
                with self.subTest(platform=platform, runner=runner, xcode=xcode, sdk=actual_sdk):
                    env = dict(RUNNER_ENVIRONMENT=runner, PLATFORM=platform, XCODE_VERSION=xcode,
                               EXPECTED_SDK=sdk, SDK_VERSION=actual_sdk, GITHUB_OUTPUT='/dev/null',
                               RUNNER_TEMP='/fixture', PUB_CACHE=f'/fixture/apple-native-pub-{platform}')
                    result = subprocess.run(['bash', '-euo', 'pipefail', '-c', probes + prepare],
                                            env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, ok, result.stderr)

    def test_private_checkout_and_cleanup_preserve_scratch_ownership(self):
        steps = {s['name']: s for s in yaml.safe_load(APPLE_SUITE.read_text())['runs']['steps']}
        checkout = steps['Check out the exact source for this suite']['run']
        self.assertIn('if [[ "$RUNNER_ENVIRONMENT" == self-hosted ]]; then', checkout)
        self.assertIn('scripts/copy_apple_jit_sources.py "$GITHUB_WORKSPACE" "$SUITE_ROOT" "$GITHUB_SHA"', checkout)
        self.assertIn('ln -s "$APPLE_LOCAL_BUILD_DIR" "$SUITE_ROOT/build"', checkout)
        cleanup = steps['Clean Apple build scratch']['run']
        self.assertRegex(cleanup, r'if \[\[ "\$APPLE_HOSTED_SCRATCH" == 1 && [^\n]+\n\s+git worktree remove')
        self.assertIn('bash scripts/cleanup_apple_jit_scratch.sh "$APPLE_SCRATCH_JOB"', cleanup)

    def test_apple_simulator_evidence_is_retained_before_scratch_cleanup(self):
        action_steps = yaml.safe_load(APPLE_SUITE.read_text())['runs']['steps']
        steps = {s['name']: s for s in action_steps}
        cleanup = steps['Clean Apple build scratch']
        for name, condition, artifact, output in (
            ('Retain failed Apple native test results', 'failure()', 'apple-native-results',
             'steps.scratch.outputs.APPLE_RESULT_BUNDLE'),
            ('Retain Apple simulator ownership receipt', 'always()', 'apple-simulator',
             'steps.destination.outputs.APPLE_SIMULATOR_RECEIPT'),
        ):
            with self.subTest(name=name):
                upload = steps[name]
                self.assertIn(condition, upload['if'])
                self.assertTrue(upload['uses'].startswith('actions/upload-artifact@'))
                self.assertEqual(upload['with']['name'],
                                 artifact + '-${{ inputs.platform }}-${{ github.run_id }}-${{ github.run_attempt }}')
                self.assertIn('${{ ' + output + ' }}', upload['with']['path'].splitlines())
                self.assertLess(action_steps.index(upload), action_steps.index(cleanup))

    def test_unit_job_is_the_only_full_application_suite(self):
        workflow = WORKFLOW.read_text()
        analysis = job(workflow, 'analyze')
        unit = job(workflow, 'test')
        self.assertNotRegex(analysis, r'flutter test\b|scripts/run_tests\.sh\b')
        self.assertIn('dart run scripts/checks/check_analyzer.dart', step(analysis, 'Analyze code'))
        self.assertEqual(workflow.count('scripts/run_tests.sh'), 1)
        self.assertIn('scripts/run_tests.sh -j 2 --timeout=120s', step(unit, 'Run tests'))
        # These independent suites are intentional coverage, not duplicates.
        for name in (
            'Run real reader browser checks',
            'Run wakelock_plus VM tests',
            'Run wakelock_plus Chrome tests',
            'Run the vendored desktop preference store tests',
        ):
            self.assertTrue(step(unit, name))

    def test_required_runtime_receipts_are_not_bypassed(self):
        workflow = WORKFLOW.read_text()
        for name in ('linux-native-test', 'linux-packages', 'windows-native-test'):
            self.assertNotIn('PLEZY_VISUALIZER_REQUIRE_MILKRUST=OFF', job(workflow, name))
        cmake = (ROOT / 'native/visualizer/milkrust.cmake').read_text()
        self.assertIn('option(PLEZY_VISUALIZER_REQUIRE_MILKRUST "Require the bundled native visualization runtime" ON)', cmake)
        self.assertIn('Staged MilkRust runtime differs from the app source pin', cmake)
        self.assertIn('MilkRust runtime is missing:', cmake)


if __name__ == '__main__':
    unittest.main()

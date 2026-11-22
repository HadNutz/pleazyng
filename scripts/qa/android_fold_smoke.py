"""Exercise an installed Pleazyng APK on a foldable Android device or emulator."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time


def adb(*args):
    return subprocess.check_output(['adb', *args], text=True, timeout=35).strip()


def wait_for(read, predicate, label):
    limit = time.monotonic() + 45
    while time.monotonic() < limit:
        value = read()
        if predicate(value):
            return value
        time.sleep(1)
    raise RuntimeError(f'{label} timed out')


def supported_states(output):
    return {name.upper(): int(number) for number, name in
            re.findall(r"(?:identifier|mIdentifier|id)\s*=\s*(\d+).*?(?:name|mName)\s*=\s*['\"]([^'\"]+)", output)}


def active_session(output, package):
    sessions = []
    for block in re.split(r'(?m)^\s*package=', output)[1:]:
        if block.splitlines()[0].strip() != package or not re.search(r'(?m)^\s*active=true\s*$', block):
            continue
        state = re.search(r'PlaybackState\s*\{\s*state=(?:[A-Z_]+\()?(\d+)\)?.*?position=(-?\d+)', block, re.S)
        if state and state[1] in ('2', '3'):
            sessions.append({'state': 'playing' if state[1] == '3' else 'paused', 'positionMs': int(state[2])})
    return sessions[0] if len(sessions) == 1 else None


def state_id():
    output = adb('shell', 'cmd', 'device_state', 'print-state')
    match = re.search(r'(?:identifier|mIdentifier|id)\s*=\s*(\d+)', output)
    return int(match[1]) if match else int(output) if output.isdecimal() else None


def run(args):
    package = args.package
    samples = []
    report = {
        'package': package, 'commit': args.commit, 'model': adb('shell', 'getprop', 'ro.product.model'),
        'fingerprint': adb('shell', 'getprop', 'ro.build.fingerprint'), 'observations': samples,
    }

    def pid():
        try:
            return adb('shell', 'pidof', '-s', package)
        except subprocess.CalledProcessError:
            return ''

    def resumed():
        return any(package in line for line in adb('shell', 'dumpsys', 'activity', 'activities').splitlines()
                   if 'ResumedActivity' in line or 'topResumedActivity' in line)

    def session():
        return active_session(adb('shell', 'dumpsys', 'media_session'), package)

    def launch():
        adb('shell', 'am', 'start', '-W', '-n', f'{package}/com.edde746.plezy.PlezyActivity')

    def capture(step, expected_state=None):
        if pid() != owner:
            raise RuntimeError(f'Application process changed during {step}')
        row = {'step': step, 'pid': owner}
        if args.playback:
            observed = wait_for(session, lambda s: s and (expected_state is None or s['state'] == expected_state),
                                'One active Pleazyng playback session with the expected transport state')
            row.update(observed)
        samples.append(row)
        print(json.dumps(row), flush=True)
        return row.get('state')

    states = []
    if not args.manual:
        supported = supported_states(adb('shell', 'cmd', 'device_state', 'print-states'))
        if args.states:
            states = [int(x) for x in args.states.split(',')]
            if supported and not set(states).issubset(supported.values()):
                raise ValueError(f'Choose posture IDs from {supported}')
        else:
            closed = next((n for k, n in supported.items() if k in {'CLOSED', 'FOLDED'}), None)
            opened = next((n for k, n in supported.items() if k in {'OPEN', 'OPENED', 'FLAT', 'UNFOLDED'}), None)
            half = next((n for k, n in supported.items() if 'HALF' in k or 'TABLETOP' in k), None)
            if closed is None or opened is None:
                raise ValueError(f'Choose --states from {supported} or use --manual')
            states = [closed, opened, *([half] if half is not None else []), opened, closed]

    if not args.playback:
        adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
        adb('shell', 'wm', 'dismiss-keyguard')
        launch()
    owner = wait_for(pid, str.isdecimal, 'Initial application process')
    wait_for(resumed, bool, 'Foreground Pleazyng')
    transport = capture('initial')
    try:
        for step in args.manual.split(',') if args.manual else states:
            if args.manual:
                input(f'Move the device to {step} and press Enter: ')
            else:
                adb('shell', 'cmd', 'device_state', 'state', str(step))
                wait_for(state_id, lambda value: value == step, f'Posture {step}')
            wait_for(resumed, bool, 'Resumed activity')
            capture(step, transport)
        if args.pip:
            adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
            def pinned():
                return any(package in line and re.search(r'\b(?:mode|windowingMode)=pinned\b', line, re.I)
                           for line in adb('shell', 'dumpsys', 'activity', 'activities').splitlines())
            wait_for(pinned, bool, 'Pleazyng pinned task')
            capture('PiP', transport)
            launch()
            wait_for(resumed, bool, 'Return from PiP')
            capture('return', transport)
        report['passed'] = True
    finally:
        if args.evidence:
            args.evidence.write_text(json.dumps(report, indent=2) + '\n')
        if states:
            adb('shell', 'cmd', 'device_state', 'state', 'reset')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', default='org.snapetech.pleazyng')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--states', help='Comma-separated device_state posture IDs in test order')
    mode.add_argument('--manual', help='Comma-separated posture labels for physical folding')
    parser.add_argument('--playback', action='store_true', help='Begin with a video playing or paused in the foreground')
    parser.add_argument('--pip', action='store_true', help='Exercise Home auto-PiP and return during playback')
    parser.add_argument('--commit', help='Build commit under qualification')
    parser.add_argument('--evidence', type=Path, help='Write the observations as JSON')
    options = parser.parse_args()
    if options.pip and not options.playback:
        parser.error('--pip requires --playback')
    run(options)

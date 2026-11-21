"""Exercise an installed Pleazyng APK on a foldable Android emulator."""
import argparse
import re
import subprocess
import time


def adb(*args):
    return subprocess.check_output(['adb', *args], text=True, timeout=35).strip()


def wait_for(read, predicate, label):
    limit = time.monotonic() + 45
    last = None
    while time.monotonic() < limit:
        last = read()
        if predicate(last):
            return last
        time.sleep(1)
    raise RuntimeError(f'{label} timed out: {str(last)[:700]}')


def supported_states(output):
    return {name.upper(): int(number) for number, name in
            re.findall(r"(?:identifier|mIdentifier|id)\s*=\s*(\d+).*?(?:name|mName)\s*=\s*['\"]([^'\"]+)", output)}


def run(package):
    states = supported_states(adb('shell', 'cmd', 'device_state', 'print-states'))
    closed = next((n for k, n in states.items() if k in {'CLOSED', 'FOLDED'}), None)
    opened = next((n for k, n in states.items() if k in {'OPEN', 'OPENED', 'FLAT', 'UNFOLDED'}), None)
    if closed is None or opened is None:
        raise ValueError(f'The emulator needs both closed and open postures: {states}')
    half = next((n for k, n in states.items() if 'HALF' in k or 'TABLETOP' in k), None)
    adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    adb('shell', 'wm', 'dismiss-keyguard')
    adb('shell', 'am', 'start', '-W', '-n', f'{package}/com.edde746.plezy.PlezyActivity')

    def pid():
        try:
            return adb('shell', 'pidof', '-s', package)
        except subprocess.CalledProcessError:
            return ''

    owner = wait_for(pid, str.isdecimal, 'Initial application process')
    try:
        for state in [closed, opened, *([half] if half is not None else []), opened, closed]:
            adb('shell', 'cmd', 'device_state', 'state', str(state))
            def current():
                output = adb('shell', 'cmd', 'device_state', 'print-state')
                match = re.search(r'(?:identifier|mIdentifier|id)\s*=\s*(\d+)', output)
                return int(match.group(1)) if match else int(output) if output.isdecimal() else output
            wait_for(current, lambda value: value == state, f'Posture {state}')
            def resumed():
                return [line for line in adb('shell', 'dumpsys', 'activity', 'activities').splitlines()
                        if 'ResumedActivity' in line or 'topResumedActivity' in line]
            wait_for(resumed, lambda lines: any(package in line for line in lines), 'Resumed activity')
            if pid() != owner:
                raise RuntimeError(f'Pleazyng restarted during transition to {state}')
            print(f'Posture {state}: app resumed, PID {owner}')
    finally:
        adb('shell', 'cmd', 'device_state', 'state', 'reset')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', default='org.snapetech.pleazyng')
    run(parser.parse_args().package)

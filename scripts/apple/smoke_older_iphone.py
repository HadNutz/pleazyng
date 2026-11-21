"""Launch the same iOS simulator application on a pre-Duo runtime."""
import argparse
import json
import os
import plistlib
import subprocess
import time
from pathlib import Path


def sim(*args):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True).strip()


def older_iphone(inventory):
    for runtime in sorted(inventory['runtimes'], key=lambda r: tuple(int(n) for n in r['version'].split('.')),
                          reverse=True):
        if not runtime.get('isAvailable') or '.iOS-' not in runtime['identifier'] or not runtime['version'].startswith('26.'):
            continue
        models = [d for d in runtime.get('supportedDeviceTypes', []) if d.get('productFamily') == 'iPhone'
                  or d.get('identifier', '').startswith('com.apple.CoreSimulator.SimDeviceType.iPhone-')]
        if not models:
            models = [{'identifier': d['deviceTypeIdentifier']} for d in inventory.get('devices', {}).get(runtime['identifier'], [])
                      if d.get('isAvailable') and '.iPhone-' in d.get('deviceTypeIdentifier', '')]
        if models:
            return runtime['identifier'], models[0]['identifier']
    return None


def main(products):
    apps = [path for path in products.glob('*.app') if (path / 'Frameworks/App.framework').is_dir()]
    if len(apps) != 1:
        raise ValueError(f'Expected one built Flutter simulator app, found {apps}')
    info = plistlib.loads((apps[0] / 'Info.plist').read_bytes())
    target = older_iphone(json.loads(sim('list', '-j')))
    if target is None:
        subprocess.run(['xcodebuild', '-downloadPlatform', 'iOS', '-buildVersion', '26.5'], check=True)
        target = older_iphone(json.loads(sim('list', '-j')))
    if target is None:
        raise RuntimeError('Unable to install an iOS 26 phone runtime for compatibility testing')
    runtime, model = target
    udid = sim('create', f'Pleazyng-compat-{os.getpid()}', model, runtime)
    try:
        sim('boot', udid)
        sim('bootstatus', udid, '-b')
        sim('install', udid, str(apps[0]))
        bundle = info['CFBundleIdentifier']
        launch = sim('launch', udid, bundle)
        pid = int(launch.rsplit(':', 1)[1].strip())
        # Simulator processes are host processes. Catch a delayed Flutter-engine
        # or dyld crash, rather than accepting the launch request itself.
        for _ in range(15):
            time.sleep(1)
            os.kill(pid, 0)
        print(f'{bundle} remained running on {model}, {runtime} ({pid})')
    finally:
        sim('delete', udid)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('products', type=Path)
    main(parser.parse_args().products)

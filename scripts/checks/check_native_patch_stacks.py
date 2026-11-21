#!/usr/bin/env python3
"""Apply the native patches to disposable copies of the sources used by the builds."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
TV = ROOT / 'scripts/tv_mpv'
VIS = ROOT / 'native/visualizer'
sys.path.insert(0, str(TV))
from build import ORIGIN, RECIPE
sys.path.insert(0, str(VIS))
from prepare_sources import checkout, prepare


def run(work, *args):
    subprocess.run(args, cwd=work, check=True)


def check_set(folder, expected):
    found = {p.name for p in folder.glob('*.patch')}
    if found != set(expected):
        raise SystemExit(f'{folder}: unaccounted or missing patches: {sorted(found ^ set(expected))}')


def tv_patches(work):
    recipe = checkout('recipe', work, {'repository': ORIGIN, 'commit': RECIPE})
    check_set(TV, ['video.patch', 'sw-subtitles.patch', 'framerate-opencl.patch'])
    run(recipe, 'git', 'apply', '--unidiff-zero', str(TV / 'video.patch'))
    manifest = (recipe / 'scripts/shared/_sources.sha256').read_text().splitlines()
    for component, pattern, patch in [
        ('mpv', r'https://github\.com/mpv-player/mpv/archive/refs/tags/v[\d.]+\.tar\.gz', 'sw-subtitles.patch'),
        ('ffmpeg', r'https://ffmpeg\.org/releases/ffmpeg-[\d.]+\.tar\.gz', 'framerate-opencl.patch'),
    ]:
        (digest, url), = [line.split() for line in manifest if len(line.split()) == 2 and re.fullmatch(pattern, line.split()[1])]
        archive = work / (component + '.tar.gz')
        with urlopen(url, timeout=120) as source, archive.open('wb') as output:
            shutil.copyfileobj(source, output)
        with archive.open('rb') as contents:
            if hashlib.file_digest(contents, 'sha256').hexdigest() != digest:
                raise SystemExit(f'{component}: source archive checksum mismatch')
        dest = work / component
        dest.mkdir()
        with tarfile.open(archive) as tar:
            tar.extractall(dest, filter='data')
        source_root, = dest.iterdir()
        run(source_root, 'patch', '--batch', '--fuzz=0', '--forward', '-p1', '-i', str(TV / patch))
        print(f'{component}: applied {patch} to {digest}', flush=True)


def visualizer_patches(work):
    lock = json.loads((VIS / 'sources.lock.json').read_text())
    check_set(VIS / 'patches', [Path(lock['projectm']['patch']).name, Path(lock['mpv']['patch']).name,
                                Path(lock['appMpvBuild']['androidBridgePatch']).name])
    prepare('projectm', work, lock, VIS, 'android')
    prepare('mpv', work, lock, VIS, 'android')
    # This patch has already landed in the visualizer producer. Reverse-check
    # every hunk against its pinned postimage without changing that checkout.
    run(work / 'mpv-build', 'git', 'apply', '--reverse', '--check',
        str(VIS / lock['appMpvBuild']['androidBridgePatch']))
    # The bridge already ships in the producer. Verify the pinned shipping
    # source as well as the older visualizer lock, including its ordered PCM API.
    shipping = json.loads((ROOT / 'mpv-build.lock.json').read_text())
    producer = checkout('shipping-mpv-build', work, {
        'repository': 'https://github.com/' + shipping['repo'] + '.git', 'commit': shipping['commit'],
    })
    bridge = producer / 'platforms/android/lib/src/main/cpp/session.cpp'
    for symbol in ('plezy_android_subtitle_capture_read_next', 'mpv_plezy_audio_tap_read_next'):
        if symbol not in bridge.read_text():
            raise SystemExit(f'{shipping["commit"]}: Android bridge missing {symbol}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stack', choices=['tv', 'visualizer'])
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='pleazyng-native-patches-') as temp:
        (tv_patches if args.stack == 'tv' else visualizer_patches)(Path(temp))


if __name__ == '__main__':
    main()

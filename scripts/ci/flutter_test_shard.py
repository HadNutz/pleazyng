"""Partition every Flutter test once, using measured suite spans from v3.0.46."""
import argparse
import json
from pathlib import Path
import subprocess


def partition(files, weights, count):
    groups = [[] for _ in range(count)]
    totals = [0] * count
    for path in sorted(files, key=lambda p: (-weights.get(p, 1), p)):
        index = min(range(count), key=totals.__getitem__)
        groups[index].append(path)
        totals[index] += weights.get(path, 1)
    return groups


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('shard', type=int, choices=range(1, 4))
    args = parser.parse_args()
    weights = json.loads(Path(__file__).with_name('flutter_test_weights.json').read_text())
    files = [p.as_posix() for p in Path('test').rglob('*_test.dart')]
    selected = partition(files, weights, 3)[args.shard - 1]
    if not selected:
        raise SystemExit('Empty Flutter test shard')
    subprocess.run(['scripts/run_tests.sh', '-j', '2', '--timeout=120s', *selected], check=True)

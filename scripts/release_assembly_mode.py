"""Choose fresh assembly or append-only recovery without replacing published assets."""
import json
import os
from pathlib import Path
import subprocess


def assembly_mode(packaging_sha, status, release):
    if not packaging_sha:
        return False
    if status == 404:
        return False
    if status != 200:
        raise ValueError('Release lookup failed; refusing to infer a fresh release')
    if (not isinstance(release, dict) or type(release.get('id')) is not int
            or release['id'] < 1 or release.get('draft') is not False
            or not release.get('published_at')):
        raise ValueError('Existing release is not published; inspect its side effects before recovery')
    return True


def main():
    packaging = os.environ.get('PACKAGING_SOURCE_SHA', '')
    release = None
    status = 404
    if packaging:
        repo, tag = os.environ['GITHUB_REPOSITORY'], os.environ['RELEASE_TAG']
        result = subprocess.run(['gh', 'api', '--include', f'repos/{repo}/releases/tags/{tag}'],
                                capture_output=True, text=True)
        # gh --include emits the HTTP status/headers before the JSON body.
        blocks = result.stdout.replace('\r\n', '\n').split('\n\n', 1)
        header = blocks[0].splitlines()[0] if blocks[0] else ''
        parts = header.split()
        status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        if status == 200 and result.returncode == 0:
            release = json.loads(blocks[1])
        elif status != 404:
            raise ValueError('Release lookup did not return a verified 200 or 404')
    append = assembly_mode(packaging, status, release)
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
        output.write(f'append_only={str(append).lower()}\n')
    print('Verified published release: append signed Apple assets only' if append
          else 'No published release: assemble and verify complete release coverage')


if __name__ == '__main__':
    main()

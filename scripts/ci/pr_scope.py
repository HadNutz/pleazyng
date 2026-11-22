"""Classify the tested merge tree. Unknown revisions and workflow changes run all checks."""
import os
from pathlib import Path
import subprocess


def checks(paths):
    def editorial(path):
        return path in {'CHANGELOG.md', 'UPSTREAM_ATTRIBUTION.md', 'README.md'} or (
            path.startswith('docs/') and path.endswith('.md'))
    changed = {p for p in paths if not editorial(p)}
    infrastructure = any(p.startswith(('.github/', 'scripts/ci/')) for p in changed)
    return (infrastructure or any(not p.startswith('server/') for p in changed),
            infrastructure or any(p.startswith('server/') for p in changed))


def main():
    app = server = True
    if (os.environ.get('GITHUB_EVENT_NAME') == 'pull_request' and
            subprocess.run(['git', 'rev-parse', '--verify', '--quiet', 'HEAD^2'], stdout=subprocess.DEVNULL).returncode == 0):
        result = subprocess.run(['git', 'diff', '--name-only', '--no-renames', '-z', 'HEAD^1', 'HEAD'],
                                stdout=subprocess.PIPE)
        if result.returncode == 0 and result.stdout:
            app, server = checks(os.fsdecode(result.stdout).rstrip(chr(0)).split(chr(0)))
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
        print(f'app={str(app).lower()}', f'server={str(server).lower()}', sep=chr(10), file=output)


if __name__ == '__main__':
    main()

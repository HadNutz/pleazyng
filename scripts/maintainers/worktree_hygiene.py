#!/usr/bin/env python3
"""Inventory, archive and remove linked Git worktrees without losing work.

Subcommands:
  report   Read-only inventory. Warns when the count exceeds --warn-over or a
           worktree lives inside the main checkout or a build directory.
  archive  Write patches, untracked-file tarballs, archive refs and a verified
           bundle for every linked worktree and stash into --archive-dir.
  remove   Remove only worktrees classified "safe" whose archive exists.
           Dry run unless --apply is given.

See docs/maintainers/worktree-hygiene.md.
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
import subprocess
import sys
from pathlib import Path

# Files a policy-sync tool may rewrite in every worktree; a difference only in
# these does not count as task work.
SYNCED_FILES = {'AGENTS.md'}
BUILD_MARKERS = ('/build/', '/.dart_tool/')


def git(*args: str, cwd: str | Path | None = None, check: bool = True) -> str:
    result = subprocess.run(
        ['git', *args], cwd=cwd, check=check, capture_output=True, text=True
    )
    return result.stdout


@dataclasses.dataclass
class Worktree:
    path: str
    head: str
    branch: str | None
    locked: bool
    exists: bool
    commits_not_on_main: int = 0
    unmerged_patches: int = 0
    changed: list[str] = dataclasses.field(default_factory=list)
    untracked: int = 0
    busy: bool = False

    @property
    def task_changes(self) -> list[str]:
        return [f for f in self.changed if f not in SYNCED_FILES]

    def classify(self, main_checkout: str) -> str:
        if not self.exists:
            return 'missing'
        if self.busy:
            return 'busy'
        if self.locked:
            return 'locked'
        if self.branch:
            return 'branch-checked-out'
        if self.unmerged_patches and self.commits_not_on_main:
            return 'review-commits'
        if self.task_changes:
            return 'review-changes'
        if self.untracked:
            return 'review-untracked'
        return 'safe'

    def misplaced(self, main_checkout: str) -> bool:
        # Inside the main checkout, inside the directory its build/ resolves
        # to, or inside any build/.dart_tool directory.
        p = self.path.rstrip('/') + '/'
        roots = [main_checkout, os.path.realpath(os.path.join(main_checkout, 'build'))]
        return any(p.startswith(r.rstrip('/') + '/') for r in roots) or any(
            m in p for m in BUILD_MARKERS
        )


def parse_porcelain(text: str) -> list[dict]:
    entries, cur = [], {}
    for line in text.splitlines() + ['']:
        if not line:
            if cur:
                entries.append(cur)
            cur = {}
            continue
        key, _, value = line.partition(' ')
        cur[key] = value or True
    return entries


def process_cwds() -> set[str]:
    cwds = set()
    for pid in os.listdir('/proc') if os.path.isdir('/proc') else []:
        if pid.isdigit():
            try:
                cwds.add(os.readlink(f'/proc/{pid}/cwd'))
            except OSError:
                pass
    return cwds


def is_busy(path: str, cwds: set[str]) -> bool:
    return any(c == path or c.startswith(path + '/') for c in cwds)


def inventory(repo: str, main_ref: str = 'main') -> tuple[str, list[Worktree]]:
    entries = parse_porcelain(git('worktree', 'list', '--porcelain', cwd=repo))
    main_checkout = entries[0]['worktree']
    cwds = process_cwds()
    result = []
    for e in entries[1:]:
        path = e['worktree']
        branch = e.get('branch')
        wt = Worktree(
            path=path,
            head=e.get('HEAD', ''),
            branch=branch if isinstance(branch, str) else None,
            locked='locked' in e,
            exists=os.path.isdir(path),
        )
        if wt.exists:
            wt.commits_not_on_main = int(
                git('rev-list', '--count', wt.head, f'^{main_ref}', cwd=repo).strip() or 0
            )
            if wt.commits_not_on_main:
                cherry = git('cherry', main_ref, wt.head, cwd=repo)
                wt.unmerged_patches = sum(1 for l in cherry.splitlines() if l.startswith('+'))
            status = git('status', '--porcelain=v1', '--untracked-files=all', cwd=path)
            for line in status.splitlines():
                if line.startswith('??'):
                    wt.untracked += 1
                else:
                    wt.changed.append(line[3:].split(' -> ')[-1])
            wt.busy = is_busy(path, cwds)
        result.append(wt)
    return main_checkout, result


def archive_name(path: str) -> str:
    return path.strip('/').replace('/', '_')


def cmd_report(args) -> int:
    main_checkout, wts = inventory(args.repo, args.main)
    counts: dict[str, int] = {}
    rows = []
    for wt in wts:
        c = wt.classify(main_checkout)
        counts[c] = counts.get(c, 0) + 1
        rows.append({
            'path': wt.path, 'class': c, 'head': wt.head[:12],
            'commits_not_on_main': wt.commits_not_on_main,
            'unmerged_patches': wt.unmerged_patches,
            'task_changes': len(wt.task_changes), 'untracked': wt.untracked,
            'misplaced': wt.misplaced(main_checkout),
        })
    stashes = len(git('stash', 'list', cwd=args.repo).splitlines())
    if args.json:
        print(json.dumps({'worktrees': rows, 'counts': counts, 'stashes': stashes}, indent=2))
    else:
        for r in rows:
            if args.all or r['class'] != 'safe' or r['misplaced']:
                flag = ' MISPLACED' if r['misplaced'] else ''
                print(f"{r['class']:<18} c={r['commits_not_on_main']:<3} "
                      f"chg={r['task_changes']:<4} unt={r['untracked']:<4} {r['path']}{flag}")
        print(f'linked worktrees: {len(wts)}  ' +
              '  '.join(f'{k}={v}' for k, v in sorted(counts.items())) +
              f'  stashes: {stashes}')
    warn = len(wts) > args.warn_over or any(r['misplaced'] for r in rows)
    if warn:
        print(f'WARNING: {len(wts)} linked worktrees (limit {args.warn_over}) '
              'or misplaced worktrees; see docs/maintainers/worktree-hygiene.md',
              file=sys.stderr)
    return 1 if (warn and args.strict) else 0


def cmd_archive(args) -> int:
    repo, out = args.repo, Path(args.archive_dir)
    (out / 'worktrees').mkdir(parents=True, exist_ok=True)
    (out / 'stashes').mkdir(exist_ok=True)
    main_checkout, wts = inventory(repo, args.main)
    manifest = []
    for wt in wts:
        if not wt.exists:
            continue
        name = archive_name(wt.path)
        d = out / 'worktrees' / name
        d.mkdir(exist_ok=True)
        entry = dataclasses.asdict(wt) | {'name': name, 'class': wt.classify(main_checkout)}
        if wt.changed:
            (d / 'worktree-vs-head.patch').write_text(git('diff', '--binary', 'HEAD', cwd=wt.path))
            (d / 'staged.patch').write_text(git('diff', '--binary', '--cached', cwd=wt.path))
            state = git('stash', 'create', f'archive {name}', cwd=wt.path).strip()
            if state:
                git('update-ref', f'refs/archive/wtstate/{name}', state, cwd=repo)
                entry['state_commit'] = state
        if wt.untracked:
            files = git('ls-files', '--others', '--exclude-standard', '-z', cwd=wt.path)
            (d / 'untracked.lst0').write_text(files)
            subprocess.run(['tar', '--null', '-T', str(d / 'untracked.lst0'), '-czf',
                            str(d / 'untracked.tgz')], cwd=wt.path, check=True)
        if wt.commits_not_on_main:
            git('update-ref', f'refs/archive/wt/{name}', wt.head, cwd=repo)
        (d / 'meta.json').write_text(json.dumps(entry, indent=2))
        manifest.append(entry)
    stash_lines = git('stash', 'list', '--format=%H%x09%gd%x09%gs', cwd=repo).splitlines()
    for i, line in enumerate(stash_lines):
        sha, ref, subject = line.split('\t', 2)
        git('update-ref', f'refs/archive/stash/{i:02d}', sha, cwd=repo)
        (out / 'stashes' / f'{i:02d}.patch').write_text(
            git('stash', 'show', '-p', '--binary', '--include-untracked', sha, cwd=repo, check=False))
        with open(out / 'stashes' / 'index.tsv', 'a') as f:
            f.write(f'{i:02d}\t{sha}\t{ref}\t{subject}\n')
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    if git('for-each-ref', 'refs/archive', cwd=repo).strip():
        bundle = out / 'archive-refs.bundle'
        git('bundle', 'create', str(bundle), '--glob=refs/archive', cwd=repo)
        git('bundle', 'verify', str(bundle), cwd=repo)
    print(f'archived {len(manifest)} worktrees and {len(stash_lines)} stashes to {out}')
    return 0


def cmd_remove(args) -> int:
    out = Path(args.archive_dir)
    if not (out / 'manifest.json').is_file():
        print('No archive manifest; run "archive" first.', file=sys.stderr)
        return 2
    main_checkout, wts = inventory(args.repo, args.main)
    all_paths = [w.path for w in wts]
    removed = skipped = 0
    for wt in wts:
        name = archive_name(wt.path)
        nested = any(p.startswith(wt.path + '/') for p in all_paths)
        if wt.classify(main_checkout) != 'safe' or nested or not (out / 'worktrees' / name).is_dir():
            skipped += 1
            continue
        cmd = ['worktree', 'remove'] + (['--force'] if wt.changed else []) + [wt.path]
        if args.apply:
            git(*cmd, cwd=args.repo)
        else:
            print('would run: git ' + ' '.join(cmd))
        removed += 1
    verb = 'removed' if args.apply else 'would remove'
    print(f'{verb} {removed}; kept {skipped} for review')
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo', default=os.getcwd())
    ap.add_argument('--main', default='main')
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('report')
    r.add_argument('--warn-over', type=int, default=50)
    r.add_argument('--strict', action='store_true', help='exit 1 on warnings')
    r.add_argument('--json', action='store_true')
    r.add_argument('--all', action='store_true', help='also list safe worktrees')
    a = sub.add_parser('archive')
    a.add_argument('--archive-dir', required=True)
    m = sub.add_parser('remove')
    m.add_argument('--archive-dir', required=True)
    m.add_argument('--apply', action='store_true')
    args = ap.parse_args(argv)
    return {'report': cmd_report, 'archive': cmd_archive, 'remove': cmd_remove}[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main())

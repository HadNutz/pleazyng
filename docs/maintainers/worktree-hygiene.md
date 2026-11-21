# Worktree and stash hygiene

This runbook covers how linked worktrees and stashes of the canonical checkout
are created, inventoried, archived and removed without losing work. The policy
summary is in `AGENTS.md` ("Worktree and stash hygiene").

## Rules

- Create task worktrees with `git worktree add --detach` under
  `/home/keith/Documents/code/task-worktrees/<task>` or a task-scoped scratch
  root. Never put them inside the canonical checkout (including `.dart_tool/`),
  inside the directory the checkout's `build/` symlink points to, or inside any
  other build output directory. Tools scan those trees as part of the repo, and
  cleaning a build folder would delete the worktree with it.
- Detached worktrees only. `main` stays the only local branch (see the branch
  consolidation directive in `AGENTS.md`).
- Save work in progress as a commit on the detached worktree rather than as a
  `git stash`. Stashes are shared by every worktree, their indices shift, and
  they get lost.
- At task end: push or hand off the commits, remove the worktree with
  `git worktree remove <path>`, and run the task's cleanup helper. Plain
  `git worktree remove` refuses if anything is modified or untracked; treat a
  refusal as a signal to look, not something to `--force` past.

## Inventory (read-only)

```sh
python3 scripts/maintainers/worktree_hygiene.py --repo /home/keith/Documents/code/pleazyng report
```

It classifies each linked worktree:

| Class | Meaning |
| --- | --- |
| `safe` | No commits missing from main (or all patch-equivalent), no task changes, no untracked files. A difference in `AGENTS.md` alone counts as safe, because policy sync rewrites it in every worktree. |
| `review-commits` | Has commits whose patches aren't on main. |
| `review-changes` | Has uncommitted tracked changes. |
| `review-untracked` | Has untracked, non-ignored files (often evidence or logs). |
| `busy` | A running process has its working directory inside it. |
| `locked`, `branch-checked-out`, `missing` | Handle these by hand. |

`MISPLACED` marks worktrees inside the checkout or a build directory. The report
prints a warning to stderr when there are more than 50 linked worktrees
(`--warn-over`) or any misplaced ones. `--strict` turns the warning into exit
code 1, and `--json` gives machine-readable output.

Run it weekly and before each release. The workstation runs it as a weekly
systemd user timer, `pleazyng-worktree-report.timer`, which logs to
`~/.local/state/pleazyng/worktree-report.log`.

## Cleanup procedure

1. **Freeze.** Make sure no agent, build or test is using the worktrees. The
   tool skips `busy` worktrees, but a build can be running from the canonical
   checkout while writing into a worktree's directory. Check `ps` for
   `flutter`, `dart`, `gradle`, `cmake` and `xcodebuild` first.
2. **Archive everything** to a durable folder, not the scratch disk:
   ```sh
   python3 scripts/maintainers/worktree_hygiene.py archive \
     --archive-dir /home/keith/Documents/code/.archive/pleazyng-worktree-cleanup-<date>
   ```
   This writes, for each worktree, `worktree-vs-head.patch`, `staged.patch`,
   `untracked.tgz` and `meta.json`. It also creates these refs, puts them all
   in a verified `archive-refs.bundle`, and records the stashes in
   `stashes/NN.patch` plus `index.tsv`:
   - `refs/archive/wt/<name>` for each HEAD that isn't on main;
   - `refs/archive/wtstate/<name>` for each uncommitted state (a
     `git stash create` commit);
   - `refs/archive/stash/NN` for each stash.

   Ignored files are not archived automatically. Before removal, list
   non-cache ignored files with
   `git status --porcelain --ignored=matching | grep '^!!'` and tar any logs
   or evidence (`evidence/`, `*.log`, `artifact*`) into the worktree's archive
   folder.
3. **Dry run, then remove the safe ones:**
   ```sh
   python3 scripts/maintainers/worktree_hygiene.py remove --archive-dir <dir>
   python3 scripts/maintainers/worktree_hygiene.py remove --archive-dir <dir> --apply
   ```
   Only `safe` worktrees that have an archive folder and contain no nested
   worktree are removed. `--force` is used only when the sole change is a
   policy-synced file.
4. **Review the rest by hand.** For each `review-*` worktree, check whether
   main already has the change:
   - Commits: `git cherry main <head>`. Patch-equivalence misses squash
     merges, so also match commit subjects against `git log main --format=%s`.
   - Uncommitted changes: load main into a temporary index
     (`GIT_INDEX_FILE=<tmp> git read-tree main`), then
     `git apply --cached --check -R <patch>`. If it succeeds, the change is
     already on main. If the forward apply succeeds instead, the work is
     pending. If neither applies, main has moved on; check file by file.
   - Untracked files: compare them to main with `git hash-object` against
     `git rev-parse main:<file>`.

   Remove what is already on main. Put everything else on a list for the owner,
   with its archive path. Never apply leftover work to main without review.
5. **Stashes.** Treat each one like an uncommitted diff:
   `git diff <stash>^1 <stash>` for tracked changes, and `<stash>^3` for its
   untracked files. Before dropping a stash, check that its hash matches its
   `refs/archive/stash/NN` ref.
6. **Leave unreachable objects alone.** Don't run `git gc --prune=now`; the
   bundle covers anything that matters, and normal reflog expiry handles the
   rest.
7. **Clean empty parent directories** with `rmdir` only. Never `rm -rf` a
   shared scratch root.

## Restore

```sh
git worktree add --detach <dir> refs/archive/wtstate/<name>   # or refs/archive/wt/<name>
tar -xzf <archive>/worktrees/<name>/untracked.tgz -C <dir>
git stash store -m restored refs/archive/stash/NN
# If the refs are gone:
git fetch <archive>/archive-refs.bundle 'refs/archive/*:refs/archive/*'
```

## 2026-11-21 cleanup record

- Starting point: 398 linked worktrees and 55 stashes, about 1,470 unreachable
  commits, and five worktrees inside `.dart_tool/`.
- Archive: `/home/keith/Documents/code/.archive/pleazyng-worktree-cleanup-20261121/`
  (1.1 GB, bundle verified). It is workstation-only.
- Removed 362 worktrees:
  - 347 that were on main or patch-equivalent, where `AGENTS.md` was the only
    difference;
  - 15 more whose commits matched main by subject, or whose diff
    reverse-applied on main.
- Dropped one stash, which was already on main.
- Freed space: /home went from 134 to 212 GB available, the scratch disk from
  210 to 275 GB, and gamespool1 from 97 to 121 GB.
- Kept for owner review: 36 worktrees and 54 stashes. The lists are
  `leftover.txt`, `wt_perfile.tsv` and `stash_review2.tsv` in the archive.
- The `AGENTS.md` difference in those worktrees was the CodeQL section emptied
  ahead of commit `7c4cf970a`. It was not a recurring sync tool.
- **Pending:** the canonical checkout's `build/` symlink still points to
  `/mnt/disks/scratch/plezyng-motion-main-build-20261030` (41 GB). That
  directory also holds the kept `native-groups-20261111/app-qualification`
  worktree (25 GB). Once nothing is building from the canonical checkout:
  1. Point `build/` at a fresh task-scoped directory.
  2. After the owner decides on that worktree, delete the old directory's
     cache subdirectories (`app/`, `test_cache/`, plugin build directories).
     Keep `reports/`, `maestro/` and `parity-*` as evidence.

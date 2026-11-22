# Worktree recovery and retention

The workstation cleanup record and the names of the three owner-review lists are in [worktree hygiene](worktree-hygiene.md#2026-11-21-cleanup-record). Use that inventory for the November 21 cleanup. The verifier below additionally preserves ignored evidence, file modes, symlinks and hardlinks, and tests restoration in an isolated repository.


The authoritative clone is `/home/keith/Documents/code/pleazyng`. Run the inventory there before freeing space. Linked checkout metadata, stash reflogs, staged data and ignored capture files belong to that clone. A GitHub clone cannot recover them.

Run `python3 scripts/checks/worktree_inventory.py` from the authoritative clone to list checkouts and stashes. A count above 50 is a warning. The four previously reported population counts sum to 416 for a reported 398 worktrees. Reconcile paths before using any of the proposed removal counts.

## Archive and verify

1. Choose a durable archive outside the repository, its worktrees and build directories. Freeze the checkout with its users. Inspect Git locks, active build jobs, and open files or working directories below **each** candidate immediately before archiving and again before removal. A silent worktree can still belong to a running agent. Skip a live checkout.
2. Record the path, branch, HEAD, upstream/main comparison, index status, submodules, untracked files and ignored files. For each worktree save separate binary/full-index staged and unstaged patches, then archive the actual untracked files, ignored evidence, logs and local assets with relative paths and symlinks preserved. Review ignored build output before excluding anything. Preserve any changes in nested repos separately.
3. Pin each unique worktree HEAD and each stash commit by object ID under local `refs/archive/wt/` and `refs/archive/stash/`, including detached clean tips. Save stash patches including untracked files and record the original stash reflog ordering. Create a bundle containing the archive refs, their parents and the baseline. Hash and verify the bundle and archived files on durable storage.
4. Restore into a fresh offline clone. Check out the exact base, apply the staged patch to the index and worktree, then the unstaged patch to the worktree. Extract the saved untracked and ignored bytes. Compare index tree, tracked contents, file modes, symlink targets, evidence hashes and untracked payloads with the original. Restore representative stashes with their index and untracked content and verify every referenced stash object is in the bundle.
5. Re-inventory before removal. Require exact status and tip agreement with the verified archive. A normal `git worktree remove` refuses a dirty worktree. An AGENTS.md-only difference still needs verification and archival before restoring its base version in that candidate. Do not use mass force removal.
6. Use ancestry and stable patch comparison for unique commits, including an explicit comparison for merges. `git cherry` alone cannot establish that merge resolutions or dirty state are redundant. Compare stashes by object ID, including their staged and untracked parents. Propose any unique recovered work to the owner with its archive path. Resolve the current stash slot by its object ID immediately before an approved drop.
7. Handle registered worktrees below `.dart_tool/` and the former build scratch directory before considering their parent for cleanup. Check build ownership, active users and archives again, and use a fresh task-scoped build location. Keep the active main checkout, release-bump changes, TV patches, reflogs and unreachable objects intact. Avoid explicit pruning or aggressive GC.

Create new detached task checkouts under a sibling `task-worktrees/` directory. Keep task checkpoints as commits and preserve their tip until integrated or archived. At task completion run the inventory and retire only the verified task-owned checkout. Configure any instruction-sync tool on its owning host to exclude registered linked checkouts, after identifying the actual writer from its configuration or logs.

Once checkout owners have frozen the source host, run the archive verifier from that clone:

```sh
python3 scripts/checks/archive_worktrees.py --repo "$PWD" --destination /durable/pleazyng/worktrees-2026-11-21
```

The destination must be new. The final `sha256.json` is written after offline restoration. The helper checks the index, separate patches, file bytes and modes, link targets, and stashes with their staged and untracked parents. Linked checkouts nested within a parent have separate inventory rows. A dirty submodule, unresolved index or unregistered embedded repository needs its own recovery before removal. An incomplete archive is retained for diagnosis. Inventory and hash checks complement the host process and ownership checks above.

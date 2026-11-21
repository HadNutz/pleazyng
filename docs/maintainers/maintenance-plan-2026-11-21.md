# Repository maintenance plan — 2026-11-21

This plan covers four pieces of work: worktree cleanup, upstream drift,
oversized files and swallowed errors, and native code coverage. They run in
order 4, then 5, then 6 and 7 side by side. Finishing the upstream ports
before restructuring code avoids turning every later upstream port into a
merge conflict.

Every step must keep these true:

- `flutter analyze` stays clean.
- The full test suite stays green (11,556 passing, 27 skipped, 0 failing at
  the start).
- Native changes are built on their GitHub-hosted runner.
- Refactors only move code: no behaviour or public API changes.
- Nothing is deleted before it has been archived and checked.

## 4. Worktree, stash and disk cleanup — done, with leftovers

The procedure and the record are in [worktree-hygiene.md](worktree-hygiene.md).
Still open:

- The owner needs to decide on 36 kept worktrees and 54 stashes. The lists
  are in the workstation archive.
- Repointing the canonical checkout's `build/` symlink is waiting until no
  build is running from that checkout.

## 5. Upstream drift

At the start, 29 upstream commits weren't on main. Nine were already credited
in `UPSTREAM_ATTRIBUTION.md` or the changelog; 20 had no recorded decision.

1. Record every commit in a ledger,
   `docs/maintainers/upstream-sync-2026-11-21.json` plus a matching `.md`. Use
   the 2026-11-09 ledger's format: sha, source URL, author, disposition,
   evidence and files.
2. Port in this order:
   1. Data safety and correctness: downloads after a storage stop, iOS/macOS
      purgeable space, PIN-protected profiles on the TV shelf, asking for a
      profile on resume, Live TV access after a profile switch, retrying a
      server that was unreachable at launch, keeping a reconnecting server's
      client, paging past the end of a library, remote focus after a reload.
   2. UX.
   3. Performance.
   4. pt-PT, through `scripts/codegen.sh`.
3. Fork-specific changes are recorded with an explicit disposition rather than
   ported blindly. These include the Homebrew cask and the Xcode 27.1 IPA
   change.
4. The 25/30 fps → 50/60 Hz change interacts with frame-rate matching and
   motion smoothing. Port it only behind the existing settings, with tests for
   both modes, and only after the owner approves.
5. Port one commit per change, with its upstream test where there is one, an
   attribution entry and a changelog line, as `AGENTS.md` requires.
6. Add a report-only drift check that compares `HEAD..upstream/main` against
   the ledgers and lists commits with no decision. Run it weekly and before
   each release.

## 6. Oversized files and swallowed errors

- **Files shared with upstream** (`plex_client`, `media_detail_screen`,
  `download_manager_service`, the video player, `main.dart`, settings): don't
  split them. Move the fork's own additions into fork-owned part files or
  extensions, so the upstream portion stays easy to compare. Each step should
  make the diff against upstream for those files smaller.
- **Fork-only files**: split freely, moving code only and one file per commit.
  These are `find_next_screen`, `source_playback`, `content_access`,
  `subtitle_ai_sheet`, `music_car_host`, `source_controller`,
  `iptv_source_repository` and `music_playback_service_impl`. Before each
  split, add tests that pin current behaviour. `media_detail_screen`,
  `content_access` and `music_playback_service_impl` have the weakest
  coverage.
- **Swallowed errors**: there are 726 `catch (_)` sites and 47 empty catch
  blocks.
  - Pass 1 adds `appLogger.d` context to the empty blocks without changing
    control flow.
  - Pass 2 sorts the rest into three groups: best-effort (add a
    `// best-effort: <reason>` comment), should be logged, and should pass the
    error on. Any change in behaviour gets its own commit and test.
- **CI ratchets**:
  - no file may grow past its current size;
  - new files are capped at about 1,500 lines;
  - no new uncommented `catch (_)`.

## 7. Native code coverage

- **Static analysis**: add Android Lint, detekt, SwiftLint and clang-tidy (for
  `native/` and `scripts/tv_mpv`). Each starts from a baseline that accepts
  today's findings, so only new findings fail.
- **CodeQL** is allowed again (owner directive, 2026-11-21) and may be added
  as an additional analyzer on hosted runners.
- **Apple compile checks**: when a push touches Apple sources, run a hosted
  macOS build-only job for iOS, tvOS and macOS. Unsigned builds are enough to
  catch SDK renames on the change that causes them.
- **Patch stacks**: check that every patch in `scripts/tv_mpv/` and
  `native/visualizer/patches/` applies cleanly to the source pinned in its
  lock file.
- **Native tests**: Kotlin JVM tests for decoder ordering, DV/FEL routing and
  fallback, HDR10+ SEI stripping, and SAF downloads; XCTest for the MpvPlayer
  bridge and the AVFoundation DV paths; tests for the C++ visualizer helper.
  Device qualification stays separate evidence.
- **Ratchet**: native test file counts can only go up, and lint baselines can
  only shrink.

## Owner decisions needed

- What to do with each leftover worktree and stash from item 4.
- The 50/60 Hz port in item 5.

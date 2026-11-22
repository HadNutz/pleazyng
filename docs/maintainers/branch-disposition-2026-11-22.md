# Branch disposition — 2026-11-22

The reviewed integration was merged as PR #306 at `75ab54244c31585774a65e42b13a2d3b178fa55a`. PR #305 was already merged into `main`. No other pull request was open after #306 merged.

The remaining remote task branches were compared against the integration and their workflow runs were checked before retirement:

| Branch tip | Unique change beyond the integrated candidate | Disposition |
| --- | --- | --- |
| `ci/watch-together-relay-20261121` — `bddf16cc15f329ff347a1bc27c9a343480fb043b` | None; its relay-test change is patch-equivalent to code in PR #306. | Retire branch name; keep the integrated test. |
| `qualification/detail-appearance-20261121` — `5222c5aa1de3d7657d19713b66616bd776023a65` | One-off `compare-detail-evidence.yml` workflow only. The comparison run passed (#44950958908); a later unrelated playback-fixture check failed (#44952635164). | Do not retain a temporary diagnostic workflow as permanent CI. Preserve its tip under an archive tag. |
| `qualification/native-parity-20261121` — `cd76f29956d161a70610786d79435cedffd70bbf` | One-off `verify-native-parity.yml` workflow only; its run was cancelled (#44953797986). | Do not retain a temporary diagnostic workflow as permanent CI. Preserve its tip under an archive tag. |
| `qualification/profile-fixtures-20261121` — `bf33b1e2a774e9b2a95dd88588c76dd35cf61c97` | One-off `verify-profile-fixtures.yml` workflow only. Its profile-session test and Drift cleanup fix are in the integrated candidate; all three integrated Flutter test shards passed in #44984187257. | Keep the maintained tests and cleanup fix; preserve the diagnostic-workflow tip under an archive tag. |
| `qualification/upstream-2026-11-21-checkpoints` — `be701cef3b08b72f42783eca82302816433b27c3` | No patch-unique code beyond the integrated candidate; its checkpoint run was cancelled (#44942586765). | Retire the superseded branch name. |

The temporary workflow-only tips are retained as `archive/qualification-*` tags before their remote branch names are removed. Their Actions run records remain available on GitHub. The upstream `main` stayed at `8310991fa14f0cbac9c71cfb494d028d4314c7ff` during this integration; no additional upstream synchronization was needed.

CodeQL remains enabled. The Mac App Store keychain password derivation remediation is in the merged candidate; the main-branch scan is checked separately after merge.

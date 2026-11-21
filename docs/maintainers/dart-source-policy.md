# Dart source maintenance

The first revision containing this file establishes the line-count and error-handler baseline after the November 21 upstream ports, concurrent changes from main, and code moves. Subsequent changes compare against their merge base. Git retains the original source for every baseline entry.

For each maintained Dart file under `lib/`, keep the line count at or below its previous value. New files have a 1,500-line limit. Generated model and localization files and the three generated data tables are outside this measurement. Move fork-owned declarations into same-library parts when that preserves the upstream comparison. The check matches existing wildcard handlers across moved files and also counts repeated copies.

A new `catch (_)` needs a comment inside the handler explaining what happens to the failed operation. Optional artwork, search enrichment, diagnostics and capability probes can return an unavailable result. An unavailable identity or unverified permission must fail closed. For a durable write, propagate the failure to the owner that can retry or report it. Keep payloads and credentials out of logs.

The rollout reviewed 733 wildcard handlers in the integrated source. It added context-only debug logs to previously empty handlers and documented 231 fallbacks across 155 files. The Dart parser confirmed that the annotations preserved the syntax tree of every affected file. Existing handlers that translate exceptions, report typed failure, close a failed transport or leave a durable journal entry pending keep those outcomes. The separate show-track-preference fix preserves an unreadable table before the player reports the failed save.

Run the check from the repository root with a fetched comparison commit.

```sh
dart run scripts/checks/dart_source_ratchet.dart origin/main
```

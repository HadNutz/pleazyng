# Apple static MPVKit framework packaging

## Purpose

Xcode may copy a static MPVKit XCFramework slice into an app's
`Frameworks/<name>.framework` directory as a codeless stub. The app already
contains the linked static code, but the generated stub's `Info.plist` is not a
valid runtime framework plist and can make simulator installation fail with
`PackageInspectionFailed`.

The last app-target build phase on iOS, tvOS, and macOS runs
`scripts/apple/prune_static_mpv_frameworks.py` before Xcode signs the app. It
checks the exact `mpv-build` revision recorded by `Package.resolved`, the
selected platform and architecture slices, framework identity and static
archive headers, the app's dynamic load commands, and all copied notice files.
It fails before mutation when any check is ambiguous. It copies only
allow-listed notice resources byte-for-byte, then removes only wrappers whose
matching pinned source slices are verified as static archives. Dynamic
frameworks are left in place.

At the current package pin, `Libmpv.framework` also contains
`LICENSE.SpatialAudioBridge`. The helper copies that exact, size-bounded notice
before removing the wrapper. It uses the platform's bundle resource layout:
`PleazyngStaticFrameworkResources/<framework>/` at the app root on iOS and
tvOS, and `Contents/Resources/PleazyngStaticFrameworkResources/<framework>/`
on macOS. This file matches the Flutter asset
`assets/licenses/SpatialAudioBridge.txt`; unknown top-level framework files
remain errors.

Do not create a top-level `Resources/` directory in a flat iOS or tvOS app
bundle. CFBundle classifies that layout as an old-style bundle and looks for
the app plist under `Resources/Info.plist`, which can make both
`Bundle(url:)` and the simulator installer report a missing bundle id while
the root `Info.plist` is still valid. The layout classification is described
in Apple's [CFBundle resource lookup source](https://raw.githubusercontent.com/apple-oss-distributions/CF/main/CFBundle_Resources.c).
The simulator probe records the complete plist, Foundation's direct plist and
bundle identities, and checks that the bundle id and executable stay stable
before and after notice preservation.

On a reused DerivedData product, the helper refuses any pre-existing
top-level `Resources` name, case-insensitively, and leaves its contents
untouched. Clean and rebuild that specific app product before retrying; do not
delete or migrate unknown bundle resources.

Each build writes a JSON receipt under `DERIVED_FILE_DIR`. The receipt records
the package revision, selected source slices, complete embedded plist content,
Mach-O headers/build commands and load dependencies, and hashes/sizes for
preserved notice files. On an incremental build where Xcode has already
removed the wrappers, the phase checks that prior receipt against the current
pin, app path, load commands and copied notice bytes before accepting the
already-pruned bundle.

## Focused simulator probe

Use the **Static MPVKit simulator packaging probe** manual workflow from
`main`. Supply the full immutable product-source commit whose tvOS
`Package.resolved` pin matches the probe project. The job checks that the
source commit is in the selected trusted `main` history before resolving the
package. It builds a small SwiftUI tvOS app against that exact MPVKit package,
records an inspect-only receipt, and first verifies that unnormalized install
reproduces the known codeless-framework plist failure. It then applies the
same verifier/pruner, installs and launches the app in a tvOS simulator, and
checks that the app called `avcodec_version()` successfully.

The workflow retains inspect/apply receipts and command logs as an artifact.
It also retains the probe app's complete generated `Info.plist` and validates
its bundle id, executable, package type, name, versions, supported simulator
platform, tvOS device family and minimum OS before attempting installation.
The Foundation probe snapshots its bundle identity before pruning, after
pruning, and after signing.
The launched fixture writes its `avcodec_version()` marker to the app's
`Library/Caches` directory, matching tvOS's writable app-storage location.
This focused result qualifies the tvOS simulator packaging path only. Normal
iOS and macOS build/installation checks must pass before claiming those
platforms are qualified.

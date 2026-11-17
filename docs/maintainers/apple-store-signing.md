# Apple Store signing

The existing Apple Distribution identity passed native macOS qualification: the configured PKCS12 was imported, its private key verified against the certificate, and a small executable signed and verified strictly. No certificate was issued or revoked. The [2026-11-05 native preflight](https://github.com/snapetech-org/pleazyng/actions/runs/42169674435) passed the three host/Top Shelf profiles and both projects' signing bindings; its [bounded report](qualification/apple-signing-20261105.json) is historical evidence. It does not qualify the subsequently added iOS RommWorker profile, a complete app archive, App Store processing or purchase behavior.

The original PKCS12 required a compatible SHA1/3DES re-encoding for Security.framework. The isolated keychain also needs the checksum-pinned official Apple WWDR G3 intermediate and membership in the user keychain search list. `scripts/apple_signing_material.py` provides the same verified context for the preflight and release jobs, restores the original search list, deletes its keychain and removes task-owned temporary material. It never changes the default keychain or system trust.

## Required secrets

- `APPLE_DISTRIBUTION_CERTIFICATE_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_TEAM_ID`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `TVOS_PROVISIONING_PROFILE_BASE64`
- `TVOS_TOPSHELF_PROVISIONING_PROFILE_BASE64`
- `APPLE_API_ISSUER_ID` (iOS worker profile preflight)
- `APPLE_API_KEY_ID` (iOS worker profile preflight)
- `APPLE_API_PRIVATE_KEY` (iOS worker profile preflight)

Profiles must name `org.snapetech.pleazyng` for iOS/tvOS and `org.snapetech.pleazyng.TopShelfExtension` for Top Shelf, the correct platform, the imported certificate, and `group.org.snapetech.pleazyng`. Expired, development, ad-hoc, enterprise, other-team and old-bundle profiles fail validation. The old PlezyNG profiles are preserved for dependency review.

`apple-signing-preflight.yml` is manual, restricted to main and runs on hosted native macOS. Its artifact contains only bounded public certificate/profile fields. It checks the actual three profile bindings and the selected Release target settings. Do not upload keys, PKCS12 files, profile payloads or private working directories as artifacts.

## iOS worker profile preflight

The iOS extension also needs a distinct App Store profile for
`org.snapetech.pleazyng.RommWorker`. Enable its required Enhanced Security
capability through Apple's supported Developer portal before regenerating that
profile with the existing distribution certificate. Preserve the host and tvOS
identities, the certificate and the checked-in worker entitlements.

Use the current `build.yml` signing-only action to check this profile before
retrying a failed archive:

```sh
gh workflow run build.yml --repo snapetech-org/pleazyng --ref main \
  -f action=apple-signing-preflight -f runner_pool=public \
  -f execution_profile=hybrid -f mode=release
```

This action selects hosted `macos-26-intel` and separate concurrency; it does
not build an app or launch the release matrix. It validates the host profile
and creates or reuses a worker profile bound to the same team and existing
certificate. The worker must authorize all seven requirements from
`native/games/romm/apple/extension/RommWorker.entitlements`; an active profile
missing those grants is insufficient. The legacy three-profile check above
does not establish this requirement.

Require a successful run and its bounded `ios-profile-public-report` artifact
with both `profile_bootstrap_qualified` and `worker_security_qualified` true,
the expected entitlement names/source hash, and the expected certificate/team.
`app_build_qualified` remains false. An invalid fresh profile fails the check;
repair the capability before trying again. Keep profile payloads and signing
secrets out of artifacts. After qualification, retry only the failed original
archive and dependent release assembly, preserving successful platform outputs
and their original provenance.

## Store archive path

Keep `include_apple_store_build=true` for the first coordinated signed qualification run. The unsigned developer IPA remains separate. `build_apple_store_archive.py` imports the signing identity in a scoped context, validates and temporarily installs profiles, applies distinct manual Release signing settings to Runner and TopShelfExtension, archives and exports with an explicit profile map. It restores the original project bytes and removes only profiles it created. Existing installed profiles are preserved. iOS Store compilation explicitly selects trial/IAP mode and disables the direct-download update check; tvOS's native AOT build already selects IAP mode.

The helper's public receipt records archive/export completion separately from purchase and application qualification. Run the exact intended release revision through the existing coordinated full build; do not dispatch a duplicate matrix just for these secrets. A signed IPA must still process in App Store Connect and pass actual device, StoreKit purchase/restore, reviewer-access and screenshot checks. `APPLE_STORE_UPLOAD_READY` stays false until that signed-build/upload path is verified. Upload automation is separate from TestFlight tester invitations and App Review submission.

## macOS App Store package

`macos-app-store-signed.yml` is the manual, reusable signed Mac App Store lane.
It accepts an exact annotated stable version tag, checks that the tag and
`pubspec.yaml` version match, builds that immutable source with the existing
IAP build mode, and signs the universal app and installer for the exact bundle
`org.snapetech.pleazyng`. It uses the configured App Store Connect API key,
team ID and certificate-password secret; it does not need a new signing secret.

The lane inventories Apple certificates and reuses an exact local identity when
available. If an active Mac App Distribution or Mac Installer Distribution
certificate has no local private key, the workflow requests a separate
certificate through the Apple API. It never revokes or replaces an existing
certificate. Apple's account certificate limit is an external gate. The CSR
private key and CSR stay mode `0600` in the service user's recovery directory
and are imported into `~/Library/Keychains/Pleazyng-Mac-App-Store.keychain-db`.
This dedicated service keychain persists between signed releases and is locked
when each job ends. The workflow preserves the user's original keychain search
list and existing provisioning profiles.

Set the manual workflow's `preflight_only` input to verify the existing App and
Installer identities before an archive. It signs a temporary app bundle and
installer package locally, verifies both, and uploads only a public preflight
receipt. It does not create certificates or profiles, build Pleazyng, or call
App Store Connect. The normal workflow mode performs the signed app build and
upload after preflight succeeds. Before export, it also checks that the
embedded `PlezyTorrent.framework` has its expected bundle identity and valid
`CFBundleShortVersionString` and `CFBundleVersion` metadata.

The workflow creates or reuses a `MAC_APP_STORE` profile only after checking the
exact team, bundle ID, macOS platform, selected certificate and expiration. It
temporarily changes only the macOS Runner Release signing settings, restores the
project file afterward, verifies the app and installer signatures, uploads the
package to App Store Connect app `6826955231`, and waits for the exact version
and build to reach `VALID`. It does not update listing metadata, create or edit
in-app purchase products, change `pleazyng_lifetime_unlock`, set prices, or
submit App Review. A processed upload does not qualify sandbox/JIT runtime,
StoreKit purchase and restore, screenshots, or Apple review. The first signed
run remains an external signing and account qualification gate.

Xcode's `-resolvePackageDependencies` rewrites these tracked files while
refreshing the tagged Swift packages:

- `macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved`

The project resolver removes pins outside its package graph. The MAS lane
snapshots only these two known lockfiles, restores their exact release-tag bytes
after resolution and archive, and records each original SHA-256 in the signed
build receipt. Whole-checkout source validation remains strict before and after
those steps; any other tracked change fails the build.

The explicit `publish-app-stores.yml` Apple lanes inspect the checksum-verified,
attested IPA's bundle, platform, marketing version, and build number before
upload. They target the existing App Store Connect app ID `6826955231`, reuse
an already valid exact version/build without a duplicate upload, and wait up to
15 minutes for a new upload to reach `VALID`. `FAILED`, `INVALID`, duplicate,
or mismatched records fail closed. The workflow retains a public processing
receipt with the release IPA hash and GitHub run identity. App Store Connect
does not expose an IPA hash for an already existing build, so that receipt
marks reused builds as a version/build identity match. Upload success and
processing do not create a matching draft version, invite TestFlight users,
or submit App Review.

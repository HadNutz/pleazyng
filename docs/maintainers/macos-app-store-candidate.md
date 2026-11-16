# macOS App Store candidate

The manual `macOS App Store Candidate` workflow configures a separate macOS
`SUPPORTER_MODE=iap` build with update checks disabled, selects the sandboxed
`macos/Runner/AppStore.entitlements` in the Xcode build settings, creates an
unsigned `.xcarchive`, and packages the universal app with `productbuild` as an
unsigned installer. Code signing is disabled, so the archive does not enforce
or qualify the sandbox at runtime. Its artifact includes the archive, package,
and a JSON receipt with the source commit, bundle identity, version,
architectures, package digest, and explicit qualification fields.

The candidate is retained as a workflow artifact and is not added to the
versioned GitHub release. It does not change or replace the direct distribution
DMG. The receipt deliberately reports the app, installer, StoreKit purchase and
restore flow, sandbox runtime, JIT runtime, App Store Connect processing, and
Apple review as unqualified. The unsigned package cannot be uploaded to App
Store Connect.

The separate `Signed macOS App Store release` workflow builds from an exact
annotated stable release tag, signs the app with a `MAC_APP_DISTRIBUTION`
identity, exports a `MAC_INSTALLER_DISTRIBUTION` package and uploads it to the
existing App Store Connect app `6826955231`. It creates a matching `MAC_APP_STORE`
profile when needed. It first reuses an exact local private-key identity; if an
account certificate lacks its private key locally, it requests an additional
certificate and never revokes or replaces existing certificates. Apple account
certificate limits remain an external gate. Newly created signing keys are
retained in the dedicated, locked-at-rest service keychain on the signing Mac
for later release tags. The workflow restores the Xcode project and keychain
search list after the run and does not change Store listing, IAP products, SKU,
or pricing.

The signed workflow is implemented but has not yet run. Its receipt reports
App Store Connect processing separately from sandboxed runtime qualification
(including JIT-dependent playback), StoreKit purchase and restore, authentic
captures, and Apple review. A successful upload and `VALID` processing state do
not establish those runtime or review gates. The v3.0.36 product source stays at
its published tag; the same workflow accepts later annotated stable release
tags without changing product source.

To retain an unsigned packaging candidate, dispatch `macOS App Store Candidate`
from `main` and keep its archive, package and JSON receipt together. For the
signed App Store lane, dispatch `macos-app-store-signed.yml` from `main` with an
exact annotated version tag, then retain its signed package and processing
receipt together. Keep the selected tag's source commit and artifact digest
paired when presenting the build for account-backed qualification.

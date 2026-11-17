# Paid LG webOS build profile

`tools/webos/build_release_candidate.sh` intentionally builds the normal core
release as a tester/off package. The separate `tools/webos/build_paid_ipk.sh`
route requires the configured Flutter-webOS SDK, NDK, engine and visualizer
inputs, plus `LG_PAYMENTWALL_API_ORIGIN=https://billing.pleazyng.app` and the
base64url Ed25519 grant public key. The paid build passes `SUPPORTER_MODE=iap`
and the payment configuration as Flutter compile-time defines.

The IPK contains `lg-paymentwall-build.json` with its billing mode, origin,
fixed product, price and public-key SHA-256 fingerprint. Its
`webos-app-provenance.json` records the same profile and binds it to the exact
package hash. The public verification key is the only payment key included in
the client; the merchant secret and grant-signing private key are not build
inputs.

`tools/webos/check_release_package.py` compares packaged billing metadata to
the provenance record. `scripts/tv_store_submission.py --store lg` verifies
the IPK and requires the exact matching paid provenance profile; it rejects
tester/off packages even when `--package-verified` is supplied. The standard
all-platform core release still publishes its webOS IPK and checksums; an LG
Seller Lounge handoff is optional and is prepared only for a paid IPK. Tizen
tester packaging and core release eligibility are separate.

This build path does not establish physical device qualification, merchant
approval or live billing configuration. The payment backend remains disabled
until its separately documented runtime gates are satisfied; see
[`lg-paymentwall.md`](lg-paymentwall.md).

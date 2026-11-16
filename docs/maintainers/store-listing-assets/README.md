# Screenshot review and release handoff

[View all twelve native captures](native-captures-contact-sheet.jpg).

| Layout | Committed screenshots | Provenance |
| --- | --- | --- |
| Amazon Fire TV | [Four 1920×1080 captures](amazon/) | [TV receipt](amazon/tv-capture-provenance.json) |
| Amazon tablet-form-factor candidate | [Three 2560×1600 captures](amazon/tablet/) | [Tablet receipt](amazon/tablet/capture-provenance.json) |
| Google Play phone | [Three 1080×1920 captures](google-play/) | [Phone receipt](google-play/capture-provenance.json) |
| Google Play tablet | [Two 2560×1600 captures](google-play/) | [Tablet receipt](google-play/tablet-capture-provenance.json) |

The Amazon TV and tablet images are genuine captures of the exact signed 3.0.36
Amazon APK running against the public Jellyfin demo. The TV surface is 1920×1080;
the tablet surface is 2560×1600. The tablet run used a generic Android tablet
emulator, not Fire OS. These captures do not qualify physical Fire TV or tablet
hardware, playback or Amazon purchase/restore behavior. The Google Play phone
and tablet images are historical 3.0.0 captures from an Amazon-flavor build;
they are review evidence only and must be replaced before public Play review.
The store PNGs preserve the capture pixels; only fully opaque alpha channels
were removed. The contact sheet contains review thumbnails, not upload assets.

## Capture build

The Amazon captures use version **3.0.36**, source
`2388a06cc74d03e69ac7178fcd927a54460a5e3a`, and the signed APK SHA256
`4d07d84d29994f338cea9bb5ba7f764d2b248b89409ab6a1f64f9fefbdc0a344`.
The [APK verification receipt](capture-build-evidence/pleazyng-amazon-firetv-3.0.36-provenance.json)
records package, version, signer, ABIs and static qualification. The APK remains
a release artifact rather than a Git source file. Per-image receipts bind each
capture to this APK and source commit. The older 3.0.0 Fire TV images have been
removed from the current Amazon asset set.

## Next release

Follow the [Fire TV runbook](../fire-tv.md). The full release workflow builds a
fresh signed `pleazyng-amazon-firetv.apk` and matching provenance receipt from the
release source, attests both, and includes both in release assets and checksums.
The coverage gate requires both files. Validate that release build before store
handoff; do not substitute the older capture APK.

Amazon's 3.0.33 submission was rejected for listing accuracy. The prepared
correction includes Fire TV-specific short/long copy plus four TV and three
tablet captures from the exact signed 3.0.36 Amazon APK. Review the app icon and
promotional artwork, inspect both Fire TV and tablet image slots in the console,
replace every stale image, and verify the saved text before resubmitting. The
repository does not establish which assets are currently attached in the console.
Leave
`AMAZON_APPSTORE_BOOTSTRAP_COMPLETE=false` until the initial submission is
completed. Subsequent binary uploads verify the release APK/receipt and do not
change listing metadata or screenshots. Keep the existing lifetime SKU and
seller price; never include IAP prices in Amazon listing metadata. Physical Fire
TV and tablet behavior and purchase/restore remain separate qualification steps.

## Interface concepts

[Sixteen labeled TV, phone, tablet and desktop previews](../interface-previews/)
are retained separately. They render production Flutter widgets with synthetic
fixtures and are **not store screenshots**. Their manifest records their own,
earlier source revision. Do not mix them into store upload slots.

The [subtitle and appearance pack](../playback-appearance-previews/) contains
light/dark/OLED widget renders. [Player mockups](../player-mockups/) are kept
separately and visibly label simulated controls over an attributed film still.
The old blank video fixtures were rejected. [New dark native captures and their
validation limits](../readme-captures/) are separate from these widget renders
and the original store-upload receipts above.

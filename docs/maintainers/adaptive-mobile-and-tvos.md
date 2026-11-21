# Adaptive mobile layout and tvOS actions

The mobile shell can place navigation inside a system vertical bar and report
fold bounds to Flutter. Hosted sheets choose one side of a fold, respect the
bar and keyboard insets, and retain the fork's back and focus handling. Video
routes claim bar ownership before opening playback, so replacement routes do
not flash it back on. Normal phone, desktop and TV shells retain their existing
selection rules. Navigation remains scrollable when its destinations cannot fit.

The native iOS bridge compiles its new system API only with a compatible SDK;
older SDKs report empty geometry and use the normal layout. Headless tests can
exercise geometry, RTL, inset and ownership behavior independently of that SDK.

On tvOS, library trailers play internally. External YouTube trailers are offered
only when the YouTube app is available. Browser-only provider links are hidden.
Failed handoffs display localized feedback; provider links cannot launch local
files, scripts or unrelated OS handlers. Existing Seerr actions and extras
previews remain available.

Validation: 130 focused Flutter tests passed across shell, sheets, catalog,
menus and trailer helpers. Both changed Swift sources passed parsing on Linux.
This is not an Apple SDK build or physical-device qualification; native Apple
validation remains a separate check. The Android playback adaptation is tested
separately against the fork's pinned engine.

## Upstream sources

These authors contributed the linked changes to upstream Plezy. Pleazyng
independently adapted and tested them, without implying direct contribution to
or endorsement of this fork.

- [Fold and vertical-bar layout](https://github.com/edde746/plezy/commit/b4192d6f355921aa9dbdd89b000012e7c4496fa7) by [@v-vincere](https://github.com/v-vincere).
- [Sheet safe areas](https://github.com/edde746/plezy/commit/04ec8506c78dc29b4dfc18f751943fb6ecb89eec) by [@edde746](https://github.com/edde746).
- [tvOS trailer and link actions](https://github.com/edde746/plezy/commit/16d5b404cb14163a776b701265e55b6f66cdfc34) by [@moust4ki](https://github.com/moust4ki).

See the [source ledger](../../UPSTREAM_ATTRIBUTION.md).

## Foldable release qualification

The live playback route owns the decoder across pane changes. The Flutter geometry tests exercise flat and half-open folds, opaque hinges, two hinges, right-to-left placement, cropped windows and camera insets. The browse test keeps an editable detail mounted while closing and reopening the device. These are simulated inputs. Native output and lifecycle behavior require separate evidence.

| Target | Checks to record on a release candidate |
|---|---|
| iPhone Duo | Outer → inner → tabletop → PiP → return. Check camera clearance, both rail edges, paused and playing video, subtitles and OS Split View. Open a second window, browse music, switch profiles and verify that only one session owns transport. |
| Android book and dual-screen devices | Galaxy Fold, Pixel Fold, another OEM and a spanned physical hinge. Switch displays with the taskbar shown and hidden while seeking, changing subtitles and using live time-shift. |
| Flip and Razr | Continue inside after using transport on the cover. On Samsung add the Flex Window widget and check play, skip and open. Test both OEM continue-on-cover settings. |
| Multi-fold, tablet and standard phone | TriFold outer and fully open, narrow split-screen, compact phone and tablet. Check RTL manga, an EPUB reading anchor, PDF zoom, keyboard focus, large text and TalkBack or VoiceOver. |
| Steam streaming and native output | While streaming, fold and rotate, check touch coordinates against all four video corners and test the controller. Repeat video transitions with offline and streamed media, Watch Together, supported HDR formats and each available engine. |
| HarmonyOS NEXT | Build and sign the [native player](../../harmonyos/README.md). Test authenticated and local video, HDR and SDR, paused playback, tabletop, both creases on tri-fold hardware, PiP controls and return. |
| Windows foldable | Resize, span and unspan, test touch and keyboard, and verify the physical video rectangle and audible session. |

Record the commit, device model, OS, player backend, content mode, starting posture, final posture, observed position, audio and focus. An unrecorded case is unqualified.

The iOS native reliability job runs the phone-scene contract on the Duo simulator. On a hosted runner it also installs the built simulator app on an iOS 26 phone and checks that its process remains alive after launch. For Android, dispatch **Android foldable qualification** with the release workflow run ID. It installs that run's x86_64 APK on a Pixel Fold emulator and verifies the resumed activity and process identity across the supported closed, open and half-open states. Neither launch check substitutes for a media playback run on hardware.

## Playback evidence on the candidate device

For Android, start a movie on the desired engine, enable automatic PiP in the app and allow PiP in system settings. Use the device picker provided by standard ADB (for example, set `ANDROID_SERIAL`) when several devices are connected. Run these passes once while playing and again while paused. Enable and disable each OEM’s continue-on-cover setting in separate runs. A cover that the OS reserves for widgets must be recorded as such.

```sh
python3 scripts/qa/android_fold_smoke.py --playback --manual 'cover,inner,tabletop,inner' --commit "$(git rev-parse HEAD)" --evidence fold.json
python3 scripts/qa/android_fold_smoke.py --playback --pip --commit "$(git rev-parse HEAD)" --evidence pip.json
```

Use `--states` with a comma-separated list of supported IDs on emulators or devices that allow shell posture overrides. The script checks the foreground activity, process identity and one active media session. It records transport and position and checks the pinned task for PiP. Inspect the picture and subtitles on the actual panel, check for duplicate audio and compare the HDR output using a known SDR/HDR pair. A capability flag alone cannot establish panel output.

On Windows, span embedded panels, move the window until only one panel is visible, and repeat at different DPI and orientations. For a continuous internal panel, select the physical hinge direction under Settings → Playback → Foldable display hinge. Automatic uses the actual embedded-panel layout. Normal external monitors and mirrored clones should not add hinges.

For cold recovery, background a paused tuner or catch-up programme, allow the OS to save the task, then terminate the background process (on Android use `adb shell am kill org.snapetech.pleazyng`). Reopen from Recents. Verify the same channel, broadcast time and pause intent. Repeat after the broadcast has fallen outside the available buffer. A fresh tuner can only seek within its newly reported window. A memory-only buffer that died with the process falls back to live. Repeat with a locked Watch Together room as both host and guest, then after changing the profile, leaving the room or letting its server-side reconnect lease expire. Record room member identity and host control without recording the reconnect token.

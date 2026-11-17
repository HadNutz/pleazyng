# Pleazyng Privacy Notice

Effective November 17, 2026

Pleazyng is a media client. It does not create a Pleazyng account, host your media, or send your library to a Pleazyng server. The app stores its working data on your device and connects to the media servers and other services you choose to use.

## Data stored on your device

Pleazyng stores app settings, server and profile details, library preferences, and information needed to resume playback. It may also store authentication tokens for the services you connect, downloaded media, and diagnostic logs. Tokens are protected with platform secure storage where supported; other app data is kept in the app's local storage. Local speech features may save a bounded, profile-scoped cache of generated subtitle text and timing metadata so the same WAV can be reused for another translation. On a cache miss, the selected WAV is staged in temporary app storage for transcription. Pleazyng attempts to remove temporary WAV copies when processing ends; if cleanup fails or the app stops unexpectedly, they may remain until temporary or app storage is cleared. The persistent transcript cache does not contain WAV bytes. Without an active profile, one transcript is kept in memory for the current app process only. Cached transcripts remain on the device until they are evicted or app storage is cleared. Media saved to a folder you selected may remain there and can be deleted separately.

If you turn on **Save transcript recovery on this device**, playback speech recognition also saves recognized text, cue timings and interruption/gap information for the current profile and item. This option is off by default for each subtitle sheet session. The recovery journal keeps up to 12 captures and 64 MiB per profile, removing older captures as needed. It contains no audio, source credentials, media titles or resolved media URLs. Restoring requires confirmation of the current media edition and audio track; it opens the saved text for review and never resumes recording or applies subtitles automatically. Removing the profile or clearing app storage removes these checkpoints.

## Connections to other services

When you sign in or use a feature, Pleazyng sends the requests needed for that feature to the service you selected. This can include Plex, Jellyfin, or Emby servers; Plex account and discovery services; optional services you connect for tracking, requests, recommendations, or media information; a Watch Together relay you configure; a WebDAV endpoint you configure for backups; and a Cast receiver you choose. Those services receive the information needed to answer the request, such as account credentials or tokens, server and media identifiers, playback actions, and network details. Each service handles that information under its own privacy terms.

Standalone video metadata lookup is off by default for file sources. If you enable it, opening a video's details can send a cleaned filename title, optional year, detected episode numbers, or an existing NFO catalog identifier to Trakt for matching. The video file, full source path and source credentials are not sent for that lookup. If you enable encrypted progress and notes sync, the configured WebDAV or cloud-drive storage provider receives the sync files; cloud-drive write access is requested only for this feature. Settings backup is a separate WebDAV upload containing the portable settings export. Review the destination and exported settings before enabling either service.

Store purchases are handled by the store where you got the app, except LG builds that use the Paymentwall checkout described below. Pleazyng does not receive your payment card details.

### LG lifetime unlock through Paymentwall

In LG webOS builds configured for Paymentwall, the app generates a random license identifier and a separate recovery credential, protected by the device key store. No new Pleazyng account or media-server account is required. The recovery code is shown only when you request it; keep it private because it permits restoring the license on another device.

When you open checkout or check/restore ownership, the app sends the license identifier and recovery credential over HTTPS to `billing.pleazyng.app`. The billing service stores a hash of the credential, license ownership/revision, payment reference, fixed product and price, refund status, callback records, and short-lived checkout-session hashes. It queries Paymentwall to verify the purchase and handle refunds; a browser success message alone does not unlock the app. Paymentwall receives the random license identifier and product information and processes the payment under [its privacy policy](https://www.paymentwall.com/en/privacypolicy). The billing service does not receive your media library, server credentials or playback history. Network providers receive ordinary connection information, such as your IP address.

A signed ownership record is stored on your device for offline access and updated when verified ownership changes. Billing records are retained on the service for restoration and refund handling; uninstalling or clearing local data does not erase those records or Paymentwall's records. For questions or requests about these records, contact **support@snape.tech** privately. Do not post a recovery code or payment reference in a public issue. Paymentwall handles requests about payment information it holds.

Pleazyng does not use advertising or analytics SDKs. The standard store build workflow does not include Sentry crash reporting. Other builds can include optional crash reporting; when included and enabled in Settings, diagnostic events may be sent to Sentry. You can turn off crash reporting in the app settings.

Release builds can check GitHub for Pleazyng updates. When a check runs, GitHub receives the request and ordinary network information such as your IP address.

## Sharing and retention

Pleazyng maintainers do not receive your media library, server credentials, or playback history through a Pleazyng service. Information remains on your device except for the selected service connections, authorization handoff and purchase verification described in this notice, or when you export and share a log or backup or contact the maintainers. Connected services apply their own retention rules. Logs and backups can contain device or server details, so review them before sharing.

You can remove local app data by deleting it in the app where supported, clearing the app's storage, or uninstalling the app. Media saved to a user-selected folder may remain there. To remove information held by a media or third-party service, use that service's account controls.

## Disconnecting accounts and deleting data

Pleazyng does not create or operate a Pleazyng user account. You can connect accounts that you already have for services such as Plex, Jellyfin, and Emby. Removing a server or service connection in Pleazyng removes that connection from the app, but does not delete the account or server data held by that service.

To delete an account held by a connected service, use that service's account controls. For a self-hosted Jellyfin or Emby server, contact the server administrator. Pleazyng cannot delete accounts, media, or playback data held by those services. To remove data stored locally by Pleazyng, remove the connection in the app, clear the app's storage, or uninstall it. Downloads saved to a folder you selected may need to be deleted separately.

## Contact

For privacy questions, use the [Pleazyng GitHub project page](https://github.com/snapetech-org/pleazyng/issues). GitHub issues are public; do not include passwords, access tokens, server addresses, or other sensitive information in an issue.

We may update this notice when the app's data practices change. The effective date above will change with each revision.


## Trakt integration

Connecting Trakt is optional. When connected, Pleazyng reads your account details, watch history, ratings and lists for the features you use. Playback scrobbling and watched-state sync send playback events or changes to your own Trakt account when you enable those features. Metadata searches send the search title and identifiers, not your media files or source credentials. Trakt data is used within Pleazyng for these features; it is not sold or provided as a catalog or data feed to other services.

Trakt device-code authorization connects directly to Trakt. Browser authorization requires a user-operated HTTPS relay that you explicitly configure; that relay handles the authorization exchange and temporarily holds its result for the initiating app. Trust the relay operator before using it. Official builds contain no default relay URL, and the first-party MyAnimeList broker does not process Trakt authorization or tokens. No Trakt client secret is included in the app. Account tokens and cached data remain on your device for your connection and selected features.

Disconnect Trakt in Settings → Services → Trakt to stop account access, remove the local connection and attempt to revoke its token. You can also revoke Pleazyng in Trakt's connected-app settings. Disconnecting does not erase history or lists on Trakt; use Trakt's account controls to manage or delete that data. Clear Pleazyng's app storage to remove remaining local caches. For help with data you sent directly to SnapeTech support, contact support@snape.tech; we retain support correspondence only as needed to handle your request and applicable recordkeeping obligations.

Pleazyng uses Trakt but is not endorsed or certified by Trakt.

## MyAnimeList authorization handoff

The optional MyAnimeList sign-in uses a first-party Cloudflare-hosted callback to return a single-use authorization code to the initiating app. The app holds its PKCE verifier locally and exchanges the code directly with MyAnimeList. The callback receives and briefly retains the authorization code and signed state until delivery or expiry; it does not receive the verifier or provider access/refresh tokens and does not forward requests to a home-hosted relay. Cloudflare receives ordinary request/network information.

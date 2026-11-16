# Store listing copy

Store copy is platform-specific. Do not paste the shared cross-platform paragraph
into a TV or mobile listing without checking which features, controls and media
formats are present in that store's build. Product pages must describe the
app's own experience, not the features of another Pleazyng package.

## Short descriptions

Google Play short description (64 characters):

> Plex, Jellyfin and Emby player with downloads and watchlist sync

Apple App Store subtitle (24 characters):

> Your media, in one place

Amazon Appstore short description (64 characters):

> Browse and play your Plex, Jellyfin or Emby libraries on Fire TV

AppStream summary (30 characters):

> Plex, Jellyfin and Emby client

## Cross-platform package description

Use this for general-purpose desktop/package listings only when the package
supports the described controls and media. It is not a default for phone or TV
store listings.

> Pleazyng connects to your own Plex, Jellyfin or Emby server so you can browse and play available video and music, continue from saved progress, manage watchlists, and choose available audio and subtitle tracks. Depending on the server and device, you can also use supported Live TV and DVR, offline downloads, and Watch Together playback. Features and playback quality depend on the server, account permissions, media, device and distribution channel. Pleazyng does not provide media or a server. Pleazyng uses Trakt but is not endorsed or certified by Trakt.

## Amazon Appstore: Fire TV

Use this copy for the Fire TV listing. It deliberately limits its claims to
server-backed video browsing and playback with a remote; it makes no HDR,
Dolby Vision, downloads, Watch Together, or cross-device claim.

**Short description:**

> Browse and play your Plex, Jellyfin or Emby libraries on Fire TV

**Long description:**

> Pleazyng for Fire TV lets you browse and play video from your own Plex, Jellyfin or Emby media server using a Fire TV remote.
>
> Connect to a server account, choose a library and title, then play available video. During playback, select audio and subtitle tracks provided by your server and use the playback controls available on your device.
>
> Pleazyng does not provide movies, shows, server accounts or hosted media. You need network access and access to a compatible server. Available titles and playback options depend on your server, media, account permissions and Fire TV device.
>
> Pleazyng uses Trakt but is not endorsed or certified by Trakt.

**Feature bullets:**

- Connect to a Plex, Jellyfin or Emby server you use.
- Browse video libraries with a Fire TV remote.
- Resume server-saved playback progress.
- Select the audio and subtitle tracks your server provides.
- Use your own media; Pleazyng does not include video content.

Keep the app title and publisher identity consistent with the installed app and
the seller account. Do not include prices, ASINs, unrelated platform names,
unverified media-quality claims, or screenshots from another form factor. Amazon
listing metadata must not state the app or IAP price.

## Google Play: Android phones, tablets and TV

> Pleazyng connects your Android device to your own Plex, Jellyfin or Emby server. Browse and play available movies, shows and music, follow saved playback progress, manage watchlists, and choose available audio and subtitle tracks. Supported servers and devices may also provide Live TV, DVR, offline downloads and Watch Together. Playback quality and feature availability depend on the server, account, media and device. Pleazyng does not provide media or a server. Pleazyng uses Trakt but is not endorsed or certified by Trakt.

Use current Android captures from the Play-signed build. Do not use Amazon-flavor
screenshots as proof of the Play purchase, review-access or entitlement flow.

## Apple App Store

> Pleazyng connects your Apple device to your own compatible media server. Browse your library, play available media, follow server-saved progress, and use the playback controls available on your device. You need your own compatible server and account. Available titles, playback options and features depend on the server, account, media and device. Pleazyng does not provide media or a server. Pleazyng uses Trakt but is not endorsed or certified by Trakt.

Keep each product page focused on the Apple device it supports. Use captures of
the submitted iOS, tvOS or macOS build for that product page; do not mention
other mobile platforms or app marketplaces in Apple metadata.

## Microsoft Store

> Pleazyng connects your Windows PC to your own Plex, Jellyfin or Emby server. Browse and play available media, follow saved playback progress, manage watchlists, and use the audio, subtitle and playback controls supported by your server and device. Pleazyng does not provide media or a server. Available titles and features depend on your server, account, media and Windows device. Pleazyng uses Trakt but is not endorsed or certified by Trakt.

Use screenshots from the Windows Store package and show the desktop experience.
Do not imply that TV remotes, Fire TV, Apple devices or Android-only functions
are part of the Windows package.

## Samsung and LG TV stores

> Pleazyng connects your TV to your own Plex, Jellyfin or Emby server. Browse and play available video with your TV remote. Available titles and playback options depend on your server, account, media and TV model. Pleazyng does not provide media or a server. Pleazyng uses Trakt but is not endorsed or certified by Trakt.

Use actual captures from the matching Tizen or webOS package and TV model. Do not
claim HDR, Dolby Vision, a codec, audio format, resolution, IAP or playback
behavior unless that exact build and target device support it.

## Store links

- Privacy policy: `https://github.com/snapetech-org/pleazyng/blob/main/PRIVACY.md`
- Support: `https://github.com/snapetech-org/pleazyng/issues`

## Listing and image audit

- Amazon rejected Pleazyng 3.0.33 for listing accuracy. The committed Amazon TV
  and tablet captures now come from the exact signed 3.0.36 Amazon APK and have
  per-image provenance. The corrected Fire TV text and new image sets are ready
  for the Developer Console. Inspect every icon, promotional-art and screenshot
  slot, replace stale assets and verify the saved metadata before resubmitting;
  this repository cannot show what is currently attached in the seller portal.
- Google Play's saved draft uses the broad description above and its screenshot
  receipts identify version 3.0.0 built with the Amazon flavor. Reconcile the
  draft to Android Play capabilities and refresh captures from the Play build
  before public production review.
- Apple has no submitted version. Keep its prepared listing Apple-specific and
  attach device-matched screenshots before its first submission.
- Microsoft has no published listing and publisher verification remains
  pending. Use the Windows-specific copy and captures when the assigned Store
  identity is available.
- Samsung Tizen and LG webOS are manual TV-store handoffs, not published store
  listings. Their current packages and images require seller review and exact
  device qualification before any public availability claim.
- Linux package summaries and Homebrew/Chocolatey/WinGet metadata are not mobile
  app-store listings. Keep their product scope and public status aligned with
  the package actually delivered.

The store screenshot review pack is maintained in
[`store-listing-assets/README.md`](store-listing-assets/README.md). Synthetic
widget renders and mockups are not store screenshots.

# Research notes

What the surrounding ecosystem looks like, and what macOS 27.2 actually allows, gathered before
deciding what this fork should become. Written for whoever picks this up next — including future
me — so every claim says where it came from: **[verified here]** means run on this machine
(macOS 27.2.1, build 26B131, 2026-11-24), **[doc]** means a primary source, **[one-source]** means
I found only one account of it.

## 1. What a wallpaper slot can hold, on this machine

`WallpaperCore` no longer exists as an inspectable framework: `/System/Library/PrivateFrameworks/`
has no such bundle, and the name survives only as a static module inside
`/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent`. The provider
identifiers therefore come from `strings -a` over the agent and the appexes in
`/System/Library/ExtensionKit/Extensions/`:

| Provider | Payload | Settable by hand? |
|---|---|---|
| `…choice.image` | `{type: "imageFile", url: {relative: "file://…"}}` | yes |
| `…choice.dynamic` | `{type: "systemDesktopPicture", url: {relative: "…/X.madesktop"}}` | yes |
| `…choice.color` | `colors`, `colorSpace` (GradientExtension) | yes |
| `…choice.image-folder` | folder in `Files`, cadence in `Content.Shuffle` | yes, coarse |
| `…choice.aerials` | `{assetID}` — must resolve in the aerial catalogue | yes, see §3 |
| `…choice.screen-saver` | `name`/`moduleName` + `path` (LegacyExtension) | unreliable |
| `…choice.helios` | solar / "Automatic" grouping | not decoded |
| `…choice.sonoma`, `…choice.sequoia` | bundled motion wallpapers | no |

**[verified here]** There is no `…choice.sequence`: Apple's photo-sequence provider is gone,
replaced by `image-folder`.

The store on this machine (`…/com.apple.wallpaper/Store/Index.plist`, 932 B) populates only
`AllSpacesAndDisplays` and `SystemDefault`; `Displays` and `Spaces` are empty dicts, and each scope
has `Desktop` + `Idle` — not `Linked`/`ScreenSaver`. `Idle` is `Provider: default` with an empty
`Configuration`: "no screensaver" is expressible, which is why the fork's restore must not assume
an aerial lives there.

`/System/Library/Desktop Pictures/` holds 63 `.madesktop` files that are XML plists and only
*point* at content (`mobileAssetID`, `thumbnailPath`, `isDynamic`, `isSolar`, width, height); the
frames come from the MobileAsset catalogue. So "a dynamic wallpaper" means "an asset id in another
database", which is why user-made dynamic HEICs are addressed by URL instead (§3).

## 2. The aerial catalogue, and how it refreshes

**[verified here]** `~/Library/Application Support/com.apple.wallpaper/aerials/`:

- `manifest/entries.json` — 194 KB, 164 assets; keys `assets`, `categories`, `initialAssetCount`,
  `localizationVersion`, `version`; per asset `id`, `shotID`, `url-4K-SDR-240FPS`, `previewImage`,
  `subcategories`, `variant`, `videoGravity`, `group`, `includeInShuffle`, `pointsOfInterest`.
- `manifest/manifest.source` — one line: `/itunes-assets/Aerials126/v4/82/2e/34/…/resources-27-0-1.tar`.
- `manifest.tar` — 2 MB, the archive `entries.json` was extracted from.
- `thumbnails/` — 229 `<assetID>.png`.
- `videos/` — one `<assetID>.mov`, 460,351,092 bytes, mode `0600`.

**[verified here]** Extended attributes tell you how Apple tracks its own downloads:

```
videos/4207734D-….mov      LastETag: "6321…-7"   com.apple.quarantine: 0086;…;WallpaperAerialsExtension;
thumbnails/4207734D-….png  LastETag: "7CF7…"     SourceURL: https://sylvan.apple.com/…/GG_A_Sunset_…_Thumbnail.png
```

So provenance is `SourceURL` + `LastETag` per file, written by the aerials extension itself, and a
missing `LastETag` is what invites a re-download.

**[verified here]** `defaults read com.apple.wallpaper.aerial`:

```
LastAerialDownloadDate = 2026-07-19 07:48:12 +0000
lastUpdateDate         = 2026-09-04 04:05:22 +0000
remoteResourceURL      = https://sylvan.apple.com/itunes-assets/Aerials126/v4/…/resources-27-0-1.tar
scheduledUpdateDate    = 2026-11-25 05:42:41 +0000
```

Two things follow. Links are per-OS and re-keyed, so anything hard-coded rots. And the catalogue is
re-fetched on a schedule — here, the next morning — which means anything written *into*
`entries.json` is on a timer. That is the strongest argument in these notes against injecting fake
assets into Apple's own manifest.

**[verified here]** The clip on disk is HEVC, Main 10, 4096×2160, `yuv420p10le`, and its SPS says
`sps_max_sub_layers_minus1 = 4` with `nuh_temporal_id_plus1` values 1–5: **five temporal
sub-layers**. Any user video that wants to be treated as an aerial has to match that class of
encoding — see §3(b) for what happens when it doesn't.

**[doc]** CDN history (tvOS 10 `a1.phobos.apple.com`, tvOS 11 `sylvan.apple.com/Aerials/2x/`, later
`…Aerials-13/-15/-16.tar`, tvOS 26 via `bag.itunes.apple.com/bag.xml` needing the
`X-Apple-Store-Front: 143441-1,29` header) is in [theothernt's gist](https://gist.github.com/theothernt/57a51cade0c12c407f48a5121e0939d5);
quality keys are `url-1080-SDR/HDR`, `url-4K-SDR/HDR`, `url-4K-SDR-240FPS`.

**[doc]** The whole catalogue is 60–80 GB: [WallGet](https://github.com/mikeswanson/WallGet)
(user path vs legacy `/Library/Application Support/com.apple.idleassetsd`, `.part` + atomic rename +
resume, and a warning that macOS re-downloads aerials by itself while an aerial wallpaper is
active) and [Aerialist](https://github.com/eddytwist/aerial-shelf) ("164 videos ≈ 80 GB, avg 0.5 GB",
2026-11-07). This is why the fork's download consent exists at all.

**[doc]** Nobody redistributes Apple's clips: [aerial-tv](https://github.com/pengchujin/aerial-tv)
states the footage is Apple's and streams it from Apple's servers; Aerialist says it "doesn't
include or redistribute them". An MIT licence on a downloader grants no rights to the videos.

## 3. Making a slot something the user chose

Four routes, in ascending order of ambition and risk.

**(a) Still image, dynamic HEIC, colour — the store's own vocabulary.** The payloads in §1 are all
writable by hand. A published working recipe (walks every `Desktop.Content.Choices` node, then
`killall -HUP cfprefsd && killall WallpaperAgent`, SIGTERM not SIGKILL because SIGKILL makes the
agent restore from `/var/db/Wallpapers`) is
[macos-tahoe-wallpaper.md](https://github.com/odakin/claude-config/blob/main/conventions/macos-tahoe-wallpaper.md).
For sun-cycle content the format is the `apple_desktop:solar` / `apple_desktop:h24` HEIC metadata
([NSHipster](https://github.com/NSHipster/articles/blob/master/2018-10-01-macos-dynamic-desktop.md),
[wallpapper](https://github.com/mczachurski/wallpapper)): one file that changes with the sun, no
process running. [BiAksoy's tool](https://github.com/BiAksoy/aerial-dynamic-wallpaper) builds one
from four user images (`aerial-build-dynamic --images morning.png day.png …`) and applies it with
the public `NSWorkspace.setDesktopImageURL`, "last checked macOS 27.2".
**[doc]** Apple picks the frame from the *sun's position* for your location, falling back to the
time zone when Location Services is off
([Apple, Wallpaper settings](https://support.apple.com/en-me/guide/mac-help/mchlp1103/14.0/mac/14.0)),
and the selection rule was reverse-measured as (altitude, azimuth, frame) scoring on the sun's half
of the sky ([solar-selection.md](https://github.com/BiAksoy/aerial-dynamic-wallpaper/blob/main/docs/solar-selection.md),
[pdfux's notes](https://gist.github.com/pdfux/5659724021e584313c00b843312e909d)).

**(b) Arbitrary local video as an aerial — the keys exist on this OS, the encoder is the catch.**
**[verified here]** `strings -a` on
`/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/MacOS/WallpaperAerialsExtension`
contains `AerialManifestLocalPathOverride`, `AerialManifestURLOverride`, `AerialManifestForceLocal`,
plus the log lines "AerialManifestForceLocal is set; skipping downloaded manifest" and "Loading
fallback manifest (AerialManifestLocalPathOverride: %s)". No signature or checksum-validation
strings appear around the manifest file itself.
**[doc]** [Aerialist's `CatalogOverride.swift`](https://raw.githubusercontent.com/eddytwist/aerialist/main/Sources/AerialCore/CatalogOverride.swift)
uses exactly this: a *copy* of `entries.json` with custom assets, `<uuid>.mov` in `videos/`,
`<uuid>.png` in `thumbnails/`, `includeInShuffle: false`, and a deliberately non-resolving
`url-4K-SDR-240FPS` (`https://aerialist.invalid/videos/<id>.mov`) so only the local file is used;
undo is deleting the two keys, and its README warns an update may stop honouring them.
**[one-source]** [AerialSwap](https://github.com/mxpalm/AerialSwap/blob/main/docs/TECHNICAL.md)
takes the rougher road — injecting its own category into Apple's `entries.json` ("nothing checks a
signature on that file"), APFS clones plus `SourceURL` xattrs, and a LaunchAgent that watches the
manifest and re-injects when macOS overwrites it. It documents the failure that matters most here:
**a video without HEVC temporal sub-layers produces `VideoSampleReadingErrors Code=4` and a grey
desktop**, with no crash report, and [the same class of breakage](https://github.com/AlexisBCD/macos-custom-video-wallpaper-fix)
is reported on 14/15/26 independently. Given §2's five sub-layers on Apple's own clip, that is the
real gate on "use my own footage".
**[one-source]** [LivePaper](https://github.com/Raunik2/LivePaper) additionally purges `.bmp`
snapshots from a `com.apple.wallpaper.caches` directory after each swap — **[verified here]** that
directory does not exist on this machine, so treat it as version- or state-dependent.

**(c) Your own wallpaper app extension — the durable answer.**
**[doc]** [Phosphene](https://github.com/kageroumado/phosphene) (`brew install --cask phosphene`,
macOS 26+) puts any video into System Settings › Wallpaper and the lock screen and keeps playing
after the app quits; its [REFERENCE.md](https://github.com/kageroumado/phosphene/blob/main/REFERENCE.md)
documents `WallpaperExtensionKit` loading, the `acquire/update/invalidate/snapshot` XPC, an
`AVSampleBufferDisplayLayer` in a remote `CAContext`, a required `WallpaperSnapshotXPC` swizzle, and
the stale-`.appex` → `com.apple.extensionKit.errorDomain (2)` fix (`lsregister -f`).
**[verified here]** the extension point is not open in the ordinary sense:
`/System/Library/ExtensionKit/ExtensionPoints/com.apple.wallpaper.appexpt` requires
`com.apple.private.wallpaper.extension` (host: `…extension-host`). Phosphene and Aerial 4 ship such
extensions anyway, so the entitlement is evidently obtainable — or not enforced — for locally
installed, non-sandboxed bundles; **[one-source]**, needs a build to confirm.

**(d) Screen-saver slot.** **[doc]** Third-party `.saver` modules are broken in the legacy engine on
Sonoma, Sequoia and Tahoe ([Wade Tregaskis](https://wadetregaskis.com/how-to-make-a-macos-screen-saver/)),
and the engine doesn't reliably send `terminate`
([HN](https://news.ycombinator.com/item?id=42881342), [open Feedbacks](https://forums.developer.apple.com/forums/profile/C_Wiz/replies?sortBy=lastUpdated)).
**[verified here]** the legacy engine now lives at
`/System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex` (plus an x86_64
twin), outside `/System/Library/ExtensionKit/Extensions/`, and `/usr/libexec/idleassetsd` is gone
while the agent still references `/Library/Application Support/com.apple.idleassetsd/Customer/`.
Conclusion: keep the fork's "follow the screen saver only while it is still ours" rule; don't build
on `.saver`.

## 4. Public APIs, and why the plist hack is not laziness

**[doc]** `osascript -e 'tell application "System Events" to set picture of every desktop to …'` is
reported returning success while the screen stays put on 26.5.x, and per an
[Apple developer forum reply (Feb 2026)](https://developer.apple.com/forums/thread/814926) it turns
**"Show on all Spaces" off**, which quietly confines every later change to the active Space.
**[doc]** `NSWorkspace.setDesktopImageURL(_:for:options:)` is public and per-`NSScreen`; the same
Tahoe doc says it is dead on 26.5.x while BiAksoy reports it working on 27.2. Known papercuts:
setting the same path with new content doesn't refresh, and
[sindresorhus/macos-wallpaper](https://github.com/sindresorhus/macos-wallpaper) (718★,
`brew install wallpaper`) documents `desktopImageURL(for:)` returning a *directory* before 26, no
`Tile` support, and images only. [desktoppr](https://github.com/scriptingosx/desktoppr) is the MDM-side
reference for the same step.
**[verified here]** neither route can address a per-Space or per-display scope: those exist only as
`Spaces.<uuid>` / `Displays.<uuid>` nodes in the store.

So the supported APIs are images-only, version-fragile and blind to scope. Writing the store is more
capable and, paradoxically, more predictable — at the cost of owning an undocumented format. That
trade is the entire reason [PaperSaver](https://github.com/AerialScreensaver/PaperSaver) exists.

## 5. Ecosystem map

| Project | What it is | Why it matters here |
|---|---|---|
| [Aerial 4.1](https://github.com/AerialScreensaver/Aerial) | wallpaper + screensaver *app extension*, macOS 26/27, v4.1.12 (2026-11-19) | already does time-of-day, scheduled auto-advance, local `.mov/.mp4`, live feeds, cache limits, thermal/battery pause |
| [PaperSaver](https://github.com/AerialScreensaver/PaperSaver) | MIT SwiftPM library, macOS 14+, writes the store for you | `setWallpaperExtension(slot:.desktop)`, `WriteOptions(restartAgent, verify, rollbackOnFailure)`, `Index.plist.backup`, per-display/Space targets, `Type = linked\|individual\|idle`, and a measured ~1-in-3 agent restarts on 27.2 that leave the extension not running |
| [Aerialist](https://github.com/eddytwist/aerial-shelf) | menu-bar shelf + `aerialctl` | closest to this fork's feature set; the manifest-override recipe in live code |
| [AerialSwap](https://github.com/mxpalm/AerialSwap) | custom video wallpapers via manifest injection | the temporal-sublayer failure mode, `testedMajorVersion` gating, a manifest watcher |
| [Phosphene](https://github.com/kageroumado/phosphene) | any video as a real wallpaper, via app extension | the long-term answer to "user-customizable" |
| [WallGet](https://github.com/mikeswanson/WallGet) | downloader for the whole catalogue | download / resume / size hygiene |
| [rebeccacremona/wallpaper](https://github.com/rebeccacremona/wallpaper) | "Tahoe Aerial Switcher": LaunchAgent + captured plists | the launchd alternative, plus a documented gotcha: some variants store `Provider: default` with an empty config rather than an aerial id |
| [macos-wallpaper](https://github.com/sindresorhus/macos-wallpaper), [aerial-dynamic-wallpaper](https://github.com/BiAksoy/aerial-dynamic-wallpaper) | CLI `wallpaper`, `aerial-build-dynamic` | images and dynamic HEIC without touching the store |
| [JohnCoates/Aerial](https://github.com/JohnCoates/Aerial) | legacy `.saver`, last release 3.6.3 (2025-08-12) | the history, and [CustomVideos.md](https://github.com/JohnCoates/Aerial/blob/v3.6.3/Documentation/CustomVideos.md) which predates all of this |
| [Alpenglow](https://github.com/remco-space/Alpenglow), [Moodpaper](https://github.com/FuturisticXx/Moodpaper), [WallpaperScheduler](https://github.com/Kapfilm/WallpaperScheduler), [Sundial](https://github.com/Nyxnix/sundial) | photo-library / slot-based rotators | the UX vocabulary for per-slot content (§7) |

**[doc]** Aerial 4's open issues are the same class of problem this fork has: #210 auto-pause
clashes with "Show on all Spaces", #207 `VTDecoderXPCService` memory pressure, #134 external
display wallpaper stops, #175 cache limit exceeded. Nobody has this nailed.

## 6. Menu bar, scheduling and login-item conventions

**Hiding the icon is a documented API, not a hack.** **[verified here]** the SDK this package builds
against has `MenuBarExtra` initialisers taking `isInserted:`
(`arm64e-apple-macos.swiftinterface:2379,2417-2493`, all `@available(macOS 13.0,*)`), and
[Apple's page](https://developer.apple.com/documentation/swiftui/menubarextra) samples exactly
`@AppStorage("showMenuBarExtra")` + `MenuBarExtra(…, isInserted: $showMenuBarExtra)`. The same page
states the trap: *"an app that only shows in the menu bar will be automatically terminated if the
user removes the extra from the menu bar"* — so the toggle must live in Settings, and the app must
not depend on the extra to stay alive. Patterns worth copying:
[boring.notch](https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/boringNotchApp.swift)
(persisted default, `isInserted`), [AltTab](https://github.com/lwouis/alt-tab-macos) (`StatusItemLifecycle`
*removes* rather than hides, because a retained hidden item was reported to intercept Apple-menu
clicks on 15.8.1; KVO on `isVisible` so a ⌘-drag-off persists the preference),
[Ice](https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/ControlItem/ControlItem.swift)
(caches/restores `preferredPosition` around `isVisible = false` because hiding deletes it),
[Stats](https://github.com/exelban/stats/blob/master/Stats/AppDelegate.swift) (Dock policy derived
from a `dockIcon` default *and* whether a window exists).
[doc]** Note also that macOS 26+ moved this partly into the system:
["Change Menu Bar settings on Mac"](https://support.apple.com/en-us/guide/mac-help/mchlad96d366/mac)
(its macOS 27 page lists items to include in the menu bar, including third-party ones), and that a
stale `isAllowed:false` / `menuItemLocations` entry can make an extra vanish with no app involvement
([forum](https://developer.apple.com/forums/thread/827337)). So the in-app toggle is a convenience,
not the only defence.

**Reaching Settings with no icon.** **[doc]** `applicationShouldHandleReopen` fires when Finder or
the Dock reactivates a running app ([Apple](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)));
Stats and AltTab both open settings there, and this fork already does
(`AerialSwitcherApp.swift:33-37`). Keep `isReleasedWhenClosed = false`; `SettingsLink` /
`openSettings` (macOS 14+) is bypassed by apps hosting settings in an `NSWindowController`, which is
what `SettingsWindow.swift` does.

**Scheduling.** **[doc]** `launchd.plist(5)` is explicit: unlike cron, `StartCalendarInterval` jobs
are started on the next wake and multiple missed intervals coalesce into one, while `StartInterval`
misses intervals "due to shortcomings in kqueue(3)"; `RunAtLoad` should be avoided. A user
LaunchAgent only runs in an Aqua session — the same constraint as Apple's own
`/System/Library/LaunchAgents/com.apple.wallpaper.plist` (`LimitLoadToSessionType = Aqua`).
**[verified here]** cron is present but not running on this machine (`pgrep -l cron` → none,
`/etc/crontab` absent, `/usr/lib/cron` a dangling symlink), so it is not an option.
**[doc]** `Timer`/`DispatchTime` are uptime-based and freeze across sleep, while wall-clock
deadlines (`dispatch_walltime`) don't; Apple's own clock docs say `ContinuousClock` keeps counting
through sleep and `SuspendingClock` stops.
**Current state here:** `AppModel` polls coarsely and forces a sync on
`didWake`/`sessionDidBecomeActive`/clock/TZ change, and `Schedule.phase(at:)` re-derives from
`Date()`, so a sleep-through-a-slot self-heals on wake. `Schedule.nextChange(after:)`
(`Schedule.swift:58`) already exists and is unused for scheduling — the cheap improvement is exact
wall-clock ticks from it, with the poll kept as the safety net.

**Login items.** **[doc]** `SMAppService.mainApp` is the app-as-login-item service; `.agent`/`.daemon`
register bundled helper plists. `status == .requiresApproval` means registered but the user has not
approved it — and `register()` returns *without error* in that case, which is the silent-failure
path ([status docs](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval)).
BTM auto-approval is built on Developer ID + notarization, so an ad-hoc build lands in the
user-toggled list and every rebuild can reset consent.
**[verified here]** `codesign -dvv` on the installed app gives `flags=0x2(adhoc)`,
`TeamIdentifier=not set`, `spctl -a -t install` → rejected, yet it runs because the bundle carries
only `com.apple.provenance` and no `com.apple.quarantine` (built and copied, not browser-downloaded;
Gatekeeper only assesses *downloaded* software
([Platform Security](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web))).
`sfltool dumpbtm` shows no `aerial-switcher` record, i.e. the login item is not registered — which
also means `AppModel.swift:22`, which samples `.status` once at init, has never seen anything.
Since macOS 15 the Control-click → Open bypass is gone, leaving only Open Anyway in
Privacy & Security ([Nektony](https://nektony.com/how-to/remove-non-notarized-apps-mac?srsltid=AYCX9vKaABrTMwg0iapg2c69QY0Fkj8iROzI8lZSTfmWo-YAoWm2qCn8),
[iBoysoft](https://iboysoft.com/tips/allow-apps-to-run-sequoia.html) — secondary sources).

## 7. How comparable apps say it, and what "set and forget" means

**[doc]** Per-slot content has three vocabularies in the wild: "periods"
([WallpaperScheduler](https://github.com/Kapfilm/WallpaperScheduler): 2/4/8 periods, per-period image
and start time), "time slots" with named phases
([Moodpaper](https://github.com/FuturisticXx/Moodpaper): Deep Night…Evening, "assign favorites to a
time of day"), and "rules" plus "slideshows" ([Sundial](https://github.com/Nyxnix/sundial)).
**[doc]** When a tool stops for a reason, the good pattern is Apple's own battery menu: one pinned
row with state + reason + one-tap resume ("Charging On Hold" → "Charge to Full Now",
[Apple](https://support.apple.com/en-am/102397)), and f.lux's "Disable → for an hour / until sunrise".
The fork's existing "Your own wallpaper is showing" is already in that register; what it lacks is a
resume affordance next to the reason.
**[doc]** For *when*, the community's set-and-forget winner is the zero-process file: a dynamic HEIC
needs nothing running, while every scheduler owes itself wake/startup/time-zone sync
([f.lux](https://justgetflux.com/news/pages/macquickstart/) is the model: "tell f.lux where you
live, then forget about it"). [SunsetScreen](https://www.skytopia.com/software/sunsetscreen/)
deliberately makes sunrise/sunset *manual* because astronomy-based times felt too early in winter —
worth remembering before wiring location in.
**[one-source]** [24 Hour Wallpaper](https://apps.apple.com/cn/app/24-hour-wallpaper/id1226087575?l=en)
(30+ frames per scene, its own "ProTime engine" or Apple dynamic) is the closest commercial analogue
to what a per-slot editor here would look like.

**Content from a library the user already owns.** **[doc]** [Alpenglow](https://github.com/remco-space/Alpenglow)
is the interesting one: it does *not* copy — it maintains an album inside the Apple Photos library
and lets System Settings rotate it. [WallpaperScheduler](https://github.com/Kapfilm/WallpaperScheduler)
copies into `~/Documents/WallpaperScheduler/Presets` so it survives uninstall;
[Sundial](https://github.com/Nyxnix/sundial) uses security-scoped bookmarks and copies nothing.
**[doc]** Lightroom Classic has no read API: the supported seam is the SDK's export actions
([Adobe](https://helpx.adobe.com/cn/lightroom-classic/help/export-presets-settings-plug-ins.html)),
so "auto-export a folder, let the app rotate it" is the honest design, and no project does this
today (only [lightwall](https://github.com/nordstrand/lightwall), 0★, empty README).
**[doc]** Skip Unsplash as a built-in source: its API terms require hotlinking the returned URLs and
calling `download_location` when "setting an Image as background wallpaper"
([terms](https://unsplash.com/api-terms)), which fights this fork's offline, consent-first posture.

## 8. Upstream health, and where the fork overlaps

**[verified here]** GitHub REST, 2026-11-24: `YnNJU/aerial-switcher` has 46 stars, 3 forks, 0
watchers, MIT, 15 commits on `main` — 4 on 2026-04-17/18 (CLI origin), then 11 on 2026-11-02→06
(the menu-bar rewrite and v1.0.0→1.0.3), nothing since. Releases v1.0.0–v1.0.3. Open items are
exactly two, both filed 2026-11-15 by `ysyecust`: **#1** "Preserve screen saver changes on restore,
keep non-sync errors visible, support download retries" and **#2** (PR, `fix/restore-errors-and-downloads`,
unmerged, 10 files +430/−70) closing it. There are **no** issues about per-slot customization or
menu-bar visibility, and no CI workflows in the repo or in any of the three forks.

So: nothing upstream collides with the two features this fork is considering; the collision is with
PR #2, which overlaps fork items 3, 4 and 5 but not 1 and 2 (see FORK.md). Upstream's own README
already warns "future macOS updates may break it".

## 9. Decisions this suggests

1. **Per-slot customization should start where the store already speaks the user's language** —
   still image, user-made dynamic HEIC, colour. No manifest games, no downloads, and the dynamic-HEIC
   route even offers users a *no-daemon* exit: export once, delete the app.
2. **Custom video per slot is real but gated on encoding**, not on Apple's cooperation: the
   `AerialManifest*` keys exist on this OS, nothing validates the manifest, and the failure mode is a
   grey desktop unless the file carries HEVC temporal sub-layers like Apple's own clips. Ship it
   behind a `testedMajorVersion`-style gate and a re-encode step, or don't ship it yet.
3. **Read PaperSaver before writing more of the store writer.** It has verify/rollback, scope
   targeting, option-values rules and extension-not-running detection; MIT, so the fork can vendor it.
4. **Keep the still-frame, ~2 MB, no-daemon identity.** That is the difference between this fork and
   Aerial 4, not a gap to close.
5. **Sun-based scheduling is the cheapest big win** after per-slot content: it fixes the "winter
   sunset at 16:30" complaint that a fixed clock can't, and the machinery (`TimeOfDay`,
   `Schedule.nextChange`) is already here.
6. **Disk policy is the shared pain point** (80 GB catalogue, macOS re-downloads on its own): keep
   consent, and consider "download just before its turn, keep the last N".
7. **Two small correctness items** the research surfaced: read `SMAppService.status` after
   `register()` and on window appear rather than once at init, and schedule exact wall-clock ticks
   from `nextChange(after:)` instead of relying only on the coarse poll.

## 10. Only an experiment can answer

1. Does a custom asset id in an overridden manifest render **on the desktop** (not merely in System
   Settings' picker), and does a user clip without temporal sub-layers really grey out? Cheapest
   test: copy `entries.json`, duplicate one Golden Gate asset with a new UUID pointing at a **hard
   link** of the 460 MB clip already on disk (zero extra bytes), set the two `AerialManifest*` keys,
   restart the agent, then delete the keys to revert.
2. Does the scheduled catalogue refresh (`scheduledUpdateDate`, here tomorrow 05:42) clobber
   overridden assets, and does `AerialManifestForceLocal` prevent it? AerialSwap says yes/no
   respectively, which is why it runs a watcher.
3. Can a slot change be made visible without `killall WallpaperAgent` — is restarting only
   `WallpaperAerialsExtension` enough — and what is the *local* rate of "agent restarted but the
   provider didn't come back" on 27.2, against PaperSaver's ~1 in 3?
4. Can a non-sandboxed, ad-hoc-signed app extension actually load on the `com.apple.wallpaper`
   extension point without the private entitlement?

## 11. Where each finding landed

The findings above are tracked as issues on this fork, so the notes and the plan stay together:

| Issue | From |
|---|---|
| [#1 Per-slot content: photo, dynamic HEIC, or colour](https://github.com/next-miracle-creator/aerial-switcher/issues/1) | §3(a), §9.1–2 |
| [#2 Sunrise/sunset scheduling](https://github.com/next-miracle-creator/aerial-switcher/issues/2) | §9.5 |
| [#3 "Show menu bar icon" toggle](https://github.com/next-miracle-creator/aerial-switcher/issues/3) | §6 |
| [#4 Read `SMAppService.status` after `register()`](https://github.com/next-miracle-creator/aerial-switcher/issues/4) | §6, §9.7 |
| [#5 Exact wall-clock ticks from `nextChange(after:)`](https://github.com/next-miracle-creator/aerial-switcher/issues/5) | §6, §9.7 |
| [#6 Reload reliability, and reading PaperSaver first](https://github.com/next-miracle-creator/aerial-switcher/issues/6) | §4, §5, §9.3, §10.3 |
| [#7 Store-schema drift preflight + tested-on range](https://github.com/next-miracle-creator/aerial-switcher/issues/7) | §1, §9.2 |

The open experiments in §10 are not issues — they are the cheapest way to turn a **[doc]**
claim into a **[verified here]** one, and #1 and #6 depend on their answers. Nothing here is
scheduled: the fork ships no roadmap, and a decision to build any of it is still ahead.

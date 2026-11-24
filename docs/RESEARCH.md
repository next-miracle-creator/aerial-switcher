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

**Correction to an earlier note in this file.** I first wrote that an overridden manifest gets
"clobbered on `scheduledUpdateDate`". That is not what the projects using the override keys report.
**[doc]** [BiAksoy's live-mode notes](https://github.com/BiAksoy/aerial-dynamic-wallpaper/blob/main/docs/live-mode.md),
last checked macOS 27.2, state the actual consequence: *while the override is on, macOS does not
refresh its list of aerials*, so footage added by a system update only shows up after the override
is disabled — and the tool deliberately refuses to touch a hand-set override. Whether the refresh
also overwrites an injected `entries.json` is still unverified here (it is §10.2). What is
documented is a workaround on the injection route rather than the override route:
**[doc]** [AerialSwap](https://github.com/mxpalm/AerialSwap) runs a LaunchAgent that watches
`entries.json` and re-applies its group, standing down if it has been wiped three times in ten
minutes — i.e. it treats being overwritten as a likely event, and self-heals instead of assuming
it cannot happen. Its notes add that a duplicate asset is ignored unless its `version` is at least
the builtin manifest's, which is a different failure from being deleted.

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
| [Aerialist](https://github.com/eddytwist/aerialist) | menu-bar rotation of only the aerials you picked, v0.5.0 (2026-11-19), MIT | "without the 80 GB": downloads each clip just before its turn, keeps only the last 1/3/5/10 shown, never deletes what you pinned or your own files; writes one video id into the store and restarts the agent. The disk policy §9.6 describes is already shipped by someone |
| [AerialSwap](https://github.com/mxpalm/AerialSwap) | custom video as a *native* aerial, v2.0, macOS 27 tested, MIT | the injection route done carefully: adds a category to `entries.json`, APFS-clones the file into `aerials/videos/<id>.mov`, sets the `SourceURL`/`LastETag`/quarantine xattrs, bumps `version` above the builtin manifest so it is not ignored, and runs a LaunchAgent that re-applies the group if the system overwrites it. Also optical-flow frame-rate conversion so the post-unlock slow-down doesn't stutter, plus Workshop/Pixabay/yt-dlp importers |
| [macos-custom-video-wallpaper-fix](https://github.com/AlexisBCD/macos-custom-video-wallpaper-fix) | the root cause of "custom aerial goes black after unlock", MIT, macOS 26.4.1 | **[doc]** the only place I found that names it: `WallpaperExtensionKit.VideoSampleReadingErrors Code-4 noTemporalInfo`, derived by reading `__swift5_fieldmd` out of the dyld shared cache. Apple's clips carry HEVC temporal sub-layers (`tscl`/`tsas` sample groups) that the unlock ramp-down reads; **no** ffmpeg (`libx265` or `hevc_videotoolbox`) and not `avconvert` produce them — only VideoToolbox with `kVTCompressionPropertyKey_BaseLayerFrameRate`, and the repo ships that encoder. Two further traps: an ~18 s loop hits `Buffer was nil` and freezes permanently unless stretched to ~5 min, and 8-bit makes the Settings thumbnails noisy |
| [wallpaper-aerials-fix](https://github.com/yuvrajangadsingh/wallpaper-aerials-fix) | one job: unsticks the aerial provider on unlock, MIT, Sonoma–Tahoe | subscribes to `com.apple.screenIsUnlocked`/`IsLocked` distributed notifications and SIGTERMs `WallpaperAerialsExtension` by process name, with `--wait-for-displays` for the external-monitor case. This is the recovery path our #6 is missing, in 1 binary |
| [Sunpaper](https://github.com/mduncs/sunpaper-app) | menu-bar app that schedules Apple aerials *by the sun*, v1.2.0 (2026-10-06), MIT | overlaps almost our whole roadmap: dawn/sunrise/solar-noon/sunset/dusk + signed offset, a draggable 24-hour track that snaps to sun events, per-display schedules, aerials *and* the user's own stills, a catalog picker with a "already on this Mac" filter, prefetch 5 min early, rollback from a snapshot with Retry, unreadable settings set aside rather than overwritten, and optional "smoothing" that hides the grey flash by covering each display with its own capture and cross-fading (needs screen-recording permission). Author: personal, unsupported, README written by a model — treat as a design reference |
| [HourGlow](https://github.com/bobbyhuang-dev/hourglow) | general trigger→wallpaper scheduler, v1.6.1, Apache-2.0, macOS 26+, zero deps, <10 MB | our #2 and #5 already built: fixed clock, sunrise/sunset ± offset, or solar-phase slices; NOAA sun times computed locally from system location, a city, typed coordinates, or *nothing* (time-zone inference, no permission); **no polling** — one `Timer(fire:)` at the next trigger plus separate wake / clock-change / timezone-change / day-rollover notifications; refuses to undo your manual pick; staged edits behind an Apply button; `SMAppService` login item; bilingual UI |
| [Phosphene](https://github.com/kageroumado/phosphene) | any video as a real wallpaper, via app extension | the long-term answer to "user-customizable" |
| [WallpaperMachine](https://github.com/MMFoundation/WallpaperMachine) | Wallpaper Engine on the Mac, v1.14.0 (2026-11-23), GPL-3.0, 1.6k stars, notarized | the maximalist alternative, and a different route: a resident Rust/Metal renderer in a desktop-level window, which *also* writes a still "poster" into the system store with a ledger so it can restore what it replaced on quit; scheduling by weekday/clock and sunrise-sunset ±180 min, Focus, per-Space, battery/thermal ceilings, Shortcuts |
| [WallGet](https://github.com/mikeswanson/WallGet) | downloader for the whole catalogue | download / resume / size hygiene |
| [rebeccacremona/wallpaper](https://github.com/rebeccacremona/wallpaper) | "Tahoe Aerial Switcher": LaunchAgent + captured plists | the launchd alternative, plus a documented gotcha: some variants store `Provider: default` with an empty config rather than an aerial id |
| [macos-wallpaper](https://github.com/sindresorhus/macos-wallpaper), [aerial-dynamic-wallpaper](https://github.com/BiAksoy/aerial-dynamic-wallpaper) | CLI `wallpaper`, `aerial-build-dynamic` | images and dynamic HEIC without touching the store |
| [JohnCoates/Aerial](https://github.com/JohnCoates/Aerial) | legacy `.saver`, last release 3.6.3 (2025-08-12) | the history, and [CustomVideos.md](https://github.com/JohnCoates/Aerial/blob/v3.6.3/Documentation/CustomVideos.md) which predates all of this |
| [Alpenglow](https://github.com/remco-space/Alpenglow), [Moodpaper](https://github.com/FuturisticXx/Moodpaper), [WallpaperScheduler](https://github.com/Kapfilm/WallpaperScheduler), [Sundial](https://github.com/Nyxnix/sundial), [WallShifter](https://github.com/tarrgor/WallShifter) | photo-library / slot-based rotators | the UX vocabulary for per-slot content (§7). WallShifter's is the one habit worth stealing: snapshot each display's `desktopImageURL` at launch by `CGDirectDisplayID` and restore in `applicationWillTerminate`. Sundial and WallpaperScheduler show the form we are trying to grow out of — a coarse repeating poll |
| [tahoe-motion-wallpaper](https://github.com/victor-gurbani/tahoe-motion-wallpaper), [EMarionih/wallpaper-switcher](https://github.com/EMarionih/wallpaper-switcher), [MacOS_Dynamic_Aerial](https://github.com/postrou/MacOS_Dynamic_Aerial) | small do-it-yourself versions of exactly this feature | all three write `Index.plist` and restart `WallpaperAgent`, so the mechanism is not ours alone to defend. The first is the most complete (discovers asset ids from `entries.json`, fills missing clips, dry-run and status, and schedules with a LaunchAgent's `StartCalendarInterval` rather than a timer); the Python one atomic-writes with a `.bak` and is idempotent; postrou's overwrites the whole store from four snapshots, which is how you also clobber the screensaver |
| [DynamicDesktop](https://github.com/commingling/DynamicDesktop) | keeps any display *moving* with native aerials, via a click-through window at `kCGDesktopWindowLevel+1` | deliberately not a store writer — reads the store only to find the current wallpaper. Useful contrast: this is what "always animating" costs (a resident player, a window per display) versus our one write per boundary |
| [wallpy](https://github.com/siphyshu/wallpy) | Go CLI + LaunchAgent, declarative `schedule.toml` | the nicest schema for sun-relative timing I found: `at = sunrise+1h30m / dusk / noon`, plus weekday rules and a documented fallback clock when there is no location or the sun never sets — and it ships test vectors for the evaluation |

**[doc]** Aerial 4's open issues are the same class of problem this fork has: #210 auto-pause
clashes with "Show on all Spaces", #207 `VTDecoderXPCService` memory pressure, #134 external
display wallpaper stops, #175 cache limit exceeded. Nobody has this nailed.

### 5.1 The second pass, and what it changed

A wider sweep (GitHub search over `aerial wallpaper macos`, `dynamic wallpaper sunrise`,
`wallpaper time of day switch`, `topic:macos-wallpaper`, plus Chinese-language coverage of this
fork's own launch) turned up work that post-dates or outruns parts of our roadmap. Stated plainly,
because it is the uncomfortable answer:

- **The feature is not rare.** Four independent projects already switch Apple's aerials by time of
  day the same way we do ([tahoe-motion-wallpaper](https://github.com/victor-gurbani/tahoe-motion-wallpaper),
  [EMarionih](https://github.com/EMarionih/wallpaper-switcher), [postrou](https://github.com/postrou/MacOS_Dynamic_Aerial),
  and, with sun events, [Sunpaper](https://github.com/mduncs/sunpaper-app)). Our mechanism earns no
  originality points; what is still ours is the conservative per-scope write plus the step-aside and
  snapshot behaviour.
- **Both roadmap features exist elsewhere, further along.** Sun-relative scheduling and precise
  wall-clock triggers are shipped by HourGlow (Apache-2.0) and Sunpaper (MIT), including the
  no-location fallback we would have had to invent. #2 and #5 are "adopt", not "design".
- **#1's hard half is solved on paper.** The encoder that produces the temporal sub-layers a custom
  clip needs exists, with the root cause named and a verifier. What is still missing is someone
  packaging it as a step inside a scheduler's flow.
- **#6's recovery path exists as a 1-binary precedent**, and PaperSaver already measured the failure
  and handles it. Our contribution there would be a number for this machine, not a new mechanism.
- **The 80 GB question is answered** by Aerialist's keep-last-N and just-in-time download, and by
  HourGlow/Sunpaper prefetching. §9.6 should read "adopt", not "consider".
- **What nobody offers** is this fork's specific shape: ~2 MB, no renderer, no window, no
  always-on playback, a schedule you set once and forget, and a store write only at a phase
  boundary. The bigger tools buy power with a resident process; that trade is the one we should
  keep refusing.

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

A second, wider sweep (see §5.1) revised the confidence of items 2, 5 and 6: the sun maths, the
trigger model, the per-slot still-image picker, the just-in-time download policy, and the
temporal-layer encoder all already exist in MIT- or Apache-2.0-licensed projects that can be read
and cited. What remains genuinely ours is the conservative write path and the restraint — the
things those projects add are exactly the resident-process complexity this fork has no reason to
take on.

## 10. Only an experiment can answer

1. Does a custom asset id in an overridden manifest render **on the desktop** (not merely in System
   Settings' picker), and does a user clip without temporal sub-layers really grey out? Cheapest
   test: copy `entries.json`, duplicate one Golden Gate asset with a new UUID pointing at a **hard
   link** of the 460 MB clip already on disk (zero extra bytes), set the two `AerialManifest*` keys,
   restart the agent, then delete the keys to revert.
2. When the catalogue refresh fires (`scheduledUpdateDate`, here tomorrow 05:42), what actually
   happens to an injected or overridden asset: is it deleted, ignored because the builtin manifest's
   `version` is higher, or left alone while `AerialManifestForceLocal` also stops the list from
   refreshing at all? BiAksoy documents the last one; AerialSwap behaves as if the first is likely.
   Nobody I found states the answer, and it decides whether injection is a feature or a treadmill.
3. Can a slot change be made visible without `killall WallpaperAgent` — is restarting only
   `WallpaperAerialsExtension` enough — and what is the *local* rate of "agent restarted but the
   provider didn't come back" on 27.2, against PaperSaver's ~1 in 3?
4. Can a non-sandboxed, ad-hoc-signed app extension actually load on the `com.apple.wallpaper`
   extension point without the private entitlement?

## 11. Where each finding landed

The findings above are tracked as issues on this fork, so the notes and the plan stay together.
The right-hand column is the honest part: what already exists elsewhere, from the second pass (§5.1).

| Issue | From | Prior art, and what that means here |
|---|---|---|
| [#1 Per-slot content: photo, dynamic HEIC, or colour](https://github.com/next-miracle-creator/aerial-switcher/issues/1) | §3(a), §9.1–2 | Sunpaper already schedules aerials *and* user stills from one picker; BiAksoy exports a sun-following HEIC that needs no app at all; [AlexisBCD's encoder](https://github.com/AlexisBCD/macos-custom-video-wallpaper-fix) removes the video blocker's mystery. Design, don't invent |
| [#2 Sunrise/sunset scheduling](https://github.com/next-miracle-creator/aerial-switcher/issues/2) | §9.5 | Shown twice — HourGlow (Apache-2.0, NOAA + time-zone fallback) and Sunpaper (MIT, sun events with a draggable track). Borrow the maths, keep our slot model |
| [#3 "Show menu bar icon" toggle](https://github.com/next-miracle-creator/aerial-switcher/issues/3) | §6 | Not solved in this niche — none of the surveyed schedulers exposes an icon toggle, and the reference binding is `isInserted: .constant(...)` in [ControlRoom](https://github.com/twostraws/ControlRoom). Ours to build |
| [#4 Read `SMAppService.status` after `register()`](https://github.com/next-miracle-creator/aerial-switcher/issues/4) | §6, §9.7 | HourGlow registers a login item the same way; nobody publishes a status-reading rule, so this stays a genuine small fix |
| [#5 Exact wall-clock ticks from `nextChange(after:)`](https://github.com/next-miracle-creator/aerial-switcher/issues/5) | §6, §9.7 | HourGlow describes precisely this design ("no wallpaper polling", four notification classes) — evidence the shape works, still ours to implement |
| [#6 Reload reliability, and reading PaperSaver first](https://github.com/next-miracle-creator/aerial-switcher/issues/6) | §4, §5, §9.3, §10.3 | [PaperSaver](https://github.com/AerialScreensaver/PaperSaver) measured the ~1-in-3 and handles it; [wallpaper-aerials-fix](https://github.com/yuvrajangadsingh/wallpaper-aerials-fix) recovers the provider on unlock; Sunpaper cross-fades over the grey flash instead of denying it. Three separate partial answers, none inside a scheduler |
| [#7 Store-schema drift preflight + tested-on range](https://github.com/next-miracle-creator/aerial-switcher/issues/7) | §1, §9.2 | Nobody surveyed states a tested-major policy, and most assume the schema. AerialSwap's watcher is the closest thing to a drift defence |

The open experiments in §10 are not issues — they are the cheapest way to turn a **[doc]**
claim into a **[verified here]** one, and #1 and #6 depend on their answers. Nothing here is
scheduled: the fork ships no roadmap, and a decision to build any of it is still ahead.

One consequence worth stating out loud. Since §5.1 found projects that already ship #1's and #2's
functionality — some with a bigger user base than this fork's 46 upstream stars — the reason to
build here is not to be first. It is to keep the small conservative core (2 MB, no resident
renderer, per-scope writes, step aside for the user's own pick, back up before touching anything)
and take the sun maths and the trigger model from people who have already debugged them.

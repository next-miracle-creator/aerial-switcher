# Fork notes

Based on upstream `1.0.3` (commit `0885d32`), branch `local`. Everything here is aimed at one
thing: leaving a machine alone. Undocumented macOS internals and multi-gigabyte downloads are the
two places where this app can surprise a person, so both now ask first.

Run the tests:

```bash
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

Build and bundle (universal, ad-hoc signed, into `dist/`):

```bash
VERSION=1.0.3-fork.2 ./scripts/bundle.sh
```

## What changed

### 1. Nothing is downloaded without saying how big it is

Upstream downloaded every missing video of a set as soon as the set was chosen — around
4 × 440 MB per Landscape set on a real machine — with no size, no free-space check and no way
to say no.

- `VideoLibrary.plan(for:)` asks the servers for each size and reads the volume's free space
  (`volumeAvailableCapacityForImportantUsage`, the figure System Settings shows).
- `Config.autoDownload` is **off**, so the app now waits. Settings › Aerials and the menu both
  show "N videos missing · 1.7 GB · 103 GB free" with a **Download** button; turning
  "Download missing videos without asking" on restores the old behaviour.
- A download that wouldn't leave 2 GB of headroom is refused, with the numbers, rather than
  filling the disk.
- Transfers are retried (3 attempts, 2 s and 10 s apart) and a **Retry Download** entry exists
  in the menu and in Settings, which was missing entirely: after a failure on wake, before the
  network came back, there was no way to restart short of re-choosing the set.
- A response that stops short of the length it promised is now a failure, not a `.mov` in
  Apple's videos folder. `isDownloaded` only ever looked at "size > 0", so a truncated file
  counted as installed and the wallpaper silently became the macOS default.

### 2. Your own wallpaper outranks the schedule

Upstream replaced whatever the desktop showed at every phase change, so picking a picture by
hand was undone at the next switch — the README's "if you've manually changed your wallpaper,
your change is preserved" only held for the turn-it-off path.

- `SyncResult.steppedAside` is new: with a backup on file and the screen showing something the
  app didn't set, `Switcher.sync` writes nothing and says why.
- `AppModel` then stands the app down — switching off, `Config.steppedAsideAt` recording the
  reason so the menu and Settings can still explain it after a relaunch. Turning
  **Switch Wallpaper** back on takes over from what is showing then, as before.

### 3. Restoring puts back the desktop, not the whole store

`restoreBackup()` copied `Index.original.plist` over `Index.plist` in one go, which also undid
any screen saver chosen since the takeover and deleted any display or space scope created
since. Desktop entries now go back one scope at a time, matched by path, and everything else
in the live store stays. `Linked` and `Desktop` are treated as the same entry under different
names, because System Settings renames it the moment the screen saver diverges.

### 4. Screen savers are only followed, not taken

An Aerial screen saver is rewritten on each switch only while it still shows what this app set
last. Before, any Aerial found in `Idle` / `ScreenSaver` was overwritten, whichever way it got
there.

### 5. Failures that used to disappear

`AppModel.sync()` reset a single shared `error` whenever the store write succeeded, which wiped
out the messages that mattered: a manifest macOS hasn't downloaded yet, a settings save that
failed, a download that failed. There is now one slot per source (`storeError`,
`manifestError`, `settingsError`, `downloadError`) and `sync` only clears its own. Errors also
render in the General tab, where Launch at Login and restore failures were invisible, and the
download error is no longer wrapped twice ("Downloading X failed: Downloading X failed").

### 6. Smaller things

- `WallpaperStore` keeps up to 10 dated copies of the store in
  `~/Library/Application Support/AerialSwitcher/StoreSnapshots/` before each change. The file it
  rewrites is Apple's, so the way back shouldn't depend on one backup slot. Two changes inside
  the same second — switching off and straight back on — get `Index-…-2.plist` rather than the
  second copy overwriting the first.
- A `killall WallpaperAgent` that misses is retried at 0.5 s and 2 s, and logged. Before, the
  exit status was dropped on the floor: the store said one wallpaper, the screen said another,
  and nothing reported it.
- `config.json` dates are ISO 8601 so the file stays legible by hand.

## Rehearsing without touching the machine

`Tools/rehearse/run.sh` seeds a throwaway home (`/tmp/asw-fakehome`) with a copy of the real
manifest and store, fake 1-byte videos and a schedule that changes minute by minute, then drives
`Switcher` through eight scenarios: missing video, first takeover, no-op repeat, the user picking
a wallpaper, switching off after that, switching back on, restoring, and the "nothing was
downloaded" accounting. It checks results, file hashes and the directory contents, and exits
nonzero on any mismatch. The reload closure is stubbed, so the real `WallpaperAgent` is never
signalled and the screen never changes.

Note that `FileManager.default.homeDirectoryForCurrentUser` ignores `$HOME`, so pointing the
installed app at a fake home is not a thing you can do with an environment variable — this is why
the rehearsal is a separate binary over `AerialCore` sources rather than a launch of the app.

## Notes for taking any of this upstream

The four numbered behaviour changes are the ones worth a PR each, in that order: 2 and 3 are
bug fixes against issues already filed (#1, and PR #2 covers similar ground but replaces the
whole file on restore and stays silent about the manual-change case), 1 is a policy change the
maintainer may or may not want, 5 matches PR #2 item 2. Items in 6 are safe to fold into any of
them. Nothing here touches the store format itself, so all of it is testable through the
fixtures in `Tests/AerialCoreTests`.

## Rolling back

The app only ever writes inside the user's own Library. To be undoable by hand:

```bash
# stop the app and put the store back from the app's own backup
killall AerialSwitcher
W="$HOME/Library/Application Support/com.apple.wallpaper"
cp "$HOME/Library/Application Support/AerialSwitcher/Index.original.plist" "$W/Store/Index.plist"
killall WallpaperAgent

# or from any of the dated snapshots
ls "$HOME/Library/Application Support/AerialSwitcher/StoreSnapshots"

# and a copy taken before this fork was installed at all
ls "$HOME/Library/Application Support/AerialSwitcherFork"
```

Aerial videos downloaded by the app are `<assetID>.mov` in `~/Library/Application Support/com.apple.wallpaper/aerials/videos`;
macOS re-downloads any it wants, so deleting them is safe.

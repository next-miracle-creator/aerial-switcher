import Foundation
import Testing
@testable import AerialCore

@Suite struct ManifestTests {
    @Test func findsOnlyDayCycleSets() {
        #expect(Fixtures.sets.map(\.name) == ["Golden Gate", "Tahoe"])
    }

    @Test func sortsAerialsByTimeOfDay() {
        #expect(Fixtures.tahoe.aerials.map(\.phase) == [.morning, .day, .evening, .night])
        #expect(Fixtures.sets[0].aerials.map(\.phase) == [.day, .sunset, .night])
    }

    @Test func usesNamesFromTheStringsTable() throws {
        let chinese = Strings(Fixtures.strings.tables, preferredLanguages: ["zh-Hans-CN"])
        let goldenGate = try #require(Manifest.sets(from: Fixtures.manifest, strings: chinese).first)
        #expect(goldenGate.name == "金门海峡")
        #expect(goldenGate.aerials.map(\.label) == ["金门海峡白天", "Golden Gate Sunset", "Golden Gate Night"])
    }

    @Test func defaultScheduleStartsTheFirstPhaseAtSix() {
        let goldenGate = Fixtures.sets[0].defaultSchedule
        #expect(goldenGate.times == [.day: TimeOfDay(hour: 6), .sunset: TimeOfDay(hour: 17), .night: TimeOfDay(hour: 21)])
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: Paths.live.manifest.path)))
    func readsTheRealManifest() throws {
        let ids = try Manifest.load(from: Paths.live.manifest).map(\.id)
        // Golden Gate, Tahoe, Sequoia; Sonoma is not a day cycle.
        #expect(ids.contains { $0.hasPrefix("67512508") })
        #expect(ids.contains { $0.hasPrefix("0DC99DD8") })
        #expect(ids.contains { $0.hasPrefix("78D1B993") })
        #expect(!ids.contains { $0.hasPrefix("3CC63110") })
    }
}

@Suite struct ScheduleTests {
    let schedule = Fixtures.tahoe.defaultSchedule  // 06:00 morning, 12:00 day, 18:00 evening, 21:00 night
    let calendar = Fixtures.calendar

    @Test(arguments: [
        (5, 59, DayPhase.night), (6, 0, .morning), (11, 59, .morning), (12, 0, .day),
        (18, 30, .evening), (21, 0, .night), (23, 59, .night), (0, 0, .night),
    ])
    func phaseWrapsAroundMidnight(hour: Int, minute: Int, expected: DayPhase) {
        #expect(schedule.phase(at: Fixtures.date(hour, minute), calendar: calendar) == expected)
    }

    @Test func nextChangeIsLaterToday() throws {
        let next = try #require(schedule.nextChange(after: Fixtures.date(13), calendar: calendar))
        #expect(next.date == Fixtures.date(18))
        #expect(next.phase == .evening)
    }

    @Test func nextChangeRollsOverToTomorrow() throws {
        let next = try #require(schedule.nextChange(after: Fixtures.date(22), calendar: calendar))
        #expect(next.date == Fixtures.date(6).addingTimeInterval(86_400))
        #expect(next.phase == .morning)
    }

    @Test func tiedTimesShowTheLaterPhase() {
        let tied = Schedule([.morning: TimeOfDay(hour: 6), .day: TimeOfDay(hour: 6), .night: TimeOfDay(hour: 20)])
        #expect(tied.phase(at: Fixtures.date(7), calendar: calendar) == .day)
        #expect(tied.nextChange(after: Fixtures.date(21), calendar: calendar)?.phase == .day)
    }

    @Test func emptyScheduleHasNoPhase() {
        #expect(Schedule([:]).phase(at: Fixtures.date(12), calendar: calendar) == nil)
    }
}

@Suite struct WallpaperStoreTests {
    @Test func readsState() throws {
        #expect(try WallpaperStore(paths: Fixtures.paths(store: Fixtures.store(Fixtures.aerialChoice))).state() == .aerial(assetID: "OLD"))
        #expect(try WallpaperStore(paths: Fixtures.paths(store: Fixtures.store(Fixtures.defaultChoice))).state() == .systemDefault)
        #expect(try WallpaperStore(paths: Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))).state() == .other)
    }

    @Test func setsAnyWallpaperToTheAerial() throws {
        for choice in [Fixtures.aerialChoice, Fixtures.imageChoice, Fixtures.defaultChoice] {
            let store = WallpaperStore(paths: try Fixtures.paths(store: Fixtures.store(choice)))
            #expect(try store.setAerial("NEW") == 2)
            #expect(try store.state() == .aerial(assetID: "NEW"))
        }
    }

    @Test func keepsTheOriginalForRestore() throws {
        let store = WallpaperStore(paths: try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice)))
        try store.setAerial("A")
        try store.setAerial("B")
        try store.restoreBackup()
        #expect(try store.state() == .other)
        #expect(!store.hasBackup)
    }

    @Test func backsUpAWallpaperPickedSince() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let store = WallpaperStore(paths: paths)
        try store.setAerial("A")
        // The user picks the system default by hand; the next switch keeps that instead.
        try Fixtures.write(Fixtures.store(Fixtures.defaultChoice), to: paths)
        try store.setAerial("B")
        try store.restoreBackup()
        #expect(try store.state() == .systemDefault)
    }

    @Test func leavesAWallpaperPickedSinceOnRestore() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let store = WallpaperStore(paths: paths)
        try store.setAerial("A")
        try Fixtures.write(Fixtures.store(Fixtures.defaultChoice), to: paths)
        #expect(try store.restoreBackup() == false)
        #expect(try store.state() == .systemDefault)
        #expect(!store.hasBackup)
    }

    @Test func restoresABackupFromVersion1_0_0() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let store = WallpaperStore(paths: paths)
        try store.setAerial("A")
        try FileManager.default.removeItem(at: paths.lastSet)
        #expect(try store.restoreBackup())
        #expect(try store.state() == .other)
    }

    @Test func leavesAnImageScreenSaverAlone() throws {
        var scope = Fixtures.store(Fixtures.imageChoice)["AllSpacesAndDisplays"] as! [String: Any]
        scope["Idle"] = ["Content": ["Choices": [Fixtures.imageChoice]]]
        let paths = try Fixtures.paths(store: ["AllSpacesAndDisplays": scope])
        #expect(try WallpaperStore(paths: paths).setAerial("NEW") == 1)
        let saved = NSDictionary(contentsOf: paths.store)!
        let idle = (saved.value(forKeyPath: "AllSpacesAndDisplays.Idle.Content.Choices") as! [NSDictionary])[0]
        #expect(idle["Provider"] as? String == "com.apple.wallpaper.choice.image")
    }

    @Test func missingStoreThrows() {
        let paths = Paths(home: URL(fileURLWithPath: "/nonexistent"))
        #expect(throws: AerialError.self) { try WallpaperStore(paths: paths).state() }
    }

    // MARK: - Restoring without undoing everything else

    /// The screen saver is the user's own business: putting the desktop back must not take
    /// away an Aerial they chose for it in the meantime.
    @Test func restoreKeepsAScreenSaverChosenSinceTakeover() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let store = WallpaperStore(paths: paths)
        try store.setAerial("A")
        // System Settings splits Linked into Desktop and Idle; the user gives Idle their own Aerial.
        try Fixtures.write(Fixtures.store(desktop: Fixtures.aerial("A"), screenSaver: Fixtures.aerial("OTHER")), to: paths)
        #expect(try store.restoreBackup())
        let saved = try #require(NSDictionary(contentsOf: paths.store))
        let desktop = try #require(saved.value(forKeyPath: "AllSpacesAndDisplays.Desktop.Content.Choices") as? [NSDictionary])
        let idle = try #require(saved.value(forKeyPath: "AllSpacesAndDisplays.Idle.Content.Choices") as? [NSDictionary])
        #expect(desktop[0]["Provider"] as? String == "com.apple.wallpaper.choice.image")
        #expect(WallpaperStore.assetID(of: idle[0]) == "OTHER")
        #expect(try store.state() == .other)
    }

    /// A display added after the takeover is newer than the backup, and copying the whole
    /// file back would erase it along with whatever it shows.
    @Test func restoreKeepsADisplayAddedSinceTakeover() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let store = WallpaperStore(paths: paths)
        try store.setAerial("A")
        // macOS gives a display plugged in later the Aerial that is showing; the app's last
        // change is still what is on screen, so a restore is owed — but only for the desktop.
        var after = Fixtures.store(desktop: Fixtures.aerial("A"))
        after["Displays"] = ["D2": Fixtures.scope(desktop: Fixtures.aerial("A"))]
        try Fixtures.write(after, to: paths)
        #expect(try store.restoreBackup())
        let saved = try #require(NSDictionary(contentsOf: paths.store))
        let added = try #require(saved.value(forKeyPath: "Displays.D2.Desktop.Content.Choices") as? [NSDictionary])
        #expect(WallpaperStore.assetID(of: added[0]) == "A")
        let back = try #require(saved.value(forKeyPath: "AllSpacesAndDisplays.Desktop.Content.Choices") as? [NSDictionary])
        #expect(back[0]["Provider"] as? String == "com.apple.wallpaper.choice.image")
    }

    /// The file being rewritten is Apple's, so a dated copy of it is kept beforehand.
    @Test func snapshotsTheStoreBeforeChangingIt() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let store = WallpaperStore(paths: paths)
        try store.setAerial("A")
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.storeSnapshots.path).sorted()
        #expect(names.count == 1)
        let copy = try #require(NSDictionary(contentsOf: paths.storeSnapshots.appendingPathComponent(names[0])))
        let choice = try #require((copy.value(forKeyPath: "AllSpacesAndDisplays.Linked.Content.Choices") as? [NSDictionary])?.first)
        #expect(choice["Provider"] as? String == "com.apple.wallpaper.choice.image")
    }

    /// Two changes in the same second — off and straight back on — must not lose the copy the
    /// first one kept, so a taken name gets a number on the end.
    @Test func keepsBothSnapshotsTakenInTheSameSecond() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let store = WallpaperStore(paths: paths)
        try FileManager.default.createDirectory(at: paths.storeSnapshots, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let taken = paths.storeSnapshots.appendingPathComponent("Index-\(formatter.string(from: Date())).plist")
        try Data("earlier".utf8).write(to: taken)
        try store.setAerial("A")
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.storeSnapshots.path)
        #expect(names.count == 2)
        #expect(String(decoding: try Data(contentsOf: taken), as: UTF8.self) == "earlier")
    }

    /// Snapshots are a safety net, not an archive that grows forever.
    @Test func keepsOnlyTheNewestSnapshots() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let store = WallpaperStore(paths: paths)
        try FileManager.default.createDirectory(at: paths.storeSnapshots, withIntermediateDirectories: true)
        for index in 0..<12 {
            try Data("x".utf8).write(to: paths.storeSnapshots.appendingPathComponent(String(format: "Index-20260101T0000%02d.plist", index)))
        }
        try store.setAerial("A")
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.storeSnapshots.path)
        #expect(names.count == WallpaperStore.snapshotLimit)
        #expect(names.contains("Index-20260101T000011.plist"))
        #expect(!names.contains("Index-20260101T000000.plist"))
    }

    // MARK: - Screen savers

    /// An Aerial the user chose for the screen saver is theirs to keep: the schedule follows
    /// only the ones it set itself.
    @Test func leavesAForeignAerialScreenSaverAlone() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(desktop: Fixtures.imageChoice, screenSaver: Fixtures.aerial("OTHER")))
        let store = WallpaperStore(paths: paths)
        try store.setAerial("A")
        let saved = try #require(NSDictionary(contentsOf: paths.store))
        let idle = try #require(saved.value(forKeyPath: "AllSpacesAndDisplays.Idle.Content.Choices") as? [NSDictionary])
        #expect(WallpaperStore.assetID(of: idle[0]) == "OTHER")
        #expect(try store.state() == .aerial(assetID: "A"))
    }

    /// An Aerial screen saver that has been following the app keeps following it.
    @Test func keepsItsOwnAerialScreenSaverInStep() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(desktop: Fixtures.aerial("A"), screenSaver: Fixtures.aerial("A")))
        try Fixtures.mark(lastSet: "A", on: paths)
        let store = WallpaperStore(paths: paths)
        try store.setAerial("B")
        let saved = try #require(NSDictionary(contentsOf: paths.store))
        let idle = try #require(saved.value(forKeyPath: "AllSpacesAndDisplays.Idle.Content.Choices") as? [NSDictionary])
        #expect(WallpaperStore.assetID(of: idle[0]) == "B")
    }
}

@Suite struct SwitcherTests {
    let set = Fixtures.tahoe
    let config = Config(setID: "tahoe")

    func switcher(_ paths: Paths) -> Switcher {
        Switcher(paths: paths, reload: {})
    }

    @Test func switchesToTheCurrentPhase() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        try Fixtures.download(["TA-EVENING"], into: paths)
        let result = try switcher(paths).sync(set: set, config: config, at: Fixtures.date(19), calendar: Fixtures.calendar)
        #expect(result == .switched(to: set.aerial(for: .evening)!))
        #expect(try WallpaperStore(paths: paths).state() == .aerial(assetID: "TA-EVENING"))
    }

    @Test func doesNothingWhenAlreadyShowing() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.choice(provider: "com.apple.wallpaper.choice.aerials", config: ["assetID": "TA-DAY"])))
        try Fixtures.download(["TA-DAY"], into: paths)
        let result = try switcher(paths).sync(set: set, config: config, at: Fixtures.date(13), calendar: Fixtures.calendar)
        #expect(result == .alreadyShowing(set.aerial(for: .day)!))
        #expect(!WallpaperStore(paths: paths).hasBackup)
    }

    /// Each display set on its own in System Settings: no all-displays scope, and the
    /// system default scope can name the target while the display shows something else.
    @Test func switchesADisplaySetOnItsOwn() throws {
        let aerial = { (id: String) in Fixtures.choice(provider: "com.apple.wallpaper.choice.aerials", config: ["assetID": id]) }
        let display: [String: Any] = [
            "Desktop": ["Content": ["Choices": [aerial("TA-DAY")], "Shuffle": "$null"]],
            "Idle": ["Content": ["Choices": [aerial("TA-DAY")], "Shuffle": "$null"]],
            "Type": "individual",
        ]
        var store = Fixtures.store(aerial("TA-EVENING"))
        store["AllSpacesAndDisplays"] = "$null"
        store["Displays"] = ["D1": display]
        let paths = try Fixtures.paths(store: store)
        try Fixtures.download(["TA-EVENING"], into: paths)

        let result = try switcher(paths).sync(set: set, config: config, at: Fixtures.date(19), calendar: Fixtures.calendar)
        #expect(result == .switched(to: set.aerial(for: .evening)!))
        #expect(try WallpaperStore(paths: paths).state() == .aerial(assetID: "TA-EVENING"))
    }

    /// "Show on all Spaces" off: each space keeps its own wallpaper, per display, a level down.
    @Test func switchesEachSpace() throws {
        let linked = { (choice: [String: Any]) -> [String: Any] in
            ["Linked": ["Content": ["Choices": [choice], "Shuffle": "$null"]], "Type": "linked"]
        }
        let store: [String: Any] = [
            "AllSpacesAndDisplays": "$null",
            "SystemDefault": linked(Fixtures.defaultChoice),
            "Displays": ["D1": linked(Fixtures.imageChoice)],
            "Spaces": ["S1": ["Default": linked(Fixtures.imageChoice), "Displays": ["D1": linked(Fixtures.defaultChoice)]]],
        ]
        let paths = try Fixtures.paths(store: store)
        try Fixtures.download(["TA-EVENING"], into: paths)

        #expect(try switcher(paths).sync(set: set, config: config, at: Fixtures.date(19), calendar: Fixtures.calendar) == .switched(to: set.aerial(for: .evening)!))
        let saved = NSDictionary(contentsOf: paths.store)!
        let choice = (saved.value(forKeyPath: "Spaces.S1.Displays.D1.Linked.Content.Choices") as! [NSDictionary])[0]
        #expect(choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials")
        #expect(try WallpaperStore(paths: paths).state() == .aerial(assetID: "TA-EVENING"))
    }

    @Test func waitsForTheDownload() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let result = try switcher(paths).sync(set: set, config: config, at: Fixtures.date(13), calendar: Fixtures.calendar)
        #expect(result == .notDownloaded(set.aerial(for: .day)!))
        #expect(try WallpaperStore(paths: paths).state() == .other)
    }

    @Test func respectsOffPauseAndCustomTimes() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        try Fixtures.download(["TA-NIGHT"], into: paths)
        var config = config
        config.enabled = false
        #expect(try switcher(paths).sync(set: set, config: config, at: Fixtures.date(13), calendar: Fixtures.calendar) == .disabled)
        config.enabled = true
        config.paused = true
        #expect(try switcher(paths).sync(set: set, config: config, at: Fixtures.date(13), calendar: Fixtures.calendar) == .paused)
        config.paused = false
        config.schedules["tahoe"] = Schedule([.morning: TimeOfDay(hour: 6), .night: TimeOfDay(hour: 12, minute: 30)])
        #expect(try switcher(paths).sync(set: set, config: config, at: Fixtures.date(13), calendar: Fixtures.calendar) == .switched(to: set.aerial(for: .night)!))
    }

    /// A wallpaper the user picked themselves outranks the schedule: nothing is written, and
    /// the reason comes back for the menu to show.
    @Test func stepsAsideForAWallpaperTheUserPicked() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        try Fixtures.download(["TA-DAY", "TA-EVENING"], into: paths)
        let switcher = switcher(paths)
        #expect(try switcher.sync(set: set, config: config, at: Fixtures.date(13), calendar: Fixtures.calendar) == .switched(to: set.aerial(for: .day)!))
        // The user picks a picture in System Settings; the next phase must not overwrite it.
        try Fixtures.write(Fixtures.store(Fixtures.imageChoice), to: paths)
        #expect(try switcher.sync(set: set, config: config, at: Fixtures.date(19), calendar: Fixtures.calendar) == .steppedAside(set.aerial(for: .evening)!))
        #expect(try WallpaperStore(paths: paths).state() == .other)
    }

    /// Taking over is what it always was: the first change asks no leave of the store.
    @Test func takesOverWhenItHasNeverTouchedTheStore() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        try Fixtures.download(["TA-DAY"], into: paths)
        let store = WallpaperStore(paths: paths)
        #expect(!store.hasBackup)
        #expect(try switcher(paths).sync(set: set, config: config, at: Fixtures.date(13), calendar: Fixtures.calendar) == .switched(to: set.aerial(for: .day)!))
    }

    /// While the app's own Aerial is what's showing, a later phase is simply the next switch.
    @Test func keepsSwitchingItsOwnAerials() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        try Fixtures.download(["TA-DAY", "TA-EVENING"], into: paths)
        let switcher = switcher(paths)
        try switcher.sync(set: set, config: config, at: Fixtures.date(13), calendar: Fixtures.calendar)
        #expect(try switcher.sync(set: set, config: config, at: Fixtures.date(19), calendar: Fixtures.calendar) == .switched(to: set.aerial(for: .evening)!))
    }
}

@Suite struct DownloadPlanTests {
    private func plan(total: Int64, free: Int64?) -> DownloadPlan {
        DownloadPlan(aerials: Fixtures.tahoe.aerials.filter { $0.id == "TA-DAY" },
                     totalBytes: total, freeBytes: free, sizesKnown: true)
    }

    @Test(arguments: [
        // Fits, doesn't, and only fits once the room to spare is counted as well.
        (Int64(1_000_000_000), Int64(103_000_000_000), true),
        (Int64(200_000_000_000), Int64(103_000_000_000), false),
        (DownloadPlan.headroom, DownloadPlan.headroom, false),
        (DownloadPlan.headroom, DownloadPlan.headroom * 2, true),
    ])
    func leavesRoomForTheRestOfTheMachine(total: Int64, free: Int64, fits: Bool) {
        #expect(plan(total: total, free: free).fitsOnDisk == fits)
    }

    /// A volume that won't answer is no reason to refuse a download the user asked for.
    @Test func unknownSpaceAloneDoesNotBlock() {
        #expect(plan(total: 500_000_000_000, free: nil).fitsOnDisk)
    }

    @Test func nothingMissingIsAnEmptyPlan() {
        let empty = DownloadPlan(aerials: [], totalBytes: 0, freeBytes: 1, sizesKnown: false)
        #expect(empty.isEmpty)
        #expect(!empty.sizesKnown)
    }

    /// The videos folder usually isn't there before the first download, so the free space
    /// comes from the closest part of the path that is.
    @Test func readsFreeSpaceUpThePath() throws {
        let missing = URL(fileURLWithPath: "/tmp/aerial-switcher-absent/videos")
        let free = try #require(VideoLibrary.freeBytes(near: missing))
        #expect(free > 0)
    }
}

@Suite struct ConfigTests {
    @Test func roundTripsAsReadableJSON() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        let config = Config(setID: "tahoe", schedules: ["tahoe": Schedule([.morning: TimeOfDay(hour: 6, minute: 30)])])
        try config.save(to: url)
        #expect(Config.load(from: url) == config)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"morning\" : \"06:30\""))
    }

    @Test func readsSettingsFromVersion1_0_0() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        try Data(#"{"paused": true, "schedules": {}, "setID": "tahoe"}"#.utf8).write(to: url)
        #expect(Config.load(from: url) == Config(setID: "tahoe", enabled: true, paused: true))
    }

    @Test func missingFileGivesDefaults() {
        #expect(Config.load(from: URL(fileURLWithPath: "/nonexistent.json")) == Config())
    }

    /// Gigabytes are never downloaded on the app's own say-so, and a config from before the
    /// offer keeps asking. The reason it stood aside outlives a relaunch, and stays readable.
    @Test func downloadsAreAskedForUnlessSaidOtherwise() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        #expect(!Config().autoDownload)
        #expect(!Config.load(from: url).autoDownload)
        let config = Config(setID: "tahoe", autoDownload: true, steppedAsideAt: Fixtures.date(7, 30))
        try config.save(to: url)
        #expect(Config.load(from: url) == config)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("2026-11-01T23:30:00Z"))
    }
}

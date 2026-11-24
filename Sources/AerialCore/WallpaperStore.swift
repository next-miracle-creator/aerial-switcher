import Foundation
import os

public enum WallpaperState: Hashable, Sendable {
    case aerial(assetID: String)
    /// The macOS default wallpaper. It is itself an Aerial, but stored without an asset ID.
    case systemDefault
    /// A picture, color, or anything else.
    case other
}

/// Reads and rewrites macOS's wallpaper store (Index.plist).
///
/// The store holds scopes (all displays, per display, per space), each with entries
/// (Linked, Desktop, Idle, ScreenSaver) whose Choices name a provider and its configuration.
/// An Aerial choice is provider `com.apple.wallpaper.choice.aerials` with `{assetID}` as config.
public struct WallpaperStore: Sendable {
    static let aerialProvider = "com.apple.wallpaper.choice.aerials"
    static let desktopEntries = ["Linked", "Desktop"]
    static let screenSaverEntries = ["Idle", "ScreenSaver"]
    /// How many dated store copies to keep before the oldest goes.
    static let snapshotLimit = 10

    let paths: Paths

    public init(paths: Paths = .live) {
        self.paths = paths
    }

    /// What every desktop shows. Scopes that disagree, as when one display was set on its
    /// own in System Settings, count as `.other`: the system default scope alone can name
    /// an Aerial that no display shows.
    public func state() throws -> WallpaperState {
        let states = Set(desktopChoices(in: try load()).map { choice -> WallpaperState in
            if let assetID = Self.assetID(of: choice) { return .aerial(assetID: assetID) }
            return choice["Provider"] as? String == "default" ? .systemDefault : .other
        })
        return states.count == 1 ? states.first! : .other
    }

    /// Shows `assetID` on every display and space. Desktop entries that aren't an Aerial are
    /// replaced; screen saver entries follow only while they still show what this app set
    /// last, so an Aerial the user chose for the screen saver is left to them.
    /// The user's own wallpaper is kept so it can be restored: the store as it was before
    /// the first change, refreshed whenever the user has picked something else since.
    @discardableResult
    public func setAerial(_ assetID: String, now: Date = Date()) throws -> Int {
        let store = try load()
        let ourLast = ownLastSet()
        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        var count = 0

        for scope in scopes(in: store) {
            for key in Self.desktopEntries + Self.screenSaverEntries {
                guard
                    let entry = scope[key] as? NSMutableDictionary,
                    let content = entry["Content"] as? NSMutableDictionary,
                    let choices = content["Choices"] as? NSMutableArray
                else { continue }

                var changed = false
                for case let choice as NSMutableDictionary in choices where choice["Provider"] as? String == Self.aerialProvider {
                    if Self.screenSaverEntries.contains(key), Self.assetID(of: choice) != ourLast { continue }
                    choice["Configuration"] = try Self.configuration(of: choice, settingAssetID: assetID)
                    changed = true
                }
                if !changed && Self.desktopEntries.contains(key) {
                    content["Choices"] = NSMutableArray(object: NSMutableDictionary(dictionary: [
                        "Provider": Self.aerialProvider,
                        "Configuration": config,
                        "Files": NSMutableArray(),
                    ]))
                    content["Shuffle"] = "$null"
                    changed = true
                }
                if changed {
                    entry["LastSet"] = now
                    entry["LastUse"] = now
                    count += 1
                }
            }
        }

        guard count > 0 else { throw AerialError("No wallpaper entries were found in the wallpaper store.") }
        try backUpUsersWallpaper()
        keepSnapshot()
        try write(store)
        try Data(assetID.utf8).write(to: paths.lastSet, options: .atomic)
        return count
    }

    public var hasBackup: Bool { FileManager.default.fileExists(atPath: paths.storeBackup.path) }

    /// Whether the wallpaper showing is the one this app last set, not one the user picked since.
    public var isShowingOwnChange: Bool {
        guard let data = try? Data(contentsOf: paths.lastSet) else {
            // 1.0.0 kept a backup but didn't record its change; any Aerial counts as its own.
            guard hasBackup, case .aerial = try? state() else { return false }
            return true
        }
        return (try? state()) == .aerial(assetID: String(decoding: data, as: UTF8.self))
    }

    /// Puts back the user's wallpaper, unless they have already picked another one since
    /// this app's last change. Returns whether the store was changed.
    ///
    /// Only the desktop entries go back, one scope at a time: the store as it is now keeps
    /// its screen saver entries and any display or space the user has added since the backup,
    /// which copying the whole file over would silently undo.
    @discardableResult
    public func restoreBackup() throws -> Bool {
        guard hasBackup, isShowingOwnChange else {
            try? FileManager.default.removeItem(at: paths.storeBackup)
            try? FileManager.default.removeItem(at: paths.lastSet)
            return false
        }
        guard let backupData = try? Data(contentsOf: paths.storeBackup) else {
            throw AerialError("Couldn't read the wallpaper store.")
        }
        // Merge when both sides still parse and a desktop entry has a place to go back to;
        // otherwise the whole backup is the only thing that can put the wallpaper right, as
        // when the live store itself is unreadable.
        var merged = false
        if let live = try? load(), let backup = Self.dictionary(from: backupData) {
            merged = putBackDesktopEntries(from: backup, into: live) && (try? write(live)) != nil
        }
        if !merged { try backupData.write(to: paths.store, options: .atomic) }
        try? FileManager.default.removeItem(at: paths.storeBackup)
        try? FileManager.default.removeItem(at: paths.lastSet)
        return true
    }

    /// WallpaperAgent only picks up store changes when it restarts. A `killall` that misses
    /// (the agent is quitting, or being relaunched by the system) is retried a few times,
    /// because a wallpaper that silently stays old is the one failure the user can't see.
    @discardableResult
    public static func reloadAgent() -> Bool {
        if killAgent() { return true }
        for delay in [0.5, 2.0] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { _ = killAgent() }
        }
        return false
    }

    private static func killAgent() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                logger.error("killall WallpaperAgent exited with \(process.terminationStatus)")
                return false
            }
            return true
        } catch {
            logger.error("Couldn't restart WallpaperAgent: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static let logger = Logger(subsystem: "io.github.ynnju.aerial-switcher", category: "WallpaperStore")

    // MARK: - Helpers

    private func load() throws -> NSMutableDictionary {
        guard let dictionary = Self.dictionary(from: (try? Data(contentsOf: paths.store)) ?? Data()) else {
            throw AerialError("Couldn't read the wallpaper store.")
        }
        return dictionary
    }

    private static func dictionary(from data: Data) -> NSMutableDictionary? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil),
            let store = plist as? NSMutableDictionary
        else { return nil }
        return store
    }

    private func write(_ store: NSDictionary) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        try data.write(to: paths.store, options: .atomic)
    }

    private func backUpUsersWallpaper() throws {
        guard !(hasBackup && isShowingOwnChange) else { return }
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try Data(contentsOf: paths.store).write(to: paths.storeBackup, options: .atomic)
    }

    /// Dates sort as strings, so pruning is a matter of dropping what is no longer newest.
    private func keepSnapshot() {
        let fileManager = FileManager.default
        guard (try? fileManager.createDirectory(at: paths.storeSnapshots, withIntermediateDirectories: true)) != nil,
              let data = try? Data(contentsOf: paths.store)
        else { return }
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let stamp = String(format: "%04d%02d%02dT%02d%02d%02d",
                           parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        var name = "Index-\(stamp).plist"
        // Changing twice within one second — off and straight back on — must not throw away
        // the copy the first change kept, so a taken name gets a number on the end.
        var taken = 2
        while fileManager.fileExists(atPath: paths.storeSnapshots.appendingPathComponent(name).path), taken < 1000 {
            name = "Index-\(stamp)-\(taken).plist"
            taken += 1
        }
        guard (try? data.write(to: paths.storeSnapshots.appendingPathComponent(name))) != nil else { return }
        let kept = (try? fileManager.contentsOfDirectory(atPath: paths.storeSnapshots.path))?
            .filter { $0.hasPrefix("Index-") && $0.hasSuffix(".plist") }.sorted() ?? []
        for old in kept.dropLast(Self.snapshotLimit) {
            try? fileManager.removeItem(at: paths.storeSnapshots.appendingPathComponent(old))
        }
    }

    /// The Aerial this app last set, as recorded on disk. Nil before the first change, so a
    /// screen saver the user picked for themselves is never treated as one of ours.
    private func ownLastSet() -> String? {
        guard let data = try? Data(contentsOf: paths.lastSet) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Replaces each matching scope's desktop entries with the backup's. Scopes the live
    /// store has gained since are left alone, and so is everything outside desktop entries —
    /// which is how a screen saver picked after the takeover, or in a scope created after it,
    /// survives. System Settings renames `Linked` to `Desktop` the moment the screen saver
    /// diverges, so the entry the backup names and the one the live store has need not match.
    private func putBackDesktopEntries(from backup: NSDictionary, into live: NSMutableDictionary) -> Bool {
        let before = Dictionary(uniqueKeysWithValues: scopedEntries(in: backup, under: []).map { ($0.path, $0.scope) })
        var changed = false
        for (path, scope) in scopedEntries(in: live, under: []) {
            guard let earlier = firstDesktopEntry(in: before[path]) else { continue }
            for key in Self.desktopEntries where scope[key] != nil {
                scope[key] = earlier
                changed = true
            }
        }
        return changed
    }

    /// The backup's desktop entry for a scope, whatever key it was filed under.
    private func firstDesktopEntry(in scope: NSMutableDictionary?) -> NSMutableDictionary? {
        guard let scope else { return nil }
        for key in Self.desktopEntries {
            if let entry = scope[key] as? NSMutableDictionary { return entry }
        }
        return nil
    }

    /// Every dictionary holding entries, with the path it is found at, so a scope in the
    /// backup can be matched to the same scope now.
    private func scopedEntries(in store: NSDictionary, under path: [String]) -> [(path: [String], scope: NSMutableDictionary)] {
        guard let dictionary = store as? NSMutableDictionary else { return [] }
        let entryKeys = Self.desktopEntries + Self.screenSaverEntries
        if entryKeys.contains(where: { dictionary[$0] != nil }) { return [(path, dictionary)] }
        return dictionary.compactMap { key, value -> [(path: [String], scope: NSMutableDictionary)] in
            guard let nested = value as? NSDictionary else { return [] }
            return scopedEntries(in: nested, under: path + [(key as? String) ?? ""])
        }.flatMap { $0 }
    }

    /// Every dictionary holding entries. Per-display and per-space scopes nest: with
    /// "Show on all Spaces" off, a space keeps its own `Default` and `Displays.<display>`.
    private func scopes(in store: NSDictionary) -> [NSMutableDictionary] {
        let entryKeys = Self.desktopEntries + Self.screenSaverEntries
        func collect(_ value: Any) -> [NSMutableDictionary] {
            guard let dictionary = value as? NSMutableDictionary else { return [] }
            if entryKeys.contains(where: { dictionary[$0] != nil }) { return [dictionary] }
            return dictionary.allValues.flatMap(collect)
        }
        return ["AllSpacesAndDisplays", "SystemDefault", "Displays", "Spaces"].flatMap { store[$0].map(collect) ?? [] }
    }

    private func desktopChoices(in store: NSDictionary) -> [NSDictionary] {
        scopes(in: store).flatMap { scope in
            Self.desktopEntries.flatMap { key -> [NSDictionary] in
                let content = (scope[key] as? NSDictionary)?["Content"] as? NSDictionary
                return (content?["Choices"] as? [NSDictionary]) ?? []
            }
        }
    }

    static func assetID(of choice: NSDictionary) -> String? {
        guard
            choice["Provider"] as? String == aerialProvider,
            let data = choice["Configuration"] as? Data,
            let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
        else { return nil }
        return config["assetID"] as? String
    }

    /// Keeps any other keys an existing Aerial configuration has.
    private static func configuration(of choice: NSDictionary, settingAssetID assetID: String) throws -> Data {
        let existing = (choice["Configuration"] as? Data).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary
        }
        let config = NSMutableDictionary(dictionary: existing ?? [:])
        config["assetID"] = assetID
        return try PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
    }
}

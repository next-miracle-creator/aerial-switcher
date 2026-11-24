import CryptoKit
import Foundation

// End-to-end rehearsal against a throwaway home folder, so the real wallpaper store is
// never touched. The reload closure is stubbed, so WallpaperAgent is never killed.

let fakeHome = URL(fileURLWithPath: "/tmp/asw-fakehome")
let paths = Paths(home: fakeHome)
let storeURL = paths.store

// MARK: - Small harness plumbing

var failures: [String] = []

func check<T: Equatable>(_ what: String, _ got: T, _ want: T) {
    let g = String(describing: got), w = String(describing: want)
    if got == want {
        print("  ok   \(what): \(g)")
    } else {
        print("  FAIL \(what): got \(g), want \(w)")
        failures.append(what)
    }
}

func note(_ text: String) { print("  ·    \(text)") }

func sha(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "missing" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func date(hour: Int, minute: Int) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: minute, second: 30, of: Date())!
}

func movCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: paths.videos.path).filter { $0.hasSuffix(".mov") }.count) ?? -1
}

func snapshots() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: paths.storeSnapshots.path)) ?? []).sorted()
}

/// The provider of every desktop entry in a store file, for eyeballing what is showing.
func providers(in url: URL) -> [String] {
    guard let root = try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? NSDictionary
    else { return ["unreadable"] }
    var found: [String] = []
    func walk(_ value: Any) {
        if let array = value as? NSArray { array.forEach(walk); return }
        guard let dict = value as? NSDictionary else { return }
        for key in ["Desktop", "Linked"] {
            if let entry = dict[key] as? NSDictionary,
               let choices = (entry["Content"] as? NSDictionary)?["Choices"] as? NSArray {
                for case let choice as NSDictionary in choices {
                    found.append(choice["Provider"] as? String ?? "?")
                }
            }
        }
        for value in dict.allValues where value is NSDictionary || value is NSArray { walk(value) }
    }
    walk(root)
    return found
}

func desktopProviders() -> [String] { providers(in: storeURL) }

/// Simulate the user picking a picture in System Settings: every desktop entry becomes an image.
func putUpAUsersOwnWallpaper() throws {
    var format = PropertyListSerialization.PropertyListFormat.xml
    let root = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: storeURL), options: .mutableContainersAndLeaves, format: &format) as! NSMutableDictionary
    let config = try PropertyListSerialization.data(fromPropertyList: ["type": "imageFile"], format: .binary, options: 0)
    let image: [String: Any] = ["Provider": "com.apple.wallpaper.choice.image", "Configuration": config, "Files": [Any]()]
    func walk(_ value: Any) {
        if let array = value as? NSArray { array.forEach(walk); return }
        guard let dict = value as? NSMutableDictionary else { return }
        for key in ["Desktop", "Linked"] {
            guard let entry = dict[key] as? NSMutableDictionary,
                  let content = entry["Content"] as? NSMutableDictionary
            else { continue }
            content["Choices"] = NSMutableArray(object: NSMutableDictionary(dictionary: image))
            content["Shuffle"] = "$null"
        }
        for value in dict.allValues where value is NSMutableDictionary || value is NSArray { walk(value) }
    }
    walk(root)
    let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    try data.write(to: storeURL, options: .atomic)
}

// MARK: - The rehearsal

let setID = "0DC99DD8-3386-4D1E-8878-C43E97EB710A"
let dayID = "4C108785-A7BA-422E-9C79-B0129F1D5550"
let eveningID = "52ACB9B8-75FC-4516-BC60-4550CFF3B661"

let manifestHash = sha(paths.manifest)
let switcher = Switcher(paths: paths, reload: { print("  ·    (would restart WallpaperAgent here — it is not)") })
let store = switcher.store
let sets = try Manifest.load(from: paths.manifest)
guard let set = sets.first(where: { $0.id == setID }) else {
    print("no \(setID) in the manifest: \(sets.map(\.id))")
    exit(1)
}
note("set “\(set.name)” has \(set.aerials.count) aerials, read from the fake home only")

var config = Config.load(from: paths.config)
check("config: autoDownload off", config.autoDownload, false)
check("config: switching on", config.enabled, true)

print("\n1. A video that isn't on disk is reported, not fetched.")
let evening = set.aerial(for: .evening)
let eveningFile = paths.videos.appendingPathComponent("\(evening!.id).mov")
let spare = URL(fileURLWithPath: "/tmp/asw-evening-spare.mov")
try? FileManager.default.removeItem(at: spare)
try FileManager.default.moveItem(at: eveningFile, to: spare)
check("videos on disk", movCount(), 1)
let appSupportBefore = (try? FileManager.default.contentsOfDirectory(atPath: paths.appSupport.path).sorted()) ?? []
let missing = try switcher.sync(set: set, config: config, at: date(hour: 18, minute: 30))
check("result", missing, SyncResult.notDownloaded(evening!))
check("no partial-download folder", FileManager.default.fileExists(atPath: paths.partialDownloads.path), false)
check("no byte written anywhere else", (try? FileManager.default.contentsOfDirectory(atPath: paths.appSupport.path).sorted()) ?? [], appSupportBefore)
try FileManager.default.moveItem(at: spare, to: eveningFile)

print("\n2. The first switch takes over, and keeps the way back.")
note("showing before: \(desktopProviders())")
let tookOver = try switcher.sync(set: set, config: config, at: date(hour: 17, minute: 58))
check("result", tookOver, SyncResult.switched(to: set.aerial(for: .day)!))
check("desktop now", Set(desktopProviders()), Set([WallpaperStore.aerialProvider]))
check("store holds the day aerial", try store.state(), .aerial(assetID: dayID))
check("backup of the user's wallpaper exists", store.hasBackup, true)
note("backup holds: \(providers(in: paths.storeBackup))")
check("last set recorded", try String(contentsOf: paths.lastSet, encoding: .utf8), dayID)
check("snapshot count", snapshots().count, 1)

print("\n3. The same phase again writes nothing.")
let storeHash = sha(storeURL)
check("result", try switcher.sync(set: set, config: config, at: date(hour: 17, minute: 59)), SyncResult.alreadyShowing(set.aerial(for: .day)!))
check("store untouched", sha(storeURL), storeHash)
check("snapshot count", snapshots().count, 1)

print("\n4. The user picks a wallpaper: the schedule steps aside.")
try putUpAUsersOwnWallpaper()
let userHash = sha(storeURL)
check("result", try switcher.sync(set: set, config: config, at: date(hour: 18, minute: 30)), SyncResult.steppedAside(evening!))
check("the user's wallpaper stays up", sha(storeURL), userHash)
check("still what the user chose", Set(desktopProviders()), Set(["com.apple.wallpaper.choice.image"]))

print("\n5. Switching off after stepping aside leaves the user alone.")
check("restoreBackup changed nothing", try store.restoreBackup(), false)
check("the user's wallpaper still stays up", sha(storeURL), userHash)
check("backup dropped", store.hasBackup, false)

print("\n6. Switching back on takes over again, from here.")
check("result", try switcher.sync(set: set, config: config, at: date(hour: 18, minute: 30)), SyncResult.switched(to: evening!))
check("store holds the evening aerial", try store.state(), .aerial(assetID: eveningID))
check("snapshot count", snapshots().count, 2)
let nowHash = sha(storeURL)

print("\n7. Switching off while its own Aerial is showing puts the user's wallpaper back.")
check("restoreBackup restored", try store.restoreBackup(), true)
check("store changed", sha(storeURL) != nowHash, true)
note("restored to: \(desktopProviders())")
check("backup gone", store.hasBackup, false)
check("last set gone", FileManager.default.fileExists(atPath: paths.lastSet.path), false)

print("\n8. Nothing was downloaded, and the manifest was only read.")
check("videos on disk", movCount(), 2)
check("no download folder", FileManager.default.fileExists(atPath: paths.partialDownloads.path), false)
check("manifest untouched", sha(paths.manifest), manifestHash)

print("\nFiles the rehearsal left under \(fakeHome.path):")
for url in try FileManager.default.contentsOfDirectory(at: paths.appSupport, includingPropertiesForKeys: nil)
    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    print("  \(paths.appSupport.lastPathComponent)/\(url.lastPathComponent)")
}
for name in snapshots() { print("  \(paths.storeSnapshots.lastPathComponent)/\(name)") }

print(failures.isEmpty ? "\nAll checks passed." : "\n\(failures.count) failed: \(failures)")
exit(failures.isEmpty ? 0 : 1)

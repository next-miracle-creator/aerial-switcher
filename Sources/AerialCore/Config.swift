import Foundation

/// What the user picked, saved as JSON in the app's Application Support folder.
public struct Config: Codable, Equatable, Sendable {
    /// ID of the chosen set; nil until the user picks one.
    public var setID: String?
    /// Custom times per set, so switching sets back and forth keeps each set's edits.
    public var schedules: [String: Schedule] = [:]
    /// Off: no switching, and the wallpaper from before the app is put back.
    public var enabled = true
    /// Paused: no switching, the wallpaper showing stays.
    public var paused = false
    /// Fetch missing videos as soon as a set is picked. Off by default: a set is several
    /// hundred megabytes a video, and a silent gigabyte is not something to assume.
    public var autoDownload = false
    /// When the app found a wallpaper the user had chosen themselves and stood down. Kept so
    /// the reason is still there after a relaunch, and cleared on taking over again.
    public var steppedAsideAt: Date?

    public init(
        setID: String? = nil,
        schedules: [String: Schedule] = [:],
        enabled: Bool = true,
        paused: Bool = false,
        autoDownload: Bool = false,
        steppedAsideAt: Date? = nil
    ) {
        self.setID = setID
        self.schedules = schedules
        self.enabled = enabled
        self.paused = paused
        self.autoDownload = autoDownload
        self.steppedAsideAt = steppedAsideAt
    }

    /// Settings saved by an older version may lack newer keys; those get their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setID = try container.decodeIfPresent(String.self, forKey: .setID)
        schedules = try container.decodeIfPresent([String: Schedule].self, forKey: .schedules) ?? [:]
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        autoDownload = try container.decodeIfPresent(Bool.self, forKey: .autoDownload) ?? false
        steppedAsideAt = try container.decodeIfPresent(Date.self, forKey: .steppedAsideAt)
    }

    public func schedule(for set: AerialSet) -> Schedule {
        schedules[set.id] ?? set.defaultSchedule
    }

    public static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        return (try? decoder().decode(Config.self, from: data)) ?? Config()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder().encode(self).write(to: url, options: .atomic)
    }

    /// Dates as ISO 8601, so a hand-edited or inspected config.json stays readable.
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

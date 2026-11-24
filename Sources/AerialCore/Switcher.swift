import Foundation

public enum SyncResult: Equatable, Sendable {
    case switched(to: Aerial)
    case alreadyShowing(Aerial)
    case disabled
    case paused
    case noSetChosen
    /// The Aerial for the current phase isn't on disk yet; switching now would show the
    /// macOS default wallpaper instead.
    case notDownloaded(Aerial)
    /// The wallpaper showing is one the user picked, not one this app set. Switching would
    /// overwrite their choice, so the schedule waits: turn switching off and on again, or
    /// pick a set, to take over from here.
    case steppedAside(Aerial)
}

/// Puts the wallpaper in line with the schedule. Safe to call any time — on a timer,
/// after waking, at login — because it does nothing when the right Aerial is already showing.
public struct Switcher: Sendable {
    public let store: WallpaperStore
    public let videos: VideoLibrary
    let reload: @Sendable () -> Void

    public init(paths: Paths = .live, reload: @Sendable @escaping () -> Void = { _ = WallpaperStore.reloadAgent() }) {
        store = WallpaperStore(paths: paths)
        videos = VideoLibrary(paths: paths)
        self.reload = reload
    }

    public func aerial(for set: AerialSet, config: Config, at date: Date, calendar: Calendar = .current) -> Aerial? {
        config.schedule(for: set).phase(at: date, calendar: calendar).flatMap(set.aerial(for:))
    }

    public func sync(set: AerialSet?, config: Config, at date: Date = Date(), calendar: Calendar = .current) throws -> SyncResult {
        guard config.enabled else { return .disabled }
        guard !config.paused else { return .paused }
        guard let set, let target = aerial(for: set, config: config, at: date, calendar: calendar) else { return .noSetChosen }
        guard videos.isDownloaded(target) else { return .notDownloaded(target) }
        if try store.state() == .aerial(assetID: target.id) { return .alreadyShowing(target) }
        // Having taken over once, the app only owns the wallpaper while it still shows what
        // it set. Something else on screen is the user speaking; the schedule listens.
        if store.hasBackup, !store.isShowingOwnChange { return .steppedAside(target) }
        try store.setAerial(target.id, now: date)
        reload()
        return .switched(to: target)
    }
}

import AerialCore
import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class AppModel {
    struct Download {
        var index: Int
        var count: Int
        var fraction: Double
        var totalBytes: Int64?
    }

    private(set) var sets: [AerialSet] = []
    private(set) var config: Config
    private(set) var result: SyncResult?
    private(set) var download: Download?
    /// What the chosen set still lacks, and what fetching it would take. Nothing is
    /// downloaded on the app's own say-so unless the user asked for exactly that.
    private(set) var downloadPlan: DownloadPlan?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var now = Date()

    /// One slot per source, so an ordinary clock tick only clears what it actually knows
    /// about. A single shared `error` used to be reset by every `sync`, which hid the
    /// message that mattered: the missing manifest, the failed save, the failed download.
    private(set) var storeError: String?
    private(set) var manifestError: String?
    private(set) var settingsError: String?
    private(set) var downloadError: String?

    /// What to show: the store first, since that is the job failing here and now.
    var error: String? { storeError ?? manifestError ?? settingsError ?? downloadError }

    private let paths = Paths.live
    private let switcher: Switcher
    /// The phase last put on screen. The wallpaper is only touched again when the phase
    /// changes (or after waking), so picking another wallpaper by hand isn't undone a minute later.
    private var shownPhase: DayPhase?
    private var downloadTask: Task<Void, Never>?
    private var downloadID = UUID()
    private var planningDownload = false

    init() {
        config = Config.load(from: paths.config)
        switcher = Switcher(paths: paths)
        loadSets()
        startClock()
        observeSystemEvents()
        sync(force: true)
        refreshDownloadPlan()
    }

    var selectedSet: AerialSet? { sets.first { $0.id == config.setID } }
    var schedule: Schedule? { selectedSet.map(config.schedule(for:)) }
    var currentPhase: DayPhase? { schedule?.phase(at: now) }
    var nextChange: (date: Date, phase: DayPhase)? { schedule?.nextChange(after: now) }

    /// A download the user has to agree to: something is missing, it isn't running, and
    /// silent downloading is off.
    var downloadOffered: Bool {
        downloadTask == nil && !planningDownload && !config.autoDownload && downloadPlan.map { !$0.isEmpty } == true
    }

    /// Whether the app stood down because it found a wallpaper the user chose themselves.
    var stoodAside: Bool { config.steppedAsideAt != nil }

    // MARK: - Actions

    func selectSet(_ id: String) {
        guard id != config.setID else { return }
        config.setID = id
        // Picking a set means wanting to see it.
        config.enabled = true
        config.paused = false
        config.steppedAsideAt = nil
        save()
        cancelDownload()
        downloadPlan = nil
        refreshDownloadPlan()
    }

    /// While dragging, `commit` is false: the schedule on screen follows, but it's only saved,
    /// and the wallpaper only switched, once the drag ends.
    func setTime(_ time: TimeOfDay, for phase: DayPhase, commit: Bool = true) {
        guard let set = selectedSet else { return }
        var schedule = config.schedule(for: set)
        schedule.times[phase] = time
        config.schedules[set.id] = schedule
        if commit { save() }
    }

    func resetSchedule() {
        guard let set = selectedSet else { return }
        config.schedules[set.id] = nil
        save()
    }

    func setPaused(_ paused: Bool) {
        guard paused != config.paused else { return }
        config.paused = paused
        save()
    }

    func setAutoDownload(_ autoDownload: Bool) {
        guard autoDownload != config.autoDownload else { return }
        config.autoDownload = autoDownload
        save()
        // Switching it on means wanting what's missing now.
        if autoDownload { refreshDownloadPlan(startWhenReady: true) }
    }

    /// Turning off puts back the wallpaper from before this app took over; turning on again
    /// takes over again (keeping a fresh copy of whatever is showing then).
    func setEnabled(_ enabled: Bool) {
        guard enabled != config.enabled else { return }
        config.enabled = enabled
        // Pause keeps an Aerial on screen; off and back on there is none to keep.
        config.paused = false
        if enabled { config.steppedAsideAt = nil } else { cancelDownload() }
        save()
        guard !enabled else { return }
        do {
            if try switcher.store.restoreBackup() { WallpaperStore.reloadAgent() }
        } catch {
            storeError = error.localizedDescription
        }
    }

    func setLanguage(_ language: AppLanguage) {
        Localization.shared.language = language
        // The set names come from macOS, in the language asked for.
        loadSets()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            settingsError = tr("Couldn't change Launch at Login: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Starts what the offer is describing. Called by the button, and by an auto-download.
    func startDownload() {
        guard downloadTask == nil, let plan = downloadPlan, !plan.isEmpty else { return }
        guard plan.fitsOnDisk else {
            downloadError = tr("Not enough free space: %1$@ needed, %2$@ free.", Self.showing(plan.totalBytes), plan.freeBytes.map(Self.showing) ?? tr("unknown"))
            return
        }
        downloadError = nil
        let id = UUID()
        downloadID = id
        download = Download(index: 0, count: plan.aerials.count, fraction: 0, totalBytes: plan.sizesKnown ? plan.totalBytes : nil)
        downloadTask = Task {
            let videos = switcher.videos
            var failure: String?
            for (index, aerial) in plan.aerials.enumerated() {
                guard downloadID == id else { return }
                download?.index = index
                download?.fraction = 0
                do {
                    try await videos.download(aerial, attempts: Self.downloadAttempts) { fraction in
                        Task { @MainActor in
                            guard self.downloadID == id else { return }
                            self.download?.fraction = fraction
                        }
                    }
                } catch {
                    failure = tr("Downloading %1$@ failed: %2$@", aerial.label, error.localizedDescription)
                    break
                }
            }

            guard downloadID == id else { return }
            downloadTask = nil
            download = nil
            downloadError = failure
            downloadPlan = nil
            sync(force: true)
            if failure == nil { refreshDownloadPlan() }
        }
    }

    /// Ask again, now, whatever the settings say: the menu and Settings both offer this
    /// after a failure, where there was no way back before.
    func retryDownload() {
        guard downloadTask == nil else { return }
        downloadError = nil
        refreshDownloadPlan(startWhenReady: true)
    }

    // MARK: - Syncing

    private func save() {
        do {
            try config.save(to: paths.config)
        } catch {
            settingsError = tr("Couldn't save settings: %@", error.localizedDescription)
        }
        sync(force: true)
    }

    func sync(force: Bool = false) {
        now = Date()
        let phase = currentPhase
        guard force || phase != shownPhase else { return }
        do {
            result = try switcher.sync(set: selectedSet, config: config, at: now)
            storeError = nil
            switch result {
            case .switched, .alreadyShowing: shownPhase = phase
            case .notDownloaded:
                shownPhase = nil
                if downloadPlan == nil { refreshDownloadPlan() }
            case .steppedAside:
                shownPhase = nil
                standAside()
            default: shownPhase = nil
            }
        } catch {
            storeError = error.localizedDescription
            shownPhase = nil
        }
    }

    /// The wallpaper showing is one the user picked, so the schedule stops claiming the
    /// screen: switching off from here leaves their choice in place, and says why.
    private func standAside() {
        guard config.enabled else { return }
        config.steppedAsideAt = now
        setEnabled(false)
    }

    private func loadSets() {
        do {
            sets = try Manifest.load(from: paths.manifest, preferredLanguages: Localization.shared.preferredLanguages)
            manifestError = nil
        } catch {
            manifestError = error.localizedDescription
        }
    }

    private func startClock() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.sync()
            }
        }
    }

    private func observeSystemEvents() {
        let names: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification),
            (.default, .NSSystemClockDidChange),
            (.default, .NSSystemTimeZoneDidChange),
        ]
        for (center, name) in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sync(force: true)
                    // A download that died with the network is worth another look on wake;
                    // it starts by itself only if that was asked for.
                    self?.refreshDownloadPlan()
                }
            }
        }
    }

    // MARK: - Downloads

    /// What the set still needs and what it would cost. Asks the servers for sizes, so it
    /// runs on request — at startup, on a wake, when the user asks — not on the clock.
    func refreshDownloadPlan(startWhenReady: Bool = false) {
        guard downloadTask == nil, let set = selectedSet else { return }
        let missing = switcher.videos.missing(in: set)
        guard !missing.isEmpty else { downloadPlan = nil; return }
        guard !planningDownload else { return }
        planningDownload = true
        Task { [weak self] in
            guard let self else { return }
            let plan = await self.switcher.videos.plan(for: missing)
            self.planningDownload = false
            guard self.downloadTask == nil else { return }
            self.downloadPlan = plan
            if startWhenReady || self.config.autoDownload { self.startDownload() }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        download = nil
        downloadID = UUID()
    }

    static let downloadAttempts = 3

    /// Bytes shown the way a Finder window shows them.
    static func showing(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

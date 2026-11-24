import Foundation
import os

/// What a set's missing videos would cost, worked out before any of it is downloaded: a
/// Landscape set is four or five videos of a few hundred megabytes each, so the user sees
/// the size and the free space and decides.
public struct DownloadPlan: Equatable, Sendable {
    public var aerials: [Aerial]
    /// Sum of the server's Content-Length, 0 for whatever wasn't reachable.
    public var totalBytes: Int64
    /// Bytes the volume has room for; nil when even that couldn't be read.
    public var freeBytes: Int64?
    /// False when some size couldn't be asked for, so `totalBytes` is a floor, not the figure.
    public var sizesKnown: Bool

    public var isEmpty: Bool { aerials.isEmpty }

    /// Room to spare beyond the videos, so a download doesn't fill the disk out from under
    /// whatever else is writing.
    public static let headroom: Int64 = 2_000_000_000

    /// Whether the download fits in what's free, once the headroom is kept back.
    public var fitsOnDisk: Bool {
        guard let freeBytes else { return true }
        return totalBytes + Self.headroom <= freeBytes
    }
}

/// The Aerial videos macOS keeps on disk, one `<assetID>.mov` per Aerial.
/// An Aerial that isn't downloaded shows as the macOS default wallpaper, and macOS
/// doesn't fetch it by itself, so the app downloads missing videos of the chosen set.
public struct VideoLibrary: Sendable {
    let paths: Paths

    public init(paths: Paths = .live) {
        self.paths = paths
    }

    public func isDownloaded(_ aerial: Aerial) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: file(for: aerial).path)[.size] as? Int) ?? 0
        return size > 0
    }

    public func missing(in set: AerialSet) -> [Aerial] {
        set.aerials.filter { !isDownloaded($0) }
    }

    /// Bytes still to download for a set, from the server's Content-Length.
    public func downloadSize(of aerials: [Aerial]) async -> Int64 {
        (await plan(for: aerials)).totalBytes
    }

    /// Asks the server for each size and reads the volume's free space, without writing
    /// anything. Safe to call before offering a download.
    public func plan(for aerials: [Aerial]) async -> DownloadPlan {
        var total: Int64 = 0
        var known = true
        await withTaskGroup(of: Int64?.self) { group in
            for aerial in aerials {
                guard let url = aerial.videoURL else { known = false; continue }
                group.addTask {
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 15
                    let response = try? await URLSession.shared.data(for: request).1
                    guard let length = response?.expectedContentLength, length > 0 else { return nil }
                    return length
                }
            }
            for await length in group {
                guard let length else { known = false; continue }
                total += length
            }
        }
        return DownloadPlan(aerials: aerials, totalBytes: total, freeBytes: Self.freeBytes(near: paths.videos), sizesKnown: known)
    }

    /// Bytes a volume still has for new files, as the system reports them (it counts purgeable
    /// space, the same way System Settings does). The videos folder is often missing before
    /// the first download, so walk up to whatever part of the path does exist.
    static func freeBytes(near url: URL) -> Int64? {
        let fileManager = FileManager.default
        var directory = url
        while !fileManager.fileExists(atPath: directory.path) {
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// Downloads one video, `progress` getting the fraction done, 0...1.
    ///
    /// Streams into a file of our own rather than using a download task: an async download
    /// task never reports progress, and a cancelled one leaves its partial file behind.
    /// A response that stops short of the length it promised is a broken movie, not a
    /// downloaded one, so it fails instead of being moved into place.
    public func download(_ aerial: Aerial, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard let url = aerial.videoURL else {
            throw AerialError("This video has no download link in the manifest.")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.partialDownloads, withIntermediateDirectories: true)
        let partial = paths.partialDownloads.appendingPathComponent("\(aerial.id).mov")
        defer { try? fileManager.removeItem(at: partial) }

        let writer = try DownloadWriter(file: partial, progress: progress)
        let session = URLSession(configuration: .default, delegate: writer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            try await writer.run(session.dataTask(with: url))
        } catch DownloadWriter.Failure.status(let code) {
            Self.logger.error("Server answered \(code) for \(aerial.id, privacy: .public)")
            throw AerialError("The server refused this video.")
        } catch DownloadWriter.Failure.incomplete(let got, let expected) {
            Self.logger.error("Got \(got) of \(expected) bytes for \(aerial.id, privacy: .public)")
            throw AerialError("The download ended before the whole file arrived.")
        }

        let destination = file(for: aerial)
        try fileManager.createDirectory(at: paths.videos, withIntermediateDirectories: true)
        let written = (try? fileManager.attributesOfItem(atPath: partial.path)[.size] as? Int).flatMap { Int64($0) } ?? 0
        guard written > 0 else { throw AerialError("The downloaded file was empty.") }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partial, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    /// Downloads, retrying a few times with a wait between: a video that fails on wake
    /// before the network is properly back should not need a person to notice.
    /// Gives up at once on a cancellation, and on a server that says no.
    public func download(_ aerial: Aerial, attempts: Int = 3, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        var lastError: Error = CancellationError()
        for attempt in 0..<max(attempts, 1) {
            do {
                try await download(aerial, progress: progress)
                if attempt > 0 { Self.logger.notice("Downloaded \(aerial.label, privacy: .public) on try \(attempt + 1)") }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AerialError where error.message.contains("no download link") {
                throw error
            } catch {
                lastError = error
                guard attempt + 1 < attempts else { break }
                try await Task.sleep(for: .seconds(Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]))
            }
        }
        throw lastError
    }

    static let retryDelays: [TimeInterval] = [2, 10]
    static let logger = Logger(subsystem: "io.github.ynnju.aerial-switcher", category: "VideoLibrary")

    private func file(for aerial: Aerial) -> URL {
        paths.videos.appendingPathComponent("\(aerial.id).mov")
    }
}

/// Writes a data task's response to a file, reporting progress in whole percents.
private final class DownloadWriter: NSObject, URLSessionDataDelegate, Sendable {
    enum Failure: Error {
        case status(Int)
        case incomplete(received: Int64, expected: Int64)
    }

    private struct State {
        var handle: FileHandle
        var continuation: CheckedContinuation<Void, Error>?
        var task: URLSessionTask?
        var cancelled = false
        var failure: Error?
        var expected: Int64 = 0
        var received: Int64 = 0
        var percent = -1
    }

    private let state: OSAllocatedUnfairLock<State>
    private let progress: @Sendable (Double) -> Void

    init(file: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        state = OSAllocatedUnfairLock(uncheckedState: State(handle: try FileHandle(forWritingTo: file)))
        self.progress = progress
    }

    func run(_ task: URLSessionDataTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLockUnchecked { state in
                    state.continuation = continuation
                    state.task = task
                    return state.cancelled
                }
                cancelled ? task.cancel() : task.resume()
                if cancelled { finish(CancellationError()) }
            }
        } onCancel: {
            let task = state.withLockUnchecked { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
        // A task that ended early leaves a short file behind; catch it here, where the
        // byte count and the promise are both at hand.
        let (received, expected) = state.withLockUnchecked { ($0.received, $0.expected) }
        if expected > 0, received < expected { throw Failure.incomplete(received: received, expected: expected) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            state.withLockUnchecked { $0.failure = Failure.status((response as? HTTPURLResponse)?.statusCode ?? -1) }
            return .cancel
        }
        state.withLockUnchecked { $0.expected = response.expectedContentLength }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let fraction: Double? = state.withLockUnchecked { state in
            do {
                try state.handle.write(contentsOf: data)
            } catch {
                state.failure = error
                dataTask.cancel()
                return nil
            }
            state.received += Int64(data.count)
            guard state.expected > 0 else { return nil }
            let fraction = Double(state.received) / Double(state.expected)
            let percent = Int(fraction * 100)
            guard percent != state.percent else { return nil }
            state.percent = percent
            return fraction
        }
        if let fraction { progress(fraction) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        let (continuation, result) = state.withLockUnchecked { state in
            defer { state.continuation = nil }
            try? state.handle.close()
            let result: Error? = state.failure ?? (state.cancelled ? CancellationError() : error)
            return (state.continuation, result)
        }
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
    }
}

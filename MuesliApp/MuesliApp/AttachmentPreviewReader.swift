import Foundation
import Combine
import ImageIO
import CryptoKit
import Darwin

/// Bounded, immutable preview requests. Every filesystem operation and image
/// decode runs inside the selected meeting's existing persistence owner.
nonisolated final class AttachmentPreviewReader: @unchecked Sendable {
    enum Kind: Hashable, Sendable { case image, text }
    enum Mode: Hashable, Sendable { case thumbnail, detail }
    struct Request: Hashable, Sendable {
        let folder: URL
        let attachmentID: UUID
        let filename: String
        let kind: Kind
        let mode: Mode
        var sourceSessionID: String? = nil
        var expectedBytes: Int? = nil
        var expectedSHA256: String? = nil
    }
    struct PreviewImage: @unchecked Sendable { let image: CGImage }
    enum Content: Sendable { case image(PreviewImage), text(String) }
    enum Event: Sendable { case loading, pending, loaded(Content), failed(String) }
    struct Snapshot: Sendable { let active: Int; let requests: Int; let subscribers: Int }
    typealias Callback = @Sendable (Event) -> Void
    final class Subscription: @unchecked Sendable {
        private weak var reader: AttachmentPreviewReader?
        private let request: Request
        private let id: UUID
        fileprivate init(reader: AttachmentPreviewReader, request: Request, id: UUID) {
            self.reader = reader; self.request = request; self.id = id
        }
        func cancel() { reader?.cancel(request: request, id: id) }
        deinit { cancel() }
    }
    private struct Job {
        var subscribers: [UUID: Callback]
        let deadline: ContinuousClock.Instant
        var pending = false
        var running = false
    }
    static let shared = AttachmentPreviewReader()
    private let lock = NSLock()
    private let store: TranscriptPersistenceStore
    private let timeout: Duration
    private let maximumActive: Int
    private let maximumRequests: Int
    private let maximumSubscribers: Int
    private let beforeRead: @Sendable (Request) throws -> Void
    private var jobs: [Request: Job] = [:]
    private var order: [Request] = []
    private var activeFolders: Set<URL> = []
    private let timer: DispatchSourceTimer

    init(store: TranscriptPersistenceStore = .shared, timeoutSeconds: Double = 5,
         maximumActive: Int = 8, maximumRequests: Int = 64, maximumSubscribers: Int = 128,
         beforeRead: @escaping @Sendable (Request) throws -> Void = { _ in }) {
        self.store = store
        timeout = .seconds(max(0.001, timeoutSeconds))
        self.maximumActive = min(8, max(1, maximumActive))
        self.maximumRequests = min(64, max(1, maximumRequests))
        self.maximumSubscribers = min(128, max(1, maximumSubscribers))
        self.beforeRead = beforeRead
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "muesli.attachment-preview-deadline"))
        timer.schedule(deadline: .now() + 0.01, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.publishDeadlines() }
        timer.resume()
    }
    deinit { timer.cancel() }
    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(active: activeFolders.count, requests: jobs.count,
                                 subscribers: jobs.values.reduce(0) { $0 + $1.subscribers.count }) }
    }
    @discardableResult
    func subscribe(_ request: Request, onEvent: @escaping Callback) -> Subscription? {
        let id = UUID()
        let event: Event = lock.withLock {
            guard jobs.values.reduce(0, { $0 + $1.subscribers.count }) < maximumSubscribers else {
                return .failed("Too many previews are open. Close a preview and retry.")
            }
            if var job = jobs[request] {
                job.subscribers[id] = onEvent
                jobs[request] = job
                return job.pending ? .pending : .loading
            }
            guard jobs.count < maximumRequests else {
                return .failed("Preview capacity is full. Retry when another preview finishes.")
            }
            jobs[request] = Job(subscribers: [id: onEvent], deadline: .now + timeout)
            order.append(request)
            return .loading
        }
        onEvent(event)
        if case .failed = event { return nil }
        let subscription = Subscription(reader: self, request: request, id: id)
        pump()
        return subscription
    }
    private func cancel(request: Request, id: UUID) {
        lock.withLock {
            guard var job = jobs[request] else { return }
            job.subscribers[id] = nil
            if job.subscribers.isEmpty, !job.running {
                jobs[request] = nil
                order.removeAll { $0 == request }
            } else { jobs[request] = job }
        }
    }
    private func publishDeadlines() {
        let callbacks: [Callback] = lock.withLock {
            var callbacks: [Callback] = []
            for request in order {
                guard var job = jobs[request], !job.pending, .now >= job.deadline else { continue }
                job.pending = true
                jobs[request] = job
                callbacks.append(contentsOf: job.subscribers.values)
            }
            return callbacks
        }
        callbacks.forEach { $0(.pending) }
    }
    private func pump() {
        let admitted: [Request] = lock.withLock {
            var admitted: [Request] = []
            for request in order where activeFolders.count < maximumActive {
                guard var job = jobs[request], !job.running, !activeFolders.contains(request.folder) else { continue }
                job.running = true
                jobs[request] = job
                activeFolders.insert(request.folder)
                admitted.append(request)
            }
            return admitted
        }
        for request in admitted {
            do {
                _ = try store.start(in: request.folder, onCompletion: { [self] (result: Result<Content, TranscriptPersistenceStore.Failure>) in
                    switch result {
                    case .success(let content): complete(request, event: .loaded(content))
                    case .failure(let error): complete(request, event: .failed(error.localizedDescription))
                    }
                }) { [beforeRead] _ in
                    try beforeRead(request)
                    return try Self.read(request)
                }
            } catch { complete(request, event: .failed(error.localizedDescription)) }
        }
    }
    private func complete(_ request: Request, event: Event) {
        let callbacks: [Callback] = lock.withLock {
            let callbacks = jobs.removeValue(forKey: request)?.subscribers.values.map { $0 } ?? []
            order.removeAll { $0 == request }
            activeFolders.remove(request.folder)
            return callbacks
        }
        callbacks.forEach { $0(event) }
        pump()
    }
    private static func fail(_ message: String) -> NSError {
        NSError(domain: "AttachmentPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func readFile(_ file: Int32, limit: Int) throws -> Data {
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw fail("The attachment is not a regular file.")
        }
        guard info.st_size >= 0, info.st_size <= limit else {
            throw fail("This preview exceeds its \(limit / (1024 * 1024)) MB size limit.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(file, &buffer, min(buffer.count, limit + 1 - data.count))
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw fail("The attachment could not be read.")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw fail("The attachment exceeds the preview size limit.") }
        }
        var after = stat()
        guard fstat(file, &after) == 0, data.count == info.st_size,
              after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
            throw fail("The attachment changed while it was being read. Retry.")
        }
        return data
    }
    private static func read(_ request: Request) throws -> Content {
        let name = request.filename
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.utf8.contains(0), name.utf8.count <= 255 else { throw fail("The attachment filename is invalid.") }
        let folder = open(request.folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw fail("The meeting folder could not be opened.") }
        defer { _ = close(folder) }
        // Reconcile with the owned current index, not a stale view's record.
        let manifestFile = openat(folder, "attachments.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard manifestFile >= 0 else { throw fail("The attachment index could not be opened.") }
        defer { _ = close(manifestFile) }
        let manifestData = try readFile(manifestFile, limit: 4 * 1024 * 1024)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(AttachmentsManifest.self, from: manifestData)
        guard Set(manifest.attachments.map(\.id)).count == manifest.attachments.count,
              Set(manifest.attachments.map(\.filename)).count == manifest.attachments.count,
              let record = manifest.attachments.first(where: { $0.id == request.attachmentID }),
              record.filename == name,
              (record.type == .image ? Kind.image : .text) == request.kind,
              record.sourceSessionID == request.sourceSessionID,
              record.byteCount == request.expectedBytes,
              record.sha256 == request.expectedSHA256 else {
            throw fail("The attachment's saved record changed or is invalid. Reopen the meeting before retrying.")
        }
        let directory = openat(folder, "attachments", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw fail("The attachment folder could not be opened.") }
        defer { _ = close(directory) }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw fail("The attachment is missing or cannot be opened safely.") }
        defer { _ = close(file) }
        let limit = request.kind == .text ? 1024 * 1024 : 32 * 1024 * 1024
        let data = try readFile(file, limit: limit)
        if let expected = request.expectedBytes, expected != data.count {
            throw fail("The attachment size no longer matches its saved record.")
        }
        if let expected = request.expectedSHA256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw fail("The attachment no longer matches its saved fingerprint.") }
        }
        switch request.kind {
        case .text:
            guard let text = String(data: data, encoding: .utf8) else { throw fail("The attachment is not valid UTF-8 text.") }
            return .text(text)
        case .image:
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue * height.doubleValue <= 16_000_000 else {
                throw fail("The image is invalid or exceeds the 16 megapixel preview limit.")
            }
            let pixels = request.mode == .thumbnail ? 160 : 2048
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
            ] as CFDictionary), image.width <= pixels, image.height <= pixels else {
                throw fail("The image preview could not be decoded within its size limit.")
            }
            return .image(PreviewImage(image: image))
        }
    }
}

/// View lifetime and request identity fence every late callback. Loading is
/// triggered by appearance/identity changes, never by evaluating View.body.
@MainActor
final class AttachmentPreviewModel: ObservableObject {
    @Published private(set) var event: AttachmentPreviewReader.Event = .loading
    private let reader: AttachmentPreviewReader
    private var request: AttachmentPreviewReader.Request?
    private var subscription: AttachmentPreviewReader.Subscription?
    private var generation = UUID()
    private var terminal = false
    init(reader: AttachmentPreviewReader = .shared) { self.reader = reader }
    func load(_ request: AttachmentPreviewReader.Request?) {
        subscription?.cancel(); subscription = nil
        generation = UUID(); terminal = false; self.request = request
        guard let request else { event = .failed("This attachment no longer belongs to an open meeting."); return }
        event = .loading
        let generation = self.generation
        subscription = reader.subscribe(request) { [weak self] event in
            guard let self else { return }
            if case .loading = event { return }
            Task { @MainActor in
                guard self.generation == generation, self.request == request, !self.terminal else { return }
                switch event { case .loaded, .failed: self.terminal = true; default: break }
                self.event = event
            }
        }
    }
    func retry() { load(request) }
    func stop() { generation = UUID(); subscription?.cancel(); subscription = nil; event = .loading }
}

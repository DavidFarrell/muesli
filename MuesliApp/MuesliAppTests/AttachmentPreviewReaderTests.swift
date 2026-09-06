import XCTest
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@MainActor
final class AttachmentPreviewReaderTests: XCTestCase {
    nonisolated private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        let terminal = TaskCompletion(), terminalSignal = DispatchSemaphore(value: 0)
        var values: [AttachmentPreviewReader.Event] { lock.withLock { recorded } }
        private var recorded: [AttachmentPreviewReader.Event] = []
        func receive(_ event: AttachmentPreviewReader.Event) {
            XCTAssertFalse(Thread.isMainThread, "Worker terminal publication is independent of UI")
            lock.withLock { recorded.append(event) }
            switch event {
            case .loaded, .failed: terminal.markCompleted(); terminalSignal.signal()
            default: break
            }
        }
        // Initial/loading admission runs on the caller, actual result off UI.
        func record(_ event: AttachmentPreviewReader.Event) {
            switch event { case .loading, .pending: lock.withLock { recorded.append(event) }
            default: receive(event) }
        }
    }
    nonisolated private final class Barrier: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        func block() { XCTAssertFalse(Thread.isMainThread); entered.signal(); _ = release.wait(timeout: .now() + 10) }
    }
    private func fixture(data: Data = Data("Saved text".utf8), kind: AttachmentPreviewReader.Kind = .text,
                         filename: String = UUID().uuidString + ".txt") throws -> AttachmentPreviewReader.Request {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try data.write(to: folder.appendingPathComponent("attachments").appendingPathComponent(filename))
        let record = Attachment(type: kind == .image ? .image : .text, timestamp: 1, filename: filename,
            sourceSessionID: "source-A", byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        try manifest([record], folder: folder)
        return .init(folder: folder, attachmentID: record.id, filename: filename, kind: kind, mode: .detail,
                     sourceSessionID: record.sourceSessionID, expectedBytes: record.byteCount, expectedSHA256: record.sha256)
    }
    private func manifest(_ records: [Attachment], folder: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(AttachmentsManifest(attachments: records)).write(to: folder.appendingPathComponent("attachments.json"))
    }
    private func load(_ request: AttachmentPreviewReader.Request, reader: AttachmentPreviewReader = AttachmentPreviewReader()) async throws -> AttachmentPreviewReader.Event {
        let probe = Probe()
        let token = reader.subscribe(request, onEvent: probe.record)
        let result = await probe.terminal.wait(timeoutSeconds: 3)
        XCTAssertEqual(result, .completed)
        withExtendedLifetime(token) {}
        return try XCTUnwrap(probe.values.last)
    }
    private func expectFailure(_ request: AttachmentPreviewReader.Request) async throws {
        guard case .failed = try await load(request) else { return XCTFail("Invalid attachment was rendered") }
    }

    func testActualOwnedReadAndImageDecodeFinishWithMainActorBlocked() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 3200, height: 1800, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage()), encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var request = try fixture(data: encoded as Data, kind: .image, filename: "image.png")
        let reader = AttachmentPreviewReader()
        for (mode, bound) in [(AttachmentPreviewReader.Mode.thumbnail, 160), (.detail, 2048)] {
            request = .init(folder: request.folder, attachmentID: request.attachmentID, filename: request.filename,
                kind: .image, mode: mode, sourceSessionID: request.sourceSessionID,
                expectedBytes: request.expectedBytes, expectedSHA256: request.expectedSHA256)
            let probe = Probe(), token = reader.subscribe(request, onEvent: probe.record)
            XCTAssertEqual(probe.terminalSignal.wait(timeout: .now() + 5), .success)
            guard case .loaded(.image(let preview)) = probe.values.last else { return XCTFail("Image did not decode") }
            XCTAssertLessThanOrEqual(preview.image.width, bound)
            XCTAssertLessThanOrEqual(preview.image.height, bound)
            withExtendedLifetime(token) {}
        }
    }

    func testOversizedImageHeaderFailsBeforeFullImageDecode() async throws {
        // Valid 5000 x 4000 one-bit grayscale PNG, generated by streaming
        // zero scanlines through zlib. The compressed fixture is only 2.5 KB;
        // its properties can be read without constructing a 20 MP bitmap.
        let data = try XCTUnwrap(Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAE4gAAA+gAQAAAAA+YsuHAAAJkUlEQVR4nO3BMQEAAADCoPVPbQsvoAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAeBo3egABc2jRKAAAAABJRU5ErkJggg==
        """, options: .ignoreUnknownCharacters))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 5_000)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 4_000)
        let request = try fixture(data: data, kind: .image, filename: "oversized.png")
        guard case .failed(let message) = try await load(request) else { return XCTFail("Oversized source was decoded") }
        XCTAssertTrue(message.contains("16 megapixel"))
    }

    func testSameFolderRequestsSerializeAndAllThumbnailsComplete() async throws {
        let first = try fixture(), barrier = Barrier()
        var requests = [first]
        var records = [Attachment(id: first.attachmentID, type: .text, timestamp: 1, filename: first.filename,
            sourceSessionID: first.sourceSessionID, byteCount: first.expectedBytes, sha256: first.expectedSHA256)]
        for n in 1..<12 {
            let filename = "\(n).txt", data = Data("\(n)".utf8)
            try data.write(to: first.folder.appendingPathComponent("attachments").appendingPathComponent(filename))
            let record = Attachment(type: .text, timestamp: 1, filename: filename)
            records.append(record)
            requests.append(.init(folder: first.folder, attachmentID: record.id, filename: filename, kind: .text, mode: .thumbnail))
        }
        try manifest(records, folder: first.folder)
        let reader = AttachmentPreviewReader(timeoutSeconds: 0.01) { if $0.attachmentID == first.attachmentID { barrier.block() } }
        let probes = requests.map { _ in Probe() }
        let tokens = zip(requests, probes).map { reader.subscribe($0, onEvent: $1.record) }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(reader.snapshot().active, 1)
        XCTAssertEqual(reader.snapshot().requests, 12)
        XCTAssertThrowsError(try TranscriptPersistenceStore.shared.start(in: first.folder) { _ in 1 })
        barrier.release.signal()
        for probe in probes {
            let outcome = await probe.terminal.wait(timeoutSeconds: 3)
            XCTAssertEqual(outcome, .completed)
            guard case .loaded(.text) = probe.values.last else { return XCTFail("Same-folder preview was rejected as busy") }
        }
        XCTAssertEqual(reader.snapshot().requests, 0)
        withExtendedLifetime(tokens) {}
    }

    func testAdmissionIsBoundedAndTimeoutNeverReleasesOriginalFolder() async throws {
        let barrier = Barrier()
        let reader = AttachmentPreviewReader(timeoutSeconds: 0.01, maximumRequests: 9) { _ in barrier.block() }
        let requests = try (0..<10).map { _ in try fixture() }
        let probes = requests.map { _ in Probe() }
        var tokens: [AttachmentPreviewReader.Subscription?] = []
        // Rejected admission can notify on this caller; don't assert a worker for that event.
        for i in 0..<9 { tokens.append(reader.subscribe(requests[i], onEvent: probes[i].record)) }
        for _ in 0..<8 { XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success) }
        var rejected = false
        tokens.append(reader.subscribe(requests[9]) { if case .failed = $0 {} })
        rejected = tokens.last! == nil
        XCTAssertTrue(rejected)
        XCTAssertEqual(reader.snapshot().active, 8)
        XCTAssertEqual(reader.snapshot().requests, 9)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(probes[0].values.contains { if case .pending = $0 { return true }; return false })
        tokens[0]?.cancel()
        XCTAssertEqual(reader.snapshot().active, 8)
        XCTAssertThrowsError(try TranscriptPersistenceStore.shared.start(in: requests[0].folder) { _ in 1 })
        for _ in 0..<9 { barrier.release.signal() }
        for probe in probes[1..<9] {
            let outcome = await probe.terminal.wait(timeoutSeconds: 3)
            XCTAssertEqual(outcome, .completed)
        }
        XCTAssertEqual(reader.snapshot().active, 0)
        withExtendedLifetime(tokens) {}
    }

    func testRetryObservesOriginalReadAndSubscriberCapacityIsBounded() async throws {
        let request = try fixture(), barrier = Barrier(), probe = Probe()
        let reader = AttachmentPreviewReader(timeoutSeconds: 0.01, maximumSubscribers: 2) { _ in barrier.block() }
        let first = reader.subscribe(request, onEvent: probe.record)
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
        let model = AttachmentPreviewModel(reader: reader)
        model.load(request)
        for _ in 0..<20 { model.retry() }
        XCTAssertEqual(reader.snapshot().active, 1)
        XCTAssertEqual(reader.snapshot().requests, 1)
        XCTAssertEqual(reader.snapshot().subscribers, 2)
        let rejected = reader.subscribe(request) { _ in }
        XCTAssertNil(rejected)
        XCTAssertEqual(reader.snapshot().subscribers, 2)
        barrier.release.signal()
        let result = await probe.terminal.wait(timeoutSeconds: 3)
        XCTAssertEqual(result, .completed)
        for _ in 0..<200 {
            if case .loaded(.text("Saved text")) = model.event { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .loaded(.text("Saved text")) = model.event else { return XCTFail("Retry did not observe original completion") }
        XCTAssertEqual(reader.snapshot().requests, 0)
        withExtendedLifetime(first) {}
    }

    func testFreshManifestAndHashRejectRemovedDuplicateAndChangedRecords() async throws {
        let changed = try fixture()
        try Data("Wrong text".utf8).write(to: changed.folder.appendingPathComponent("attachments").appendingPathComponent(changed.filename))
        try await expectFailure(changed)
        let removed = try fixture()
        try manifest([], folder: removed.folder)
        try await expectFailure(removed)
        let duplicate = try fixture()
        let record = Attachment(id: duplicate.attachmentID, type: .text, timestamp: 0, filename: duplicate.filename,
            sourceSessionID: duplicate.sourceSessionID, byteCount: duplicate.expectedBytes, sha256: duplicate.expectedSHA256)
        try manifest([record, record], folder: duplicate.folder)
        try await expectFailure(duplicate)
    }

    func testUnsafePathsSymlinksOversizeAndInvalidUTF8FailVisibly() async throws {
        let valid = try fixture()
        let traversal = AttachmentPreviewReader.Request(folder: valid.folder, attachmentID: valid.attachmentID,
            filename: "../attachments.json", kind: .text, mode: .detail)
        try await expectFailure(traversal)
        let symlink = try fixture()
        let file = symlink.folder.appendingPathComponent("attachments").appendingPathComponent(symlink.filename)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: symlink.folder.appendingPathComponent("attachments.json"))
        try await expectFailure(symlink)
        try await expectFailure(fixture(data: Data(repeating: 65, count: 1024 * 1024 + 1)))
        try await expectFailure(fixture(data: Data([0xFF, 0xFE])))
    }

    func testViewRequestGenerationRejectsLateOtherFolderAndDisappearedContent() async throws {
        let first = try fixture(data: Data("Old".utf8)), second = try fixture(data: Data("Current".utf8))
        let barrier = Barrier(), originalFinished = TaskCompletion()
        let reader = AttachmentPreviewReader { request in if request.folder == first.folder { barrier.block() } }
        let observer = reader.subscribe(first) { if case .loaded = $0 { originalFinished.markCompleted() } }
        let model = AttachmentPreviewModel(reader: reader)
        model.load(first)
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
        model.load(second)
        for _ in 0..<200 {
            if case .loaded(.text("Current")) = model.event { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .loaded(.text("Current")) = model.event else { return XCTFail("Current view did not load") }
        barrier.release.signal()
        let completed = await originalFinished.wait(timeoutSeconds: 3)
        XCTAssertEqual(completed, .completed)
        await Task.yield()
        guard case .loaded(.text("Current")) = model.event else { return XCTFail("Old folder replaced current content") }
        model.stop()
        guard case .loading = model.event else { return XCTFail("Disappeared view retained content") }
        withExtendedLifetime(observer) {}
    }
}

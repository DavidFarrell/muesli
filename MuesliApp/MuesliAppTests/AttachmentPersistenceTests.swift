import XCTest
import CoreGraphics
import ImageIO

@MainActor
final class AttachmentPersistenceTests: XCTestCase {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func add(_ folder: URL, source: String = "source-A", timestamp: Double = 10,
                     text: String = "Original", store: TranscriptPersistenceStore = .shared) async throws -> AttachmentPersistence.Snapshot {
        let owner = try store.start(in: folder) { context in
            XCTAssertFalse(Thread.isMainThread)
            return try AttachmentPersistence.add(context: context, type: .text, timestamp: timestamp,
                                                 sourceID: source, data: Data(text.utf8))
        }
        return try await owner.value(timeoutSeconds: 3)
    }
    private func manifest(_ folder: URL) async throws -> AttachmentsManifest {
        let read = try TranscriptPersistenceStore.shared.start(in: folder) { try AttachmentPersistence.readManifest(context: $0) }
        return try await read.value(timeoutSeconds: 3)
    }

    func testEqualTimestampsAcrossResumeHaveUniqueFilesAndSourceIdentity() async throws {
        let folder = try fixture()
        _ = try await add(folder)
        let result = try await add(folder, source: "source-B", timestamp: 10, text: "Resumed")
        XCTAssertEqual(result.attachments.count, 2)
        XCTAssertEqual(Set(result.attachments.map(\.filename)).count, 2)
        XCTAssertEqual(result.attachments.map(\.sourceSessionID), ["source-A", "source-B"])
        XCTAssertEqual(result.attachments.map(\.timestamp), [10, 10])
        for (attachment, text) in zip(result.attachments, ["Original", "Resumed"]) {
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("attachments/\(attachment.filename)"), encoding: .utf8), text)
            XCTAssertEqual(attachment.byteCount, text.utf8.count)
            XCTAssertEqual(attachment.sha256?.count, 64)
        }
    }

    func testManifestFailuresPreservePriorIndexAndBytesWithoutFalsePublication() async throws {
        for step in [TranscriptPersistenceStore.Step.stage("attachments.json"), .replace("attachments.json"), .commitJournal] {
            let folder = try fixture()
            let original = try await add(folder)
            let originalIndex = try Data(contentsOf: folder.appendingPathComponent("attachments.json"))
            let store = TranscriptPersistenceStore { if $0 == step { throw CocoaError(.fileWriteOutOfSpace) } }
            do { _ = try await add(folder, text: "Never indexed", store: store); XCTFail("Expected save failure") }
            catch { }
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("attachments.json")), originalIndex)
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("attachments/\(original.attachments[0].filename)"), encoding: .utf8), "Original")
            let current = try await manifest(folder)
            XCTAssertEqual(current.attachments.map(\.id), original.attachments.map(\.id))
        }
    }

    func testDeleteCommitsIndexBeforeRemovingBytesAndDoesNotTrustUIFilename() async throws {
        let folder = try fixture(), added = try await add(folder)
        let attachment = added.attachments[0]
        let file = folder.appendingPathComponent("attachments/\(attachment.filename)")
        let bad = TranscriptPersistenceStore { if $0 == .commitJournal { throw CocoaError(.fileWriteOutOfSpace) } }
        let failed = try bad.start(in: folder) { try AttachmentPersistence.remove(context: $0, id: attachment.id) }
        if case .failed = await failed.wait(timeoutSeconds: 3) {} else { XCTFail("Expected failed transaction") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let retained = try await manifest(folder)
        XCTAssertEqual(retained.attachments.count, 1)
        let remove = try TranscriptPersistenceStore.shared.start(in: folder) { try AttachmentPersistence.remove(context: $0, id: attachment.id) }
        let removed = try await remove.value(timeoutSeconds: 3)
        XCTAssertTrue(removed.attachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLegacySharedFilenameRemovalPreservesRemainingReference() async throws {
        let folder = try fixture(), initial = try await add(folder)
        let first = initial.attachments[0]
        let legacy = Attachment(type: .text, timestamp: 1, filename: first.filename)
        let setup = try TranscriptPersistenceStore.shared.start(in: folder) { context in
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try context.commit(files: ["attachments.json": encoder.encode(AttachmentsManifest(attachments: [first, legacy]))])
            return true
        }
        _ = try await setup.value()
        let operation = try TranscriptPersistenceStore.shared.start(in: folder) { try AttachmentPersistence.remove(context: $0, id: first.id) }
        let result = try await operation.value()
        XCTAssertEqual(result.attachments.map(\.id), [legacy.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("attachments/\(first.filename)").path))
    }

    func testStalledAttachmentRetainsFolderUntilStopSuccessorObservesItsCommit() async throws {
        let folder = try fixture(), entered = TaskCompletion(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = TranscriptPersistenceStore { step in
            if step == .stage("attachments.json") { entered.markCompleted(); _ = release.wait(timeout: .now() + 5) }
        }
        let save = try store.start(in: folder) {
            try AttachmentPersistence.add(context: $0, type: .text, timestamp: 30, sourceID: "resumed", data: Data("Keep this".utf8))
        }
        let began = await entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(began, .completed)
        if case .timedOut = await save.wait(timeoutSeconds: 0.02) {} else { XCTFail("Expected pending owner") }
        XCTAssertThrowsError(try TranscriptPersistenceStore.shared.start(in: folder) { _ in true })
        let stopped = try TranscriptPersistenceStore.shared.startAfterCurrent(in: folder) { try AttachmentPersistence.readManifest(context: $0) }
        release.signal()
        let final = try await stopped.value(timeoutSeconds: 3)
        XCTAssertEqual(final.attachments.count, 1)
        XCTAssertEqual(final.attachments[0].sourceSessionID, "resumed")
    }

    func testActualAttachmentWriteContinuesWhileMainActorIsBlocked() throws {
        let folder = try fixture(), completed = DispatchSemaphore(value: 0)
        _ = try TranscriptPersistenceStore.shared.start(in: folder, onCompletion: { (result: Result<AttachmentPersistence.Snapshot, TranscriptPersistenceStore.Failure>) in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            completed.signal()
        }) { context in
            XCTAssertFalse(Thread.isMainThread)
            return try AttachmentPersistence.add(context: context, type: .text, timestamp: 1, sourceID: "source", data: Data("Independent".utf8))
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 3), .success,
                       "The actual manifest/byte owner must finish while MainActor cannot run")
    }

    func testActualImageDecodeAndCommitRunWhileMainActorIsBlocked() throws {
        let folder = try fixture(), completed = DispatchSemaphore(value: 0)
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(canvas.makeImage()), bytes = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let input = AttachmentPersistence.ImageInput(data: bytes as Data)
        _ = try TranscriptPersistenceStore.shared.start(in: folder, onCompletion: { (result: Result<AttachmentPersistence.Snapshot, TranscriptPersistenceStore.Failure>) in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            completed.signal()
        }) { context in
            XCTAssertFalse(Thread.isMainThread)
            let png = try input.png()
            return try AttachmentPersistence.add(context: context, type: .image, timestamp: 2,
                                                 sourceID: "image-source", data: png)
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
    }

    func testInvalidAndOversizedImagesFailBeforeManifestPublication() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/oversized-attachment.png")
        let oversizedPixels = try Data(contentsOf: fixtureURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(oversizedPixels as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 5000)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 4000)
        for data in [Data("invalid image".utf8), oversizedPixels,
                     Data(repeating: 0, count: AttachmentPersistence.maximumBytes + 1)] {
            let folder = try fixture(), input = AttachmentPersistence.ImageInput(data: data)
            let operation = try TranscriptPersistenceStore.shared.start(in: folder) { context in
                try AttachmentPersistence.add(context: context, type: .image, timestamp: 1,
                    sourceID: "source", data: input.png())
            }
            if case .failed = await operation.wait(timeoutSeconds: 3) {} else { XCTFail("Invalid image was accepted") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("attachments.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("attachments").path))
        }
    }

    func testInvalidMetadataAndEscapingDirectoryArePreserved() async throws {
        let folder = try fixture(), outside = try fixture()
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("attachments"), withDestinationURL: outside)
        do { _ = try await add(folder); XCTFail("Expected rejection of redirected attachment storage") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        let invalidFolder = try fixture()
        let bytes = Data("not JSON".utf8)
        try bytes.write(to: invalidFolder.appendingPathComponent("attachments.json"))
        do { _ = try await add(invalidFolder); XCTFail("Expected corrupt manifest to be preserved") } catch { }
        XCTAssertEqual(try Data(contentsOf: invalidFolder.appendingPathComponent("attachments.json")), bytes)
        XCTAssertFalse(AttachmentPersistence.validFilename("../source.pcm"))
        XCTAssertFalse(AttachmentPersistence.validFilename("/tmp/file"))
        XCTAssertFalse(AttachmentPersistence.validFilename("a\\b"))
    }

    func testDeleteKeepsDirectoryIdentityWhenParentPathIsReplaced() async throws {
        let folder = try fixture(), outside = try fixture(), added = try await add(folder)
        let attachment = added.attachments[0]
        let unrelated = outside.appendingPathComponent(attachment.filename)
        try Data("Unrelated original".utf8).write(to: unrelated)
        let heldDirectory = folder.appendingPathComponent("held-original-directory")
        let store = TranscriptPersistenceStore { step in
            if step == .replace("attachments.json") {
                let directory = folder.appendingPathComponent("attachments")
                try FileManager.default.moveItem(at: directory, to: heldDirectory)
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
            }
        }
        let operation = try store.start(in: folder) { try AttachmentPersistence.remove(context: $0, id: attachment.id) }
        let result = try await operation.value(timeoutSeconds: 3)
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "Unrelated original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: heldDirectory.appendingPathComponent(attachment.filename).path))
    }

    func testDanglingManifestSymlinkIsPreservedAsExistingInvalidState() async throws {
        let folder = try fixture()
        let manifest = folder.appendingPathComponent("attachments.json")
        let missing = folder.appendingPathComponent("missing-original.json")
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: missing)
        do { _ = try await add(folder); XCTFail("Dangling manifest is not an absent manifest") } catch { }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: manifest.path), missing.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("attachments").path))
    }

    func testLegacyAttachmentDecodesWithoutInventedProvenance() throws {
        let json = #"{"id":"9CB66040-751F-4637-9EBC-99019C5DD232","type":"text","timestamp":2,"filename":"t+0000002.000.txt","createdAt":0}"#
        let attachment = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        XCTAssertNil(attachment.sourceSessionID)
        XCTAssertNil(attachment.byteCount)
        XCTAssertNil(attachment.sha256)
    }
}

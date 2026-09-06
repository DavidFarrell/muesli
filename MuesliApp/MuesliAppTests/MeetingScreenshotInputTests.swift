import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class MeetingScreenshotInputTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func image(_ url: URL, origin: MeetingScreenshotInput.Image.Origin) throws -> MeetingScreenshotInput.Image {
        let access = try MeetingFileAccess.acquire(in: url.deletingLastPathComponent())
        let directory = try MeetingScreenshotDirectory(access: access)
        return MeetingScreenshotInput.Image(file: try directory.reference(url.lastPathComponent), origin: origin)
    }
    private func pixel(width: Int = 2, height: Int = 2) -> CGImage {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4 * width,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    private func png(_ url: URL, width: Int = 2, height: Int = 2) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, pixel(width: width, height: height), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func session(_ root: URL, offset: Int64 = 0, finish: Bool = true) async throws -> (SessionArtifactStore, MeetingSessionMetadata) {
        let source = UUID().uuidString
        let store = try SessionArtifactStore(meetingDirectory: root, sourceSessionID: source,
            timeline: CaptureTimeline(epochMicroseconds: 1_000_000), timelineOffsetUs: offset)
        let committed = expectation(description: "actual durable image")
        XCTAssertTrue(store.submitScreenshot(pixel(), captureTimeUs: 3_000_000) { _ in committed.fulfill() })
        await fulfillment(of: [committed], timeout: 3)
        if finish { _ = await store.finish(timeoutSeconds: 3) }
        var session = MeetingSessionMetadata(sessionID: Int(offset) + 1, startedAt: Date(), audioFolder: "audio-" + source, streams: [:])
        session.sourceSessionID = source
        session.timelineOffsetSeconds = Double(offset) / 1_000_000
        session.artifactsFolder = store.relativeDirectory
        return (store, session)
    }
    private func metadata(_ root: URL, _ sessions: [MeetingSessionMetadata]) throws {
        let value = MeetingMetadata(version: 1, title: "Fixture", createdAt: Date(), updatedAt: Date(), durationSeconds: 100,
            lastTimestamp: 0, status: .completed, sessions: sessions, segmentCount: 0, speakerNames: [:])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: root.appendingPathComponent("meeting.json"))
    }
    private func read(_ root: URL) async throws -> MeetingScreenshotInput {
        let owner = try TranscriptPersistenceStore().start(in: root) { try MeetingScreenshotInput.snapshot(context: $0) }
        return try await owner.value(timeoutSeconds: 3)
    }
    private func editLedger(_ store: SessionArtifactStore, edit: ([[String: Any]]) -> [[String: Any]]) throws {
        let url = store.directory.appendingPathComponent("assets.jsonl")
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        let data = try edit(rows).reduce(into: Data()) { result, row in
            result.append(try JSONSerialization.data(withJSONObject: row)); result.append(0x0a)
        }
        try data.write(to: url)
    }
    private func assertInvalid(_ root: URL) async {
        do { _ = try await read(root); XCTFail("Invalid image provenance was admitted") } catch { }
    }

    func testActualResumedStoresKeepSourceAndMeetingTimeWithoutAddingOffsetTwice() async throws {
        let root = try folder()
        let first = try await session(root)
        let second = try await session(root, offset: 25_000_000)
        try metadata(root, [first.1, second.1])
        let input = try await read(root)
        XCTAssertEqual(input.images.count, 2)
        XCTAssertEqual(input.images.sorted { $0.timestamp! < $1.timestamp! }.map(\.origin), [
            .committed(sourceSessionID: first.0.sourceSessionID, meetingTime: 2),
            .committed(sourceSessionID: second.0.sourceSessionID, meetingTime: 27)])
        XCTAssertTrue(input.images.allSatisfy { !$0.url.lastPathComponent.hasPrefix("t+") })
        let selected = try await SpeakerIdentifier().selectScreenshots(from: input.images, targetCount: 16)
        XCTAssertEqual(selected.compactMap(\.timestamp), [2, 27])
    }

    func testFrozenTornTailAndUnlistedPNGsAreNotImages() async throws {
        let root = try folder(), pair = try await session(root)
        try metadata(root, [pair.1])
        try png(pair.0.directory.appendingPathComponent("screenshots/unlisted.png"))
        let handle = try FileHandle(forWritingTo: pair.0.directory.appendingPathComponent("assets.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"screenshot\",\"path\":\"uncommitted".utf8))
        try handle.close()
        let input = try await read(root)
        XCTAssertEqual(input.images.count, 1)
    }

    func testStillOwnedStoreIsRefusedUntilActualClose() async throws {
        let root = try folder(), pair = try await session(root, finish: false)
        try metadata(root, [pair.1])
        await assertInvalid(root)
        _ = await pair.0.finish(timeoutSeconds: 3)
        let input = try await read(root)
        XCTAssertEqual(input.images.count, 1)
    }

    func testLegacyAndModernAreExplicitlyDifferentEvidence() async throws {
        let root = try folder(), pair = try await session(root, offset: 25_000_000)
        try metadata(root, [pair.1])
        let legacy = root.appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        try png(legacy.appendingPathComponent("t+99999.png"))
        let input = try await read(root)
        let old = try XCTUnwrap(input.images.first { $0.origin == .legacy })
        XCTAssertNil(old.timestamp)
        XCTAssertTrue(old.evidence.contains("unverified"))
        let current = try XCTUnwrap(input.images.first { $0.timestamp != nil })
        XCTAssertEqual(current.timestamp, 27)
        XCTAssertTrue(current.evidence.contains(pair.0.sourceSessionID))
        XCTAssertTrue(current.evidence.contains(current.relativePath))
        XCTAssertTrue(current.evidence.contains(current.url.deletingPathExtension().lastPathComponent))
        XCTAssertFalse(current.evidence.contains("99999"))
    }

    func testForeignSourceRecordAndMismatchedIndexedSourceAreRejected() async throws {
        let root = try folder(), pair = try await session(root)
        var wrong = pair.1; wrong.sourceSessionID = UUID().uuidString
        try metadata(root, [wrong]); await assertInvalid(root)
        try metadata(root, [pair.1])
        try editLedger(pair.0) { rows in
            var rows = rows; rows[1]["source_session_id"] = UUID().uuidString; return rows
        }
        await assertInvalid(root)
    }

    func testTraversalCrossSessionSymlinkAndMissingCommittedImageAreRejected() async throws {
        for mutation in ["traversal", "other-source", "symlink", "missing"] {
            let root = try folder(), pair = try await session(root)
            try metadata(root, [pair.1])
            if mutation == "traversal" || mutation == "other-source" {
                try editLedger(pair.0) { rows in
                    var rows = rows
                    rows[1]["path"] = mutation == "traversal" ? "artifacts/\(pair.0.sourceSessionID)/screenshots/../../outside.png"
                        : "artifacts/\(UUID().uuidString)/screenshots/foreign.png"
                    return rows
                }
            } else {
                let shot = try FileManager.default.contentsOfDirectory(at: pair.0.directory.appendingPathComponent("screenshots"), includingPropertiesForKeys: nil)[0]
                try FileManager.default.removeItem(at: shot)
                if mutation == "symlink" {
                    let other = root.appendingPathComponent("foreign.png"); try png(other)
                    try FileManager.default.createSymbolicLink(at: shot, withDestinationURL: other)
                }
            }
            await assertInvalid(root)
        }
    }

    func testBackwardBooleanAndOffsetMismatchedTimesAreRejected() async throws {
        for mutation in ["boolean", "predates", "index", "after-end", "decreases"] {
            let root = try folder(), pair = try await session(root, offset: 25_000_000)
            var value = pair.1
            if mutation == "index" { value.timelineOffsetSeconds = 24 }
            try metadata(root, [value])
            if mutation != "index" {
                try editLedger(pair.0) { rows in
                    var rows = rows
                    if mutation == "after-end" {
                        rows.append(["type": "capture_stopped", "source_session_id": pair.0.sourceSessionID, "t": 26])
                    } else if mutation == "decreases" {
                        var earlier = rows[1]; earlier["t"] = 26; rows.append(earlier)
                    } else { rows[1]["t"] = mutation == "boolean" ? true : 1 }
                    return rows
                }
            }
            await assertInvalid(root)
        }
    }

    func testSamePixelsAcrossSourcesAreNotDeduplicatedIntoAnotherSource() async throws {
        let root = try folder(), first = root.appendingPathComponent("a.png"), second = root.appendingPathComponent("b.png")
        try png(first); try png(second)
        let images = [try image(first, origin: .committed(sourceSessionID: "one", meetingTime: 1)),
                      try image(second, origin: .committed(sourceSessionID: "two", meetingTime: 2))]
        let selected = try await SpeakerIdentifier().selectScreenshots(from: images, targetCount: 16)
        XCTAssertEqual(selected, images)
    }

    func testActualEncodedPayloadsRetainTheirOwnEvidenceWhenAnInvalidLegacyImageIsSkipped() async throws {
        let root = try folder(), valid = root.appendingPathComponent("valid.png"), corrupt = root.appendingPathComponent("bad.png")
        try png(valid); try Data("not an image".utf8).write(to: corrupt)
        let source = UUID().uuidString
        let images = [try image(corrupt, origin: .legacy),
                      try image(valid, origin: .committed(sourceSessionID: source, meetingTime: 27))]
        let payloads = try await SpeakerIdentifier().loadImagePayloads(from: images)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].evidence, images[1].evidence)
        XCTAssertTrue(payloads[0].evidence.contains("27.000000"))
        XCTAssertFalse(payloads[0].base64Data.isEmpty)
        do {
            _ = try await SpeakerIdentifier().loadImagePayloads(from: [try image(corrupt, origin: images[1].origin)])
            XCTFail("A corrupt committed image must not be silently omitted")
        } catch { }
    }

    func testBoundedImageDecodeRejectsOversizeBytesAndDimensionsBeforePixels() async throws {
        let root = try folder(), bytes = root.appendingPathComponent("bytes.png"), dimensions = root.appendingPathComponent("dimensions.png")
        try png(bytes)
        let handle = try FileHandle(forWritingTo: bytes)
        try handle.truncate(atOffset: 32 * 1024 * 1024 + 1); try handle.close()
        // Valid highly compressed PNG, inspected as metadata without decoding
        // its 20 MP bitmap. The fixture is generated from repeated zero rows.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/screenshot-20mp.png")
        let data = try Data(contentsOf: fixture)
        try data.write(to: dimensions)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 5_000)
        for (url, expected) in [(bytes, "32 MiB"), (dimensions, "16 megapixel")] {
            do {
                _ = try await SpeakerIdentifier().loadImagePayloads(from: [try image(url, origin: .committed(sourceSessionID: "fixture", meetingTime: 0))])
                XCTFail("Oversized image was decoded")
            } catch { XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription) }
        }
    }

    func testActualPayloadThumbnailHasBoundedDimensionsAndDedupeHonorsCancellation() async throws {
        let root = try folder(), wide = root.appendingPathComponent("wide.png")
        try png(wide, width: 2_560, height: 100)
        let image = try image(wide, origin: .legacy)
        let identifier = SpeakerIdentifier()
        let payload = try await identifier.loadImagePayloads(from: [image])[0]
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(Data(base64Encoded: payload.base64Data)) as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue, 1_024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue, 1_024)
        let task = Task { try await identifier.selectScreenshots(from: [image, image], targetCount: 16) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled dedupe continued") } catch is CancellationError { }
    }

    func testModernImageIdentityAndUnknownHeaderVersionAreNotGuessed() async throws {
        for mutation in ["id", "version"] {
            let root = try folder(), pair = try await session(root)
            try metadata(root, [pair.1])
            try editLedger(pair.0) { rows in
                var rows = rows
                if mutation == "version" { rows[0]["schema_version"] = 2 }
                else { rows[1]["path"] = pair.0.relativeDirectory + "/screenshots/not-an-artifact-id.png" }
                return rows
            }
            await assertInvalid(root)
        }
    }


    nonisolated private final class PreparationGate: @unchecked Sendable {
        let entered = TaskCompletion(), release = DispatchSemaphore(value: 0)
        func block() { entered.markCompleted(); _ = release.wait(timeout: .now() + 10) }
    }
    func testActualIdentificationKeepsAdmissionAfterCancelUntilBlockedPreparationReturns() async throws {
        let root = try folder(), gate = PreparationGate()
        let input = try await read(root)
        let original = Task {
            try await SpeakerIdentifier().identifySpeakers(screenshots: [], access: input.access, transcript: "",
                speakerIds: [], beforePreparation: { gate.block() })
        }
        defer { original.cancel(); gate.release.signal() }
        let entered = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(entered, .completed, "MainActor remains available while preparation is blocked")
        original.cancel()
        do {
            _ = try await SpeakerIdentifier().identifySpeakers(screenshots: [], access: input.access, transcript: "",
                speakerIds: [], beforePreparation: { XCTFail("A competing image job started") })
            XCTFail("Cancelled original released a still-blocked owner")
        } catch { XCTAssertTrue(error.localizedDescription.contains("earlier request")) }
        gate.release.signal()
        do { _ = try await original.value; XCTFail("Cancelled preparation reached a model request") }
        catch is CancellationError { }
        enum EndBeforeModel: Error { case fixture }
        do {
            _ = try await SpeakerIdentifier().identifySpeakers(screenshots: [], access: input.access, transcript: "",
                speakerIds: [], beforePreparation: { throw EndBeforeModel.fixture })
            XCTFail("Fixture should end before a network request")
        } catch EndBeforeModel.fixture { }
    }


    func testCaseVariantArtifactUUIDCannotDuplicateTheSameRecordedImage() async throws {
        let root = try folder(), pair = try await session(root)
        try metadata(root, [pair.1])
        try editLedger(pair.0) { rows in
            var rows = rows, alias = rows[1]
            let path = alias["path"] as! String
            alias["path"] = pair.0.relativeDirectory + "/screenshots/" + URL(fileURLWithPath: path).lastPathComponent.lowercased()
            alias["t"] = 3
            rows.append(alias)
            return rows
        }
        do { _ = try await read(root); XCTFail("Duplicate artifact UUID was admitted through a case alias") }
        catch { XCTAssertTrue(error.localizedDescription.contains("duplicate screenshot identity"), error.localizedDescription) }
    }


    func testAncestorSwapAfterSnapshotCannotEncodeForeignImageWithOldProvenance() async throws {
        let root = try folder(), pair = try await session(root)
        try metadata(root, [pair.1])
        let input = try await read(root)
        let screenshots = pair.0.directory.appendingPathComponent("screenshots")
        try FileManager.default.moveItem(at: screenshots, to: pair.0.directory.appendingPathComponent("original-screenshots"))
        let foreign = try folder()
        try png(foreign.appendingPathComponent(input.images[0].url.lastPathComponent), width: 32, height: 32)
        try FileManager.default.createSymbolicLink(at: screenshots, withDestinationURL: foreign)
        do { _ = try await SpeakerIdentifier().loadImagePayloads(from: input.images); XCTFail("Foreign ancestor image was encoded") }
        catch { }
    }

    func testFileReplacementAndSameInodeRewriteAfterSnapshotAreRejected() async throws {
        for replace in [true, false] {
            let root = try folder(), pair = try await session(root)
            try metadata(root, [pair.1])
            let input = try await read(root), imageURL = input.images[0].url
            if replace { try FileManager.default.moveItem(at: imageURL, to: pair.0.directory.appendingPathComponent("original.png")) }
            try png(imageURL, width: 32, height: 32)
            do { _ = try await SpeakerIdentifier().loadImagePayloads(from: input.images); XCTFail("Changed image retained its old evidence") }
            catch { }
        }
    }

    func testDanglingMetadataAndLedgerAncestorSymlinksNeverBecomeAbsentLegacyEvidence() async throws {
        let missing = try folder()
        try FileManager.default.createSymbolicLink(at: missing.appendingPathComponent("meeting.json"), withDestinationURL: missing.appendingPathComponent("absent.json"))
        await assertInvalid(missing)
        let root = try folder(), pair = try await session(root)
        try metadata(root, [pair.1])
        let original = root.appendingPathComponent("original-artifacts")
        try FileManager.default.moveItem(at: root.appendingPathComponent("artifacts"), to: original)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("artifacts"), withDestinationURL: original)
        await assertInvalid(root)
    }

    func testNameEditsInvalidateCapturedBasisAndStaleDiskMutationPreservesHumanName() async throws {
        let model = TranscriptModel()
        let before = SpeakerIdentificationBasis(model)
        model.renameSpeaker(id: "speaker", to: "Human edit")
        XCTAssertEqual(before.contentGeneration, model.contentGeneration)
        XCTAssertFalse(before.matches(model), "Names changed without a content generation increment")
        let presented = SpeakerIdentificationBasis(model)
        model.renameSpeaker(id: "speaker", to: "Second human edit")
        XCTAssertFalse(presented.matches(model), "An already presented suggestion must expire too")
        let root = try folder()
        try metadata(root, [])
        let human = try MeetingMetadataMutation.start(in: root, patch: .init(names: ["speaker": "Human edit"]))
        _ = try await human.value(timeoutSeconds: 2)
        let stale = try MeetingMetadataMutation.start(in: root,
            patch: .init(names: ["speaker": "Old suggestion"], expectedNames: [:]))
        do { _ = try await stale.value(timeoutSeconds: 2); XCTFail("A stale suggestion replaced the saved human name") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Speaker names changed")) }
        let current = try TranscriptPersistenceStore().start(in: root) { try $0.readMetadata() }
        let saved = try await current.value(timeoutSeconds: 2)
        XCTAssertEqual(saved.speakerNames["speaker"], "Human edit")
    }


    func testConditionalNameProposalIsNotTransferredAsUnconditionalFinalizerIntent() async throws {
        let root = try folder(), gate = PreparationGate(), finished = TaskCompletion()
        try metadata(root, [])
        let store = TranscriptPersistenceStore { step in if step == .stage("meeting.json") { gate.block() } }
        let edits = MeetingMetadataEdits(store: store) { event in
            if case .committed = event { finished.markCompleted() }
        }
        edits.submitNames(["speaker": "Reviewed suggestion"], in: root, contentGeneration: 0, expectedNames: [:])
        let entered = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(entered, .completed)
        XCTAssertEqual(edits.retire(in: root), [:])
        gate.release.signal()
        let ended = await finished.wait(timeoutSeconds: 3)
        XCTAssertEqual(ended, .completed)
    }

    func testOversizedMetadataDoesNotFallBackToLegacyImages() async throws {
        let root = try folder(), path = root.appendingPathComponent("meeting.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: 4 * 1024 * 1024 + 1); try handle.close()
        await assertInvalid(root)
    }

}

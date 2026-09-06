import XCTest
import Foundation
import CryptoKit

final class ArchiveOutputEvidenceTests: XCTestCase {
    private struct Fixture {
        let root: URL; let sourceID: UUID; let assetID: UUID; let operation: UUID
        var receipt: ArchiveReceipt
        let processing: ArchiveProcessingEvidence.Verified
        let nativeEvents: ArchiveReceipt.FileRecord
        let images: [ArchiveOutputEvidence.CopiedImage]
        var sidecar: [String: Any]
        func verify() throws -> ArchiveOutputEvidence.Verified {
            try ArchiveOutputEvidence.validate(receipt: receipt, processing: processing, nativeEvents: nativeEvents,
                                               copiedImages: images, vaultURL: root)
        }
        mutating func update(_ role: ArchiveReceipt.Output.Role, data: Data) throws {
            let index = receipt.outputs.firstIndex { $0.role == role }!, old = receipt.outputs[index]
            try data.write(to: URL(fileURLWithPath: old.file.path))
            var outputs = receipt.outputs
            outputs[index] = .init(role: role, file: .init(path: old.file.path, bytes: Int64(data.count), sha256: digest(data)), noteID: old.noteID)
            receipt = .init(schemaVersion: 2, operationID: operation, source: receipt.source, outputs: outputs, checks: receipt.checks, cleanup: .retained)
        }
        mutating func saveSidecar() throws { try update(.speakerProvenance, data: JSONSerialization.data(withJSONObject: sidecar, options: .sortedKeys)) }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func fixture(withImage: Bool = false) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("output-evidence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = UUID(), asset = UUID(), operation = UUID()
        let path = "MuesliAssets/\(source.uuidString.lowercased())/\(asset.uuidString.lowercased()).png"
        let raw = Data(("A: observed words.\n" + (withImage ? "![[\(path)]]\n" : "")).utf8)
        var outputs: [ArchiveReceipt.Output] = []
        func write(_ role: ArchiveReceipt.Output.Role, _ name: String, _ bytes: Data, noteID: String? = nil) throws -> ArchiveReceipt.FileRecord {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            let record = ArchiveReceipt.FileRecord(path: url.path, bytes: Int64(bytes.count), sha256: Self.digest(bytes))
            outputs.append(.init(role: role, file: record, noteID: noteID)); return record
        }
        _ = try write(.rawNote, "raw/note.md", raw, noteID: "one")
        _ = try write(.officialNote, "official/note.md", raw, noteID: "one")
        _ = try write(.redactionReport, "edits.json", JSONEncoder().encode(ByteEditEvidence(raw: .init(data: raw), official: .init(data: raw), edits: [])), noteID: "one")
        let events = try write(.reprocessEvents, "events.jsonl", Data("native observed event bytes\n".utf8))
        _ = try write(.reprocessDiagnostics, "diagnostics.txt", Data())
        let claim: [String: Any] = ["source_session_id": source.uuidString, "stream": "mic", "speaker_id": "SPEAKER_00", "name": "Alice", "basis": "inferred", "evidence": "self introduction", "uncertainty": "inferred from words only"]
        var sidecar: [String: Any] = ["schema_version": 1, "operation_id": operation.uuidString,
            "notes": [["note_id": "one", "source_session_ids": [source.uuidString]]], "speaker_claims": [claim], "images": []]
        var images: [ArchiveOutputEvidence.CopiedImage] = []
        if withImage {
            // Byte fixture only: native copier/decoder qualification is separate.
            let copied = try write(.attachment, path, Data([137,80,78,71,13,10,26,10]))
            let relative = "artifacts/\(source.uuidString)/screenshots/\(asset.uuidString).png"
            images = [.init(sourceSessionID: source, assetID: asset, sourceRelativePath: relative, timelineSeconds: 1,
                            source: .init(path: relative, bytes: copied.bytes, sha256: copied.sha256), copied: copied)]
            sidecar["images"] = ["raw", "official"].map { ["note_id": "one", "variant": $0, "source_session_id": source.uuidString, "asset_id": asset.uuidString, "vault_path": path] }
        }
        _ = try write(.speakerProvenance, "provenance.json", JSONSerialization.data(withJSONObject: sidecar))
        let receipt = ArchiveReceipt(schemaVersion: 2, operationID: operation,
            source: .init(folder: "/unused-source", directoryDevice: 1, directoryInode: 1, files: [], sessionIDs: [source.uuidString]),
            outputs: outputs, checks: .init(reprocessExitCode: 0, finalResultCount: 1, errorEventCount: 0, coveredSessionIDs: [source.uuidString],
                deterministicRedactionsVerified: true, imageLinksVerified: true, sourceIntegrityProblems: []), cleanup: .retained)
        return Fixture(root: root, sourceID: source, assetID: asset, operation: operation, receipt: receipt,
            processing: .init(sessionCount: 1, streamCount: 2, turnCount: 1, sourceSessionIDs: [source],
                speakerKeys: [.init(sourceSessionID: source, stream: "mic", speakerID: "SPEAKER_00")]),
            nativeEvents: events, images: images, sidecar: sidecar)
    }
    func testActualSavedByteEditsAndInferredSpeakerCoverage() throws {
        let f = try fixture(); let value = try f.verify()
        XCTAssertEqual(value.noteCount, 1); XCTAssertEqual(value.speakerClaimCount, 1); XCTAssertEqual(value.imageReferenceCount, 0)
    }
    func testCanonicalImagesWorkAcrossRawAndOfficialFolders() throws {
        XCTAssertEqual(try fixture(withImage: true).verify().imageReferenceCount, 2)
    }
    func testChangedOfficialBytesNeedCompleteObservedEdits() throws {
        var f = try fixture(); try f.update(.officialNote, data: Data("altered output".utf8))
        XCTAssertThrowsError(try f.verify())
    }
    func testSameSizeImageMutationAndForeignNativeEventLogRefused() throws {
        let f = try fixture(withImage: true)
        try Data(repeating: 42, count: 8).write(to: URL(fileURLWithPath: f.images[0].copied.path))
        XCTAssertThrowsError(try f.verify())
        var other = try fixture(); try other.update(.reprocessEvents, data: Data("foreign model-written evidence".utf8))
        XCTAssertThrowsError(try other.verify())
    }
    func testSpeakerTupleIncludesSourceAndChannelAndCannotBeOmittedOrDuplicated() throws {
        for mode in ["omit", "duplicate", "channel", "source"] {
            var f = try fixture(); var claims = f.sidecar["speaker_claims"] as! [[String: Any]]
            if mode == "omit" { claims = [] }
            if mode == "duplicate" { claims.append(claims[0]) }
            if mode == "channel" { claims[0]["stream"] = "system" }
            if mode == "source" { claims[0]["source_session_id"] = UUID().uuidString }
            f.sidecar["speaker_claims"] = claims; try f.saveSidecar(); XCTAssertThrowsError(try f.verify(), mode)
        }
    }
    func testNamedClaimsRequireEvidenceAndUncertaintyAndInferredBasis() throws {
        for (key, value) in [("evidence", ""), ("uncertainty", " "), ("basis", "verified"), ("name", "")] {
            var f = try fixture(); var claims = f.sidecar["speaker_claims"] as! [[String: Any]]
            claims[0][key] = value; f.sidecar["speaker_claims"] = claims; try f.saveSidecar()
            XCTAssertThrowsError(try f.verify(), key)
        }
    }
    func testUnknownSpeakerCanRemainUnnamedWithExplicitUncertainty() throws {
        var f = try fixture(); var claims = f.sidecar["speaker_claims"] as! [[String: Any]]
        claims[0]["name"] = NSNull(); claims[0]["evidence"] = ""; f.sidecar["speaker_claims"] = claims; try f.saveSidecar()
        XCTAssertNoThrow(try f.verify())
    }
    func testStrictKeysDuplicateJSONAndWrongOperationRefused() throws {
        var f = try fixture(); f.sidecar["unexpected"] = true; try f.saveSidecar(); XCTAssertThrowsError(try f.verify())
        f.sidecar.removeValue(forKey: "unexpected"); f.sidecar["operation_id"] = UUID().uuidString; try f.saveSidecar(); XCTAssertThrowsError(try f.verify())
        let data = Data("{\"schema_version\":1,\"schema_version\":1}".utf8)
        try f.update(.speakerProvenance, data: data); XCTAssertThrowsError(try f.verify())
    }
    func testDeclaredSourceCoverageCannotBeEmptyOrUnknown() throws {
        for ids in [[], [UUID().uuidString]] {
            var f = try fixture(); f.sidecar["notes"] = [["note_id": "one", "source_session_ids": ids]]
            try f.saveSidecar(); XCTAssertThrowsError(try f.verify())
        }
    }
    func testImageDeclarationsMustExactlyMatchActualEmbeds() throws {
        var f = try fixture(withImage: true); f.sidecar["images"] = []; try f.saveSidecar(); XCTAssertThrowsError(try f.verify())
        var g = try fixture(withImage: true); var images = g.sidecar["images"] as! [[String: Any]]
        images[0]["asset_id"] = UUID().uuidString; g.sidecar["images"] = images; try g.saveSidecar(); XCTAssertThrowsError(try g.verify())
    }
    func testUnsupportedAndDuplicateEmbedsAreNeverInferredAsSafe() throws {
        let path = "MuesliAssets/\(UUID().uuidString.lowercased())/\(UUID().uuidString.lowercased()).png"
        let embed = "![[\(path)]]"
        for text in ["![alt](https://example.test/a.png)", "<img src='x'>", "![[../x.png]]", "![[\(path)|200]]", "![[\(path)#x]]", embed + embed, "\\" + embed, "![[broken"] {
            XCTAssertThrowsError(try ArchiveOutputEvidence.imageLinks(Data(text.utf8)), text)
        }
    }
    func testAggregateBudgetRefusesBeforeAttemptingMissingFiles() throws {
        var f = try fixture(); var outputs = f.receipt.outputs
        outputs.append(.init(role: .attachment, file: .init(path: "/missing-budget-probe", bytes: Int64.max, sha256: "x"), noteID: nil))
        f.receipt = .init(schemaVersion: 2, operationID: f.operation, source: f.receipt.source, outputs: outputs, checks: f.receipt.checks, cleanup: .retained)
        XCTAssertThrowsError(try f.verify()) { XCTAssertTrue($0.localizedDescription.contains("aggregate budget")) }
    }
}

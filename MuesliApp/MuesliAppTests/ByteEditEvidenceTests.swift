import XCTest
import Foundation

final class ByteEditEvidenceTests: XCTestCase {
    private func evidence(_ raw: Data, _ official: Data, _ edits: [ByteEditEvidence.Edit]) -> ByteEditEvidence {
        ByteEditEvidence(raw: .init(data: raw), official: .init(data: official), edits: edits)
    }
    private func failure(_ expected: ByteEditEvidence.Failure, _ body: () throws -> Void,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? ByteEditEvidence.Failure, expected, file: file, line: line)
        }
    }
    func testExactUTF8RangesPreserveUnchangedBytesAndConsentReplacement() throws {
        let raw = Data("Before consent.\r\nA: café 😀.\n秘密 stays.\n".utf8)
        let official = Data("[Record begins at consent]\r\nA: café [redacted].\n秘密 stays.\n".utf8)
        let prefix = Data("Before consent.".utf8).count
        let emoji = Data("Before consent.\r\nA: café ".utf8).count
        let value = evidence(raw, official, [
            .init(startByte: 0, endByte: Int64(prefix), replacement: Data("[Record begins at consent]".utf8)),
            .init(startByte: Int64(emoji), endByte: Int64(emoji + 4), replacement: Data("[redacted]".utf8))
        ])
        let decoded = try ByteEditEvidence.decode(JSONEncoder().encode(value))
        try decoded.validate(raw: raw, official: official)
    }
    func testInsertCutAdjacentEditsAndEmptyDocuments() throws {
        for (raw, official, edits) in [
            ("", "é", [ByteEditEvidence.Edit(startByte: 0, endByte: 0, replacement: Data("é".utf8))]),
            ("é", "", [.init(startByte: 0, endByte: 2, replacement: Data())]),
            ("ab", "Xb!", [.init(startByte: 0, endByte: 1, replacement: Data("X".utf8)),
                             .init(startByte: 2, endByte: 2, replacement: Data("!".utf8))]),
            ("ab", "XY", [.init(startByte: 0, endByte: 1, replacement: Data("X".utf8)),
                            .init(startByte: 1, endByte: 2, replacement: Data("Y".utf8))]),
            ("", "", [])
        ] {
            let left = Data(raw.utf8), right = Data(official.utf8)
            try evidence(left, right, edits).validate(raw: left, official: right)
        }
    }
    func testUTF8BoundariesRejectEvenWhenByteSpliceWouldProduceValidText() throws {
        let raw = Data("é".utf8), official = Data("ê".utf8)
        // Replacing only the final byte gives a valid different character,
        // but cannot serve as a whole-character edit record.
        let value = evidence(raw, official, [.init(startByte: 1, endByte: 2, replacement: Data([0xaa]))])
        failure(.invalidRange) { try value.validate(raw: raw, official: official) }
        let leading = evidence(raw, raw, [.init(startByte: 0, endByte: 1, replacement: Data([0xc3]))])
        failure(.invalidRange) { try leading.validate(raw: raw, official: raw) }
    }
    func testMalformedUTF8NotesAndReplacementAreRejected() throws {
        let invalid = Data([0xff]), empty = Data()
        failure(.invalidUTF8) { try evidence(invalid, empty, []).validate(raw: invalid, official: empty) }
        failure(.invalidUTF8) { try evidence(empty, invalid, []).validate(raw: empty, official: invalid) }
        failure(.invalidUTF8) {
            try evidence(empty, empty, [.init(startByte: 0, endByte: 0, replacement: invalid)]).validate(raw: empty, official: empty)
        }
    }
    func testOrderOverlapAndDuplicateInsertionPositionAreRejected() throws {
        let raw = Data("abc".utf8), empty = Data()
        let invalid: [[ByteEditEvidence.Edit]] = [
            [.init(startByte: 2, endByte: 3, replacement: empty), .init(startByte: 0, endByte: 1, replacement: empty)],
            [.init(startByte: 0, endByte: 2, replacement: empty), .init(startByte: 1, endByte: 3, replacement: empty)],
            [.init(startByte: 0, endByte: 0, replacement: empty), .init(startByte: 0, endByte: 1, replacement: empty)]
        ]
        for edits in invalid {
            failure(.invalidOrder) { try evidence(raw, raw, edits).validate(raw: raw, official: raw) }
        }
    }
    func testInvalidRangesFailWithoutOverflowOrIndexTrap() throws {
        let raw = Data("abc".utf8)
        for (start, end) in [(Int64.min, 0), (0, Int64.max), (2, 1), (4, 4)] {
            failure(.invalidRange) {
                try evidence(raw, raw, [.init(startByte: start, endByte: end, replacement: Data())]).validate(raw: raw, official: raw)
            }
        }
    }
    func testStaleLengthAndSameLengthHashChangesAreRejected() throws {
        let raw = Data("raw".utf8), official = Data("new".utf8)
        let value = evidence(raw, official, [.init(startByte: 0, endByte: 3, replacement: official)])
        failure(.staleInput) { try value.validate(raw: Data("RAW".utf8), official: official) }
        failure(.staleInput) { try value.validate(raw: raw, official: Data("NEW".utf8)) }
        failure(.staleInput) { try value.validate(raw: raw + Data([0x20]), official: official) }
    }
    func testOmittedEditAndUnrecordedRewriteFailEvenWithCorrectOfficialFingerprint() throws {
        let raw = Data("one two".utf8), official = Data("ONE TWO".utf8)
        let value = evidence(raw, official, [.init(startByte: 0, endByte: 3, replacement: Data("ONE".utf8))])
        failure(.outputMismatch) { try value.validate(raw: raw, official: official) }
        failure(.outputMismatch) { try evidence(raw, official, []).validate(raw: raw, official: official) }
    }
    func testBoundsApplyToDecodeAndDirectConstruction() throws {
        let empty = Data()
        failure(.resourceLimit) { _ = try ByteEditEvidence.decode(Data(repeating: 0x20, count: ByteEditEvidence.maximumManifestBytes + 1)) }
        let large = Data(repeating: 0x61, count: ByteEditEvidence.maximumNoteBytes + 1)
        failure(.resourceLimit) { try evidence(large, empty, []).validate(raw: large, official: empty) }
        let excessive = evidence(empty, empty, Array(repeating: .init(startByte: 0, endByte: 0, replacement: empty), count: 4_097))
        failure(.resourceLimit) { try excessive.validate(raw: empty, official: empty) }
        failure(.resourceLimit) { _ = try ByteEditEvidence.decode(JSONEncoder().encode(excessive)) }
        let replacement = evidence(empty, empty, [.init(startByte: 0, endByte: 0, replacement: large)])
        failure(.resourceLimit) { try replacement.validate(raw: empty, official: empty) }
    }
    func testStrictSchemaUnknownFieldsAndCanonicalBase64() throws {
        let bytes = Data("a".utf8)
        let value = evidence(bytes, bytes, [])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object["semantic_approval"] = true
        failure(.invalidShape) { _ = try ByteEditEvidence.decode(JSONSerialization.data(withJSONObject: object)) }
        object.removeValue(forKey: "semantic_approval")
        object["schema_version"] = 2
        failure(.unsupportedSchema) { _ = try ByteEditEvidence.decode(JSONSerialization.data(withJSONObject: object)) }
        object["schema_version"] = 1
        object["edits"] = [["start_byte": 0, "end_byte": 1, "replacement_base64": "YQ==\n"]]
        failure(.invalidReplacement) { _ = try ByteEditEvidence.decode(JSONSerialization.data(withJSONObject: object)) }
    }
    func testDataSlicesAndCanonicallyEquivalentUnicodeRemainByteExact() throws {
        let container = Data("--café--".utf8)
        let raw = container[2..<(container.count - 2)]
        let official = Data("cafe\u{301}".utf8)
        failure(.outputMismatch) { try evidence(raw, official, []).validate(raw: raw, official: official) }
        try evidence(raw, official, [.init(startByte: 3, endByte: 5, replacement: Data("e\u{301}".utf8))]).validate(raw: raw, official: official)
    }
    func testActualLocalGeneratorManifestPassesNativeVerifierWithoutChangingNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("byte-evidence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = Data("Before consent.\nZoë: 😀 secret.\nTail unchanged.\n".utf8)
        let official = Data("[Record begins at consent]\nZoë: 😀 [redacted].\nTail unchanged.\n".utf8)
        let left = folder.appendingPathComponent("raw.md"), right = folder.appendingPathComponent("official.md")
        try raw.write(to: left); try official.write(to: right)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", repo.appendingPathComponent("scripts/generate-byte-edit-evidence.py").path,
                             "--raw", left.path, "--official", right.path]
        process.standardOutput = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let value = try ByteEditEvidence.decode(data)
        try value.validate(raw: raw, official: official)
        XCTAssertEqual(try Data(contentsOf: left), raw)
        XCTAssertEqual(try Data(contentsOf: right), official)
    }
}

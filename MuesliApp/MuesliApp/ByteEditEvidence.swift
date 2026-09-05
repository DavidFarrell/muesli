import Foundation
import CryptoKit

/// Evidence of an observed byte transformation only. Successful verification
/// establishes neither appropriate redaction nor speaker/consent meaning.
/// Callers provide actual bytes read by their retained file owner; this pure
/// verifier does not acquire source ownership, read files or authorize cleanup.
nonisolated struct ByteEditEvidence: Codable, Sendable {
    static let maximumNoteBytes = 8 * 1024 * 1024
    static let maximumManifestBytes = 16 * 1024 * 1024
    static let maximumEdits = 4_096
    static let kind = "observed_byte_transformation"

    enum Failure: String, Error, LocalizedError {
        case unsupportedSchema, invalidShape, resourceLimit, invalidFingerprint
        case invalidUTF8, staleInput, invalidRange, invalidOrder, invalidReplacement, outputMismatch
        var errorDescription: String? {
            switch self {
            case .unsupportedSchema: return "Unsupported byte-edit evidence version or purpose."
            case .invalidShape: return "Byte-edit evidence contains missing or unknown fields."
            case .resourceLimit: return "Byte-edit evidence exceeds its resource limits."
            case .invalidFingerprint: return "A byte-edit fingerprint is malformed."
            case .invalidUTF8: return "A note or replacement is not valid UTF-8."
            case .staleInput: return "The notes no longer match the recorded byte lengths and hashes."
            case .invalidRange: return "An edit is out of bounds or splits a UTF-8 character."
            case .invalidOrder: return "Edit ranges overlap or are not in original byte order."
            case .invalidReplacement: return "Replacement bytes are not canonical base64."
            case .outputMismatch: return "The complete recorded edits do not reproduce the official note."
            }
        }
    }

    struct Fingerprint: Codable, Sendable {
        let bytes: Int64
        let sha256: String
        init(bytes: Int64, sha256: String) { self.bytes = bytes; self.sha256 = sha256 }
        init(data: Data) { bytes = Int64(data.count); sha256 = ByteEditEvidence.digest(data) }
        enum CodingKeys: String, CodingKey, CaseIterable { case bytes, sha256 }
        init(from decoder: Decoder) throws {
            try ByteEditEvidence.exactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
            let values = try decoder.container(keyedBy: CodingKeys.self)
            bytes = try values.decode(Int64.self, forKey: .bytes)
            sha256 = try values.decode(String.self, forKey: .sha256)
        }
    }

    struct Edit: Codable, Sendable {
        /// Half-open offsets in the pristine raw UTF-8 bytes, not characters
        /// or offsets in an already-edited intermediate document.
        let startByte: Int64
        let endByte: Int64
        let replacement: Data
        init(startByte: Int64, endByte: Int64, replacement: Data) {
            self.startByte = startByte; self.endByte = endByte; self.replacement = replacement
        }
        enum CodingKeys: String, CodingKey, CaseIterable {
            case startByte = "start_byte", endByte = "end_byte", replacement = "replacement_base64"
        }
        init(from decoder: Decoder) throws {
            try ByteEditEvidence.exactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
            let values = try decoder.container(keyedBy: CodingKeys.self)
            startByte = try values.decode(Int64.self, forKey: .startByte)
            endByte = try values.decode(Int64.self, forKey: .endByte)
            let encoded = try values.decode(String.self, forKey: .replacement)
            guard encoded.utf8.count <= (ByteEditEvidence.maximumNoteBytes + 2) / 3 * 4 else {
                throw Failure.resourceLimit
            }
            guard let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded else {
                throw Failure.invalidReplacement
            }
            replacement = bytes
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(startByte, forKey: .startByte)
            try values.encode(endByte, forKey: .endByte)
            try values.encode(replacement.base64EncodedString(), forKey: .replacement)
        }
    }

    let schemaVersion: Int
    let evidenceKind: String
    let raw: Fingerprint
    let official: Fingerprint
    let edits: [Edit]
    init(raw: Fingerprint, official: Fingerprint, edits: [Edit], schemaVersion: Int = 1,
         evidenceKind: String = ByteEditEvidence.kind) {
        self.schemaVersion = schemaVersion; self.evidenceKind = evidenceKind
        self.raw = raw; self.official = official; self.edits = edits
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version", evidenceKind = "evidence_kind", raw, official, edits
    }
    init(from decoder: Decoder) throws {
        try Self.exactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        evidenceKind = try values.decode(String.self, forKey: .evidenceKind)
        raw = try values.decode(Fingerprint.self, forKey: .raw)
        official = try values.decode(Fingerprint.self, forKey: .official)
        var collection = try values.nestedUnkeyedContainer(forKey: .edits)
        var decoded: [Edit] = []
        var replacementBytes = 0
        while !collection.isAtEnd {
            guard decoded.count < Self.maximumEdits else { throw Failure.resourceLimit }
            let edit = try collection.decode(Edit.self)
            guard edit.replacement.count <= Self.maximumNoteBytes - replacementBytes else { throw Failure.resourceLimit }
            replacementBytes += edit.replacement.count
            decoded.append(edit)
        }
        edits = decoded
        try validateShape()
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumManifestBytes else { throw Failure.resourceLimit }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    /// Empty documents and insertion/cut-only transformations are legitimate.
    /// Eligibility rules for archiving a note are a separate caller contract.
    func validate(raw rawBytes: Data, official officialBytes: Data) throws {
        try validateShape()
        guard rawBytes.count <= Self.maximumNoteBytes, officialBytes.count <= Self.maximumNoteBytes else {
            throw Failure.resourceLimit
        }
        guard String(data: rawBytes, encoding: .utf8) != nil,
              String(data: officialBytes, encoding: .utf8) != nil else { throw Failure.invalidUTF8 }
        guard raw.bytes == rawBytes.count, official.bytes == officialBytes.count,
              raw.sha256 == Self.digest(rawBytes), official.sha256 == Self.digest(officialBytes) else {
            throw Failure.staleInput
        }
        var cursor = 0
        var previousStart: Int64 = -1
        var output = Data()
        output.reserveCapacity(officialBytes.count)
        for edit in edits {
            guard edit.startByte >= 0, edit.endByte >= edit.startByte, edit.endByte <= raw.bytes else {
                throw Failure.invalidRange
            }
            guard edit.startByte >= cursor, edit.startByte > previousStart else { throw Failure.invalidOrder }
            let start = Int(edit.startByte), end = Int(edit.endByte)
            guard Self.boundary(start, in: rawBytes), Self.boundary(end, in: rawBytes) else {
                throw Failure.invalidRange
            }
            guard String(data: edit.replacement, encoding: .utf8) != nil else { throw Failure.invalidUTF8 }
            try Self.append(rawBytes[(rawBytes.startIndex + cursor)..<(rawBytes.startIndex + start)],
                            to: &output, limit: officialBytes.count)
            try Self.append(edit.replacement, to: &output, limit: officialBytes.count)
            cursor = end; previousStart = edit.startByte
        }
        try Self.append(rawBytes[(rawBytes.startIndex + cursor)..<rawBytes.endIndex],
                        to: &output, limit: officialBytes.count)
        guard output == officialBytes, Self.digest(output) == official.sha256 else { throw Failure.outputMismatch }
    }

    private func validateShape() throws {
        guard schemaVersion == 1, evidenceKind == Self.kind else { throw Failure.unsupportedSchema }
        guard edits.count <= Self.maximumEdits else { throw Failure.resourceLimit }
        var total = 0
        for edit in edits {
            guard edit.replacement.count <= Self.maximumNoteBytes - total else { throw Failure.resourceLimit }
            total += edit.replacement.count
        }
        for value in [raw, official] {
            guard value.bytes >= 0, value.bytes <= Self.maximumNoteBytes else { throw Failure.resourceLimit }
            guard value.sha256.utf8.count == 64,
                  value.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.invalidFingerprint
            }
        }
    }
    private static func boundary(_ offset: Int, in bytes: Data) -> Bool {
        offset == 0 || offset == bytes.count || bytes[bytes.startIndex + offset] & 0xc0 != 0x80
    }
    private static func append(_ bytes: Data, to output: inout Data, limit: Int) throws {
        guard bytes.count <= limit - output.count else { throw Failure.outputMismatch }
        output.append(bytes)
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private static func exactKeys(_ decoder: Decoder, _ expected: [String]) throws {
        let actual = try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)
        guard Set(actual) == Set(expected) else { throw Failure.invalidShape }
    }
}

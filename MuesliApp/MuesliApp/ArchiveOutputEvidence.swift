import Foundation

/// Checks actual saved note bytes and declared provenance against native input
/// observations. This is neither a semantic correctness judgment nor permission
/// to move a source. The final owner must retain and revalidate all file owners.
nonisolated enum ArchiveOutputEvidence {
    struct Failure: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }
    /// Native copier observations, never decoded from a model-written receipt.
    /// Construction belongs to the retained source/copy worker, which must bind
    /// source ledger, source bytes and actual destination identity independently.
    struct CopiedImage: Sendable {
        let sourceSessionID: UUID
        let assetID: UUID
        let sourceRelativePath: String
        let timelineSeconds: Double
        let source: ArchiveReceipt.FileRecord
        let copied: ArchiveReceipt.FileRecord
        var vaultPath: String { "MuesliAssets/\(sourceSessionID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).png" }
    }
    struct Verified: Sendable { let noteCount: Int; let speakerClaimCount: Int; let imageReferenceCount: Int }
    private struct Provenance: Decodable {
        let schemaVersion: Int; let operationID: UUID
        let notes: [Note]; let speakerClaims: [Claim]; let images: [Image]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", operationID = "operation_id", notes
            case speakerClaims = "speaker_claims", images
        }
    }
    private struct Note: Decodable {
        let noteID: String; let sourceSessionIDs: [UUID]
        enum CodingKeys: String, CodingKey { case noteID = "note_id", sourceSessionIDs = "source_session_ids" }
    }
    private struct Claim: Decodable {
        let sourceSessionID: UUID; let stream: String; let speakerID: String
        let name: String?; let basis: String; let evidence: String; let uncertainty: String
        enum CodingKeys: String, CodingKey {
            case sourceSessionID = "source_session_id", stream, speakerID = "speaker_id", name, basis, evidence, uncertainty
        }
        var key: ArchiveProcessingEvidence.SpeakerKey { .init(sourceSessionID: sourceSessionID, stream: stream, speakerID: speakerID) }
    }
    private struct Image: Decodable, Hashable {
        let noteID: String; let variant: String; let sourceSessionID: UUID; let assetID: UUID; let vaultPath: String
        enum CodingKeys: String, CodingKey {
            case noteID = "note_id", variant, sourceSessionID = "source_session_id", assetID = "asset_id", vaultPath = "vault_path"
        }
    }

    /// All inputs other than `receipt` come from native retained workers. Run
    /// this before the receipt's broader file scan to enforce aggregate bounds.
    /// Callers must still call receipt.validate with a fresh exhaustive source.
    static func validate(receipt: ArchiveReceipt, processing: ArchiveProcessingEvidence.Verified,
                         nativeEvents: ArchiveReceipt.FileRecord, copiedImages: [CopiedImage], vaultURL: URL) throws -> Verified {
        try require(receipt.schemaVersion == 2 && receipt.cleanup == .retained, "Unsupported or already committed handoff.")
        try require(receipt.outputs.count <= 4096 && Set(receipt.outputs.map { $0.file.path }).count == receipt.outputs.count,
                    "Saved outputs are duplicated or exceed their limit.")
        let vault = vaultURL.path
        try require(canonical(vault), "The vault path is not canonical.")
        var total: Int64 = 0, semantic: Int64 = 0
        for output in receipt.outputs {
            let bytes = output.file.bytes
            try require(bytes >= 0 && bytes <= 512 * 1024 * 1024 - total, "Saved output evidence exceeds its aggregate budget.")
            total += bytes
            let limit: Int64
            switch output.role {
            case .rawNote, .officialNote: limit = 8 * 1024 * 1024
            case .redactionReport: limit = 16 * 1024 * 1024
            case .speakerProvenance: limit = 2 * 1024 * 1024
            case .reprocessEvents: limit = 64 * 1024 * 1024
            case .reprocessDiagnostics: limit = 16 * 1024 * 1024
            case .attachment: limit = 128 * 1024 * 1024
            }
            try require(bytes <= limit, "A saved output exceeds its role's size limit.")
            if [.rawNote, .officialNote, .redactionReport, .speakerProvenance].contains(output.role) {
                try require(bytes <= 128 * 1024 * 1024 - semantic, "Note evidence exceeds its aggregate read budget."); semantic += bytes
            }
        }
        let event = try one(receipt, .reprocessEvents, nil)
        try require(event.file.bytes == nativeEvents.bytes && event.file.sha256 == nativeEvents.sha256,
                    "The saved processing log is not the native completed process's evidence.")
        try require(try ArchiveReceipt.readFingerprint(at: URL(fileURLWithPath: event.file.path), maximumBytes: 64 * 1024 * 1024) == event.file,
                    "The saved processing evidence changed.")
        let sidecar = try one(receipt, .speakerProvenance, nil)
        let provenance = try decode(ArchiveReceipt.readVerifiedData(sidecar.file, maximumBytes: 2 * 1024 * 1024))
        try require(provenance.schemaVersion == 1 && provenance.operationID == receipt.operationID, "Provenance belongs to another operation.")
        let noteRoles: Set<ArchiveReceipt.Output.Role> = [.rawNote, .officialNote, .redactionReport]
        let noteIDs = Set(receipt.outputs.filter { noteRoles.contains($0.role) }.compactMap(\.noteID))
        try require(!noteIDs.isEmpty && noteIDs.count <= 256 && provenance.notes.count == noteIDs.count
                    && Set(provenance.notes.map(\.noteID)) == noteIDs, "Note provenance does not cover exactly the saved note groups.")
        var covered: Set<UUID> = []
        for note in provenance.notes {
            try require(short(note.noteID, 256) && !note.sourceSessionIDs.isEmpty && note.sourceSessionIDs.count <= 128
                        && Set(note.sourceSessionIDs).count == note.sourceSessionIDs.count
                        && Set(note.sourceSessionIDs).isSubset(of: processing.sourceSessionIDs), "A note's source coverage is missing or ambiguous.")
            covered.formUnion(note.sourceSessionIDs)
        }
        try require(covered == processing.sourceSessionIDs, "Note declarations omit a processed source.")
        try require(provenance.speakerClaims.count <= 4096 && provenance.speakerClaims.count == processing.speakerKeys.count
                    && Set(provenance.speakerClaims.map(\.key)) == processing.speakerKeys, "Speaker claims must cover every native source/stream/speaker tuple exactly once.")
        for claim in provenance.speakerClaims {
            try require(claim.basis == "inferred" && short(claim.speakerID, 256)
                        && short(claim.uncertainty, 1024) && claim.evidence.utf8.count <= 1024,
                        "Speaker names must retain their inference basis and uncertainty.")
            if let name = claim.name { try require(short(name, 256) && short(claim.evidence, 1024), "A named speaker needs explicit supporting evidence.") }
        }
        try require(copiedImages.count <= 4096 && Set(copiedImages.map(\.vaultPath)).count == copiedImages.count,
                    "Native copied-image inventory is duplicated or too large.")
        var images: [String: CopiedImage] = [:]
        for image in copiedImages {
            try require(processing.sourceSessionIDs.contains(image.sourceSessionID) && image.timelineSeconds.isFinite && image.timelineSeconds >= 0
                        && image.sourceRelativePath == "artifacts/\(image.sourceSessionID.uuidString)/screenshots/\(image.assetID.uuidString).png"
                        && image.source.path == image.sourceRelativePath && image.source.bytes > 0
                        && image.source.bytes == image.copied.bytes && image.source.sha256 == image.copied.sha256
                        && image.copied.path == vault + "/" + image.vaultPath, "Native copied-image evidence is inconsistent.")
            images[image.vaultPath] = image
        }
        try require(provenance.images.count <= 4096 && Set(provenance.images).count == provenance.images.count,
                    "Image references are duplicated or exceed their limit.")
        var referencedPaths: Set<String> = []
        for reference in provenance.images {
            guard let image = images[reference.vaultPath], let note = provenance.notes.first(where: { $0.noteID == reference.noteID }) else {
                throw Failure(message: "An image reference has no native copied source or note.")
            }
            try require(["raw", "official"].contains(reference.variant) && image.sourceSessionID == reference.sourceSessionID
                        && image.assetID == reference.assetID && note.sourceSessionIDs.contains(reference.sourceSessionID),
                        "An image is attributed to the wrong source or note variant.")
            referencedPaths.insert(image.copied.path)
        }
        let attachments = receipt.outputs.filter { $0.role == .attachment }
        try require(Set(attachments.map { $0.file.path }) == referencedPaths && attachments.count == referencedPaths.count,
                    "Saved attachments must match the referenced native copies exactly.")
        for attachment in attachments {
            guard let copied = copiedImages.first(where: { $0.copied.path == attachment.file.path }) else { throw Failure(message: "Unknown copied image.") }
            try require(attachment.file == copied.copied, "An attachment differs from the native copy observation.")
            try require(try ArchiveReceipt.readFingerprint(at: URL(fileURLWithPath: attachment.file.path), maximumBytes: 128 * 1024 * 1024) == copied.copied,
                        "A copied image changed after native copying.")
        }
        for noteID in noteIDs {
            let raw = try one(receipt, .rawNote, noteID), official = try one(receipt, .officialNote, noteID)
            let edits = try one(receipt, .redactionReport, noteID)
            try require(raw.file.path.hasPrefix(vault + "/") && official.file.path.hasPrefix(vault + "/"), "Notes must be inside the selected vault.")
            let rawBytes = try ArchiveReceipt.readVerifiedData(raw.file, maximumBytes: 8 * 1024 * 1024)
            let officialBytes = try ArchiveReceipt.readVerifiedData(official.file, maximumBytes: 8 * 1024 * 1024)
            let editBytes = try ArchiveReceipt.readVerifiedData(edits.file, maximumBytes: 16 * 1024 * 1024)
            try ArchiveSourceJSON.check(editBytes)
            try ByteEditEvidence.decode(editBytes).validate(raw: rawBytes, official: officialBytes)
            for (variant, bytes) in [("raw", rawBytes), ("official", officialBytes)] {
                let actual = try imageLinks(bytes)
                let expected = provenance.images.filter { $0.noteID == noteID && $0.variant == variant }.map(\.vaultPath)
                try require(actual.count == expected.count && Set(actual) == Set(expected), "Actual saved image links differ from their provenance declarations.")
            }
        }
        return Verified(noteCount: noteIDs.count, speakerClaimCount: provenance.speakerClaims.count, imageReferenceCount: provenance.images.count)
    }

    /// Deliberately conservative supported Markdown subset. All embeds must be
    /// canonical vault-relative PNG wiki embeds. Ambiguous HTML, markdown image
    /// syntax, escapes and aliases require review instead of inferred rendering.
    static func imageLinks(_ bytes: Data) throws -> [String] {
        try require(bytes.count <= 8 * 1024 * 1024, "Note is too large.")
        guard let text = String(data: bytes, encoding: .utf8) else { throw Failure(message: "Note is not UTF-8.") }
        try require(!text.contains("<") && !text.contains("\\") && !text.contains("! [") && !text.contains("![^"), "Unsupported image or HTML syntax requires review.")
        var cursor = text.startIndex, found: [String] = []
        while let start = text.range(of: "![", range: cursor..<text.endIndex) {
            try require(text[start.lowerBound...].hasPrefix("![["), "Only canonical wiki image embeds are supported.")
            let body = text.index(start.lowerBound, offsetBy: 3)
            guard let end = text.range(of: "]]", range: body..<text.endIndex) else { throw Failure(message: "Incomplete image embed.") }
            let path = String(text[body..<end.lowerBound]), pieces = path.split(separator: "/", omittingEmptySubsequences: false)
            try require(pieces.count == 3 && pieces[0] == "MuesliAssets" && pieces[2].hasSuffix(".png"), "Image path is not canonical.")
            let source = String(pieces[1]), asset = String(pieces[2].dropLast(4))
            try require(UUID(uuidString: source)?.uuidString.lowercased() == source && UUID(uuidString: asset)?.uuidString.lowercased() == asset,
                        "Image identity is not canonical.")
            try require(found.count < 4096 && !found.contains(path), "Image embeds are duplicated or exceed their limit.")
            found.append(path); cursor = end.upperBound
        }
        return found
    }
    private static func decode(_ bytes: Data) throws -> Provenance {
        try require(bytes.count <= 2 * 1024 * 1024, "Provenance exceeds its limit.")
        try ArchiveSourceJSON.check(bytes)
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure(message: "Provenance is not an object.") }
        try exact(value, ["schema_version", "operation_id", "notes", "speaker_claims", "images"])
        for (key, fields, limit) in [
            ("notes", ["note_id", "source_session_ids"], 256),
            ("speaker_claims", ["source_session_id", "stream", "speaker_id", "name", "basis", "evidence", "uncertainty"], 4096),
            ("images", ["note_id", "variant", "source_session_id", "asset_id", "vault_path"], 4096)
        ] {
            guard let entries = value[key] as? [[String: Any]], entries.count <= limit else { throw Failure(message: "Provenance collection is invalid or too large.") }
            for entry in entries { try exact(entry, fields) }
        }
        return try JSONDecoder().decode(Provenance.self, from: bytes)
    }
    private static func one(_ receipt: ArchiveReceipt, _ role: ArchiveReceipt.Output.Role, _ noteID: String?) throws -> ArchiveReceipt.Output {
        let matches = receipt.outputs.filter { $0.role == role && $0.noteID == noteID }
        try require(matches.count == 1, "A required output is missing or duplicated."); return matches[0]
    }
    private static func exact(_ value: [String: Any], _ keys: [String]) throws { try require(Set(value.keys) == Set(keys), "Provenance has missing or unknown fields.") }
    private static func short(_ value: String, _ limit: Int) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit }
    private static func canonical(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
}

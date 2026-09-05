import Foundation

nonisolated enum AttachmentType: String, Codable, Sendable {
    case image
    case text
}

nonisolated struct Attachment: Identifiable, Codable, Sendable {
    let id: UUID
    let type: AttachmentType
    let timestamp: Double  // shared meeting timeline; legacy files retain their original unknown scope
    let filename: String   // unique immutable filename; old timestamp filenames remain readable
    let sourceSessionID: String?
    let byteCount: Int?
    let sha256: String?
    let createdAt: Date

    init(id: UUID = UUID(), type: AttachmentType, timestamp: Double, filename: String, createdAt: Date = Date(), sourceSessionID: String? = nil, byteCount: Int? = nil, sha256: String? = nil) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.filename = filename
        self.createdAt = createdAt
        self.sourceSessionID = sourceSessionID
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

nonisolated struct AttachmentsManifest: Codable, Sendable {
    var attachments: [Attachment]
}

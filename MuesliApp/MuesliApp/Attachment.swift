import Foundation

enum AttachmentType: String, Codable {
    case image
    case text
}

struct Attachment: Identifiable, Codable {
    let id: UUID
    let type: AttachmentType
    let timestamp: Double  // seconds since meeting start
    let filename: String   // e.g., "t+0000005.123.png" or "t+0000005.123.txt"
    let createdAt: Date

    init(id: UUID = UUID(), type: AttachmentType, timestamp: Double, filename: String, createdAt: Date = Date()) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.filename = filename
        self.createdAt = createdAt
    }
}

struct AttachmentsManifest: Codable {
    var attachments: [Attachment]
}

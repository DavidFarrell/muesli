import Foundation

/// Existing speaker-ID screenshots are a legacy input. The bounded folder
/// snapshot and its later image reads share one archive-exclusion reference.
nonisolated struct MeetingScreenshotInput: Sendable {
    let urls: [URL]
    let access: MeetingFileAccess

    static func snapshot(context: TranscriptPersistenceStore.Context) throws -> MeetingScreenshotInput {
        let folder = context.folder.appendingPathComponent("screenshots", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
            return MeetingScreenshotInput(urls: [], access: context.access)
        }
        guard isDirectory.boolValue else { throw CocoaError(.fileReadCorruptFile) }
        // Nonrecursive enumeration; a malformed meeting cannot queue unlimited
        // downstream image reads. Image selection remains the identifier's job.
        guard let entries = FileManager.default.enumerator(at: folder,
            includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else {
            throw CocoaError(.fileReadUnknown)
        }
        var urls: [URL] = []
        var count = 0
        for case let url as URL in entries {
            count += 1
            guard count <= 10_000 else { throw CocoaError(.fileReadTooLarge) }
            if ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) { urls.append(url) }
        }
        return MeetingScreenshotInput(urls: urls.sorted { $0.lastPathComponent < $1.lastPathComponent }, access: context.access)
    }
}

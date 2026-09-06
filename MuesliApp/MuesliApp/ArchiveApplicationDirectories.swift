import Foundation
import Darwin

/// Fixed native support locations. Bootstrap runs on the listener's retained
/// worker; it neither changes existing permissions nor keeps hidden file owners.
nonisolated enum ArchiveApplicationDirectories {
    struct Paths: Sendable, Equatable {
        let base: URL
        var endpoint: URL { base.appendingPathComponent("ArchiveBridge", isDirectory: true) }
        var output: URL { base.appendingPathComponent("ArchiveOperations", isDirectory: true) }
        var journal: URL { base.appendingPathComponent("ArchiveJournal", isDirectory: true) }
        static var standard: Paths { Paths(base: ArchiveWorkflowSocket.defaultDirectory().deletingLastPathComponent()) }
    }
    struct Failure: Error, Sendable { }

    static func ensure(_ paths: Paths) throws {
        let path = paths.base.path
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !components.isEmpty, components.count <= 128,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw Failure() }
        var descriptors: [Int32] = []
        var links: [(Int32, String, Int32)] = []
        defer { descriptors.reversed().forEach { Darwin.close($0) } }
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw Failure() }
        descriptors.append(root)
        for (index, name) in components.enumerated() {
            let parent = descriptors.last!
            // The selected native base's ancestors must already exist. Existing
            // Muesli installations may have a 0755 base; private children below
            // it provide the endpoint/output boundary without chmod migration.
            if index == components.count - 1 {
                guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw Failure() }
            }
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw Failure() }
            descriptors.append(child); links.append((parent, name, child))
            try validateLink(parent, name, child)
        }
        let base = descriptors.last!
        var info = stat()
        guard fstat(base, &info) == 0, info.st_uid == geteuid() else { throw Failure() }
        for name in ["ArchiveBridge", "ArchiveOperations", "ArchiveJournal"] {
            guard mkdirat(base, name, 0o700) == 0 || errno == EEXIST else { throw Failure() }
            let child = openat(base, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw Failure() }
            descriptors.append(child); links.append((base, name, child))
            try validateLink(base, name, child)
            guard fstat(child, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw Failure() }
            try synchronize(child)
        }
        try synchronize(base)
        // Reused paths must also cross the durability barrier: a previous
        // failed bootstrap may have created the name before its sync failed.
        try synchronize(links[components.count - 1].0)
        for (parent, name, child) in links { try validateLink(parent, name, child) }
    }
    private static func validateLink(_ parent: Int32, _ name: String, _ child: Int32) throws {
        var named = stat(), opened = stat()
        guard fstat(child, &opened) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else { throw Failure() }
    }
    private static func synchronize(_ fd: Int32) throws {
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw Failure() }
    }
}

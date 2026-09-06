import XCTest
import Darwin

final class ArchiveApplicationDirectoriesTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/archive-app-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func mode(_ url: URL) throws -> mode_t {
        var value = stat(); guard lstat(url.path, &value) == 0 else { throw ArchiveApplicationDirectories.Failure() }
        return value.st_mode & 0o777
    }
    func testExistingInstallationBaseKeepsModeAndPrivateRootsAreReusable() throws {
        let root = try fixture(), base = root.appendingPathComponent("Muesli")
        XCTAssertEqual(mkdir(base.path, 0o755), 0)
        let paths = ArchiveApplicationDirectories.Paths(base: base)
        try ArchiveApplicationDirectories.ensure(paths)
        try ArchiveApplicationDirectories.ensure(paths)
        XCTAssertEqual(try mode(base), 0o755)
        for child in [paths.endpoint, paths.output, paths.journal] { XCTAssertEqual(try mode(child), 0o700) }
    }
    func testCreatesOnlyFinalNativeBaseAndRefusesMissingAncestor() throws {
        let root = try fixture(), base = root.appendingPathComponent("Muesli")
        try ArchiveApplicationDirectories.ensure(.init(base: base))
        XCTAssertEqual(try mode(base), 0o700)
        let absent = root.appendingPathComponent("missing/Muesli")
        XCTAssertThrowsError(try ArchiveApplicationDirectories.ensure(.init(base: absent)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }
    func testSymlinkBaseOrPrivateRootIsRefusedWithoutFollowingIt() throws {
        let root = try fixture(), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let base = root.appendingPathComponent("Muesli")
        try FileManager.default.createSymbolicLink(at: base, withDestinationURL: target)
        XCTAssertThrowsError(try ArchiveApplicationDirectories.ensure(.init(base: base)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        try FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("ArchiveBridge"), withDestinationURL: target)
        XCTAssertThrowsError(try ArchiveApplicationDirectories.ensure(.init(base: base)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
    func testExistingBroadPrivateDirectoryIsPreservedAndRefused() throws {
        let root = try fixture(), paths = ArchiveApplicationDirectories.Paths(base: root)
        XCTAssertEqual(mkdir(paths.endpoint.path, 0o755), 0)
        XCTAssertThrowsError(try ArchiveApplicationDirectories.ensure(paths))
        XCTAssertEqual(try mode(paths.endpoint), 0o755)
    }
    func testDefaultEndpointMatchesPackagedCLI() {
        XCTAssertEqual(ArchiveApplicationDirectories.Paths.standard.endpoint, ArchiveWorkflowSocket.defaultDirectory())
    }
}

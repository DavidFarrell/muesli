import Foundation
import CryptoKit
import Darwin

/// Expectations from the signed app package. The authenticated service still
/// verifies its complete sealed payload before returning a source-free reservation.
nonisolated struct PackagedInferenceRuntime: Sendable {
    let runtimeManifestSHA256: Data
    let modelManifestSHA256: Data

    private struct Package: Decodable {
        let schemaVersion: Int
        let appBuildID: String
        let sourceCommit: String
        let sourceTreeSHA256: String
        let runtimeSHA256: String
        let modelsSHA256: String
        let clientIdentifier: String
        let signingTeam: String
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", appBuildID = "app_build_id"
            case sourceCommit = "source_commit", sourceTreeSHA256 = "source_tree_sha256"
            case runtimeSHA256 = "runtime_manifest_sha256", modelsSHA256 = "model_manifest_sha256"
            case clientIdentifier = "inference_client_identifier", signingTeam = "signing_team"
        }
    }

    /// Called on the retained preparation worker, never on the UI or capture queue.
    static func load(bundle: Bundle = .main, build: BuildIdentity = .current) throws -> Self {
        let contents = bundle.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let recordURL = contents.appendingPathComponent("Resources/local-runtime-package.json")
        let record: Package
        do {
            record = try JSONDecoder().decode(Package.self, from: readRegular(recordURL, maximumBytes: 1024 * 1024))
        } catch {
            throw BackendAdmissionOwner.Failure(message: "This build does not contain a verified local transcription package.")
        }
        guard record.schemaVersion == 1, build.sourceDirty == false,
              record.appBuildID == build.buildID, record.sourceCommit == build.sourceCommit,
              record.sourceTreeSHA256 == build.sourceTreeSHA256,
              record.clientIdentifier == "paidiaconsulting.MuesliApp", record.signingTeam == "JA9EPB8K4N" else {
            throw BackendAdmissionOwner.Failure(message: "The local transcription package does not match this app build.")
        }
        let resources = contents.appendingPathComponent("XPCServices/paidiaconsulting.MuesliApp.InferenceService.xpc/Contents/Resources", isDirectory: true)
        let runtime = Data(SHA256.hash(data: try readRegular(resources.appendingPathComponent("runtime-manifest.json"), maximumBytes: 8 * 1024 * 1024)))
        let models = Data(SHA256.hash(data: try readRegular(resources.appendingPathComponent("model-manifest.json"), maximumBytes: 8 * 1024 * 1024)))
        guard hex(runtime) == record.runtimeSHA256, hex(models) == record.modelsSHA256 else {
            throw BackendAdmissionOwner.Failure(message: "The local transcription runtime or model manifest changed.")
        }
        return Self(runtimeManifestSHA256: runtime, modelManifestSHA256: models)
    }

    private static func readRegular(_ url: URL, maximumBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= maximumBytes,
              let data = try handle.read(upToCount: maximumBytes + 1), data.count == info.st_size else {
            throw BackendAdmissionOwner.Failure(message: "The local transcription package contains an invalid manifest.")
        }
        return data
    }

    private static func hex(_ value: Data) -> String { value.map { String(format: "%02x", $0) }.joined() }
}

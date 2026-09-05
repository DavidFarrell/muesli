import Foundation

/// Build inputs are expectations, never evidence about the selected external runtime.
nonisolated struct BuildIdentity: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let buildID: String
    let sourceCommit: String?
    let sourceDirty: Bool?
    let sourceTreeSHA256: String?
    let expectedInputSHA256: [String: String?]
    let schemas: [String: Int]
    let buildSettings: [String: String]

    static let current: BuildIdentity = {
        guard let data = Data(base64Encoded: EmbeddedBuildIdentity.base64),
              let value = try? JSONDecoder().decode(BuildIdentity.self, from: data) else {
            preconditionFailure("Generated build identity is invalid")
        }
        return value
    }()

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", buildID = "build_id"
        case sourceCommit = "source_commit", sourceDirty = "source_dirty"
        case sourceTreeSHA256 = "source_tree_sha256"
        case expectedInputSHA256 = "expected_input_sha256", schemas
        case buildSettings = "build_settings"
    }
}

/// Files/versions observed by the process before inference, not proof of loaded
/// model state, code-signing, license compliance or equivalence to the build lock.
nonisolated struct ObservedRuntimeIdentity: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let observation: String
    let pythonVersion: String
    let executableSHA256: String?
    let backendSHA256: String?
    let packageVersions: [String: String]
    let modelAssetsSHA256: [String: String]
    let modelObservation: String
    var packageSourceCommits: [String: String]? = nil
    var selectedToolsSHA256: [String: String]? = nil

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", observation
        case pythonVersion = "python_version", executableSHA256 = "executable_sha256"
        case backendSHA256 = "backend_sha256", packageVersions = "package_versions"
        case modelAssetsSHA256 = "model_assets_sha256", modelObservation = "model_observation"
        case packageSourceCommits = "package_source_commits", selectedToolsSHA256 = "selected_tools_sha256"
    }

    struct Event: Decodable {
        let type: String
        let sourceSessionID: String?
        let identity: ObservedRuntimeIdentity
        enum CodingKeys: String, CodingKey {
            case type, identity, sourceSessionID = "source_session_id"
        }
    }

    static func event(_ line: String, sourceSessionID: String) -> ObservedRuntimeIdentity? {
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)),
              event.type == "runtime_identity", event.sourceSessionID == sourceSessionID,
              event.identity.isSafeDiagnosticValue else { return nil }
        return event.identity
    }

    /// The external runtime is untrusted. Do not let an arbitrary event smuggle
    /// paths or meeting contents into the default diagnostic export.
    var isSafeDiagnosticValue: Bool {
        let packages: Set<String> = ["parakeet-mlx", "mlx", "mlx-metal", "senko", "coremltools", "numpy", "soundfile", "librosa", "numba", "llvmlite", "huggingface-hub"]
        let models: Set<String> = ["asr_config", "asr_weights", "senko_assets"]
        let tools: Set<String> = ["ffmpeg", "python_shared_library"]
        func hex(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
        func version(_ value: String) -> Bool {
            value.first.map { "0123456789".contains($0) } == true && value.count <= 64 && value.allSatisfy { "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+_-".contains($0) }
        }
        return schemaVersion == 1 && observation == "process_preflight"
            && ["selected_files_hashed", "unavailable"].contains(modelObservation)
            && version(pythonVersion) && executableSHA256.map(hex) != false && backendSHA256.map(hex) != false
            && packageVersions.allSatisfy { packages.contains($0.key) && version($0.value) }
            && modelAssetsSHA256.allSatisfy { models.contains($0.key) && hex($0.value) }
            && (selectedToolsSHA256 ?? [:]).allSatisfy { tools.contains($0.key) && hex($0.value) }
            && (packageSourceCommits ?? [:]).allSatisfy {
                packages.contains($0.key) && [40, 64].contains($0.value.count)
                    && $0.value.allSatisfy { "0123456789abcdef".contains($0) }
            }
    }
}

nonisolated enum BuildDiagnostic {
    /// No paths, names, raw error messages, transcript content or log tail.
    static func summary(build: BuildIdentity = .current, runtime: ObservedRuntimeIdentity?,
                        counters: [String: Int], sandboxed: Bool) -> String {
        struct Report: Encodable {
            let build: BuildIdentity
            let observedRuntime: ObservedRuntimeIdentity?
            let counters: [String: Int]
            let sandboxed: Bool
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = Report(build: build, observedRuntime: runtime?.isSafeDiagnosticValue == true ? runtime : nil,
                            counters: counters, sandboxed: sandboxed)
        return (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "Diagnostic encoding failed."
    }
}

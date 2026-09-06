import Foundation

/// The wire protocol carries requests and observations, never native completion proof.
nonisolated enum ArchiveWorkflowProtocol {
    static let version = 1
    static let maximumMessageBytes = 16 * 1024
    static let maximumPathBytes = 4_096

    enum Failure: String, Error, Codable, Sendable {
        case invalidRequest, busy, unknownOperation, notReady, stopping
        case preparationFailed, admissionRejected, validationFailed, uncertain
        case transportUnavailable, transportTimeout, unsafeEndpoint
    }
    enum Command: String, Codable, Sendable { case begin, status, finalize, abandon }
    struct Request: Sendable {
        let command: Command
        let operationID: UUID?
        let sourcePath: String?
        let vaultPath: String?
        let receiptPath: String?

        static func begin(sourcePath: String, vaultPath: String) -> Self {
            Self(command: .begin, operationID: nil, sourcePath: sourcePath, vaultPath: vaultPath, receiptPath: nil)
        }
        static func operation(_ command: Command, id: UUID, receiptPath: String? = nil) -> Self {
            Self(command: command, operationID: id, sourcePath: nil, vaultPath: nil, receiptPath: receiptPath)
        }
        func encode() throws -> Data {
            var fields: [String: Any] = ["protocol_version": version, "command": command.rawValue]
            if let operationID { fields["operation_id"] = operationID.uuidString.lowercased() }
            if let sourcePath { fields["source_path"] = sourcePath }
            if let vaultPath { fields["vault_path"] = vaultPath }
            if let receiptPath { fields["receipt_path"] = receiptPath }
            let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            _ = try Self.decode(data)
            return data
        }
        /// Deliberately flat JSON (numeric version, string arguments): parsing rejects duplicate
        /// and escaped-alias keys, nesting and unknown fields before admission.
        static func decode(_ data: Data) throws -> Self {
            var parser = FlatParser(bytes: Array(data))
            let fields = try parser.parse()
            guard fields["protocol_version"] == String(version),
                  let raw = fields["command"], let command = Command(rawValue: raw) else { throw Failure.invalidRequest }
            var keys: Set<String> = ["protocol_version", "command"]
            switch command {
            case .begin: keys.formUnion(["source_path", "vault_path"])
            case .status, .abandon: keys.insert("operation_id")
            case .finalize: keys.formUnion(["operation_id", "receipt_path"])
            }
            guard Set(fields.keys) == keys else { throw Failure.invalidRequest }
            for key in ["source_path", "vault_path", "receipt_path"] {
                if let path = fields[key] { try validatePath(path) }
            }
            let operationID = fields["operation_id"].flatMap(UUID.init(uuidString:))
            if command != .begin && operationID == nil { throw Failure.invalidRequest }
            return Self(command: command, operationID: operationID, sourcePath: fields["source_path"],
                        vaultPath: fields["vault_path"], receiptPath: fields["receipt_path"])
        }
    }
    enum State: String, Codable, Sendable {
        case preparing, awaitingOutputs, finalizing, retained, trashed, uncertain, failed, abandoned
    }
    struct Response: Codable, Sendable {
        let protocolVersion: Int
        let operationID: UUID?
        let state: State?
        let outputManifestPath: String?
        let failure: Failure?
        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version", operationID = "operation_id", state
            case outputManifestPath = "output_manifest_path", failure
        }
        init(operationID: UUID? = nil, state: State? = nil, outputManifestPath: String? = nil, failure: Failure? = nil) {
            protocolVersion = version; self.operationID = operationID; self.state = state
            self.outputManifestPath = outputManifestPath; self.failure = failure
        }
        func encoded() throws -> Data {
            let data = try JSONEncoder().encode(self)
            guard data.count <= maximumMessageBytes else { throw Failure.invalidRequest }
            return data
        }
    }
    static func validatePath(_ value: String) throws {
        guard value.hasPrefix("/"), value.utf8.count <= maximumPathBytes,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !value.split(separator: "/").contains("..") else { throw Failure.invalidRequest }
    }
    private struct FlatParser {
        let bytes: [UInt8]
        var index = 0
        mutating func parse() throws -> [String: String] {
            guard bytes.count <= maximumMessageBytes else { throw Failure.invalidRequest }
            try take(123)
            var fields: [String: String] = [:]
            while true {
                let key = try string(); try take(58)
                let value: String
                if key == "protocol_version" {
                    space(); let start = index
                    while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
                    guard index == start + 1 else { throw Failure.invalidRequest }
                    value = String(decoding: bytes[start..<index], as: UTF8.self)
                } else { value = try string() }
                guard fields.count < 6, fields.updateValue(value, forKey: key) == nil else { throw Failure.invalidRequest }
                space()
                if index < bytes.count && bytes[index] == 125 { index += 1; break }
                try take(44)
            }
            space(); guard index == bytes.count else { throw Failure.invalidRequest }
            return fields
        }
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) throws {
            space(); guard index < bytes.count && bytes[index] == byte else { throw Failure.invalidRequest }; index += 1
        }
        mutating func string() throws -> String {
            space(); let start = index; try take(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                if byte == 92 { guard index < bytes.count else { throw Failure.invalidRequest }; index += 1 }
            }
            throw Failure.invalidRequest
        }
    }
}

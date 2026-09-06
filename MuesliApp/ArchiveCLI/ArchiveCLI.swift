import Foundation
import Darwin

/// Only relays the four fixed operations to the running app. Cannot execute
/// a backend, manufacture proof, or move a source itself.
@main
struct ArchiveCLI {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let request: ArchiveWorkflowProtocol.Request
            switch arguments.first {
            case "begin" where arguments.count == 3:
                request = .begin(sourcePath: arguments[1], vaultPath: arguments[2])
            case "status" where arguments.count == 2, "abandon" where arguments.count == 2:
                guard let id = UUID(uuidString: arguments[1]),
                      let command = ArchiveWorkflowProtocol.Command(rawValue: arguments[0]) else {
                    throw ArchiveWorkflowProtocol.Failure.invalidRequest
                }
                request = .operation(command, id: id)
            case "finalize" where arguments.count == 3:
                guard let id = UUID(uuidString: arguments[1]) else { throw ArchiveWorkflowProtocol.Failure.invalidRequest }
                request = .operation(.finalize, id: id, receiptPath: arguments[2])
            default: throw ArchiveWorkflowProtocol.Failure.invalidRequest
            }
            let response = try ArchiveWorkflowSocket.request(request)
            try FileHandle.standardOutput.write(contentsOf: response.encoded() + Data([10]))
            exit(response.failure == nil ? 0 : 1)
        } catch {
            let failure = (error as? ArchiveWorkflowProtocol.Failure) ?? .transportUnavailable
            let response = ArchiveWorkflowProtocol.Response(failure: failure)
            if let data = try? response.encoded() { try? FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
            // No private source paths or note content is included in diagnostics.
            exit(1)
        }
    }
}

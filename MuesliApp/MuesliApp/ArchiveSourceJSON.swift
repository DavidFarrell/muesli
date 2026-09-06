import Foundation

/// JSONDecoder otherwise accepts duplicate object keys. Reject that ambiguity
/// (including escaped aliases) before typed decoding, with a finite depth/node
/// budget. Typed decoding still validates JSON primitive syntax and fields.
nonisolated enum ArchiveSourceJSON {
    static func check(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.value(depth: 0)
        parser.space()
        try parser.require(parser.index == parser.bytes.count)
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func require(_ condition: Bool) throws {
            if !condition { throw ArchiveSourceEligibility.Failure(message: "Source JSON is malformed, ambiguous or exceeds its structural limit.") }
        }
        mutating func take(_ byte: UInt8) throws { space(); try require(index < bytes.count && bytes[index] == byte); index += 1 }
        mutating func value(depth: Int) throws {
            nodes += 1; space()
            try require(depth <= 48 && nodes <= 200_000 && index < bytes.count)
            switch bytes[index] {
            case 123:
                index += 1; space(); var keys: Set<String> = []
                if index < bytes.count && bytes[index] == 125 { index += 1; return }
                while true {
                    space(); let key = try string()
                    try require(keys.insert(key).inserted)
                    try take(58); try value(depth: depth + 1); space()
                    try require(index < bytes.count)
                    if bytes[index] == 125 { index += 1; return }
                    try take(44)
                }
            case 91:
                index += 1; space()
                if index < bytes.count && bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); space(); try require(index < bytes.count)
                    if bytes[index] == 93 { index += 1; return }
                    try take(44)
                }
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                try require(index > start)
            }
        }
        mutating func string() throws -> String {
            try require(index < bytes.count && bytes[index] == 34)
            let start = index; index += 1
            while index < bytes.count {
                let current = bytes[index]; index += 1
                if current == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                if current == 92 { try require(index < bytes.count); index += 1 }
            }
            try require(false); return ""
        }
    }
}

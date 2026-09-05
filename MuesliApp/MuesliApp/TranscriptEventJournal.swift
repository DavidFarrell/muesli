import Foundation

/// Replays only the reader's acknowledged byte range, retaining earlier lines
/// even if a later physical write left an invalid or incomplete UTF-8 tail.
nonisolated enum TranscriptEventJournal {
    struct Replay: Sendable {
        var lines: [String] = []
        var error: String?
    }

    static func replay(url: URL, start: UInt64, byteCount: UInt64,
                       maximumLineBytes: Int = 4 * 1024 * 1024) -> Replay {
        var result = Replay()
        var pending = Data()
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard start <= size, byteCount <= size - start else {
                result.error = "The committed transcript journal is truncated."
                return result
            }
            try handle.seek(toOffset: start)
            var remaining = byteCount
            while remaining > 0 {
                let data = try handle.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
                guard !data.isEmpty else {
                    result.error = "The committed transcript journal ended early."
                    return result
                }
                remaining -= UInt64(data.count)
                pending.append(data)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let lineBytes = pending.prefix(upTo: newline)
                    guard lineBytes.count <= maximumLineBytes,
                          let line = String(data: lineBytes, encoding: .utf8) else {
                        result.error = "A committed transcript event is invalid."
                        return result
                    }
                    if !line.isEmpty { result.lines.append(line) }
                    pending.removeSubrange(...newline)
                }
                guard pending.count <= maximumLineBytes else {
                    result.error = "A committed transcript event exceeds the size limit."
                    return result
                }
            }
            if !pending.isEmpty { result.error = "The committed transcript range ends within an event." }
        } catch { result.error = error.localizedDescription }
        return result
    }
}

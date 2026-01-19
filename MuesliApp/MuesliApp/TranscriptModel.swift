import Foundation
import Combine

// MARK: - Transcript Model

struct TranscriptSegment: Identifiable {
    var id: String { "\(stream)_\(Int(round(t0 * 1000)))" }
    let speakerID: String
    let stream: String
    let t0: Double
    let t1: Double?
    let text: String
    let isPartial: Bool
}

@MainActor
final class TranscriptModel: ObservableObject {
    @Published var segments: [TranscriptSegment] = []
    @Published var speakerNames: [String: String] = [:]
    @Published var lastTranscriptAt: Date?
    @Published var lastTranscriptText: String = ""

    func displayName(for speakerID: String) -> String {
        speakerNames[speakerID] ?? speakerID
    }

    func renameSpeaker(id: String, to name: String) {
        speakerNames[id] = name
    }

    func resetForNewMeeting(keepSpeakerNames: Bool) {
        segments.removeAll()
        lastTranscriptAt = nil
        lastTranscriptText = ""
        if !keepSpeakerNames {
            speakerNames.removeAll()
        }
    }

    func asPlainText(includePartials: Bool = false) -> String {
        segments
            .filter { includePartials || !$0.isPartial }
            .map { seg in
                let name = displayName(for: seg.speakerID)
                let stream = seg.stream == "unknown" ? "" : "[\(seg.stream)] "
                return "\(stream)t=\(String(format: "%.2f", seg.t0))s \(name): \(seg.text)"
            }
            .joined(separator: "\n")
    }

    private func mergeSegment(_ newSegment: TranscriptSegment, into existingSegments: [TranscriptSegment]) -> [TranscriptSegment] {
        let epsilon: Double = 0.05
        let newStart = newSegment.t0
        let newEnd = newSegment.t1 ?? newSegment.t0
        let newDuration = max(0, newEnd - newStart)

        var shouldAppend = true
        var updated = existingSegments

        updated.removeAll { existing in
            guard existing.stream == newSegment.stream else { return false }
            let existingEnd = existing.t1 ?? existing.t0
            let existingDuration = max(0, existingEnd - existing.t0)

            let overlap = min(existingEnd, newEnd) - max(existing.t0, newStart)
            if overlap <= 0 {
                return false
            }

            let closeStart = abs(existing.t0 - newStart) <= 0.12
            let newCoversExisting = newStart <= existing.t0 + epsilon && newEnd >= existingEnd - epsilon
            let existingCoversNew = existing.t0 <= newStart + epsilon && existingEnd >= newEnd - epsilon

            if existingCoversNew && existingDuration > newDuration + 0.1 && existing.text.count >= newSegment.text.count {
                shouldAppend = false
                return false
            }

            let overlapRatio = overlap / max(0.01, min(existingDuration, newDuration))
            if newCoversExisting || closeStart || overlapRatio >= 0.8 {
                return true
            }

            return false
        }

        if shouldAppend {
            updated.append(newSegment)
        }

        return updated
    }

    private func sortedSegments(_ items: [TranscriptSegment]) -> [TranscriptSegment] {
        items.sorted { $0.t0 < $1.t0 }
    }

    func ingest(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return
        }

        switch type {
        case "segment":
            let speakerID = (obj["speaker_id"] as? String) ?? "unknown"
            let stream = (obj["stream"] as? String) ?? "unknown"
            let t0 = (obj["t0"] as? Double) ?? 0
            let t1 = obj["t1"] as? Double
            let text = (obj["text"] as? String) ?? ""
            let segment = TranscriptSegment(
                speakerID: speakerID,
                stream: stream,
                t0: t0,
                t1: t1,
                text: text,
                isPartial: false
            )
            var updated = segments.filter { !$0.isPartial }
            updated = mergeSegment(segment, into: updated)
            segments = sortedSegments(updated)
            lastTranscriptAt = Date()
            if !text.isEmpty {
                lastTranscriptText = text
            }

        case "partial":
            let speakerID = (obj["speaker_id"] as? String) ?? "unknown"
            let stream = (obj["stream"] as? String) ?? "unknown"
            let t0 = (obj["t0"] as? Double) ?? 0
            let text = (obj["text"] as? String) ?? ""
            let segment = TranscriptSegment(
                speakerID: speakerID,
                stream: stream,
                t0: t0,
                t1: nil,
                text: text,
                isPartial: true
            )
            var updated = segments
            if let idx = updated.lastIndex(where: { $0.isPartial && $0.stream == stream }) {
                updated[idx] = segment
            } else {
                updated.append(segment)
            }
            segments = sortedSegments(updated)
            lastTranscriptAt = Date()
            if !text.isEmpty {
                lastTranscriptText = text
            }

        case "speakers":
            if let known = obj["known"] as? [[String: Any]] {
                for entry in known {
                    if let speakerID = entry["speaker_id"] as? String {
                        let name = (entry["name"] as? String) ?? speakerID
                        speakerNames[speakerID] = name
                    }
                }
            }

        default:
            return
        }
    }
}

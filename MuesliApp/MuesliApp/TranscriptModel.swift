import Foundation
import Combine

// MARK: - Transcript Model

struct TranscriptSegment: Identifiable {
    let id: UUID
    let speakerID: String
    let stream: String
    let t0: Double
    let t1: Double?
    let text: String
    let isPartial: Bool

    init(
        id: UUID = UUID(),
        speakerID: String,
        stream: String,
        t0: Double,
        t1: Double?,
        text: String,
        isPartial: Bool
    ) {
        self.id = id
        self.speakerID = speakerID
        self.stream = stream
        self.t0 = t0
        self.t1 = t1
        self.text = text
        self.isPartial = isPartial
    }

    var logicKey: String { "\(stream)_\(Int(round(t0 * 1000)))" }
}

extension String {
    func isEchoOf(_ other: String) -> Bool {
        let s1 = self.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let s2 = other.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !s1.isEmpty, !s2.isEmpty else { return false }

        if s1.count >= 5 && s2.contains(s1) { return true }
        if s2.count >= 5 && s1.contains(s2) { return true }

        let words1 = Set(s1.split(separator: " ").map(String.init))
        let words2 = Set(s2.split(separator: " ").map(String.init))

        guard !words1.isEmpty, !words2.isEmpty else { return false }

        let intersection = words1.intersection(words2)
        let smaller = min(words1.count, words2.count)

        return Double(intersection.count) / Double(smaller) >= 0.7
    }
}

@MainActor
final class TranscriptModel: ObservableObject {
    var timestampOffset: Double = 0
    @Published var segments: [TranscriptSegment] = []
    @Published var speakerNames: [String: String] = [:]
    @Published var lastTranscriptAt: Date?
    @Published var lastTranscriptText: String = ""
    var echoSuppressionEnabled: Bool = true

    private let echoTimeWindowSeconds: Double = 1.0

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
        timestampOffset = 0
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

    private func isEcho(_ segment: TranscriptSegment) -> Bool {
        guard echoSuppressionEnabled else { return false }
        guard segment.stream == "mic" else { return false }

        return segments.contains { existing in
            !existing.isPartial &&
            existing.stream == "system" &&
            abs(existing.t0 - segment.t0) < echoTimeWindowSeconds &&
            segment.text.isEchoOf(existing.text)
        }
    }

    private func removeEchoes(causedBy systemSegment: TranscriptSegment) {
        guard echoSuppressionEnabled else { return }
        guard systemSegment.stream == "system" else { return }

        segments.removeAll { existing in
            !existing.isPartial &&
            existing.stream == "mic" &&
            abs(existing.t0 - systemSegment.t0) < echoTimeWindowSeconds &&
            existing.text.isEchoOf(systemSegment.text)
        }
    }

    func ingest(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let type = obj["type"] as? String ?? "segment"

        switch type {
        case "segment":
            let speakerID = (obj["speaker_id"] as? String) ?? "unknown"
            let stream = (obj["stream"] as? String) ?? "unknown"
            let t0 = ((obj["t0"] as? Double) ?? 0) + timestampOffset
            let t1Raw = obj["t1"] as? Double
            let t1 = t1Raw.map { $0 + timestampOffset }
            let text = (obj["text"] as? String) ?? ""
            let segment = TranscriptSegment(
                speakerID: speakerID,
                stream: stream,
                t0: t0,
                t1: t1,
                text: text,
                isPartial: false
            )
            if isEcho(segment) {
                return
            }
            if segment.stream == "system" {
                removeEchoes(causedBy: segment)
            }

            // A final only supersedes a same-stream partial once it covers the
            // audio the partial was describing; partials from other streams -
            // and same-stream partials describing later audio - must survive.
            let finalEnd = segment.t1 ?? segment.t0
            if let supersededIdx = segments.firstIndex(where: {
                $0.isPartial && $0.stream == segment.stream && finalEnd >= $0.t0
            }) {
                segments.remove(at: supersededIdx)
            }

            let finals = segments.filter { !$0.isPartial }
            let lastFinalT0 = finals.last?.t0 ?? -Double.infinity
            let inOrder = segment.t0 >= lastFinalT0
            let mergedFinals = mergeSegment(segment, into: finals)

            if inOrder && mergedFinals.count == finals.count + 1 {
                // Common case: in-order final, nothing to dedupe. Insert right
                // after the existing finals instead of rebuilding the array.
                let insertIndex = segments.lastIndex(where: { !$0.isPartial }).map { $0 + 1 } ?? 0
                segments.insert(segment, at: insertIndex)
            } else {
                // Rare case: overlap dedupe or out-of-order arrival - rebuild,
                // keeping any surviving partials after the (re-ordered) finals.
                let survivingPartials = segments.filter { $0.isPartial }
                let orderedFinals = inOrder ? mergedFinals : sortedSegments(mergedFinals)
                segments = orderedFinals + survivingPartials
            }

            lastTranscriptAt = Date()
            if !text.isEmpty {
                lastTranscriptText = text
            }

        case "partial":
            let speakerID = (obj["speaker_id"] as? String) ?? "unknown"
            let stream = (obj["stream"] as? String) ?? "unknown"
            let t0 = ((obj["t0"] as? Double) ?? 0) + timestampOffset
            let text = (obj["text"] as? String) ?? ""
            let lastT0 = segments.last?.t0 ?? -Double.infinity

            if let idx = segments.lastIndex(where: { $0.isPartial && $0.stream == stream }) {
                // Keep the existing row's identity so SwiftUI treats this as an
                // update, not a remove+insert (avoids row-identity churn).
                let segment = TranscriptSegment(
                    id: segments[idx].id,
                    speakerID: speakerID,
                    stream: stream,
                    t0: t0,
                    t1: nil,
                    text: text,
                    isPartial: true
                )
                segments[idx] = segment
                if segment.t0 < lastT0 {
                    segments = sortedSegments(segments)
                }
            } else {
                let segment = TranscriptSegment(
                    speakerID: speakerID,
                    stream: stream,
                    t0: t0,
                    t1: nil,
                    text: text,
                    isPartial: true
                )
                if t0 >= lastT0 {
                    segments.append(segment)
                } else {
                    segments = sortedSegments(segments + [segment])
                }
            }

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

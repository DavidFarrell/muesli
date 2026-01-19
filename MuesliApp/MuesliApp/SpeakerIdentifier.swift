import Foundation
import AppKit
import CoreGraphics
import ImageIO

actor SpeakerIdentifier {
    struct SpeakerMapping: Codable {
        var speakerId: String
        var name: String
        var confidence: Double

        enum CodingKeys: String, CodingKey {
            case speakerId = "speaker_id"
            case name
            case confidence
        }
    }

    struct IdentificationResult {
        var mappings: [SpeakerMapping]
        var rawResponse: String
    }

    enum Progress {
        case extractingFrames
        case analyzing
        case complete
    }

    private let ollamaBaseURL = URL(string: "http://localhost:11434")!
    private let model = "gemma3:27b"
    private let maxImageDimension: CGFloat = 1024
    private let targetScreenshotCount = 16
    private let dedupeHashThreshold = 6
    private let dedupeMinTimeDelta: Double = 10.0

    private struct ImagePayload {
        let mediaType: String
        let base64Data: String
    }

    private struct ScreenshotCandidate {
        let url: URL
        let timestamp: Double?
        let name: String
    }

    func identifySpeakers(
        screenshots: [URL],
        transcript: String,
        speakerIds: [String],
        progressHandler: ((Progress) -> Void)? = nil
    ) async throws -> IdentificationResult {
        progressHandler?(.extractingFrames)
        let selectedScreenshots = selectScreenshots(from: screenshots, targetCount: targetScreenshotCount)
        let imagePayloads = try loadImagePayloads(from: selectedScreenshots)
        progressHandler?(.analyzing)
        let prompt = buildPrompt(transcript: transcript, speakerIds: speakerIds)
        let rawResponse = try await requestOllama(images: imagePayloads, prompt: prompt)
        let mappings = parseMappings(from: rawResponse)
        progressHandler?(.complete)
        return IdentificationResult(mappings: mappings, rawResponse: rawResponse)
    }

    private func selectScreenshots(from screenshots: [URL], targetCount: Int) -> [URL] {
        guard !screenshots.isEmpty, targetCount > 0 else { return [] }
        let candidates = screenshots.map { url in
            ScreenshotCandidate(url: url, timestamp: extractTimestamp(from: url), name: url.lastPathComponent)
        }
        let sorted = candidates.sorted { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (left?, right?):
                if left == right {
                    return lhs.name < rhs.name
                }
                return left < right
            case (nil, nil):
                return lhs.name < rhs.name
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        }
        let deduped = dedupeNearDuplicates(sorted)
        let selected = selectEvenly(from: deduped, targetCount: targetCount)
        return selected.map { $0.url }
    }

    private func selectEvenly(from candidates: [ScreenshotCandidate], targetCount: Int) -> [ScreenshotCandidate] {
        guard !candidates.isEmpty, targetCount > 0 else { return [] }
        if candidates.count <= targetCount {
            return candidates
        }
        let hasTimestamps = candidates.allSatisfy { $0.timestamp != nil }
        if hasTimestamps {
            return selectEvenlyByTime(candidates, targetCount: targetCount)
        }
        return selectEvenlyByIndex(candidates, targetCount: targetCount)
    }

    private func selectEvenlyByTime(_ candidates: [ScreenshotCandidate], targetCount: Int) -> [ScreenshotCandidate] {
        guard targetCount > 1,
              let start = candidates.first?.timestamp,
              let end = candidates.last?.timestamp,
              start != end else {
            return selectEvenlyByIndex(candidates, targetCount: targetCount)
        }
        let step = (end - start) / Double(targetCount - 1)
        var selected: [ScreenshotCandidate] = []
        var index = 0
        for i in 0..<targetCount {
            let targetTime = start + (Double(i) * step)
            while index < candidates.count - 1,
                  let ts = candidates[index].timestamp,
                  ts < targetTime {
                index += 1
            }
            selected.append(candidates[index])
        }
        return fillSelectionIfNeeded(selected, from: candidates, targetCount: targetCount)
    }

    private func selectEvenlyByIndex(_ candidates: [ScreenshotCandidate], targetCount: Int) -> [ScreenshotCandidate] {
        if targetCount <= 1 {
            return [candidates[candidates.count / 2]]
        }
        let step = Double(candidates.count - 1) / Double(targetCount - 1)
        var selected: [ScreenshotCandidate] = []
        var lastIndex = -1
        for i in 0..<targetCount {
            let idx = min(candidates.count - 1, Int(round(Double(i) * step)))
            if idx != lastIndex {
                selected.append(candidates[idx])
                lastIndex = idx
            }
        }
        return fillSelectionIfNeeded(selected, from: candidates, targetCount: targetCount)
    }

    private func fillSelectionIfNeeded(
        _ selected: [ScreenshotCandidate],
        from candidates: [ScreenshotCandidate],
        targetCount: Int
    ) -> [ScreenshotCandidate] {
        var output = uniqueSelection(selected)
        if output.count >= targetCount {
            return Array(output.prefix(targetCount))
        }
        var seen = Set(output.map { $0.url.path })
        for candidate in candidates {
            if output.count >= targetCount {
                break
            }
            if seen.insert(candidate.url.path).inserted {
                output.append(candidate)
            }
        }
        return output
    }

    private func uniqueSelection(_ candidates: [ScreenshotCandidate]) -> [ScreenshotCandidate] {
        var seen = Set<String>()
        var result: [ScreenshotCandidate] = []
        for candidate in candidates {
            let key = candidate.url.path
            if seen.insert(key).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private func dedupeNearDuplicates(_ candidates: [ScreenshotCandidate]) -> [ScreenshotCandidate] {
        guard candidates.count > 1 else { return candidates }
        var result: [ScreenshotCandidate] = []
        var lastHash: UInt64?
        var lastTimestamp: Double?
        for candidate in candidates {
            guard let hash = averageHash(for: candidate.url) else {
                result.append(candidate)
                lastHash = nil
                lastTimestamp = candidate.timestamp
                continue
            }
            if let previousHash = lastHash {
                let distance = hammingDistance(previousHash, hash)
                if distance <= dedupeHashThreshold {
                    if let previousTimestamp = lastTimestamp,
                       let currentTimestamp = candidate.timestamp {
                        if abs(currentTimestamp - previousTimestamp) < dedupeMinTimeDelta {
                            continue
                        }
                    } else {
                        continue
                    }
                }
            }
            result.append(candidate)
            lastHash = hash
            lastTimestamp = candidate.timestamp
        }
        return result
    }

    private func extractTimestamp(from url: URL) -> Double? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("t+") else { return nil }
        let start = name.index(name.startIndex, offsetBy: 2)
        return Double(name[start...])
    }

    private func averageHash(for url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = 8
        let height = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)
        let hash: UInt64? = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let avg = pixels.reduce(0) { $0 + Int($1) } / pixels.count
            var hash: UInt64 = 0
            for (index, value) in pixels.enumerated() {
                if Int(value) >= avg {
                    hash |= 1 << UInt64(index)
                }
            }
            return hash
        }
        return hash
    }

    private func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        Int((lhs ^ rhs).nonzeroBitCount)
    }

    private func loadImagePayloads(from urls: [URL]) throws -> [ImagePayload] {
        var payloads: [ImagePayload] = []
        for url in urls {
            guard let image = loadImage(from: url),
                  let resized = resizeImage(image, maxDimension: maxImageDimension),
                  let data = encodePNG(resized) else {
                continue
            }
            let mediaType = "image/png"
            payloads.append(ImagePayload(mediaType: mediaType, base64Data: data.base64EncodedString()))
        }
        return payloads
    }

    private func loadImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func resizeImage(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }

        let maxInput = max(width, height)
        let ratio = min(1.0, maxDimension / maxInput)
        let newWidth = Int(width * ratio)
        let newHeight = Int(height * ratio)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    private func encodePNG(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private func buildPrompt(transcript: String, speakerIds: [String]) -> String {
        let ids = speakerIds.joined(separator: ", ")
        return """
        You are identifying real names for speakers in a transcript. The transcript uses labels like SPEAKER_00.\n\n\
        Speaker IDs: \(ids)\n\n\
        Transcript:\n\(transcript)\n\n\
        Return ONLY JSON. Provide an array of objects with keys: speaker_id, name, confidence.\n\
        confidence is 0.0 to 1.0. If unknown, set name to \"Unknown\" and confidence to 0.0.\n\
        """
    }

    private func requestOllama(images: [ImagePayload], prompt: String) async throws -> String {
        let url = ollamaBaseURL.appendingPathComponent("v1/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var content: [[String: Any]] = images.map { payload in
            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": payload.mediaType,
                    "data": payload.base64Data,
                ],
            ]
        }
        content.append([
            "type": "text",
            "text": prompt,
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                [
                    "role": "user",
                    "content": content,
                ],
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "SpeakerIdentifier", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            throw NSError(domain: "SpeakerIdentifier", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseMappings(from rawResponse: String) -> [SpeakerMapping] {
        let assistantText = extractAssistantText(from: rawResponse) ?? rawResponse
        let jsonString = extractJson(from: assistantText) ?? assistantText

        guard let data = jsonString.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode([SpeakerMapping].self, from: data) {
            return direct
        }
        if let wrapped = try? decoder.decode(MappingWrapper.self, from: data) {
            return wrapped.mappings
        }
        return []
    }

    private struct MappingWrapper: Codable {
        let mappings: [SpeakerMapping]
    }

    private func extractAssistantText(from rawResponse: String) -> String? {
        guard let data = rawResponse.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            return nil
        }
        let texts = content.compactMap { $0["text"] as? String }
        if texts.isEmpty {
            return nil
        }
        return texts.joined(separator: "\n")
    }

    private func extractJson(from text: String) -> String? {
        guard let startIndex = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }
        guard let endIndex = text.lastIndex(where: { $0 == "}" || $0 == "]" }) else {
            return nil
        }
        if startIndex >= endIndex {
            return nil
        }
        return String(text[startIndex...endIndex])
    }
}

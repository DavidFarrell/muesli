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

    static func checkAvailability(
        modelName: String = "gemma3:27b",
        timeoutSeconds: TimeInterval = 3
    ) async -> SpeakerIdStatus {
        let url = URL(string: "http://localhost:11434/api/tags")!
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .error("invalid response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .error("status \(http.statusCode)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return .error("invalid payload")
            }
            let hasModel = models.contains { ($0["name"] as? String) == modelName }
            return hasModel ? .ready : .modelMissing(modelName)
        } catch {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .timedOut:
                    return .ollamaNotRunning
                default:
                    return .error(urlError.localizedDescription)
                }
            }
            return .error(error.localizedDescription)
        }
    }

    private let ollamaBaseURL = URL(string: "http://localhost:11434")!
    private let model = "gemma3:27b"
    private let maxImageDimension: CGFloat = 1024
    private let targetScreenshotCount = 16
    private let dedupeHashThreshold = 6
    private let dedupeMinTimeDelta: Double = 10.0
    private let requestTimeout: TimeInterval = 300
    private let maxRetries = 2
    private let retryDelaySeconds: TimeInterval = 1.5

    private struct ImagePayload {
        let mediaType: String
        let base64Data: String
    }

    private struct OllamaHTTPError: LocalizedError {
        let statusCode: Int

        var errorDescription: String? {
            "Ollama returned status \(statusCode)."
        }
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
        existingSpeakerNames: [String: String] = [:],
        userHint: String? = nil,
        progressHandler: ((Progress) -> Void)? = nil
    ) async throws -> IdentificationResult {
        // DEBUG: Log inputs
        print("[SpeakerID DEBUG] === Starting speaker identification ===")
        print("[SpeakerID DEBUG] Screenshots count: \(screenshots.count)")
        print("[SpeakerID DEBUG] Speaker IDs: \(speakerIds)")
        print("[SpeakerID DEBUG] Transcript length: \(transcript.count) chars")
        print("[SpeakerID DEBUG] User hint: \(userHint ?? "(none)")")

        progressHandler?(.extractingFrames)
        try Task.checkCancellation()
        let selectedScreenshots = selectScreenshots(from: screenshots, targetCount: targetScreenshotCount)
        print("[SpeakerID DEBUG] Selected \(selectedScreenshots.count) screenshots")

        let imagePayloads = try loadImagePayloads(from: selectedScreenshots)
        print("[SpeakerID DEBUG] Loaded \(imagePayloads.count) image payloads")

        progressHandler?(.analyzing)
        let sampledTranscript = sampleTranscript(transcript, speakerIds: speakerIds)
        print("[SpeakerID DEBUG] Sampled transcript: \(transcript.components(separatedBy: .newlines).count) lines -> \(sampledTranscript.components(separatedBy: .newlines).count) lines")
        print("[SpeakerID DEBUG] Sampled transcript preview (first 1000 chars):")
        print(String(sampledTranscript.prefix(1000)))
        print("[SpeakerID DEBUG] ---")

        let prompt = buildPrompt(transcript: transcript, speakerIds: speakerIds, userHint: userHint)
        print("[SpeakerID DEBUG] Built prompt (\(prompt.count) chars)")
        print("[SpeakerID DEBUG] Prompt speaker list section:")
        // Print just the speaker list part
        for id in speakerIds {
            print("[SpeakerID DEBUG]   \(id) = ?")
        }

        let rawResponse = try await requestOllama(images: imagePayloads, prompt: prompt)
        let targetSpeakerIds = mappingTargetSpeakerIds(from: speakerIds)
        let parsedMappings = parseMappings(from: rawResponse, targetSpeakerIds: targetSpeakerIds)
        let mappings = sanitizeMappings(
            parsedMappings,
            speakerIds: speakerIds,
            existingSpeakerNames: existingSpeakerNames,
            userHint: userHint
        )
        print("[SpeakerID DEBUG] === Identification complete: \(mappings.count) mappings ===")
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
        var didDraw = false
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            didDraw = true
        }
        guard didDraw else { return nil }
        let avg = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var hash: UInt64 = 0
        for (index, value) in pixels.enumerated() {
            if Int(value) >= avg {
                hash |= 1 << UInt64(index)
            }
        }
        return hash
    }

    private func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        Int((lhs ^ rhs).nonzeroBitCount)
    }

    private func loadImagePayloads(from urls: [URL]) throws -> [ImagePayload] {
        var payloads: [ImagePayload] = []
        for url in urls {
            try Task.checkCancellation()
            guard let image = loadImage(from: url),
                  let resized = resizeImage(image, maxDimension: maxImageDimension),
                  let data = encodeJPEG(resized, quality: 0.8) else {
                continue
            }
            payloads.append(ImagePayload(mediaType: "image/jpeg", base64Data: data.base64EncodedString()))
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

    private func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private let maxTranscriptLines = 40
    private let linesPerSpeaker = 3

    /// Sample transcript to get representative lines for each speaker while staying within limits.
    /// Strategy:
    /// 1. For each speaker, collect lines where they speak
    /// 2. Sample evenly from beginning, middle, end for each speaker
    /// 3. Also include lines that mention names (greetings, introductions)
    /// 4. Sort final selection by timestamp
    private func sampleTranscript(_ transcript: String, speakerIds: [String]) -> String {
        let lines = transcript.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return transcript }

        // If already short enough, return as-is
        if lines.count <= maxTranscriptLines {
            return transcript
        }

        var selectedLines = Set<Int>()

        // Group lines by speaker
        var linesBySpeaker: [String: [Int]] = [:]
        for speakerId in speakerIds {
            linesBySpeaker[speakerId] = []
        }

        for (index, line) in lines.enumerated() {
            for speakerId in speakerIds {
                if line.contains(speakerId) {
                    linesBySpeaker[speakerId, default: []].append(index)
                    break
                }
            }
        }

        // For each speaker, sample evenly from their lines
        for (_, indices) in linesBySpeaker {
            guard !indices.isEmpty else { continue }
            if indices.count <= linesPerSpeaker {
                selectedLines.formUnion(indices)
            } else {
                // Sample from beginning, middle, end
                selectedLines.insert(indices.first!)
                selectedLines.insert(indices.last!)
                let middleIndex = indices.count / 2
                selectedLines.insert(indices[middleIndex])
            }
        }

        // Also look for lines with potential name mentions (greetings, introductions)
        let namePatterns = ["hey ", "hi ", "hello ", "thanks ", "thank you ", "bye ", "i'm ", "my name", "david", "nick", "brian", "bry", "col"]
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            for pattern in namePatterns {
                if lower.contains(pattern) {
                    selectedLines.insert(index)
                    break
                }
            }
        }

        // If we have too many, trim to maxTranscriptLines by sampling evenly
        var finalIndices = Array(selectedLines).sorted()
        if finalIndices.count > maxTranscriptLines {
            let step = Double(finalIndices.count) / Double(maxTranscriptLines)
            var sampled: [Int] = []
            for i in 0..<maxTranscriptLines {
                let idx = min(finalIndices.count - 1, Int(Double(i) * step))
                sampled.append(finalIndices[idx])
            }
            finalIndices = sampled.sorted()
        }

        // Build result maintaining original order
        let result = finalIndices.map { lines[$0] }.joined(separator: "\n")
        let omitted = lines.count - finalIndices.count
        if omitted > 0 {
            return result + "\n[... \(omitted) more lines omitted ...]"
        }
        return result
    }

    private func mappingTargetSpeakerIds(from speakerIds: [String]) -> [String] {
        let hasSystem = speakerIds.contains { $0.lowercased().hasPrefix("system:") }
        let hasMic = speakerIds.contains { $0.lowercased().hasPrefix("mic:") }
        if hasSystem && hasMic {
            return speakerIds
        }
        if hasSystem {
            let systemOnly = speakerIds.filter { $0.lowercased().hasPrefix("system:") }
            return systemOnly.isEmpty ? speakerIds : systemOnly
        }
        if hasMic {
            let micOnly = speakerIds.filter { $0.lowercased().hasPrefix("mic:") }
            return micOnly.isEmpty ? speakerIds : micOnly
        }
        return speakerIds
    }

    private func splitSpeakerId(_ raw: String) -> (prefix: String?, base: String) {
        let compact = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        let parts = compact.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        return (nil, compact)
    }

    private func speakerIndex(from base: String) -> Int? {
        let folded = base.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        if let regex = try? NSRegularExpression(pattern: #"speaker\D*0*([0-9]{1,4})"#, options: [.caseInsensitive]) {
            let range = NSRange(folded.startIndex..<folded.endIndex, in: folded)
            if let match = regex.firstMatch(in: folded, options: [], range: range),
               match.numberOfRanges >= 2,
               let numberRange = Range(match.range(at: 1), in: folded) {
                return Int(folded[numberRange])
            }
        }

        let digits = folded.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        if !digits.isEmpty {
            return Int(digits)
        }
        return nil
    }

    private func canonicalTargetSpeakerId(for rawSpeakerId: String, targetSpeakerIds: [String]) -> String? {
        let compactRaw = rawSpeakerId.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !compactRaw.isEmpty else { return nil }

        if targetSpeakerIds.contains(compactRaw) {
            return compactRaw
        }
        if let caseInsensitive = targetSpeakerIds.first(where: { $0.caseInsensitiveCompare(compactRaw) == .orderedSame }) {
            return caseInsensitive
        }

        let rawParts = splitSpeakerId(compactRaw)
        let rawPrefix = rawParts.prefix?.lowercased()
        let candidatePool = targetSpeakerIds.filter { target in
            guard let rawPrefix else { return true }
            let targetPrefix = splitSpeakerId(target).prefix?.lowercased()
            return targetPrefix == rawPrefix
        }

        let baseMatches = candidatePool.filter {
            splitSpeakerId($0).base.caseInsensitiveCompare(rawParts.base) == .orderedSame
        }
        if baseMatches.count == 1 {
            return baseMatches[0]
        }

        if let rawIndex = speakerIndex(from: rawParts.base) {
            let numericMatches = candidatePool.filter {
                speakerIndex(from: splitSpeakerId($0).base) == rawIndex
            }
            if numericMatches.count == 1 {
                return numericMatches[0]
            }
        }

        return nil
    }

    private func sanitizeMappings(
        _ mappings: [SpeakerMapping],
        speakerIds: [String],
        existingSpeakerNames: [String: String],
        userHint: String?
    ) -> [SpeakerMapping] {
        let targetSpeakerIds = mappingTargetSpeakerIds(from: speakerIds)
        guard !targetSpeakerIds.isEmpty else { return [] }

        let hasSystem = speakerIds.contains { $0.lowercased().hasPrefix("system:") }
        let hasMic = speakerIds.contains { $0.lowercased().hasPrefix("mic:") }
        let targetSet = Set(targetSpeakerIds)

        var bestBySpeakerId: [String: SpeakerMapping] = [:]
        for mapping in mappings {
            guard let speakerId = canonicalTargetSpeakerId(for: mapping.speakerId, targetSpeakerIds: targetSpeakerIds) else {
                let raw = mapping.speakerId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty {
                    print("[SpeakerID DEBUG] Ignoring mapping with unmatched speaker_id: \(raw)")
                }
                continue
            }
            guard targetSet.contains(speakerId) else { continue }

            var normalized = mapping
            normalized.speakerId = speakerId
            normalized.name = cleanedMappingName(mapping.name)
            normalized.confidence = min(max(mapping.confidence, 0.0), 1.0)

            if let existing = bestBySpeakerId[speakerId] {
                if normalized.confidence > existing.confidence {
                    bestBySpeakerId[speakerId] = normalized
                }
            } else {
                bestBySpeakerId[speakerId] = normalized
            }
        }

        var normalizedMappings: [SpeakerMapping] = targetSpeakerIds.map { speakerId in
            if let mapping = bestBySpeakerId[speakerId] {
                return mapping
            }
            return SpeakerMapping(speakerId: speakerId, name: "Unknown", confidence: 0.0)
        }

        let recorderNames = recorderNameCandidates(from: userHint)
        if hasSystem && hasMic {
            if !recorderNames.isEmpty {
                var strongestRecorderMapping: SpeakerMapping?
                for idx in normalizedMappings.indices {
                    guard !isUnknownName(normalizedMappings[idx].name) else { continue }
                    guard isRecorderName(normalizedMappings[idx].name, recorderNames: recorderNames) else { continue }

                    if let existing = strongestRecorderMapping {
                        if normalizedMappings[idx].confidence > existing.confidence {
                            strongestRecorderMapping = normalizedMappings[idx]
                        }
                    } else {
                        strongestRecorderMapping = normalizedMappings[idx]
                    }

                    guard normalizedMappings[idx].speakerId.lowercased().hasPrefix("system:") else { continue }
                    print("[SpeakerID DEBUG] Blocking recorder name '\(normalizedMappings[idx].name)' from \(normalizedMappings[idx].speakerId); setting Unknown")
                    normalizedMappings[idx].name = "Unknown"
                    normalizedMappings[idx].confidence = 0.0
                }

                let hasRecorderOnMic = normalizedMappings.contains { mapping in
                    mapping.speakerId.lowercased().hasPrefix("mic:") &&
                    !isUnknownName(mapping.name) &&
                    isRecorderName(mapping.name, recorderNames: recorderNames)
                }
                if !hasRecorderOnMic,
                   let strongestRecorderMapping,
                   !isUnknownName(strongestRecorderMapping.name),
                   let micIndex = normalizedMappings.indices.first(where: { normalizedMappings[$0].speakerId.lowercased().hasPrefix("mic:") }) {
                    print("[SpeakerID DEBUG] Assigning recorder name '\(strongestRecorderMapping.name)' to \(normalizedMappings[micIndex].speakerId)")
                    normalizedMappings[micIndex].name = strongestRecorderMapping.name
                    normalizedMappings[micIndex].confidence = max(normalizedMappings[micIndex].confidence, strongestRecorderMapping.confidence)
                }
            }
        }

        normalizedMappings = applyExistingNameFallback(
            normalizedMappings,
            existingSpeakerNames: existingSpeakerNames,
            hasSystem: hasSystem,
            hasMic: hasMic,
            recorderNames: recorderNames
        )
        normalizedMappings = enforceUniqueNonUnknownNames(normalizedMappings)

        if hasSystem {
            normalizedMappings = fillMissingSystemNamesFromExisting(
                normalizedMappings,
                existingSpeakerNames: existingSpeakerNames,
                hasMic: hasMic,
                recorderNames: recorderNames
            )
            normalizedMappings = enforceUniqueNonUnknownNames(normalizedMappings)
        }

        return normalizedMappings
    }

    private func cleanedMappingName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        return trimmed
    }

    private func normalizePersonName(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let words = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    private func isUnknownName(_ raw: String) -> Bool {
        let normalized = normalizePersonName(raw)
        if normalized.isEmpty { return true }
        let unknownTokens: Set<String> = ["unknown", "unk", "na", "none", "n a"]
        return unknownTokens.contains(normalized)
    }

    private func recorderNameCandidates(from userHint: String?) -> Set<String> {
        var recorderNames = Set<String>()
        for clue in recorderNameClues(from: userHint) {
            let normalized = normalizePersonName(clue)
            guard !normalized.isEmpty else { continue }
            recorderNames.insert(normalized)
        }
        return recorderNames
    }

    private func recorderNameClues(from userHint: String?) -> [String] {
        var rawNames: [String] = []

        let fullUserName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullUserName.isEmpty {
            rawNames.append(fullUserName)
        }

        let trimmedHint = userHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedHint.isEmpty {
            let patterns = [
                #"(?i)\b(?:recorder(?:'s)?\s+name|recorder|mic\s+speaker|microphone\s+speaker)\s*(?:is|=|:)\s*([A-Za-z][A-Za-z'’\-]*(?:\s+[A-Za-z][A-Za-z'’\-]*){0,3})"#,
                #"(?i)\b(?:i am|i'm|im|my name is)\s+([A-Za-z][A-Za-z'’\-]*(?:\s+[A-Za-z][A-Za-z'’\-]*){0,3})"#,
                #"(?i)\b([A-Za-z][A-Za-z'’\-]*(?:\s+[A-Za-z][A-Za-z'’\-]*){0,3})\s+is\s+the\s+person\s+on\s+the\s+host\s+machine\b"#,
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let nsRange = NSRange(trimmedHint.startIndex..<trimmedHint.endIndex, in: trimmedHint)
                regex.enumerateMatches(in: trimmedHint, options: [], range: nsRange) { match, _, _ in
                    guard let match,
                          match.numberOfRanges >= 2,
                          let range = Range(match.range(at: 1), in: trimmedHint) else { return }
                    let captured = String(trimmedHint[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !captured.isEmpty {
                        rawNames.append(captured)
                    }
                }
            }
        }

        var seen = Set<String>()
        var deduped: [String] = []
        for candidate in rawNames {
            let key = normalizePersonName(candidate)
            guard !key.isEmpty else { continue }
            if seen.insert(key).inserted {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    private func isRecorderName(_ rawName: String, recorderNames: Set<String>) -> Bool {
        let normalized = normalizePersonName(rawName)
        guard !normalized.isEmpty else { return false }
        if recorderNames.contains(normalized) {
            return true
        }

        let words = Set(normalized.split(separator: " ").map(String.init))
        guard !words.isEmpty else { return false }

        for candidate in recorderNames {
            let candidateWords = candidate.split(separator: " ").map(String.init)
            guard !candidateWords.isEmpty else { continue }
            if candidateWords.count == 1 {
                if words.contains(candidateWords[0]) {
                    return true
                }
                continue
            }
            let candidateSet = Set(candidateWords)
            if candidateSet.isSubset(of: words) {
                return true
            }
        }
        return false
    }

    private func lookupExistingName(
        for speakerId: String,
        in existingSpeakerNames: [String: String]
    ) -> String? {
        if let exact = existingSpeakerNames[speakerId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !exact.isEmpty {
            return exact
        }
        if let ciMatch = existingSpeakerNames.first(where: {
            $0.key.caseInsensitiveCompare(speakerId) == .orderedSame
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
           !ciMatch.isEmpty {
            return ciMatch
        }

        let targetParts = splitSpeakerId(speakerId)
        let targetPrefix = targetParts.prefix?.lowercased()
        let targetBase = targetParts.base

        if let targetPrefix {
            if let samePrefix = existingSpeakerNames.first(where: { key, value in
                let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty else { return false }
                let parts = splitSpeakerId(key)
                return parts.prefix?.lowercased() == targetPrefix &&
                    parts.base.caseInsensitiveCompare(targetBase) == .orderedSame
            })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
               !samePrefix.isEmpty {
                return samePrefix
            }
        }

        if let suffixMatch = existingSpeakerNames.first(where: { key, value in
            let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return false }
            return splitSpeakerId(key).base.caseInsensitiveCompare(targetBase) == .orderedSame
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
           !suffixMatch.isEmpty {
            return suffixMatch
        }

        return nil
    }

    private func applyExistingNameFallback(
        _ mappings: [SpeakerMapping],
        existingSpeakerNames: [String: String],
        hasSystem: Bool,
        hasMic: Bool,
        recorderNames: Set<String>
    ) -> [SpeakerMapping] {
        guard !existingSpeakerNames.isEmpty else { return mappings }
        var result = mappings
        var fallbackByIndex: [Int: String] = [:]
        for idx in result.indices {
            guard let fallback = lookupExistingName(for: result[idx].speakerId, in: existingSpeakerNames) else { continue }
            guard !isUnknownName(fallback) else { continue }
            if hasSystem && hasMic &&
                result[idx].speakerId.lowercased().hasPrefix("system:") &&
                !recorderNames.isEmpty &&
                isRecorderName(fallback, recorderNames: recorderNames) {
                continue
            }
            fallbackByIndex[idx] = fallback
        }

        let hasCompleteCoverage = fallbackByIndex.count == result.count

        for idx in result.indices {
            guard let fallback = fallbackByIndex[idx] else { continue }
            let shouldApply: Bool
            if hasCompleteCoverage {
                shouldApply = normalizePersonName(result[idx].name) != normalizePersonName(fallback)
            } else {
                shouldApply = isUnknownName(result[idx].name)
            }
            guard shouldApply else { continue }

            if hasCompleteCoverage {
                print("[SpeakerID DEBUG] Preserving existing name for \(result[idx].speakerId) as '\(fallback)'")
                result[idx].confidence = max(result[idx].confidence, 0.995)
            } else {
                print("[SpeakerID DEBUG] Filling \(result[idx].speakerId) from existing name '\(fallback)'")
                result[idx].confidence = max(result[idx].confidence, 0.99)
            }
            result[idx].name = fallback
        }
        return result
    }

    private func fillMissingSystemNamesFromExisting(
        _ mappings: [SpeakerMapping],
        existingSpeakerNames: [String: String],
        hasMic: Bool,
        recorderNames: Set<String>
    ) -> [SpeakerMapping] {
        guard !existingSpeakerNames.isEmpty else { return mappings }
        var result = mappings
        var usedSystemNames = Set(
            result
                .filter { $0.speakerId.lowercased().hasPrefix("system:") && !isUnknownName($0.name) }
                .map { normalizePersonName($0.name) }
                .filter { !$0.isEmpty }
        )

        for idx in result.indices {
            guard result[idx].speakerId.lowercased().hasPrefix("system:") else { continue }
            guard isUnknownName(result[idx].name) else { continue }
            guard let fallback = lookupExistingName(for: result[idx].speakerId, in: existingSpeakerNames) else { continue }
            guard !isUnknownName(fallback) else { continue }

            let normalizedFallback = normalizePersonName(fallback)
            guard !normalizedFallback.isEmpty else { continue }
            if usedSystemNames.contains(normalizedFallback) {
                continue
            }
            if hasMic && !recorderNames.isEmpty && isRecorderName(fallback, recorderNames: recorderNames) {
                continue
            }

            print("[SpeakerID DEBUG] Restoring missing system speaker \(result[idx].speakerId) as '\(fallback)'")
            result[idx].name = fallback
            result[idx].confidence = max(result[idx].confidence, 0.98)
            usedSystemNames.insert(normalizedFallback)
        }

        return result
    }

    private func enforceUniqueNonUnknownNames(_ mappings: [SpeakerMapping]) -> [SpeakerMapping] {
        var groups: [String: [Int]] = [:]
        for (index, mapping) in mappings.enumerated() {
            guard !isUnknownName(mapping.name) else { continue }
            let normalized = normalizePersonName(mapping.name)
            guard !normalized.isEmpty else { continue }
            groups[normalized, default: []].append(index)
        }

        var result = mappings
        for (name, indices) in groups where indices.count > 1 {
            let keepIndex = indices.max { lhs, rhs in
                result[lhs].confidence < result[rhs].confidence
            } ?? indices[0]
            for index in indices where index != keepIndex {
                print("[SpeakerID DEBUG] Duplicate name '\(name)' for \(result[index].speakerId); setting Unknown")
                result[index].name = "Unknown"
                result[index].confidence = 0.0
            }
        }
        return result
    }

    private func buildPrompt(transcript: String, speakerIds: [String], userHint: String?) -> String {
        let trimmedHint = userHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hintBlock: String
        if let trimmedHint, !trimmedHint.isEmpty {
            hintBlock = """

            USER PROVIDED HINT:
            \(trimmedHint)
            """
        } else {
            hintBlock = ""
        }

        let hasSystem = speakerIds.contains { $0.lowercased().hasPrefix("system:") }
        let hasMic = speakerIds.contains { $0.lowercased().hasPrefix("mic:") }
        let mappingSpeakerIds = mappingTargetSpeakerIds(from: speakerIds)
        let speakerList = mappingSpeakerIds.map { "\($0) = ?" }.joined(separator: "\n")
        let recorderNameConstraintBlock: String = {
            guard hasMic && hasSystem else { return "" }
            let recorderClues = recorderNameClues(from: userHint)
            guard !recorderClues.isEmpty else { return "" }
            let names = recorderClues.joined(separator: ", ")
            return """
            RECORDER NAME CONSTRAINT:
            - Recorder name clue(s): \(names)
            - Never assign these names to any system:SPEAKER_XX.

            """
        }()

        let audioStreamsBlock: String
        if hasMic && hasSystem {
            audioStreamsBlock = """
        AUDIO STREAMS EXPLAINED:
        - "mic:SPEAKER_XX" = audio from the recorder's microphone (YOU are the recorder)
        - "system:SPEAKER_XX" = audio from the call (everyone else comes through system audio)
        """
        } else if hasMic {
            audioStreamsBlock = """
        AUDIO STREAMS EXPLAINED:
        - "mic:SPEAKER_XX" = audio from the microphone (all speakers are mic)
        """
        } else if hasSystem {
            audioStreamsBlock = """
        AUDIO STREAMS EXPLAINED:
        - "system:SPEAKER_XX" = audio from the call (all speakers are system)
        """
        } else {
            audioStreamsBlock = """
        AUDIO STREAMS EXPLAINED:
        - Speaker IDs are unprefixed (no mic/system stream label)
        """
        }

        let stepsBlock: String
        let mappingHeader: String
        let importantBlock: String
        if hasMic && hasSystem {
            stepsBlock = """
        STEP 2 - IDENTIFY THE RECORDER (CRITICAL):
        Look at the transcript lines starting with "[mic]" - this is the recorder speaking.
        The recorder is ONE of the people visible on screen.
        To identify them: look for moments where other speakers address the recorder by name.
        For example, if someone says "David Gérouville-Farrell, what do you think?" and mic:SPEAKER_01 responds, then David Gérouville-Farrell is the recorder.
        IMPORTANT: Do NOT assign the recorder's name to any system:SPEAKER_XX.

        STEP 3 - MAP ALL LISTED SPEAKERS:
        Map every listed speaker_id.
        - mic:SPEAKER_XX should map to the recorder.
        - system:SPEAKER_XX should map to everyone else from the call audio.
        If you see extra names on screen, use transcript timing and address patterns to decide who is speaking.
        \(hintBlock)
        """
            mappingHeader = "Map each listed speaker ID to their real name:"
            importantBlock = """
        IMPORTANT:
        - Include BOTH mic and system speakers in your JSON output.
        - Recorder name must appear only on mic:SPEAKER_XX.
        - Use the EXACT speaker_id format shown above (including any prefix like "system:" or "mic:").
        """
        } else if hasMic {
            stepsBlock = """
        STEP 2 - MATCH MIC SPEAKERS:
        All speakers are in the mic stream (no system audio). Map each mic speaker to their real name.
        \(hintBlock)
        """
            mappingHeader = "Map each MIC speaker to their real name:"
            importantBlock = """
        IMPORTANT:
        - Only include mic speakers in your JSON output. Do NOT invent system speaker IDs.
        - Use the EXACT speaker_id format shown above (including any prefix like "mic:").
        """
        } else if hasSystem {
            stepsBlock = """
        STEP 2 - MATCH SYSTEM SPEAKERS:
        Map each system speaker to their real name.
        \(hintBlock)
        """
            mappingHeader = "Map each SYSTEM speaker to their real name:"
            importantBlock = """
        IMPORTANT:
        - Only include system speakers in your JSON output.
        - Use the EXACT speaker_id format shown above (including any prefix like "system:").
        """
        } else {
            stepsBlock = """
        STEP 2 - MATCH SPEAKERS:
        Map each listed speaker ID to their real name.
        \(hintBlock)
        """
            mappingHeader = "Map each speaker to their real name:"
            importantBlock = """
        IMPORTANT:
        - Only include the listed speaker IDs in your JSON output.
        - Use the EXACT speaker_id format shown above.
        """
        }

        let transcriptClues: String = {
            var lines = [
                "- If someone says \"Hey [Name]\" or \"Hi [Name]\" -> speaker is NOT [Name] (talking TO them)",
                "- If someone says \"Hi, I'm [Name]\" -> speaker IS [Name]",
                "- If someone is addressed by nickname (e.g., \"Bry\" for Brian), use the full name from the video tile",
            ]
            if hasMic && hasSystem {
                lines.append("- Lines starting with \"[mic]\" are the RECORDER speaking - use this to identify who the recorder is")
            } else if hasMic {
                lines.append("- Lines starting with \"[mic]\" are mic speakers - all speakers are mic")
            }
            return lines.joined(separator: "\n")
        }()

        // Smart transcript sampling to ensure coverage of all speakers
        let truncatedTranscript = sampleTranscript(transcript, speakerIds: speakerIds)

        return """
        TASK: Identify speakers in a video call by reading name labels from screenshots.

        \(audioStreamsBlock)

        \(recorderNameConstraintBlock)

        STEP 1 - READ THE NAME LABELS:
        Look at each video tile in the screenshots. At the BOTTOM of each tile is a TEXT LABEL with the participant's name.
        The text is usually white/light colored against a darker background.
        List EVERY name you can read from the tiles.

        \(stepsBlock)

        TRANSCRIPT CLUES:
        \(transcriptClues)

        Transcript excerpt:

        \(truncatedTranscript)

        \(mappingHeader)
        \(speakerList)

        \(importantBlock)

        Return JSON array: [{"speaker_id": "[exact ID from list above]", "name": "Full Name", "confidence": 0.0-1.0}]
        If you cannot identify a speaker, use "Unknown" with confidence 0.0.
        """
    }

    private func requestOllama(images: [ImagePayload], prompt: String) async throws -> String {
        var lastError: Error?
        for attempt in 0...maxRetries {
            try Task.checkCancellation()
            do {
                return try await performOllamaRequest(images: images, prompt: prompt)
            } catch {
                lastError = error
                if attempt >= maxRetries || !shouldRetry(error) {
                    throw error
                }
                let delay = retryDelaySeconds * pow(2.0, Double(attempt))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? NSError(
            domain: "SpeakerIdentifier",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Ollama request failed."]
        )
    }

    private func performOllamaRequest(images: [ImagePayload], prompt: String) async throws -> String {
        let url = ollamaBaseURL.appendingPathComponent("v1/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

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
            throw OllamaHTTPError(statusCode: http.statusCode)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let httpError = error as? OllamaHTTPError {
            return httpError.statusCode == 408 || httpError.statusCode == 429 || httpError.statusCode >= 500
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .networkConnectionLost,
                 .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func parseMappings(from rawResponse: String, targetSpeakerIds: [String]) -> [SpeakerMapping] {
        // DEBUG: Log raw response
        print("[SpeakerID DEBUG] Raw response length: \(rawResponse.count) chars")
        print("[SpeakerID DEBUG] Raw response (first 500 chars):")
        print(String(rawResponse.prefix(500)))
        print("[SpeakerID DEBUG] ---")

        let assistantText = extractAssistantText(from: rawResponse) ?? rawResponse
        print("[SpeakerID DEBUG] Extracted assistant text length: \(assistantText.count) chars")
        print("[SpeakerID DEBUG] Assistant text (first 500 chars):")
        print(String(assistantText.prefix(500)))
        print("[SpeakerID DEBUG] ---")

        let jsonString = extractJson(from: assistantText) ?? assistantText
        print("[SpeakerID DEBUG] Extracted JSON length: \(jsonString.count) chars")
        print("[SpeakerID DEBUG] JSON string:")
        print(jsonString)
        print("[SpeakerID DEBUG] ---")

        guard let data = jsonString.data(using: .utf8) else {
            print("[SpeakerID DEBUG] Failed to convert JSON string to data")
            return []
        }
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode([SpeakerMapping].self, from: data) {
            print("[SpeakerID DEBUG] Successfully decoded \(direct.count) mappings (direct array)")
            for m in direct {
                print("[SpeakerID DEBUG]   \(m.speakerId) -> \(m.name) (\(m.confidence))")
            }
            return direct
        }
        if let wrapped = try? decoder.decode(MappingWrapper.self, from: data) {
            print("[SpeakerID DEBUG] Successfully decoded \(wrapped.mappings.count) mappings (wrapped)")
            for m in wrapped.mappings {
                print("[SpeakerID DEBUG]   \(m.speakerId) -> \(m.name) (\(m.confidence))")
            }
            return wrapped.mappings
        }

        let lenient = parseMappingsLenient(from: data, targetSpeakerIds: targetSpeakerIds)
        if !lenient.isEmpty {
            print("[SpeakerID DEBUG] Successfully decoded \(lenient.count) mappings (lenient)")
            for m in lenient {
                print("[SpeakerID DEBUG]   \(m.speakerId) -> \(m.name) (\(m.confidence))")
            }
            return lenient
        }

        print("[SpeakerID DEBUG] Failed to decode JSON as mappings")
        // Try to see what the decode error is
        do {
            _ = try decoder.decode([SpeakerMapping].self, from: data)
        } catch {
            print("[SpeakerID DEBUG] Decode error: \(error)")
        }
        return []
    }

    private struct MappingWrapper: Codable {
        let mappings: [SpeakerMapping]
    }

    private func parseMappingsLenient(from data: Data, targetSpeakerIds: [String]) -> [SpeakerMapping] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        if let names = json as? [String],
           names.count == targetSpeakerIds.count,
           !names.isEmpty {
            var mappings: [SpeakerMapping] = []
            for (speakerId, rawName) in zip(targetSpeakerIds, names) {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                mappings.append(SpeakerMapping(speakerId: speakerId, name: name, confidence: 0.75))
            }
            if mappings.count == targetSpeakerIds.count {
                return mappings
            }
        }

        let items: [[String: Any]]
        if let array = json as? [[String: Any]] {
            items = array
        } else if let dict = json as? [String: Any] {
            if let mappings = dict["mappings"] as? [[String: Any]] {
                items = mappings
            } else if let mappings = dict["speaker_mappings"] as? [[String: Any]] {
                items = mappings
            } else if let mappings = dict["results"] as? [[String: Any]] {
                items = mappings
            } else {
                items = []
            }
        } else {
            items = []
        }

        guard !items.isEmpty else { return [] }

        var mappings: [SpeakerMapping] = []
        for item in items {
            let speakerId = firstString(
                in: item,
                keys: ["speaker_id", "speakerId", "speaker", "speaker_label", "id"]
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = firstString(
                in: item,
                keys: ["name", "person", "participant", "full_name"]
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !speakerId.isEmpty, !name.isEmpty else { continue }

            let confidenceRaw = firstAny(
                in: item,
                keys: ["confidence", "score", "probability", "prob", "certainty"]
            )
            let confidence = normalizedConfidence(confidenceRaw)

            mappings.append(SpeakerMapping(speakerId: speakerId, name: name, confidence: confidence))
        }
        return mappings
    }

    private func firstAny(in dict: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dict[key] {
                return value
            }
            if let value = dict.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                return value
            }
        }
        return nil
    }

    private func firstString(in dict: [String: Any], keys: [String]) -> String? {
        guard let value = firstAny(in: dict, keys: keys) else { return nil }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func normalizedConfidence(_ raw: Any?) -> Double {
        guard let raw else { return 0.0 }
        let value: Double?
        if let number = raw as? NSNumber {
            value = number.doubleValue
        } else if let string = raw as? String {
            let cleaned = string.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            value = Double(cleaned)
        } else {
            value = nil
        }
        guard var confidence = value else { return 0.0 }
        if confidence > 1.0, confidence <= 100.0 {
            confidence /= 100.0
        }
        if confidence < 0.0 { return 0.0 }
        if confidence > 1.0 { return 1.0 }
        return confidence
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
        if let fenced = extractFencedJson(from: text) {
            return fenced
        }

        let chars = Array(text)
        guard !chars.isEmpty else { return nil }

        for start in chars.indices where chars[start] == "{" || chars[start] == "[" {
            guard let end = findJsonEnd(in: chars, start: start) else { continue }
            let candidate = String(chars[start...end])
            guard let data = candidate.data(using: .utf8) else { continue }
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                return candidate
            }
        }
        return nil
    }

    private func extractFencedJson(from text: String) -> String? {
        let patterns = [
            #"(?s)```json\s*(\[[\s\S]*?\]|\{[\s\S]*?\})\s*```"#,
            #"(?s)```\s*(\[[\s\S]*?\]|\{[\s\S]*?\})\s*```"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
                  match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = candidate.data(using: .utf8) else { continue }
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                return candidate
            }
        }
        return nil
    }

    private func findJsonEnd(in chars: [Character], start: Int) -> Int? {
        var stack: [Character] = []
        var inString = false
        var escaped = false

        for index in start..<chars.count {
            let ch = chars[index]
            if inString {
                if escaped {
                    escaped = false
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    continue
                }
                if ch == "\"" {
                    inString = false
                }
                continue
            }

            if ch == "\"" {
                inString = true
                continue
            }

            if ch == "{" || ch == "[" {
                stack.append(ch)
                continue
            }

            if ch == "}" || ch == "]" {
                guard let last = stack.last else { return nil }
                let expectedOpen: Character = ch == "}" ? "{" : "["
                guard last == expectedOpen else { return nil }
                stack.removeLast()
                if stack.isEmpty {
                    return index
                }
            }
        }
        return nil
    }
}

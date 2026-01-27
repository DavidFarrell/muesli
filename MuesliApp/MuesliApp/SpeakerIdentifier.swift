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
        let mappings = parseMappings(from: rawResponse)
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
        let mappingSpeakerIds: [String] = {
            if hasSystem && hasMic {
                let systemOnly = speakerIds.filter { $0.lowercased().hasPrefix("system:") }
                return systemOnly.isEmpty ? speakerIds : systemOnly
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
        }()
        let speakerList = mappingSpeakerIds.map { "\($0) = ?" }.joined(separator: "\n")

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
        For example, if someone says "David, what do you think?" and mic:SPEAKER_01 responds, then David is the recorder.
        IMPORTANT: Do NOT assign the recorder's name to any system:SPEAKER_XX. They only appear as mic:SPEAKER_XX.

        STEP 3 - MATCH SYSTEM SPEAKERS:
        The remaining participants (everyone EXCEPT the recorder) should map to system speaker IDs.
        If you see 5 names on screen but only 4 system speakers, one of those names is the recorder - exclude them.
        \(hintBlock)
        """
            mappingHeader = "Map each SYSTEM speaker to their real name:"
            importantBlock = """
        IMPORTANT:
        - Only include system speakers in your JSON output. Do NOT include mic speakers.
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

    private func parseMappings(from rawResponse: String) -> [SpeakerMapping] {
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

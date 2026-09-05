import Foundation

/// Shared preview/meeting supervision policy. Progress means successfully
/// converted native samples, including digital silence. A system source may
/// legitimately have no callbacks: only explicit failures trigger its retries.
nonisolated struct CaptureSourceHealth: Sendable {
    enum Phase: String, Sendable { case idle, starting, healthy, recovering, failed, quarantined }
    private(set) var phase: Phase = .idle
    private(set) var generation = 0
    private(set) var attempts = 0
    private(set) var message: String?
    private(set) var lastProgressAt: Date?
    private(set) var startedAt: Date?
    private(set) var frameCount = 0
    private(set) var invalidated = false
    private var retryAt: Date?
    let maximumAttempts: Int

    init(maximumAttempts: Int = 3) { self.maximumAttempts = maximumAttempts }

    mutating func begin(generation: Int, now: Date = Date()) {
        self.generation = generation
        attempts += 1
        phase = .starting
        startedAt = now
        frameCount = 0
        lastProgressAt = nil
        invalidated = false
        retryAt = nil
    }

    mutating func progress(frames: Int, generation: Int, at now: Date = Date()) -> Bool {
        guard generation == self.generation, frames > frameCount, !invalidated else { return false }
        frameCount = frames
        lastProgressAt = now
        phase = .healthy
        message = nil
        attempts = 0
        retryAt = nil
        return true
    }

    mutating func fail(_ message: String, retryable: Bool = true, quarantined: Bool = false, now: Date = Date()) {
        self.message = message
        // Repeated failures from one bad generation must not push its retry
        // deadline forward forever or rearm a retry already reserved.
        if invalidated, retryable, !quarantined, phase == .recovering || phase == .failed { return }
        invalidated = true
        if quarantined { phase = .quarantined; retryAt = nil }
        else if retryable && attempts < maximumAttempts {
            phase = .recovering
            retryAt = now.addingTimeInterval(min(4, pow(2, Double(max(0, attempts - 1)))))
        } else { phase = .failed; retryAt = nil }
    }

    mutating func invalidate(generation: Int, now: Date = Date()) -> Bool {
        guard generation == self.generation, phase != .idle, !invalidated else { return false }
        fail("The audio device configuration changed.", now: now)
        retryAt = now
        return true
    }

    mutating func observeExpectedProgress(now: Date = Date(), stallThreshold: TimeInterval = 4) {
        if !invalidated, phase == .starting || phase == .healthy,
           let reference = lastProgressAt ?? startedAt, now.timeIntervalSince(reference) > stallThreshold {
            fail("Audio samples stopped arriving.", now: now)
            invalidated = false
        }
    }

    mutating func shouldRecover(now: Date = Date(), requireContinuousCallbacks: Bool,
                                canStartRecovery: Bool = true, stallThreshold: TimeInterval = 4) -> Bool {
        if requireContinuousCallbacks { observeExpectedProgress(now: now, stallThreshold: stallThreshold) }
        guard canStartRecovery, phase == .recovering, let retryAt, now >= retryAt else { return false }
        self.retryAt = nil // exactly one queued reconciliation owns this attempt
        return true
    }

    /// Fresh user intent resets retry allowance without retiring a still-valid
    /// native generation (for example Follow -> Pin on the same device).
    mutating func resetRecoveryBudget(now: Date = Date()) {
        attempts = 0
        if phase == .failed || phase == .recovering {
            phase = .recovering
            retryAt = now
        }
    }

    mutating func reset() { self = CaptureSourceHealth(maximumAttempts: maximumAttempts) }
}

nonisolated struct AudioRefreshResult: Sendable {
    enum Outcome: String, Sendable { case healthy, unverified, failed, notRequested }
    let microphone: Outcome
    let system: Outcome
    var verified: Bool { [microphone, system].allSatisfy { $0 == .healthy || $0 == .notRequested } }
    var message: String {
        if verified { return "Audio checked" }
        var parts: [String] = []
        if microphone == .failed { parts.append("Microphone unavailable") }
        if microphone == .unverified { parts.append("Waiting for microphone samples") }
        if system == .failed { parts.append("System audio unavailable") }
        if system == .unverified { parts.append("System audio has no verified samples yet") }
        return parts.joined(separator: ". ")
    }
}

/// Desired source ownership is distinct from a native generation. Stop retires
/// intent immediately, even if a framework call cannot finish yet.
nonisolated struct CaptureRequestIntent: Sendable {
    private(set) var revision = 0
    private(set) var active = false
    mutating func begin() -> Int { revision += 1; active = true; return revision }
    mutating func retire() { revision += 1; active = false }
    func matches(_ revision: Int) -> Bool { active && self.revision == revision }
}

nonisolated enum CapturePreviewPolicy {
    static func wantsPreview(isCapturing: Bool, isStarting: Bool, isFinalizing: Bool,
                             isStartScreenActive: Bool, onboarding: Bool) -> Bool {
        !isCapturing && !isStarting && !isFinalizing && isStartScreenActive && !onboarding
    }
}

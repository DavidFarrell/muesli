import AVFoundation
import CoreMedia
import XCTest

nonisolated private final class CaptureTestSender: FrameSending, @unchecked Sendable {
    struct Frame: Sendable { let stream: StreamID; let pts: Int64; let data: Data }
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var failures: [String] = []
    private var losses: [(Int64, Int64)] = []
    let failureComplete = DispatchSemaphore(value: 0)
    let complete: DispatchSemaphore?
    let expectedCount: Int
    init(expectedCount: Int = 0, complete: DispatchSemaphore? = nil) {
        self.expectedCount = expectedCount; self.complete = complete
    }
    func send(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        lock.withLock {
            frames.append(Frame(stream: stream, pts: ptsUs, data: payload))
            if frames.count == expectedCount { complete?.signal() }
        }
    }
    func reportLoss(stream: StreamID, ptsUs: Int64, frames: Int64, reason: String) {
        lock.withLock { losses.append((ptsUs, frames)) }
    }
    func reportFailure(stream: StreamID, message: String) {
        lock.withLock { failures.append(message) }
        failureComplete.signal()
    }
    func failureSnapshot() -> (Int, [(Int64, Int64)]) { lock.withLock { (failures.count, losses) } }
    func snapshot() -> [Frame] { lock.withLock { frames } }
}

nonisolated private final class PacketStore: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [CapturedMicAudio] = []
    func append(_ packet: CapturedMicAudio) { lock.withLock { packets.append(packet) } }
    func snapshot() -> [CapturedMicAudio] { lock.withLock { packets } }
}

private actor CaptureSinkBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting = false
    func wait() async {
        await withCheckedContinuation { continuation in self.continuation = continuation; waiting = true }
    }
    func isWaiting() -> Bool { waiting }
    func release() { continuation?.resume(); continuation = nil }
}

final class CaptureIngressTests: XCTestCase {
    func testSystemStopEvidencePrecedesUIAndDuplicateCallbacksNotifyOnce() async {
        let sender = CaptureTestSender()
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, stream: .system)
        await forwarder.beginMeeting()
        await forwarder.beginGeneration(8, writer: nil)
        let relay = SystemAudioCaptureRelay(generation: 8, forwarder: forwarder,
            display: MicDeliveryDisplayMailbox { _ in }) { error in
                sender.reportFailure(stream: .system, message: error.localizedDescription)
            }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<100 {
                relay.recordNativeStop(NSError(domain: "Synthetic system stop", code: 7))
            }
            finished.signal()
        }
        // Native evidence and notification admission must complete while the
        // real UI executor remains blocked, without invoking SCStream/hardware.
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(relay.hasStopped)
        XCTAssertEqual((relay.stopError as NSError?)?.code, 7)
        XCTAssertEqual(sender.failureSnapshot().0, 1)
        await relay.finish()
        XCTAssertTrue(relay.hasStopped, "Retiring buffers cannot erase native stop evidence")
        let fresh = SystemAudioCaptureRelay(generation: 9, forwarder: forwarder,
            display: MicDeliveryDisplayMailbox { _ in }, onStopped: { _ in })
        XCTAssertNil(fresh.stopError, "Terminal state belongs to the original relay generation")
    }

    nonisolated private static func packet(_ pts: Int64, generation: Int = 1, bytes: Int = 320) -> CapturedMicAudio {
        CapturedMicAudio(data: Data(repeating: 1, count: bytes), captureTimeUs: pts, generation: generation,
                         nativeSampleRate: 16000, nativeChannels: 1, nativeFrameCount: bytes / 2, formatEpoch: 1, outputSampleRate: 16000)
    }

    /// Exercises the exact callback factory used in AppModel, including
    /// native conversion and the bounded worker, while MainActor is blocked.
    /// A direct-only test of MicAudioForwarder cannot catch the audited bug.
    @MainActor
    func testApplicationCallbackContinuesSendingWhileMainActorIsBlocked() async throws {
        let complete = DispatchSemaphore(value: 0)
        let sender = CaptureTestSender(expectedCount: 400, complete: complete)
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1)
        await forwarder.beginMeeting(epoch: CaptureTimeline(epochMicroseconds: 1_000_000))
        await forwarder.beginGeneration(1, writer: sender)
        await forwarder.setOutputEnabled(true)
        var displayCount = 0
        let display = MicDeliveryDisplayMailbox { _ in displayCount += 1 }
        let ingress = MicAudioIngress.forwarding(to: forwarder, display: display)
        let callback = ingress.callback()
        DispatchQueue.global(qos: .userInitiated).async {
            let processor = MicCaptureProcessor(generation: 1, output: callback)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
            buffer.frameLength = 160
            buffer.floatChannelData![0].update(repeating: 0.25, count: 160)
            for index in 0..<400 { processor.receive(buffer, captureTimeUs: 1_000_000 + Int64(index) * 10_000) }
            processor.finish()
        }
        // Deliberately block, without yielding, until the recording sink has
        // received four seconds of real normalized samples.
        XCTAssertEqual(complete.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(displayCount, 0)
        XCTAssertEqual(sender.snapshot().reduce(0) { $0 + $1.data.count }, 128_000)
        XCTAssertEqual(sender.snapshot().map(\.pts), (0..<400).map { Int64($0) * 10_000 })
        await ingress.finish()
        XCTAssertEqual(ingress.snapshot().droppedFrames, 0)
    }

    @MainActor
    func testFinalUnknownTimestampFailureReachesSinkWhileMainActorIsBlocked() async throws {
        let sender = CaptureTestSender()
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1)
        await forwarder.beginMeeting(epoch: CaptureTimeline(epochMicroseconds: 1_000_000))
        await forwarder.beginGeneration(1, writer: sender)
        let ingress = MicAudioIngress.forwarding(to: forwarder, display: MicDeliveryDisplayMailbox { _ in },
                                                onProblem: await forwarder.captureFailureHandler())
        DispatchQueue.global().async {
            let processor = MicCaptureProcessor(generation: 1, onProblem: ingress.problemCallback(), output: ingress.callback())
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
            buffer.frameLength = 160
            processor.receive(buffer, captureTimeUs: nil)
            processor.finish()
        }
        XCTAssertEqual(sender.failureComplete.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(sender.failureSnapshot().0, 1)
        XCTAssertTrue(sender.failureSnapshot().1.isEmpty, "An unknown timestamp must not invent a range")
        await ingress.finish()
        XCTAssertEqual(ingress.snapshot().sourceProblemCount, 1, "Evidence survives final retirement")
        XCTAssertNil(ingress.snapshot().latestSourceProblem?.captureTimeUs)
    }

    func testFinalUnsupportedFormatReportsItsOwnNativeRangeWithoutFollowingPacket() async throws {
        let sender = CaptureTestSender()
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1)
        await forwarder.beginMeeting(epoch: CaptureTimeline(epochMicroseconds: 1_000_000))
        await forwarder.beginGeneration(9, writer: sender)
        let ingress = MicAudioIngress.forwarding(to: forwarder, display: MicDeliveryDisplayMailbox { _ in },
                                                onProblem: await forwarder.captureFailureHandler())
        let processor = MicCaptureProcessor(generation: 9, onProblem: ingress.problemCallback(), output: ingress.callback())
        let goodFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let good = AVAudioPCMBuffer(pcmFormat: goodFormat, frameCapacity: 160)!
        good.frameLength = 160
        good.floatChannelData![0].update(repeating: 0, count: 160)
        processor.receive(good, captureTimeUs: 1_000_000)
        let unsupportedFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 48000, channels: 1, interleaved: false))
        let bad = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: unsupportedFormat, frameCapacity: 480))
        bad.frameLength = 480
        processor.receive(bad, captureTimeUs: 2_000_000)
        processor.finish()
        await ingress.finish()
        let failure = sender.failureSnapshot()
        XCTAssertEqual(failure.0, 1)
        XCTAssertEqual(failure.1.count, 1)
        XCTAssertEqual(failure.1.first?.0, 1_000_000)
        XCTAssertEqual(failure.1.first?.1, 160)
        XCTAssertEqual(ingress.snapshot().latestSourceProblem?.nativeFrameCount, 480)
        XCTAssertEqual(ingress.snapshot().latestSourceProblem?.generation, 9)
    }

    func testDelayedBunchedDeliveryRetainsCaptureTimesAndRestartEpoch() async {
        let sender = CaptureTestSender()
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1)
        await forwarder.beginMeeting(epoch: CaptureTimeline(epochMicroseconds: 9_000_000))
        await forwarder.beginGeneration(1, writer: sender)
        await forwarder.setOutputEnabled(true)
        let display = MicDeliveryDisplayMailbox { _ in }
        let ingress = MicAudioIngress.forwarding(to: forwarder, display: display)
        for pts in [9_000_000, 9_010_000, 9_020_000] { ingress.callback()(Self.packet(Int64(pts))) }
        await ingress.finish()
        await forwarder.stop()
        await forwarder.beginGeneration(2, writer: sender)
        await forwarder.setOutputEnabled(true)
        _ = await forwarder.deliver(Self.packet(61_000_000, generation: 2))
        _ = await forwarder.deliver(Self.packet(9_030_000, generation: 1))
        XCTAssertEqual(sender.snapshot().map(\.pts), [0, 10_000, 20_000, 52_000_000])
    }

    func testBoundIncludesInFlightAndStopDrainsAcceptedPrefix() async {
        let barrier = CaptureSinkBarrier()
        let saved = PacketStore()
        let rejected = PacketStore()
        let ingress = MicAudioIngress(capacityBytes: 640, onRejected: { packet, _ in rejected.append(packet) }) { packet in
            if packet.captureTimeUs == 0 { await barrier.wait() }
            saved.append(packet)
        }
        XCTAssertTrue(ingress.enqueue(Self.packet(0)))
        while !(await barrier.isWaiting()) { await Task.yield() }
        XCTAssertTrue(ingress.enqueue(Self.packet(10_000)))
        for index in 2..<100 { XCTAssertFalse(ingress.enqueue(Self.packet(Int64(index) * 10_000))) }
        let snapshot = ingress.snapshot()
        XCTAssertEqual(snapshot.queuedBytes, 640)
        XCTAssertEqual(snapshot.droppedFrames, 98)
        XCTAssertEqual(rejected.snapshot().map(\.captureTimeUs), (2..<100).map { Int64($0) * 10_000 })
        XCTAssertEqual(snapshot.droppedSamples, 98 * 160)
        XCTAssertEqual(snapshot.droppedBytes, 98 * 320)
        XCTAssertEqual(snapshot.firstDroppedPTS, 20_000)
        XCTAssertEqual(snapshot.lastDroppedEndPTS, 1_000_000)
        await barrier.release()
        await ingress.finish()
        XCTAssertEqual(saved.snapshot().map(\.captureTimeUs), [0, 10_000])
        XCTAssertEqual(ingress.snapshot().queuedBytes, 0)
        XCTAssertFalse(ingress.enqueue(Self.packet(1_000_000)))
        XCTAssertEqual(rejected.snapshot().last?.captureTimeUs, 1_000_000)
    }

    func testSystemNativeRelayNormalizes48000StereoAndPreservesCapturePTSOffUI() async throws {
        let sender = CaptureTestSender()
        let timeline = CaptureTimeline(epochMicroseconds: 3_000_000)
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, stream: .system)
        await forwarder.beginMeeting(epoch: timeline)
        await forwarder.beginGeneration(8, writer: sender)
        await forwarder.setOutputEnabled(true)
        let relay = SystemAudioCaptureRelay(generation: 8, forwarder: forwarder,
                                           display: MicDeliveryDisplayMailbox { _ in }, onStopped: { _ in })
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        pcm.frameLength = 48000
        pcm.floatChannelData![0].update(repeating: 0.5, count: 48000)
        pcm.floatChannelData![1].update(repeating: 0, count: 48000)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                                       presentationTimeStamp: CMTime(value: 3_250_000, timescale: 1_000_000),
                                       decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                                            sampleCount: 48000, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer), noErr)
        let native = try XCTUnwrap(sampleBuffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(native, blockBufferAllocator: kCFAllocatorDefault,
                                                                     blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                                     bufferList: pcm.audioBufferList), noErr)
        CMSampleBufferSetDataReady(native)
        relay.receive(native)
        await relay.finish()
        let frames = sender.snapshot()
        XCTAssertEqual(frames.first?.pts, 250_000)
        XCTAssertEqual(frames.reduce(0) { $0 + $1.data.count / 2 }, 16000)
        XCTAssertTrue(frames.allSatisfy { $0.stream == .system })
        let samples = frames.reduce(into: Data()) { $0.append($1.data) }.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(Double(samples[8000]) / 32767, 0.25, accuracy: 0.001, "System stereo keeps arithmetic channel averaging")
        XCTAssertEqual(relay.snapshot().nativeSampleRate, 48000)
        XCTAssertEqual(relay.snapshot().nativeChannels, 2)
        XCTAssertEqual(relay.snapshot().callbackCount, 1)
        XCTAssertEqual(relay.ingressSnapshot().droppedFrames, 0)
    }

    func testSourcesAndScreenshotUseSameEpochThroughRestart() async {
        let sender = CaptureTestSender()
        let timeline = CaptureTimeline(epochMicroseconds: 5_000_000)
        let mic = MicAudioForwarder(sampleRate: 16000, channels: 1)
        let system = MicAudioForwarder(sampleRate: 16000, channels: 1, stream: .system)
        for source in [mic, system] {
            await source.beginMeeting(epoch: timeline)
            await source.beginGeneration(1, writer: sender)
            await source.setOutputEnabled(true)
            _ = await source.deliver(Self.packet(5_123_000))
        }
        let screenshotPTS = CMTime(value: 5_123_000, timescale: 1_000_000)
        XCTAssertEqual(CaptureTimeline.microseconds(CMTimeSubtract(screenshotPTS, timeline.epochPTS)), 123_000)
        XCTAssertEqual(sender.snapshot().map(\.pts), [123_000, 123_000])
        XCTAssertEqual(sender.snapshot().map(\.stream), [.mic, .system])
        await mic.stop()
        await mic.beginGeneration(2, writer: sender)
        await mic.setOutputEnabled(true)
        _ = await mic.deliver(Self.packet(75_123_000, generation: 2))
        _ = await system.deliver(Self.packet(75_123_000))
        XCTAssertEqual(sender.snapshot().suffix(2).map(\.pts), [70_123_000, 70_123_000])
    }
}

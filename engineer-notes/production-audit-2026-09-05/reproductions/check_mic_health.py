#!/usr/bin/env python3
"""Run actual AppModel mic/preview callbacks and Refresh without hardware init.

Methods and CaptureSourceHealth are extracted unchanged from the selected source.
Only peripheral UI, device enumeration, and native restart are stand-ins; restart
records admission and fails promptly so the bounded Refresh outcome is observable.
A plain result value models an off-UI packet received 15 seconds before publication.
"""
import argparse
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
APP = 'MuesliApp/MuesliApp/'
parser = argparse.ArgumentParser()
parser.add_argument('--source-ref')
args = parser.parse_args()


def source(name):
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:{APP}{name}'], cwd=ROOT, text=True)
    return (ROOT / APP / name).read_text()


def method(text, marker):
    start = text.index(marker)
    brace = text.index('{', start)
    level, cursor = 1, brace + 1
    while level:
        if text[cursor] == '{': level += 1
        elif text[cursor] == '}': level -= 1
        cursor += 1
    return text[start:cursor].replace('private func ', 'func ', 1)


model = source('AppModel.swift')
methods = '\n'.join(method(model, marker) for marker in [
    'private func onMicAudioDelivered(', 'private func handlePreviewMicAudio(',
    'func refreshMicrophonesAwaitingCompletion()'])
program = r'''
import Foundation
nonisolated enum AudioLog { static func event(_ name: String, _ fields: [String: Any]) {} }
nonisolated enum AudioDeviceManager { static func snapshot() -> String { "synthetic" } }
nonisolated enum MicAudioForwarder {
 struct DeliveryResult: Sendable {
  let totalFrameCount: Int, receivedAt: Date, level: Float, frameSampleCount: Int, elapsedSeconds: Double
  let isFirstFrame: Bool, isResumptionAfterGap: Bool
 }
}
@MainActor final class Meters {
 var alert = "Existing recovery warning"
 func clearMicAlert() { alert = "" }
}
@MainActor final class CaptureEngine {
 var health = CaptureSourceHealth()
 init() { health.begin(generation: 1); _ = health.progress(frames: 1, generation: 1) }
 func supervise(allowRecovery: Bool) -> Bool { false }
 func resetRecoveryBudget() {}
 func restartCapture() async -> Bool { false }
}
@MainActor final class AppModel {
 var isCapturing = true, isFinalizing = false, isStartingMeeting = false, isStartScreenActive = false, transcribeMic = true
 var micEngineGeneration = 7, previewMicGeneration = 7
 var micHealth = CaptureSourceHealth(), previewMicHealth = CaptureSourceHealth()
 var debugMicErrorMessage = "Existing failure", meters = Meters(), micNoAudioRecoveryAttempts = 2, micRecoveryParked = true
 var micEngineStartedAt: Date?, micLevel: Float = 0, debugMicBuffers = 0, debugMicFrames = 0, debugMicPTS = 0.0
 var lastMicAudioAt: Date?, micFrameCount = 0, debugMicFormat = "", micOutputSampleRate = 16000, micOutputChannels = 1
 var previewVoiceProcessingDowngraded = false, micVoiceProcessingDowngraded = false
 var captureEngine = CaptureEngine(), micLifecycleTask: Task<Void, Never>?, restartCount = 0
 func publishMicError() {}
 func publishMicMeters() {}
 func resetMicRecoveryLadder() { micNoAudioRecoveryAttempts = 0; micRecoveryParked = false; meters.clearMicAlert() }
 func loadInputDevices() {}
 func loadOutputDevices() {}
 func observeMicrophoneProblems(preview: Bool) {}
 func enqueueMicLifecycle(_ name: String, operation: @escaping @MainActor (AppModel) async -> Void) {
  micLifecycleTask = Task { await operation(self) }
 }
 func restartMeetingMicEngineForInputSwitch() async { restartCount += 1; micHealth.fail("Synthetic restart refused", retryable: false) }
 func refreshHomeLevelPreview() async { restartCount += 1; previewMicHealth.fail("Synthetic restart refused", retryable: false) }
 METHODS
}
@main struct Reproduction {
 @MainActor static func main() async {
  var failures = 0
  for preview in [false, true] {
   for delayed in [false, true] {
    let model = AppModel()
    model.isCapturing = !preview; model.isStartScreenActive = preview
    let received = Date().addingTimeInterval(delayed ? -15 : 0)
    model.micHealth.begin(generation: 7, now: received)
    model.previewMicHealth.begin(generation: 7, now: received)
    let packet = MicAudioForwarder.DeliveryResult(totalFrameCount: 1, receivedAt: received,
      level: 0, frameSampleCount: 160, elapsedSeconds: 0, isFirstFrame: true, isResumptionAfterGap: false)
    if preview { model.handlePreviewMicAudio(packet) }
    else { model.onMicAudioDelivered(packet, generation: 7) }
    let phase = preview ? model.previewMicHealth.phase : model.micHealth.phase
    let healthy = phase == .healthy, warningCleared = model.meters.alert.isEmpty
    if healthy == delayed || warningCleared == delayed { failures += 1 }
    print("preview=\(preview) delayed=\(delayed) callback_healthy=\(healthy) warning_cleared=\(warningCleared)")
    if !preview {
     let result = await model.refreshMicrophonesAwaitingCompletion()
     if result.verified == delayed || model.restartCount != (delayed ? 1 : 0) { failures += 1 }
     print("delayed=\(delayed) Refresh_verified=\(result.verified) restart_admissions=\(model.restartCount)")
    }
   }
  }
  let retired = AppModel(), now = Date()
  retired.micHealth.begin(generation: 8, now: now); retired.micEngineGeneration = 8
  let packet = MicAudioForwarder.DeliveryResult(totalFrameCount: 1, receivedAt: now, level: 0,
    frameSampleCount: 160, elapsedSeconds: 0, isFirstFrame: true, isResumptionAfterGap: false)
  retired.onMicAudioDelivered(packet, generation: 7)
  if retired.micHealth.phase == .healthy || retired.meters.alert.isEmpty { failures += 1 }
  if failures > 0 { exit(1) }
 }
}
'''.replace('METHODS', methods)
with tempfile.TemporaryDirectory(prefix='muesli-mic-health-', dir='/private/tmp') as directory:
    work = pathlib.Path(directory)
    health = work / 'CaptureSourceHealth.swift'; health.write_text(source('CaptureSourceHealth.swift'))
    main = work / 'main.swift'; main.write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(health), str(main), '-o', str(work / 'run')], check=True)
    result = subprocess.run([str(work / 'run')], timeout=15)
    raise SystemExit(result.returncode)

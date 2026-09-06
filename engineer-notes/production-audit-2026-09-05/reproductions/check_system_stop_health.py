#!/usr/bin/env python3
"""Run actual native-stop/supervision/meter methods without SCK hardware setup.

The complete relevant methods and callback bodies come from the selected source;
only framework, meter and converted-buffer containers are stand-ins. The queued
native-stop UI handler is deliberately delivered after polling/meter observation.
"""
import argparse
import pathlib
import subprocess
import tempfile
ROOT = pathlib.Path(__file__).resolve().parents[3]
APP = 'MuesliApp/MuesliApp/'
parser = argparse.ArgumentParser(); parser.add_argument('--source-ref'); args = parser.parse_args()

def source(name):
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:{APP}{name}'], cwd=ROOT, text=True)
    return (ROOT / APP / name).read_text()


def block(text, marker):
    start = text.index(marker); start = text.index('{', start); depth = 1; end = start + 1
    while depth:
        if text[end] == '{': depth += 1
        if text[end] == '}': depth -= 1
        end += 1
    return text[start + 1:end - 1]

text = source('CaptureEngine.swift')
modern = 'private func observeSystemSourceProblems()' in text
stop = block(text, 'func stream(_ stream: SCStream, didStopWithError error: Error)')
record = 'func recordNativeStop(_ error: Error) {' + block(text, 'func recordNativeStop(') + '}' if modern else ''
observe = 'func observeSystemSourceProblems() -> Bool {' + block(text, 'private func observeSystemSourceProblems()') + '}' if modern else ''
store = '''private var nativeStopError: Error?
 var stopError: Error? { stoppedLock.withLock { nativeStopError } }
 var hasStopped: Bool { stopError != nil }''' if modern else '''private var stoppedByFramework = false
 var hasStopped: Bool { stoppedLock.withLock { stoppedByFramework } }'''
display = block(text, 'let display = MicDeliveryDisplayMailbox').split('result in', 1)[1]
notification = block(text, 'Task { @MainActor [weak self] in').split('[weak self] in', 1)[1]
program = r'''
import Foundation
nonisolated struct Injected: Error {}
nonisolated final class Relay: @unchecked Sendable {
 let stoppedLock = NSLock()
 STORE
 struct Snapshot { var conversionFailures = 0; var convertedFrames = 160 }
 struct Problem { let message = "Recorded conversion failure" }
 struct Ingress { var sourceProblemCount = 0; var latestSourceProblem: Problem? }
 var value = Snapshot(), ingress = Ingress()
 func snapshot() -> Snapshot { value }
 func ingressSnapshot() -> Ingress { ingress }
 func onStopped(_ error: Error) {}
 func didStop(_ error: Error) { STOP }
 RECORD
}
nonisolated struct Result {
 let level: Float = 0.5, totalFrameCount = 1, frameSampleCount = 160, elapsedSeconds: Double = 1
}
@MainActor final class Owner { var isBusy = false }
@MainActor final class Native { var isRetired = false }
@MainActor final class Meter {
 var error = "-", bufferUpdates = 0
 func setSystemError(message: String, errorCount: Int) { error = message }
 func updateSystem(level: Float, buffers: Int, frames: Int, pts: Double, format: String) { bufferUpdates += 1 }
}
@MainActor final class Probe {
 var retirementPending = false, operationOwner = Owner(), nativeSource: Native?, request: Int? = 1
 var health = CaptureSourceHealth(), relay: Relay? = Relay(), lastConversionFailures = 0, generation = 1
 var lastSourceProblemCount = 0, observedNativeStop = false, stopping = false
 var debugSystemErrorMessage = "-", debugAudioErrors = 0, metersModel: Meter? = Meter()
 var systemLevel: Float = 0, debugSystemBuffers = 0, debugSystemFrames = 0, debugSystemPTS = 0.0, debugSystemFormat = "-"
 var onStreamStopped: ((Error) -> Void)?
 func clearRetiredSource() {}
 func supervise(allowRecovery: Bool = true) -> Bool { SUPERVISE }
 OBSERVE
 func surface(_ result: Result) {
  let currentGeneration = generation
  let callback = { [weak self] (result: Result) in DISPLAY }
  callback(result)
 }
 func deliverNotification(_ error: Error) {
  let currentGeneration = generation
  let callback = { [weak self] in NOTIFICATION }
  callback()
 }
}
@main struct Reproduction {
 @MainActor static func main() async {
  var failures = 0
  for kind in ["native_stop", "conversion_failure", "silence"] {
   for observer in ["supervise", "display"] {
    let probe = Probe(); probe.health.begin(generation: 1)
    let relay = probe.relay!
    if kind == "native_stop" { await Task.detached { relay.didStop(Injected()) }.value }
    if kind == "conversion_failure" {
     relay.value.conversionFailures = 1
     relay.ingress.sourceProblemCount = 1; relay.ingress.latestSourceProblem = .init()
    }
    var notifications = 0
    probe.onStreamStopped = { _ in notifications += 1 }
    if observer == "supervise" { _ = probe.supervise(allowRecovery: false) }
    else { probe.surface(Result()) }
    let verified = AudioRefreshResult(microphone: .notRequested,
     system: probe.health.phase == .healthy ? .healthy : .unverified).verified
    let expected = kind == "silence"
    if verified != expected { failures += 1 }
    print("kind=\(kind) observer=\(observer) healthy=\(probe.health.phase.rawValue) Refresh_verified=\(verified)")
    if kind == "native_stop" {
     let recoveryAt = Date().addingTimeInterval(10)
     let reserved = probe.health.shouldRecover(now: recoveryAt, requireContinuousCallbacks: false)
     probe.deliverNotification(Injected())
     for _ in 0..<100 { _ = probe.supervise(allowRecovery: false); probe.surface(Result()) }
     let rearmed = probe.health.shouldRecover(now: recoveryAt, requireContinuousCallbacks: false)
     if !reserved || rearmed || notifications != 1 || probe.debugAudioErrors != 1 { failures += 1 }
     print("terminal_notifications=\(notifications) error_count=\(probe.debugAudioErrors)")
    }
   }
  }
  if failures > 0 { exit(1) }
 }
}
'''
for key, value in [('STORE', store), ('STOP', stop), ('RECORD', record), ('SUPERVISE', block(text, 'func supervise(')),
                   ('OBSERVE', observe), ('DISPLAY', display), ('NOTIFICATION', notification)]:
    program = program.replace(key, value)
with tempfile.TemporaryDirectory(prefix='muesli-system-health-', dir='/private/tmp') as directory:
    work = pathlib.Path(directory)
    health = work/'CaptureSourceHealth.swift'; health.write_text(source('CaptureSourceHealth.swift'))
    main = work/'main.swift'; main.write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work/'modules'), str(health), str(main), '-o', str(work/'run')], check=True)
    raise SystemExit(subprocess.run([str(work/'run')], timeout=10).returncode)

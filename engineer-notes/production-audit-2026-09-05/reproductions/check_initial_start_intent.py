#!/usr/bin/env python3
"""Synthetic actual-method reproduction; no AppModel initialization or hardware.

Extracts AppModel's actual queue, initial enqueue block, continuation/source
predicates, start-entry guards, adoption and failed-start catch, plus the actual
Quit coordinator and CaptureOperationOwner. Native capture, final cleanup and
source/UI containers are stand-ins; no hardware-backed AppModel is initialized.
"""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[3]
app = root / 'MuesliApp/MuesliApp'
model = (app / 'AppModel.swift').read_text()

def body(text, marker):
    start = text.index(marker)
    brace = text.index('{', start)
    level, cursor = 1, brace + 1
    while level:
        level += (text[cursor] == '{') - (text[cursor] == '}')
        cursor += 1
    return text[brace + 1:cursor - 1]

def declaration(text, marker):
    start = text.index(marker)
    content = body(text, marker)
    brace = text.index('{', start)
    return text[start:brace + 1] + content + '}'

methods = '\n'.join(declaration(model, marker).replace('private func ', 'func ', 1) for marker in [
    'private func enqueueMicLifecycle(', 'private func meetingMicStartContext(',
    'private func isCurrentMicStart(', 'private func isCurrentSource(', 'private func retireMeetingMicSource('
])
context = declaration(model, 'private struct MeetingMicStartContext').replace('private struct', 'struct', 1)
initial_start = model.index('            let initialMicIntent = micSourceIntent')
initial_end = model.index('            guard isCurrentSource(recorder, eventsURL: sessionEventsURL)', initial_start)
initial = model[initial_start:initial_end]
def continuation_at(start):
    lines = model[start:].splitlines()
    count = 2 if lines[1].strip().startswith('try ApplicationQuitCoordinator.shared.requireCurrentStart(') else 1
    return '\n'.join(lines[:count])

def continuation_after(marker):
    start = model.index('            guard isCurrentSource(recorder, eventsURL: sessionEventsURL)', model.index(marker))
    return continuation_at(start)

after_mic = continuation_at(initial_end)
before_system = continuation_after('            await micAudioForwarder.beginMeeting(epoch: captureTimeline)')
before_backend = continuation_after('            let formats = await captureEngine.waitForAudioFormats(timeoutSeconds: 2.0)')
start_body = body(model, 'private func startMeeting(resuming ')
failure_body = body(start_body[start_body.rindex('        } catch {'):], '} catch {')
entry = body(model, 'private func startMeetingMicEngine(').split('        startMicFramesWatchdog()', 1)[0]
attempt = body(model, 'private func attemptMeetingMicEngineStart(')
adopt = body(attempt, 'adoption: { [self] claim in').split('claim in', 1)[1]
coordinator = declaration((app / 'ApplicationQuitCoordinator.swift').read_text(), 'final class ApplicationQuitCoordinator:')

program = r'''
import Foundation
import Combine
nonisolated enum AudioLog { static func event(_ name: String, _ fields: [String: String] = [:]) {} }
nonisolated enum StreamID { case mic }
nonisolated final class LocalAudioRecorder: Sendable { let id = UUID(); func reportFailure(stream: StreamID, message: String) {} }
nonisolated final class MeetingFileAccess: Sendable {}
nonisolated struct CaptureTimeline: Sendable {}
nonisolated final class NativeProbe: @unchecked Sendable {
 private let lock = NSLock(); private var calls = 0
 func record() { lock.withLock { calls += 1 } }
 var count: Int { lock.withLock { calls } }
}
@MainActor COORDINATOR
@MainActor final class AppModel {
 CONTEXT
 var micSourceIntent: UUID? = UUID(), micEngineGeneration = 1
 var isCapturing = true, isFinalizing = false, isStartingMeeting = true, transcribeMic = true
 var micEngine: UUID?, micEngineStartedAt: Date?
 var sourceRecorder: LocalAudioRecorder? = LocalAudioRecorder()
 var sourceTimeline: CaptureTimeline? = CaptureTimeline()
 var currentMeetingAccess: MeetingFileAccess? = MeetingFileAccess()
 var transcriptEventsURL: URL? = URL(fileURLWithPath: "/synthetic/source/events")
 var pendingMicOperation: (@MainActor (AppModel) async -> Void)?
 var pendingMicReason = "", micLifecycleTask: Task<Void, Never>?, micRecoveryPending = false
 let owner = CaptureOperationOwner(), probe = NativeProbe()
 let initialStartIntent = ApplicationQuitCoordinator.shared.startIntent
 enum Screen { case start, session }
 var activeScreen = Screen.session, shareableContentError: String?, backendPythonCandidatePath: String?
 var isSandboxed = false, prepareCalls = 0, cleanupCalls = 0, continuations = 0
 var cleanedRecorder: UUID?
 func appendBackendLog(_ value: String, toTail: Bool) {}
 func teardownFailedMeetingStart(session: UUID, wasResume: Bool, priorMetadata: Int?) async {
  cleanupCalls += 1; cleanedRecorder = sourceRecorder?.id
  retireMeetingMicSource(); sourceRecorder = nil; transcriptEventsURL = nil; micEngine = nil
 }
 METHODS
 func enqueueInitialStart() async {
  let startIntent = initialStartIntent, recorder = sourceRecorder!, sessionEventsURL = transcriptEventsURL!
  let session = UUID(), meeting: Int? = nil, metadata: Int? = nil
  let work = try? ShutdownWorkRegistry.shared.begin("Synthetic initial setup")
  defer { work?.finish() }
  do { INITIAL
   AFTER_MIC
   continuations += 1
  } catch { FAILURE_BODY }
 }
 func suspendedInitialContinuation(stage: String, entered: TaskCompletion, release: TaskCompletion) async {
  let startIntent = initialStartIntent, recorder = sourceRecorder!, sessionEventsURL = transcriptEventsURL!
  let session = UUID(), meeting: Int? = nil, metadata: Int? = nil
  let work = try? ShutdownWorkRegistry.shared.begin("Synthetic initial setup")
  defer { work?.finish() }
  entered.markCompleted(); _ = await release.wait(timeoutSeconds: 10)
  do {
   if stage == "before-system" {
    BEFORE_SYSTEM
   } else {
    BEFORE_BACKEND
   }
   probe.record(); continuations += 1
  } catch { FAILURE_BODY }
 }
 func startMeetingMicEngine(expectedSourceIntent: UUID? = nil) async {
  ENTRY
  let engine = UUID(), generation = micEngineGeneration, probe = self.probe
  try? await owner.perform(operation: { probe.record() }, adoption: { [self] claim in ADOPT }, cleanupIfAbandoned: {})
 }
 func enqueueEstablishedRecovery() async {
  enqueueMicLifecycle("established-recovery") { model in await model.startMeetingMicEngine() }
  await micLifecycleTask?.value
 }
}
@main struct Reproduction {
 @MainActor static func main() async {
  var failures = 0
  for scenario in ["initial-healthy", "initial-quit-cancel", "established-recovery-quit-cancel"] {
   let model = AppModel(), entered = TaskCompletion(), release = TaskCompletion()
   let quit = ApplicationQuitCoordinator.shared, originalIntent = quit.startIntent
   model.isStartingMeeting = scenario != "established-recovery-quit-cancel"
   quit.configure(accepted: {}, prepare: { model.prepareCalls += 1; model.retireMeetingMicSource() }, cancelled: {})
   model.enqueueMicLifecycle("previous-native-operation") { _ in
    entered.markCompleted(); _ = await release.wait(timeoutSeconds: 10)
   }
   _ = await entered.wait(timeoutSeconds: 2)
   let queued = Task { @MainActor in
    if scenario == "established-recovery-quit-cancel" { await model.enqueueEstablishedRecovery() }
    else { await model.enqueueInitialStart() }
   }
   while model.pendingMicOperation == nil { await Task.yield() }
   if scenario != "initial-healthy" {
    quit.requestQuit { _ in }; quit.cancelQuit()
   }
   let originalRetired = !quit.canContinueStart(originalIntent)
   release.markCompleted(); await queued.value
   let expected = scenario == "initial-quit-cancel" ? 0 : 1
   let actual = model.probe.count
   print("\(scenario): original_start_retired=\(originalRetired) native_admissions=\(actual) expected=\(expected) adopted=\(model.micEngine != nil) async_quit_prepare=\(model.prepareCalls)")
   if actual != expected { failures += 1 }
   if scenario == "initial-quit-cancel" && (model.cleanupCalls != 1 || model.continuations != 0) { failures += 1 }
   if scenario == "established-recovery-quit-cancel" && model.cleanupCalls != 0 { failures += 1 }
  }
  for stage in ["before-system", "before-backend"] {
   for replaceSource in [false, true] {
    let model = AppModel(), entered = TaskCompletion(), release = TaskCompletion()
    let quit = ApplicationQuitCoordinator.shared, originalRecorder = model.sourceRecorder!.id
    quit.configure(accepted: {}, prepare: { model.prepareCalls += 1; model.retireMeetingMicSource() }, cancelled: {})
    let pending = Task { @MainActor in await model.suspendedInitialContinuation(stage: stage, entered: entered, release: release) }
    _ = await entered.wait(timeoutSeconds: 2)
    quit.requestQuit { _ in }; quit.cancelQuit()
    if replaceSource {
     model.sourceRecorder = LocalAudioRecorder(); model.micSourceIntent = UUID()
     model.transcriptEventsURL = URL(fileURLWithPath: "/synthetic/replacement/events")
    }
    let replacementID = model.sourceRecorder?.id
    release.markCompleted(); await pending.value
    let expectedCleanup = replaceSource ? 0 : 1
    let retainedCorrectSource = replaceSource ? model.sourceRecorder?.id == replacementID : model.cleanedRecorder == originalRecorder
    print("\(stage) replaced=\(replaceSource): native_admissions=\(model.probe.count) cleanup=\(model.cleanupCalls) expected_cleanup=\(expectedCleanup) correct_source=\(retainedCorrectSource)")
    if model.probe.count != 0 || model.cleanupCalls != expectedCleanup || !retainedCorrectSource { failures += 1 }
   }
  }
  if failures > 0 { exit(1) }
 }
}
'''
for key, value in [('COORDINATOR', coordinator), ('CONTEXT', context), ('METHODS', methods),
                   ('INITIAL', initial), ('AFTER_MIC', after_mic), ('BEFORE_SYSTEM', before_system),
                   ('BEFORE_BACKEND', before_backend), ('FAILURE_BODY', failure_body), ('ENTRY', entry), ('ADOPT', adopt)]:
    program = program.replace(key, value)
with tempfile.TemporaryDirectory(prefix='muesli-queued-mic-intent-', dir='/private/tmp') as temporary:
    work = pathlib.Path(temporary)
    files = []
    for name in ['CaptureOperationOwner.swift', 'TaskCompletion.swift', 'ShutdownWorkRegistry.swift']:
        destination = work / name
        destination.write_text((app / name).read_text())
        files.append(str(destination))
    main = work / 'main.swift'; main.write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), *files, str(main), '-o', str(work / 'run')], check=True)
    raise SystemExit(subprocess.run([str(work / 'run')], timeout=25).returncode)

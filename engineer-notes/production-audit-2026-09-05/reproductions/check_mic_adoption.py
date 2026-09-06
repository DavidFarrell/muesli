#!/usr/bin/env python3
"""Execute the actual AppModel adoption block without hardware-backed AppModel init.

Only storage/UI containers and the native engine (a gated UUID) are stand-ins.
The source predicate, post-start adoption block, CaptureOperationOwner, deadline,
and shutdown registry are read from the selected actual source. No app is launched.
The baseline and corrected wiring differ intentionally: baseline releases the
operation before its UI adoption; corrected code passes its actual claim callback.
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
    path = APP + name
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:{path}'], cwd=ROOT, text=True)
    return (ROOT / path).read_text()

def block(text, marker):
    start = text.index(marker)
    brace = text.index('{', start)
    level = 1
    cursor = brace + 1
    while level:
        if text[cursor] == '{': level += 1
        elif text[cursor] == '}': level -= 1
        cursor += 1
    return text[brace + 1:cursor - 1]

model = source('AppModel.swift')
method = block(model, 'private func attemptMeetingMicEngineStart(')
modern = 'adoption: { [self] claim in' in method
if modern:
    body = block(method, 'adoption: { [self] claim in').split('claim in', 1)[1]
    signature = 'func adopt(generation: Int, engine: UUID, ingress: Int, context: MeetingMicStartContext, claim: CaptureOperationOwner.Claim)'
    source_predicate = block(model, 'private func isCurrentMicStart(')
    retirement = block(model, 'private func retireMeetingMicSource(')
    launch = '''try? await owner.perform(operation: {
        entered.markCompleted(); _ = await nativeReturn.wait(timeoutSeconds: 10)
    }, adoption: { claim in
        model.adopt(generation: 1, engine: engine, ingress: 0, context: context, claim: claim)
    }, cleanupIfAbandoned: { cleaned.markCompleted() })'''
else:
    start = method.index('        guard generation == micEngineGeneration else {')
    body = method[start:method.index('        // Only open the pipe', start)]
    signature = 'func adopt(generation: Int, engine: UUID, ingress: Int, context: MeetingMicStartContext) async'
    source_predicate = 'true'
    retirement = ''
    launch = '''try? await owner.perform(operation: {
        entered.markCompleted(); _ = await nativeReturn.wait(timeoutSeconds: 10)
    }, cleanupIfAbandoned: { cleaned.markCompleted() })
    await model.adopt(generation: 1, engine: engine, ingress: 0, context: context)'''
current_source = block(model, 'private func isCurrentSource(')
program = r'''
import Foundation
nonisolated enum AudioLog { static func event(_ name: String, _ fields: [String: Int]) {} }
nonisolated enum StreamID { case mic }
nonisolated final class LocalAudioRecorder: Sendable { func reportFailure(stream: StreamID, message: String) {} }
@MainActor final class ApplicationQuitCoordinator {
 static let shared = ApplicationQuitCoordinator(); var startIntent = UUID()
 func canContinueStart(_ id: UUID) -> Bool { id == startIntent }
}
@MainActor final class AppModel {
 struct MeetingMicStartContext { let sourceIntent: UUID; let quitIntent: UUID; let recorder: LocalAudioRecorder; let eventsURL: URL }
 var micSourceIntent: UUID? = UUID(), micEngineGeneration = 1
 var isCapturing = true, isFinalizing = false, transcribeMic = true
 var micEngine: UUID?, micEngineStartedAt: Date?
 var sourceRecorder: LocalAudioRecorder? = LocalAudioRecorder()
 var transcriptEventsURL: URL? = URL(fileURLWithPath: "/synthetic/source/events")
 var nativeStops = 0
 func context() -> MeetingMicStartContext { MeetingMicStartContext(sourceIntent: micSourceIntent!,
     quitIntent: ApplicationQuitCoordinator.shared.startIntent, recorder: sourceRecorder!, eventsURL: transcriptEventsURL!) }
 func stopNativeMicrophone(_ engine: UUID, ingress: Int, preview: Bool) async -> Bool { nativeStops += 1; return true }
 func isCurrentSource(_ recorder: LocalAudioRecorder, eventsURL: URL) -> Bool { CURRENT_SOURCE }
 func isCurrentMicStart(_ context: MeetingMicStartContext) -> Bool { SOURCE_PREDICATE }
 func retireMeetingMicSource() { RETIREMENT }
 SIGNATURE { ADOPTION_BODY }
 func stopAndFinish(replacement: Bool) {
   isFinalizing = true; retireMeetingMicSource(); micEngine = nil; isCapturing = false
   sourceRecorder = nil; transcriptEventsURL = nil; isFinalizing = false
   if replacement {
     micSourceIntent = UUID(); sourceRecorder = LocalAudioRecorder()
     transcriptEventsURL = URL(fileURLWithPath: "/synthetic/replacement/events"); isCapturing = true
   }
 }
}
@main struct Reproduction {
 @MainActor static func main() async {
   var failures = 0
   for scenario in ["stop_finished", "stop_then_new_source", "quit_cancel", "same_source_new_generation", "healthy"] {
     let model = AppModel(), owner = CaptureOperationOwner(shutdown: ShutdownWorkRegistry())
     let entered = TaskCompletion(), nativeReturn = TaskCompletion(), cleaned = TaskCompletion()
     let engine = UUID(), context = model.context()
     let pending = Task { @MainActor in LAUNCH }
     _ = await entered.wait(timeoutSeconds: 2)
     if scenario == "same_source_new_generation" { model.micEngineGeneration += 1 }
     else if scenario == "quit_cancel" { ApplicationQuitCoordinator.shared.startIntent = UUID() }
     else if scenario != "healthy" { model.stopAndFinish(replacement: scenario == "stop_then_new_source") }
     nativeReturn.markCompleted(); await pending.value
     let adopted = model.micEngine == engine
     let expected = scenario == "healthy"
     if adopted != expected { failures += 1 }
     print("\(scenario): adopted=\(adopted) expected=\(expected) busy=\(owner.isBusy)")
   }
   if failures > 0 { exit(1) }
 }
}
'''
for key, value in [('CURRENT_SOURCE', current_source), ('SOURCE_PREDICATE', source_predicate),
                   ('RETIREMENT', retirement), ('SIGNATURE', signature), ('ADOPTION_BODY', body), ('LAUNCH', launch)]:
    program = program.replace(key, value)
with tempfile.TemporaryDirectory(prefix='muesli-mic-adoption-', dir='/private/tmp') as work:
    work = pathlib.Path(work)
    files = []
    for name in ['CaptureOperationOwner.swift', 'TaskCompletion.swift', 'ShutdownWorkRegistry.swift']:
        path = work / name; path.write_text(source(name)); files.append(str(path))
    main = work / 'main.swift'; main.write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
        '-module-cache-path', str(work / 'modules'), *files, str(main), '-o', str(work / 'run')], check=True)
    result = subprocess.run([str(work / 'run')], timeout=20)
    raise SystemExit(result.returncode)

# Preserve the microphone callback's concurrency contract

`MicCapturing.start` and `MicEngine.start` already accept a Sendable configuration-change callback. MicEngine's stored property erased that contract before a NotificationCenter callback captured it. Preserve `@Sendable` on the stored property. There is no callback scheduling or behavior change.

Before the annotation correction, whole-app Swift 6 strict checking failed at MicEngine.swift's notification closure because the captured callback was not Sendable. After the one-line correction, all app Swift source files plus the actual generated EmbeddedBuildIdentity declaration passed Swift 6 frontend typechecking with default MainActor isolation, complete strict concurrency and warnings as errors. Evidence: `/private/tmp/muesli-all-app-strict-v2.log` (empty diagnostics, exit zero). This checks app declarations and bodies, not test-target Swift 6 migration or runtime hardware behavior. No stubs were used.

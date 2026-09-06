# Canonical native target integration

This isolated change compiles the qualified source into the app and test targets. It does not activate a service, install an app, launch a picker, or change the app's process-selection behavior.

## Source boundaries

The checkout advances the client to `879f3c6`. Additive inference-service files come from frozen helper `d28ad33bb71de4807aee180e9b8d7d943e636c60`. All seven existing overlapping files (protocol, source-admission headers/implementations, protocol documentation and their native tests) were compared byte for byte and retained. The client and native observer were retained from the current branch. Historical proof scripts and qualification records remain historical; they do not certify this app build.

Python imports are limited to read-only process-lifetime source pins, the source-only live directory guard and admitted UUID check, container-owned derived live audio, the fixed XPC entry module, and their tests. No current Swift app, backend activation, typed completion or batch implementation was replaced.

Both app and test targets compile the same canonical `BackendXPCJobOwner.swift`, `InferenceProtocolV2.m`, `MuesliNativeProcessObserver.m`, and `SourceLeaseAdmission.m`. Both use the shared native headers and link Security. The actual Swift-parent Python harness now also compiles and links those native objects and the client bridge. The build identity includes `release/inference-service`; only generated Python bytecode has the same scoped exclusion as the existing Python/script roots.

## Verification

- 34 actual native-parent/child lease and fixed XPC-entry Python tests passed.
- 14 build-identity and frozen-proof-input tests passed, including changed native/compiler input affecting the source digest.
- 32 selected actual Xcode app/test-target tests passed.
- Canonical complete app production and DEBUG strict Swift 6 typechecks passed with no diagnostics: all real app Swift sources, the canonical client and actual generated build identity, default MainActor, complete concurrency and warnings as errors.
- The canonical native process-observer suite passed using generated processes and ad-hoc fixture signing.

Evidence is under `/private/tmp/muesli-native-target-*`: `python-tests.log`, `build-identity-tests.log`, `xcode-tests.log`, `production-strict.log`, `debug-strict.log`, `strict-inputs.txt`, and `observer-tests/result.json`.

The separate experiment overriding the whole Xcode project to Swift 6 with its existing `NonisolatedNonsendingByDefault` feature enabled fails at the pre-existing `BackendOutputReader.AsyncIterator.next()` call (`sending self.iterator risks causing data races`). The canonical strict frontend above does not enable that additional feature. This change does not claim migration of the app's configured Swift language mode or the test target to Swift 6, and does not weaken or edit that reader.

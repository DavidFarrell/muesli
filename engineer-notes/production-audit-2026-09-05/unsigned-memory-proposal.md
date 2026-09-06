# Authorised isolated runtime compatibility experiment

Prototype location: `/private/tmp/muesli-inference-xpc`, original implementation `bc702fa`, reviewed proposal `c16199f`, authorised experiment frozen at `fe1a744464c14c2071d4bdce841b77950a5d10c7`. The prototype is not integrated into the application.

Status, 6 September 2026: **The user explicitly authorised this helper-only experiment. Its actual inference and bounded security checks passed, followed by an independent Astra review.** The exception is applied only in the isolated prototype. This is not approval or evidence of a finished production integration, installation or distribution.

The exact frozen development-signed proof passed generated Parakeet ASR and Senko on committed PCM and legacy WAV, native IPv4/IPv6 TCP/UDP denial with positive controls, wrong-peer rejection, actual service/decoder termination on cancellation, and unchanged source hashes. Independent audit verified all 254 native signatures, exact entitlement sets and runtime flags, 17 packaged backend modules and 13 recorded source/overlay hashes. A diagnostic native decoder also denied an unbookmarked generated private-home control with `EPERM`; its original real-decoder bundle stayed unchanged. Evidence: `/private/tmp/muesli-xpc-fe1a744-results.json`, `-comparison.json`, `-child-report.json`, and `/private/tmp/muesli-xpc-astra-frozen-audit.json` / `-policy.jsonl`.

**Open boundary:** a private-home bookmark from the nonsandboxed proof host failed admission. A separate diagnostic host with only App Sandbox and user-selected read-only entitlements is ready to test a visible selection of the generated fixture, but the Mac was locked. Temporary-directory success and the negative home control do not prove a successful private-source grant. Current backend/source lease, continuous live protocol, journal/client ownership and packaged model identity integration are also pending. In particular, the current Python child lease opens existing locks read/write; read-only shared-lock admission must be qualified before using a read-only source grant. The frozen proof uses an older staged runtime plus an explicit four-module overlay, not the full current application backend.

The development-signed proof embeds CPython directly inside `paidiaconsulting.MuesliApp.InferenceService.xpc`, through `PythonBridge.m`. There is no separately launched Python executable. FFmpeg is a separate child with only App Sandbox inheritance entitlements. The proposed exception therefore belongs only to the XPC service executable. It does not belong to the main Muesli app, the proof host, FFmpeg, or any global machine setting.

## Exact proposed change

Add the following single Boolean entitlement to `release/inference-service/Service.entitlements` when signing **only** `InferenceService.xpc`:

```xml
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
```

The existing service entitlements remain `com.apple.security.app-sandbox = true` and `com.apple.security.cs.allow-jit = true`. The proposed resulting set contains exactly those three keys. The signing command retains `--options runtime`; library validation stays enabled. Neither `com.apple.security.network.client` nor `com.apple.security.network.server` is added. No `disable-library-validation`, `disable-executable-page-protection`, `get-task-allow`, sandbox exception, arbitrary command, environment, module, or import-path RPC is proposed.

Before the user's explicit authorisation, automatic approval review rejected this exact entitlement addition: “Adding the persistent allow-unsigned-executable-memory entitlement materially weakens code-execution protections for the helper, and the user authorized local inference generally but not this exact broad security exception.” The experiment remained unapplied at that earlier checkpoint. The later user decision authorised the isolated test; it did not add the exception to the main app or decoder.

## Why this is requested

The actual signed, hardened, sandboxed service successfully resolves the generated-source and staged-model bookmarks and initializes isolated bundled Python. The speech reprocess then reaches Parakeet loading and macOS kills the service at `LLVMPY_TryAllocateExecutableMemory` → `llvm::sys::Memory::protectMappedMemory` → `sys_icache_invalidate`, with `CODESIGNING / Invalid Page`. `allow-jit` alone is already present in this failing test.

The exact installed dependency is llvmlite 0.46.0, linked to LLVM 20.1.8. Its upstream tag is `50404fd444be60fc038ff0464b51b50c8bc42f8f`. `ffi/executionengine.cpp:132–143` allocates ordinary read/write pages and changes them to executable pages. LLVM 20.1.8's `llvm/lib/Support/Unix/Memory.inc` uses `MAP_PRIVATE | MAP_ANON`, without `MAP_JIT`. The actual library imports `mmap` and `mprotect`, and imports no `pthread_jit_*` functions.

This is also the real allocator's design, not merely a problematic startup probe. On ARM64, llvmlite's memory manager reserves code, read-only data, and writable data in a single contiguous mapping, then changes the code portion to executable. Numba calls its JIT probe unconditionally while importing; `NUMBA_DISABLE_JIT` cannot avoid the failing probe. Disabling or replacing that probe would not repair the allocator.

A bounded upstream investigation found no supported build flag or existing Apple JIT-compatible allocator in the tagged source, current llvmlite main `18cfd93f8b07629074c8dafae044798f757fc2e8`, or LLVM's current Unix memory implementation. A custom port would need a managed `MAP_JIT` code arena, separate writable data, correct per-thread write protection around every compiler/relocation write, instruction-cache synchronization, and failure restoration, followed by compiler/runtime qualification. No such custom port is included or represented as verified here.

## Security effect and retained boundaries

This exception permits the inference service to make unsigned generated memory executable without the narrower `MAP_JIT` allocation discipline. It weakens protection against an attacker who already achieves a memory-corruption or code-injection primitive inside that service. It does not authenticate model output, remove parser vulnerabilities, or turn generated code into signed code.

The proposal retains the independently enforced App Sandbox boundary, fixed inference operations, and exact team-and-identifier peer requirements set on both XPC connections before activation. It retains isolated Python configuration, fixed bundled module search paths, service-container caches, fresh admitted source/model bookmarks, one job per service process, and actual process-group termination for cancellation. Swift still owns authoritative audio and the durable event journal; this proof has not changed main-app capture integration.

The exception is scoped to the service's signed entitlement set. It is not added to FFmpeg's signed child entitlement set or to the proof host. Distribution signing and notarization remain unqualified; the available certificate is Apple Development, with actual Team ID `JA9EPB8K4N`.

## Existing evidence and required next validation

Existing local evidence from 2026-09-05:

- `/private/tmp/muesli-xpc-policy-v2.json`: signed native IPv4/IPv6 TCP and UDP attempts all return `EPERM`; a real host loopback TCP positive control succeeds. The service owns its process group and uses its sandbox container.
- `/private/tmp/muesli-xpc-preflight-v2.json`: service returns status zero after resolving fresh implicit bookmarks and initializing only its bundled interpreter. Later configuration also enables unbuffered output and explicit UTF-8.
- `/private/tmp/muesli-xpc-inference-v2.jsonl` and `/private/tmp/muesli-xpc-inference-v2.log`: the real generated 14.034-second speech reprocess reaches ASR load and then loses the helper connection.
- `/Users/david/Library/Logs/DiagnosticReports/InferenceService-2026-09-05-205925.ips`: the exact code-signing crash and LLVM stack above.
- `/private/tmp/muesli-xpc-workspace-tests.log`: 22 tests pass, including source preservation and cleanup on decoder failure.

The authorised experiment completed the original requested entitlement, inference, native-network, peer, cancellation and child-inheritance checks, followed by an independent Astra review. Preserve the remaining private-source and current-application integration gates above. A bounded isolated pass is not a claim that installed private-folder inference is qualified. The user has deferred distribution credentials/notarisation and requested a local build and installation for subsequent manual testing once the preceding work is ready.

Primary sources:

- [Apple entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-unsigned-executable-memory)
- [Apple file access and cross-process bookmark contract](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [llvmlite exact allocation probe](https://github.com/numba/llvmlite/blob/50404fd444be60fc038ff0464b51b50c8bc42f8f/ffi/executionengine.cpp#L132)
- [llvmlite exact memory manager](https://github.com/numba/llvmlite/blob/50404fd444be60fc038ff0464b51b50c8bc42f8f/ffi/memorymanager.cpp)
- [LLVM 20.1.8 Unix memory implementation](https://github.com/llvm/llvm-project/blob/llvmorg-20.1.8/llvm/lib/Support/Unix/Memory.inc)

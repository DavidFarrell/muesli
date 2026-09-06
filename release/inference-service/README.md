# Native inference service proof

This is an isolated development proof, **not an integrated or qualified release**. Main-app capture/backend selection is unchanged. CPython is embedded inside the native XPC service; only the bundled decoder is launched as a child.

`build-proof.sh` takes a fresh output directory, the qualified standalone Python directory, a signing identity, and the identity's actual ten-character Team ID. The Python directory's sibling `tools/` must contain the qualified decoder. It copies the runtime into its own bundle, overlays this slice's four backend modules, signs native components inside out, signs the sandboxed XPC service, signs the host, and verifies the bundle. It never signs or changes the supplied runtime in place. It also builds the fixed read-only OS-version utility, signs it with decoder inheritance only, and embeds `proof-build-inputs.json` for exact source provenance. `audit-proof.py APP --team TEAM` separately verifies every actual native signed entitlement set and records installed backend hashes. Build against the staged headers that match the copied interpreter.

The resulting `InferenceProof.app/Contents/MacOS/InferenceProof` accepts these local proof commands:

- `policy`: a real loopback positive control and native IPv4/IPv6 TCP/UDP denial checks.
- `preflight SOURCE MODEL`: resolve fresh implicit-scope bookmarks and verify local assets through isolated bundled Python.
- `reprocess SOURCE MODEL`: run batch ASR and Senko on a generated meeting fixture.
- `live SOURCE MODEL`: use a committed-source directory and the backend's fixed live operation. This proof host currently supplies EOF on stdin; continuous live protocol integration is pending.
- `ownership SOURCE MODEL`: keep Python output full, reject cancellation from the wrong connection/job, invalidate an unrelated connection, cancel the original owner, and require actual process exit.
- `decoder-ownership SOURCE MODEL`: use the generated large legacy fixture to observe and hold only the exact real decoder child, fill output, and require actual service and decoder exit after cancellation.

The XPC protocol accepts only `preflight`, `live`, `reprocess`, and a job-ID cancellation request, plus the bounded diagnostic policy probe. It never accepts a command, environment, module name, interpreter path, or import path. It validates both peers using exact signed identifiers and the actual signing team before accepting messages. One job is admitted per service lifetime. An independent native deadline kills the actual owned process group on cancellation, abandoned connections, or fixed operation timeout. No timer claims that a process has completed. The production client must continue treating accepted cancellation, final reply, stdout EOF, and actual connection interruption as distinct facts.

Fresh cross-process bookmarks use Apple's implicit security scope, but the original host must possess and transfer actual file authority; successful temporary-directory access alone does not prove that capability. Persistent app-scoped bookmarks are not transferable between the app and service identities. The service resolves each fresh bookmark with no UI or volume mounting, retains its access until the actual operation returns, then balances the implicit access with one stop. Source/model paths never enter Python's module search path. Python's isolated preconfiguration enables UTF-8; its configuration ignores environment and user site, excludes the working directory, disables bytecode, uses explicit bundled library paths, and leaves standard output unbuffered.

Service-owned temporary audio gives the inherited-sandbox decoder access without relying on transfer of a bookmark grant from the service. Python reads the Swift-owned committed source and writes only derived temporary media. The source and model bookmarks are not durable state; the host must create fresh bookmarks for each new service process.

## Qualification state

The user explicitly authorized the helper-only unsigned-memory experiment on 2026-09-06. It now runs real generated Parakeet ASR and Senko inference with unchanged source hashes. Native network denial, wrong-peer rejection, and both actual blocked-output/decoder cancellation tests pass. Every actual native entitlement set has been audited; the exception remains service-only. See [the exact results and remaining private-folder admission gate](qualification-2026-09-06.md) and [the approved exception's effect and original failing evidence](unsigned-memory-proposal.md).

The normal proof host is not sandboxed. `build-picker-proof.sh` builds a separate diagnostic copy with only sandbox + user-selected read-only, requiring visible selection of the exact generated fixture. `build-child-policy-proof.sh` builds a separate native diagnostic decoder replacement for OS-policy evidence; its expected conversion failure must never be represented as real FFmpeg success. Both leave the original proof unchanged.

Current-app source/journal ownership, continuous live protocol, model/build identity binding, local installation and independent final implementation review remain separate. Distribution signing/notarization and physical audio qualification are deferred; no installed Muesli app has been changed by this proof.

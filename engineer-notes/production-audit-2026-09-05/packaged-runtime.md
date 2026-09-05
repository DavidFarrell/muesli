# Relocatable runtime preparation

This slice prepares and tests an unsigned/development payload. It does not switch the installed app to that payload or establish a distributable, sandboxed app.

## Fixed inputs

- uv 0.11.3; explicit project `uv.toml` and unchanged application `uv.lock`.
- CPython 3.12.13, python-build-standalone build 20260325, Apple Silicon install-only stripped archive. SHA-256 `c33a34853ae48d54fbac15cbb84ad67ccd8a639ce2cef866ecf474ebd02f1286`, verified against the upstream GitHub release asset digest. Full interpreter installation is extracted; no developer `.venv` is copied.
- Build tools constrained to setuptools 80.9.0, wheel 0.45.1 and hatchling 1.27.0. Runtime requirements are exported from the existing lock, including the pinned Senko Git commit, and installed without dependency re-resolution. The backend is a wheel, not an editable source path.
- FFmpeg 9.0.1 source archive SHA-256 `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`. The upstream detached signature was verified against published fingerprint `FCF986EA15E6E293A5644F10B4322F04D67658D8` before pinning. The builder retains the exact source archive, configuration, build log and LGPL notice.

The minimal decoder supports local file/pipe PCM workflows, WAV and AIFF inputs, mono/resampling, WAV output and raw s16le/f32le output. Network, GPL/nonfree options, external library autodetection and unrelated codecs are disabled. It explicitly targets macOS 26.2 and links only system libraries. This is the app's capture-format decoder, not a claim of general FFmpeg format compatibility.

## Tools and ownership

1. `stage-python-runtime.py` validates the interpreter archive before creating a fresh output directory, materializes locked packages with an isolated build environment, removes unused absolute-shebang entry points and bytecode caches, and records source/build provenance.
2. `relocate-runtime.py` records original/transformed native hashes while removing build-machine rpaths and absolute dylib IDs. The one explicit dependency rewrite binds the pinned Numba OpenMP pool to the pinned sklearn-shipped OpenMP library (both declare compatibility 5.0.0). Actual inference qualifies this pinned pairing; arbitrary host libraries are never copied as a fallback.
3. `audit-runtime.py` checks all payload links, arm64 Mach-O load commands, rpaths, resolved bundled dependencies and minimum macOS. It rejects escaping links/rpaths, unresolved libraries and absolute non-system loads. Every regular payload file is hashed, including dynamically loaded Senko libraries and Metal/CoreML resources. Static inspection does not prove dynamic code paths work.
4. `runtime-notices.py` inventories each installed distribution's exact shipped license/notice files and hashes without importing model code. It distinguishes declared metadata from missing notice evidence; this is not a legal redistribution conclusion. Model cards and conversion provenance remain separate from Python package licenses.
5. `sign-runtime.py` signs and verifies native leaves, then records post-sign payload hashes outside the payload. It does not disable library validation. Enclosing bundles must be signed afterwards. Ad-hoc signing is qualification only; distribution identity/notarization remain separate.

The six small packaging regressions compile real native fixtures. They prove relocation with the original directory removed, reject escaping links/rpaths and missing libraries, reject newer minimum OS requirements, and reject altered source archives before creating output. The normal verification script runs them without model downloads.

## Execution evidence, 5 September 2026

A development payload from the fixed inputs contained 250 native Python/package binaries; adding the minimal decoder made 251. Its runtime and cached ASR model files were copied to a different directory, with no Hugging Face cache symlinks retained. Modified native files were ad-hoc signed.

Actual ASR and Senko diarisation succeeded on a generated 14.034-second speech WAV with:

- CPython `-I -B`, clean environment and PATH restricted to the packaged decoder and system tools;
- fresh writable HOME/temp directories;
- OS denial of all network access and reads from the original staging directory and original Hugging Face cache;
- OS denial of writes into the relocated payload.

The output contained 40 transcribed words, one speaker and one speaker turn. The cold inference run exercised CoreML and MLX. A separate cold Numba probe forced the relocated OpenMP backend and cached parallel JIT, verifying the sum of integers 0 through 99,999 under the same read-only/no-network constraints. Test evidence is in `/private/tmp/muesli-relocated-runtime-inference.log` and the matching transcript outputs. The decoder's build also tests actual 48 kHz to 16 kHz conversion into both required raw PCM formats.

This qualification used `sandbox-exec` solely as a test harness. The production design uses a separately sandboxed XPC inference service; it must independently prove native network denial, container caches, external-input capability handling and bounded process ownership. No production enforcement claim is made from this runtime test.

## Upstream references

- [Standalone Python release](https://github.com/astral-sh/python-build-standalone/releases/tag/20260325)
- [FFmpeg release and signature verification](https://ffmpeg.org/download.html)
- [FFmpeg license and source guidance](https://ffmpeg.org/legal.html)
- [Apple code-signing structure](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

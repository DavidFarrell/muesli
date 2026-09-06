# Finalized transcript count after Resume

Batch replacement can save both system turns and matching microphone echoes.
Resume loads those records through the normal transcript reducer, which suppresses
the echoes. Stop then atomically replaces the saved transcript with the reduced
records plus the durable current-session journal. Previously the metadata helper
kept the larger historical segment count, so the saved JSONL and meeting metadata
disagreed and exact-record export refused the meeting.

The stopped-session transaction now sets `segmentCount` to the exact final record
count before encoding and committing all transcript files. Export's integrity
check remains strict. Batch replacement already uses its exact record count.

The other production caller of `MeetingMetadata.finalized` is the metadata-only
failed-start finalizer in AppModel. It passes an empty segment list and leaves the
existing transcript files intact. That path still preserves the old count; a
global change to the shared metadata helper would corrupt that contract.

## Generated workflow reproduction

`FinalizedTranscriptCountTests` uses a generated two-stream batch result and
actual `TranscriptReplacement` encoding/persistence, actual Resume storage
preparation, the production Resume `TranscriptModel.ingest` sequence, actual
`commitStoppedMeeting`, and actual `TranscriptExportOwner`. Temporary source PCM
and recorder manifests support the actual Resume offset validation; no model,
physical capture, application UI or user files are involved.

On baseline `598634288df09113b6ed453e93b18bfb51c3bc1a`, the unchanged test file
(SHA-256 `066609487fdf0aa728eb9c305391eb7bc75f94765a7aeab1b5c78846fa784049`)
produced six failed assertions: both the two-record and three-record Stop cases
saved metadata count four and failed real export. The metadata-only failed-Resume
control passed, preserving all four unchanged records and successful export.

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project MuesliApp/MuesliApp.xcodeproj -scheme MuesliApp \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/muesli-finalized-count-repro-derived \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  -only-testing:MuesliAppTests/FinalizedTranscriptCountTests test
```

To replay the baseline, copy the test file into a disposable checkout of that
commit and run the same command. Local red evidence is retained in
`/private/tmp/muesli-finalized-count-red.log`.

The same test file passes on the correction, including both real exports and the
metadata-only control. The complete suite on this task's base passed 614 Swift
tests in `/private/tmp/muesli-finalized-count-full-green.log`; whole-app Swift 6
strict-concurrency type checking with warnings as errors also passed.

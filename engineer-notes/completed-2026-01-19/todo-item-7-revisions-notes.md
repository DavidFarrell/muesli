# Todo Item 7 - Revisions Applied

## Changes applied
1) **TXT format consistency**
   - `saveTranscriptFiles(for:)` now uses `transcriptModel.asPlainText()` for the TXT output to match the copy/export format.

2) **Copy transcript feedback**
   - The "Copy transcript" button now briefly changes to "Copied!" for 1.5 seconds after copying.

3) **Export uses Save panel**
   - "Export transcript" now opens an `NSSavePanel` and writes the chosen `.txt` plus a sibling `.jsonl` with the same base filename.
   - Export no longer writes redundantly to the meeting folder.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - `saveTranscriptFiles(for:)` TXT output uses `asPlainText()`.
  - Copy button uses feedback text state.
  - `exportTranscriptFiles()` uses `NSSavePanel` and writes to selected location.

## Notes for reviewer
- JSONL format remains raw speaker IDs as requested.
- Export writes `foo.txt` + `foo.jsonl` next to each other based on the chosen filename.

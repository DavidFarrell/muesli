# Todo Item 10 - Harden AudioSampleExtractor buffer list allocation

## Goal
Handle multi-buffer audio layouts safely by allocating the full AudioBufferList size needed by CoreMedia.

## What I changed
- `extractInt16Mono` now queries `bufferListSizeNeededOut` first.
- Allocates an AudioBufferList of the correct size using `UnsafeMutableRawPointer.allocate`.
- Uses the dynamically sized buffer list when calling `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - `AudioSampleExtractor.extractInt16Mono` now uses dynamic buffer list allocation.

## Notes for reviewer
- This avoids failures with non-interleaved or multi-buffer audio formats.
- Existing conversion logic is unchanged.

# TODO: Thumbnail Previews for Window/Display Picker

## Phase 0 - Data Model
- [x] Add `displayThumbnails` + `windowThumbnails` dictionaries to `AppModel`.

## Phase 1 - Thumbnail Capture
- [x] Implement `captureThumbnails()` to populate display + window thumbnails after refresh.
- [x] Implement `resizeImage(_:to:)` for 160x90 thumbnails (aspect fit).
- [x] Call `captureThumbnails()` from `loadShareableContent()` after `displays`/`windows` update.

## Phase 2 - UI Picker Updates
- [x] Update display picker rows to show 80x45 thumbnail + label.
- [x] Update window picker rows to show 80x45 thumbnail + app/title text.

## Phase 3 - Manual Verification
- [ ] Multi-display setup shows correct display thumbnails.
- [ ] Multiple windows show correct window thumbnails.
- [ ] Thumbnail quality is legible at 80x45.
- [ ] Refresh sources updates thumbnails.
- [ ] Permission denied handled gracefully.

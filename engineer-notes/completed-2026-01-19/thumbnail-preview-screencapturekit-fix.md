# Thumbnail Preview - ScreenCaptureKit Capture

## Summary
- Replaced CGDisplayCreateImage / CGWindowListCreateImage with ScreenCaptureKit screenshot capture to avoid macOS availability issues.

## Changes
- `captureThumbnails()` now uses `SCScreenshotManager.captureSampleBuffer` with `SCContentFilter` for displays and windows.
- Added `captureThumbnail(for:)` helper to convert a `CMSampleBuffer` to `CGImage`.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`

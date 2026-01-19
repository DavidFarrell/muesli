# Engineering Spec: Window/Display Thumbnail Previews

**Author:** David (via Claude)
**Date:** 2026-01-19
**Priority:** Medium
**Estimated Effort:** 1-2 hours

---

## 1. Problem Statement

When selecting a window or display to capture, the user sees only text labels:
- Displays: "Display 1", "Display 2"
- Windows: "Safari - Google", "Slack - #general"

With multiple windows/displays, it's hard to identify which is which without visual context.

**User request:** Show a small thumbnail preview of each window/display in the picker so the user can visually identify what they're selecting.

---

## 2. Solution Overview

Add **static thumbnail previews** captured when the shareable content list is loaded. Thumbnails are captured once (not live-updating) to keep implementation simple and resource usage low.

### Why Static vs Live?

| Approach | Complexity | Resources | User Value |
|----------|------------|-----------|------------|
| **Static thumbnail** | Low (~20 lines) | Minimal | High - identifies windows |
| Live thumbnail | High (~100+ lines) | Multiple streams | Marginal - picker is open briefly |

Static thumbnails are sufficient - the user just needs to identify which window is which.

---

## 3. Implementation Details

### 3.1 Data Model Changes

**File:** `MuesliApp/MuesliApp/AppModel.swift`

Add thumbnail storage alongside existing arrays:

```swift
// Add near existing @Published properties (around line 83-84)
@Published var displays: [SCDisplay] = []
@Published var windows: [SCWindow] = []
@Published var displayThumbnails: [CGDirectDisplayID: CGImage] = [:]  // NEW
@Published var windowThumbnails: [CGWindowID: CGImage] = [:]          // NEW
```

### 3.2 Thumbnail Capture

**File:** `MuesliApp/MuesliApp/AppModel.swift`

Add a function to capture thumbnails after fetching shareable content. Call this from `refreshShareableContent()`.

```swift
/// Capture thumbnail previews for all windows and displays
/// Call after populating self.displays and self.windows
@MainActor
private func captureThumbnails() async {
    // Clear existing thumbnails
    displayThumbnails.removeAll()
    windowThumbnails.removeAll()

    let thumbnailSize = CGSize(width: 160, height: 90)  // 16:9 aspect ratio

    // Capture display thumbnails
    for display in displays {
        if let image = CGDisplayCreateImage(display.displayID) {
            // Scale down to thumbnail size
            if let thumbnail = resizeImage(image, to: thumbnailSize) {
                displayThumbnails[display.displayID] = thumbnail
            }
        }
    }

    // Capture window thumbnails
    for window in windows {
        let windowID = CGWindowID(window.windowID)
        if let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) {
            if let thumbnail = resizeImage(image, to: thumbnailSize) {
                windowThumbnails[window.windowID] = thumbnail
            }
        }
    }
}

/// Resize a CGImage to fit within the given size while maintaining aspect ratio
private func resizeImage(_ image: CGImage, to maxSize: CGSize) -> CGImage? {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)

    let widthRatio = maxSize.width / width
    let heightRatio = maxSize.height / height
    let ratio = min(widthRatio, heightRatio)

    let newWidth = Int(width * ratio)
    let newHeight = Int(height * ratio)

    guard let context = CGContext(
        data: nil,
        width: newWidth,
        height: newHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

    return context.makeImage()
}
```

### 3.3 Call Thumbnail Capture

**File:** `MuesliApp/MuesliApp/AppModel.swift`

In `refreshShareableContent()`, add thumbnail capture after populating the arrays:

```swift
// Around line 532-541, after setting displays and windows:
displays = content.displays
windows = content.windows
screenPermissionGranted = true

// ADD THIS:
await captureThumbnails()

if selectedDisplayID == nil {
    selectedDisplayID = displays.first?.displayID
}
```

### 3.4 UI Changes

**File:** `MuesliApp/MuesliApp/ContentView.swift`

Replace the text-only Picker items with thumbnail + text. Around lines 175-190:

**Before:**
```swift
if model.sourceKind == .display {
    Picker("Display", selection: $model.selectedDisplayID) {
        ForEach(model.displays, id: \.displayID) { display in
            Text("Display \(display.displayID)")
                .tag(Optional(display.displayID))
        }
    }
} else {
    Picker("Window", selection: $model.selectedWindowID) {
        ForEach(model.windows, id: \.windowID) { window in
            let title = window.title ?? "(untitled)"
            let app = window.owningApplication?.applicationName ?? "(unknown app)"
            Text("\(app) - \(title)")
                .tag(Optional(window.windowID))
        }
    }
}
```

**After:**
```swift
if model.sourceKind == .display {
    Picker("Display", selection: $model.selectedDisplayID) {
        ForEach(model.displays, id: \.displayID) { display in
            HStack {
                if let cgImage = model.displayThumbnails[display.displayID] {
                    Image(decorative: cgImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 45)
                        .cornerRadius(4)
                }
                Text("Display \(display.displayID)")
            }
            .tag(Optional(display.displayID))
        }
    }
} else {
    Picker("Window", selection: $model.selectedWindowID) {
        ForEach(model.windows, id: \.windowID) { window in
            let title = window.title ?? "(untitled)"
            let app = window.owningApplication?.applicationName ?? "(unknown app)"
            HStack {
                if let cgImage = model.windowThumbnails[window.windowID] {
                    Image(decorative: cgImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 45)
                        .cornerRadius(4)
                }
                Text("\(app) - \(title)")
            }
            .tag(Optional(window.windowID))
        }
    }
}
```

---

## 4. Testing Plan

### Manual Verification

1. **Multiple displays** - Connect external monitor, verify both displays show correct thumbnails
2. **Multiple windows** - Open several apps, verify window thumbnails match actual windows
3. **Thumbnail quality** - Verify thumbnails are legible at 80x45 display size
4. **Performance** - Verify no noticeable delay when opening picker with many windows
5. **Refresh** - If shareable content is refreshed, thumbnails should update

### Edge Cases

1. **Minimized windows** - May show blank or last-visible state (acceptable)
2. **Window closes** - If window closes after thumbnail captured, picker shows stale thumbnail until refresh (acceptable)
3. **Permission denied** - Should gracefully handle if screenshot permission not granted

---

## 5. Files to Modify

| File | Changes |
|------|---------|
| `AppModel.swift` | Add `displayThumbnails`, `windowThumbnails` dictionaries; add `captureThumbnails()` and `resizeImage()` functions; call from `refreshShareableContent()` |
| `ContentView.swift` | Update Picker items to show thumbnail + text in HStack |

---

## 6. Future Improvements (Out of Scope)

1. **Refresh button** - Manual button to re-capture thumbnails
2. **Live preview** - Real-time updating thumbnails (significant complexity increase)
3. **Larger preview on hover** - Show full-size preview when hovering over picker item
4. **App icon fallback** - Show app icon if thumbnail capture fails

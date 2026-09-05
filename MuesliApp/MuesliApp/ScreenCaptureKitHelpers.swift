import Foundation
import ScreenCaptureKit
import CoreGraphics

enum ScreenCaptureKitHelpers {
    // Permission probes and picker refreshes share this actual native slot.
    private static let contentOwner = NativeCallbackOwner<Content>()
    nonisolated struct Content: @unchecked Sendable { let value: SCShareableContent }
    static func fetchShareableContent(excludingDesktopWindows: Bool, onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        let value = try await contentOwner.perform(timeoutSeconds: 8) { reply in
            SCShareableContent.getExcludingDesktopWindows(excludingDesktopWindows, onScreenWindowsOnly: onScreenWindowsOnly) { content, error in
                if let error { reply(.failure(error)) }
                else if let content { reply(.success(Content(value: content))) }
                else { reply(.failure(CocoaError(.coderValueNotFound))) }
            }
        }
        return value.value
    }
}

/// Filter and configuration are prepared once on the UI actor, then remain
/// immutable through the native request. Request only the displayed pixel
/// dimensions; avoid decoding and resizing a full display on the UI actor.
nonisolated final class SourceThumbnailRequest: @unchecked Sendable {
    struct Image: @unchecked Sendable { let value: CGImage }
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    init(filter: SCContentFilter) {
        self.filter = filter
        let configuration = SCStreamConfiguration()
        configuration.width = 160
        configuration.height = 90
        configuration.showsCursor = false
        configuration.scalesToFit = true
        self.configuration = configuration
    }
    func capture(_ reply: @escaping NativeCallbackOwner<Image>.Reply) {
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
            if let error { reply(.failure(error)) }
            else if let image { reply(.success(Image(value: image))) }
            else { reply(.failure(CocoaError(.coderValueNotFound))) }
        }
    }
}

import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum TranscriptImageCaptureError: LocalizedError {
    case outputPathIsNotDirectory(String)
    case windowFrameUnavailable
    case kakaoProcessUnavailable
    case shareableContentTimedOut
    case shareableContentUnavailable(String)
    case matchedWindowNotFound
    case screenshotTimedOut
    case screenshotUnavailable(String)
    case imageEncodingFailed
    case imageCaptureCountMismatch(expected: Int, captured: Int)

    var errorDescription: String? {
        switch self {
        case .outputPathIsNotDirectory(let path):
            return "IMAGE_CAPTURE_OUTPUT_INVALID: path is not a directory: \(path)"
        case .windowFrameUnavailable:
            return "IMAGE_CAPTURE_WINDOW_FRAME_UNAVAILABLE: matched KakaoTalk window has no AX frame"
        case .kakaoProcessUnavailable:
            return "IMAGE_CAPTURE_KAKAO_PROCESS_UNAVAILABLE: KakaoTalk process is not running"
        case .shareableContentTimedOut:
            return "IMAGE_CAPTURE_SHAREABLE_CONTENT_TIMEOUT: ScreenCaptureKit did not return shareable content"
        case .shareableContentUnavailable(let reason):
            return "IMAGE_CAPTURE_SHAREABLE_CONTENT_UNAVAILABLE: \(reason)"
        case .matchedWindowNotFound:
            return "IMAGE_CAPTURE_WINDOW_NOT_FOUND: ScreenCaptureKit could not match the resolved KakaoTalk window"
        case .screenshotTimedOut:
            return "IMAGE_CAPTURE_SCREENSHOT_TIMEOUT: ScreenCaptureKit did not return the KakaoTalk window image"
        case .screenshotUnavailable(let reason):
            return "IMAGE_CAPTURE_SCREENSHOT_UNAVAILABLE: \(reason)"
        case .imageEncodingFailed:
            return "IMAGE_CAPTURE_ENCODING_FAILED: could not produce a deterministic JPEG under 1 MiB"
        case .imageCaptureCountMismatch(let expected, let captured):
            return "IMAGE_CAPTURE_COUNT_MISMATCH: detected \(expected) image(s), captured \(captured)"
        }
    }
}

/// Captures one resolved KakaoTalk window and crops only the image frames that
/// survived `KakaoTalkTranscriptReader`'s message-image filtering.
struct TranscriptImageCapturer {
    static let maximumJPEGBytes = 1_048_576

    private let outputDirectory: URL
    private let runner: AXActionRunner

    init(outputDirectoryPath: String, runner: AXActionRunner) throws {
        let expanded = (outputDirectoryPath as NSString).expandingTildeInPath
        let absolutePath: String
        if expanded.hasPrefix("/") {
            absolutePath = expanded
        } else {
            absolutePath = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
            .appendingPathComponent(expanded, isDirectory: true)
            .path
        }

        let directory = URL(fileURLWithPath: absolutePath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw TranscriptImageCaptureError.outputPathIsNotDirectory(directory.path)
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        self.outputDirectory = directory
        self.runner = runner
    }

    func captureImages(in snapshot: TranscriptSnapshot, from window: UIElement) throws -> TranscriptSnapshot {
        let expectedCount = snapshot.messages.reduce(0) { $0 + $1.imageCount }
        let frameCount = snapshot.messages.reduce(0) { $0 + $1.imageFrames.count }
        guard frameCount == expectedCount else {
            throw TranscriptImageCaptureError.imageCaptureCountMismatch(
                expected: expectedCount,
                captured: frameCount
            )
        }

        guard expectedCount > 0 else {
            return TranscriptSnapshot(
                chat: snapshot.chat,
                fetchedAt: snapshot.fetchedAt,
                messages: snapshot.messages.map { $0.withCapturedImages(paths: [], sha256: []) },
                transcriptFrame: snapshot.transcriptFrame
            )
        }

        guard let axWindowFrame = window.frame else {
            throw TranscriptImageCaptureError.windowFrameUnavailable
        }

        let capturedWindow = try captureWindow(
            axFrame: axWindowFrame,
            axTitle: window.title
        )
        var capturedCount = 0
        var messages: [TranscriptMessage] = []
        messages.reserveCapacity(snapshot.messages.count)

        for message in snapshot.messages {
            var paths: [String] = []
            var hashes: [String] = []
            paths.reserveCapacity(message.imageFrames.count)
            hashes.reserveCapacity(message.imageFrames.count)

            for frame in message.imageFrames {
                guard isNearlyContained(frame, in: snapshot.transcriptFrame) else {
                    runner.log("read: image frame is clipped by the transcript viewport: \(frameDescription(frame))")
                    continue
                }
                guard let cropped = crop(
                    capturedWindow.image,
                    sourceFrame: frame,
                    windowFrame: capturedWindow.frame,
                    contentRect: capturedWindow.contentRect
                ) else {
                    runner.log("read: image frame could not be cropped: \(frameDescription(frame))")
                    continue
                }

                let data = try deterministicJPEG(cropped)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let destination = outputDirectory.appendingPathComponent("\(hash).jpg", isDirectory: false)
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )

                paths.append(destination.path)
                hashes.append(hash)
                capturedCount += 1
            }

            messages.append(message.withCapturedImages(paths: paths, sha256: hashes))
        }

        guard capturedCount == expectedCount else {
            throw TranscriptImageCaptureError.imageCaptureCountMismatch(
                expected: expectedCount,
                captured: capturedCount
            )
        }

        return TranscriptSnapshot(
            chat: snapshot.chat,
            fetchedAt: snapshot.fetchedAt,
            messages: messages,
            transcriptFrame: snapshot.transcriptFrame
        )
    }

    private func captureWindow(axFrame: CGRect, axTitle: String?) throws -> CapturedWindowScreenshot {
        guard let processID = KakaoTalkApp.runningApplication?.processIdentifier else {
            throw TranscriptImageCaptureError.kakaoProcessUnavailable
        }

        let content = try loadShareableContent()
        guard let matchedWindow = bestMatchingWindow(
            in: content.windows,
            processID: processID,
            axFrame: axFrame,
            axTitle: axTitle
        ) else {
            throw TranscriptImageCaptureError.matchedWindowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: matchedWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(matchedWindow.frame.width.rounded()))
        configuration.height = max(1, Int(matchedWindow.frame.height.rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.backgroundColor = NSColor.white.cgColor
        configuration.queueDepth = 1

        let capturedSurface: CapturedSurfaceImage
        if #available(macOS 14.0, *) {
            configuration.preservesAspectRatio = true
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.shouldBeOpaque = true
            configuration.captureResolution = .nominal
            let image = try captureScreenshot(filter: filter, configuration: configuration)
            capturedSurface = CapturedSurfaceImage(
                image: image,
                contentRect: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                contentScale: nil,
                scaleFactor: nil
            )
        } else {
            capturedSurface = try captureSingleStreamFrame(filter: filter, configuration: configuration)
        }

        runner.log(
            "read: captured KakaoTalk window once (window_id=\(matchedWindow.windowID), size=\(capturedSurface.image.width)x\(capturedSurface.image.height), content=\(frameDescription(capturedSurface.contentRect)), content_scale=\(capturedSurface.contentScale.map(String.init(describing:)) ?? "unknown"), scale_factor=\(capturedSurface.scaleFactor.map(String.init(describing:)) ?? "unknown"))"
        )
        return CapturedWindowScreenshot(
            image: capturedSurface.image,
            frame: matchedWindow.frame,
            contentRect: capturedSurface.contentRect
        )
    }

    private func loadShareableContent() throws -> SCShareableContent {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedResult<SCShareableContent>()
        SCShareableContent.getExcludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        ) { content, error in
            if let content {
                result.storeIfEmpty(.success(content))
            } else if let error {
                result.storeIfEmpty(.failure(error))
            } else {
                result.storeIfEmpty(.failure(
                    TranscriptImageCaptureError.shareableContentUnavailable("empty ScreenCaptureKit response")
                ))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw TranscriptImageCaptureError.shareableContentTimedOut
        }
        do {
            return try result.get()
        } catch let error as TranscriptImageCaptureError {
            throw error
        } catch {
            throw TranscriptImageCaptureError.shareableContentUnavailable(error.localizedDescription)
        }
    }

    @available(macOS 14.0, *)
    private func captureScreenshot(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) throws -> CGImage {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedResult<CGImage>()
        SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) { image, error in
            if let image {
                result.storeIfEmpty(.success(image))
            } else if let error {
                result.storeIfEmpty(.failure(error))
            } else {
                result.storeIfEmpty(.failure(
                    TranscriptImageCaptureError.screenshotUnavailable("empty ScreenCaptureKit response")
                ))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw TranscriptImageCaptureError.screenshotTimedOut
        }
        do {
            return try result.get()
        } catch let error as TranscriptImageCaptureError {
            throw error
        } catch {
            throw TranscriptImageCaptureError.screenshotUnavailable(error.localizedDescription)
        }
    }

    private func captureSingleStreamFrame(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) throws -> CapturedSurfaceImage {
        let frameResult = LockedResult<CapturedSurfaceImage>()
        let frameSemaphore = DispatchSemaphore(value: 0)
        let output = SingleFrameStreamOutput(result: frameResult, semaphore: frameSemaphore)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "dev.kmsg.image-capture")
        )

        let startResult = LockedResult<Void>()
        let startSemaphore = DispatchSemaphore(value: 0)
        stream.startCapture { error in
            if let error {
                startResult.storeIfEmpty(.failure(error))
            } else {
                startResult.storeIfEmpty(.success(()))
            }
            startSemaphore.signal()
        }

        guard startSemaphore.wait(timeout: .now() + 10) == .success else {
            throw TranscriptImageCaptureError.screenshotTimedOut
        }
        do {
            _ = try startResult.get()
        } catch {
            throw TranscriptImageCaptureError.screenshotUnavailable(error.localizedDescription)
        }

        guard frameSemaphore.wait(timeout: .now() + 10) == .success else {
            let stopSemaphore = DispatchSemaphore(value: 0)
            stream.stopCapture { _ in stopSemaphore.signal() }
            _ = stopSemaphore.wait(timeout: .now() + 2)
            throw TranscriptImageCaptureError.screenshotTimedOut
        }

        let stopSemaphore = DispatchSemaphore(value: 0)
        stream.stopCapture { _ in stopSemaphore.signal() }
        _ = stopSemaphore.wait(timeout: .now() + 2)

        do {
            return try frameResult.get()
        } catch {
            throw TranscriptImageCaptureError.screenshotUnavailable(error.localizedDescription)
        }
    }

    private func bestMatchingWindow(
        in windows: [SCWindow],
        processID: pid_t,
        axFrame: CGRect,
        axTitle: String?
    ) -> SCWindow? {
        let candidates = windows.filter { $0.owningApplication?.processID == processID }
        guard !candidates.isEmpty else { return nil }

        let normalizedAXTitle = normalizedTitle(axTitle)
        let ranked = candidates.map { window -> (window: SCWindow, score: CGFloat, distance: CGFloat, titleMatch: Bool) in
            let windowTitle = normalizedTitle(window.title)
            let titleMatch = !normalizedAXTitle.isEmpty
                && !windowTitle.isEmpty
                && (windowTitle == normalizedAXTitle
                    || windowTitle.localizedCaseInsensitiveContains(normalizedAXTitle)
                    || normalizedAXTitle.localizedCaseInsensitiveContains(windowTitle))
            let titlePenalty: CGFloat = normalizedAXTitle.isEmpty || windowTitle.isEmpty || titleMatch ? 0 : 10_000
            let layerPenalty: CGFloat = window.windowLayer == 0 ? 0 : 1_000
            let distance = geometryDistance(window.frame, axFrame)
            return (window, titlePenalty + layerPenalty + distance, distance, titleMatch)
        }
        guard let best = ranked.min(by: { $0.score < $1.score }) else { return nil }

        let geometryTolerance = max(80, (axFrame.width + axFrame.height) * 0.15)
        guard best.titleMatch || best.distance <= geometryTolerance else {
            return nil
        }
        return best.window
    }

    private func crop(
        _ image: CGImage,
        sourceFrame: CGRect,
        windowFrame: CGRect,
        contentRect: CGRect
    ) -> CGImage? {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        let clipped = sourceFrame.intersection(windowFrame)
        guard !clipped.isNull, !clipped.isEmpty,
              visibleAreaRatio(of: sourceFrame, inside: windowFrame) >= 0.98
        else {
            return nil
        }

        let pixelFrame = CGRect(
            x: contentRect.minX + (clipped.minX - windowFrame.minX) / windowFrame.width * contentRect.width,
            y: contentRect.minY + (clipped.minY - windowFrame.minY) / windowFrame.height * contentRect.height,
            width: clipped.width / windowFrame.width * contentRect.width,
            height: clipped.height / windowFrame.height * contentRect.height
        ).integral
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let bounded = pixelFrame.intersection(imageBounds).integral
        guard !bounded.isNull, bounded.width >= 1, bounded.height >= 1 else { return nil }
        return image.cropping(to: bounded)
    }

    private func isNearlyContained(_ frame: CGRect, in bounds: CGRect?) -> Bool {
        guard let bounds else { return false }
        return visibleAreaRatio(of: frame, inside: bounds) >= 0.98
    }

    private func visibleAreaRatio(of frame: CGRect, inside bounds: CGRect) -> CGFloat {
        guard frame.width > 0, frame.height > 0 else { return 0 }
        let intersection = frame.intersection(bounds)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return (intersection.width * intersection.height) / (frame.width * frame.height)
    }

    private func deterministicJPEG(_ source: CGImage) throws -> Data {
        let qualityLevels: [CGFloat] = [0.90, 0.80, 0.70, 0.60, 0.50, 0.40, 0.30, 0.20, 0.10]
        var image = source

        for _ in 0..<12 {
            for quality in qualityLevels {
                guard let data = encodeJPEG(image, quality: quality) else { continue }
                if data.count <= Self.maximumJPEGBytes {
                    return data
                }
            }

            guard image.width > 1 || image.height > 1,
                  let resized = resize(image, factor: 0.75)
            else {
                break
            }
            image = resized
        }

        throw TranscriptImageCaptureError.imageEncodingFailed
    }

    private func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func resize(_ image: CGImage, factor: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * factor).rounded(.down)))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded(.down)))
        guard width != image.width || height != image.height else { return nil }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func geometryDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    private func normalizedTitle(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func frameDescription(_ frame: CGRect) -> String {
        "x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))"
    }
}

private struct CapturedWindowScreenshot {
    let image: CGImage
    let frame: CGRect
    let contentRect: CGRect
}

private struct CapturedSurfaceImage: @unchecked Sendable {
    let image: CGImage
    let contentRect: CGRect
    let contentScale: CGFloat?
    let scaleFactor: CGFloat?
}

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    @discardableResult
    func storeIfEmpty(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return false }
        value = result
        return true
    }

    func get() throws -> Value {
        lock.lock()
        let result = value
        lock.unlock()
        guard let result else {
            throw TranscriptImageCaptureError.screenshotUnavailable("capture completed without a result")
        }
        return try result.get()
    }
}

private final class SingleFrameStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let result: LockedResult<CapturedSurfaceImage>
    private let semaphore: DispatchSemaphore
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(result: LockedResult<CapturedSurfaceImage>, semaphore: DispatchSemaphore) {
        self.result = result
        self.semaphore = semaphore
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer,
                  createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[.status] as? Int,
              SCFrameStatus(rawValue: statusRawValue) == .complete,
              let contentRectValue = attachments[.contentRect] as? NSValue,
              let pixelBuffer = sampleBuffer.imageBuffer
        else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let surfaceImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let surfaceBounds = CGRect(
            x: 0,
            y: 0,
            width: surfaceImage.width,
            height: surfaceImage.height
        )
        let contentRect = contentRectValue.rectValue.integral.intersection(surfaceBounds)
        guard !contentRect.isNull,
              contentRect.width >= 1,
              contentRect.height >= 1
        else {
            return
        }

        let contentScale = (attachments[.contentScale] as? NSNumber).map { CGFloat(truncating: $0) }
        let scaleFactor = (attachments[.scaleFactor] as? NSNumber).map { CGFloat(truncating: $0) }
        let captured = CapturedSurfaceImage(
            image: surfaceImage,
            contentRect: contentRect,
            contentScale: contentScale,
            scaleFactor: scaleFactor
        )
        if result.storeIfEmpty(.success(captured)) {
            semaphore.signal()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if result.storeIfEmpty(.failure(error)) {
            semaphore.signal()
        }
    }
}

import CoreGraphics

/// Which part of a detected message image `read --capture-images` saves.
///
/// Kept free of AX and ScreenCaptureKit so the decision can be run on its own
/// (tests/test_read_image_capture_region.py compiles this file alone).
enum ImageCaptureRegion {
    /// A frame at least this visible is saved whole.
    static let wholeFrameVisibleRatio: CGFloat = 0.98
    /// A frame cut by the viewport is still saved, as its visible part only,
    /// when at least this much of it shows. Most of a photo tells the reader
    /// what it is; a sliver does not, and is left as `has_image` without a path.
    static let partialFrameVisibleRatio: CGFloat = 0.5

    /// The part of `frame` to save, or nil when too little of it is on screen.
    /// The viewport is the only clip that matters here: rows scroll under the
    /// transcript's top and bottom edges, never out of the window's sides.
    static func region(for frame: CGRect, in viewport: CGRect?) -> CGRect? {
        guard let viewport else { return nil }
        let ratio = visibleAreaRatio(of: frame, inside: viewport)
        if ratio >= wholeFrameVisibleRatio { return frame }
        guard ratio >= partialFrameVisibleRatio else { return nil }
        let visible = frame.intersection(viewport)
        return visible.isNull || visible.isEmpty ? nil : visible
    }

    /// One decision per detected frame, in message order then frame order.
    /// Every frame is judged alone: a clipped frame never costs another frame
    /// its pixels.
    static func regions(for messageFrames: [[CGRect]], in viewport: CGRect?) -> [[CGRect?]] {
        messageFrames.map { frames in frames.map { region(for: $0, in: viewport) } }
    }

    static func visibleAreaRatio(of frame: CGRect, inside bounds: CGRect) -> CGFloat {
        guard frame.width > 0, frame.height > 0 else { return 0 }
        let intersection = frame.intersection(bounds)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return (intersection.width * intersection.height) / (frame.width * frame.height)
    }
}

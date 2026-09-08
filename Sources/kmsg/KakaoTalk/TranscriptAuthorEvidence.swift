import Foundation
import CoreGraphics

/// AXStaticText is used for both sender names and shared-card titles. Text
/// content (even a short, name-like title) cannot distinguish those roles.
/// Keep this policy independent of AX so the exact production rule is runnable
/// against fixtures without opening customer conversations.
enum TranscriptAuthorEvidence {
    static func isSenderLabel(
        labelFrame: CGRect?,
        contentFrames: [CGRect],
        isDirectMetadata: Bool,
        isInsideContent: Bool,
        hasRichContent: Bool
    ) -> Bool {
        guard !isInsideContent else { return false }
        let frames = contentFrames.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        if let labelFrame, !labelFrame.isEmpty, !frames.isEmpty {
            // AX screen coordinates increase downwards. The sender is above
            // the bubble, while a preview's title/domain/price is inside it.
            return frames.allSatisfy { labelFrame.maxY <= $0.minY + 2 }
        }
        // At the viewport edge AX can lose every frame. Preserve ordinary
        // direct sender labels, but do not anchor a run on an unmeasured card.
        return isDirectMetadata && !hasRichContent
    }
}

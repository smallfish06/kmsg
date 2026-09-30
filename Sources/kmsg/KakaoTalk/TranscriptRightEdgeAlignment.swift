import CoreGraphics
import Foundation

/// Resolve wide outgoing text from the right edge shared by independently
/// measured short outgoing bubbles in this snapshot. No cross-read cache.
enum TranscriptRightEdgeAlignment {
    struct Row {
        let bodyFrame: CGRect?
        let side: String
        let explicitPeer: Bool
        let richContent: Bool
    }

    static func resolvedRows(_ rows: [Row], transcriptFrame: CGRect?) -> Set<Int> {
        func finitePositive(_ frame: CGRect) -> Bool {
            [frame.minX, frame.minY, frame.width, frame.height, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
                && frame.width > 0 && frame.height > 0
        }
        guard let root = transcriptFrame, finitePositive(root) else { return [] }
        func validBody(_ row: Row) -> CGRect? {
            guard !row.richContent, let body = row.bodyFrame, finitePositive(body),
                  body.minX >= root.minX, body.maxX <= root.maxX,
                  body.width <= root.width * 0.9 else { return nil }
            // Vertical clipping is normal for history above the viewport.
            return body
        }
        let anchors = rows.compactMap { row -> CGRect? in
            guard row.side == "right", !row.explicitPeer, let body = validBody(row),
                  body.width <= root.width * 0.6,
                  (body.midX - root.minX) / root.width >= 0.62,
                  root.maxX - body.maxX <= root.width * 0.12 else { return nil }
            return body
        }
        guard anchors.count >= 2, let low = anchors.map(\.maxX).min(),
              let high = anchors.map(\.maxX).max(), high - low <= 2 else { return [] }
        let edge = (low + high) / 2
        // If peer evidence reaches the same edge, alignment is not identifying
        // in this layout. Keep every ambiguous row unresolved.
        guard !rows.contains(where: { row in
            guard row.explicitPeer || row.side == "left", let body = validBody(row) else { return false }
            return abs(body.maxX - edge) <= 2
        }) else { return [] }
        return Set(rows.indices.filter { index in
            let row = rows[index]
            guard row.side == "unknown", !row.explicitPeer, let body = validBody(row) else { return false }
            return abs(body.maxX - edge) <= 2
        })
    }
}

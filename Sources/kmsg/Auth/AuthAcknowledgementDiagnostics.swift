import Foundation

/// Fixed numeric telemetry only. Two bounded summary lines survive the
/// bridge's 500-character forwarding limit without growing command summaries.
enum AuthAcknowledgementDiagnostics {
    static func lines(_ metrics: [String: Double]) -> [String] {
        guard let total = metrics["auth.ack"], total.isFinite, total >= 0, total <= 86400 else { return [] }
        let sections: [[(String, String, Bool)]] = [
            [("walk", "auth.ackwalk", true), ("guard", "auth.ackguard", true),
             ("fallback", "auth.ackfb", true), ("runs", "auth.ackruns", false),
             ("roots", "auth.ackroots", false), ("active", "auth.ackactive", false),
             ("plans", "auth.ackplans", false), ("credit", "auth.ackcredit", false),
             ("planNodes", "auth.ackplanodes", false), ("guardMax", "auth.ackguardmax", false),
             ("reason", "auth.ackreason", false)],
            [("hits", "auth.ackhits", false), ("nodes", "auth.acknodes", false),
             ("reused", "auth.ackreused", false), ("live", "auth.acklive", false),
             ("validation", "auth.ackvbatch", false), ("rootReads", "auth.ackrread", false),
             ("rootValidation", "auth.ackvrread", false), ("unknown", "auth.ackunknown", false),
             ("fallbacks", "auth.ackfallbacks", false)],
        ]
        var lines: [String] = []
        for (index, section) in sections.enumerated() {
            var line = String(format: "[kmsg] auth-detail total=%.2f status=done schema=1 part=%d", total, index + 1)
            for (label, key, isTime) in section {
                guard let value = metrics[key], value.isFinite, value >= 0,
                      value <= (isTime ? 86400 : 1_000_000_000),
                      isTime || value.rounded(.towardZero) == value else { return [] }
                line += " \(label)=" + String(format: isTime ? "%.2f" : "%.0f", value)
            }
            guard line.utf8.count < 500 else { return [] }
            lines.append(line)
        }
        return lines
    }
}

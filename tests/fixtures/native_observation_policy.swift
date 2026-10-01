import Foundation
import CoreGraphics

typealias Native = TranscriptNativeObservation
var checks = 0
func check(_ label: String, _ value: @autoclosure () -> Bool) {
    checks += 1
    if !value() { fatalError(label) }
}
func row(_ id: Int, _ y: CGFloat, body: String = "same", date: String = "2026-10-01",
         owner: String = "peer", frame: CGRect? = nil, bodyFrame: CGRect? = nil,
         sourceBody: Int? = nil, missingRow: Bool = false, missingBody: Bool = false,
         origin: Native.Origin = .rowParser, ambiguous: Bool = false) -> Native.Candidate {
    Native.Candidate(source: Native.Source(row: missingRow ? nil : id, body: missingBody ? nil : (sourceBody ?? id + 100),
        rowFrame: frame ?? CGRect(x: 0, y: y, width: 400, height: 40),
        bodyFrame: bodyFrame ?? CGRect(x: owner == "peer" ? 20 : 260, y: y + 10, width: 100, height: 20),
        origin: origin, ambiguous: ambiguous), legacyKey: owner + "|12:00|" + body, signature: [owner, body, date])
}
func selected(_ rows: [Native.Candidate], stable: Bool = true, limit: Int = 10) -> Native.Selection {
    Native.select(rows, limit: limit, stable: stable)
}
let a = row(1, 0), b = row(2, 50)
check("distinct equal physical text retained", selected([a, b]).indices == [0, 1])
check("distinct equal text verified", selected([a, b]).order == .verified)
check("multiplicity carries physical source proof", selected([a, b]).multiplicity == .physicalRow)
check("one source exposed twice collapses", selected([a, a, b]).indices == [0, 2])
check("same-source exposure keeps order proof", selected([a, a, b]).order == .verified)
check("same source moving during parse cannot certify", selected([a, row(1, 100)]).order == .uncertain)
let fallbackA = row(1, 0, origin: .fallback)
check("parser plus same-source fallback merges", selected([a, b, fallbackA]).indices == [0, 1])
check("fallback merge does not certify order", selected([a, b, fallbackA]).order == .uncertain)
let orphan = Native.Candidate(source: nil, legacyKey: a.legacyKey, signature: a.signature)
check("unassociated equal fallback cannot inflate count", selected([a, orphan]).indices == [0])
check("unassociated fallback is legacy", selected([a, orphan]).multiplicity == .legacy)
check("same minute mixed sides retain order", selected([a, row(2, 50, owner: "self")]).order == .verified)
check("same minute same text different days retained", selected([a, row(2, 50, date: "2026-10-02")]).indices.count == 2)
check("equal vertical geometry cannot certify", selected([a, row(2, 0)]).order == .uncertain)
check("equal geometry does not inflate repeated text", selected([a, row(2, 0)]).indices.count == 1)
check("overlap does not inflate repeated text", selected([a, row(2, 20)]).indices.count == 1)
check("reordered observations never certify", selected([b, a]).order == .uncertain)
check("recollection does not certify", selected([a, b], stable: false).order == .uncertain)
check("coherent recollection keeps multiplicity", selected([a, b], stable: false).indices == [0, 1])
check("missing row association does not certify", selected([a, row(2, 50, missingRow: true)]).multiplicity == .legacy)
check("missing body association does not certify", selected([a, row(2, 50, missingBody: true)]).multiplicity == .legacy)
let noBounds = Native.Candidate(source: Native.Source(row: 2, body: 102, rowFrame: nil, bodyFrame: nil,
    origin: .rowParser, ambiguous: false), legacyKey: a.legacyKey, signature: a.signature)
check("missing bounds do not inflate", selected([a, noBounds]).indices.count == 1)
check("ambiguous body association falls back", selected([a, row(2, 50, ambiguous: true)]).multiplicity == .legacy)
for bad in [CGRect.zero, CGRect.null, CGRect.infinite,
            CGRect(x: 0, y: CGFloat.nan, width: 400, height: 40), CGRect(x: 0, y: 50, width: -10, height: 40)] {
    check("invalid row frame cannot certify", selected([a, row(2, 50, frame: bad)]).order == .uncertain)
    check("invalid body frame cannot certify", selected([a, row(2, 50, bodyFrame: bad)]).order == .uncertain)
}
check("body outside associated row rejected", selected([a, row(2, 50, bodyFrame: CGRect(x: 10, y: 150, width: 100, height: 20))]).order == .uncertain)
check("negative raw frame size cannot certify", selected([row(1, 0, frame: CGRect(x: 400, y: 0, width: -400, height: 40))]).order == .uncertain)
check("identical body node in different rows cannot inflate", selected([a, row(2, 50, sourceBody: 101)]).indices.count == 1)
check("body conflict cannot certify", selected([a, row(2, 50, sourceBody: 101)]).order == .uncertain)
check("different exposure body for one row cannot inflate", selected([a, row(1, 0, body: "changed", sourceBody: 300)]).indices.count == 1)
check("transitive source overlap cannot inflate", selected([a, row(1, 0, sourceBody: 300), row(2, 50, sourceBody: 300)]).indices.count == 1)
check("final limit preserves ordinals", selected([a, b, row(3, 100)], limit: 2).indices == [1, 2])
check("unreturned missing old bounds do not taint final window", selected([noBounds, row(3, 100), row(4, 150)], limit: 2).order == .verified)
check("empty has no proof", selected([]).indices.isEmpty && selected([]).order == .uncertain)
check("zero limit is safe", selected([a], limit: 0).indices.isEmpty)
unsetenv("KMSG_NATIVE_OBSERVATION_ENABLED")
check("absent flag is off", !Native.isEnabled)
for value in ["false", "1", "TRUE", "true "] {
    setenv("KMSG_NATIVE_OBSERVATION_ENABLED", value, 1)
    check("only explicit true enables the pilot", !Native.isEnabled)
}
setenv("KMSG_NATIVE_OBSERVATION_ENABLED", "true", 1)
check("explicit true enables the pilot", Native.isEnabled)
unsetenv("KMSG_NATIVE_OBSERVATION_ENABLED")
print("OK: \(checks) pure observation assertions")

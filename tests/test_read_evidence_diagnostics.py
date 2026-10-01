"""Actual parser + bounded metadata diagnostics over in-memory AX objects.

No live AX, Kakao, network, messages, or admission policy changes are exercised.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_native_observation import production_harness

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "Sources/kmsg/KakaoTalk"
CASES = r'''
let parser = Parser()
let reference = Date(timeIntervalSince1970: 1_790_827_200)
func makeRows() -> [UIElement] {
    (0..<6).map { index in
        let y = CGFloat(index * 60)
        let text = UIElement(kAXTextAreaRole, CGRect(x:20,y:y+24,width:180,height:20), "CUSTOMER_SECRET_SENTINEL \(index)")
        let time = UIElement(kAXStaticTextRole, CGRect(x:20,y:y+44,width:80,height:12), "오후 12:00")
        time.helpText = "2026. 10. 1."
        let name = UIElement(kAXStaticTextRole, CGRect(x:20,y:y+4,width:80,height:16), "PEER_SECRET_SENTINEL")
        let result = UIElement(kAXRowRole, CGRect(x:0,y:y,width:400,height:60), children:[
            UIElement(kAXCellRole, CGRect(x:0,y:y,width:400,height:60), children:[name,text,time])])
        UIElement.identifierValues[ObjectIdentifier(result.axElement)] = "PRIVATE_ROW_IDENTIFIER_\(index)"
        UIElement.identifierValues[ObjectIdentifier(text.axElement)] = "GENERIC_BODY_IDENTIFIER"
        return result
    }
}
func semantic(_ rows: [TranscriptMessage]) -> [[String: Any]] {
    rows.map { row in
        var result = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as! [String: Any]
        if var observation = result["native_observation"] as? [String: Any] {
            observation["id"] = "read-local-uuid"; result["native_observation"] = observation
        }
        return result
    }
}
func ordinaryCalls(_ rows: [UIElement]) -> [Int] {
    var counts = [0,0,0,0]
    func visit(_ node: UIElement) {
        counts[0] += node.frameReads; counts[1] += node.childReads
        counts[2] += node.searches; counts[3] += node.attributeReads
        node.nodes.forEach(visit)
    }
    rows.forEach(visit); return counts
}
func run(_ rows: [UIElement], timing: Bool, native: Bool, fresh: [UIElement]? = nil) -> ([TranscriptMessage], Int, [Int]) {
    setenv("KMSG_READ_TIMING_ENABLED", timing ? "true" : "false", 1)
    setenv("KMSG_NATIVE_OBSERVATION_ENABLED", native ? "true" : "false", 1)
    let root = UIElement(kAXScrollAreaRole, CGRect(x:0,y:-10,width:400,height:1200), children:rows)
    let cache = FrameCache()
    if TranscriptReadEvidenceDiagnostics.enabled { cache.readEvidence = TranscriptReadEvidenceDiagnostics() }
    cache.lastCollectedRow = rows.last?.axElement
    cache.readEvidence?.setCollection([rows.count,rows.count,rows.count,rows.count,0,0,0,0,0,0,0])
    let before = UIElement.identifierReads
    let result = parser.extractMessages(from:rows,transcriptRoot:root,limit:10,includeSystemMessages:false,
        referenceDate:reference,frameCache:cache,recollectRows:{ candidate in
            let chosen = fresh ?? rows
            candidate.lastCollectedRow = chosen.last?.axElement
            candidate.readEvidence?.setCollection([chosen.count,chosen.count,chosen.count,chosen.count,0,0,0,0,0,0,0])
            return chosen
        }).messages
    return (result, UIElement.identifierReads-before, ordinaryCalls(rows))
}
let offRows = makeRows(), onRows = makeRows()
let off = run(offRows,timing:false,native:true)
let on = run(onRows,timing:true,native:true)
let offNative = run(makeRows(),timing:true,native:false)
let offBoth = run(makeRows(),timing:false,native:false)
let sparse = run((0..<30).map{_ in UIElement(kAXRowRole)},timing:true,native:true,fresh:makeRows())
let unsupportedRows = makeRows()
func clearIDs(_ nodes: [UIElement]) {
    for node in nodes {
        UIElement.identifierValues.removeValue(forKey:ObjectIdentifier(node.axElement)); clearIDs(node.nodes)
    }
}
clearIDs(unsupportedRows)
let unsupported = run(unsupportedRows,timing:true,native:true)
var privacyLines: [String] = []
let diagnostics = TranscriptReadEvidenceDiagnostics()
let helpValues: [String?] = [nil,"","2026. 10. 1.","2026-10-01T12:00:05Z","1234567890","HELP_SECRET_SENTINEL",String(repeating:"x",count:600)]
helpValues.forEach { diagnostics.recordHelp($0) }
var directCalls = 0
TranscriptReadEvidenceDiagnostics.emit(snapshot:diagnostics.snapshot(),pass:1,
    sources:(0..<10).map{(row:$0*2,body:$0*2+1)},lastRowSourcePresent:true,lastBodySourcePresent:true,
    lastCollectedRowCompared:true,lastCollectedRowMatches:true,readIdentifier:{ id in
        directCalls += 1
        switch id {
        case 14: return .value("010-1234-5678")
        case 15: return .value("PRIVATE_IDENTIFIER_SENTINEL")
        case 16: return .unsupported
        case 17: return .noValue
        case 18: return .failed
        default: return .value("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        }
    },write:{privacyLines.append($0)})
let semanticEqual = NSDictionary(dictionary:["rows":semantic(off.0)]).isEqual(to:["rows":semantic(on.0)])
let sparseEqual = NSDictionary(dictionary:["rows":semantic(on.0)]).isEqual(to:["rows":semantic(sparse.0)])
let keys = Set((semantic(on.0)[0]["native_observation"] as! [String:Any]).keys)
var slowLines: [String] = [], slowCalls = 0
TranscriptReadEvidenceDiagnostics.emit(snapshot:diagnostics.snapshot(),pass:1,
    sources:(0..<3).map{(row:$0*2,body:$0*2+1)},lastRowSourcePresent:true,lastBodySourcePresent:true,
    lastCollectedRowCompared:true,lastCollectedRowMatches:true,readIdentifier:{ _ in
        slowCalls += 1; Thread.sleep(forTimeInterval:0.11); return .failed
    },write:{slowLines.append($0)})
let result: [String:Any] = ["semanticEqual":semanticEqual,"sparseEqual":sparseEqual,
    "sameOrdinaryAXCalls":off.2 == on.2,"offIdentifierCalls":off.1,"onIdentifierCalls":on.1,
    "offNativeCalls":offNative.1,"offBothCalls":offBoth.1,"sparseIdentifierCalls":sparse.1,
    "unsupportedIdentifierCalls":unsupported.1,"directIdentifierCalls":directCalls,
    "privacyLines":privacyLines,"nativeObservationKeys":keys.sorted(),
    "slowIdentifierCalls":slowCalls,"slowLines":slowLines,
    "latestEndCertificatePresent":semantic(on.0).contains{$0["latest_end"] != nil},
    "helpShapes":helpValues.map{TranscriptReadEvidenceDiagnostics.helpShape($0)}]
print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
'''


@unittest.skipIf(shutil.which("swiftc") is None, "swiftc not available")
class ReadEvidenceDiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            main = folder / "main.swift"
            main.write_text(production_harness((NATIVE / "TranscriptReader.swift").read_text()) + CASES)
            sdk_args = []
            if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
                sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True, check=True)
                sdk_args = ["-sdk", sdk.stdout.strip()]
            helpers = [NATIVE / f"{name}.swift" for name in ["TranscriptAuthorEvidence", "TranscriptRightEdgeAlignment",
                "TranscriptAttributionRecovery", "TranscriptNativeObservation", "TranscriptReadEvidenceDiagnostics"]]
            binary = folder / "read-evidence"
            built = subprocess.run(["swiftc", *sdk_args, *map(str, helpers), str(main), "-o", str(binary)], capture_output=True, text=True)
            if built.returncode:
                raise AssertionError(built.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode:
                raise AssertionError(run.stdout + run.stderr)
            cls.data = json.loads(run.stdout)
            cls.stderr = run.stderr
            path = os.environ.get("KMSG_READ_EVIDENCE_FIXTURE_REPORT")
            if path:
                Path(path).write_text(json.dumps({"data":cls.data,"diagnostics":cls.stderr.splitlines()},indent=2) + "\n")

    def test_selected_messages_order_and_certificate_are_unchanged(self):
        self.assertTrue(self.data["semanticEqual"])
        self.assertTrue(self.data["sparseEqual"])
        self.assertFalse(self.data["latestEndCertificatePresent"])
        self.assertEqual(self.data["nativeObservationKeys"], ["count","id","index","multiplicity","order","version"])

    def test_only_two_flags_enable_at_most_six_identifier_queries(self):
        for key in ["offIdentifierCalls","offNativeCalls","offBothCalls"]:
            self.assertEqual(self.data[key],0)
        for key in ["onIdentifierCalls","sparseIdentifierCalls","unsupportedIdentifierCalls","directIdentifierCalls"]:
            self.assertEqual(self.data[key],6)
        self.assertTrue(self.data["sameOrdinaryAXCalls"])

    def test_help_shapes_use_existing_values_without_treating_seconds_as_identity(self):
        self.assertEqual(self.data["helpShapes"],list(range(7)))

    def test_one_slow_identifier_query_prevents_additional_diagnostic_queries(self):
        self.assertEqual(self.data["slowIdentifierCalls"],1)
        self.assertEqual(len(self.data["slowLines"]),2)
        values = list(map(int,self.data["slowLines"][1].split("ident=",1)[1].split("/")))
        self.assertEqual(values[1],1)  # actual calls
        self.assertEqual(values[-1],5)  # skipped by the launch budget
        self.assertGreaterEqual(values[-2],100)

    def test_no_raw_metadata_or_customer_text_is_logged(self):
        output = self.stderr + "\n".join(self.data["privacyLines"])
        for sentinel in ["CUSTOMER_SECRET_SENTINEL","PEER_SECRET_SENTINEL","HELP_SECRET_SENTINEL",
                         "PRIVATE_IDENTIFIER_SENTINEL","PRIVATE_ROW_IDENTIFIER","GENERIC_BODY_IDENTIFIER",
                         "010-1234-5678","aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]:
            self.assertNotIn(sentinel,output)
        self.assertTrue(all(len(line)<500 for line in output.splitlines()))

    def test_fixed_numeric_schema_has_two_parts_for_each_selected_pass(self):
        lines = self.stderr.splitlines()
        self.assertEqual(len(lines),6)
        self.assertEqual(sum("part=1" in line for line in lines),3)
        self.assertEqual(sum("part=2" in line for line in lines),3)
        self.assertTrue(any("pass=2" in line for line in lines))
        for line in lines:
            self.assertRegex(line,r"^\[kmsg\] read-evidence total=[0-9.]+ status=ok part=[12] schema=1 ")
        for first, second in zip(lines[::2],lines[1::2]):
            self.assertEqual(first.split("total=",1)[1].split()[0],second.split("total=",1)[1].split()[0])

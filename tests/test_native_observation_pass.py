"""Actual parser provenance/AX boundary tests; no GUI or customer messages.

A fresh pass can certify only its own complete selected rows. The original
sparse failure and actual Supervisor comparison are retained in the rollout
archive, independently of these forward regression tests.
"""
import json
import os
from pathlib import Path
import shutil
import unittest
from test_native_observation import production_harness, swift_run

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "Sources/kmsg/KakaoTalk"
CASES = r'''

setenv("KMSG_NATIVE_OBSERVATION_ENABLED", "true", 1)
let parser = Parser()
let reference = Date(timeIntervalSince1970: 1_790_827_200)
func makeRow(_ index: Int, _ body: String, owner: String = "peer") -> UIElement {
    let y = CGFloat(index * 60), x: CGFloat = owner == "peer" ? 20 : 260
    let text = UIElement(kAXTextAreaRole, CGRect(x:x,y:y+24,width:100,height:20),body)
    let time = UIElement(kAXStaticTextRole, CGRect(x:x,y:y+44,width:80,height:12),"오후 12:00")
    time.helpText = "2026. 10. 1."
    var children = [text,time]
    if owner == "peer" { children.insert(UIElement(kAXStaticTextRole,CGRect(x:x,y:y+4,width:80,height:16),"peer fixture"),at:0) }
    return UIElement(kAXRowRole,CGRect(x:0,y:y,width:400,height:60),children:[
        UIElement(kAXCellRole,CGRect(x:0,y:y,width:400,height:60),children:children)])
}
func baseline() -> [UIElement] { (0..<11).map { makeRow($0,$0 == 10 ? "previous own reply" : "synthetic own \($0)",owner:"self") } + [makeRow(11,"repeat")] }
func appended() -> [UIElement] { baseline() + [makeRow(12,"repeat")] }
func extract(_ rows: [UIElement], fresh: [UIElement]? = nil, rootRows: [UIElement]? = nil, enabled: Bool = true) -> [String:Any] {
    if enabled { setenv("KMSG_NATIVE_OBSERVATION_ENABLED", "true", 1) }
    else { unsetenv("KMSG_NATIVE_OBSERVATION_ENABLED") }
    let root = UIElement(kAXScrollAreaRole,CGRect(x:0,y:-10,width:400,height:1500),children:rootRows ?? fresh ?? rows)
    let cache = FrameCache()
    var recollections = 0, distinctSources = true, distinctCaches = true
    let result = parser.extractMessages(from:rows,transcriptRoot:root,limit:10,includeSystemMessages:false,
        referenceDate:reference,frameCache:cache,recollectRows:{ freshCache in
            recollections += 1
            distinctSources = distinctSources && cache.observationSources !== freshCache.observationSources
            distinctCaches = distinctCaches && cache !== freshCache
            return fresh ?? rows
        })
    let payload = try! JSONSerialization.jsonObject(with:JSONEncoder().encode(result.messages)) as! [[String:Any]]
    var seen = Set<ObjectIdentifier>(), calls = [0,0,0,0]
    func count(_ node: UIElement) {
        guard seen.insert(ObjectIdentifier(node)).inserted else { return }
        calls[0] += node.frameReads; calls[1] += node.childReads
        calls[2] += node.searches; calls[3] += node.attributeReads
        node.nodes.forEach(count)
    }
    ([root] + rows + (fresh ?? [])).forEach(count)
    return ["messages":payload,"calls":calls,"recollections":recollections,
        "freshSourcesDistinct":distinctSources,"freshCachesDistinct":distinctCaches,"notes":Dictionary(uniqueKeysWithValues:result.notes.map{($0.key,$0.value)}),
        "repeatRows":result.messages.filter{$0.body == "repeat"}.count,
        "order":result.messages.first?.nativeObservation?.order.rawValue ?? "empty",
        "multiplicity":result.messages.first?.nativeObservation?.multiplicity.rawValue ?? "empty"]
}
let dead = (0..<30).map{_ in UIElement(kAXRowRole)}
var results:[String:[String:Any]] = [:]
results["baseline"] = extract(baseline())
results["direct-fresh-append"] = extract(appended())
results["sparse-full-replacement"] = extract(dead,fresh:appended())
results["sparse-partial-fresh"] = extract((0..<30).map{_ in UIElement(kAXRowRole)},fresh:[makeRow(11,"repeat"),makeRow(12,"repeat")])
results["sparse-empty-fresh"] = extract((0..<30).map{_ in UIElement(kAXRowRole)},fresh:[])
let shared = makeRow(11,"repeat")
results["same-ax-row-twice"] = extract(Array(baseline().prefix(11))+[shared,shared])
let sameGeometry = baseline()+[makeRow(11,"repeat")]
results["different-ax-same-geometry"] = extract(sameGeometry)
let unknown = appended()
unknown[12].bounds = nil
unknown[12].nodes[0].nodes = [UIElement(kAXTextAreaRole,nil,"repeat"),UIElement(kAXStaticTextRole,nil,"오후 12:00")]
results["attribution-fresh-replacement"] = extract(unknown,fresh:appended())
let changed = appended(); changed[11].nodes[0].nodes[0].stringValue = "other peer fixture"
results["attribution-known-owner-changed"] = extract(unknown,fresh:changed)
let shifted = baseline() + [makeRow(12,"different last input")]
results["attribution-window-changed"] = extract(unknown,fresh:shifted)
let ambiguous = appended()
ambiguous[12].nodes[0].nodes.append(UIElement(kAXTextAreaRole,CGRect(x:20,y:744,width:100,height:20),"repeat"))
results["ambiguous-body-node"] = extract(ambiguous)

let heldMessages = (0..<26).map{_ in UIElement(kAXRowRole)} + (26..<30).map{ makeRow($0,"retained first \($0)") }
results["held-rows-reparse-empty-recollection"] = extract(heldMessages,fresh:[],rootRows:heldMessages)
results["fresh-worse-retains-first"] = extract(heldMessages,fresh:[makeRow(28,"worse fresh 1"),makeRow(29,"worse fresh 2")])
let sharedBodyRows = appended()
sharedBodyRows[12].nodes[0].nodes[1] = sharedBodyRows[11].nodes[0].nodes[1]
results["shared-ax-body-distinct-rows"] = extract(sharedBodyRows)

results["direct-fresh-off"] = extract(appended(),enabled:false)
results["sparse-full-replacement-off"] = extract((0..<30).map{_ in UIElement(kAXRowRole)},fresh:appended(),enabled:false)
let data=try! JSONSerialization.data(withJSONObject:results,options:[.sortedKeys])
print(String(data:data,encoding:.utf8)!)

'''

@unittest.skipIf(shutil.which("swiftc") is None, "swiftc not available")
class NativeObservationPassTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (NATIVE / "TranscriptReader.swift").read_text()
        helpers = [NATIVE / f"{name}.swift" for name in ["TranscriptAuthorEvidence",
            "TranscriptRightEdgeAlignment", "TranscriptAttributionRecovery", "TranscriptNativeObservation"]]
        cls.cases = json.loads(swift_run(production_harness(source) + CASES, helpers))
        path = os.environ.get("KMSG_PARSE_PASS_FIXTURE_REPORT")
        if path:
            Path(path).write_text(json.dumps(cls.cases, indent=2) + "\n")

    def test_complete_fresh_sparse_selection_matches_direct_final_parse(self):
        direct, sparse = (self.cases[k] for k in ["direct-fresh-append", "sparse-full-replacement"])
        semantic = lambda rows: [{k:v for k,v in row.items() if k != "native_observation"} for row in rows]
        self.assertEqual(semantic(direct["messages"]), semantic(sparse["messages"]))
        self.assertEqual(sparse["order"], "verified")
        self.assertEqual(sparse["multiplicity"], "physical-row")
        self.assertEqual(sparse["repeatRows"], 2)
        self.assertEqual(sparse["notes"], {"sparse":"0/30","held0":"30/30","fresh":"13","reparse":"12"})
        self.assertEqual(sparse["recollections"], 1)

    def test_fresh_recollections_own_both_source_registry_and_cache(self):
        for name in ["sparse-full-replacement", "attribution-fresh-replacement", "fresh-worse-retains-first"]:
            with self.subTest(name=name):
                case = self.cases[name]
                self.assertGreater(case["recollections"], 0)
                self.assertTrue(case["freshSourcesDistinct"])
                self.assertTrue(case["freshCachesDistinct"])

    def test_held_rows_and_rejected_worse_fresh_pass_remain_uncertain(self):
        for name in ["held-rows-reparse-empty-recollection", "fresh-worse-retains-first"]:
            with self.subTest(name=name):
                case = self.cases[name]
                self.assertEqual(case["order"], "uncertain")
                self.assertEqual(case["notes"]["reparse"], "4")
                self.assertTrue(any(row["body"].startswith("retained first") for row in case["messages"]))
        self.assertNotIn("fresh", self.cases["held-rows-reparse-empty-recollection"]["notes"])

    def test_partial_empty_and_fallback_mixtures_gain_no_certificate(self):
        partial = self.cases["sparse-partial-fresh"]
        self.assertEqual(partial["order"], "uncertain")
        self.assertIn("fb", partial["notes"])
        self.assertEqual(partial["repeatRows"], 1)
        self.assertEqual(self.cases["sparse-empty-fresh"]["messages"], [])

    def test_attribution_acceptance_and_rejection_keep_existing_proof_boundary(self):
        for name, accepted in [("attribution-fresh-replacement","1"),
                               ("attribution-known-owner-changed","0"), ("attribution-window-changed","0")]:
            with self.subTest(name=name):
                self.assertEqual(self.cases[name]["notes"]["attraccepted"], accepted)
                self.assertEqual(self.cases[name]["order"], "uncertain")
        self.assertEqual(self.cases["attribution-fresh-replacement"]["repeatRows"], 2)

    def test_repeated_ax_exposure_is_one_row_and_cross_row_source_conflict_is_uncertain(self):
        self.assertEqual(self.cases["same-ax-row-twice"]["repeatRows"], 1)
        self.assertEqual(self.cases["same-ax-row-twice"]["order"], "verified")
        shared = self.cases["shared-ax-body-distinct-rows"]
        self.assertEqual(shared["repeatRows"], 1)
        self.assertEqual(shared["order"], "uncertain")
        self.assertEqual(shared["multiplicity"], "legacy")

    def test_geometry_and_multiple_body_nodes_cannot_claim_new_physical_rows(self):
        for name in ["different-ax-same-geometry", "ambiguous-body-node"]:
            with self.subTest(name=name):
                self.assertEqual(self.cases[name]["order"], "uncertain")
                self.assertEqual(self.cases[name]["multiplicity"], "legacy")
                self.assertEqual(self.cases[name]["repeatRows"], 1)

    def test_final_limits_and_one_certificate_describe_exact_returned_array(self):
        for name, case in self.cases.items():
            if name.endswith("-off"): continue
            rows = case["messages"]
            self.assertLessEqual(len(rows), 10, name)
            self.assertEqual([r["native_observation"]["index"] for r in rows], list(range(len(rows))), name)
            self.assertTrue(all(r["native_observation"]["count"] == len(rows) for r in rows), name)
            self.assertLessEqual(len({r["native_observation"]["id"] for r in rows}), 1, name)

    def test_feature_off_retains_content_dedup_and_no_new_ax_work(self):
        for name in ["direct-fresh", "sparse-full-replacement"]:
            on = self.cases["direct-fresh-append" if name == "direct-fresh" else name]
            off = self.cases[name + "-off"]
            self.assertEqual(off["repeatRows"], 1)
            self.assertTrue(all("native_observation" not in row for row in off["messages"]))
            self.assertEqual(on["calls"], off["calls"])
            self.assertEqual(on["notes"], off["notes"])

if __name__ == "__main__":
    unittest.main()

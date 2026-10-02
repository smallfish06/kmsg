"""Actual v11 row parser vs optional numeric cost observer; fake AX only."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from test_auth_ack_structure_scope import block
from test_native_observation import production_harness

ROOT=Path(os.environ.get('KMSG_NATIVE_TEST_ROOT',Path(__file__).resolve().parents[1]))
NATIVE=ROOT/'Sources/kmsg/KakaoTalk'
FIXTURES=Path(__file__).parent/'fixtures'
READER=Path(os.environ.get('KMSG_PARSE_COST_SOURCE',NATIVE/'TranscriptReader.swift'))
LINE=re.compile(r'^\[kmsg\] parse-cost total=(\d{1,3}\.\d{3}) status=done schema=1 selected=([0-6]) ms=(1(?:/\d{1,5}){11}) counts=(1(?:/\d{1,5}){16}) clip=([01])$')
CLOCK=r'''
var AXEvents:[String]=[], ControlEvents:[String]=[]
enum ParseFixtureClock {
    static var calls=0, slept:UInt64=0
    static func now()->UInt64 {calls+=1;return UInt64(AXEvents.count)*1_000_000+slept}
}
func fixtureSleep(forTimeInterval:Double) {
    ControlEvents.append("sleep");ParseFixtureClock.slept += UInt64(forTimeInterval*1_000_000_000)
}
final class AXTraversalReadScope {
    func children(atRoot root:UIElement)->[UIElement] {root.children}
    func roleAndChildren(of element:UIElement)->(role:String?,children:[UIElement]) {element.roleAndChildren()}
}
'''
HELPER_CASES=r'''
if CommandLine.arguments.contains("helper") {
    var time:UInt64=0
    let c=TranscriptParseCost(now:{time})
    for slice in TranscriptParseCost.Slice.allCases {
        time=0;let started=c.mark();time=UInt64.max;c.end(slice,started)
    }
    for field in TranscriptParseCost.Count.allCases {c.add(field,Int.max);c.add(field,Int.max)}
    var lines:[String]=[]
    c.emit(selectedPass:6,write:{lines.append($0)})
    c.emit(selectedPass:6,write:{lines.append($0)})
    let backwards=TranscriptParseCost(now:{time})
    time=100;let start=backwards.mark();time=0;backwards.end(.parse,start)
    let empty=TranscriptParseCost()
    let saved=dup(STDERR_FILENO);close(STDERR_FILENO)
    empty.emit(selectedPass:0)
    dup2(saved,STDERR_FILENO);close(saved)
    print(String(data:try! JSONSerialization.data(withJSONObject:["lines":lines,"backwards":backwards.line(selectedPass:99),"closedSinkReturned":true]),encoding:.utf8)!)
    exit(0)
}
'''

def traced_harness(source,ui):
    program=production_harness(source).replace('Thread.sleep(forTimeInterval:', 'fixtureSleep(forTimeInterval:')
    program=program.replace('import Foundation\n','import Foundation\nimport Darwin\n'+CLOCK,1)
    # All ordinary AX reads receive stable synthetic element IDs. No new
    # values or identities are read by the cost observer.
    program=program.replace('final class UIElement {','final class UIElement {\n    static var nextID=0\n    let probeID:Int\n    func event(_ key:String) {AXEvents.append("\\(probeID):"+key)}')
    program=program.replace('    let role: String?','    private let storedRole: String?\n    var role:String? {event("role");return storedRole}')
    for name in ['title','stringValue','helpText']:
        program=program.replace('    var '+name+': String?','    private var raw_'+name+': String?\n    var '+name+':String? {get {event("'+name+'");return raw_'+name+'} set {raw_'+name+'=newValue}}')
    program=program.replace('    weak var parent: UIElement?','    private weak var rawParent:UIElement?\n    var parent:UIElement? {get {event("parent");return rawParent} set {rawParent=newValue}}')
    program=program.replace('self.role = role; bounds = frame; stringValue = value;', 'Self.nextID+=1;probeID=Self.nextID;storedRole = role; bounds = frame; raw_stringValue = value;')
    program=program.replace('childReads += 1; return nodes','event("children");childReads += 1; return nodes')
    program=program.replace('frameReads += 1; return bounds','event("frame");frameReads += 1; return bounds')
    program=program.replace('        attributeReads += 1','        event("attribute:"+name);attributeReads += 1')
    program=program.replace('func valueAndHelp() -> (String?, String?) { (stringValue, helpText) }','func valueAndHelp() -> (String?, String?) {event("value-help-batch");return (raw_stringValue, raw_helpText)}\n    func roleAndChildren()->(role:String?,children:[UIElement]) {event("structure-batch");return(storedRole,nodes)}')
    # Use actual production bounded traversal bodies, not a shadow visit count.
    signatures=['    func findAll(roles:', '    func findAll(role:', '    func findAll(where predicate:']
    actual=['    public func findAll(\n        roles:', '    public func findAll(role: String, limit: Int', '    public func findAll(where predicate: (UIElement) -> Bool, limit:']
    for old,new in zip(signatures,actual):
        existing=block(program,program.index(old))
        method=block(ui,ui.index(new)).replace('public ','')
        program=program.replace(existing,method)
    # Replace only the clock provider in the real optional observer; OFF must
    # perform zero reads of this test clock.
    program=program.replace('init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds })', 'init(now: @escaping () -> UInt64 = { ParseFixtureClock.now() })')
    return program

@unittest.skipIf(shutil.which('swiftc') is None,'swiftc unavailable')
class TranscriptParseCostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.tmp.cleanup)
        path=Path(cls.tmp.name)
        baseline=(FIXTURES/'transcript_parse_cost_reference.swift').read_text()
        candidate=READER.read_text();ui=(ROOT/'Sources/kmsg/Accessibility/UIElement.swift').read_text()
        cases=(FIXTURES/'transcript_parse_cost.swift').read_text()
        helpers=[NATIVE/(name+'.swift') for name in ['TranscriptAuthorEvidence','TranscriptRightEdgeAlignment','TranscriptAttributionRecovery','TranscriptNativeObservation','TranscriptReadEvidenceDiagnostics']]
        sdk=[]
        if sys.platform=='darwin' and not os.environ.get('SDKROOT'):
            sdk=['-sdk',subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()]
        cls.runs={};cls.diagnostics={};cls.logs={}
        for name,source in [('baseline',baseline),('candidate',candidate)]:
            main=path/'main.swift';binary=path/name
            main.write_text(traced_harness(source,ui)+(HELPER_CASES if name=='candidate' else '')+cases)
            built=subprocess.run(['swiftc',*sdk,*map(str,helpers),str(main),'-o',str(binary)],capture_output=True,text=True)
            if built.returncode:raise AssertionError(built.stdout+built.stderr)
            for mode in ['off','on']:
                run=subprocess.run([str(binary),mode],capture_output=True,text=True)
                if run.returncode:raise AssertionError(run.stdout+run.stderr)
                cls.runs[name,mode]=json.loads(run.stdout);cls.logs[name,mode]=run.stderr.splitlines()
                cls.diagnostics[name,mode]=[LINE.fullmatch(line) for line in run.stderr.splitlines() if line.startswith('[kmsg] parse-cost ')]
            if name=='candidate':
                run=subprocess.run([str(binary),'helper'],capture_output=True,text=True,check=True)
                cls.helper=json.loads(run.stdout)
        report=os.environ.get('KMSG_PARSE_COST_REPORT')
        if report:
            projected=[]
            for mode in ['off','on']:
                for name,b in cls.runs['baseline',mode].items():
                    c=cls.runs['candidate',mode][name]
                    semantic=lambda r:{k:v for k,v in r.items() if k not in ['clockCalls','phases']}
                    projected.append({'mode':mode,'case':name,'sameResultSourcesProofAndAX':semantic(b)==semantic(c),'samePhases':b['phases']==c['phases'],'axCalls':len(c['axEvents']),'axOrderSHA256':hashlib.sha256(json.dumps(c['axEvents']).encode()).hexdigest(),'parseClockCalls':c['clockCalls'],'recollections':c['recollections'],'notes':c['notes'],'returned':len(c['messages'])})
            Path(report).write_text(json.dumps({'executions':sum(len(r) for r in cls.runs.values()),'cases':projected,'renderedLines':[m[0] if m else 'INVALID' for m in cls.diagnostics['candidate','on']],'helper':cls.helper},indent=2)+'\n')

    def test_frozen_v11_result_source_authority_and_all_ax_order_preserved(self):
        for mode in ['off','on']:
            for case,b in self.runs['baseline',mode].items():
                with self.subTest(mode=mode,case=case):
                    c=self.runs['candidate',mode][case]
                    for key in ['messages','calls','axEvents','sourceRefs','notes','recollections','freshSourcesDistinct','freshCachesDistinct','order','multiplicity','phases']:
                        self.assertEqual(c[key],b[key],key)

    def test_off_has_no_clock_or_cost_output(self):
        self.assertEqual(self.diagnostics['candidate','off'],[])
        self.assertTrue(all(r['clockCalls']==0 for r in self.runs['candidate','off'].values()))
        self.assertTrue(all(r['clockCalls']==0 for r in self.runs['baseline','on'].values()))

    def test_on_returns_same_as_off_including_ax_identity_reads(self):
        for case,off in self.runs['candidate','off'].items():
            on=self.runs['candidate','on'][case]
            for key in ['messages','sourceRefs','notes','calls','axEvents','recollections']:
                self.assertEqual(off[key],on[key],(case,key))
            self.assertGreater(on['clockCalls'],0)

    def test_wire_is_bounded_closed_numeric_and_one_per_extraction(self):
        rows=self.diagnostics['candidate','on']
        self.assertEqual(len(rows),len(self.runs['candidate','on']))
        for m in rows:
            self.assertIsNotNone(m)
            self.assertLessEqual(len(m[0].encode()),500)
            ms=list(map(int,m[3].split('/')));counts=list(map(int,m[4].split('/')))
            self.assertEqual(counts[1],sum(counts[2:6]))
            self.assertAlmostEqual(float(m[1]),(ms[1]+ms[-1])/1000,places=3)
            self.assertLessEqual(ms[2],ms[1])
            self.assertLessEqual(sum(ms[3:10]),ms[2])
            self.assertEqual(m[5],'0')
        self.assertNotIn('CUSTOMER_SECRET_SENTINEL','\n'.join(self.logs['candidate','on']))

    def test_discarded_and_retained_retry_costs_are_not_overwritten(self):
        counts=[list(map(int,m[4].split('/'))) for m in self.diagnostics['candidate','on']]
        self.assertTrue(any(v[1]==2 and v[3]==1 for v in counts)) # fresh sparse
        self.assertTrue(any(v[1]==2 and v[4]==1 for v in counts)) # held sparse
        self.assertTrue(any(v[1]==2 and v[5]==1 for v in counts)) # attribution
        self.assertTrue(any(v[-1]==1 for v in counts)) # flat fallback retained separately
        passes={int(m[2]) for m in self.diagnostics['candidate','on']}
        # Sparse attempts retaining <threshold messages always proceed into
        # flat fallback, so selected provenance becomes6, not3/4. Their
        # attempts remain in the held/fresh counters above.
        self.assertTrue({1,2,5,6}.issubset(passes))

    def test_emits_before_evidence_and_keeps_existing_pair_adjacent(self):
        lines=self.logs['candidate','on']
        parse_positions=[i for i,l in enumerate(lines) if l.startswith('[kmsg] parse-cost ')]
        for i in parse_positions:
            following=lines[i+1:]
            detail=next(j for j,l in enumerate(following) if l.startswith('[kmsg] read-detail '))
            evidence=[l for l in following[:detail] if l.startswith('[kmsg] read-evidence ')]
            self.assertIn(len(evidence),[0,2])
            if evidence:
                self.assertEqual(following[detail-2:detail],evidence)
                self.assertIn('part=1',evidence[0]);self.assertIn('part=2',evidence[1])

    def test_saturation_backwards_clock_once_and_sink_failure_are_diagnostic_only(self):
        self.assertEqual(len(self.helper['lines']),1)
        saturated=LINE.fullmatch(self.helper['lines'][0]);self.assertIsNotNone(saturated)
        self.assertEqual(saturated[5],'1');self.assertLessEqual(len(saturated[0].encode()),500)
        backwards=LINE.fullmatch(self.helper['backwards']);self.assertIsNotNone(backwards)
        self.assertEqual(backwards[1],'0.000');self.assertEqual(backwards[2],'0')
        self.assertTrue(self.helper['closedSinkReturned'])

if __name__=='__main__':unittest.main()

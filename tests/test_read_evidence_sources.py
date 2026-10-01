"""Production row/collection semantics and single-read identifier types.

All AX objects are synthetic. No app, GUI, network, or customer input is used.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_auth_ack_structure_scope import block
from test_native_observation import production_harness

ROOT=Path(__file__).resolve().parents[1]
NATIVE=ROOT/'Sources/kmsg/KakaoTalk'
SCENARIOS=['message-last','empty-last','cell-empty-last','time-last','date-last',
           'last-legacy-repeat','fresh-empty-last','identifier-failure-last','row-children-incomplete']

IDENTIFIER_STUB=r'''
import Foundation
import ApplicationServices.HIServices
enum AccessibilityError:Error { case axError(AXError), typeMismatch }
enum ReadKind { case scalar }
struct AuthReadDiagnostics {
    static let current:AuthReadDiagnostics? = nil
    func beginRead(_ kind:ReadKind)->Int {0}
    func endRead(_ started:Int,failed:Bool) {}
}
struct SearchDiscoveryDiagnostics {
    static let currentPass:SearchDiscoveryDiagnostics? = nil
    func beginRead()->Int {0}
    func endRead(_ started:Int,batch:Bool,error:AXError) {}
    func recordScalar(element:AXUIElement,name:String,error:AXError,raw:CFTypeRef?) {}
}
final class Node:NSObject {
    let value:CFTypeRef?,error:AXError
    init(_ value:CFTypeRef?,_ error:AXError = .success) {self.value=value;self.error=error}
}
typealias AXUIElement=Node
var calls=0
func AXUIElementCopyAttributeValue(_ element:Node,_ key:CFString,_ out:UnsafeMutablePointer<CFTypeRef?>)->AXError {
    calls+=1;out.pointee=element.value;return element.error
}
struct UIElement {
    let axElement:Node
    init(_ node:Node) {axElement=node}
// ATTRIBUTE
}
'''
IDENTIFIER_CASES=r'''
var geometry=CGPoint.zero
let cases:[(String,Node,Int)] = [
    ("string",Node("PRIVATE_ID_SENTINEL" as NSString),0),
    ("number",Node(NSNumber(value:42)),3),
    ("boolean",Node(kCFBooleanTrue),4),
    ("null",Node(kCFNull),5),
    ("array",Node(["PRIVATE_ID_SENTINEL"] as NSArray),6),
    ("dictionary",Node(["key":"PRIVATE_ID_SENTINEL"] as NSDictionary),7),
    ("data",Node(Data([1,2,3]) as NSData),8),
    ("date",Node(Date(timeIntervalSince1970:0) as NSDate),9),
    ("ax-value",Node(AXValueCreate(.cgPoint,&geometry)),10),
    ("success-nil",Node(nil),5),
    ("no-value",Node(nil,.noValue),2),
    ("unsupported",Node(nil,.attributeUnsupported),1),
    ("not-implemented",Node(nil,.notImplemented),1),
    ("cannot-complete",Node(nil,.cannotComplete),12),
    ("invalid-element",Node(nil,.invalidUIElement),13),
    ("api-disabled",Node(nil,.apiDisabled),14),
    ("illegal-argument",Node(nil,.illegalArgument),15),
    ("failure",Node(nil,.failure),16),
    ("other-ax-error",Node(nil,.notificationUnsupported),17),
    ("other-type",Node(CFUUIDCreate(nil)),11),
    ("oversized",Node(String(repeating:"x",count:600) as NSString),19)]
var output:[[String:Any]]=[]
for (name,node,expected) in cases {
    let source=TranscriptObservationSources(),element=UIElement(node)
    let id=source.identity(of:element),before=calls
    let result=source.readIdentifier(id)
    precondition(result.status.rawValue==expected && calls-before==1)
    output.append(["case":name,"status":result.status.rawValue,"calls":calls-before])
}
let invalid=TranscriptObservationSources(),before=calls
precondition(invalid.readIdentifier(999).status == .unexpectedFailure && calls==before)

var lines:[String]=[]
let diagnostics=TranscriptReadEvidenceDiagnostics()
TranscriptReadEvidenceDiagnostics.emit(snapshot:diagnostics.snapshot(),pass:1,
    sources:(0..<3).map{(row:$0*2,body:$0*2+1)},lastRowSourcePresent:true,lastBodySourcePresent:true,
    lastCollectedRowCompared:true,lastCollectedRowMatches:true,
    readIdentifier:{ $0%2==0 ? .noValue : .classified(.number) },write:{lines.append($0)})

var huge=diagnostics.snapshot(),hugeLines:[String]=[]
huge.collection=Array(repeating:Int.max,count:11);huge.help=Array(repeating:Int.max,count:7)
huge.helpNanos=UInt64.max
TranscriptReadEvidenceDiagnostics.emit(snapshot:huge,pass:6,
    sources:[],lastRowSourcePresent:false,lastBodySourcePresent:false,
    lastCollectedRowCompared:false,lastCollectedRowMatches:false,
    readIdentifier:{_ in .failed},write:{hugeLines.append($0)})
let data:[String:Any] = ["cases":output,"invalidIndexCalls":calls-before,
    "classifiedLines":lines,"saturationLines":hugeLines,
    "unvisited":huge.lastRowDisposition.rawValue]
diagnostics.recordLastRowAnalysis(childrenComplete:false)
let unknown=diagnostics.snapshot()
precondition(unknown.lastRowDisposition == .unknown && unknown.lastRowChildrenState==2)
diagnostics.recordLastRowDisposition(.noBody)
diagnostics.resetParsing()
precondition(diagnostics.snapshot().lastRowDisposition == .unvisited
             && diagnostics.snapshot().lastRowChildrenState==0)
print(String(data:try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys]),encoding:.utf8)!)
'''

def tuple_at(line,key):
    return list(map(int,line.split(key+'=',1)[1].split()[0].split('/')))

@unittest.skipIf(shutil.which('swiftc') is None,'swiftc not available')
class ReadEvidenceSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder=tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.folder.cleanup)
        directory=Path(cls.folder.name)
        sdk=[]
        if sys.platform=='darwin' and not os.environ.get('SDKROOT'):
            path=subprocess.run(['xcrun','--sdk','macosx','--show-sdk-path'],capture_output=True,text=True,check=True).stdout.strip()
            sdk=['-sdk',path]
        reader=(NATIVE/'TranscriptReader.swift').read_text()
        collection=reader[reader.index('    private func collectTranscriptRows('):reader.index('    private func extractMessages(')]
        program=production_harness(reader).replace('struct Parser {\n let runner = Runner()\n',
            'struct Parser {\n let runner = Runner()\n'+collection.replace('private ',''))
        # Track the same ordinary fake AX boundary across ON/OFF. Identifier
        # probes are counted separately; their values never enter this trace.
        program=program.replace('final class UIElement {','final class UIElement {\n    static var nextProbeID=0, readEvents:[String]=[]\n    let probeID:Int')
        program=program.replace('self.role = role;', 'Self.nextProbeID+=1;probeID=Self.nextProbeID;self.role = role;')
        program=program.replace('frameReads += 1;', 'Self.readEvents.append("frame:\\(probeID)"); frameReads += 1;')
        program=program.replace('childReads += 1;', 'Self.readEvents.append("children:\\(probeID)"); childReads += 1;')
        program=program.replace('searches += 1', 'Self.readEvents.append("search:\\(probeID)"); searches += 1')
        program=program.replace('attributeReads += 1', 'if name != kAXIdentifierAttribute {Self.readEvents.append("attribute:\\(probeID)")}; attributeReads += 1')
        cases=(ROOT/'tests/fixtures/read_evidence_sources.swift').read_text()
        cases=cases.replace('"ordinaryCalls":ordinaryCounts(root)', '"ordinaryCalls":ordinaryCounts(root),"ordinaryOrder":UIElement.readEvents')
        context=(NATIVE/'MessageContextResolver.swift').read_text()
        cost=context[:context.index('struct MessageTranscriptContext')]
        helpers=[NATIVE/f'{name}.swift' for name in ['TranscriptAuthorEvidence','TranscriptRightEdgeAlignment',
            'TranscriptAttributionRecovery','TranscriptNativeObservation','TranscriptReadEvidenceDiagnostics']]

        def compile_run(source,name,extra,arguments):
            main=directory/'main.swift';main.write_text(source)
            binary=directory/name
            built=subprocess.run(['swiftc',*sdk,*map(str,extra),str(main),'-o',str(binary)],capture_output=True,text=True)
            if built.returncode:raise AssertionError(built.stderr)
            results=[]
            for args in arguments:
                run=subprocess.run([str(binary),*args],capture_output=True,text=True)
                if run.returncode:raise AssertionError(run.stdout+run.stderr)
                results.append((json.loads(run.stdout),run.stderr))
            return results

        cls.rows={}
        row_runs=compile_run(program+'\n'+cost+'\n'+cases,'rows',helpers,
            [(case,on) for case in SCENARIOS for on in ['false','true']])
        for (case,on),(data,stderr) in zip([(c,o) for c in SCENARIOS for o in ['false','true']],row_runs):
            cls.rows[case,on]=(data,stderr)
        ui=(ROOT/'Sources/kmsg/Accessibility/UIElement.swift').read_text()
        attribute=block(ui,ui.index('    public func attribute<T>('))
        sources=reader[reader.index('private final class TranscriptObservationSources {'):].replace('private ','')
        cls.ident,cls.ident_stderr=compile_run(IDENTIFIER_STUB.replace('// ATTRIBUTE',attribute)+sources+IDENTIFIER_CASES,
            'identifiers',[NATIVE/'TranscriptReadEvidenceDiagnostics.swift'],[()])[0]
        artifact=os.environ.get('KMSG_READ_EVIDENCE_SOURCE_REPORT')
        if artifact:
            rows=[]
            for case in SCENARIOS:
                off,on=cls.rows[case,'false'],cls.rows[case,'true']
                rows.append({'case':case,'sameMessagesAndProof':off[0]['semanticDigest']==on[0]['semanticDigest'],
                    'sameOrdinaryAXOrder':off[0]['ordinaryOrder']==on[0]['ordinaryOrder'],
                    'offIdentifierCalls':off[0]['identifierCalls'],'onIdentifierCalls':on[0]['identifierCalls'],
                    'returned':on[0]['returned'],'order':on[0]['order'],'diagnostics':on[1].splitlines()})
            Path(artifact).write_text(json.dumps({'rows':rows,'identifiers':cls.ident},indent=2)+'\n')

    def test_actual_collection_and_parser_same_messages_proof_and_ordinary_ax_order(self):
        for case in SCENARIOS:
            off,stderr_off=self.rows[case,'false'];on,stderr_on=self.rows[case,'true']
            with self.subTest(case=case):
                self.assertEqual(off['semanticDigest'],on['semanticDigest'])
                self.assertEqual(off['ordinaryCalls'],on['ordinaryCalls'])
                self.assertEqual(off['ordinaryOrder'],on['ordinaryOrder'])
                self.assertEqual(off['identifierCalls'],0)
                self.assertEqual(on['identifierCalls'],6)
                self.assertEqual(stderr_off,'')
                self.assertEqual(len(stderr_on.splitlines()),2)

    def test_collection_tail_disposition_is_not_conversation_end(self):
        for case in SCENARIOS:
            data,stderr=self.rows[case,'true'];end=tuple_at(stderr.splitlines()[0],'end')
            self.assertEqual(end[1:12],[52,52,52,52,0,0,0,0,0,0,0])
            self.assertEqual(end[16],0)
            if case in ['message-last','identifier-failure-last']:
                self.assertEqual(end[15:],[1,0,4,1,1])
            elif case in ['empty-last','cell-empty-last','time-last','fresh-empty-last']:
                self.assertEqual(end[15:],[0,0,2,1,3])
                self.assertEqual(data['order'],'verified')
            elif case=='date-last':self.assertEqual(end[15:],[0,0,3,1,3])
            elif case=='last-legacy-repeat':
                self.assertEqual(end[15:],[0,0,4,1,3])
                self.assertEqual(data['order'],'uncertain')
            elif case=='row-children-incomplete':self.assertEqual(end[15:],[0,0,2,2,3])

    def test_current_attribute_generic_and_probe_classify_without_another_ax_read(self):
        self.assertEqual(len(self.ident['cases']),21)
        self.assertTrue(all(row['calls']==1 for row in self.ident['cases']))
        self.assertEqual(self.ident['invalidIndexCalls'],0)
        by={r['case']:r['status'] for r in self.ident['cases']}
        self.assertEqual(by['success-nil'],by['null'])
        self.assertEqual(by['number'],3)
        self.assertEqual(by['cannot-complete'],12)
        self.assertEqual(by['invalid-element'],13)

    def test_row_and_body_statuses_disambiguate_the_old_three_plus_three_failure(self):
        first,second=self.ident['classifiedLines']
        ident=tuple_at(second,'ident');statuses=tuple_at(second,'idstat')
        self.assertEqual(ident[1],6)
        self.assertEqual(ident[3],0);self.assertEqual(ident[6],0)
        self.assertEqual(ident[9:11],[3,3])
        self.assertEqual(statuses[1:21],[0,0,3]+[0]*17)
        self.assertEqual(statuses[21:],[0,0,0,3]+[0]*16)

    def test_unvisited_and_saturation_are_explicit_and_all_lines_fit(self):
        self.assertEqual(self.ident['unvisited'],0)
        lines=self.ident['saturationLines']
        self.assertTrue(all(len(line)<500 for line in lines))
        self.assertEqual(tuple_at(lines[0],'end')[17:],[0,0,0])
        # Even impossible simultaneous maximum counters fit the fixed schema.
        def saturated(count):return '/'.join(['2']+['99999']*count)
        maximum=('\n'.join([
            '[kmsg] read-evidence total=199.998 status=ok part=1 schema=2 pass=6 help='+saturated(8)+' end='+saturated(19),
            '[kmsg] read-evidence total=199.998 status=ok part=2 schema=2 ident='+saturated(19)+' idstat='+saturated(40)]))
        self.assertTrue(all(len(line)<500 for line in maximum.splitlines()))
        output=json.dumps(self.ident)
        self.assertNotIn('PRIVATE_ID_SENTINEL',output)
        self.assertEqual(self.ident_stderr,'')

if __name__=='__main__':unittest.main()

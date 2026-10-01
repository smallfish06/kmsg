"""Metadata-only auth diagnostics against frozen production AX decoders/scope.

Only the IPC functions are fake. AXValue error slots use Apple's real local
encoding; no application AX element or native command is created.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

from test_auth_ack_structure_scope import block, swiftc_command

ROOT = Path(__file__).resolve().parents[1]
READ = ROOT / 'Sources/kmsg/Auth/AuthReadDiagnostics.swift'
UI = ROOT / 'Sources/kmsg/Accessibility/UIElement.swift'
SCOPE = ROOT / 'Sources/kmsg/Accessibility/AXTraversalReadScope.swift'
PHASE = ROOT / 'Sources/kmsg/Auth/AuthPhaseDiagnostics.swift'
REFERENCE = ROOT / 'tests/fixtures/auth_structure_decoder_reference.swift'
SCOPE_REFERENCE = ROOT / 'tests/fixtures/auth_scope_reference.swift'

STUB = r'''
import Foundation
import ApplicationServices.HIServices
public final class Node: NSObject {
    var role: String? = "group"
    var children: [Node] = []
    var incomplete = false
}
public typealias AXUIElement = Node
enum AccessibilityError: Error { case axError(AXError), typeMismatch }
var scenario = "empty", ipc: [String] = [], ticks: UInt64 = 0, clockCalls = 0
func fakeNow() -> UInt64 { clockCalls += 1; ticks += 10_000_000; return ticks }
func errorValue(_ error: AXError) -> AnyObject { var value = error; return AXValueCreate(.axError, &value)! }
func AXUIElementCopyAttributeValue(_ node: Node, _ name: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    let key = name as String
    ipc.append("scalar:" + key)
    if key == kAXChildrenAttribute {
        if node.incomplete { return .cannotComplete }
        value.pointee = node.children as CFArray
    } else if key == kAXRoleAttribute {
        if let role = node.role { value.pointee = role as CFString } else { return .noValue }
    } else if key == kAXTitleAttribute {
        if scenario == "scalar-error" { return .cannotComplete }
        value.pointee = "PRIVATE body name token" as CFString
    } else { return .attributeUnsupported }
    return .success
}
func AXUIElementCopyMultipleAttributeValues(_ node: Node, _ names: CFArray,
    _ options: AXCopyMultipleAttributeOptions, _ value: UnsafeMutablePointer<CFArray?>) -> AXError {
    let labels = names as! [String]
    ipc.append("batch:" + labels.joined(separator: ","))
    if scenario == "batch-cannot-complete" { return .cannotComplete }
    if scenario == "nil-success-array" { return .success }
    if scenario == "wrong-count" { value.pointee = ["PRIVATE"] as CFArray; return .success }
    if labels != [kAXRoleAttribute, kAXChildrenAttribute] {
        value.pointee = ["PRIVATE body" as NSString, errorValue(.attributeUnsupported),
                        errorValue(.cannotComplete), NSNull()] as CFArray
        return .success
    }
    var role: AnyObject = node.role.map { $0 as NSString } ?? NSNull()
    var children: AnyObject = node.incomplete ? errorValue(.cannotComplete) : node.children as NSArray
    switch scenario {
    case "one-child": children = [Node()] as NSArray
    case "unsupported": children = errorValue(.attributeUnsupported)
    case "no-value": children = errorValue(.noValue)
    case "cannot-complete": children = errorValue(.cannotComplete)
    case "invalid-element": children = errorValue(.invalidUIElement)
    case "null": children = NSNull()
    case "wrong-type": children = "PRIVATE customer body" as NSString
    case "mixed-array": children = [Node(), "PRIVATE"] as NSArray
    case "nonerror-axvalue": var point = CGPoint.zero; children = AXValueCreate(.cgPoint, &point)!
    case "role-unsupported": role = errorValue(.attributeUnsupported)
    case "role-null": role = NSNull()
    case "role-wrong-type": role = NSNumber(value: 7)
    case "bad-role-valid-child": role = errorValue(.cannotComplete); children = [Node()] as NSArray
    default: break
    }
    value.pointee = [role, children] as CFArray
    return .success
}
public final class UIElement {
    public let axElement: Node
    public init(_ element: Node) { axElement = element }
// UI_METHODS
}
func saveScope(_ scope: AXTraversalReadScope) {
// RECORD_SCOPE
}
func numbers(_ lines: [String], _ kind: String) -> [String: String] {
    guard let line = lines.first(where: { $0.hasPrefix("[kmsg] auth-" + kind + " ") }) else { return [:] }
    return Dictionary(uniqueKeysWithValues: line.split(separator: " ").dropFirst(2).map {
        let p = $0.split(separator: "=", maxSplits: 1); return (String(p[0]), String(p[1]))
    })
}
let cases = ["empty", "one-child", "unsupported", "no-value", "cannot-complete", "invalid-element",
             "null", "wrong-type", "mixed-array", "nonerror-axvalue", "role-unsupported", "role-null",
             "role-wrong-type", "bad-role-valid-child", "batch-cannot-complete", "nil-success-array",
             "wrong-count", "scalar-error"]
var rows: [[String: Any]] = []
for name in cases { for enabled in [false, true] {
    scenario = name; ipc = []; ticks = 0; clockCalls = 0
    let diagnostics = enabled ? AuthReadDiagnostics(now: fakeNow) : nil
    let previous = AuthReadDiagnostics.install(diagnostics)
    _ = diagnostics?.enterPhase("dismiss")
    let element = UIElement(Node())
    var observedAbsence = false
    // READ_STRUCTURE
    let strings = element.optionalStringAttributesRead([kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute])
    let scalar: String? = element.attributeOptional(kAXTitleAttribute)
    rows.append(["case": name, "enabled": enabled, "rolePresent": result.role != nil,
                 "children": result.children.count, "complete": result.complete,
                 "stringsPresent": strings.values.map { $0 != nil }, "fallback": strings.scalarFallbackIndices,
                 "scalarPresent": scalar != nil, "ipc": ipc, "clockCalls": clockCalls,
                 "observedAbsence": observedAbsence,
                 "lines": diagnostics?.lines(total: 1) ?? []])
    AuthReadDiagnostics.install(previous)
} }

var plans: [[String: Any]] = []
for name in ["reject", "activate", "unknown", "invalid-before-hits", "incomplete-root",
             "changed-root", "inconsistent-root", "uncertain-repeat", "limit", "validate-changed"] {
 for enabled in [false, true] {
    scenario = "graph"; ipc = []; ticks = 0; clockCalls = 0
    let diagnostics = enabled ? AuthReadDiagnostics(now: fakeNow) : nil
    let previous = AuthReadDiagnostics.install(diagnostics)
    _ = diagnostics?.enterPhase("dismiss")
    let root = Node(), leaves = (0..<3).map { _ in Node() }
    root.children = leaves
    let scope = AXTraversalReadScope(maxEntries: name == "limit" ? 0 : 4096)
    let wrapped = UIElement(root)
    _ = scope.children(atRoot: wrapped)
    var returned: [String] = []
    if name != "limit" {
        for leaf in leaves {
            if name == "unknown", leaf === leaves[0] { leaf.incomplete = true }
            let value = scope.roleAndChildren(of: UIElement(leaf))
            returned.append("\(value.role ?? "nil"):\(value.children.count)")
        }
    }
    switch name {
    case "invalid-before-hits": leaves[0].role = "changed"; _ = scope.roleAndChildren(of: UIElement(leaves[0]))
    case "incomplete-root": root.incomplete = true; _ = scope.children(atRoot: wrapped)
    case "changed-root": _ = scope.roleAndChildren(of: wrapped); root.children = []; _ = scope.children(atRoot: wrapped)
    case "inconsistent-root": root.children = []; _ = scope.children(atRoot: wrapped)
    case "uncertain-repeat": leaves[0].incomplete = true; _ = scope.roleAndChildren(of: UIElement(leaves[0]))
    default: break
    }
    let roots = name == "unknown" ? [wrapped, UIElement(Node()), wrapped] : [wrapped, wrapped, wrapped]
    scope.considerReuse(in: roots[...], roles: ["button"], roleLimits: ["button": 8],
                        maxNodes: 260, guardAXCost: name == "reject" ? 50 : 1)
    if name == "activate" || name == "validate-changed" {
        _ = scope.roleAndChildren(of: UIElement(leaves[0]))
        scope.considerReuse(in: roots[...], roles: ["button"], roleLimits: ["button": 8], maxNodes: 260, guardAXCost: 1)
    }
    if name == "validate-changed" { leaves[0].role = "changed" }
    let validation = scope.validateReusedStructure()
    let c = scope.counts
    scope.discard()
    saveScope(scope)
    plans.append(["case": name, "enabled": enabled, "returned": returned, "ipc": ipc,
                  "validation": validation.rawValue, "hits": c.hits, "active": c.activated,
                  "plans": c.admissionChecks, "clockCalls": clockCalls,
                  "lines": diagnostics?.lines(total: 1) ?? []])
    AuthReadDiagnostics.install(previous)
 } }

// DIAGNOSTIC_CHECKS
print(String(data: try JSONSerialization.data(withJSONObject: ["rows": rows, "plans": plans, "checks": checks],
        options: [.sortedKeys]), encoding: .utf8)!)
'''

CHECKS = r'''
var checks: [String: Any] = [:]
ticks = 0; clockCalls = 0
let outer = AuthReadDiagnostics(now: fakeNow)
let saved = AuthReadDiagnostics.install(outer)
let phase = AuthPhaseDiagnostics(now: fakeNow)
scenario = "empty"; ipc = []
phase.measure(.dismiss) {
    let element = UIElement(Node())
    _ = element.roleAndChildrenRead()
    phase.measure(.markers) { let _: String? = element.attributeOptional(kAXTitleAttribute) }
    phase.measure(.inputs) { _ = element.optionalStringAttributesRead([kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute]) }
    _ = element.roleAndChildrenRead()
}
let _: String? = UIElement(Node()).attributeOptional(kAXTitleAttribute)
checks["attribution"] = outer.lines(total: 1)
let inner = AuthReadDiagnostics(now: fakeNow)
enum FixtureError: Error { case failed }
func throwingScope() throws {
    let prior = AuthReadDiagnostics.install(inner)
    defer { AuthReadDiagnostics.install(prior) }
    throw FixtureError.failed
}
do { try throwingScope() } catch {}
checks["nestedRestored"] = AuthReadDiagnostics.current === outer
let semaphore = DispatchSemaphore(value: 0)
final class ResultBox: @unchecked Sendable { var isolated = false }
let box = ResultBox()
Thread.detachNewThread {
    box.isolated = AuthReadDiagnostics.current == nil
    semaphore.signal()
}
semaphore.wait()
checks["threadIsolated"] = box.isolated
AuthReadDiagnostics.install(saved)
checks["restored"] = AuthReadDiagnostics.current == nil
let bounded = AuthReadDiagnostics(now: fakeNow)
bounded.recordScope(invalid: .max, firstInvalidVisit: .max, skipMask: .max, rejects: .max,
    evaluatedPlans: 1,
    bestNet: .max, bestHits: .max, bestNodes: .max, bestGuard: .max,
    rootMissing: .max, unknownBreaks: .max, rootIncomplete: .max)
checks["bounded"] = bounded.lines(total: 86400)
checks["badTotal"] = bounded.lines(total: .infinity)
let merged = AuthReadDiagnostics(now: fakeNow)
func mergeScope(plans: Int, guardCost: Int) {
    merged.recordScope(invalid: 0, firstInvalidVisit: 0, skipMask: 0, rejects: plans,
        evaluatedPlans: plans, bestNet: 0, bestHits: plans * 3, bestNodes: plans * 3,
        bestGuard: guardCost, rootMissing: 0, unknownBreaks: 0, rootIncomplete: 0)
}
mergeScope(plans: 0, guardCost: 0)
mergeScope(plans: 1, guardCost: 50)
mergeScope(plans: 0, guardCost: 0)
checks["zeroPlanMerge"] = merged.lines(total: 1)
'''


def select_methods(source):
    names = ['attribute', 'attributeOptional', 'batchAttributes', 'optionalStringAttributesRead',
             'roleAndChildrenRead', 'childrenRead']
    selected = []
    for name in names:
        for match in re.finditer(r'    (?:public |private )?func ' + name + r'\b', source):
            selected.append((match.start(), block(source, match.start())))
    return '\n\n'.join(value for _, value in sorted(selected))


@unittest.skipIf(shutil.which('swiftc') is None, 'swiftc unavailable')
class AuthReadDiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='auth-read-diagnostics-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.results = {}
        for candidate in [False, True]:
            decoder = select_methods(UI.read_text()) if candidate else REFERENCE.read_text()
            scope = SCOPE.read_text() if candidate else SCOPE_REFERENCE.read_text()
            record = '''let c = scope.counts
    AuthReadDiagnostics.current?.recordScope(invalid: c.invalidMask, firstInvalidVisit: c.firstInvalidVisit,
        skipMask: c.skipMask, rejects: c.rejects, evaluatedPlans: c.admissionChecks,
        bestNet: c.bestNet, bestHits: c.bestHits,
        bestNodes: c.bestNodes, bestGuard: c.bestGuard, rootMissing: c.rootMissing,
        unknownBreaks: c.unknownBreaks, rootIncomplete: c.rootIncomplete)''' if candidate else ''
            source = READ.read_text() + '\n' + PHASE.read_text() + '\n' + scope + '\n' + STUB
            if candidate:
                source += '\n' + (ROOT / 'Sources/kmsg/Accessibility/AuthShadowPlanner.swift').read_text()
            source = source.replace('// READ_STRUCTURE',
                'let result = element.roleAndChildrenRead(observeAbsence: enabled ? { observedAbsence = $0 } : nil)'
                if candidate else 'let result = element.roleAndChildrenRead()')
            source = source.replace('// UI_METHODS', decoder).replace('// RECORD_SCOPE', record)
            source = source.replace('// DIAGNOSTIC_CHECKS', CHECKS if candidate else 'let checks: [String: Any] = [:]')
            path = Path(cls.tmp.name) / ('candidate.swift' if candidate else 'reference.swift')
            path.write_text(source)
            binary = path.with_suffix('')
            built = subprocess.run([*swiftc_command(), str(path), '-o', str(binary)], capture_output=True, text=True)
            if built.returncode:
                raise AssertionError(built.stderr)
            cls.results[candidate] = json.loads(subprocess.check_output([str(binary)], text=True))
        if report := os.environ.get('KMSG_AUTH_READ_DIAGNOSTICS_REPORT'):
            Path(report).write_text(json.dumps({'referenceSha256': hashlib.sha256(REFERENCE.read_bytes()).hexdigest(),
                'scopeReferenceSha256': hashlib.sha256(SCOPE_REFERENCE.read_bytes()).hexdigest(),
                'sourceSha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in [READ, UI, SCOPE, PHASE]},
                'systemAXInvoked': False, 'results': {str(k): v for k, v in cls.results.items()}}, indent=2) + '\n')

    def test_decoder_values_complete_and_ipc_order_equal_frozen_with_on_off(self):
        reference = {(r['case'], r['enabled']): r for r in self.results[False]['rows']}
        self.assertEqual(len(reference), 36)
        for row in self.results[True]['rows']:
            old = reference[row['case'], row['enabled']]
            for field in ['rolePresent', 'children', 'complete', 'stringsPresent', 'fallback', 'scalarPresent', 'ipc']:
                self.assertEqual(row[field], old[field], (row['case'], field))
            self.assertEqual(len(row['ipc']), 3)
            if not row['enabled']:
                self.assertEqual(row['clockCalls'], 0)
                self.assertEqual(row['lines'], [])

    def test_real_axerror_slot_types_are_distinguished_without_completeness_promotion(self):
        rows = {r['case']: r for r in self.results[True]['rows'] if r['enabled']}
        classes = {'unsupported': 'unsupported', 'no-value': 'noValue', 'cannot-complete': 'cannotComplete',
                   'invalid-element': 'otherAXError', 'null': 'null', 'wrong-type': 'wrongType',
                   'mixed-array': 'wrongType', 'nonerror-axvalue': 'wrongType',
                   'batch-cannot-complete': 'requestFailure', 'nil-success-array': 'malformed', 'wrong-count': 'malformed'}
        for name, expected in classes.items():
            shape = self.fields(rows[name]['lines'], 'shape')
            self.assertEqual(shape[expected], '1', name)
            self.assertEqual(shape['childrenMissing'], '1', name)
            self.assertFalse(rows[name]['complete'], name)
        for name, row in rows.items():
            self.assertEqual(row['observedAbsence'], name in ['unsupported', 'no-value'], name)
        row = rows['bad-role-valid-child']
        self.assertEqual(row['children'], 1)
        self.assertFalse(row['complete'])
        shape = self.fields(row['lines'], 'shape')
        self.assertEqual(shape['roleMissing'], '1')
        self.assertEqual(shape['childrenMissing'], '0')

    @staticmethod
    def fields(lines, kind):
        line = next(line for line in lines if line.startswith('[kmsg] auth-' + kind + ' '))
        return dict(item.split('=', 1) for item in line.split()[2:])

    def test_scope_admission_and_validation_equal_frozen_including_errors_and_limits(self):
        reference = {(r['case'], r['enabled']): r for r in self.results[False]['plans']}
        self.assertEqual(len(reference), 20)
        for row in self.results[True]['plans']:
            for field in ['returned', 'ipc', 'validation', 'hits', 'active', 'plans']:
                self.assertEqual(row[field], reference[row['case'], row['enabled']][field], (row['case'], field))
            if not row['enabled']: self.assertEqual(row['clockCalls'], 0)

    def test_rejected_plan_and_hidden_pre_reuse_fault_are_visible(self):
        rows = {r['case']: r for r in self.results[True]['plans'] if r['enabled']}
        rejected = self.fields(rows['reject']['lines'], 'plan')
        self.assertEqual([rejected[k] for k in ['rejects','bestNet','bestHits','bestNodes','bestGuard']], ['1','6','9','3','50'])
        invalid = self.fields(rows['invalid-before-hits']['lines'], 'plan')
        self.assertEqual(rows['invalid-before-hits']['hits'], 0)
        self.assertEqual(invalid['invalid'], '8')
        self.assertEqual(invalid['firstInvalidVisit'], '4')
        self.assertEqual(invalid['skipMask'], '2')
        unknown = self.fields(rows['unknown']['lines'], 'plan')
        self.assertEqual(unknown['unknownBreaks'], '2')
        self.assertEqual(unknown['rootMissing'], '1')
        self.assertEqual(self.fields(rows['incomplete-root']['lines'], 'plan')['rootIncomplete'], '1')
        self.assertEqual(self.fields(rows['activate']['lines'], 'plan')['skipMask'], '1')
        self.assertEqual(self.fields(rows['limit']['lines'], 'plan')['invalid'], '1')
        self.assertEqual(self.fields(rows['validate-changed']['lines'], 'plan')['invalid'], '8')

    def test_existing_copy_calls_are_disjointly_attributed_and_thread_scope_restored(self):
        checks = self.results[True]['checks']
        for field in ['nestedRestored', 'threadIsolated', 'restored']: self.assertTrue(checks[field], field)
        io = self.fields(checks['attribution'], 'io')
        self.assertEqual(io['ack'], '0,2,0.020,0.010,0')
        self.assertEqual(io['marker'], '1,0,0.010,0.010,0')
        self.assertEqual(io['input'], '0,1,0.010,0.010,0')
        self.assertEqual(io['other'], '1,0,0.010,0.010,0')

    def test_zero_plan_scope_cannot_mask_a_later_rejected_zero_credit_plan(self):
        fields = self.fields(self.results[True]['checks']['zeroPlanMerge'], 'plan')
        self.assertEqual([fields[k] for k in ['bestNet', 'bestHits', 'bestNodes', 'bestGuard']],
                         ['0', '3', '3', '50'])

    def test_output_is_fixed_numeric_private_free_and_bounded(self):
        lines = [line for part in ['rows','plans'] for row in self.results[True][part] for line in row['lines']]
        lines += self.results[True]['checks']['bounded']
        for line in lines:
            self.assertLess(len(line.encode()), 500)
            self.assertNotIn('PRIVATE', line)
            self.assertRegex(line, r'^\[kmsg\] auth-(plan|shape|io) ')
            fields = dict(item.split('=', 1) for item in line.split()[2:])
            for key, value in fields.items():
                if key == 'status': self.assertEqual(value, 'done')
                else: self.assertRegex(value, r'^\d+(?:\.\d+)?(?:,\d+(?:\.\d+)?)*$')
        self.assertEqual(self.fields(self.results[True]['checks']['bounded'], 'plan')['clip'], '1')
        self.assertEqual(self.results[True]['checks']['badTotal'], [])


if __name__ == '__main__':
    unittest.main()

"""Run real authentication decisions against fixed fake AX, with timing ON/OFF."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

from test_auth_ack_structure_scope import block, swiftc_command

ROOT = Path(__file__).resolve().parents[1]

STUB = r'''
import Foundation
let kAXTextFieldRole = "field", kAXTextAreaRole = "area", kAXButtonRole = "button"
var trace: [String] = [], lines: [String] = [], clockReads = 0
var clock: UInt64 = 0
func now() -> UInt64 { clockReads += 1; clock += 1_000_000; return clock }
func fixtureSleep(forTimeInterval time: Double) { trace.append("sleep:\(time)") }
enum AuthenticationMode { case automaticIfNeeded, promptForFreshCredentials }
enum AuthenticationOutcome: String { case alreadyAuthenticated, loggedIn }
enum Failure: Error { case expected }
struct DecryptedCredentials { let identifier = "PRIVATE-CREDENTIAL"; let password = "PRIVATE-PASSWORD" }
struct LoginForm {}
struct UIElement {
    let id: String
    let titleText: String
    let roleText: String
    var title: String? { trace.append(id + ".title"); return titleText }
    var role: String? { trace.append(id + ".role"); return roleText }
    var isEnabled: Bool { trace.append(id + ".enabled"); return true }
    var axDescription: String? { trace.append(id + ".description"); return "PRIVATE-AX" }
    var identifier: String? { trace.append(id + ".identifier"); return "PRIVATE-ID" }
    func findAll(where predicate: (UIElement) -> Bool, limit: Int, maxNodes: Int) -> [UIElement] {
        trace.append("findAll.predicate.\(limit).\(maxNodes)")
        return Array(world.inputs.filter(predicate).prefix(limit))
    }
    func findAll(role: String, limit: Int, maxNodes: Int) -> [UIElement] {
        trace.append("findAll.role.\(limit).\(maxNodes)")
        return world.buttons
    }
}
final class World {
    var fresh = false, usable = true, ack = false, list = true, main = true
    var loggedIn = false, failStore = false, form = true, stored = true
    var title = "PRIVATE-WINDOW", marker = "PRIVATE-MARKER", password = false
    var inputs: [UIElement] = [], buttons: [UIElement] = []
    var window: UIElement { UIElement(id: "window", titleText: title, roleText: "window") }
}
var world = World()
enum AuthVerificationCache {
    static var isFresh: Bool { trace.append("cache.fresh"); return world.fresh }
    static func markVerified() { trace.append("cache.mark"); world.fresh = true }
}
final class KakaoTalkApp {
    var hasUsableWindow: Bool { trace.append("app.usable"); return world.usable }
    var chatListWindow: UIElement? { trace.append("app.list"); return world.list ? world.window : nil }
    func ensureWindowReopened(timeout: Double, trace: ((String) -> Void)?) -> UIElement? {
        record("app.reopen:\(timeout)"); return world.window
    }
    enum Mode { case fast }
    func ensureMainWindow(timeout: Double, mode: Mode, trace: ((String) -> Void)?) -> UIElement? {
        record("app.main:\(timeout)"); return world.main ? world.window : nil
    }
    func activate() { trace.append("app.activate") }
}
func record(_ value: String) { trace.append(value) }
final class AXActionRunner {
    func log(_ value: String) { /* Never export message text. */ }
    func pressEscapeKey() { trace.append("escape") }
}
final class CredentialStore {
    func storedIdentifier() -> String? { trace.append("store.identifier"); return nil }
    func loadCredentials() throws -> DecryptedCredentials? {
        trace.append("store.load"); if world.failStore { throw Failure.expected }
        return world.stored ? DecryptedCredentials() : nil
    }
    func save(identifier: String, password: String) throws { trace.append("store.save") }
}
// This state/phase fixture models field discovery as a supplied field list.
// The real fresh-pair BFS is exercised by test_auth_input_traversal.py.
enum AuthInputTraversal {
    static func find(in root: UIElement, limit: Int, maxNodes: Int) -> [UIElement] {
        root.findAll(where: { element in
            let role = element.role ?? ""
            guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == "AXSecureTextField" else { return false }
            return element.isEnabled
        }, limit: limit, maxNodes: maxNodes)
    }
}
enum PasswordPrompt {
    static func promptForCredentials(defaultIdentifier: String?) throws -> DecryptedCredentials {
        trace.append("prompt"); return DecryptedCredentials()
    }
}
final class Authenticator {
    let kakao = KakaoTalkApp(), runner = AXActionRunner()
    let phaseDiagnostics: AuthPhaseDiagnostics?
    let authDiagnostic: ((String) -> Void)? = { lines.append($0) }
    init(enabled: Bool) { phaseDiagnostics = enabled ? AuthPhaseDiagnostics(now: now) : nil }
    func emitAcknowledgementMetrics() { trace.append("ack.emit") }
    func dismissPostLoginAcknowledgementIfPresent() -> Bool { trace.append("ack.inspect"); return world.ack }
    func collectLoginMarkerText(from root: UIElement) -> String {
        trace.append("login.markers"); return world.loggedIn ? "ordinary" : world.marker
    }
    func containsLoginMarkers(_ text: String) -> Bool { text == "login-marker" }
    func normalizedText(_ text: String) -> String { text.lowercased() }
    func looksLikePasswordField(_ input: UIElement) -> Bool { trace.append("input.password"); return world.password }
    func findLoginForm() -> LoginForm? { trace.append("login.form"); return world.form ? LoginForm() : nil }
    func performBlindLogin(with credentials: DecryptedCredentials) throws { trace.append("login.blind") }
    func performLogin(with credentials: DecryptedCredentials, form: LoginForm) throws { trace.append("login.perform") }
// METHODS
    func run(_ mode: AuthenticationMode) throws -> AuthenticationOutcome {
        try ensureAuthenticated(using: CredentialStore(), mode: mode)
    }
}
'''

CASES = r'''
let names = ["cache", "cache-no-window", "logged-in", "ack", "title", "markers",
             "inputs", "button", "password", "main", "no-window", "store-error",
             "blind", "prompt", "prompt-login", "repeat"]
var output: [[String: Any]] = []
for name in names {
    for enabled in [false, true] {
        world = World(); trace = []; lines = []; clockReads = 0; clock = 0
        switch name {
        case "cache": world.fresh = true
        case "cache-no-window": world.fresh = true; world.usable = false
        case "ack": world.ack = true
        case "title": world.title = "Login"
        case "markers", "prompt-login": world.marker = "login-marker"
        case "inputs": world.inputs = (0..<2).map { UIElement(id: "input\($0)", titleText: "PRIVATE-INPUT", roleText: "field") }
        case "button": world.buttons = [UIElement(id: "button", titleText: "Login", roleText: "button")]
        case "password": world.inputs = [UIElement(id: "input", titleText: "PRIVATE-INPUT", roleText: "field")]; world.password = true
        case "main": world.list = false
        case "no-window": world.list = false; world.main = false
        case "store-error": world.ack = true; world.failStore = true
        case "blind": world.ack = true; world.form = false; world.stored = false
        default: break
        }
        let auth = Authenticator(enabled: enabled)
        var outcomes: [String] = []
        var scopeRestored: [Bool] = []
        let mode: AuthenticationMode = name.hasPrefix("prompt") ? .promptForFreshCredentials : .automaticIfNeeded
        for _ in 0..<(name == "repeat" ? 2 : 1) {
            let parentDiagnostics = AuthReadDiagnostics()
            let previousDiagnostics = AuthReadDiagnostics.install(parentDiagnostics)
            do { outcomes.append(try auth.run(mode).rawValue) }
            catch { outcomes.append("error") }
            scopeRestored.append(AuthReadDiagnostics.current === parentDiagnostics)
            AuthReadDiagnostics.install(previousDiagnostics)
        }
        output.append(["name": name, "enabled": enabled, "trace": trace,
                       "outcomes": outcomes, "lines": lines, "clockReads": clockReads,
                       "scopeRestored": scopeRestored])
    }
}
print(String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8)!)
'''


@unittest.skipIf(shutil.which('swiftc') is None, 'swiftc unavailable')
class AuthPhaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        folder = Path(cls.temp.name)
        helper = (ROOT / 'Sources/kmsg/Auth/AuthPhaseDiagnostics.swift').read_text()
        helper += '\n' + (ROOT / 'Sources/kmsg/Auth/AuthReadDiagnostics.swift').read_text()
        source = (ROOT / 'Sources/kmsg/Auth/KakaoTalkAuthenticator.swift').read_text()
        selected = []
        for name in ['ensureAuthenticated', 'isAuthenticated', 'isLikelyLoginWindow', 'authPhase']:
            match = re.search(r'    (?:private )?func ' + name + r'\b', source)
            selected.append(block(source, match.start()))
        variants = {'candidate': '\n'.join(selected),
                    'reference': (ROOT / 'tests/fixtures/auth_phase_reference.swift').read_text()}
        cls.results = {}
        for variant, methods in variants.items():
            main = folder / (variant + '.swift')
            main.write_text(helper + STUB.replace('// METHODS', methods.replace('Thread.sleep', 'fixtureSleep')) + CASES)
            binary = folder / variant
            built = subprocess.run([*swiftc_command(), str(main), '-o', str(binary)], capture_output=True, text=True)
            if built.returncode:
                raise AssertionError(built.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
            cls.results[variant] = json.loads(executed.stdout)

    def test_full_decisions_and_ax_action_order_match_v1_with_timing_on_and_off(self):
        reference = {(r['name'], r['enabled']): r for r in self.results['reference']}
        self.assertEqual(len(self.results['candidate']), 32)
        for candidate in self.results['candidate']:
            with self.subTest(name=candidate['name'], enabled=candidate['enabled']):
                original = reference[candidate['name'], candidate['enabled']]
                self.assertEqual(candidate['outcomes'], original['outcomes'])
                self.assertEqual(candidate['trace'], original['trace'])

    def test_off_has_no_clock_reads_or_output(self):
        for candidate in self.results['candidate']:
            if not candidate['enabled']:
                self.assertEqual(candidate['clockReads'], 0)
                self.assertEqual(candidate['lines'], [])

    def test_actual_ensure_restores_parent_scope_after_success_failure_and_cache_return(self):
        for candidate in self.results['candidate']:
            self.assertTrue(all(candidate['scopeRestored']), (candidate['name'], candidate['enabled']))

    def test_numeric_bounded_output_has_no_private_values(self):
        expected = {'total','cache','reopen','state','dismiss','list','main','login','title','markers',
                    'inputs','buttons','password','reset','status','schema','states','checks'}
        for candidate in self.results['candidate']:
            for line in candidate['lines']:
                self.assertLess(len(line.encode()), 500)
                self.assertNotIn('PRIVATE', line)
                if not line.startswith('[kmsg] auth-phase '):
                    self.assertRegex(line, r'^\[kmsg\] auth-(plan|shape|io) total=')
                    continue
                self.assertTrue(line.startswith('[kmsg] auth-phase total='))
                fields = dict(pair.split('=') for pair in line.split()[2:])
                self.assertEqual(set(fields), expected)
                self.assertEqual(fields['status'], 'done')
                for key, value in fields.items():
                    if key != 'status': self.assertRegex(value, r'^\d+(?:\.\d+)?$')

    def test_cached_calls_do_not_emit_or_reuse_previous_full_timing(self):
        candidate = {r['name']: r for r in self.results['candidate'] if r['enabled']}
        self.assertEqual(candidate['cache']['lines'], [])
        self.assertEqual(len(candidate['repeat']['lines']), 4)
        self.assertEqual([line.split()[1] for line in candidate['repeat']['lines']],
                         ['auth-plan', 'auth-shape', 'auth-io', 'auth-phase'])
        self.assertEqual(candidate['repeat']['outcomes'], ['alreadyAuthenticated', 'alreadyAuthenticated'])

    def test_failure_still_emits_and_nested_timing_is_not_reported_as_independent(self):
        candidate = next(r for r in self.results['candidate'] if r['enabled'] and r['name'] == 'store-error')
        self.assertEqual(candidate['outcomes'], ['error'])
        self.assertEqual(len(candidate['lines']), 4)
        fields = dict(pair.split('=') for pair in candidate['lines'][-1].split()[2:])
        self.assertGreater(float(fields['total']), float(fields['state']))
        self.assertGreater(float(fields['state']), float(fields['dismiss']))


if __name__ == '__main__':
    unittest.main()

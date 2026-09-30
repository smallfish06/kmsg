"""Execute the production confirmation loop with a simulated AX chat list.

A new chat may be below dozens of pinned rooms even after its opener was sent.
The fixture deliberately starts beyond the old 40-row horizon. No Kakao app,
customer account, keyboard event, or message send is involved in this test.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Sources/kmsg/KakaoTalk/KakaoContactAutomation.swift'

STUBS = r'''
import Foundation
struct UIElement { let title: String? = "카카오톡"; let identifier: String? = "Main Window" }
struct Discovery { let title: String; let lastMessage: String? }
struct Snapshot { let discovery: Discovery }
var rows: [Snapshot] = []
var scans: [Int] = []
var friends = false
struct ChatListScanner {
    func scan(in window: UIElement, limit: Int, trace: ((String) -> Void)?) -> [Snapshot] {
        scans.append(limit)
        return Array(rows.prefix(limit))
    }
    func looksLikeFriendsList(_ snapshots: [Snapshot], in window: UIElement, trace: ((String) -> Void)?) -> Bool { friends }
}
struct ChatTextNormalizer {
    static func normalizeForMatch(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}
enum Slot { case chatListContainer, chatRowTitle, chatRowPreview }
struct AXPathCacheStore {
    static let shared = Self()
    func clear(slots: [Slot]) throws {}
}
struct ChatIdentityRegistryStore {
    static let shared = Self()
    func assignChatIDs(for discoveries: [Discovery]) -> [String] { discoveries.indices.map { "id-\($0)" } }
}
enum KakaoTalkError: Error { case actionFailed(String) }
enum ContactAutomationFailureCode: String { case chatIdentityNotConfirmed = "CHAT_IDENTITY_NOT_CONFIRMED" }
struct Kakao { let chatListWindow: UIElement? = UIElement(); func activate() {} }
struct Runner { func pressCommandTwo() {}; func log(_ message: String) {} }
// Avoid real sleeps while leaving the production control flow unchanged.
enum Thread { static func sleep(forTimeInterval: Double) {} }
struct Automation {
    let kakao = Kakao()
    let runner = Runner()
'''

CASES = r'''
}
func row(_ title: String, _ preview: String = "unrelated") -> Snapshot {
    Snapshot(discovery: Discovery(title: title, lastMessage: preview))
}
func reset(_ count: Int) {
    rows = (0..<count).map { row("pinned-\($0)") }
    scans = []
    friends = false
}
func confirm() throws -> String {
    try Automation().confirmChatRow(chatTitle: "Customer(1234)", mainListWindow: UIElement()) { $0 == "hello" }
}
func check(_ ok: Bool, _ label: String) {
    if !ok { fatalError(label) }
}
func mustFail(_ label: String) {
    do { _ = try confirm(); fatalError(label) } catch {}
}
reset(170)
rows.append(row("Customer(1234)", "hello"))
check(try confirm() == "id-170", "room after 170 pinned chats")
check(scans == [40, 200], "widens after prefix miss")

reset(350)
rows.append(row("Customer(1234)", "hello"))
check(try confirm() == "id-350", "deep room")
check(scans == [40, 200, 500], "bounded deep retry")

reset(170)
rows.append(row("Customer(1234)", "customer already replied"))
check(try confirm() == "id-170", "preview replacement retains unique-title fallback")

reset(170)
rows.append(row("Customer(1234)", "hello"))
rows.append(row("Customer(1234)", "hello"))
mustFail("duplicate title and opener must fail")

reset(170)
rows.append(row("Customer(1234)", "unrelated room"))
rows.append(row("Customer(1234)", "hello"))
check(try confirm() == "id-171", "preview resolves title ambiguity")

reset(170)
rows.append(row("Customer(1234)", "reply one"))
rows.append(row("Customer(1234)", "reply two"))
mustFail("ambiguous titles cannot use fallback")

reset(520)
rows.append(row("Customer(1234)", "hello"))
mustFail("beyond bounded horizon remains unconfirmed")
check(scans == [40, 200, 500, 500], "bounded failure")

reset(5)
rows.append(row("Customer(1234)", "hello"))
friends = true
mustFail("friends tab must never confirm identity")
print("OK")
'''

@unittest.skipIf(shutil.which('swiftc') is None, 'swiftc not available')
class FriendIdentityDepthTests(unittest.TestCase):
    def test_production_confirmation_loop(self):
        source = SOURCE.read_text()
        method = source.split('    private func confirmChatRow(', 1)[1].split('    private func resolveExactChatMessageInput(', 1)[0]
        harness = STUBS + '    func confirmChatRow(' + method + CASES
        sdk_args = []
        if sys.platform == 'darwin' and not os.environ.get('SDKROOT'):
            sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True)
            if sdk.returncode == 0 and sdk.stdout.strip():
                sdk_args = ['-sdk', sdk.stdout.strip()]
        with tempfile.TemporaryDirectory() as tmp:
            main = Path(tmp) / 'main.swift'
            main.write_text(harness)
            binary = Path(tmp) / 'identitycheck'
            build = subprocess.run(['swiftc', *sdk_args, str(main), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout.strip(), 'OK')

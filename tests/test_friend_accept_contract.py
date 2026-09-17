import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
AUTOMATION = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "KakaoContactAutomation.swift"
COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "FriendCommand.swift"


class FriendAcceptContractTests(unittest.TestCase):
    """`kmsg friend accept`: the user added this account first and sent a connect code.

    2026-09-17 (talkfriend): KakaoTalk suspended a bridge account after it ran a
    burst of friend adds. The replacement flow never initiates a friend add — the
    user adds the account, sends a code in that room, and this command accepts
    them *inside that room*. The AX facts it relies on were measured on a live
    client the same day:

    * the profile is an AXPopover hanging off the chat header's 프로필 button, not
      a window (kAXWindows never lists it), and that button rejects AXPress;
    * a non-friend's popover has no 프로필 편집 pencil, only 친구 추가 / 차단;
    * 친구 추가's AXPress returns kAXErrorFailure (-25200) while succeeding;
    * renaming a friend retitles every untitled room they are in, so a title
      alone can match more than one chat-list row.
    """

    def setUp(self) -> None:
        self.source = AUTOMATION.read_text(encoding="utf-8")
        self.command = COMMAND.read_text(encoding="utf-8")

    def _body(self, start: str, end: str) -> str:
        return self.source.split(start, 1)[1].split(end, 1)[0]

    def test_code_is_verified_before_anything_is_touched(self) -> None:
        body = self._body("func acceptFriend(", "private static let profileDescription")
        verify = body.index("verifyConnectCode(connectCode, in: chatWindow)")
        self.assertLess(verify, body.index("openProfilePopover(in: chatWindow)"))
        self.assertLess(verify, body.index("addButton.press()"))
        self.assertLess(verify, body.index("renameFriend(to: newName"))

    def test_accept_never_enters_the_friend_add_search_ui(self) -> None:
        body = self._body("func acceptFriend(", "// ESC closes the friend-add popover")
        for forbidden in ("navigateToFriends(", "openFriendAddUI(", "triggerSearch(", "fillContactFields(", "selectKakaoIDMode("):
            self.assertNotIn(forbidden, body)

    def test_friend_add_is_judged_by_state_not_by_the_press_result(self) -> None:
        body = self._body("func acceptFriend(", "private static let profileDescription")
        # The press may throw on success, so it must not be a bare `try`.
        self.assertIn("do { try addButton.press() } catch", body)
        self.assertIn("profileButton(described: Self.profileEditDescription, in: profileRoot) != nil", body)

    def test_header_profile_button_is_a_direct_child_and_really_clicked(self) -> None:
        header = self._body("private func headerProfileButton(", "private func currentProfilePopover(")
        self.assertIn("chatWindow.children.first", header)
        opener = self._body("private func openProfilePopover(", "private func profileButton(")
        self.assertIn("runner.mouseClick(", opener)
        self.assertNotIn(".press()", opener)

    def test_rename_lookups_are_scoped_to_the_friend_info_dialog(self) -> None:
        body = self._body("private func renameFriend(", "private func cancelPopover(")
        self.assertIn("dialog.findFirst(maxDepth: 4, where: { $0.role == kAXTextAreaRole })", body)
        self.assertNotIn("chatWindow.findFirst", body)
        # AXValue only — no keyboard typing that could land in another input.
        self.assertIn("field.setAttribute(kAXValueAttribute", body)
        self.assertNotIn("typeText", body)
        self.assertNotIn("pressEnterKey", body)
        # Success is the retitled window, not the button press.
        self.assertIn("usableChatTitle(chatWindow.title) == newName", body)

    def test_row_is_confirmed_by_title_and_content_together(self) -> None:
        body = self._body("func acceptFriend(", "private static let profileDescription")
        self.assertIn("confirmChatIdentity(chatTitle: chatTitle, opener: message", body)
        self.assertIn("containsStandaloneCode: connectCode", body)
        row = self._body("private func confirmChatRow(", "// MARK: - Accept")
        self.assertIn("previewMatches(lastMessage)", row)
        self.assertIn("matches.count > 1", row)

    def test_command_closes_the_window_on_every_exit(self) -> None:
        body = self.command.split("struct FriendAcceptCommand", 1)[1]
        resolve = body.index("resolver.resolve(chatID: chatID)")
        close = body.index("resolver.closeWindow(resolution.window)")
        accept = body.index("automation.acceptFriend(")
        self.assertLess(resolve, close)
        self.assertLess(close, accept)  # registered in a defer before the work
        self.assertIn("defer {", body[resolve:accept])

    def test_command_rejects_names_over_the_kakaotalk_limit(self) -> None:
        body = self.command.split("struct FriendAcceptCommand", 1)[1]
        self.assertIn("trimmedName.count > 20", body)


if __name__ == "__main__":
    unittest.main()

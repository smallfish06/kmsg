import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
KMSG_ENTRYPOINT = REPO_ROOT / "Sources" / "kmsg" / "kmsg.swift"
FRIEND_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "FriendCommand.swift"
OPEN_PROFILE_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "OpenProfileCommand.swift"
CONTACT_AUTOMATION = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "KakaoContactAutomation.swift"
OPEN_PROFILE_AUTOMATION = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "KakaoOpenProfileAutomation.swift"


class FriendOpenProfileCommandContractTests(unittest.TestCase):
    def test_friend_and_open_profile_commands_are_registered(self) -> None:
        source = KMSG_ENTRYPOINT.read_text(encoding="utf-8")

        self.assertIn("FriendCommand.self", source)
        self.assertIn("OpenProfileCommand.self", source)
        self.assertNotIn("            ProfileCommand.self,", source)

    def test_friend_add_exposes_kakao_id_json_and_dry_run(self) -> None:
        source = FRIEND_COMMAND.read_text(encoding="utf-8")

        self.assertIn('commandName: "friend"', source)
        self.assertIn('commandName: "add"', source)
        self.assertIn("var kakaoID: String", source)
        self.assertIn("var message: String?", source)
        self.assertIn("var json: Bool = false", source)
        self.assertIn("var dryRun: Bool = false", source)
        self.assertIn('"external_chat_id"', source)
        self.assertIn("message: message?.trimmingCharacters", source)

    def test_open_profile_start_exposes_profile_url_message_json_and_dry_run(self) -> None:
        source = OPEN_PROFILE_COMMAND.read_text(encoding="utf-8")

        self.assertIn('commandName: "open-profile"', source)
        self.assertIn('commandName: "start"', source)
        self.assertIn("var profile: String", source)
        self.assertIn("var url: String", source)
        self.assertIn("var message: String?", source)
        self.assertIn("var json: Bool = false", source)
        self.assertIn("var dryRun: Bool = false", source)
        self.assertIn('"open_profile_url"', source)

    def test_contact_automation_has_actionable_failure_codes(self) -> None:
        source = CONTACT_AUTOMATION.read_text(encoding="utf-8")

        self.assertIn("FRIEND_ADD_UI_NOT_FOUND", source)
        self.assertIn("addFriend(kakaoID:", source)
        self.assertNotIn("assignMultiProfile(friend:", source)

    def test_friend_add_restores_and_raises_main_list_window_before_navigation(self) -> None:
        source = CONTACT_AUTOMATION.read_text(encoding="utf-8")

        restore = source.index("let rootWindow = try requireMainListWindow()")
        navigate = source.index("try navigateToFriends(in: rootWindow)")
        self.assertLess(restore, navigate)
        self.assertIn("runner.pressCommandTwo()", source)
        self.assertIn("listWindow = kakao.chatListWindow", source)
        self.assertIn("try window.performAction(kAXRaiseAction)", source)
        self.assertIn("KakaoTalkApp.forceOpen", source)
        self.assertIn("return kakao.chatListWindow ?? kakao.mainWindow", source)
        self.assertIn("findFriendAddButton(in: rootWindow) != nil", source)
        self.assertIn("guard let addButton = findFriendAddButton(in: rootWindow)", source)
        self.assertIn("runner.mouseClick(at:", source)

    def test_friend_add_opens_one_to_one_chat_before_returning(self) -> None:
        source = CONTACT_AUTOMATION.read_text(encoding="utf-8")

        resolve_name = source.index("let friendName = resolveFriendDisplayName")
        open_chat = source.index("let chatWindow = try openOneToOneChat")
        result = source.index("return KakaoFriendAddResult")
        self.assertLess(resolve_name, open_chat)
        self.assertLess(open_chat, result)
        self.assertIn('"CHAT_START_UI_NOT_FOUND"', source)
        self.assertIn('"CHAT_WINDOW_NOT_READY"', source)
        self.assertIn('bottomButton(in: resultRoot, matching: ["1:1 채팅", "1:1"])', source)
        self.assertIn('bottomButton(in: resultRoot, matching: ["친구 추가"])', source)
        self.assertIn("try pressFriendAddConfirmation(addButton)", source)
        self.assertIn("chatAction = existingFriendChat", source)
        self.assertIn("try pressOneToOneChat(chatAction)", source)
        self.assertIn("let windowsBeforeChatStart = kakao.windows", source)
        self.assertIn("let focusedWindowBeforeChatStart = kakao.focusedWindow", source)
        self.assertIn('label: "friend 1:1 chat ready attempt', source)
        self.assertIn("hasChatComposer(", source)
        self.assertIn("limit: 32, maxNodes: 800", source)
        self.assertIn("hasOneToOneChatAction(in: window)", source)
        self.assertIn("let structuralCandidate = isNewWindow && focusChanged && strongTitleMatch", source)
        self.assertIn("isStableStructuralChatWindow(", source)
        self.assertIn("guard hasComposer || structuralTransition", source)
        self.assertIn("role == kAXTextAreaRole || isMessageLabeled || customComposer", source)
        self.assertIn("friend composer candidates rejected:", source)
        self.assertIn("friend chat candidate title=", source)
        self.assertIn("let openedByThisClick = (isNewWindow || focusChanged) && titleMatches", source)
        self.assertIn("guard let chatTitle = usableChatTitle(chatWindow.title)", source)
        self.assertIn("retrying refreshed 1:1 chat action", source)
        self.assertIn("if openedChatWindow == nil", source)
        self.assertIn('tryRaiseWindow(openedChatWindow, label: "opened friend chat")', source)

    def test_friend_add_sends_optional_first_message_through_the_exact_opened_window(self) -> None:
        command = FRIEND_COMMAND.read_text(encoding="utf-8")
        source = CONTACT_AUTOMATION.read_text(encoding="utf-8")

        self.assertIn('help: "Send the first message in the 1:1 chat opened from Friends"', command)
        self.assertIn("func addFriend(kakaoID: String, message: String? = nil)", source)
        open_chat = source.index("let chatWindow = try openOneToOneChat")
        send_message = source.index("try sendFirstMessage(message, in: chatWindow)")
        result = source.index("return KakaoFriendAddResult")
        self.assertLess(open_chat, send_message)
        self.assertLess(send_message, result)

        self.assertIn("sameElement(focusedWindow, chatWindow)", source)
        self.assertIn("isSameOrDescendant(input, of: chatWindow)", source)
        self.assertIn("kakao.applicationElement.element(at: point)", source)
        self.assertIn("isSafeComposerFocusProbe(hit, at: point, in: chatWindow)", source)
        self.assertIn("runner.typeTextWithVerification(", source)
        self.assertIn('label: "friend first-message input"', source)
        self.assertIn("guard let currentValue = input.stringValue", source)
        self.assertIn("input.stringValue == message", source)
        self.assertIn("exactChatMessageInputHasFocus(input, in: chatWindow)", source)
        self.assertIn("runner.pressEnterKey()", source)
        send_confirmation = source[source.index('label: "friend first-message send reflected"'):]
        self.assertIn("return value.isEmpty", send_confirmation)
        self.assertNotIn("value.trimmingCharacters", send_confirmation[: send_confirmation.index("guard sent else")])
        self.assertIn("messageSendNotConfirmed", source)
        self.assertNotIn("typeTextWithVerification(message, on: nil", source)
        self.assertNotIn("ChatWindowResolver", source)

    def test_friend_add_confirms_a_unique_chat_identity_from_title_and_opener(self) -> None:
        source = CONTACT_AUTOMATION.read_text(encoding="utf-8")

        self.assertIn('case chatIdentityNotConfirmed = "CHAT_IDENTITY_NOT_CONFIRMED"', source)
        send_message = source.index("try sendFirstMessage(message, in: chatWindow)")
        confirm_identity = source.index("externalChatID = try confirmChatIdentity(")
        result = source.index("return KakaoFriendAddResult")
        self.assertLess(send_message, confirm_identity)
        self.assertLess(confirm_identity, result)
        self.assertIn("runner.pressCommandTwo()", source[confirm_identity:])
        self.assertIn("scanner.scan(in: listWindow, limit: 40", source)
        self.assertIn("ChatTextNormalizer.normalize(snapshot.discovery.title) == normalizedTitle", source)
        self.assertIn("ChatTextNormalizer.normalize(lastMessage) == normalizedOpener", source)
        self.assertIn("if matches.count > 1", source)
        self.assertIn("let assignedIDs = registry.assignChatIDs", source)
        self.assertIn("externalChatID: externalChatID", source)
        self.assertNotIn("externalChatID: nil", source)
        self.assertNotIn("usableChatTitle(chatWindow.title) ?? friendName", source)

    def test_open_profile_automation_has_actionable_failure_codes(self) -> None:
        source = OPEN_PROFILE_AUTOMATION.read_text(encoding="utf-8")

        self.assertIn("OPEN_PROFILE_URL_OPEN_FAILED", source)
        self.assertIn("OPEN_PROFILE_LAUNCH_URL_RESOLVE_FAILED", source)
        self.assertIn("OPEN_PROFILE_WINDOW_NOT_READY", source)
        self.assertIn("MESSAGE_INPUT_NOT_FOUND", source)
        self.assertIn("startOpenProfile(profile:", source)
        self.assertIn("let launchURL = try resolveLaunchURL(from: url)", source)
        self.assertIn("NSWorkspace.shared.open(launchURL)", source)
        self.assertIn("data-join-scheme", source)
        self.assertIn("URLSession.shared.dataTask", source)
        self.assertIn("let windowsBeforeOpen = kakao.windows", source)
        self.assertIn("existingWindows.contains", source)
        self.assertIn("!isExistingWindow && hasMessageInput", source)


if __name__ == "__main__":
    unittest.main()

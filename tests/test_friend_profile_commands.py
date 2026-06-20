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
        self.assertIn("var json: Bool = false", source)
        self.assertIn("var dryRun: Bool = false", source)
        self.assertIn('"external_chat_id"', source)

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

    def test_open_profile_automation_has_actionable_failure_codes(self) -> None:
        source = OPEN_PROFILE_AUTOMATION.read_text(encoding="utf-8")

        self.assertIn("OPEN_PROFILE_URL_OPEN_FAILED", source)
        self.assertIn("OPEN_PROFILE_WINDOW_NOT_READY", source)
        self.assertIn("MESSAGE_INPUT_NOT_FOUND", source)
        self.assertIn("startOpenProfile(profile:", source)


if __name__ == "__main__":
    unittest.main()

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
KMSG_ENTRYPOINT = REPO_ROOT / "Sources" / "kmsg" / "kmsg.swift"
FRIEND_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "FriendCommand.swift"
PROFILE_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ProfileCommand.swift"
CONTACT_AUTOMATION = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "KakaoContactAutomation.swift"


class FriendProfileCommandContractTests(unittest.TestCase):
    def test_friend_and_profile_commands_are_registered(self) -> None:
        source = KMSG_ENTRYPOINT.read_text(encoding="utf-8")

        self.assertIn("FriendCommand.self", source)
        self.assertIn("ProfileCommand.self", source)

    def test_friend_add_exposes_kakao_id_json_and_dry_run(self) -> None:
        source = FRIEND_COMMAND.read_text(encoding="utf-8")

        self.assertIn('commandName: "friend"', source)
        self.assertIn('commandName: "add"', source)
        self.assertIn("var kakaoID: String", source)
        self.assertIn("var json: Bool = false", source)
        self.assertIn("var dryRun: Bool = false", source)
        self.assertIn('"external_chat_id"', source)

    def test_profile_assign_exposes_friend_profile_json_and_dry_run(self) -> None:
        source = PROFILE_COMMAND.read_text(encoding="utf-8")

        self.assertIn('commandName: "profile"', source)
        self.assertIn('commandName: "assign"', source)
        self.assertIn("var friend: String", source)
        self.assertIn("var profile: String", source)
        self.assertIn("var json: Bool = false", source)
        self.assertIn("var dryRun: Bool = false", source)

    def test_contact_automation_has_actionable_failure_codes(self) -> None:
        source = CONTACT_AUTOMATION.read_text(encoding="utf-8")

        self.assertIn("FRIEND_ADD_UI_NOT_FOUND", source)
        self.assertIn("PROFILE_ASSIGN_UI_NOT_FOUND", source)
        self.assertIn("PROFILE_NOT_FOUND", source)
        self.assertIn("addFriend(kakaoID:", source)
        self.assertIn("assignMultiProfile(friend:", source)


if __name__ == "__main__":
    unittest.main()

import ArgumentParser
import Foundation

struct FriendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "friend",
        abstract: "Manage KakaoTalk friends",
        subcommands: [
            FriendAddCommand.self,
        ]
    )
}

struct FriendAddCommand: ParsableCommand {
    private struct JSONResponse: Codable {
        let ok: Bool
        let kakaoID: String
        let friendName: String
        let chatTitle: String
        let externalChatID: String?
        let dryRun: Bool

        enum CodingKeys: String, CodingKey {
            case ok
            case kakaoID = "kakao_id"
            case friendName = "friend_name"
            case chatTitle = "chat_title"
            case externalChatID = "external_chat_id"
            case dryRun = "dry_run"
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a KakaoTalk friend by KakaoTalk ID"
    )

    @Option(name: .long, help: "KakaoTalk ID to add")
    var kakaoID: String

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: .long, help: "Do not touch KakaoTalk; only print the planned result")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    func validate() throws {
        if kakaoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--kakao-id is required.")
        }
    }

    func run() throws {
        let normalizedID = kakaoID.trimmingCharacters(in: .whitespacesAndNewlines)
        if dryRun {
            try printResult(
                friendName: normalizedID,
                chatTitle: normalizedID,
                externalChatID: "dryrun:\(normalizedID)",
                dryRun: true
            )
            return
        }

        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        do {
            let automation = KakaoContactAutomation(kakao: kakao, runner: runner)
            let result = try automation.addFriend(kakaoID: normalizedID)
            try printResult(
                friendName: result.friendName,
                chatTitle: result.chatTitle,
                externalChatID: result.externalChatID,
                dryRun: false
            )
        } catch {
            if json {
                try printError(error)
            } else {
                print("Failed to add friend: \(error)")
            }
            throw ExitCode.failure
        }
    }

    private func printResult(friendName: String, chatTitle: String, externalChatID: String?, dryRun: Bool) throws {
        if json {
            let response = JSONResponse(
                ok: true,
                kakaoID: kakaoID,
                friendName: friendName,
                chatTitle: chatTitle,
                externalChatID: externalChatID,
                dryRun: dryRun
            )
            try printJSON(response)
            return
        }

        print("Friend ready: \(friendName)")
        print("Chat title: \(chatTitle)")
        if let externalChatID {
            print("External chat ID: \(externalChatID)")
        }
    }
}

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
        let method: String
        let kakaoID: String?
        let phone: String?
        let friendName: String
        let chatTitle: String
        let externalChatID: String?
        let dryRun: Bool

        enum CodingKeys: String, CodingKey {
            case ok
            case method
            case kakaoID = "kakao_id"
            case phone
            case friendName = "friend_name"
            case chatTitle = "chat_title"
            case externalChatID = "external_chat_id"
            case dryRun = "dry_run"
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a KakaoTalk friend by KakaoTalk ID or by contact (name + phone)"
    )

    @Option(name: .long, help: "KakaoTalk ID to add")
    var kakaoID: String?

    @Option(name: .long, help: "Phone number to add via the contact tab (requires --name)")
    var phone: String?

    @Option(name: .long, help: "Contact display name saved with --phone")
    var name: String?

    @Option(name: .long, help: "Send the first message in the 1:1 chat opened from Friends")
    var message: String?

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: .long, help: "Do not touch KakaoTalk; only print the planned result")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Fill the friend-add form, then dismiss without adding (UI smoke)")
    var probeUI: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    private var trimmedKakaoID: String? {
        guard let value = kakaoID?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private var normalizedPhone: String? {
        guard let value = phone else { return nil }
        // KakaoTalk's phone field only takes digits; tolerate dashes/spaces here.
        let digits = value.filter { $0.isNumber }
        return digits.isEmpty ? nil : digits
    }

    private var trimmedName: String? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    func validate() throws {
        switch (trimmedKakaoID, normalizedPhone) {
        case (nil, nil):
            throw ValidationError("Provide either --kakao-id or --phone.")
        case (.some, .some):
            throw ValidationError("--kakao-id and --phone are mutually exclusive.")
        case (nil, .some):
            if trimmedName == nil {
                throw ValidationError("--name is required when adding by --phone.")
            }
        case (.some, nil):
            break
        }
        if let message, message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--message must not be empty when provided.")
        }
    }

    private var target: FriendAddTarget {
        if let id = trimmedKakaoID {
            return .kakaoID(id)
        }
        return .contact(name: trimmedName ?? "", phone: normalizedPhone ?? "")
    }

    func run() throws {
        let target = self.target
        if dryRun {
            try printResult(
                friendName: target.displayName,
                chatTitle: target.displayName,
                externalChatID: "dryrun:\(target.identity)",
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
            let result = try automation.addFriend(
                target: target,
                message: message?.trimmingCharacters(in: .whitespacesAndNewlines),
                probeOnly: probeUI
            )
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
                method: trimmedKakaoID != nil ? "kakao_id" : "phone",
                kakaoID: trimmedKakaoID,
                phone: normalizedPhone,
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

import ArgumentParser
import Foundation

struct OpenProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open-profile",
        abstract: "Start KakaoTalk Open Profile chats",
        subcommands: [
            OpenProfileStartCommand.self,
        ]
    )
}

struct OpenProfileStartCommand: ParsableCommand {
    private struct JSONResponse: Codable {
        let ok: Bool
        let profile: String
        let openProfileURL: String
        let chatTitle: String
        let externalChatID: String
        let messageProvided: Bool
        let dryRun: Bool

        enum CodingKeys: String, CodingKey {
            case ok
            case profile
            case openProfileURL = "open_profile_url"
            case chatTitle = "chat_title"
            case externalChatID = "external_chat_id"
            case messageProvided = "message_provided"
            case dryRun = "dry_run"
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Open a KakaoTalk Open Profile URL and optionally send the first message"
    )

    @Option(name: .long, help: "Character or Open Profile display name")
    var profile: String

    @Option(name: .long, help: "KakaoTalk Open Profile URL, usually https://open.kakao.com/o/...")
    var url: String

    @Option(name: .long, help: "Optional first message to send after entering the Open Profile chat")
    var message: String?

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: .long, help: "Do not touch KakaoTalk; only print the planned result")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    func validate() throws {
        if profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--profile is required.")
        }
        _ = try parseOpenProfileURL(url)
        if let message, message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--message cannot be empty.")
        }
    }

    func run() throws {
        let normalizedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let openProfileURL = try parseOpenProfileURL(url)
        let normalizedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)

        if dryRun {
            try printResult(
                profile: normalizedProfile,
                url: openProfileURL,
                messageProvided: normalizedMessage != nil,
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
            let automation = KakaoOpenProfileAutomation(kakao: kakao, runner: runner)
            _ = try automation.startOpenProfile(
                profile: normalizedProfile,
                url: openProfileURL,
                message: normalizedMessage
            )
            try printResult(
                profile: normalizedProfile,
                url: openProfileURL,
                messageProvided: normalizedMessage != nil,
                dryRun: false
            )
        } catch {
            if json {
                try printError(error)
            } else {
                print("Failed to start Open Profile chat: \(error)")
            }
            throw ExitCode.failure
        }
    }

    private func printResult(profile: String, url: URL, messageProvided: Bool, dryRun: Bool) throws {
        let externalChatID = "open-profile:\(profile)"
        if json {
            try printJSON(JSONResponse(
                ok: true,
                profile: profile,
                openProfileURL: url.absoluteString,
                chatTitle: profile,
                externalChatID: externalChatID,
                messageProvided: messageProvided,
                dryRun: dryRun
            ))
            return
        }

        print("Open Profile ready: \(profile)")
        print("Open Profile URL: \(url.absoluteString)")
        print("Chat title: \(profile)")
        print("External chat ID: \(externalChatID)")
        if messageProvided {
            print(dryRun ? "Message: planned" : "Message: sent")
        }
    }
}

private func parseOpenProfileURL(_ rawValue: String) throws -> URL {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
        throw ValidationError("--url must be a valid KakaoTalk Open Profile URL.")
    }

    if scheme == "http" || scheme == "https" {
        let host = url.host?.lowercased() ?? ""
        guard host == "open.kakao.com" || host.hasSuffix(".open.kakao.com") else {
            throw ValidationError("--url must point to open.kakao.com or use a KakaoTalk deep-link scheme.")
        }
        return url
    }

    guard scheme.hasPrefix("kakao") else {
        throw ValidationError("--url must point to open.kakao.com or use a KakaoTalk deep-link scheme.")
    }
    return url
}

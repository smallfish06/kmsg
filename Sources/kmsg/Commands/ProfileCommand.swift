import ArgumentParser
import Foundation

struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Manage KakaoTalk friend profile settings",
        subcommands: [
            ProfileAssignCommand.self,
        ]
    )
}

struct ProfileAssignCommand: ParsableCommand {
    private struct JSONResponse: Codable {
        let ok: Bool
        let friend: String
        let profile: String
        let dryRun: Bool

        enum CodingKeys: String, CodingKey {
            case ok
            case friend
            case profile
            case dryRun = "dry_run"
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "assign",
        abstract: "Assign a KakaoTalk multi-profile to a friend"
    )

    @Option(name: .long, help: "Friend name or chat title")
    var friend: String

    @Option(name: .long, help: "KakaoTalk multi-profile name")
    var profile: String

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: .long, help: "Do not touch KakaoTalk; only print the planned result")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    func validate() throws {
        if friend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--friend is required.")
        }
        if profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--profile is required.")
        }
    }

    func run() throws {
        let normalizedFriend = friend.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if dryRun {
            try printResult(friend: normalizedFriend, profile: normalizedProfile, dryRun: true)
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
            try automation.assignMultiProfile(friend: normalizedFriend, profile: normalizedProfile)
            try printResult(friend: normalizedFriend, profile: normalizedProfile, dryRun: false)
        } catch {
            if json {
                try printError(error)
            } else {
                print("Failed to assign profile: \(error)")
            }
            throw ExitCode.failure
        }
    }

    private func printResult(friend: String, profile: String, dryRun: Bool) throws {
        if json {
            try printJSON(JSONResponse(ok: true, friend: friend, profile: profile, dryRun: dryRun))
            return
        }

        print("Profile assigned: \(profile) -> \(friend)")
    }
}

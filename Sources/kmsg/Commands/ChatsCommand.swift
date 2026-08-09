import ArgumentParser
import Foundation

struct ChatsCommand: ParsableCommand {
    private struct ChatsJSONResponse: Codable {
        let count: Int
        let chats: [ChatListEntry]
    }

    static let configuration = CommandConfiguration(
        commandName: "chats",
        abstract: "List chat rooms"
    )

    @Flag(name: .shortAndLong, help: "Show detailed information")
    var verbose: Bool = false

    @Option(name: .shortAndLong, help: "Maximum number of chats to show")
    var limit: Int = 20

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: [.short, .long], help: "Keep auto-opened chat window after chats")
    var keepWindow: Bool = false

    func run() throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        let profiler = PhaseProfiler(command: "chats")
        defer { profiler.emitSummary(status: "done") }
        profiler.begin("auth")
        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let chatWindowResolver = ChatWindowResolver(kakao: kakao, runner: runner)
        let windowsBefore = kakao.windows

        // Prefer the chat list window ("카카오톡") over any conversation window
        let mainWindow: UIElement
        let autoOpenedWindow: Bool
        if let chatListWindow = kakao.chatListWindow {
            mainWindow = chatListWindow
            autoOpenedWindow = false
            runner.log("chats: using chatListWindow title='\(chatListWindow.title ?? "")'")
        } else if let fallback = kakao.ensureMainWindow(timeout: 5.0, trace: { message in
            runner.log(message)
        }) {
            mainWindow = fallback
            autoOpenedWindow = !windowsBefore.contains(where: { existing in
                CFEqual(existing.axElement, fallback.axElement)
            })
            runner.log("chats: fallback to ensureMainWindow")
        } else {
            print("Could not find a usable KakaoTalk window.")
            AuthVerificationCache.invalidate()
            throw ExitCode.failure
        }

        defer {
            if autoOpenedWindow && keepWindow {
                runner.log("chats: keep-window enabled; auto-opened window will be kept")
            } else if autoOpenedWindow {
                if chatWindowResolver.closeWindow(mainWindow) {
                    runner.log("chats: auto-opened window closed")
                } else {
                    runner.log("chats: failed to close auto-opened window")
                }
            }
        }

        runner.log("chats: usable window ready")

        // 남은 검색어는 목록을 필터한 채로 두고, 그 상태는 프로세스가 아니라 카톡
        // GUI 에 남아 다음 실행들에 그대로 상속된다 — 스캔은 status=done 으로
        // 한두 행을 정상 결과처럼 돌려주고, 호출자에게는 방들이 사라진 것으로 보인다
        // (2026-08-09 09:50~10:00 UTC: rows=1 이 153회 연속, 그 10분간 read/send 0건).
        // 아래 재스캔은 이걸 못 고친다. 덜 그려진 목록은 기다리면 채워지지만 필터된
        // 목록은 지워주기 전까지 영원히 그대로다.
        if chatWindowResolver.clearChatListSearchIfDirty(in: mainWindow) {
            profiler.note("searchcleared", "1")
            Thread.sleep(forTimeInterval: 0.35)
        }

        profiler.begin("scan")
        let scanner = ChatListScanner()
        var snapshots = scanner.scan(in: mainWindow, limit: limit, trace: { message in
            runner.log(message)
        })
        defer { profiler.note("rows", String(snapshots.count)) }

        // 스캔이 성공했다는 것과 정상이었다는 것은 다르다. 창을 여는 명령(read/send)
        // 직후 카톡이 목록을 다시 그리는 동안 컨테이너의 children 이 순간적으로 한둘만
        // 남는데, 여기서 그걸 그대로 돌려주면 호출자에게는 "그 방들이 사라졌다"로
        // 보인다. talkfriend 브릿지 실측(2026-08-09): 스캔 50회 중 17회가 정상(25행
        // 0.57s / 100행 2.5s) 대신 **0.03초에 1~2행**이었고, 전부 read/send 직후였다
        // (창을 안 건드린 직후의 스캔은 9회 모두 정상). 그 17회가 멀쩡한 방 ~100개를
        // "고착"으로 만들어 브릿지가 그 방들의 창을 열었다 닫게 했다.
        //
        // 한 행짜리 목록과 한 행만 그려진 목록은 AX 상으로 구별되지 않으므로, 판단
        // 근거는 이 설치본이 실제로 봐 온 방 수뿐이다(레지스트리는 오래된 레코드를
        // 축출하므로 전체 이력이 아니라 최근 현실을 담는다). 갓 설치한 상태에서는 0이고,
        // 그때는 비교하지 않는다.
        let expectedRows = min(limit, ChatIdentityRegistryStore.shared.knownChatCount)
        if expectedRows > 0 && snapshots.count * 2 < expectedRows {
            runner.log(
                "chats: scan resolved \(snapshots.count) row(s) where ~\(expectedRows) were expected — letting the list settle and rescanning"
            )
            // 캐시된 컨테이너 경로도 버린다. 덜 그려진 것인지 엉뚱한 컨테이너를 물었는지
            // 여기서는 구별할 수 없고(검증이 역할만 본다), 버리면 둘 다 덮인다.
            try? AXPathCacheStore.shared.clear(slots: [.chatListContainer])
            Thread.sleep(forTimeInterval: 0.35)
            let settled = scanner.scan(in: kakao.chatListWindow ?? mainWindow, limit: limit, trace: { message in
                runner.log(message)
            })
            profiler.note("resettled", settled.count > snapshots.count ? "1" : "0")
            // 더 많이 잡혔을 때만 바꾼다 — 재시도가 결과를 줄이는 일은 없어야 한다.
            if settled.count > snapshots.count {
                snapshots = settled
            }
        }

        // The main window being on the friends tab shows up two ways: an
        // empty scan, OR — worse — a non-empty scan of friend rows whose
        // "previews" are status messages that never change with new messages,
        // silently freezing inbound detection downstream. Both cases: switch
        // to the chats tab (⌘2) and rescan once.
        if snapshots.isEmpty || scanner.looksLikeFriendsList(snapshots, in: mainWindow, trace: { runner.log($0) }) {
            runner.log(
                snapshots.isEmpty
                    ? "chats: empty scan — switching to the chats tab (⌘2) and rescanning"
                    : "chats: scan is not the chat list — switching to the chats tab (⌘2) and rescanning"
            )
            // 요약 줄에 남긴다. `runner.log` 는 `--trace-ax` 없이는 아무 데도 안 가는데
            // 브릿지는 그 플래그 없이 돈다 — 그래서 이 복구는 프로덕션에서 완전히
            // 보이지 않는다. 하필 이 상태의 대가가 조용한 수신 정지라 "몇 번이나
            // 일어나고 있나"가 곧 다음 조사의 첫 질문이 된다 (`searchcleared` 와
            // 같은 이유, 같은 자리).
            profiler.note("tabrecovered", "1")
            kakao.activate()
            runner.pressCommandTwo()
            Thread.sleep(forTimeInterval: 0.4)
            let retryWindow = kakao.chatListWindow ?? mainWindow
            snapshots = scanner.scan(in: retryWindow, limit: limit, trace: { message in
                runner.log(message)
            })
            // Refuse to report friends as chats: bogus rows with frozen
            // previews are strictly worse than an empty result (callers treat
            // empty as scan-missing and fall back to direct by-name reads).
            if scanner.looksLikeFriendsList(snapshots, in: retryWindow, trace: { runner.log($0) }) {
                runner.log("chats: rescan still looks like the friends list — reporting no chats instead of friends rows")
                snapshots = []
            }
        }

        if snapshots.isEmpty {
            if json {
                try printChatsAsJSON([])
                return
            }
            print("No chat list found.")
            print("\nTip: Make sure you're on the 'Chats' (채팅) tab in KakaoTalk.")
            print("Use 'kmsg inspect' to explore the UI structure.")
            runner.log("chats: no chat items found after traversal")
            return
        }

        let registry = ChatIdentityRegistryStore.shared
        let assignedIDs = registry.assignChatIDs(for: snapshots.map(\.discovery))
        let chats = zip(snapshots, assignedIDs).map { snapshot, chatID in
            ChatListEntry(
                title: snapshot.discovery.title,
                chatID: chatID.isEmpty ? nil : chatID,
                lastMessage: snapshot.discovery.lastMessage,
                unread: snapshot.discovery.unread
            )
        }
        if json {
            try printChatsAsJSON(chats)
            return
        }

        print("Searching for chat list in KakaoTalk...\n")
        print("Found \(chats.count) chat(s):\n")

        for (index, chat) in chats.enumerated() {
            print("[\(index + 1)] \(chat.title)")
            print("    chat_id: \(chat.chatID ?? "unavailable")")
            if verbose, let msg = chat.lastMessage {
                print("    └─ \(msg)")
            }
        }
    }

    private func printChatsAsJSON(_ chats: [ChatListEntry]) throws {
        let response = ChatsJSONResponse(count: chats.count, chats: chats)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }
}

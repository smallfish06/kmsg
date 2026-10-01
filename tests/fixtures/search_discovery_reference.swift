// Frozen resolver methods from 1e9745b (v1.261002.6), before support diagnostics.
    private func findExistingSearchField(in rootWindow: UIElement) -> UIElement? {
        if let cachedSearchField = resolveCachedElement(
            slot: .searchField,
            root: rootWindow,
            validate: { field in
                field.isEnabled && field.role == kAXTextFieldRole
            }
        ) {
            return cachedSearchField
        }

        let initialFields = discoverSearchFieldCandidates(in: rootWindow)
        if let field = pickSearchField(from: initialFields) {
            rememberCachedElement(slot: .searchField, root: rootWindow, element: field)
            return field
        }

        return nil
    }

    private func discoverSearchFieldCandidates(in rootWindow: UIElement) -> [UIElement] {
        var fields: [UIElement] = []
        fields.append(contentsOf: rootWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        if let focusedWindow = kakao.focusedWindow {
            fields.append(contentsOf: focusedWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        }
        if let mainWindow = kakao.mainWindow {
            fields.append(contentsOf: mainWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        }
        return fields.filter { $0.isEnabled }
    }

    private func pickSearchField(from fields: [UIElement]) -> UIElement? {
        fields
            .filter { $0.isEnabled }
            .sorted { lhs, rhs in
                let lhsY = lhs.position?.y ?? .greatestFiniteMagnitude
                let rhsY = rhs.position?.y ?? .greatestFiniteMagnitude
                return lhsY < rhsY
            }
            .first
    }

    func clearChatListSearchIfDirty(in window: UIElement) -> Bool {
        guard interactionMode != .backgroundSafe else { return false }
        // 검색창을 "찾아내려고" 버튼을 누르지는 않는다(locateSearchField 의 마지막
        // 수단). 이건 매 tick 도는 경로라 그 부작용이 상시화된다.
        guard let searchField = findExistingSearchField(in: window) else { return false }
        let residue = searchField.stringValue ?? ""
        guard !residue.isEmpty else { return false }

        runner.log("chats: chat list search field still holds '\(residue)' — clearing it before the scan")
        clearChatListSearch(searchField, in: window, label: residue)
        return (searchField.stringValue ?? "").isEmpty
    }

    private func clearChatListSearch(_ searchField: UIElement, in rootWindow: UIElement, label: String) {
        guard !(searchField.stringValue ?? "").isEmpty else { return }

        // AX 포커스와 키 이벤트의 목적지는 다른 축이다. focusWithVerification 은 AX
        // 속성을 세팅할 뿐이고, pressCommandA/pressDeleteKey 는 CGEvent 라 **프론트모스트
        // 앱**으로 간다 — 카톡을 올리지 않으면 그 키는 이 프로세스를 띄운 터미널로 간다
        // (첫 판이 정확히 그래서 "FAILED to clear" 로 죽었다). 이 파일의 다른 키 입력
        // 자리들이 전부 activate 를 먼저 부르는 이유가 이거다.
        kakao.activate()
        _ = tryRaiseWindow(rootWindow)
        Thread.sleep(forTimeInterval: 0.08)

        guard runner.focusWithVerification(searchField, label: "search field clear", attempts: 1) else {
            runner.log("search: could not focus the field to clear '\(label)' — the chat list may stay filtered")
            return
        }

        runner.pressCommandA()
        runner.pressDeleteKey()

        var cleared = runner.waitUntil(
            label: "search field emptied",
            timeout: 0.3,
            pollInterval: 0.05,
            evaluateAfterTimeout: true
        ) {
            (searchField.stringValue ?? "").isEmpty
        }

        // 필드를 잡은 상태에서의 Escape 는 검색을 통째로 끝낸다(NSSearchField 기본 동작).
        // 한 번 더 쓰는 이유는 실패의 대가가 비대칭이라서다 — 여기서 못 지우면 다음
        // 스캔들이 필터된 목록을 정상 결과로 돌려준다.
        if !cleared {
            runner.log("search: cmd+A/delete did not empty '\(label)'; retrying with escape")
            runner.pressEscapeKey()
            cleared = runner.waitUntil(
                label: "search field emptied (escape)",
                timeout: 0.3,
                pollInterval: 0.05,
                evaluateAfterTimeout: true
            ) {
                (searchField.stringValue ?? "").isEmpty
            }
        }
        // 실패는 조용히 넘어가면 안 된다: 다음 `chats` 가 필터된 목록을 정상 결과로
        // 돌려주는 게 바로 여기서 시작한다.
        runner.log(cleared ? "search: cleared '\(label)' from the chat list search field"
                           : "search: FAILED to clear '\(label)' — the chat list is still filtered")
    }

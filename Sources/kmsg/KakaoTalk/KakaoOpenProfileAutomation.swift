import AppKit
import ApplicationServices.HIServices
import Foundation

struct KakaoOpenProfileResult {
    let profile: String
    let openProfileURL: URL
    let chatTitle: String
    let externalChatID: String
}

private enum OpenProfileAutomationFailureCode: String {
    case urlOpenFailed = "OPEN_PROFILE_URL_OPEN_FAILED"
    case windowNotReady = "OPEN_PROFILE_WINDOW_NOT_READY"
    case messageInputNotFound = "MESSAGE_INPUT_NOT_FOUND"
    case inputNotReflected = "INPUT_NOT_REFLECTED"
    case enterNotEffective = "ENTER_NOT_EFFECTIVE"
}

struct KakaoOpenProfileAutomation {
    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner

    init(kakao: KakaoTalkApp, runner: AXActionRunner) {
        self.kakao = kakao
        self.runner = runner
    }

    func startOpenProfile(profile: String, url: URL, message: String?) throws -> KakaoOpenProfileResult {
        guard NSWorkspace.shared.open(url) else {
            throw KakaoTalkError.actionFailed("[\(OpenProfileAutomationFailureCode.urlOpenFailed.rawValue)] Could not open '\(url.absoluteString)'")
        }

        let profileRoot = try waitForOpenProfileWindow(profile: profile)
        let chatWindow = enterChatIfAvailable(from: profileRoot, profile: profile)

        if let message {
            try sendMessage(message, to: chatWindow)
        }

        return KakaoOpenProfileResult(
            profile: profile,
            openProfileURL: url,
            chatTitle: profile,
            externalChatID: "open-profile:\(profile)"
        )
    }

    private func waitForOpenProfileWindow(profile: String) throws -> UIElement {
        var resolved: UIElement?
        let found = runner.waitUntil(label: "open profile window", timeout: 8.0, pollInterval: 0.2) {
            kakao.activate()
            guard let root = currentRoot() else {
                return false
            }
            resolved = root
            return containsText(profile, in: root) || resolveMessageInputField(in: root) != nil || hasAnyText(in: root, matching: ["오픈프로필", "오픈채팅", "open profile", "open chat"])
        }

        guard found, let resolved else {
            throw KakaoTalkError.windowNotFound("[\(OpenProfileAutomationFailureCode.windowNotReady.rawValue)] Open Profile window did not become ready")
        }
        return resolved
    }

    private func enterChatIfAvailable(from root: UIElement, profile: String) -> UIElement {
        let activeRoot = currentRoot() ?? root
        if resolveMessageInputField(in: activeRoot) != nil {
            return activeRoot
        }

        let patterns = [
            "1:1 채팅", "1:1대화", "채팅하기", "대화하기", "메시지 보내기",
            "채팅", "대화", "메시지", "chat", "message", "open chat"
        ]
        if let button = findActionCandidate(in: activeRoot, matching: patterns), activate(button, label: "open profile chat start") {
            var chatWindow: UIElement?
            _ = runner.waitUntil(label: "open profile chat ready", timeout: 3.0, pollInterval: 0.1) {
                if let focused = currentRoot(), resolveMessageInputField(in: focused) != nil {
                    chatWindow = focused
                    return true
                }
                return false
            }
            return chatWindow ?? currentRoot() ?? activeRoot
        }

        runner.log("open profile: chat start button not found for '\(profile)'; keeping opened profile window")
        return activeRoot
    }

    private func sendMessage(_ message: String, to window: UIElement) throws {
        kakao.activate()
        _ = tryRaiseWindow(window)
        Thread.sleep(forTimeInterval: 0.12)

        guard let input = resolveMessageInputField(in: currentRoot() ?? window) ?? resolveMessageInputField(in: window) else {
            throw KakaoTalkError.elementNotFound("[\(OpenProfileAutomationFailureCode.messageInputNotFound.rawValue)] Message input field not found")
        }

        guard runner.focusWithVerification(input, label: "open profile message input", attempts: 1) else {
            throw KakaoTalkError.actionFailed("[\(OpenProfileAutomationFailureCode.messageInputNotFound.rawValue)] Could not focus message input")
        }

        let inputReady =
            runner.setTextWithVerification(message, on: input, label: "open profile message input", attempts: 1) ||
            runner.typeTextWithVerification(message, on: input, label: "open profile message input", attempts: 2)

        guard inputReady else {
            throw KakaoTalkError.actionFailed("[\(OpenProfileAutomationFailureCode.inputNotReflected.rawValue)] Message input was not reflected")
        }

        let sent = runner.pressEnterWithVerification(
            on: input,
            label: "open profile message input",
            attempts: 2,
            reflectionTimeout: 0.36,
            retryDelay: 0.08
        )

        guard sent else {
            throw KakaoTalkError.actionFailed("[\(OpenProfileAutomationFailureCode.enterNotEffective.rawValue)] Enter key had no visible effect")
        }
    }

    private func currentRoot() -> UIElement? {
        kakao.focusedWindow ?? kakao.mainWindow ?? kakao.windows.last
    }

    private func resolveMessageInputField(in root: UIElement) -> UIElement? {
        let candidates = collectMessageInputCandidates(from: root)
        return candidates.sorted { lhs, rhs in
            scoreMessageInputCandidate(lhs, in: root) > scoreMessageInputCandidate(rhs, in: root)
        }.first
    }

    private func collectMessageInputCandidates(from root: UIElement) -> [UIElement] {
        let roleCandidates = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            return element.role == kAXTextAreaRole || element.role == kAXTextFieldRole
        }, limit: 72, maxNodes: 800)

        let editableCandidates = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
            guard editable else { return false }
            let role = element.role ?? ""
            return role != kAXStaticTextRole && role != kAXImageRole
        }, limit: 72, maxNodes: 800)

        return deduplicate(roleCandidates + editableCandidates)
    }

    private func scoreMessageInputCandidate(_ element: UIElement, in root: UIElement) -> Double {
        guard element.isEnabled else { return -Double.greatestFiniteMagnitude }

        let role = element.role ?? ""
        var score = 0.0
        if role == kAXTextAreaRole {
            score += 10_000.0
        } else if role == kAXTextFieldRole {
            score += 7_000.0
        } else {
            let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
            score += editable ? 4_000.0 : 0.0
        }

        let text = normalize(elementText(element))
        if text.contains("검색") || text.contains("search") {
            score -= 8_000.0
        }
        if text.contains("메시지") || text.contains("message") || text.contains("입력") {
            score += 1_000.0
        }

        if let rootFrame = root.frame, let elementFrame = element.frame {
            let relativeY = (elementFrame.midY - rootFrame.minY) / max(rootFrame.height, 1.0)
            if relativeY > 0.55 {
                score += 1_500.0
            }
            if elementFrame.width > rootFrame.width * 0.35 {
                score += 800.0
            }
        }

        return score
    }

    private func findActionCandidate(in root: UIElement, matching patterns: [String]) -> UIElement? {
        let candidates = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            let role = element.role ?? ""
            return role == kAXButtonRole || role == "AXMenuButton" || role == "AXPopUpButton" || role == kAXStaticTextRole || role == kAXRowRole || role == kAXCellRole
        }, limit: 120, maxNodes: 1_800)

        return candidates.map { element in
            (element: element, score: scoreElement(element, matching: patterns))
        }
        .filter { $0.score > 0 }
        .sorted { lhs, rhs in lhs.score > rhs.score }
        .first?.element
    }

    private func hasAnyText(in root: UIElement, matching patterns: [String]) -> Bool {
        findActionCandidate(in: root, matching: patterns) != nil
    }

    private func activate(_ element: UIElement, label: String) -> Bool {
        if supportsAction(kAXPressAction, on: element) {
            do {
                try element.press()
                runner.log("\(label): activated via AXPress")
                return true
            } catch {
                runner.log("\(label): AXPress failed (\(error))")
            }
        }

        if supportsAction("AXConfirm", on: element) {
            do {
                try element.performAction("AXConfirm")
                runner.log("\(label): activated via AXConfirm")
                return true
            } catch {
                runner.log("\(label): AXConfirm failed (\(error))")
            }
        }

        if runner.focusWithVerification(element, label: label, attempts: 1) {
            runner.pressEnterKey()
            return true
        }

        if let frame = element.frame {
            runner.mouseDoubleClick(at: CGPoint(x: frame.midX, y: frame.midY), label: label)
            return true
        }

        return false
    }

    private func tryRaiseWindow(_ window: UIElement) -> Bool {
        if supportsAction(kAXRaiseAction, on: window) {
            do {
                try window.performAction(kAXRaiseAction)
                runner.log("open profile: window raised via AXRaise")
                return true
            } catch {
                runner.log("open profile: AXRaise failed (\(error))")
            }
        }
        return false
    }

    private func supportsAction(_ action: String, on element: UIElement) -> Bool {
        (try? element.actionNames().contains(action)) ?? false
    }

    private func deduplicate(_ candidates: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(candidates.count)
        for candidate in candidates {
            if unique.contains(where: { CFEqual($0.axElement, candidate.axElement) }) {
                continue
            }
            unique.append(candidate)
        }
        return unique
    }

    private func scoreElement(_ element: UIElement, matching patterns: [String]) -> Int {
        let text = normalize(elementText(element))
        var score = 0
        for pattern in patterns {
            let normalizedPattern = normalize(pattern)
            if text == normalizedPattern {
                score += 5_000
            } else if text.contains(normalizedPattern) {
                score += 2_500
            }
        }
        if element.isEnabled {
            score += 100
        }
        return score
    }

    private func containsText(_ text: String, in element: UIElement) -> Bool {
        normalize(elementText(element)).contains(normalize(text))
    }

    private func elementText(_ element: UIElement) -> String {
        collectTexts(element).joined(separator: " ")
    }

    private func collectTexts(_ element: UIElement) -> [String] {
        var values: [String] = []
        for value in [element.title, element.axDescription, element.identifier, element.stringValue, element.helpText] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append(value)
            }
        }
        for child in element.children.prefix(16) {
            for value in [child.title, child.axDescription, child.identifier, child.stringValue, child.helpText] {
                if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    values.append(value)
                }
            }
        }
        return values
    }

    private func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}

// Frozen production methods from kmsg 4480afab184a5e3c7a2cb14688b32ced923fe345.
// Synthetic fixture reference only; never linked into the application.
// BEGIN AUTH
    private func appendUnique(_ candidate: UIElement?, to roots: inout [UIElement]) {
        guard let candidate else { return }
        guard !roots.contains(where: { CFEqual($0.axElement, candidate.axElement) }) else { return }
        roots.append(candidate)
    }

    private func appendFocusedElementAncestorChain(from element: UIElement?, to roots: inout [UIElement]) {
        var current = element
        var remaining = 8
        while let candidate = current, remaining > 0 {
            appendUnique(candidate, to: &roots)
            current = candidate.parent
            remaining -= 1
        }
    }

    private func resolvePostLoginAcknowledgement() -> PostLoginAcknowledgement? {
        for root in collectPostLoginAcknowledgementRoots() {
            guard let acknowledgement = resolvePostLoginAcknowledgement(in: root) else {
                continue
            }
            return acknowledgement
        }
        return nil
    }

    private func collectPostLoginAcknowledgementRoots() -> [UIElement] {
        var roots: [UIElement] = []
        appendUnique(kakao.focusedWindow, to: &roots)
        appendUnique(kakao.mainWindow, to: &roots)
        appendUnique(kakao.applicationElement.focusedUIElement, to: &roots)
        appendFocusedElementAncestorChain(from: kakao.applicationElement.focusedUIElement, to: &roots)

        let systemWide = UIElement.systemWide()
        appendUnique(systemWide.focusedUIElement, to: &roots)
        appendFocusedElementAncestorChain(from: systemWide.focusedUIElement, to: &roots)

        for window in kakao.windows {
            appendUnique(window, to: &roots)
        }

        appendUnique(kakao.applicationElement, to: &roots)
        return roots
    }

    private func resolvePostLoginAcknowledgement(in root: UIElement) -> PostLoginAcknowledgement? {
        let message = collectPostLoginAcknowledgementText(from: root)
        guard containsPostLoginAcknowledgementMarkers(message) else {
            return nil
        }

        let buttons = root.findAll(role: kAXButtonRole, limit: 8, maxNodes: 220)
        guard let button = buttons.max(by: { scoreAcknowledgementButton($0) < scoreAcknowledgementButton($1) }),
              scoreAcknowledgementButton(button) > 0
        else {
            return nil
        }

        return PostLoginAcknowledgement(root: root, button: button, message: message)
    }

    private func collectPostLoginAcknowledgementText(from root: UIElement) -> String {
        let roles: Set<String> = [kAXButtonRole, kAXStaticTextRole, kAXGroupRole]
        let found = root.findAll(roles: roles, roleLimits: [
            kAXButtonRole: 8,
            kAXStaticTextRole: 16,
            kAXGroupRole: 6,
        ], maxNodes: 260)

        let tokens = (found[kAXStaticTextRole] ?? []) + (found[kAXButtonRole] ?? []) + (found[kAXGroupRole] ?? [])
        return normalizedText(tokens.map {
            [
                $0.title,
                $0.axDescription,
                $0.stringValue,
                $0.identifier,
            ].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: " "))
    }

    private func containsPostLoginAcknowledgementMarkers(_ text: String) -> Bool {
        let exactMarkers = [
            "currently logged in",
            "already logged in",
            "you are currently logged in",
            "you are already logged in",
            "logged in on another device",
            "이미 로그인",
            "로그인되어 있습니다",
        ]

        if exactMarkers.contains(where: text.contains) {
            return true
        }

        let hasLoggedInMarker =
            text.contains("logged in") ||
            text.contains("이미 로그인") ||
            text.contains("로그인되어")
        let hasPromptMarker =
            text.contains("ok") ||
            text.contains("확인") ||
            text.contains("currently") ||
            text.contains("already") ||
            text.contains("device")

        return hasLoggedInMarker && hasPromptMarker
    }

    private func scoreAcknowledgementButton(_ button: UIElement) -> Int {
        let texts = buttonTextCandidates(button)
        var score = 0
        if texts.contains("ok") {
            score += 140
        }
        if texts.contains("확인") {
            score += 120
        }
        if texts.contains("confirm") {
            score += 100
        }
        if button.isEnabled {
            score += 20
        }
        return score
    }

    private func buttonTextCandidates(_ button: UIElement) -> [String] {
        Array(
            Set(
                [
                    button.title,
                    button.axDescription,
                    button.identifier,
                    button.stringValue,
                ]
                .compactMap { $0 }
                .map(normalizedText)
                .filter { !$0.isEmpty }
            )
        )
    }

    private func normalizedText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
// END AUTH
// BEGIN UI
    public func roleAndChildren() -> (role: String?, children: [UIElement]) {
        let values = batchAttributes([kAXRoleAttribute, kAXChildrenAttribute])
        let role = values[0] as? String
        let children = (values[1] as? [AXUIElement])?.map { UIElement($0) } ?? []
        return (role, children)
    }

    public func findAll(
        roles: Set<String>,
        roleLimits: [String: Int] = [:],
        maxNodes: Int = 500
    ) -> [String: [UIElement]] {
        var results: [String: [UIElement]] = [:]
        for role in roles { results[role] = [] }

        var saturated = 0
        let totalRoles = roles.count
        var queue = children
        var index = 0
        var visited = 0

        while index < queue.count && visited < maxNodes && saturated < totalRoles {
            let current = queue[index]
            index += 1
            visited += 1

            let (currentRole, children) = current.roleAndChildren()
            if let role = currentRole, roles.contains(role) {
                let limit = roleLimits[role] ?? .max
                if results[role]!.count < limit {
                    results[role]!.append(current)
                    if results[role]!.count >= limit {
                        saturated += 1
                    }
                }
            }

            if saturated < totalRoles && visited < maxNodes {
                queue.append(contentsOf: children)
            }
        }

        return results
    }

    public func findAll(role: String, limit: Int, maxNodes: Int? = nil) -> [UIElement] {
        var results: [UIElement] = []
        var queue = children
        var index = 0
        var visited = 0
        let nodeBudget = maxNodes ?? .max

        while index < queue.count && results.count < limit && visited < nodeBudget {
            let current = queue[index]
            index += 1
            visited += 1
            let (currentRole, currentChildren) = current.roleAndChildren()
            if currentRole == role {
                results.append(current)
                if results.count >= limit { break }
            }
            if visited >= nodeBudget { break }
            queue.append(contentsOf: currentChildren)
        }

        return results
    }
// END UI

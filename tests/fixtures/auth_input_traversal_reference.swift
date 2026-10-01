// Scalar classifier/form reference frozen from c3699794d01b1fe16d353e2a0a7925226693b92a.
    private func buildLoginForm(from window: UIElement) -> LoginForm? {
        let inputFields = window.findAll(where: { element in
            let role = element.role ?? ""
            guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == "AXSecureTextField" else { return false }
            return element.isEnabled
        }, limit: 8, maxNodes: 240)

        guard inputFields.count >= 2 else { return nil }
        let sortedInputs = inputFields.sorted { lhs, rhs in
            let lhsY = lhs.position?.y ?? .greatestFiniteMagnitude
            let rhsY = rhs.position?.y ?? .greatestFiniteMagnitude
            if lhsY == rhsY {
                let lhsX = lhs.position?.x ?? .greatestFiniteMagnitude
                let rhsX = rhs.position?.x ?? .greatestFiniteMagnitude
                return lhsX < rhsX
            }
            return lhsY < rhsY
        }

        guard let usernameField = sortedInputs.first(where: { !looksLikePasswordField($0) }) ?? sortedInputs.first else {
            return nil
        }
        guard let passwordField = sortedInputs.first(where: { candidate in
            !CFEqual(candidate.axElement, usernameField.axElement) && looksLikePasswordField(candidate)
        }) ?? sortedInputs.dropFirst().first else {
            return nil
        }

        return LoginForm(window: window, usernameField: usernameField, passwordField: passwordField)
    }

    private func isLikelyLoginWindow(_ window: UIElement) -> Bool {
        let phaseStarted = phaseDiagnostics?.begin()
        defer { if let phaseStarted { phaseDiagnostics?.end(.login, since: phaseStarted) } }
        let title = authPhase(.title) { normalizedText(window.title ?? "") }
        if title.contains("login") || title.contains("log in") || title.contains("로그인") {
            return true
        }

        let loginMarkerText = authPhase(.markers) { collectLoginMarkerText(from: window) }
        if containsLoginMarkers(loginMarkerText) {
            return true
        }

        let inputs = authPhase(.inputs) {
            window.findAll(where: { element in
                let role = element.role ?? ""
                guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == "AXSecureTextField" else { return false }
                return element.isEnabled
            }, limit: 6, maxNodes: 200)
        }
        if inputs.count >= 2 {
            return true
        }

        let buttonTitles = authPhase(.buttons) {
            window.findAll(role: kAXButtonRole, limit: 10, maxNodes: 200).map { button in
                normalizedText([
                    button.title,
                    button.axDescription,
                    button.identifier,
                ].compactMap { $0 }.joined(separator: " "))
            }
        }

        if buttonTitles.contains(where: {
            $0.contains("login") || $0.contains("log in") || $0.contains("로그인") || $0.contains("signin")
        }) {
            return true
        }

        return authPhase(.password) { inputs.contains(where: looksLikePasswordField) }
    }

    private func authPhase<T>(_ phase: AuthPhaseDiagnostics.Phase, _ action: () throws -> T) rethrows -> T {
        guard let phaseDiagnostics else { return try action() }
        return try phaseDiagnostics.measure(phase, action)
    }

    private func collectLoginMarkerText(from root: UIElement) -> String {
        let roles: Set<String> = [kAXButtonRole, kAXStaticTextRole, kAXCheckBoxRole]
        let found = root.findAll(roles: roles, roleLimits: [
            kAXButtonRole: 12,
            kAXStaticTextRole: 12,
            kAXCheckBoxRole: 6,
        ], maxNodes: 260)

        let tokens = (found[kAXButtonRole] ?? []) + (found[kAXStaticTextRole] ?? []) + (found[kAXCheckBoxRole] ?? [])
        return normalizedText(tokens.map {
            [
                $0.title,
                $0.axDescription,
                $0.stringValue,
                $0.identifier,
            ].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: " "))
    }

    private func containsLoginMarkers(_ text: String) -> Bool {
        let markers = [
            "qr code",
            "start over",
            "keep me logged in",
            "find my kakao account",
            "reset password",
            "remaining time",
            "how to log in",
            "log in using a qr code",
        ]
        return markers.contains(where: text.contains)
    }

    private func looksLikePasswordField(_ element: UIElement) -> Bool {
        let role = element.role ?? ""
        if role == "AXSecureTextField" {
            return true
        }

        let metadata = normalizedText([
            element.title,
            element.axDescription,
            element.identifier,
        ].compactMap { $0 }.joined(separator: " "))
        if metadata.contains("password") || metadata.contains("passwd") || metadata.contains("비밀번호") {
            return true
        }

        if let stringValue = element.stringValue, stringValue.contains("•") || stringValue.contains("*") {
            return true
        }

        return false
    }

    private func normalizedText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

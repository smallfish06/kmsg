// Frozen v1.261002.1 (8102b3c) authentication decisions for timing equivalence.

    func ensureAuthenticated(
        using store: CredentialStore,
        mode: AuthenticationMode
    ) throws -> AuthenticationOutcome {
        defer { emitAcknowledgementMetrics() }
        // Fast path: a recent full check concluded logged-in AND a usable
        // window handle is cheaply present right now. The full pipeline below
        // costs seconds of AX round-trips per command on a loaded machine; the
        // session state it verifies changes ~monthly. Window-gone and every
        // command failure invalidate the cache (see command defers), so a
        // stale verdict costs at most one failed command, not a silent stall.
        if mode == .automaticIfNeeded, AuthVerificationCache.isFresh, kakao.hasUsableWindow {
            runner.log("auth: fresh verification cache + usable window; skipping full check")
            return .alreadyAuthenticated
        }

        // KakaoTalk may be running with its main window closed (the user closed the window
        // but left the app running in the background). Activation alone won't reopen it, so
        // an already-authenticated session would be misread as logged-out and fall through to
        // a failing blind keyboard login. Reopen the window once before evaluating auth state.
        _ = kakao.ensureWindowReopened(timeout: 3.0, trace: { [self] message in
            runner.log("auth: \(message)")
        })

        if mode == .promptForFreshCredentials {
            let prompted = try PasswordPrompt.promptForCredentials(defaultIdentifier: store.storedIdentifier())

            if isAuthenticated() {
                try store.save(identifier: prompted.identifier, password: prompted.password)
                AuthVerificationCache.markVerified()
                return .alreadyAuthenticated
            }

            guard let form = findLoginForm() else {
                try performBlindLogin(with: prompted)
                try store.save(identifier: prompted.identifier, password: prompted.password)
                AuthVerificationCache.markVerified()
                return .loggedIn
            }

            try performLogin(with: prompted, form: form)
            try store.save(identifier: prompted.identifier, password: prompted.password)
            AuthVerificationCache.markVerified()
            return .loggedIn
        }

        if isAuthenticated() {
            AuthVerificationCache.markVerified()
            return .alreadyAuthenticated
        }

        let storedCredentials = try store.loadCredentials()
        let credentials = try storedCredentials ?? PasswordPrompt.promptForCredentials(defaultIdentifier: store.storedIdentifier())
        guard let form = findLoginForm() else {
            try performBlindLogin(with: credentials)
            if storedCredentials == nil {
                try store.save(identifier: credentials.identifier, password: credentials.password)
            }
            AuthVerificationCache.markVerified()
            return .loggedIn
        }

        try performLogin(with: credentials, form: form)
        if storedCredentials == nil {
            try store.save(identifier: credentials.identifier, password: credentials.password)
        }
        AuthVerificationCache.markVerified()
        return .loggedIn
    }

    private func isAuthenticated() -> Bool {
        if dismissPostLoginAcknowledgementIfPresent() {
            return false
        }

        if let chatListWindow = kakao.chatListWindow, !isLikelyLoginWindow(chatListWindow) {
            runner.log("auth: chatListWindow considered authenticated title='\(chatListWindow.title ?? "")'")
            return true
        }

        if let usableWindow = kakao.ensureMainWindow(timeout: 0.6, mode: .fast, trace: { [self] message in
            self.runner.log("auth: \(message)")
        }) {
            let title = usableWindow.title ?? ""
            let loginLike = isLikelyLoginWindow(usableWindow)
            runner.log("auth: usableWindow title='\(title)' loginLike=\(loginLike)")
            if !loginLike {
                return true
            }
            // A leftover popover/sheet (e.g. an aborted friend-add) makes the
            // logged-in main window read as a login screen. Dismiss it and
            // re-check once before concluding we're logged out; ESC on a real
            // login window is harmless.
            runner.log("auth: login-like window; dismissing possible leftover popover and re-checking")
            kakao.activate()
            runner.pressEscapeKey()
            Thread.sleep(forTimeInterval: 0.2)
            runner.pressEscapeKey()
            Thread.sleep(forTimeInterval: 0.3)
            if let rechecked = kakao.ensureMainWindow(timeout: 0.6, mode: .fast, trace: { [self] message in
                self.runner.log("auth: \(message)")
            }), !isLikelyLoginWindow(rechecked) {
                runner.log("auth: authenticated after dismissing leftover UI")
                return true
            }
        }

        return false
    }

    private func isLikelyLoginWindow(_ window: UIElement) -> Bool {
        let title = normalizedText(window.title ?? "")
        if title.contains("login") || title.contains("log in") || title.contains("로그인") {
            return true
        }

        let loginMarkerText = collectLoginMarkerText(from: window)
        if containsLoginMarkers(loginMarkerText) {
            return true
        }

        let inputs = window.findAll(where: { element in
            let role = element.role ?? ""
            return element.isEnabled && (role == kAXTextFieldRole || role == kAXTextAreaRole || role == "AXSecureTextField")
        }, limit: 6, maxNodes: 200)
        if inputs.count >= 2 {
            return true
        }

        let buttonTitles = window.findAll(role: kAXButtonRole, limit: 10, maxNodes: 200).map { button in
            normalizedText([
                button.title,
                button.axDescription,
                button.identifier,
            ].compactMap { $0 }.joined(separator: " "))
        }

        if buttonTitles.contains(where: {
            $0.contains("login") || $0.contains("log in") || $0.contains("로그인") || $0.contains("signin")
        }) {
            return true
        }

        return inputs.contains(where: looksLikePasswordField)
    }

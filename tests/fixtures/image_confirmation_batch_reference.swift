// Frozen native v9 image methods; only fake-clock/IPC and visit counters are injected by the test.
struct Baseline {
let targetDescription="SYNTHETIC"
    private func waitForConfirmationSheet(
        in window: UIElement, runner: AXActionRunner, diagnostics: ImageConfirmationDiagnostics? = nil
    ) -> UIElement? {
        var sheet: UIElement?
        _ = runner.waitUntil(label: "confirmation sheet", timeout: 1.5, pollInterval: 0.1) {
            sheet = locateConfirmationSheet(in: window, diagnostics: diagnostics)
            return sheet != nil
        }
        return sheet
    }
    private func locateConfirmationSheet(in window: UIElement, diagnostics: ImageConfirmationDiagnostics? = nil) -> UIElement? {
        let started = diagnostics?.beginLookup()
        defer { if let started { diagnostics?.endLookup(started) } }
        let elements: [AXUIElement]? = window.attributeOptional(kAXSheetsAttribute)
        if let elements {
            if let found = elements.first {
                diagnostics?.directPresent += 1
                return UIElement(found)
            }
            diagnostics?.directEmpty += 1
        } else {
            diagnostics?.directUnknown += 1
        }
        diagnostics?.fallbackWalks += 1
        let found = window.findFirst(where: {
            let role = $0.role
            world.visits.append($0.axElement.id)
            diagnostics?.fallbackVisits += 1
            if role == nil { diagnostics?.fallbackUnknownRoles += 1 }
            return role == kAXSheetRole
        })
        if found != nil { diagnostics?.fallbackFound += 1 }
        return found
    }
    private func findSendButton(in confirmationSheet: UIElement) -> UIElement? {
        confirmationSheet.findAll(role: kAXButtonRole).first { button in
            let title = (button.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title == "전송" || title == "Send"
        }
    }
    private func waitForSendCompletion(
        in window: UIElement,
        confirmationSheet: UIElement,
        runner: AXActionRunner,
        diagnostics: ImageConfirmationDiagnostics? = nil
    ) -> Bool {
        runner.waitUntil(label: "send-image completion", timeout: 1.5, pollInterval: 0.1) {
            locateConfirmationSheet(in: window, diagnostics: diagnostics) == nil ||
                !windowContainsElement(window, target: confirmationSheet, diagnostics: diagnostics)
        }
    }
    private func windowContainsElement(
        _ window: UIElement, target: UIElement, diagnostics: ImageConfirmationDiagnostics? = nil
    ) -> Bool {
        let started = diagnostics?.beginContains()
        defer { if let started { diagnostics?.endContains(started) } }
        let found = window.findFirst(where: { candidate in
            diagnostics?.containsVisits += 1
            return areSameAXElement(candidate, target)
        }) != nil
        if found { diagnostics?.containsFound += 1 }
        return found
    }
    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
    func run(_ mode:String)->String {
        let root=UIElement(world.root),target=UIElement(world.target),runner=AXActionRunner()
        switch mode {
        case "locate": return locateConfirmationSheet(in:root,diagnostics:world.diagnostics).map{String($0.axElement.id)} ?? "nil"
        case "wait": return waitForConfirmationSheet(in:root,runner:runner,diagnostics:world.diagnostics).map{String($0.axElement.id)} ?? "nil"
        case "complete": return waitForSendCompletion(in:root,confirmationSheet:target,runner:runner,diagnostics:world.diagnostics) ? "complete":"incomplete"
        default: do {try flow(root);return "native-success"} catch{return "native-failure"}
        }
    }
    func flow(_ window:UIElement)throws {
        let runner=AXActionRunner(),profiler=PhaseProfiler(),confirmationDiagnostics=world.diagnostics
        // 4. Confirmation sheet can be transient or skipped entirely depending on KakaoTalk state.
        profiler.begin("sheet")
        if let confirmationSheet = waitForConfirmationSheet(in: window, runner: runner, diagnostics: confirmationDiagnostics) {
            profiler.note("sheet.found", "1")
            runner.log("Confirmation sheet found")
            profiler.begin("sheet_settle")
            Thread.sleep(forTimeInterval: 0.2)

            profiler.begin("button")
            guard let button = findSendButton(in: confirmationSheet) else {
                profiler.note("button.found", "0")
                profiler.begin("complete")
                if !waitForSendCompletion(in: window, confirmationSheet: confirmationSheet, runner: runner, diagnostics: confirmationDiagnostics) {
                    throw KakaoTalkError.elementNotFound("Send button not found on confirmation sheet")
                }
                runner.log("send-image: sheet vanished before button lookup; treating as success")
                fixturePrint("✓ Image sent to \(targetDescription)")
                profiler.begin("settle")
                Thread.sleep(forTimeInterval: 0.5)
                return
            }

            profiler.note("button.found", "1")
            profiler.begin("click")
            let clicked = runner.clickWithRetry(button, label: "send button")
            profiler.note("click.ok", clicked ? "1" : "0")
            if !clicked {
                profiler.begin("complete")
                if !waitForSendCompletion(in: window, confirmationSheet: confirmationSheet, runner: runner, diagnostics: confirmationDiagnostics) {
                    throw KakaoTalkError.actionFailed("Failed to click send button after retries")
                }
            }
        } else {
            profiler.note("sheet.found", "0")
            runner.log("send-image: confirmation sheet not observed; allowing direct-send path")
            profiler.begin("direct_wait")
            Thread.sleep(forTimeInterval: 0.7)
        }

        fixturePrint("✓ Image sent to \(targetDescription)")

        // Give it a moment to finish sending
        profiler.begin("settle")
        Thread.sleep(forTimeInterval: 0.5)
    }
}

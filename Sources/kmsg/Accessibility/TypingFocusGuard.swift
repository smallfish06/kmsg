import Foundation

/// Decides whether character key events may be posted, from what currently
/// holds keyboard focus. Pure: the AX reads live in `AXActionRunner`.
///
/// Why this exists: a character key that reaches an `NSTableView` instead of a
/// text input starts AppKit's type-select, which walks the table creating row
/// views. 2026-11-12 22:12 KST (talkfriend local-mac-1) KakaoTalk's main thread
/// was pinned in `-[NSTableView keyDown:] → _performTypeSelect: →
/// rowViewAtRow:createIfNeeded:` and every AX call slowed 3–6x for an hour.
/// kmsg posts character keys through HID, so they land on whatever has focus —
/// the only safe moment to type is when that is a text input.
enum TypingFocusGuard {
    /// Roles that take typed characters as text. AXSearchField is normally a
    /// subrole of AXTextField; it is listed as a role too so an app that
    /// reports it either way is accepted.
    static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    static let textInputSubroles: Set<String> = ["AXSearchField"]

    struct Observation {
        /// KakaoTalk's AXFocusedUIElement could be read at all.
        var focusReadable: Bool
        var role: String?
        var subrole: String?
        /// nil when the caller has no handle on the element it means to type
        /// into; otherwise whether the focused element is that element.
        var isExpectedElement: Bool?
        /// The system-wide focused element positively belongs to another
        /// process. Unknown counts as false: only evidence blocks here.
        var focusInOtherApp: Bool

        init(
            focusReadable: Bool,
            role: String? = nil,
            subrole: String? = nil,
            isExpectedElement: Bool? = nil,
            focusInOtherApp: Bool = false
        ) {
            self.focusReadable = focusReadable
            self.role = role
            self.subrole = subrole
            self.isExpectedElement = isExpectedElement
            self.focusInOtherApp = focusInOtherApp
        }
    }

    enum Verdict: Equatable {
        case allow
        /// The token goes on the summary line as `type.blocked=<token>`.
        case block(String)
    }

    static func isTextInput(role: String?, subrole: String?) -> Bool {
        if let role, textInputRoles.contains(role) { return true }
        if let subrole, textInputSubroles.contains(subrole) { return true }
        return false
    }

    static func verdict(for observation: Observation) -> Verdict {
        // Keys go to the app that holds system focus, whatever KakaoTalk's own
        // (possibly stale) focused element says.
        if observation.focusInOtherApp { return .block("otherapp") }
        guard observation.focusReadable else { return .block("nofocus") }
        guard isTextInput(role: observation.role, subrole: observation.subrole) else {
            return .block(token(observation.role) ?? "norole")
        }
        if observation.isExpectedElement == false {
            return .block("\(token(observation.role) ?? "norole")/other")
        }
        return .allow
    }

    /// Summary-line values are split on spaces by the bridge; keep one token.
    private static func token(_ role: String?) -> String? {
        guard let role else { return nil }
        let cleaned = String(role.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return cleaned.isEmpty ? nil : cleaned
    }
}

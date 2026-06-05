# kmsg Behavior-Preserving Refactor — Design

- **Date**: 2026-06-06
- **Status**: Approved (approach + verification mode confirmed)
- **Scope**: Entire `kmsg` Swift target, largest files first
- **Hard constraint**: Zero penalty to functionality or performance — every change is either *mechanical* (cannot change behavior) or *low-risk* (behavior-preserving by construction, verified)

## 1. Goal

Improve the maintainability of the `kmsg` codebase (KakaoTalk automation via macOS Accessibility APIs, ~9,700 LOC, 28 files, no automated Swift test suite) across four user-requested goals, **without any observable behavior or performance change**:

1. Decompose large files into focused units.
2. Remove duplication.
3. Fix naming / readability.
4. Improve type-safety / concurrency (documentation + mechanical fixes only; behavioral annotations deferred).

## 2. Approach

**Approach A — Safe full sweep, sequenced low-risk-first.** Work proceeds in waves so that each phase is independently buildable and verifiable, and confidence accumulates before any change that is even adjacent to control flow:

- **Wave A (mechanical)**: shared primitives that are byte-for-byte equivalent substitutions and named-constant extraction. Touches identifiers and literals only — never order or values.
- **Wave B (low-risk decomposition)**: pure code-move splitting of the five largest files; consolidation of the dedup family, metadata/regex tokenizer, command bootstrap, and JSON-output helpers — preserving every verified semantic divergence.
- **Wave C (deferred)**: control-flow clusters, concurrency annotations, error-taxonomy unification — **out of scope** for this effort; require explicit sign-off (see §6).

## 3. Hard Invariants (never change)

Preserved EXACTLY throughout:

- Every `limit:` / `maxNodes:` AX-traversal budget.
- Every scoring tier value and ratio.
- Every `Thread.sleep` interval, `waitUntil(timeout:pollInterval:evaluateAfterTimeout:)` parameter, retry count, and fallback ordering.
- All stdout/stderr/JSON output **byte** format: JSON encoder flags (incl. per-site `.withoutEscapingSlashes`), plain-text `author:/time:/body:` triples, `[system]` / `[trace-ax]` prefixes, MCP `Content-Length` framing + `fwrite`/`fflush` ordering, ISO8601 status, exit codes, and all error-message strings (esp. MCP error codes consumed by clients).
- AX-identity dedup stays **O(n²) CFEqual-keyed** — no `Set`/`Hashable` (CFEqual identity is not hash-stable; switching would silently change which duplicates collapse).
- `TranscriptReader` FrameCache CFEqual (~line 1040) compares a raw `AXUIElement`, **not** a `UIElement` — explicitly excluded from the `isSameElement` migration.

## 4. Phased Plan

### Phase 0 — Baseline capture & golden-output harness
Establish a no-regression oracle before any edit.
- Confirm clean baseline: `swift build` and `swift build -c release`. Record the exact warning set as a signal baseline.
- Capture golden stdout **and** stderr (separately) from the debug binary against a live KakaoTalk session into a scratch dir (NOT committed): `status --verbose`, `inspect --depth 5`, `inspect --depth 5 --debug`, `chats --verbose --limit 20`, `chats --json --limit 20`, `read "<chat>" --limit 50` (+ `--json`), `send "<chat>" "hi" --dry-run`.
- Capture MCP framing golden: a canned `initialize` + `tools/list` + `tools/call kmsg_read` JSON-RPC sequence, raw bytes incl. `Content-Length` headers.
- Capture `cache export` JSON shape + ISO8601 status format.
- **Verify**: all artifacts saved; both builds green. No source changed.

### Phase 1 — `UIElement.isSameElement` consolidation (mechanical)
Replace 11 `CFEqual(lhs.axElement, rhs.axElement)` sites across 10 files behind one method.
- Add `func isSameElement(_ other: UIElement) -> Bool { CFEqual(axElement, other.axElement) }` (safe: `axElement` is non-optional `public let`).
- Replace the 5 private `areSameAXElement` defs (MessageContextResolver, ChatWindowResolver, SendCommand, SendImageCommand, CacheCommand) + `AXPathCache.isSameElement` + 4 inline closures (ChatsCommand, InspectCommand, ChatListScanner, TranscriptReader:973) + 2 inline in KakaoTalkAuthenticator (345, 381).
- **DO NOT TOUCH** TranscriptReader:1040 (FrameCache, raw AXUIElement).
- Remove only newly-orphaned private decls.
- **Verify**: build clean, no new warnings; golden re-run byte-identical; `grep CFEqual` shows exactly the 1 FrameCache site + the 1 new def.

### Phase 2 — Stringly-typed constants & trivial AX predicates (mechanical)
- Add `kAXSecureTextFieldRole` to AXConstants; replace 3 bare literals in KakaoTalkAuthenticator.
- Add `UIElement.isTextInputRole` (`role == kAXTextAreaRole || role == kAXTextFieldRole`); replace verified sites in MessageContextResolver/SendCommand/ChatWindowResolver/CacheCommand. **Authenticator keeps a separate `isLoginInputRole`** (superset incl. AXSecureTextField).
- Add `UIElement.isEditable` (`attributeOptional(kAXEditableAttribute) ?? false`); replace 12 verified sites.
- Add `throwIfAXError(_:)` helper; replace 6 `guard error == .success else { throw … }` two-liners in UIElement.
- **Verify**: build clean; goldens byte-identical; confirm each predicate preserves exact nil-handling.

### Phase 3 — Named-constant extraction for magic numbers (low risk, value-preserving)
- Per-file (not cross-file) private enums/constants for `limit:`/`maxNodes:` pairs, scoring tiers, and timing literals in TranscriptReader, ChatWindowResolver, SendCommand, MessageContextResolver, CacheCommand, KakaoTalkApp, AXActionRunner. Each constant equals the existing literal exactly.
- Call SITES stay structurally untouched — only the literal becomes a named reference.
- **Verify**: build clean; grep each constant's value against the original literal; re-run timing-sensitive goldens (send/read/chats/inspect).

### Phase 4 — Pure code-move decomposition of the 5 largest files (low risk)
Relocate cohesive method groups into `extension` files within the same module. Code MOVES only — no logic edits inside moved bodies.
- **TranscriptReader** → TimeParsing, MetadataTokenClassifier, BodyContentNormalizer, DuplicationHelper, +FrameCache; RowAnalyzer last (highest coupling).
- **ChatWindowResolver** → WindowResolutionStrategy, SearchProfiler, TextScoringEngine, AXElementUtilities, SearchFieldLocator, ChatWindowValidation. **EXCLUDE** SearchResultActivation (high-risk, stays).
- **SendCommand** → extract only provably logic-free helpers; defer search/recovery/input-resolution extracts.
- **MCPServerCommand** → JSONRPCServer (framing verbatim — no reorder of header/body/fflush), KmsgErrorMapper, KmsgArgumentParser, KmsgToolCallHandler.
- **KakaoTalkAuthenticator** → LoginFormResolver, PostLoginAcknowledgementHandler, UIElementSearchUtilities, ButtonScoringAndResolution. **Defer** BlindLoginSequence.
- After EACH single move: `swift build`. Never batch moves before a build. `git diff` must show only relocation + `extension` wrapper.
- **Verify**: per-move build clean; full golden re-run incl. MCP byte-stream; `wc -l` confirms decomposition without pulling in any deferred high-risk extract.

### Phase 5 — Dedup family + metadata/regex tokenizer consolidation (low risk, divergence-preserving)
- `[UIElement].deduplicatedByAXIdentity()` — EXACT existing O(n²) `contains(where: isSameElement)` scan. Replace 5 sites. Keep O(n²)/CFEqual.
- `dedupedPreservingOrder(by:)` String-keyed helper. Replace string variants. **EXCLUDE** `deduplicateMessagesPreservingOrder` from the empty-filter path (verified it lacks `guard !value.isEmpty`) — own variant or flag.
- Shared `MessageMetadataTokenizer` (extractTimeToken/isLikelyCountToken/isLikelySystemMetadataToken — byte-identical between TranscriptReader & InspectCommand). **PRESERVE the `metadataTokens` CRLF divergence**: shared fn takes pre-normalized text (or `replacingNewlines:` flag).
- Fold repeated time/date regex literals into named constants (character-identical).
- Unify dedup helper NAMES across files (call-site rename only, no logic change).
- **Verify**: build clean; re-run `read`/`read --json`/`inspect --debug` goldens (CRLF divergence trap) + chats/send.

### Phase 6 — Command bootstrap & JSON-output helpers (low risk)
- `ensureAccessibilityOrExit()` wrapping the throwing permission guard. Apply to 8 command files. **EXCLUDE** StatusCommand (uses `ensureGranted()` as a plain Bool).
- `setupCommand(traceAX:deepRecovery:)` factory for the runner/auth/resolver triple. **Preserve** SendCommand's dryRun fast-path exiting BEFORE permission/auth.
- `JSONOutputFormatter.encode<T>(_:escapingSlashes:)`. Preserve per-site `.withoutEscapingSlashes` (Read/Watch yes; Chats/CredentialStore no) and Read's FileHandle-write vs Chats' `print` mechanism.
- Leave auto-close window logic (depends on `openedViaSearch` + CFEqual title guards) unless a verbatim move.
- **Verify**: build clean; `read --json`/`chats --json`/`watch` goldens byte-identical incl. slash-escaping; `send --dry-run` still short-circuits; `cache export` JSON unchanged.

## 5. Verification Strategy

No automated Swift tests, so confidence is built from four independent signals, applied after EVERY phase (and after every file-move in Phase 4):

1. **Build as gate** — `swift build` after each atomic change; `swift build -c release` at each phase boundary. A failed build halts and triggers re-plan.
2. **Warnings as signal** — any NEW warning vs the Phase 0 baseline is a regression signal (orphaned private methods removed as part of consolidation are the expected exception).
3. **Golden-output smoke tests** — **live KakaoTalk verification confirmed available**. Re-run the Phase 0 commands against the same live state and diff for byte-equality. Tokenization-heavy (`read`/`inspect --debug`) and timing-heavy (`send`/search) goldens are the priority checks for Phases 3/5.
4. **Diff-review discipline** — every changed line traces to one of the four goals. Mechanical phases: only identifier substitution or literal→named-constant swaps. Code-move phases: only relocation + an `extension` wrapper. Each new constant grep-compared to its original literal.

## 6. Out of Scope / Deferred (require explicit sign-off)

- Adding an automated test suite.
- Changing any AX budget, scoring value, sleep/poll interval, `evaluateAfterTimeout` polarity, retry count, or fallback ordering (only their NAMING is in scope).
- Any output-format change (JSON flags, plain-text layout, prefixes, MCP framing, exit codes, error strings).
- Switching AX-identity dedup to `Set`/`Hashable`.
- Concurrency model changes — `@MainActor`/Sendable behavioral annotations, async/await conversion of polling. (Documentation comments clarifying thread assumptions are allowed.)
- Error-taxonomy unification into a single `KmsgError`.
- High-risk control-flow clusters: SearchResultActivation (AXPress→AXConfirm→AXSelected→Enter fallback chain), `ChatIdentityRegistry.assignChatIDs`, BlindLoginSequence, SendCommand input/search resolution, KakaoTalkApp WindowRecovery.
- Performance "optimizations" (regex pre-compile, Calendar caching) — they alter timing/allocation.
- New features/flags/abstractions; renaming public-facing flags (`deepRecovery`, `keepWindow`, `traceAX`) pending confirmation nothing external depends on them.
- "Improving" or deleting pre-existing dead code (mention only).

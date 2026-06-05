# kmsg Behavior-Preserving Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve the maintainability of the kmsg Swift CLI — decompose the largest files, remove duplication, fix naming/readability, and apply mechanical type-safety fixes — with ZERO change to observable behavior or performance.

**Architecture:** Work is sequenced low-risk-first. Wave A (Phases 1-3) introduces shared primitives and named constants that are byte-for-byte equivalent substitutions and therefore cannot change behavior. Wave B (Phases 4-6) is pure code-move decomposition plus helper consolidation that is behavior-preserving by construction. High-risk control-flow, concurrency-annotation, and error-taxonomy work is intentionally OUT OF SCOPE (see spec section 6).

**Tech Stack:** Swift, Swift Package Manager, swift-argument-parser, macOS Accessibility (`AXUIElement`). No automated Swift test suite — verification is `swift build` + a warning baseline + live-KakaoTalk golden-output byte-diffing + diff-review discipline.

**Spec:** `docs/superpowers/specs/2026-06-06-kmsg-refactor-design.md`

---

## How to use this plan

- **Run phases in order.** Each phase is independently buildable and verifiable. Do not start a phase before the previous one is fully committed.
- **Line numbers drift.** Every phase edits files that later phases also touch, so absolute line numbers in later tasks WILL shift. Always re-locate an edit by its enclosing function/symbol name and the unique snippet shown — never by the cited line number alone (line numbers are orientation only, accurate as of drafting).
- **Earlier phases are baked in — never revert them (IMPORTANT).** All phase task sections were drafted in parallel from the *original* source, so a code snippet in a later phase (especially Phases 4–6) may show the *pre-transformation* form of a line that an earlier phase already changed — e.g. it may print `CFEqual(a.axElement, b.axElement)` (Phase 1 replaced this with `a.isSameElement(b)`), the bare literal `"AXSecureTextField"` (Phase 2 replaced this with `kAXSecureTextFieldRole`), `attributeOptional(kAXEditableAttribute) ?? false` (Phase 2 → `.isEditable`), or a raw magic number (Phase 3 → a named constant). When you reach a later phase the file already contains the *transformed* form. **Always move/edit the CURRENT code; never rewrite a line back to a stale snippet to "match" the plan.** The snippets exist to locate code and show structure — not to undo a prior phase. A "move verbatim" / "leave as-is" directive means *as the code currently exists after prior phases*, not as printed in the snippet. Likewise, anchor descriptions that mention an old name (e.g. "the loop that uses `areSameAXElement`") identify the method by its role even if Phase 1 already renamed the inner call — match by function signature and call sites.
- **Commits:** Conventional Commits, type `refactor`, with a module scope (e.g. `refactor(send): ...`). Never `git add .` or `git add -A` — stage explicit paths only. Never `--no-verify`.
- **Hard invariants (never change):** every `limit:`/`maxNodes:` budget, scoring tier value/ratio, `Thread.sleep` interval, `waitUntil` timeout/pollInterval/`evaluateAfterTimeout`, retry count, fallback ordering, and every byte of stdout/stderr/JSON/MCP-framing output. AX-identity dedup stays O(n^2) CFEqual-keyed (never `Set`/`Hashable`).

---

## Verification Protocol (applies to every task's "GOLDEN" step)

Because there is no test suite and the live KakaoTalk session drifts over time (new messages change `read`/`chats`/`watch` output independently of any code change), use the right check per command:

**1. Build gate (every code change).** `swift build` must end in `Build complete!` (exit 0). Then confirm no NEW warning vs `/tmp/kmsg-golden-baseline/warnings.txt` — an incremental build re-emits warnings for the file you just changed, so any warning it prints must already be in the baseline. Orphaned private methods you intentionally removed are the expected exception.

**2a. Stable-output commands → diff vs frozen Phase-0 golden.** For commands whose output does NOT depend on live chat content — `status`, `inspect` (static UI), `send --dry-run`, `cache export`, and the MCP `initialize`/`tools/list` framing — diff directly against `/tmp/kmsg-golden-baseline/<name>.out` and `.err`. Expect empty diffs.

**2b. Content-dependent commands → back-to-back prev-vs-new diff.** For `read`, `chats --verbose/--json`, and `watch` (output reflects live messages), the frozen golden may legitimately drift. Instead isolate the code change:

```bash
# At the START of each task that will be verified with a content-dependent command:
cp .build/debug/kmsg /tmp/kmsg-prev      # snapshot the known-good (pre-change) binary

# After the edit + successful `swift build`, run BOTH back-to-back on the same quiet session:
/tmp/kmsg-prev      read "테헤란로 죽돌이" --limit 50 > /tmp/prev.out 2> /tmp/prev.err
.build/debug/kmsg   read "테헤란로 죽돌이" --limit 50 > /tmp/new.out  2> /tmp/new.err
diff /tmp/prev.out /tmp/new.out && diff /tmp/prev.err /tmp/new.err
# Expected: empty diffs. Only verify while the conversation is quiet (no messages arriving
# between the two runs); re-run if a message lands mid-check.
```

A per-task "GOLDEN" step that names a content-dependent command (`read`/`chats`/`watch`) should be executed via the prev-vs-new method above; one that names a stable command uses the frozen golden. When in doubt, prev-vs-new is always safe.

**3. Diff discipline (every code change).** `git diff` must show ONLY: identifier substitution (mechanical), literal-to-named-constant swaps (Phase 3), helper-call substitution (Phases 1-2,5-6), or pure relocation + an `extension` wrapper (Phase 4). Never a reordered token inside a moved body, never a changed numeric value.

---

## Phase 0 - Baseline capture & golden-output harness

**Goal:** Establish a reproducible no-regression oracle BEFORE any edit. No source changes here.

**Aggregate risk:** none (read-only baseline)

> Goldens live in `/tmp/kmsg-golden-baseline/` (scratch, NOT committed). Capture against a live, logged-in KakaoTalk session with Accessibility permission granted. Known test chat: `테헤란로 죽돌이`.

### Task 0.1: Clean build + warning baseline

**Files:** none (read-only)

- [ ] **Step 1: Create scratch dir.** Run: `mkdir -p /tmp/kmsg-golden-baseline`

- [ ] **Step 2: Clean debug build.** Run: `swift build 2>&1 | tee /tmp/kmsg-golden-baseline/build_debug.log` | Expected: ends `Build complete!` (exit 0).

- [ ] **Step 3: Full release build to surface all warnings.** Run: `rm -rf .build/release && swift build -c release 2>&1 | tee /tmp/kmsg-golden-baseline/build_release.log` | Expected: ends `Build complete!`.

- [ ] **Step 4: Record the warning baseline.** Run: `grep -E "warning:" /tmp/kmsg-golden-baseline/build_release.log | sort -u > /tmp/kmsg-golden-baseline/warnings.txt; wc -l < /tmp/kmsg-golden-baseline/warnings.txt` | Expected: prints the count of current warnings (possibly 0). This file is the regression signal for every later build.

### Task 0.2: Capture CLI golden outputs

**Files:** none (read-only)

- [ ] **Step 1: Confirm the test chat is reachable.** Run: `.build/debug/kmsg chats --limit 20` and confirm `테헤란로 죽돌이` (or your chosen chat) appears. If not, pick a chat that does and use it consistently for all `read`/`send` goldens.

- [ ] **Step 2: Capture stable + content goldens (stdout and stderr separately).** Run:

```bash
G=/tmp/kmsg-golden-baseline
B=.build/debug/kmsg
$B status --verbose                                        > $G/status.out         2> $G/status.err
$B inspect --depth 5                                       > $G/inspect5.out       2> $G/inspect5.err
$B inspect --depth 5 --debug                               > $G/inspect5_debug.out 2> $G/inspect5_debug.err
$B chats --verbose --limit 20                              > $G/chats.out          2> $G/chats.err
$B chats --json --limit 20                                 > $G/chats_json.out     2> $G/chats_json.err
$B read "테헤란로 죽돌이" --limit 50                          > $G/read.out           2> $G/read.err
$B read "테헤란로 죽돌이" --limit 50 --json                   > $G/read_json.out      2> $G/read_json.err
$B send "테헤란로 죽돌이" "verification ping" --dry-run        > $G/send_dryrun.out    2> $G/send_dryrun.err
$B cache export $G/cache_export.json                       > $G/cache_export.out   2> $G/cache_export.err
```
Expected: each `.out` contains real content (not an error message). Spot-check `read.out` and `chats.out` are non-empty and well-formed.

- [ ] **Step 3: Determinism note.** `read`/`chats` reflect live chat state. These goldens are only valid while the session is quiet; per the Verification Protocol, content-dependent commands are verified prev-vs-new, so a drifting frozen golden is acceptable. The stable goldens (`status`, `inspect5*`, `send_dryrun`, `cache_export`) should be reproducible immediately.

### Task 0.3: Capture MCP JSON-RPC framing golden

**Files:** none (read-only)

- [ ] **Step 1: Frame a deterministic protocol sequence and capture raw bytes.** `tools/call` hits live UI (non-deterministic) so it is EXCLUDED; `initialize` + `tools/list` fully exercise the Content-Length framing and JSON shape. Run:

```bash
G=/tmp/kmsg-golden-baseline
python3 - "$G/mcp.bytes" <<'PY'
import subprocess, sys, json
msgs = [
    {"jsonrpc":"2.0","id":1,"method":"initialize",
     "params":{"protocolVersion":"2024-11-05","capabilities":{},
               "clientInfo":{"name":"golden","version":"0"}}},
    {"jsonrpc":"2.0","method":"notifications/initialized"},
    {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}},
]
payload = b"".join(
    f"Content-Length: {len(b)}

".encode() + b
    for b in (json.dumps(m).encode() for m in msgs)
)
out = subprocess.run([".build/debug/kmsg","mcp-server"], input=payload,
                     capture_output=True, timeout=30).stdout
open(sys.argv[1],"wb").write(out)
print(f"captured {len(out)} bytes")
PY
```
Expected: prints a positive byte count; `$G/mcp.bytes` contains `Content-Length:` headers followed by JSON-RPC responses for `initialize` and `tools/list`. (If the server name in `kmsg --help` differs from `mcp-server`, adjust.)

### Task 0.4: Confirm baseline complete

**Files:** none (read-only)

- [ ] **Step 1: List captured goldens.** Run: `ls -la /tmp/kmsg-golden-baseline/` | Expected: `warnings.txt`, `build_*.log`, and the `*.out`/`*.err`/`mcp.bytes` artifacts all present. No source files changed (`git status --short` is empty). Baseline established; proceed to Phase 1.



---

## Phase 1 — UIElement.isSameElement consolidation

**Goal:** Replace every two-`UIElement` `CFEqual(lhs.axElement, rhs.axElement)` site with a single canonical `a.isSameElement(b)` helper, removing the per-file/per-type duplicate predicates this makes unused.

**Aggregate risk:** mechanical

> Site inventory (11 logical CFEqual-on-two-UIElements sites across 10 files; the FrameCache site is deliberately excluded):
> 1. `AXPathCache.swift` — `AXPathResolver.isSameElement(_:_:)` static (callers: `buildPath` lines 310, 316, 330)
> 2. `CacheCommand.swift` — `warmupSameElement(_:_:)` (callers: `locateWarmupMessageInput` line 271, `warmupWindowWasPresent` line 396)
> 3. `ChatsCommand.swift` — inline in `run()` (line 53)
> 4. `InspectCommand.swift` — inline in `compactPath(for:maxHops:)` (line 362)
> 5. `SendCommand.swift` — `areSameAXElement(_:_:)` (callers: `closeWindowsIfNeeded` line 741, `resolveMessageInputField` line 781, `deduplicateCandidates` line 866)
> 6. `SendImageCommand.swift` — `areSameAXElement(_:_:)` (callers: `closeWindowsIfNeeded` line 138, `windowContainsElement` line 183)
> 7. `ChatListScanner.swift` — inline in `deduplicateElements(_:)` (line 288)
> 8. `ChatWindowResolver.swift` — `areSameAXElement(_:_:)` (callers: `deduplicateSearchCandidates` line 855, `deduplicateElements` line 873, `waitForWindowClosed` line 969)
> 9. `MessageContextResolver.swift` — `areSameAXElement(_:_:)` (callers: `resolveMessageInputField` line 72, `deduplicateElements` line 467)
> 10. `TranscriptReader.swift` — inline in `deduplicateElements(_:)` (line 973)
> 11. `KakaoTalkAuthenticator.swift` — inline in `appendUnique(_:to:)` (line 345) AND inline in `buildLoginForm(from:)` (line 381) — two sites in one file
>
> EXCLUDED: `TranscriptReader.swift` `FrameCache.frame(of:)` (line 1040) compares a raw stored `AXUIElement` (`entries[idx].element`) against `element.axElement` — NOT two `UIElement`s. It stays untouched.

---

### Task 1.1: Create UIElement+Identity.swift

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement+Identity.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement+Identity.swift`

- [ ] **Step 1: Create the new file with the exact canonical helper.** Write `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement+Identity.swift` with EXACTLY this content (`axElement` is non-optional `public let axElement: AXUIElement`, so no optional handling is needed):

```swift
import ApplicationServices.HIServices

extension UIElement {
    func isSameElement(_ other: UIElement) -> Bool { CFEqual(axElement, other.axElement) }
}
```

- [ ] **Step 2: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs baseline at `/tmp/kmsg-golden-baseline/warnings.txt`. (At this point `isSameElement` is defined but only used by the new extension — no callers migrated yet, so build must still succeed.)

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff --stat` and confirm the ONLY change is the new untracked file `Sources/kmsg/Accessibility/UIElement+Identity.swift` (one addition, no edits to existing files).

- [ ] **Step 4: COMMIT.** Run:
  - `git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement+Identity.swift`
  - `git commit -m "refactor(accessibility): add UIElement.isSameElement identity helper"`

---

### Task 1.2: Migrate AXPathCache.swift (AXPathResolver.isSameElement)

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/AXPathCache.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/AXPathCache.swift`

- [ ] **Step 1: Migrate caller in `buildPath(from:to:)` — the `while` loop break (current line 310).** Anchor: the `while let current = cursor` loop appending `lineage`.

```swift
        while let current = cursor {
            lineage.append(current)
            if current.isSameElement(root) {
                break
            }
            cursor = current.parent
        }
```

- [ ] **Step 2: Migrate caller in `buildPath(from:to:)` — the reached-root guard (current line 316).** Anchor: `guard let reachedRoot = lineage.last`.

```swift
        guard let reachedRoot = lineage.last, reachedRoot.isSameElement(root) else {
            return nil
        }
```

- [ ] **Step 3: Migrate caller in `buildPath(from:to:)` — the `firstIndex(where:)` child match (current line 330).** Anchor: `guard let childIndex = children.firstIndex(where:`.

```swift
            guard let childIndex = children.firstIndex(where: { $0.isSameElement(child) }) else {
                return nil
            }
```

- [ ] **Step 4: Remove the now-unused private static helper (current lines 418-420).** This declaration becomes unused after Steps 1-3. Delete EXACTLY:

```swift
    private static func isSameElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
```

- [ ] **Step 5: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 6: GOLDEN.** AXPathCache feeds the cache resolve/remember path exercised by `chats` and `send --dry-run` (dry-run does not touch live UI but exercises arg parsing) and the cache export. Re-run the cache export golden and the chats golden:
  - `.build/debug/kmsg cache export /tmp/check_cache.json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/cache_export.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/cache_export.err /tmp/check.err`
  - `.build/debug/kmsg chats --verbose --limit 20 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.err`
  - Expected: empty diffs (byte-identical).

- [ ] **Step 7: DIFF-DISCIPLINE.** Run: `git diff /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/AXPathCache.swift` and confirm the change is ONLY identifier substitution (`isSameElement(current, root)` → `current.isSameElement(root)`, etc.) plus deletion of the unused private static helper — no token reordering, no value change.

- [ ] **Step 8: COMMIT.** Run:
  - `git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/AXPathCache.swift`
  - `git commit -m "refactor(cache): route AXPathResolver identity checks through UIElement.isSameElement"`

---

### Task 1.3: Migrate CacheCommand.swift (warmupSameElement)

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CacheCommand.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CacheCommand.swift`

- [ ] **Step 1: Migrate caller in `locateWarmupMessageInput(in:kakao:runner:)` (current line 271).** Anchor: the `if let focusedWindow = kakao.focusedWindow, !warmupSameElement(...)` guard.

```swift
    if let focusedWindow = kakao.focusedWindow, !root.isSameElement(focusedWindow) {
        candidates.append(contentsOf: collectWarmupInputCandidates(from: focusedWindow, limit: 70))
    }
```

- [ ] **Step 2: Migrate caller in `warmupWindowWasPresent(_:in:)` (current line 396).** Anchor: the `windows.contains { existing in` closure.

```swift
private func warmupWindowWasPresent(_ window: UIElement, in windows: [UIElement]) -> Bool {
    windows.contains { existing in
        existing.isSameElement(window)
    }
}
```

- [ ] **Step 3: Remove the now-unused file-private helper (current lines 389-391).** Delete EXACTLY:

```swift
private func warmupSameElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
    CFEqual(lhs.axElement, rhs.axElement)
}
```

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 5: GOLDEN.** `cache warmup` requires a live session and mutates UI, so use the read-only cache export golden as the safe proxy for this file's compilation/behavior, plus the status golden:
  - `.build/debug/kmsg cache export /tmp/check_cache.json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/cache_export.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/cache_export.err /tmp/check.err`
  - `.build/debug/kmsg status --verbose > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/status.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check.err`
  - Expected: empty diffs (byte-identical).

- [ ] **Step 6: DIFF-DISCIPLINE.** Run: `git diff /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CacheCommand.swift` and confirm the change is ONLY identifier substitution (`warmupSameElement(root, focusedWindow)` → `root.isSameElement(focusedWindow)`, `warmupSameElement(existing, window)` → `existing.isSameElement(window)`) plus deletion of the unused file-private helper — no token reordering, no value change.

- [ ] **Step 7: COMMIT.** Run:
  - `git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CacheCommand.swift`
  - `git commit -m "refactor(cache): replace warmupSameElement with UIElement.isSameElement"`

---

### Task 1.4: Migrate ChatsCommand.swift and InspectCommand.swift (inline sites)

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/ChatsCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/InspectCommand.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/ChatsCommand.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/InspectCommand.swift`

- [ ] **Step 1: Migrate inline site in `ChatsCommand.run()` (current line 53).** Anchor: the `autoOpenedWindow = !windowsBefore.contains(where:` assignment inside the `else if let fallback = kakao.ensureMainWindow` branch.

```swift
            autoOpenedWindow = !windowsBefore.contains(where: { existing in
                existing.isSameElement(fallback)
            })
```

- [ ] **Step 2: Migrate inline site in `InspectCommand.compactPath(for:maxHops:)` (current line 362).** Anchor: the `indexInParent = parent.children.firstIndex(where: { sibling in` computation.

```swift
                indexInParent = parent.children.firstIndex(where: { sibling in
                    sibling.isSameElement(node)
                }) ?? 0
```

- [ ] **Step 3: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 4: GOLDEN.** Re-run the goldens for both touched commands:
  - `.build/debug/kmsg chats --verbose --limit 20 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.err`
  - `.build/debug/kmsg chats --json --limit 20 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats_json.err /tmp/check.err`
  - `.build/debug/kmsg inspect --depth 5 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/inspect5.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/inspect5.err /tmp/check.err`
  - Expected: empty diffs (byte-identical). (The `compactPath` change only affects `inspect --show-path`/`--debug-layout` output; the plain `inspect5` golden must remain byte-identical regardless.)

- [ ] **Step 5: DIFF-DISCIPLINE.** Run: `git diff /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/ChatsCommand.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/InspectCommand.swift` and confirm BOTH changes are ONLY inline-expression substitution (`CFEqual(existing.axElement, fallback.axElement)` → `existing.isSameElement(fallback)`; `CFEqual(sibling.axElement, node.axElement)` → `sibling.isSameElement(node)`) — no token reordering, no value change, no helper added/removed.

- [ ] **Step 6: COMMIT.** Run:
  - `git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/ChatsCommand.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/InspectCommand.swift`
  - `git commit -m "refactor(commands): use UIElement.isSameElement for inline AX identity checks"`

---

### Task 1.5: Migrate SendCommand.swift (areSameAXElement, 3 callers)

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift`

- [ ] **Step 1: Migrate caller in `closeWindowsIfNeeded(resolution:kakao:resolver:runner:)` (current line 741).** Anchor: the `if let listWindow = kakao.chatListWindow, !areSameAXElement(listWindow, resolution.window)` guard.

```swift
        if let listWindow = kakao.chatListWindow,
           !listWindow.isSameElement(resolution.window)
        {
```

- [ ] **Step 2: Migrate caller in `resolveMessageInputField(chatWindow:kakao:runner:)` (current line 781).** Anchor: the `if !areSameAXElement(focusedWindow, chatWindow) {` guard that gates the `chatWindowCandidates` append.

```swift
                if !focusedWindow.isSameElement(chatWindow) {
                    let chatWindowCandidates = collectMessageInputCandidates(from: chatWindow, limit: attempt == 1 ? 36 : 60)
                    candidates.append(contentsOf: chatWindowCandidates)
                    runner.log("message input search attempt \(attempt): chatWindow candidates=\(chatWindowCandidates.count)")
                }
```

- [ ] **Step 3: Migrate caller in `deduplicateCandidates(_:)` (current line 866).** Anchor: the `if unique.contains(where: { areSameAXElement($0, candidate) }) {` guard.

```swift
            if unique.contains(where: { $0.isSameElement(candidate) }) {
                continue
            }
```

- [ ] **Step 4: Remove the now-unused private helper (current lines 874-876).** Delete EXACTLY:

```swift
    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
```

- [ ] **Step 5: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 6: GOLDEN.** Live send mutates the chat; use the `send --dry-run` golden (exercises this file's parsing/structure without sending) plus the `send_dryrun` golden name:
  - `.build/debug/kmsg send "테헤란로 죽돌이" "msg" --dry-run > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check.err`
  - Expected: empty diffs (byte-identical).

- [ ] **Step 7: DIFF-DISCIPLINE.** Run: `git diff /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift` and confirm the change is ONLY identifier substitution at the 3 call sites plus deletion of the unused private helper — no token reordering, no value change.

- [ ] **Step 8: COMMIT.** Run:
  - `git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift`
  - `git commit -m "refactor(send): replace areSameAXElement with UIElement.isSameElement"`

---

### Task 1.6: Migrate SendImageCommand.swift (areSameAXElement, 2 callers)

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendImageCommand.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendImageCommand.swift`

- [ ] **Step 1: Migrate caller in `closeWindowsIfNeeded(resolution:kakao:resolver:runner:)` (current line 138).** Anchor: the `if let listWindow = kakao.chatListWindow, !areSameAXElement(listWindow, resolution.window)` guard.

```swift
        if let listWindow = kakao.chatListWindow,
           !listWindow.isSameElement(resolution.window)
        {
```

- [ ] **Step 2: Migrate caller in `windowContainsElement(_:target:)` (current line 183).** Anchor: the `window.findFirst(where: { candidate in areSameAXElement(candidate, target) })` body.

```swift
    private func windowContainsElement(_ window: UIElement, target: UIElement) -> Bool {
        window.findFirst(where: { candidate in
            candidate.isSameElement(target)
        }) != nil
    }
```

- [ ] **Step 3: Remove the now-unused private helper (current lines 187-189).** Delete EXACTLY:

```swift
    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
```

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`. (No `send-image` golden exists and live send-image mutates the chat; the build gate plus diff-discipline are the verification for this purely-mechanical file. There is no read-only command path through `SendImageCommand`.)

- [ ] **Step 5: DIFF-DISCIPLINE.** Run: `git diff /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendImageCommand.swift` and confirm the change is ONLY identifier substitution at the 2 call sites plus deletion of the unused private helper — no token reordering, no value change.

- [ ] **Step 6: COMMIT.** Run:
  - `git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendImageCommand.swift`
  - `git commit -m "refactor(send-image): replace areSameAXElement with UIElement.isSameElement"`

---

### Task 1.7: Migrate ChatListScanner.swift (inline in deduplicateElements)

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatListScanner.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatListScanner.swift`

- [ ] **Step 1: Migrate inline site in `deduplicateElements(_:)` (current line 288).** Anchor: the `if unique.contains(where: { existing in CFEqual(existing.axElement, element.axElement) })` guard.

```swift
            if unique.contains(where: { existing in
                existing.isSameElement(element)
            }) {
                continue
            }
```

- [ ] **Step 2: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 3: GOLDEN.** `ChatListScanner` powers `chats`; re-run both chats goldens:
  - `.build/debug/kmsg chats --verbose --limit 20 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.err`
  - `.build/debug/kmsg chats --json --limit 20 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats_json.err /tmp/check.err`
  - Expected: empty diffs (byte-identical).

- [ ] **Step 4: DIFF-DISCIPLINE.** Run: `git diff /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatListScanner.swift` and confirm the change is ONLY inline-expression substitution (`CFEqual(existing.axElement, element.axElement)` → `existing.isSameElement(element)`) — no token reordering, no value change.

- [ ] **Step 5: COMMIT.** Run:
  - `git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatListScanner.swift`
  - `git commit -m "refactor(chats): use UIElement.isSameElement in ChatListScanner dedup"`

---

### Task 1.8: Migrate ChatWindowResolver.swift (areSameAXElement, 3 callers)

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`

- [ ] **Step 1: Migrate caller in `deduplicateSearchCandidates(_:)` (current line 855).** Anchor: the `if let index = unique.firstIndex(where: { existing in areSameAXElement(existing.element, candidate.element) })` guard.

```swift
            if let index = unique.firstIndex(where: { existing in
                existing.element.isSameElement(candidate.element)
            }) {
```

- [ ] **Step 2: Migrate caller in `deduplicateElements(_:)` (current line 873).** Anchor: the `if unique.contains(where: { existing in areSameAXElement(existing, element) })` guard.

```swift
            if unique.contains(where: { existing in
                existing.isSameElement(element)
            }) {
                continue
            }
```

- [ ] **Step 3: Migrate caller in `waitForWindowClosed(_:label:)` (current line 969).** Anchor: the `!kakao.windows.contains { candidate in areSameAXElement(candidate, window) }` body.

```swift
            !kakao.windows.contains { candidate in
                candidate.isSameElement(window)
            }
```

- [ ] **Step 4: Remove the now-unused private helper (current lines 974-976).** Delete EXACTLY:

```swift
    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
```

- [ ] **Step 5: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 6: GOLDEN.** `ChatWindowResolver` resolves the chat window used by `read`; re-run the read goldens against the known chat:
  - `.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err`
  - `.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.err`
  - Expected: empty diffs (byte-identical).

- [ ] **Step 7: DIFF-DISCIPLINE.** Run: `git diff /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift` and confirm the change is ONLY identifier substitution at the 3 call sites plus deletion of the unused private helper — no token reordering, no value change.

- [ ] **Step 8: COMMIT.** Run:
  - `git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
  - `git commit -m "refactor(window): replace areSameAXElement with UIElement.isSameElement"`

---

### Task 1.9: Migrate MessageContextResolver.swift (areSameAXElement, 2 callers)

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/MessageContextResolver.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/MessageContextResolver.swift`

- [ ] **Step 1: Migrate caller in `resolveMessageInputField(chatWindow:)` (current line 72).** Anchor: the `if !areSameAXElement(focusedWindow, chatWindow) {` guard inside the `attempt` loop.

```swift
                if !focusedWindow.isSameElement(chatWindow) {
                    let chatWindowCandidates = collectMessageInputCandidates(from: chatWindow, limit: attempt == 1 ? 36 : 60)
                    candidates.append(contentsOf: chatWindowCandidates)
                }
```

- [ ] **Step 2: Migrate caller in `deduplicateElements(_:)` (current line 467).** Anchor: the `if unique.contains(where: { areSameAXElement($0, candidate) }) {` guard.

```swift
            if unique.contains(where: { $0.isSameElement(candidate) }) {
                continue
            }
```

- [ ] **Step 3: Remove the now-unused private helper (current lines 475-477).** Delete EXACTLY:

```swift
    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
```

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 5: GOLDEN.** `MessageContextResolver` resolves the transcript context for `read`; re-run the read goldens:
  - `.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err`
  - `.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.err`
  - Expected: empty diffs (byte-identical).

- [ ] **Step 6: DIFF-DISCIPLINE.** Run: `git diff /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/MessageContextResolver.swift` and confirm the change is ONLY identifier substitution at the 2 call sites plus deletion of the unused private helper — no token reordering, no value change.

- [ ] **Step 7: COMMIT.** Run:
  - `git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/MessageContextResolver.swift`
  - `git commit -m "refactor(read): replace areSameAXElement with UIElement.isSameElement"`

---

### Task 1.10: Migrate TranscriptReader.swift (inline in deduplicateElements ONLY — FrameCache stays)

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`

- [ ] **Step 1: Migrate the ONE inline site in `deduplicateElements(_:)` (current line 973).** Anchor: the `let alreadySeen = buckets[hash]?.contains(where: { existing in CFEqual(existing.axElement, element.axElement) })` expression — this is inside the hash-bucketed dedup that compares two `UIElement`s.

```swift
            let alreadySeen = buckets[hash]?.contains(where: { existing in
                existing.isSameElement(element)
            }) ?? false
```

- [ ] **Step 2: CRITICAL EXCLUSION — do NOT touch `FrameCache.frame(of:)` (current line 1040).** That `CFEqual(entries[idx].element, element.axElement)` compares a raw stored `AXUIElement` (`entries[idx].element` is typed `AXUIElement`, not `UIElement`) against `element.axElement`. `isSameElement` takes a `UIElement` argument and cannot be applied here. LEAVE IT EXACTLY AS-IS:

```swift
                if CFEqual(entries[idx].element, element.axElement) {
                    return entries[idx].frame
                }
```

- [ ] **Step 3: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 4: GOLDEN.** `TranscriptReader` produces the `read` output (text and JSON); re-run both read goldens — these exercise both the migrated dedup AND the untouched FrameCache path:
  - `.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err`
  - `.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.err`
  - Expected: empty diffs (byte-identical).

- [ ] **Step 5: DIFF-DISCIPLINE.** Run: `git diff /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift` and confirm the change is EXACTLY ONE inline-expression substitution in `deduplicateElements` (`CFEqual(existing.axElement, element.axElement)` → `existing.isSameElement(element)`) and that the `FrameCache` `CFEqual` line is UNCHANGED — no token reordering, no value change, no other lines touched.

- [ ] **Step 6: COMMIT.** Run:
  - `git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
  - `git commit -m "refactor(read): use UIElement.isSameElement in transcript dedup (FrameCache untouched)"`

---

### Task 1.11: Migrate KakaoTalkAuthenticator.swift (TWO inline sites)

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/KakaoTalkAuthenticator.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/KakaoTalkAuthenticator.swift`

- [ ] **Step 1: Migrate inline site in `appendUnique(_:to:)` (current line 345).** Anchor: the `guard !roots.contains(where: { CFEqual($0.axElement, candidate.axElement) }) else { return }` guard.

```swift
        guard !roots.contains(where: { $0.isSameElement(candidate) }) else { return }
```

- [ ] **Step 2: Migrate inline site in `buildLoginForm(from:)` (current line 381).** Anchor: the `guard let passwordField = sortedInputs.first(where: { candidate in !CFEqual(candidate.axElement, usernameField.axElement) && looksLikePasswordField(candidate) })` expression.

```swift
        guard let passwordField = sortedInputs.first(where: { candidate in
            !candidate.isSameElement(usernameField) && looksLikePasswordField(candidate)
        }) ?? sortedInputs.dropFirst().first else {
            return nil
        }
```

- [ ] **Step 3: NO HELPER REMOVAL / NO PREDICATE ROUTING.** This file has NO private `areSameAXElement`/`isSameElement` to delete — both sites are inline. Do NOT touch `looksLikePasswordField`, `isLikelyLoginWindow`, `buildLoginForm`'s `"AXSecureTextField"` role checks, or any `isLoginInputRole`-style predicate. Per confirmed facts, KakaoTalkAuthenticator keeps its OWN superset login-input predicate; this task is purely the two `CFEqual` identity substitutions.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 5: GOLDEN.** Auth runs as the bootstrap before every authenticated command (`chats`, `read`); login itself cannot be golden-diffed without logging out, so use the already-authenticated `status` and `chats` paths (which traverse `appendUnique`-built root lists during the `isAuthenticated()` window probe) as the proxy:
  - `.build/debug/kmsg status --verbose > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/status.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check.err`
  - `.build/debug/kmsg chats --verbose --limit 20 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.err`
  - Expected: empty diffs (byte-identical).

- [ ] **Step 6: DIFF-DISCIPLINE.** Run: `git diff /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/KakaoTalkAuthenticator.swift` and confirm the change is EXACTLY the two inline substitutions (`CFEqual($0.axElement, candidate.axElement)` → `$0.isSameElement(candidate)`; `CFEqual(candidate.axElement, usernameField.axElement)` → `candidate.isSameElement(usernameField)`) — no token reordering, no value change, no predicate routing, no helper added/removed.

- [ ] **Step 7: COMMIT.** Run:
  - `git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/KakaoTalkAuthenticator.swift`
  - `git commit -m "refactor(auth): use UIElement.isSameElement for login element identity checks"`

---

### Task 1.12: Final assertion — only FrameCache CFEqual + the new definition remain

**Files:**
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg`

- [ ] **Step 1: Grep for all remaining `CFEqual` in Sources.** Run:
  - `grep -rn "CFEqual" /Volumes/990EVO+/workspace/chann/kmsg/Sources`
  - Expected: EXACTLY 2 hits —
    1. `Sources/kmsg/Accessibility/UIElement+Identity.swift` — the new canonical definition `CFEqual(axElement, other.axElement)`
    2. `Sources/kmsg/KakaoTalk/TranscriptReader.swift` — the FrameCache site `CFEqual(entries[idx].element, element.axElement)`
  - If any other `CFEqual` remains, a migration site was missed — STOP and re-plan.

- [ ] **Step 2: Grep for residual per-file identity helpers.** Run:
  - `grep -rn "areSameAXElement\|warmupSameElement\|func isSameElement" /Volumes/990EVO+/workspace/chann/kmsg/Sources`
  - Expected: EXACTLY 1 hit — the `func isSameElement(_ other: UIElement)` declaration in `UIElement+Identity.swift`. No `areSameAXElement`, no `warmupSameElement`, no `AXPathResolver.isSameElement` remain.

- [ ] **Step 3: Final BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 4: Confirm clean tree (all prior tasks committed).** Run: `git status --porcelain` | Expected: empty output (every migration already committed in Tasks 1.1-1.11; this task adds no code and therefore no commit).

---

## Phase 2 — Stringly-typed constants & trivial AX predicates

**Goal:** Replace bare AX role literals and repeated inline AX predicates/guards with the canonical named constant and helper extensions introduced in this phase, with zero behavioral change.
**Aggregate risk:** mechanical

---

### Task 2.1: Add `kAXSecureTextFieldRole` constant and replace bare "AXSecureTextField" literals

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/AXConstants.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/KakaoTalkAuthenticator.swift`
- Verify (build): `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement.swift`

- [ ] **Step 1: Add the constant to AXConstants.swift.** Anchor on the trailing attribute-key block (currently lines 34-35: `kAXEditableAttribute` / `kAXSheetsAttribute`). Insert the new role constant immediately after the role-constant group, before the blank line that precedes `kAXEditableAttribute`. Place it right after `kAXLinkRole` (line 32).

```swift
public let kAXLinkRole = "AXLink"
public let kAXSecureTextFieldRole = "AXSecureTextField"
```

- [ ] **Step 2: Replace literal in `KakaoTalkAuthenticator.buildLoginForm(from:)` (line 362).** Anchor on the `inputFields` predicate inside `buildLoginForm`.

```swift
        let inputFields = window.findAll(where: { element in
            let role = element.role ?? ""
            return element.isEnabled && (role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXSecureTextFieldRole)
        }, limit: 8, maxNodes: 240)
```

- [ ] **Step 3: Replace literal in `KakaoTalkAuthenticator.isLikelyLoginWindow(_:)` (line 415).** Anchor on the `inputs` predicate inside `isLikelyLoginWindow`.

```swift
        let inputs = window.findAll(where: { element in
            let role = element.role ?? ""
            return element.isEnabled && (role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXSecureTextFieldRole)
        }, limit: 6, maxNodes: 200)
```

- [ ] **Step 4: Replace literal in `KakaoTalkAuthenticator.looksLikePasswordField(_:)` (line 633).** Anchor on the early-return at the top of `looksLikePasswordField`.

```swift
    private func looksLikePasswordField(_ element: UIElement) -> Bool {
        let role = element.role ?? ""
        if role == kAXSecureTextFieldRole {
            return true
        }
```

- [ ] **Step 5: DIFF-DISCIPLINE.** Run: `git diff` | Confirm the only changes are: one added `public let` line in AXConstants.swift, and exactly 3 `"AXSecureTextField"` → `kAXSecureTextFieldRole` identifier swaps in KakaoTalkAuthenticator.swift. The `==` operand order, the `??` defaulting, and the surrounding `&&`/`||` structure are unchanged.

- [ ] **Step 6: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), no new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 7: GOLDEN (status).** The authenticator runs on the auth path exercised by `status`. Run:
```bash
.build/debug/kmsg status --verbose > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/status.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check.err
```
Expected: empty diff (byte-identical).

- [ ] **Step 8: COMMIT.** Run:
```bash
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/AXConstants.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/KakaoTalkAuthenticator.swift
git commit -m "refactor(auth): use kAXSecureTextFieldRole constant for secure field literals"
```

---

### Task 2.2: Create `UIElement+Roles.swift` with `isTextInputRole` and `isEditable`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement+Roles.swift`
- Verify (build): `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement.swift`

- [ ] **Step 1: Create the new file with the canonical helper.** Write `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement+Roles.swift` verbatim. (No import needed: `role`, `attributeOptional`, and the `kAX*` constants are all in-module; matches Phase 1's `UIElement+Identity.swift` pattern which only imported what it used.)

```swift
extension UIElement {
    var isTextInputRole: Bool { role == kAXTextAreaRole || role == kAXTextFieldRole }
    var isEditable: Bool { attributeOptional(kAXEditableAttribute) ?? false }
}
```

- [ ] **Step 2: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), no new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`. (This step proves the new file compiles before any call sites depend on it.)

- [ ] **Step 3: COMMIT.** Run:
```bash
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement+Roles.swift
git commit -m "refactor(accessibility): add UIElement isTextInputRole and isEditable helpers"
```

---

### Task 2.3: Replace `role == kAXTextAreaRole || role == kAXTextFieldRole` with `.isTextInputRole`

Each site below uses the exact form `<elem>.role == kAXTextAreaRole || <elem>.role == kAXTextFieldRole` on the optional `role` property — structurally identical to the canonical `isTextInputRole`. The CacheCommand:328 occurrence (`role == kAXTextFieldRole || role == kAXTextAreaRole` on a defaulted non-optional local `let role`) has DIFFERENT operand order and operand type and is intentionally OUT of scope — leave it as-is.

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/MessageContextResolver.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CacheCommand.swift`
- Verify (build): `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement+Roles.swift`

- [ ] **Step 1: `MessageContextResolver.collectMessageInputCandidates(from:limit:)` (line 311).** Anchor on the `roleCandidates` closure. Original returns `element.isEnabled && (role==area||role==field)` two-stage via `guard`/`return`; preserve the `guard element.isEnabled else { return false }` exactly.

```swift
        let roleCandidates = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            return element.isTextInputRole
        }, limit: limit, maxNodes: nodeBudget)
```

- [ ] **Step 2: `MessageContextResolver.collectFocusedElementLineageCandidates(_:)` (line 334).** Anchor on the `textDescendants` closure (uses `node`).

```swift
            let textDescendants = element.findAll(where: { node in
                guard node.isEnabled else { return false }
                return node.isTextInputRole
            }, limit: 8, maxNodes: 48)
```

- [ ] **Step 3: `SendCommand.collectMessageInputCandidates(from:limit:)` (line 829).** Anchor on the `roleCandidates` closure (uses `element`).

```swift
        let roleCandidates = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            return element.isTextInputRole
        }, limit: limit, maxNodes: nodeBudget)
```

- [ ] **Step 4: `SendCommand.collectFocusedElementLineageCandidates(_:)` (line 853).** Anchor on the `textDescendants` closure (uses `node`).

```swift
            let textDescendants = element.findAll(where: { node in
                guard node.isEnabled else { return false }
                return node.isTextInputRole
            }, limit: 8, maxNodes: 48)
```

- [ ] **Step 5: `CacheCommand.collectWarmupInputCandidates(from:limit:)` (line 288).** Anchor on the `roleCandidates` closure (uses `element`).

```swift
    let roleCandidates = root.findAll(where: { element in
        guard element.isEnabled else { return false }
        return element.isTextInputRole
    }, limit: limit, maxNodes: nodeBudget)
```

- [ ] **Step 6: DIFF-DISCIPLINE.** Run: `git diff` | Confirm every change is solely the substitution of `<elem>.role == kAXTextAreaRole || <elem>.role == kAXTextFieldRole` → `<elem>.isTextInputRole`. Confirm the `guard <elem>.isEnabled else { return false }` lines and all `limit:`/`maxNodes:` arguments are byte-unchanged. Explicitly confirm `CacheCommand.warmupWindowContainsLikelyChatInput` (line 328, `role == kAXTextFieldRole || role == kAXTextAreaRole`) was NOT touched.

- [ ] **Step 7: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), no new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 8: GOLDEN (send_dryrun, cache_export).** These call sites are on the send/warmup input-resolution paths. Run:
```bash
.build/debug/kmsg send "테헤란로 죽돌이" "test" --dry-run > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check.err
.build/debug/kmsg cache export /tmp/cache_check.json > /tmp/check2.out 2> /tmp/check2.err && diff /tmp/kmsg-golden-baseline/cache_export.out /tmp/check2.out && diff /tmp/kmsg-golden-baseline/cache_export.err /tmp/check2.err
```
Expected: empty diffs (byte-identical).

- [ ] **Step 9: COMMIT.** Run:
```bash
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/MessageContextResolver.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CacheCommand.swift
git commit -m "refactor(accessibility): use isTextInputRole for text-input role predicates"
```

---

### Task 2.4: Replace `attributeOptional(kAXEditableAttribute) ?? false` with `.isEditable` (12 sites)

All 12 sites are the exact form `let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false` (or the inline RHS in a `let editable:`/`let isEditable:` binding). The canonical `isEditable` reads `attributeOptional(kAXEditableAttribute) ?? false` — identical nil-handling (a `nil`/`.noValue`/type-mismatch result collapses to `false`). Substitute only the RHS expression; keep the binding name and its `: Bool` annotation so types stay explicit and behavior is identical.

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/MessageContextResolver.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CacheCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/InspectCommand.swift`
- Verify (build): `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement+Roles.swift`

- [ ] **Step 1: `MessageContextResolver.collectMessageInputCandidates(from:limit:)` — `editableCandidates` closure (line 315).** Anchor on the closure that returns `role != kAXStaticTextRole && role != kAXImageRole`.

```swift
        let editableCandidates = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            let editable: Bool = element.isEditable
            guard editable else { return false }
            let role = element.role ?? ""
            return role != kAXStaticTextRole && role != kAXImageRole
        }, limit: limit, maxNodes: nodeBudget)
```

- [ ] **Step 2: `MessageContextResolver.scoreMessageInputCandidate(_:in:)` (line 362).** Anchor on the `else` branch of the role-score `if`/`else if`/`else`.

```swift
        } else {
            let editable: Bool = element.isEditable
            roleScore = editable ? 6_000.0 : 0.0
        }
```

- [ ] **Step 3: `MessageContextResolver.isLikelyMessageInputElement(_:in:)` (line 398).** Anchor on the `guard editable else { return false }` that follows the `if role == kAXTextAreaRole { return true }` block.

```swift
        let editable: Bool = element.isEditable
        guard editable else { return false }
        guard role != kAXStaticTextRole && role != kAXImageRole else { return false }
```

- [ ] **Step 4: `SendCommand.isLikelyMessageInputElement(_:in:)` (line 608).** Anchor on the same `guard editable` pattern in SendCommand's copy (preceded by `if role == kAXTextAreaRole { return true }`).

```swift
        let editable: Bool = element.isEditable
        guard editable else { return false }
        guard role != kAXStaticTextRole && role != kAXImageRole else { return false }
        if role == kAXTextFieldRole && isLikelySearchField(element, in: window) {
```

- [ ] **Step 5: `SendCommand.collectMessageInputCandidates(from:limit:)` — `editableCandidates` closure (line 834).** Anchor on the closure with `role != kAXStaticTextRole && role != kAXImageRole`.

```swift
        let editableCandidates = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            let editable: Bool = element.isEditable
            guard editable else { return false }
            let role = element.role ?? ""
            return role != kAXStaticTextRole && role != kAXImageRole
        }, limit: limit, maxNodes: nodeBudget)
```

- [ ] **Step 6: `SendCommand.scoreMessageInputCandidate(_:in:)` (line 927).** Anchor on the `else` branch of the role-score chain.

```swift
        } else {
            let editable: Bool = element.isEditable
            roleScore = editable ? 6_000.0 : 0.0
        }
        let yScore = Double(element.position?.y ?? 0)
```

- [ ] **Step 7: `ChatWindowResolver.isLikelyMessageInputElement(_:in:)` (line 501).** Anchor on the `guard editable` pattern preceded by `if role == kAXTextAreaRole { return true }`.

```swift
        let editable: Bool = element.isEditable
        guard editable else { return false }
        guard role != kAXStaticTextRole && role != kAXImageRole else { return false }
        if role == kAXTextFieldRole, isLikelySearchField(element, in: window) {
```

- [ ] **Step 8: `CacheCommand.collectWarmupInputCandidates(from:limit:)` — `editableCandidates` closure (line 293).** Anchor on the closure with `role != kAXStaticTextRole && role != kAXImageRole`.

```swift
    let editableCandidates = root.findAll(where: { element in
        guard element.isEnabled else { return false }
        let editable: Bool = element.isEditable
        guard editable else { return false }
        let role = element.role ?? ""
        return role != kAXStaticTextRole && role != kAXImageRole
    }, limit: limit, maxNodes: nodeBudget)
```

- [ ] **Step 9: `CacheCommand.warmupWindowContainsLikelyChatInput(_:)` (line 326).** Anchor on the second `findFirst` closure (the one defaulting `let editable: Bool` then returning `role == kAXTextFieldRole || role == kAXTextAreaRole`).

```swift
    return window.findFirst(where: { element in
        guard element.isEnabled else { return false }
        let role = element.role ?? ""
        let editable: Bool = element.isEditable
        guard editable else { return false }
        return role == kAXTextFieldRole || role == kAXTextAreaRole
    }) != nil
```

- [ ] **Step 10: `CacheCommand.warmupIsLikelyMessageInput(_:window:)` (line 339).** Anchor on the `guard editable` pattern preceded by `if role == kAXTextAreaRole { return true }`.

```swift
    let editable: Bool = element.isEditable
    guard editable else { return false }
    guard role != kAXStaticTextRole && role != kAXImageRole else { return false }
    if role == kAXTextFieldRole && warmupLooksLikeSearchField(element, window: window) {
```

- [ ] **Step 11: `CacheCommand.warmupInputScore(_:window:)` (line 379).** Anchor on the `else` branch of the role-score chain.

```swift
    } else {
        let editable: Bool = element.isEditable
        roleScore = editable ? 6_000.0 : 0.0
    }
```

- [ ] **Step 12: `InspectCommand.elementStateFlags(_:)` (line 203).** Anchor on the `isEditable` local that gates the `"editable"` flag append. Keep the local binding name `isEditable` (matches the existing `isSelected` style above it).

```swift
        let isEditable: Bool = element.isEditable
        if isEditable {
            flags.append("editable")
        }
```

- [ ] **Step 13: DIFF-DISCIPLINE.** Run: `git diff` | Confirm all 12 changes are solely RHS substitutions `attributeOptional(kAXEditableAttribute) ?? false` → `isEditable`. The `let editable: Bool` / `let isEditable: Bool` binding names, the `?? false` collapsed into the helper, the subsequent `guard editable`/`if isEditable`, and all surrounding role checks are otherwise byte-identical. Confirm no `kAXEditableAttribute` reference remains in these 12 spots (the constant itself stays declared in AXConstants.swift and referenced by the helper).

- [ ] **Step 14: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), no new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 15: GOLDEN (inspect5_debug, send_dryrun, cache_export).** `elementStateFlags` is exercised by `--debug-layout`; the message-input scorers by send/warmup. Run:
```bash
.build/debug/kmsg inspect --depth 5 --debug-layout > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/inspect5_debug.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/inspect5_debug.err /tmp/check.err
.build/debug/kmsg send "테헤란로 죽돌이" "test" --dry-run > /tmp/check2.out 2> /tmp/check2.err && diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check2.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check2.err
.build/debug/kmsg cache export /tmp/cache_check.json > /tmp/check3.out 2> /tmp/check3.err && diff /tmp/kmsg-golden-baseline/cache_export.out /tmp/check3.out && diff /tmp/kmsg-golden-baseline/cache_export.err /tmp/check3.err
```
Expected: empty diffs (byte-identical).

- [ ] **Step 16: COMMIT.** Run:
```bash
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/MessageContextResolver.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CacheCommand.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/InspectCommand.swift
git commit -m "refactor(accessibility): use isEditable helper for AXEditable predicates"
```

---

### Task 2.5: Add `throwIfAXError` and migrate the 5 simple AX-error guards in UIElement

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/AXError+Extension.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement.swift`

- [ ] **Step 1: Add `throwIfAXError` to AXError+Extension.swift.** Anchor on the end of the `AccessibilityError` enum (closing brace at line 59). Append the free function after the enum, after the closing `}`.

```swift
}

func throwIfAXError(_ error: AXError) throws {
    guard error == .success else { throw AccessibilityError.axError(error) }
}
```

- [ ] **Step 2: BUILD GATE (intermediate).** Run: `swift build` | Expected: ends `Build complete!` (exit 0), no new warning. (Proves the helper compiles before any caller uses it.)

- [ ] **Step 3: Migrate `UIElement.attribute<T>(_:)` (guard at line 54).** Anchor on the `AXUIElementCopyAttributeValue` call. Replace the two-line `guard error == .success { throw ... }` with the helper. The subsequent `guard let typedValue = value as? T` / `throw .typeMismatch` block is unchanged.

```swift
        let error = AXUIElementCopyAttributeValue(axElement, name as CFString, &value)
        try throwIfAXError(error)
        guard let typedValue = value as? T else {
            throw AccessibilityError.typeMismatch
        }
```

- [ ] **Step 4: Migrate `UIElement.setAttribute(_:value:)` (guard at line 71).** Anchor on the `AXUIElementSetAttributeValue` call. This guard is the function's last statement.

```swift
        let error = AXUIElementSetAttributeValue(axElement, name as CFString, value)
        try throwIfAXError(error)
    }
```

- [ ] **Step 5: Migrate `UIElement.attributeNames()` (guard at line 80).** Anchor on the `AXUIElementCopyAttributeNames` call. The `return names as? [String] ?? []` after it is unchanged.

```swift
        let error = AXUIElementCopyAttributeNames(axElement, &names)
        try throwIfAXError(error)
        return names as? [String] ?? []
```

- [ ] **Step 6: Migrate `UIElement.actionNames()` (guard at line 203).** Anchor on the `AXUIElementCopyActionNames` call. The `return names as? [String] ?? []` after it is unchanged.

```swift
        let error = AXUIElementCopyActionNames(axElement, &names)
        try throwIfAXError(error)
        return names as? [String] ?? []
```

- [ ] **Step 7: Migrate `UIElement.performAction(_:)` (guard at line 212).** Anchor on the `AXUIElementPerformAction` call. This guard is the function's last statement.

```swift
        let error = AXUIElementPerformAction(axElement, action as CFString)
        try throwIfAXError(error)
    }
```

- [ ] **Step 8: DO NOT MODIFY `UIElement.element(at:)` (line ~233).** Verify by inspection that the compound guard `guard error == .success, let el = element else { throw AccessibilityError.axError(error) }` remains untouched — it binds `el` in the same guard, so it is NOT a simple two-line guard and is explicitly out of scope.

- [ ] **Step 9: DIFF-DISCIPLINE.** Run: `git diff` | Confirm: (a) AXError+Extension.swift adds only the `throwIfAXError` free function; (b) each of the 5 UIElement guards collapses from `guard error == .success else { throw AccessibilityError.axError(error) }` to exactly `try throwIfAXError(error)` with no change to the preceding AX-call line or the following statements; (c) `element(at:)` is unchanged. The thrown error value (`AccessibilityError.axError(error)`) is identical in all 5 cases, preserving behavior.

- [ ] **Step 10: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), no new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 11: GOLDEN (inspect5, inspect5_debug, read, status).** `attribute`/`attributeNames`/`actionNames` underpin nearly all reads; `inspect --show-actions`/`--debug-layout` and `read` exercise them broadly. Run:
```bash
.build/debug/kmsg inspect --depth 5 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/inspect5.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/inspect5.err /tmp/check.err
.build/debug/kmsg inspect --depth 5 --debug-layout > /tmp/check2.out 2> /tmp/check2.err && diff /tmp/kmsg-golden-baseline/inspect5_debug.out /tmp/check2.out && diff /tmp/kmsg-golden-baseline/inspect5_debug.err /tmp/check2.err
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check3.out 2> /tmp/check3.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check3.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check3.err
.build/debug/kmsg status --verbose > /tmp/check4.out 2> /tmp/check4.err && diff /tmp/kmsg-golden-baseline/status.out /tmp/check4.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check4.err
```
Expected: empty diffs (byte-identical).

- [ ] **Step 12: COMMIT.** Run:
```bash
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/AXError+Extension.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/UIElement.swift
git commit -m "refactor(accessibility): route simple AX guards through throwIfAXError"
```

---

## Phase 3 — Named-constant extraction for magic numbers

**Goal:** Replace magic-number literals (limit/maxNodes budgets, scoring tiers & ratios, `Thread.sleep` intervals, `waitUntil` timeouts/pollIntervals, key codes) with per-file private named constants, leaving every call site structurally unchanged.

**Aggregate risk:** low

> Per-file extraction only — never unify constants across files. Each named constant MUST equal the existing literal EXACTLY (no value change, no rounding, no merging of two sequential waits). Call sites stay structurally identical: only the literal token becomes a named reference. Helpers/constants from Phases 1–2 (`isSameElement`, `isTextInputRole`, `isEditable`, `throwIfAXError`, `kAXSecureTextFieldRole`) are already applied and may be referenced as existing.

---

### Task 3.1: AXActionRunner key codes

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/AXActionRunner.swift`
- Verify (golden): `status`, `send_dryrun` (only `send_dryrun` and `status` exercise this struct without sending; do NOT send real messages)

Literals found (key codes passed to `pressKey(code:)`):
- L160 `pressEnterWithVerification` → `pressKey(code: 36)` (Return)
- L204 `pressEscape` → `pressKey(code: 53)` (Escape)
- L208 `pressEnterKey` → `pressKey(code: 36)` (Return)
- L212 `pressDownArrowKey` → `pressKey(code: 125)` (Down arrow)
- L216 `pressTabKey` → `pressKey(code: 48)` (Tab)
- L220 `pressShiftTabKey` → `pressKey(code: 48, flags: .maskShift)` (Tab)
- L224 `pressSpaceKey` → `pressKey(code: 49)` (Space)
- L228 `pressCommandW` → `pressKey(code: 13, flags: .maskCommand) // W`
- L232 `pressCommandA` → `pressKey(code: 0, flags: .maskCommand) // A`
- L236 `pressPaste` → `pressKey(code: 9, flags: .maskCommand) // V`

- [ ] **Step 1: Add a private `KeyCode` enum.** Insert immediately after the `private let traceWriter: TraceWriter` stored-property line (before `init(traceEnabled:)`), anchored on `struct AXActionRunner {` / `private let traceWriter: TraceWriter`. Values mirror existing inline `// W / A / V` comments exactly.
  ```swift
  private enum KeyCode {
      static let returnKey: CGKeyCode = 36
      static let escape: CGKeyCode = 53
      static let downArrow: CGKeyCode = 125
      static let tab: CGKeyCode = 48
      static let space: CGKeyCode = 49
      static let w: CGKeyCode = 13
      static let a: CGKeyCode = 0
      static let v: CGKeyCode = 9
  }
  ```
- [ ] **Step 2: Substitute the Return key in `pressEnterWithVerification` (L160).** Anchored inside `func pressEnterWithVerification`, on the `let before = element?.stringValue ?? ""` line directly above.
  ```swift
          let before = element?.stringValue ?? ""
          pressKey(code: KeyCode.returnKey)
  ```
- [ ] **Step 3: Substitute the Escape key in `pressEscape` (L204).**
  ```swift
      func pressEscape() {
          pressKey(code: KeyCode.escape)
      }
  ```
- [ ] **Step 4: Substitute the Return key in `pressEnterKey` (L208).**
  ```swift
      func pressEnterKey() {
          pressKey(code: KeyCode.returnKey)
      }
  ```
- [ ] **Step 5: Substitute the Down arrow in `pressDownArrowKey` (L212).**
  ```swift
      func pressDownArrowKey() {
          pressKey(code: KeyCode.downArrow)
      }
  ```
- [ ] **Step 6: Substitute Tab in `pressTabKey` (L216).**
  ```swift
      func pressTabKey() {
          pressKey(code: KeyCode.tab)
      }
  ```
- [ ] **Step 7: Substitute Tab in `pressShiftTabKey` (L220).**
  ```swift
      func pressShiftTabKey() {
          pressKey(code: KeyCode.tab, flags: .maskShift)
      }
  ```
- [ ] **Step 8: Substitute Space in `pressSpaceKey` (L224).**
  ```swift
      func pressSpaceKey() {
          pressKey(code: KeyCode.space)
      }
  ```
- [ ] **Step 9: Substitute W in `pressCommandW` (L228).** Keep the trailing `// W` comment.
  ```swift
      func pressCommandW() {
          pressKey(code: KeyCode.w, flags: .maskCommand) // W
      }
  ```
- [ ] **Step 10: Substitute A in `pressCommandA` (L232).** Keep the trailing `// A` comment.
  ```swift
      func pressCommandA() {
          pressKey(code: KeyCode.a, flags: .maskCommand) // A
      }
  ```
- [ ] **Step 11: Substitute V in `pressPaste` (L236).** Keep the trailing `// V` comment.
  ```swift
      func pressPaste() {
          pressKey(code: KeyCode.v, flags: .maskCommand) // V
      }
  ```
- [ ] **Step 12: Per-constant grep check (values match originals).** Run and confirm each value equals the literal it replaced:
  ```
  swift -e 'import CoreGraphics' >/dev/null 2>&1; grep -nE 'returnKey: CGKeyCode = 36|escape: CGKeyCode = 53|downArrow: CGKeyCode = 125|tab: CGKeyCode = 48|space: CGKeyCode = 49|w: CGKeyCode = 13|a: CGKeyCode = 0|v: CGKeyCode = 9' Sources/kmsg/Accessibility/AXActionRunner.swift
  ```
  Expected: 8 matching lines (one per constant). Also confirm zero remaining numeric `pressKey(code:` literals:
  ```
  grep -nE 'pressKey\(code: [0-9]' Sources/kmsg/Accessibility/AXActionRunner.swift
  ```
  Expected: empty (no output).
- [ ] **Step 13: DIFF-DISCIPLINE.** Run:
  ```
  git diff Sources/kmsg/Accessibility/AXActionRunner.swift
  ```
  Confirm the change is ONLY: one added `KeyCode` enum block + literal→`KeyCode.*` substitutions. No `flags:` argument moved or reordered, no comment removed, no value changed.
- [ ] **Step 14: BUILD GATE.** Run:
  ```
  swift build
  ```
  Expected: ends `Build complete!` (exit 0); no new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.
- [ ] **Step 15: GOLDEN.** Run:
  ```
  .build/debug/kmsg status --verbose > /tmp/check.out 2> /tmp/check.err; diff /tmp/kmsg-golden-baseline/status.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check.err
  .build/debug/kmsg send "테헤란로 죽돌이" "x" --dry-run > /tmp/check2.out 2> /tmp/check2.err; diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check2.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check2.err
  ```
  Expected: empty diffs (byte-identical).
- [ ] **Step 16: COMMIT.** Run:
  ```
  git add Sources/kmsg/Accessibility/AXActionRunner.swift
  git commit -m "refactor(ax-runner): name CGKeyCode literals via KeyCode enum"
  ```

---

### Task 3.2: KakaoTalkApp window-probe sleep & probe budgets

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/KakaoTalkApp.swift`
- Verify (golden): `status`

Literals found:
- L102 `waitForRunningApplication` → `Thread.sleep(forTimeInterval: 0.1)`
- L147 `ensureMainWindow` firstProbe → `mode == .fast ? 0.45 : 0.8`
- L154 `ensureMainWindow` secondProbe → `mode == .fast ? 0.35 : 0.6`
- L165 `ensureMainWindow` relaunchBudget → `min(1.2, ...)`
- L171 `ensureMainWindow` relaunchProbe → `min(1.0, ...)`
- L177 `ensureMainWindow` openBudget → `min(1.0, ...)`
- L182 `ensureMainWindow` openProbe → `min(0.8, ...)`
- L232 `waitForUsableWindow` → `Thread.sleep(forTimeInterval: 0.1)`

> NOTE: the `max(timeout, 0.1)` clamp on L146 and `max(0, ...)` on L143 are arithmetic guards on an incoming argument, not tunable budgets — LEAVE THEM AS LITERALS (do not extract). Default-argument values in `launch(timeout: 5.0)`, `forceOpen(timeout: 1.0)`, `activateAndWaitForWindow(timeout: 2.0)`, `ensureMainWindow(timeout: 5.0)` are API defaults, not magic numbers in expressions — LEAVE AS-IS.

- [ ] **Step 1: Add a private `WindowProbe` enum.** Insert immediately after the `private let app: UIElement` stored-property line, anchored on `public final class KakaoTalkApp: Sendable {` / `public static let bundleIdentifier = "com.kakao.KakaoTalkMac"` / `private let app: UIElement`. Place the new enum right after `private let app: UIElement`.
  ```swift
  private enum WindowProbe {
      static let pollInterval: TimeInterval = 0.1
      static let firstProbeFast: TimeInterval = 0.45
      static let firstProbeRecovery: TimeInterval = 0.8
      static let secondProbeFast: TimeInterval = 0.35
      static let secondProbeRecovery: TimeInterval = 0.6
      static let relaunchBudget: TimeInterval = 1.2
      static let relaunchProbe: TimeInterval = 1.0
      static let openBudget: TimeInterval = 1.0
      static let openProbe: TimeInterval = 0.8
  }
  ```
- [ ] **Step 2: Substitute the poll sleep in `waitForRunningApplication` (L102).** Anchored inside `private static func waitForRunningApplication`, on the `if let app = runningApplication { return app }` block ending just above.
  ```swift
              if let app = runningApplication {
                  return app
              }
              Thread.sleep(forTimeInterval: WindowProbe.pollInterval)
  ```
- [ ] **Step 3: Substitute firstProbe in `ensureMainWindow` (L147).** Anchored on `let deadline = Date().addingTimeInterval(max(timeout, 0.1))` directly above (leave that `0.1` clamp untouched).
  ```swift
          let firstProbe = min(mode == .fast ? WindowProbe.firstProbeFast : WindowProbe.firstProbeRecovery, remainingTime(until: deadline))
  ```
- [ ] **Step 4: Substitute secondProbe in `ensureMainWindow` (L154).** Anchored on the `activate()` line directly above and `trace?("No usable window after activation; retrying activation and rescan")`.
  ```swift
          let secondProbe = min(mode == .fast ? WindowProbe.secondProbeFast : WindowProbe.secondProbeRecovery, remainingTime(until: deadline))
  ```
- [ ] **Step 5: Substitute relaunchBudget in `ensureMainWindow` (L165).** Anchored on `trace?("No usable window after activation-rescan; attempting relaunch")` directly above.
  ```swift
          let relaunchBudget = min(WindowProbe.relaunchBudget, remainingTime(until: deadline))
  ```
- [ ] **Step 6: Substitute relaunchProbe in `ensureMainWindow` (L171).** Anchored on the `activate()` line above and `if relaunchProbe > 0, let window = waitForUsableWindow(...)` below.
  ```swift
          let relaunchProbe = min(WindowProbe.relaunchProbe, remainingTime(until: deadline))
  ```
- [ ] **Step 7: Substitute openBudget in `ensureMainWindow` (L177).** Anchored on `trace?("No usable window after relaunch; forcing open /Applications/KakaoTalk.app")` directly above.
  ```swift
          let openBudget = min(WindowProbe.openBudget, remainingTime(until: deadline))
  ```
- [ ] **Step 8: Substitute openProbe in `ensureMainWindow` (L182).** Anchored on the second `activate()` line above and `if openProbe > 0, let window = waitForUsableWindow(...)` below.
  ```swift
          let openProbe = min(WindowProbe.openProbe, remainingTime(until: deadline))
  ```
- [ ] **Step 9: Substitute the poll sleep in `waitForUsableWindow` (L232).** Anchored inside `private func waitForUsableWindow(timeout:trace:)`, on the `trace?("Usable window found via \(usableWindow.source)")` / `return usableWindow.window` block ending just above the sleep.
  ```swift
                  trace?("Usable window found via \(usableWindow.source)")
                  return usableWindow.window
              }
              Thread.sleep(forTimeInterval: WindowProbe.pollInterval)
  ```
- [ ] **Step 10: Per-constant grep check (values match originals).** Run:
  ```
  grep -nE 'pollInterval: TimeInterval = 0.1|firstProbeFast: TimeInterval = 0.45|firstProbeRecovery: TimeInterval = 0.8|secondProbeFast: TimeInterval = 0.35|secondProbeRecovery: TimeInterval = 0.6|relaunchBudget: TimeInterval = 1.2|relaunchProbe: TimeInterval = 1.0|openBudget: TimeInterval = 1.0|openProbe: TimeInterval = 0.8' Sources/kmsg/KakaoTalk/KakaoTalkApp.swift
  ```
  Expected: 9 matching lines. Then confirm the two extracted sleeps no longer use a numeric literal while the untouched `0.1` clamp remains:
  ```
  grep -n "Thread.sleep(forTimeInterval: WindowProbe.pollInterval)" Sources/kmsg/KakaoTalk/KakaoTalkApp.swift
  grep -n "max(timeout, 0.1)" Sources/kmsg/KakaoTalk/KakaoTalkApp.swift
  ```
  Expected: first grep = 2 lines; second grep = 1 line (clamp intentionally left as literal).
- [ ] **Step 11: DIFF-DISCIPLINE.** Run:
  ```
  git diff Sources/kmsg/KakaoTalk/KakaoTalkApp.swift
  ```
  Confirm ONLY: one added `WindowProbe` enum + literal→`WindowProbe.*` substitutions on L102/147/154/165/171/177/182/232. The `mode == .fast ? _ : _` ternary structure, `min(...)`/`remainingTime(...)` wrappers, and `max(timeout, 0.1)` clamp are unchanged.
- [ ] **Step 12: BUILD GATE.** Run:
  ```
  swift build
  ```
  Expected: `Build complete!` (exit 0); no new warning vs baseline.
- [ ] **Step 13: GOLDEN.** Run:
  ```
  .build/debug/kmsg status --verbose > /tmp/check.out 2> /tmp/check.err; diff /tmp/kmsg-golden-baseline/status.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check.err
  ```
  Expected: empty diff (byte-identical).
- [ ] **Step 14: COMMIT.** Run:
  ```
  git add Sources/kmsg/KakaoTalk/KakaoTalkApp.swift
  git commit -m "refactor(kakao-app): name window-probe budgets via WindowProbe enum"
  ```

---

### Task 3.3: TranscriptReader budgets, scoring tiers & spatial ratios

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
- Verify (golden): `read`, `read_json`

Literals found (grouped by enclosing symbol):

`collectTranscriptRows` (L122–180):
- L128 `targetRowCount = max(messageLimit * 4, 50)` → multiplier `4`, floor `50`
- L136 container BFS `limit: 8, maxNodes: 900`
- L142 threshold compare `rows.count < targetRowCount` (no literal — skip)
- L144–146 row BFS `limit: max(targetRowCount * 3, 240), maxNodes: 3_000`
- L152 cells BFS `limit: max(targetRowCount * 2, 160), maxNodes: 2_000`
- L161 frame filter `inputFrame.minY + 20`
- L176 `recentWindow = max(messageLimit * 6, 80)`

`extractMessages` (L182–306):
- L190 `analysisBudget = max(limit * 5, 60)`
- L197 `reserveCapacity(min(analyses.count, limit * 2))` → multiplier `2`
- L222/238 `skippedLogs < 10`, L289 `selectedLogs < 10` → log cap `10`
- L291 `.prefix(60)` → body log preview length `60`
- L299 `messages.count < max(3, min(limit / 2, 8))` → floor `3`, divisor `2`, cap `8`

`analyzeRow` (L312–441):
- L356–363 missing-roles BFS `roleLimits: [kAXTextAreaRole: 4, kAXStaticTextRole: 8, kAXImageRole: 3, kAXButtonRole: 6], maxNodes: 140`
- L663/666 (inside `inferMessageSide`) image-vs-body gap `+ 10`

`inferMessageSide` (L655–685):
- L663 `imageFrame.midX + 10 < bodyF.minX`
- L666 `imageFrame.midX > bodyF.maxX + 10`
- L677 `max(transcriptFrame.width, 1)`
- L678 `ratio <= 0.56`
- L681 `ratio >= 0.62`

`extractFallbackMessages` (L443–497):
- L445 textArea BFS `limit: max(limit * 80, 1_200), maxNodes: 6_000`
- L446 `.suffix(max(limit * 20, 240))`
- L460 `firstAncestor(... maxHops: 6)`
- L478 links BFS `limit: max(limit * 40, 320), maxNodes: 4_000`
- L479 `.suffix(max(limit * 10, 80))`

`extractRowMetadata` (L499–514):
- L500 cells BFS `limit: 8, maxNodes: 180`
- L505 staticTexts BFS `limit: 12, maxNodes: 240`

`scoreBodyCandidate` (L950–963):
- L951 `min(text.count * 10, 500)`
- L954 newline bonus `60`
- L956 space bonus `40`
- L960 URL bonus `180`

`bestLinkTitle` (L868–876):
- L869 links BFS `limit: 4, maxNodes: 120`

`parseSystemDate` (L797–851):
- L841 `> 86_400 * 2` → seconds-per-day `86_400`, day-count `2`

> NOTE: numeric values inside regex string literals (e.g. `[1-9]`, `1[0-2]`, `[0-5][0-9]`, `\d{4}`, `% 12`, `+ 12`, `hour * 60`) are part of time/date parsing logic, NOT tunable budgets — LEAVE ALL OF THEM AS-IS. The `* 60` and `% 12`/`+ 12` in `minuteOfDay`/`logicalTimestamp` are unit conversions, not magic budgets — LEAVE AS-IS. `reserveCapacity`/`String(format: "%02d:%02d")` formatting stays literal.

- [ ] **Step 1: Add private constant enums at end of `struct KakaoTalkTranscriptReader`.** Insert immediately before the closing brace of the struct, i.e. directly after `sortElementsByReadingOrder(_:)` (ends L996) and before the `}` on L997 that closes the struct. Anchor on the closing of `sortElementsByReadingOrder`:
  ```swift
          }
      }

      private enum RowBudget {
          static let targetRowMultiplier = 4
          static let targetRowFloor = 50
          static let containerLimit = 8
          static let containerNodes = 900
          static let rowBfsMultiplier = 3
          static let rowBfsFloor = 240
          static let rowBfsNodes = 3_000
          static let cellBfsMultiplier = 2
          static let cellBfsFloor = 160
          static let cellBfsNodes = 2_000
          static let inputFrameSlack: CGFloat = 20
          static let recentWindowMultiplier = 6
          static let recentWindowFloor = 80
      }

      private enum AnalysisBudget {
          static let multiplier = 5
          static let floor = 60
          static let reserveMultiplier = 2
          static let logCap = 10
          static let bodyLogPreviewLength = 60
          static let fallbackTriggerFloor = 3
          static let fallbackTriggerDivisor = 2
          static let fallbackTriggerCap = 8
          static let textAreaLimit = 4
          static let staticTextLimit = 8
          static let imageLimit = 3
          static let buttonLimit = 6
          static let roleBfsNodes = 140
      }

      private enum SideHeuristic {
          static let imageBodyGap: CGFloat = 10
          static let transcriptWidthFloor: CGFloat = 1
          static let leftRatioMax = 0.56
          static let rightRatioMin = 0.62
      }

      private enum FallbackBudget {
          static let textAreaMultiplier = 80
          static let textAreaFloor = 1_200
          static let textAreaNodes = 6_000
          static let recentTextAreaMultiplier = 20
          static let recentTextAreaFloor = 240
          static let ancestorMaxHops = 6
          static let linkMultiplier = 40
          static let linkFloor = 320
          static let linkNodes = 4_000
          static let recentLinkMultiplier = 10
          static let recentLinkFloor = 80
      }

      private enum MetadataBudget {
          static let cellLimit = 8
          static let cellNodes = 180
          static let staticTextLimit = 12
          static let staticTextNodes = 240
      }

      private enum BodyScore {
          static let perCharacter = 10
          static let cap = 500
          static let newlineBonus = 60
          static let spaceBonus = 40
          static let urlBonus = 180
          static let linkLimit = 4
          static let linkNodes = 120
      }

      private enum SystemDate {
          static let secondsPerDay: TimeInterval = 86_400
          static let futureDayTolerance: Double = 2
      }
  ```
- [ ] **Step 2: Substitute `targetRowCount` (L128) in `collectTranscriptRows`.** Anchored on `private func collectTranscriptRows` / `let targetRowCount = ...`.
  ```swift
          let targetRowCount = max(messageLimit * RowBudget.targetRowMultiplier, RowBudget.targetRowFloor)
  ```
- [ ] **Step 3: Substitute container BFS budgets (L136).** Anchored on `let containerCandidates = transcriptRoot.findAll(where: { element in` block; only the `limit:`/`maxNodes:` line changes.
  ```swift
          }, limit: RowBudget.containerLimit, maxNodes: RowBudget.containerNodes)
  ```
- [ ] **Step 4: Substitute row BFS budgets (L144–146).** Anchored on `let bfsRows = transcriptRoot.findAll(` inside the `if rows.count < targetRowCount {` block.
  ```swift
              let bfsRows = transcriptRoot.findAll(
                  role: kAXRowRole,
                  limit: max(targetRowCount * RowBudget.rowBfsMultiplier, RowBudget.rowBfsFloor),
                  maxNodes: RowBudget.rowBfsNodes
              )
  ```
- [ ] **Step 5: Substitute cell BFS budgets (L152).** Anchored on `if rows.isEmpty {` / `let cells = transcriptRoot.findAll(role: kAXCellRole, ...`.
  ```swift
              let cells = transcriptRoot.findAll(role: kAXCellRole, limit: max(targetRowCount * RowBudget.cellBfsMultiplier, RowBudget.cellBfsFloor), maxNodes: RowBudget.cellBfsNodes)
  ```
- [ ] **Step 6: Substitute input-frame slack (L161).** Anchored on `if let inputFrame = inputElement.frame {` / `return rowFrame.maxY <= inputFrame.minY + 20`.
  ```swift
                  return rowFrame.maxY <= inputFrame.minY + RowBudget.inputFrameSlack
  ```
- [ ] **Step 7: Substitute `recentWindow` (L176).** Anchored on `let recentWindow = max(messageLimit * 6, 80)`.
  ```swift
          let recentWindow = max(messageLimit * RowBudget.recentWindowMultiplier, RowBudget.recentWindowFloor)
  ```
- [ ] **Step 8: Substitute `analysisBudget` (L190) in `extractMessages`.** Anchored on `private func extractMessages` / `let analysisBudget = max(limit * 5, 60)`.
  ```swift
          let analysisBudget = max(limit * AnalysisBudget.multiplier, AnalysisBudget.floor)
  ```
- [ ] **Step 9: Substitute reserveCapacity multiplier (L197).** Anchored on `messages.reserveCapacity(min(analyses.count, limit * 2))`.
  ```swift
          messages.reserveCapacity(min(analyses.count, limit * AnalysisBudget.reserveMultiplier))
  ```
- [ ] **Step 10: Substitute the three log caps `< 10` (L222, L238, L289) and preview length `60` (L291).** Three distinct `if skippedLogs < 10 {` / `if selectedLogs < 10 {` sites and one `.prefix(60)`.
  - L222 (anchored on `guard let bodyCandidate = analysis.bodyCandidate else {`):
    ```swift
                  if skippedLogs < AnalysisBudget.logCap {
    ```
  - L238 (anchored on `if analysis.isSystemLikeRow, !includeSystemMessages {`):
    ```swift
                  if skippedLogs < AnalysisBudget.logCap {
    ```
  - L289 (anchored on `messages.append(message)` then `if selectedLogs < 10 {`):
    ```swift
              if selectedLogs < AnalysisBudget.logCap {
    ```
  - L291 (the `body='\(bodyCandidate.body.prefix(60))'` interpolation):
    ```swift
                      "read: row[\(offset + 1)] side=\(side.rawValue) author='\(author ?? "(me)")' source=\(resolvedAuthor.source) time='\(resolvedTime ?? "unknown")' body='\(bodyCandidate.body.prefix(AnalysisBudget.bodyLogPreviewLength))'"
    ```
- [ ] **Step 11: Substitute fallback-trigger threshold (L299).** Anchored on `if messages.isEmpty || messages.count < max(3, min(limit / 2, 8)) {`.
  ```swift
          if messages.isEmpty || messages.count < max(AnalysisBudget.fallbackTriggerFloor, min(limit / AnalysisBudget.fallbackTriggerDivisor, AnalysisBudget.fallbackTriggerCap)) {
  ```
- [ ] **Step 12: Substitute missing-roles BFS budgets (L356–363) in `analyzeRow`.** Anchored on `let found = container.findAll(` / `roleLimits: [` inside `if !missingRoles.isEmpty {`.
  ```swift
                  let found = container.findAll(
                      roles: Set(missingRoles),
                      roleLimits: [
                          kAXTextAreaRole: AnalysisBudget.textAreaLimit,
                          kAXStaticTextRole: AnalysisBudget.staticTextLimit,
                          kAXImageRole: AnalysisBudget.imageLimit,
                          kAXButtonRole: AnalysisBudget.buttonLimit,
                      ],
                      maxNodes: AnalysisBudget.roleBfsNodes
                  )
  ```
- [ ] **Step 13: Substitute image-vs-body gap & ratio thresholds (L663, L666, L677, L678, L681) in `inferMessageSide`.** Anchored on `private func inferMessageSide`.
  ```swift
          if let bodyF = bodyFrame {
              for imageFrame in imageFrames {
                  if imageFrame.midX + SideHeuristic.imageBodyGap < bodyF.minX {
                      return .left
                  }
                  if imageFrame.midX > bodyF.maxX + SideHeuristic.imageBodyGap {
                      return .right
                  }
              }
          }
  ```
  and the ratio block:
  ```swift
          let ratio = (candidateFrame.midX - transcriptFrame.minX) / max(transcriptFrame.width, SideHeuristic.transcriptWidthFloor)
          if ratio <= SideHeuristic.leftRatioMax {
              return .left
          }
          if ratio >= SideHeuristic.rightRatioMin {
              return .right
          }
  ```
- [ ] **Step 14: Substitute fallback budgets (L445, L446, L460, L478, L479) in `extractFallbackMessages`.** Anchored on `private func extractFallbackMessages`.
  - L445:
    ```swift
          let textAreas = transcriptRoot.findAll(role: kAXTextAreaRole, limit: max(limit * FallbackBudget.textAreaMultiplier, FallbackBudget.textAreaFloor), maxNodes: FallbackBudget.textAreaNodes)
    ```
  - L446:
    ```swift
          let recentTextAreas = Array(sortElementsByReadingOrder(textAreas).suffix(max(limit * FallbackBudget.recentTextAreaMultiplier, FallbackBudget.recentTextAreaFloor)))
    ```
  - L460:
    ```swift
              let row = firstAncestor(of: textArea, role: kAXRowRole, maxHops: FallbackBudget.ancestorMaxHops)
    ```
  - L478:
    ```swift
              let links = transcriptRoot.findAll(where: { $0.role == kAXLinkRole }, limit: max(limit * FallbackBudget.linkMultiplier, FallbackBudget.linkFloor), maxNodes: FallbackBudget.linkNodes)
    ```
  - L479:
    ```swift
              let recentLinks = Array(sortElementsByReadingOrder(links).suffix(max(limit * FallbackBudget.recentLinkMultiplier, FallbackBudget.recentLinkFloor)))
    ```
- [ ] **Step 15: Substitute metadata BFS budgets (L500, L505) in `extractRowMetadata`.** Anchored on `private func extractRowMetadata`.
  - L500:
    ```swift
          let cells = row.findAll(role: kAXCellRole, limit: MetadataBudget.cellLimit, maxNodes: MetadataBudget.cellNodes)
    ```
  - L505:
    ```swift
              let staticTexts = container.findAll(role: kAXStaticTextRole, limit: MetadataBudget.staticTextLimit, maxNodes: MetadataBudget.staticTextNodes)
    ```
- [ ] **Step 16: Substitute body-score tiers (L951, L954, L956, L960) in `scoreBodyCandidate`.** Anchored on `private func scoreBodyCandidate`.
  ```swift
          var score = min(text.count * BodyScore.perCharacter, BodyScore.cap)
          if text.contains("\n") {
              score += BodyScore.newlineBonus
          }
          if text.contains(" ") {
              score += BodyScore.spaceBonus
          }
          let lower = text.lowercased()
          if lower.contains("http://") || lower.contains("https://") {
              score += BodyScore.urlBonus
          }
  ```
- [ ] **Step 17: Substitute link BFS budgets (L869) in `bestLinkTitle`.** Anchored on `private func bestLinkTitle` / `let links = element.findAll(where: { $0.role == kAXLinkRole }, ...`.
  ```swift
          let links = element.findAll(where: { $0.role == kAXLinkRole }, limit: BodyScore.linkLimit, maxNodes: BodyScore.linkNodes)
  ```
- [ ] **Step 18: Substitute the seconds-per-day / tolerance (L841) in `parseSystemDate`.** Anchored on `if candidate.timeIntervalSince(referenceDate) > 86_400 * 2,`.
  ```swift
              if candidate.timeIntervalSince(referenceDate) > SystemDate.secondsPerDay * SystemDate.futureDayTolerance,
  ```
- [ ] **Step 19: Per-constant grep check (values match originals).** Run:
  ```
  grep -nE 'targetRowMultiplier = 4|targetRowFloor = 50|containerLimit = 8|containerNodes = 900|rowBfsMultiplier = 3|rowBfsFloor = 240|rowBfsNodes = 3_000|cellBfsMultiplier = 2|cellBfsFloor = 160|cellBfsNodes = 2_000|inputFrameSlack: CGFloat = 20|recentWindowMultiplier = 6|recentWindowFloor = 80' Sources/kmsg/KakaoTalk/TranscriptReader.swift
  grep -nE 'multiplier = 5|floor = 60|reserveMultiplier = 2|logCap = 10|bodyLogPreviewLength = 60|fallbackTriggerFloor = 3|fallbackTriggerDivisor = 2|fallbackTriggerCap = 8|textAreaLimit = 4|staticTextLimit = 8|imageLimit = 3|buttonLimit = 6|roleBfsNodes = 140' Sources/kmsg/KakaoTalk/TranscriptReader.swift
  grep -nE 'imageBodyGap: CGFloat = 10|transcriptWidthFloor: CGFloat = 1|leftRatioMax = 0.56|rightRatioMin = 0.62' Sources/kmsg/KakaoTalk/TranscriptReader.swift
  grep -nE 'textAreaMultiplier = 80|textAreaFloor = 1_200|textAreaNodes = 6_000|recentTextAreaMultiplier = 20|recentTextAreaFloor = 240|ancestorMaxHops = 6|linkMultiplier = 40|linkFloor = 320|linkNodes = 4_000|recentLinkMultiplier = 10|recentLinkFloor = 80' Sources/kmsg/KakaoTalk/TranscriptReader.swift
  grep -nE 'cellLimit = 8|cellNodes = 180|staticTextLimit = 12|staticTextNodes = 240' Sources/kmsg/KakaoTalk/TranscriptReader.swift
  grep -nE 'perCharacter = 10|cap = 500|newlineBonus = 60|spaceBonus = 40|urlBonus = 180|linkLimit = 4|linkNodes = 120' Sources/kmsg/KakaoTalk/TranscriptReader.swift
  grep -nE 'secondsPerDay: TimeInterval = 86_400|futureDayTolerance: Double = 2' Sources/kmsg/KakaoTalk/TranscriptReader.swift
  ```
  Expected line counts: 13, 13, 4, 11, 4, 7, 2 (every declared constant present exactly once, each equal to the literal it replaced). Then confirm the date-parsing regex literals are untouched:
  ```
  grep -n "([01]?[0-9]|2[0-3]):[0-5][0-9]" Sources/kmsg/KakaoTalk/TranscriptReader.swift
  grep -n "hour \* 60" Sources/kmsg/KakaoTalk/TranscriptReader.swift
  ```
  Expected: regex/time-math lines still present unchanged (parsing logic deliberately NOT extracted).
- [ ] **Step 20: DIFF-DISCIPLINE.** Run:
  ```
  git diff Sources/kmsg/KakaoTalk/TranscriptReader.swift
  ```
  Confirm ONLY: 7 added constant-enum blocks + literal→named substitutions at the enumerated sites. No regex string changed, no `max(...)`/`min(...)`/`suffix(...)` structure altered, no scoring operator reordered, no value changed.
- [ ] **Step 21: BUILD GATE.** Run:
  ```
  swift build
  ```
  Expected: `Build complete!` (exit 0); no new warning vs baseline.
- [ ] **Step 22: GOLDEN.** Run (read of the known chat, both text and JSON):
  ```
  .build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err; diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err
  .build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check2.out 2> /tmp/check2.err; diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check2.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check2.err
  ```
  Expected: empty diffs (byte-identical). (If the golden `read_json` was captured with a different flag spelling than `--json`, use the exact invocation recorded for that golden.)
- [ ] **Step 23: COMMIT.** Run:
  ```
  git add Sources/kmsg/KakaoTalk/TranscriptReader.swift
  git commit -m "refactor(transcript): name traversal budgets and scoring tiers"
  ```

---

### Task 3.4: MessageContextResolver budgets, scoring tiers & spatial ratios

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/MessageContextResolver.swift`
- Verify (golden): `read`, `read_json`

Literals found:

`resolveMessageInputField` (L46–111):
- L70/73/78 attempt-scaled limit `attempt == 1 ? 36 : 60`
- L89 app-wide `limit: 60`
- L100 `Thread.sleep(forTimeInterval: 0.05)`
- L103 app-fallback `limit: 90`

`resolveTranscriptRoot` (L113–170):
- L154 `topCount = min(3, phase1.count)`

`collectTranscriptContainers` (L172–190):
- L176–182 roleLimits `kAXScrollAreaRole: 12, kAXTableRole: 8, kAXOutlineRole: 8, kAXListRole: 8, kAXGroupRole: 10`, `maxNodes: 600`

`scoreTranscriptContainerSpatial` (L192–250):
- L202 `max(windowFrame.width, 1)`
- L203 `< 0.35` width ratio → `-8_000`
- L208 `max(min(...), 1)`
- L209 `< 0.15` overlap → `-7_000`
- L217 scroll `4_400`, L219 table `3_600`, L221 list/outline `3_000`, L223 group `1_500`
- L228 `inputFrame.minY + 24` → `1_300`, L230 else `-2_800`
- L234 `overlapRatio * 2_200`
- L236 `max(windowFrame.width, 1)`
- L237 `centerX < 0.35` → `-1_600`
- L242 below input → `-3_000`
- L245 `height > inputFrame.height * 2.2` → `+320`

`scoreTranscriptContainerChildBonus` (L253–263):
- L257–258 roleLimits `kAXRowRole: 20, kAXStaticTextRole: 20`, `maxNodes: 240`
- L262 `rowCount * 150`, `textCount * 25`

`preferredChatPaneRoot` (L274–290):
- L276 `ancestorChain(... maxHops: 8)`
- L281/282/283 `max(windowFrame.width, 1)`, `max(windowFrame.height, 1)`, `widthRatio >= 0.45 && heightRatio >= 0.35`

`collectFocusedElementLineageCandidates` (L324–341):
- L329 `hops < 4`
- L333–334 text-descendant BFS `limit: 8, maxNodes: 48`

`collectMessageInputCandidates` (L306–322):
- L307 `max(200, limit * 4)`

`scoreMessageInputCandidate` (L350–389):
- L357 `12_000.0`, L359 `9_000.0`, L363 `6_000.0`
- L368 search penalty `8_000.0`
- L377 `max(windowFrame.height, 1.0)`, L378 `relativeY > 0.55 ? 1_500.0 : 0.0`, L380 `-6_000.0`
- L387 focus `2_000.0`

`isLikelySearchField` (L407–433):
- L431 `relativeY < 0.5`

`isElementLikelyInsideWindow` (L479–482):
- L480 `insetBy(dx: -24, dy: -24)`

> NOTE: `attempt == 1 ? 36 : 60` appears on L70, L73, L78 — three identical sites; all map to the SAME two constants (`InputBudget.attemptLimit` / `InputBudget.attemptLimitExpanded`). `1...2` loop range (L66) is a control-flow bound, NOT a budget — LEAVE AS-IS. `Double.greatestFiniteMagnitude` sentinels stay as-is.

- [ ] **Step 1: Add private constant enums at end of `struct MessageContextResolver`.** Insert immediately before the struct's closing brace, i.e. directly after `frameDescription(_:)` (ends L487) and before the closing `}` on L488. Anchor on the end of `frameDescription`:
  ```swift
          return "x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) w=\(Int(frame.size.width)) h=\(Int(frame.size.height))"
      }

      private enum InputBudget {
          static let attemptLimit = 36
          static let attemptLimitExpanded = 60
          static let appWideLimit = 60
          static let appFallbackLimit = 90
          static let reactivateSleep: TimeInterval = 0.05
          static let nodeBudgetFloor = 200
          static let nodeBudgetMultiplier = 4
          static let lineageMaxHops = 4
          static let lineageTextLimit = 8
          static let lineageTextNodes = 48
      }

      private enum ContainerBudget {
          static let scrollAreaLimit = 12
          static let tableLimit = 8
          static let outlineLimit = 8
          static let listLimit = 8
          static let groupLimit = 10
          static let maxNodes = 600
          static let topCandidateCount = 3
          static let childBonusRowLimit = 20
          static let childBonusTextLimit = 20
          static let childBonusNodes = 240
          static let childBonusRowWeight = 150
          static let childBonusTextWeight = 25
      }

      private enum SpatialScore {
          static let frameDimensionFloor: CGFloat = 1
          static let minWidthRatio: CGFloat = 0.35
          static let widthRatioPenalty: Double = -8_000
          static let overlapFloor: CGFloat = 1
          static let minOverlapRatio: CGFloat = 0.15
          static let overlapPenalty: Double = -7_000
          static let scrollAreaScore: Double = 4_400
          static let tableScore: Double = 3_600
          static let listOutlineScore: Double = 3_000
          static let groupScore: Double = 1_500
          static let aboveInputSlack: CGFloat = 24
          static let aboveInputBonus: Double = 1_300
          static let belowInputPenalty: Double = -2_800
          static let overlapWeight: Double = 2_200
          static let leftCenterRatio: CGFloat = 0.35
          static let leftCenterPenalty: Double = -1_600
          static let belowInputStartPenalty: Double = -3_000
          static let tallHeightMultiplier: CGFloat = 2.2
          static let tallHeightBonus: Double = 320
      }

      private enum PaneRoot {
          static let ancestorMaxHops = 8
          static let frameDimensionFloor: CGFloat = 1
          static let minWidthRatio: CGFloat = 0.45
          static let minHeightRatio: CGFloat = 0.35
      }

      private enum InputScore {
          static let textAreaScore: Double = 12_000.0
          static let textFieldScore: Double = 9_000.0
          static let editableScore: Double = 6_000.0
          static let searchPenalty: Double = 8_000.0
          static let heightFloor: Double = 1.0
          static let lowerHalfRatio: CGFloat = 0.55
          static let lowerHalfBonus: Double = 1_500.0
          static let outsideWindowPenalty: Double = -6_000.0
          static let focusBonus: Double = 2_000.0
      }

      private enum SearchFieldHeuristic {
          static let topHalfRatio: CGFloat = 0.5
      }

      private enum WindowInset {
          static let slack: CGFloat = -24
      }
  ```
- [ ] **Step 2: Substitute attempt-scaled limits (L70, L73, L78) in `resolveMessageInputField`.** Three sites; each `attempt == 1 ? 36 : 60` → `attempt == 1 ? InputBudget.attemptLimit : InputBudget.attemptLimitExpanded`.
  - L70 (anchored on `if let focusedWindow = kakao.focusedWindow {` / `collectMessageInputCandidates(from: focusedWindow, ...`):
    ```swift
                  let focusedWindowCandidates = collectMessageInputCandidates(from: focusedWindow, limit: attempt == 1 ? InputBudget.attemptLimit : InputBudget.attemptLimitExpanded)
    ```
  - L73 (anchored on `if !areSameAXElement(focusedWindow, chatWindow) {`):
    ```swift
                      let chatWindowCandidates = collectMessageInputCandidates(from: chatWindow, limit: attempt == 1 ? InputBudget.attemptLimit : InputBudget.attemptLimitExpanded)
    ```
  - L78 (anchored on the `} else {` branch / `let chatWindowCandidates = collectMessageInputCandidates(from: chatWindow, ...`):
    ```swift
                  let chatWindowCandidates = collectMessageInputCandidates(from: chatWindow, limit: attempt == 1 ? InputBudget.attemptLimit : InputBudget.attemptLimitExpanded)
    ```
- [ ] **Step 3: Substitute app-wide limit (L89) in `resolveMessageInputField`.** Anchored on `if attempt > 1 {` / `candidates.append(contentsOf: collectMessageInputCandidates(from: kakao.applicationElement, limit: 60))`.
  ```swift
                  candidates.append(contentsOf: collectMessageInputCandidates(from: kakao.applicationElement, limit: InputBudget.appWideLimit))
  ```
- [ ] **Step 4: Substitute reactivate sleep (L100).** Anchored on `_ = runner.focusWithVerification(chatWindow, label: "chat window", attempts: 1)` directly above.
  ```swift
              Thread.sleep(forTimeInterval: InputBudget.reactivateSleep)
  ```
- [ ] **Step 5: Substitute app-fallback limit (L103).** Anchored on `let appCandidates = collectMessageInputCandidates(from: kakao.applicationElement, limit: 90)`.
  ```swift
          let appCandidates = collectMessageInputCandidates(from: kakao.applicationElement, limit: InputBudget.appFallbackLimit)
  ```
- [ ] **Step 6: Substitute `topCount` (L154) in `resolveTranscriptRoot`.** Anchored on `// Phase 2: child bonus via BFS for top 3 candidates only` / `let topCount = min(3, phase1.count)`.
  ```swift
          let topCount = min(ContainerBudget.topCandidateCount, phase1.count)
  ```
- [ ] **Step 7: Substitute container role limits & nodes (L176–183) in `collectTranscriptContainers`.** Anchored on `private func collectTranscriptContainers` / `let roleLimits: [String: Int] = [`.
  ```swift
          let roleLimits: [String: Int] = [
              kAXScrollAreaRole: ContainerBudget.scrollAreaLimit,
              kAXTableRole: ContainerBudget.tableLimit,
              kAXOutlineRole: ContainerBudget.outlineLimit,
              kAXListRole: ContainerBudget.listLimit,
              kAXGroupRole: ContainerBudget.groupLimit,
          ]
          let found = root.findAll(roles: roles, roleLimits: roleLimits, maxNodes: ContainerBudget.maxNodes)
  ```
- [ ] **Step 8: Substitute spatial-score tiers/ratios (L202–249) in `scoreTranscriptContainerSpatial`.** Anchored on `private func scoreTranscriptContainerSpatial`. Replace each literal in place:
  ```swift
          let candidateWidthRatio = candidateFrame.width / max(windowFrame.width, SpatialScore.frameDimensionFloor)
          if candidateWidthRatio < SpatialScore.minWidthRatio {
              return SpatialScore.widthRatioPenalty
          }

          let overlapWidth = max(0, min(candidateFrame.maxX, inputFrame.maxX) - max(candidateFrame.minX, inputFrame.minX))
          let overlapRatio = overlapWidth / max(min(candidateFrame.width, inputFrame.width), SpatialScore.overlapFloor)
          if overlapRatio < SpatialScore.minOverlapRatio {
              return SpatialScore.overlapPenalty
          }

          var score: Double = 0
          let role = candidate.role ?? ""
          switch role {
          case kAXScrollAreaRole:
              score += SpatialScore.scrollAreaScore
          case kAXTableRole:
              score += SpatialScore.tableScore
          case kAXListRole, kAXOutlineRole:
              score += SpatialScore.listOutlineScore
          case kAXGroupRole:
              score += SpatialScore.groupScore
          default:
              break
          }

          if candidateFrame.maxY <= inputFrame.minY + SpatialScore.aboveInputSlack {
              score += SpatialScore.aboveInputBonus
          } else {
              score -= -SpatialScore.belowInputPenalty
          }

          score += overlapRatio * SpatialScore.overlapWeight

          let centerX = (candidateFrame.midX - windowFrame.minX) / max(windowFrame.width, SpatialScore.frameDimensionFloor)
          if centerX < SpatialScore.leftCenterRatio {
              score -= -SpatialScore.leftCenterPenalty
          }

          if candidateFrame.minY >= inputFrame.minY {
              score -= -SpatialScore.belowInputStartPenalty
          }

          if candidateFrame.height > inputFrame.height * SpatialScore.tallHeightMultiplier {
              score += SpatialScore.tallHeightBonus
          }
  ```
  > REVIEW NOTE for the implementer: the three subtraction sites (`score -= 2_800`, `score -= 1_600`, `score -= 3_000`) must preserve the exact original arithmetic. To avoid a sign mistake, define the three penalties as POSITIVE constants instead of negative, keeping the original `score -= <value>` form. Use this corrected enum + substitution rather than the negated form above:
  >
  > In the enum, replace the three negative penalty declarations with positive ones:
  > ```swift
  >     static let belowInputPenalty: Double = 2_800
  >     static let leftCenterPenalty: Double = 1_600
  >     static let belowInputStartPenalty: Double = 3_000
  > ```
  > and keep the call sites in their original subtraction form:
  > ```swift
  >         } else {
  >             score -= SpatialScore.belowInputPenalty
  >         }
  > ```
  > ```swift
  >         if centerX < SpatialScore.leftCenterRatio {
  >             score -= SpatialScore.leftCenterPenalty
  >         }
  > ```
  > ```swift
  >         if candidateFrame.minY >= inputFrame.minY {
  >             score -= SpatialScore.belowInputStartPenalty
  >         }
  > ```
  > The two early `return` penalties (`widthRatioPenalty = -8_000`, `overlapPenalty = -7_000`) stay NEGATIVE because the original returns the negative literal directly.
- [ ] **Step 9: Substitute child-bonus budgets & weights (L257–262) in `scoreTranscriptContainerChildBonus`.** Anchored on `private func scoreTranscriptContainerChildBonus`.
  ```swift
          let found = candidate.findAll(
              roles: roles,
              roleLimits: [kAXRowRole: ContainerBudget.childBonusRowLimit, kAXStaticTextRole: ContainerBudget.childBonusTextLimit],
              maxNodes: ContainerBudget.childBonusNodes
          )
          let rowCount = found[kAXRowRole]?.count ?? 0
          let textCount = found[kAXStaticTextRole]?.count ?? 0
          return Double(rowCount * ContainerBudget.childBonusRowWeight) + Double(textCount * ContainerBudget.childBonusTextWeight)
  ```
- [ ] **Step 10: Substitute pane-root hops & ratios (L276, L281–283) in `preferredChatPaneRoot`.** Anchored on `private func preferredChatPaneRoot`.
  ```swift
          let ancestors = ancestorChain(of: inputElement, maxHops: PaneRoot.ancestorMaxHops)

          let filtered = ancestors.filter { candidate in
              guard let frame = candidate.frame else { return false }
              guard isElementLikelyInsideWindow(elementFrame: frame, windowFrame: windowFrame) else { return false }
              let widthRatio = frame.width / max(windowFrame.width, PaneRoot.frameDimensionFloor)
              let heightRatio = frame.height / max(windowFrame.height, PaneRoot.frameDimensionFloor)
              return widthRatio >= PaneRoot.minWidthRatio && heightRatio >= PaneRoot.minHeightRatio
          }
  ```
- [ ] **Step 11: Substitute lineage hops & BFS budgets (L329, L333–334) in `collectFocusedElementLineageCandidates`.** Anchored on `private func collectFocusedElementLineageCandidates`.
  ```swift
          while let element = cursor, hops < InputBudget.lineageMaxHops {
              candidates.append(element)
              let textDescendants = element.findAll(where: { node in
                  guard node.isEnabled else { return false }
                  return node.role == kAXTextAreaRole || node.role == kAXTextFieldRole
              }, limit: InputBudget.lineageTextLimit, maxNodes: InputBudget.lineageTextNodes)
  ```
- [ ] **Step 12: Substitute node-budget floor/multiplier (L307) in `collectMessageInputCandidates`.** Anchored on `private func collectMessageInputCandidates` / `let nodeBudget = max(200, limit * 4)`.
  ```swift
          let nodeBudget = max(InputBudget.nodeBudgetFloor, limit * InputBudget.nodeBudgetMultiplier)
  ```
- [ ] **Step 13: Substitute input-score tiers/ratios (L357–387) in `scoreMessageInputCandidate`.** Anchored on `private func scoreMessageInputCandidate`.
  ```swift
          let role = element.role ?? ""
          let roleScore: Double
          if role == kAXTextAreaRole {
              roleScore = InputScore.textAreaScore
          } else if role == kAXTextFieldRole {
              roleScore = InputScore.textFieldScore
          } else {
              let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
              roleScore = editable ? InputScore.editableScore : 0.0
          }

          let yScore = Double(element.position?.y ?? 0)
          let topPenalty: Double
          if role == kAXTextFieldRole, isLikelySearchField(element, in: window) {
              topPenalty = InputScore.searchPenalty
          } else {
              topPenalty = 0.0
          }

          let locationScore: Double
          if let windowFrame = window.frame, let elementFrame = element.frame {
              if isElementLikelyInsideWindow(elementFrame: elementFrame, windowFrame: windowFrame) {
                  let relativeY = (elementFrame.midY - windowFrame.minY) / max(windowFrame.height, InputScore.heightFloor)
                  locationScore = relativeY > InputScore.lowerHalfRatio ? InputScore.lowerHalfBonus : 0.0
              } else {
                  locationScore = InputScore.outsideWindowPenalty
              }
          } else {
              locationScore = 0.0
          }

          let sizeScore = Double(element.size?.height ?? 0)
          let focusScore = element.isFocused ? InputScore.focusBonus : 0.0
          return roleScore + yScore + sizeScore + focusScore + locationScore - topPenalty
  ```
- [ ] **Step 14: Substitute search-field top-half ratio (L431) in `isLikelySearchField`.** Anchored on `private func isLikelySearchField` / `return relativeY < 0.5`.
  ```swift
          return relativeY < SearchFieldHeuristic.topHalfRatio
  ```
- [ ] **Step 15: Substitute window inset (L480) in `isElementLikelyInsideWindow`.** Anchored on `private func isElementLikelyInsideWindow` / `let expandedWindow = windowFrame.insetBy(dx: -24, dy: -24)`.
  ```swift
          let expandedWindow = windowFrame.insetBy(dx: WindowInset.slack, dy: WindowInset.slack)
  ```
- [ ] **Step 16: Per-constant grep check (values match originals).** Run:
  ```
  grep -nE 'attemptLimit = 36|attemptLimitExpanded = 60|appWideLimit = 60|appFallbackLimit = 90|reactivateSleep: TimeInterval = 0.05|nodeBudgetFloor = 200|nodeBudgetMultiplier = 4|lineageMaxHops = 4|lineageTextLimit = 8|lineageTextNodes = 48' Sources/kmsg/KakaoTalk/MessageContextResolver.swift
  grep -nE 'scrollAreaLimit = 12|tableLimit = 8|outlineLimit = 8|listLimit = 8|groupLimit = 10|maxNodes = 600|topCandidateCount = 3|childBonusRowLimit = 20|childBonusTextLimit = 20|childBonusNodes = 240|childBonusRowWeight = 150|childBonusTextWeight = 25' Sources/kmsg/KakaoTalk/MessageContextResolver.swift
  grep -nE 'minWidthRatio: CGFloat = 0.35|widthRatioPenalty: Double = -8_000|minOverlapRatio: CGFloat = 0.15|overlapPenalty: Double = -7_000|scrollAreaScore: Double = 4_400|tableScore: Double = 3_600|listOutlineScore: Double = 3_000|groupScore: Double = 1_500|aboveInputSlack: CGFloat = 24|aboveInputBonus: Double = 1_300|belowInputPenalty: Double = 2_800|overlapWeight: Double = 2_200|leftCenterRatio: CGFloat = 0.35|leftCenterPenalty: Double = 1_600|belowInputStartPenalty: Double = 3_000|tallHeightMultiplier: CGFloat = 2.2|tallHeightBonus: Double = 320' Sources/kmsg/KakaoTalk/MessageContextResolver.swift
  grep -nE 'ancestorMaxHops = 8|minWidthRatio: CGFloat = 0.45|minHeightRatio: CGFloat = 0.35' Sources/kmsg/KakaoTalk/MessageContextResolver.swift
  grep -nE 'textAreaScore: Double = 12_000.0|textFieldScore: Double = 9_000.0|editableScore: Double = 6_000.0|searchPenalty: Double = 8_000.0|heightFloor: Double = 1.0|lowerHalfRatio: CGFloat = 0.55|lowerHalfBonus: Double = 1_500.0|outsideWindowPenalty: Double = -6_000.0|focusBonus: Double = 2_000.0' Sources/kmsg/KakaoTalk/MessageContextResolver.swift
  grep -nE 'topHalfRatio: CGFloat = 0.5|slack: CGFloat = -24' Sources/kmsg/KakaoTalk/MessageContextResolver.swift
  ```
  Expected counts: 10, 12, 17, 3, 9, 2 (each constant present exactly once with the original value). Confirm no stray numeric `score -= 2_800 / 1_600 / 3_000` remains:
  ```
  grep -nE 'score -= (2_800|1_600|3_000)' Sources/kmsg/KakaoTalk/MessageContextResolver.swift
  ```
  Expected: empty (all three migrated to `SpatialScore.*` positive penalties).
- [ ] **Step 17: DIFF-DISCIPLINE.** Run:
  ```
  git diff Sources/kmsg/KakaoTalk/MessageContextResolver.swift
  ```
  Confirm ONLY: added constant-enum blocks + literal→named substitutions. Crucially verify the three `score -=` sites still SUBTRACT (penalty constants are positive, sign preserved), the two early `return` penalties remain NEGATIVE, and `Double.greatestFiniteMagnitude` / `0.0` neutral values are untouched. No operator flipped, no value changed.
- [ ] **Step 18: BUILD GATE.** Run:
  ```
  swift build
  ```
  Expected: `Build complete!` (exit 0); no new warning vs baseline.
- [ ] **Step 19: GOLDEN.** Run:
  ```
  .build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err; diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err
  .build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check2.out 2> /tmp/check2.err; diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check2.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check2.err
  ```
  Expected: empty diffs (byte-identical). (Use the exact `read_json` invocation recorded for the golden if the flag spelling differs.)
- [ ] **Step 20: COMMIT.** Run:
  ```
  git add Sources/kmsg/KakaoTalk/MessageContextResolver.swift
  git commit -m "refactor(message-context): name transcript-root budgets and scoring tiers"
  ```

---

### Task 3.5: ChatWindowResolver scan profiles, sleeps & scoring tiers

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
- Verify (golden): `send_dryrun`, `status` (this resolver only runs end-to-end on a real send; `send_dryrun` short-circuits before resolution, so golden parity here is the build + structural diff plus the no-regression check on the read-path goldens that share the file's helpers — do NOT trigger a real send to verify)

> The two `SearchScanProfile` literal bundles (fast/expanded) are already a named struct; per scope, extract only the bare numeric LITERALS feeding them and the loose literals elsewhere. Keep each profile field assignment structurally identical.

Literals found:

`requireUsableWindow` (L109–139):
- L115 `ensureMainWindow(timeout: 0.9, mode: .fast, ...)`
- L132 `ensureMainWindow(timeout: 3.0, mode: .recovery, ...)`

`attemptQuickOpenDefense` (L141–171):
- L152 `KakaoTalkApp.forceOpen(timeout: 0.8)`
- L155 `KakaoTalkApp.launch(timeout: 0.8)`
- L162 `ensureMainWindow(timeout: 0.8, mode: .fast, ...)`

`locateSearchField` (L260–310):
- L277 buttons BFS `limit: 24, maxNodes: 220`
- L293 `.prefix(4)`
- L301 `Thread.sleep(forTimeInterval: 0.08)`

`discoverSearchFieldCandidates` (L312–322):
- L314/316/319 `limit: 8, maxNodes: 140`

`waitForMatchingSearchResults` (L324–375): fast/expanded `SearchScanProfile` literals —
- fast: `timeout: 0.22, pollInterval: 0.04, rowLimit: 24, cellLimit: 24, supplementalLimit: 0, candidateNodeBudget: 320, textLimit: 6, textNodeBudget: 80`
- expanded: `timeout: 0.75, pollInterval: 0.05, rowLimit: 120, cellLimit: 120, supplementalLimit: 80, candidateNodeBudget: 1_200, textLimit: 16, textNodeBudget: 220`

`waitForOpenedChatWindow` (L433–440):
- L435 `waitUntil(... timeout: 0.8, pollInterval: 0.05, ...)`

`scoreSearchResult` (L551–574):
- L552 `textScore * 4`
- L555 AXPress `4_000`, L558 AXConfirm `3_000`, L561 row `1_600`, L563 cell `1_200`, L565 button `800`, L568 title `300`, L571 empty-role `-2_000`

`triggerSearchResultOpen` (L576–634):
- L585 `waitUntil(... timeout: 0.24, pollInterval: 0.05, ...)`
- L598 `waitUntil(... timeout: 0.14, pollInterval: 0.05, ...)`
- L609 `waitUntil(... timeout: 0.18, pollInterval: 0.05, ...)`
- L623 `Thread.sleep(forTimeInterval: 0.03)`
- L626 `waitUntil(... timeout: 0.22, pollInterval: 0.05, ...)`

`activationTarget` (L899–915):
- L906 `hops < 4`

`scoreQueryMatch` (L758–814):
- L764 `12_000`, L766 `10_500`, L769 `9_800`, L772 `8_800` + `count >= 2`
- L783 `8_700`, L786 `8_400`, L790 `8_200`, L794 `7_900` + `count >= 2`
- L805 `minLength >= 2`, L809 `6_600`

`collectCandidateTexts` (L719–756):
- L749 textAreas `limit: max(2, textLimit / 2)` → floor `2`, divisor `2`

`findCloseButton` (L950–964):
- L951 buttons BFS `limit: 6, maxNodes: 80`

`waitForWindowClosed` (L966–972):
- L967 `waitUntil(... timeout: 0.9, pollInterval: 0.06, ...)`

`isElementLikelyInsideWindow` (L978–981):
- L979 `insetBy(dx: -24, dy: -24)`

> NOTE: the action strings `"AXClose"`, `"AXPress"`, `"AXConfirm"`, `"AXSelected"`, the failure-code raw strings, and `hops` / `attempts: 1` ArgumentParser counts are NOT magic budgets — LEAVE AS-IS. `attempts: 1` is a verification-attempt count argument (caller-supplied semantic), not a tunable in scope here — LEAVE AS-IS. Honorific suffixes array stays as-is.

- [ ] **Step 1: Add private constant enums at end of `struct ChatWindowResolver`.** Insert immediately before the struct's closing brace, i.e. directly after `isElementLikelyInsideWindow(elementFrame:windowFrame:)` (ends L981) and before the closing `}` on L982. Anchor on the end of `isElementLikelyInsideWindow`:
  ```swift
          let expandedWindow = windowFrame.insetBy(dx: WindowInset.slack, dy: WindowInset.slack)
          return expandedWindow.intersects(elementFrame)
      }

      private enum WindowBudget {
          static let usableFastTimeout: TimeInterval = 0.9
          static let usableRecoveryTimeout: TimeInterval = 3.0
          static let forceOpenTimeout: TimeInterval = 0.8
          static let launchTimeout: TimeInterval = 0.8
          static let quickOpenProbeTimeout: TimeInterval = 0.8
          static let openedChatTimeout: TimeInterval = 0.8
          static let openedChatPoll: TimeInterval = 0.05
          static let closedTimeout: TimeInterval = 0.9
          static let closedPoll: TimeInterval = 0.06
      }

      private enum SearchFieldBudget {
          static let buttonLimit = 24
          static let buttonNodes = 220
          static let buttonPressBatch = 4
          static let buttonRetrySleep: TimeInterval = 0.08
          static let fieldLimit = 8
          static let fieldNodes = 140
          static let closeButtonLimit = 6
          static let closeButtonNodes = 80
          static let activationMaxHops = 4
          static let candidateTextFloor = 2
          static let candidateTextDivisor = 2
      }

      private enum ScanTiming {
          static let fastTimeout: TimeInterval = 0.22
          static let fastPoll: TimeInterval = 0.04
          static let expandedTimeout: TimeInterval = 0.75
          static let expandedPoll: TimeInterval = 0.05
      }

      private enum FastScan {
          static let rowLimit = 24
          static let cellLimit = 24
          static let supplementalLimit = 0
          static let candidateNodeBudget = 320
          static let textLimit = 6
          static let textNodeBudget = 80
      }

      private enum ExpandedScan {
          static let rowLimit = 120
          static let cellLimit = 120
          static let supplementalLimit = 80
          static let candidateNodeBudget = 1_200
          static let textLimit = 16
          static let textNodeBudget = 220
      }

      private enum OpenConfirmTiming {
          static let directTimeout: TimeInterval = 0.24
          static let selectTimeout: TimeInterval = 0.14
          static let enterTimeout: TimeInterval = 0.18
          static let downEnterSleep: TimeInterval = 0.03
          static let downEnterTimeout: TimeInterval = 0.22
          static let poll: TimeInterval = 0.05
      }

      private enum ResultScore {
          static let textWeight = 4
          static let pressBonus = 4_000
          static let confirmBonus = 3_000
          static let rowBonus = 1_600
          static let cellBonus = 1_200
          static let buttonBonus = 800
          static let titleBonus = 300
          static let emptyRolePenalty = -2_000
      }

      private enum QueryMatchScore {
          static let exact = 12_000
          static let prefix = 10_500
          static let contains = 9_800
          static let reverseContains = 8_800
          static let variantExact = 8_700
          static let variantPrefix = 8_400
          static let variantContains = 8_200
          static let variantReverseContains = 7_900
          static let substringFallback = 6_600
          static let minLength = 2
      }

      private enum WindowInset {
          static let slack: CGFloat = -24
      }
  ```
- [ ] **Step 2: Substitute `requireUsableWindow` timeouts (L115, L132).** Anchored inside `private func requireUsableWindow`.
  - L115 (anchored on `if let usableWindow = kakao.ensureMainWindow(timeout: 0.9, mode: .fast, ...`):
    ```swift
          if let usableWindow = kakao.ensureMainWindow(timeout: WindowBudget.usableFastTimeout, mode: .fast, trace: { message in
    ```
  - L132 (anchored on `runner.log("window: escalating to full recovery (3.0s)")` directly above):
    ```swift
          if let usableWindow = kakao.ensureMainWindow(timeout: WindowBudget.usableRecoveryTimeout, mode: .recovery, trace: { message in
    ```
  > NOTE: leave the `"(3.0s)"` log STRING on L131 unchanged — it is descriptive text, not a code literal.
- [ ] **Step 3: Substitute `attemptQuickOpenDefense` timeouts (L152, L155, L162).** Anchored inside `private func attemptQuickOpenDefense`.
  - L152: `_ = KakaoTalkApp.forceOpen(timeout: WindowBudget.forceOpenTimeout)`
  - L155: `_ = KakaoTalkApp.launch(timeout: WindowBudget.launchTimeout)`
  - L162 (anchored on `kakao.activate()` above / `if let usableWindow = kakao.ensureMainWindow(timeout: 0.8, mode: .fast, ...`):
    ```swift
          if let usableWindow = kakao.ensureMainWindow(timeout: WindowBudget.quickOpenProbeTimeout, mode: .fast, trace: { message in
    ```
- [ ] **Step 4: Substitute button/field BFS budgets in `locateSearchField` (L277, L293, L301).** Anchored on `private func locateSearchField`.
  - L277: `let searchButtons = rootWindow.findAll(role: kAXButtonRole, limit: SearchFieldBudget.buttonLimit, maxNodes: SearchFieldBudget.buttonNodes).filter { button in`
  - L293: `for button in searchButtons.prefix(SearchFieldBudget.buttonPressBatch) {`
  - L301: `Thread.sleep(forTimeInterval: SearchFieldBudget.buttonRetrySleep)`
- [ ] **Step 5: Substitute field BFS budgets in `discoverSearchFieldCandidates` (L314, L316, L319).** Three `findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140)` sites. Anchored on `private func discoverSearchFieldCandidates`.
  ```swift
          fields.append(contentsOf: rootWindow.findAll(role: kAXTextFieldRole, limit: SearchFieldBudget.fieldLimit, maxNodes: SearchFieldBudget.fieldNodes))
  ```
  ```swift
              fields.append(contentsOf: focusedWindow.findAll(role: kAXTextFieldRole, limit: SearchFieldBudget.fieldLimit, maxNodes: SearchFieldBudget.fieldNodes))
  ```
  ```swift
              fields.append(contentsOf: mainWindow.findAll(role: kAXTextFieldRole, limit: SearchFieldBudget.fieldLimit, maxNodes: SearchFieldBudget.fieldNodes))
  ```
- [ ] **Step 6: Substitute fast `SearchScanProfile` literals (L325–337) in `waitForMatchingSearchResults`.** Anchored on `let fastProfile = SearchScanProfile(`. Keep every field on its own line; only the literal value tokens change.
  ```swift
          let fastProfile = SearchScanProfile(
              label: "fast",
              timeout: ScanTiming.fastTimeout,
              pollInterval: ScanTiming.fastPoll,
              rowLimit: FastScan.rowLimit,
              cellLimit: FastScan.cellLimit,
              supplementalLimit: FastScan.supplementalLimit,
              candidateNodeBudget: FastScan.candidateNodeBudget,
              textLimit: FastScan.textLimit,
              textNodeBudget: FastScan.textNodeBudget,
              includeSupplementalRoles: false,
              includeApplicationRoot: false
          )
  ```
- [ ] **Step 7: Substitute expanded `SearchScanProfile` literals (L338–350).** Anchored on `let expandedProfile = SearchScanProfile(`.
  ```swift
          let expandedProfile = SearchScanProfile(
              label: "expanded",
              timeout: ScanTiming.expandedTimeout,
              pollInterval: ScanTiming.expandedPoll,
              rowLimit: ExpandedScan.rowLimit,
              cellLimit: ExpandedScan.cellLimit,
              supplementalLimit: ExpandedScan.supplementalLimit,
              candidateNodeBudget: ExpandedScan.candidateNodeBudget,
              textLimit: ExpandedScan.textLimit,
              textNodeBudget: ExpandedScan.textNodeBudget,
              includeSupplementalRoles: true,
              includeApplicationRoot: true
          )
  ```
- [ ] **Step 8: Substitute opened-chat wait (L435) in `waitForOpenedChatWindow`.** Anchored on `private func waitForOpenedChatWindow` / `_ = runner.waitUntil(label: "chat context ready", ...`.
  ```swift
          _ = runner.waitUntil(label: "chat context ready", timeout: WindowBudget.openedChatTimeout, pollInterval: WindowBudget.openedChatPoll, evaluateAfterTimeout: false) {
  ```
- [ ] **Step 9: Substitute candidate-text floor/divisor (L749) in `collectCandidateTexts`.** Anchored on `let textAreas = element.findAll(` / `limit: max(2, textLimit / 2),`.
  ```swift
          let textAreas = element.findAll(
              role: kAXTextAreaRole,
              limit: max(SearchFieldBudget.candidateTextFloor, textLimit / SearchFieldBudget.candidateTextDivisor),
              maxNodes: textNodeBudget
          )
  ```
- [ ] **Step 10: Substitute search-result score tiers (L552–571) in `scoreSearchResult`.** Anchored on `private func scoreSearchResult`.
  ```swift
          var score = candidate.textScore * ResultScore.textWeight
          let element = candidate.element
          if supportsAction("AXPress", on: element) {
              score += ResultScore.pressBonus
          }
          if supportsAction("AXConfirm", on: element) {
              score += ResultScore.confirmBonus
          }
          if element.role == kAXRowRole {
              score += ResultScore.rowBonus
          } else if element.role == kAXCellRole {
              score += ResultScore.cellBonus
          } else if element.role == kAXButtonRole {
              score += ResultScore.buttonBonus
          }
          if let title = element.title, !title.isEmpty {
              score += ResultScore.titleBonus
          }
          if element.role == nil || element.role?.isEmpty == true {
              score += ResultScore.emptyRolePenalty
          }
          return score
  ```
  > NOTE: the original L571 is `score -= 2_000`. Because `emptyRolePenalty` is declared as the NEGATIVE value `-2_000`, the call site must change the operator to `+=` (adding a negative equals subtracting the positive — arithmetically identical). Verify in DIFF-DISCIPLINE that `score += ResultScore.emptyRolePenalty` with `emptyRolePenalty = -2_000` reproduces the original `score -= 2_000` exactly. (Equivalent alternative: declare `emptyRolePenalty = 2_000` and keep `score -= ResultScore.emptyRolePenalty` — pick ONE and stay consistent; the grep in Step 14 assumes the negative-value form.)
- [ ] **Step 11: Substitute open-confirm waits & sleep (L585, L598, L609, L623, L626) in `triggerSearchResultOpen`.** Anchored on `private func triggerSearchResultOpen`.
  - L585 (inside `if tryActivateSearchResult(result, label: "result") {`):
    ```swift
              if runner.waitUntil(label: "search open confirm", timeout: OpenConfirmTiming.directTimeout, pollInterval: OpenConfirmTiming.poll, evaluateAfterTimeout: false, condition: opened) {
    ```
  - L598 (the `if selected, runner.waitUntil(...)` two-line condition):
    ```swift
             runner.waitUntil(label: "search open confirm", timeout: OpenConfirmTiming.selectTimeout, pollInterval: OpenConfirmTiming.poll, evaluateAfterTimeout: false, condition: opened)
    ```
  - L609 (inside the Enter-fallback block):
    ```swift
                  if runner.waitUntil(label: "search open confirm", timeout: OpenConfirmTiming.enterTimeout, pollInterval: OpenConfirmTiming.poll, evaluateAfterTimeout: false, condition: opened) {
    ```
  - L623 (between Down arrow and Enter — DO NOT merge this sleep with anything):
    ```swift
              Thread.sleep(forTimeInterval: OpenConfirmTiming.downEnterSleep)
    ```
  - L626 (the Down+Enter confirm wait):
    ```swift
              if runner.waitUntil(label: "search open confirm", timeout: OpenConfirmTiming.downEnterTimeout, pollInterval: OpenConfirmTiming.poll, evaluateAfterTimeout: false, condition: opened) {
    ```
- [ ] **Step 12: Substitute activation hops (L906) in `activationTarget`.** Anchored on `private func activationTarget` / `while let current = cursor, hops < 4 {`.
  ```swift
          while let current = cursor, hops < SearchFieldBudget.activationMaxHops {
  ```
- [ ] **Step 13: Substitute query-match score tiers (L764–809) in `scoreQueryMatch`.** Anchored on `private func scoreQueryMatch`. Replace each numeric tier; leave the regex/`hasPrefix`/`contains` logic and `count >= 2` comparisons mapped to `QueryMatchScore.minLength`.
  ```swift
          if queryNormalized == candidateNormalized {
              return QueryMatchScore.exact
          }
          if candidateNormalized.hasPrefix(queryNormalized) {
              return QueryMatchScore.prefix
          }
          if candidateNormalized.contains(queryNormalized) {
              return QueryMatchScore.contains
          }
          if queryNormalized.contains(candidateNormalized), candidateNormalized.count >= QueryMatchScore.minLength {
              return QueryMatchScore.reverseContains
          }
  ```
  and the honorific-variant block:
  ```swift
                  if queryVariant == candidateVariant {
                      best = max(best, QueryMatchScore.variantExact)
                      continue
                  }
                  if candidateVariant.hasPrefix(queryVariant) {
                      best = max(best, QueryMatchScore.variantPrefix)
                      continue
                  }
                  if candidateVariant.contains(queryVariant) {
                      best = max(best, QueryMatchScore.variantContains)
                      continue
                  }
                  if queryVariant.contains(candidateVariant), candidateVariant.count >= QueryMatchScore.minLength {
                      best = max(best, QueryMatchScore.variantReverseContains)
                  }
  ```
  and the substring fallback:
  ```swift
          let minLength = min(queryNormalized.count, candidateNormalized.count)
          if minLength >= QueryMatchScore.minLength {
              let shortest = queryNormalized.count <= candidateNormalized.count ? queryNormalized : candidateNormalized
              let longest = queryNormalized.count > candidateNormalized.count ? queryNormalized : candidateNormalized
              if longest.contains(shortest) {
                  return QueryMatchScore.substringFallback
              }
          }
  ```
  > NOTE: the local `let minLength = min(...)` variable name on L804 is unrelated to `QueryMatchScore.minLength`; it stays as a local. Only the literal `2` in `minLength >= 2` and the `count >= 2` comparisons become `QueryMatchScore.minLength`.
- [ ] **Step 14: Substitute close-button BFS budgets (L951) in `findCloseButton`.** Anchored on `private func findCloseButton` / `let buttons = window.findAll(role: kAXButtonRole, limit: 6, maxNodes: 80)`.
  ```swift
          let buttons = window.findAll(role: kAXButtonRole, limit: SearchFieldBudget.closeButtonLimit, maxNodes: SearchFieldBudget.closeButtonNodes)
  ```
- [ ] **Step 15: Substitute window-closed wait (L967) in `waitForWindowClosed`.** Anchored on `private func waitForWindowClosed` / `runner.waitUntil(label: label, timeout: 0.9, pollInterval: 0.06, ...`.
  ```swift
          runner.waitUntil(label: label, timeout: WindowBudget.closedTimeout, pollInterval: WindowBudget.closedPoll, evaluateAfterTimeout: false) {
  ```
- [ ] **Step 16: Substitute window inset (L979) in `isElementLikelyInsideWindow`.** Anchored on `private func isElementLikelyInsideWindow` / `let expandedWindow = windowFrame.insetBy(dx: -24, dy: -24)`.
  ```swift
          let expandedWindow = windowFrame.insetBy(dx: WindowInset.slack, dy: WindowInset.slack)
  ```
- [ ] **Step 17: Per-constant grep check (values match originals).** Run:
  ```
  grep -nE 'usableFastTimeout: TimeInterval = 0.9|usableRecoveryTimeout: TimeInterval = 3.0|forceOpenTimeout: TimeInterval = 0.8|launchTimeout: TimeInterval = 0.8|quickOpenProbeTimeout: TimeInterval = 0.8|openedChatTimeout: TimeInterval = 0.8|openedChatPoll: TimeInterval = 0.05|closedTimeout: TimeInterval = 0.9|closedPoll: TimeInterval = 0.06' Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  grep -nE 'buttonLimit = 24|buttonNodes = 220|buttonPressBatch = 4|buttonRetrySleep: TimeInterval = 0.08|fieldLimit = 8|fieldNodes = 140|closeButtonLimit = 6|closeButtonNodes = 80|activationMaxHops = 4|candidateTextFloor = 2|candidateTextDivisor = 2' Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  grep -nE 'fastTimeout: TimeInterval = 0.22|fastPoll: TimeInterval = 0.04|expandedTimeout: TimeInterval = 0.75|expandedPoll: TimeInterval = 0.05' Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  grep -nE 'rowLimit = 24|cellLimit = 24|supplementalLimit = 0|candidateNodeBudget = 320|textLimit = 6|textNodeBudget = 80' Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  grep -nE 'rowLimit = 120|cellLimit = 120|supplementalLimit = 80|candidateNodeBudget = 1_200|textLimit = 16|textNodeBudget = 220' Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  grep -nE 'directTimeout: TimeInterval = 0.24|selectTimeout: TimeInterval = 0.14|enterTimeout: TimeInterval = 0.18|downEnterSleep: TimeInterval = 0.03|downEnterTimeout: TimeInterval = 0.22|poll: TimeInterval = 0.05' Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  grep -nE 'textWeight = 4|pressBonus = 4_000|confirmBonus = 3_000|rowBonus = 1_600|cellBonus = 1_200|buttonBonus = 800|titleBonus = 300|emptyRolePenalty = -2_000' Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  grep -nE 'exact = 12_000|prefix = 10_500|contains = 9_800|reverseContains = 8_800|variantExact = 8_700|variantPrefix = 8_400|variantContains = 8_200|variantReverseContains = 7_900|substringFallback = 6_600|minLength = 2' Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  ```
  Expected counts: 9, 11, 4, 6, 6, 6, 8, 10 (each constant present once with the original value). Then confirm the two `SearchScanProfile(` constructions are still present and structurally intact:
  ```
  grep -c "SearchScanProfile(" Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  ```
  Expected: `2` (the struct definition usage plus the two literals collapse — verify there are still exactly two construction sites; the struct `private struct SearchScanProfile {` declaration does not match `SearchScanProfile(`).
- [ ] **Step 18: DIFF-DISCIPLINE.** Run:
  ```
  git diff Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  ```
  Confirm ONLY: added constant-enum blocks + literal→named substitutions. Verify: every `waitUntil(... evaluateAfterTimeout: false ...)` keeps `evaluateAfterTimeout: false` and is NOT flattened; the L623 `Thread.sleep` between Down arrow and Enter is preserved as a standalone statement (not merged); the `score += ResultScore.emptyRolePenalty` (with negative constant) reproduces the original `score -= 2_000`; both `SearchScanProfile` field lists keep `includeSupplementalRoles`/`includeApplicationRoot` booleans as literal `false`/`true` (booleans are not in scope). No value changed.
- [ ] **Step 19: BUILD GATE.** Run:
  ```
  swift build
  ```
  Expected: `Build complete!` (exit 0); no new warning vs baseline.
- [ ] **Step 20: GOLDEN.** Run:
  ```
  .build/debug/kmsg status --verbose > /tmp/check.out 2> /tmp/check.err; diff /tmp/kmsg-golden-baseline/status.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check.err
  .build/debug/kmsg send "테헤란로 죽돌이" "x" --dry-run > /tmp/check2.out 2> /tmp/check2.err; diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check2.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check2.err
  ```
  Expected: empty diffs (byte-identical). Do NOT perform a live send to verify the resolver's hot path; build + structural diff + these goldens are the gate.
- [ ] **Step 21: COMMIT.** Run:
  ```
  git add Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  git commit -m "refactor(chat-resolver): name scan profiles and scoring tiers"
  ```

---

### Task 3.6: SendCommand timeouts, sleeps, scoring tiers & search profiles

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift`
- Verify (golden): `send_dryrun`, `status`

Literals found:

`requireUsableWindow` (L167–181):
- L168 `ensureMainWindow(timeout: 1.2, mode: .fast, ...)`
- L175 `ensureMainWindow(timeout: 3.0, mode: .recovery, ...)`

`scoreSearchResult` (L257–277):
- L259 AXPress `10_000`, L261 AXConfirm `8_000`, L265 row `4_000`, L267 cell `3_000`, L270 title `500`, L273 empty-role `-2_000`

`triggerSearchResultOpen` (L279–333):
- L290 `waitUntil(... timeout: 0.3, pollInterval: 0.05, ...)`
- L302 `waitUntil(... timeout: 0.18, pollInterval: 0.05, ...)`
- L311 `waitUntil(... timeout: 0.28, pollInterval: 0.05, ...)`
- L322 `Thread.sleep(forTimeInterval: 0.03)`
- L325 `waitUntil(... timeout: 0.32, pollInterval: 0.05, ...)`

`locateSearchField` (L435–486):
- L453 buttons BFS `limit: 24, maxNodes: 220`
- L469 `.prefix(4)`
- L477 `Thread.sleep(forTimeInterval: 0.08)`

`discoverSearchFieldCandidates` (L488–498):
- L490/492/495 `limit: 8, maxNodes: 140`

`waitForMatchingSearchResults` (L500–512):
- L502 `waitUntil(... timeout: 0.4, pollInterval: 0.05)`

`findMatchingSearchResults` (L514–534):
- L525 `findAll(role: kAXRowRole, limit: 24, maxNodes: 260)` + `findAll(role: kAXCellRole, limit: 24, maxNodes: 260)`

`waitForOpenedChatWindow` (L536–548):
- L543 `waitUntil(... timeout: 0.8, pollInterval: 0.05, ...)`

`containsText` (L658–669):
- L665 `findAll(role: kAXStaticTextRole, limit: 5, maxNodes: 48)`

`sendMessageToWindow` (L671–721):
- L675 `Thread.sleep(forTimeInterval: 0.1)`
- L701–702 first enter `reflectionTimeout: 0.24, retryDelay: 0.06`
- L711–712 retry enter `reflectionTimeout: 0.34, retryDelay: 0.06`

`resolveMessageInputField` (L751–823):
- L777/782/787 `attempt == 1 ? 36 : 60`
- L799 app-wide `limit: 60`
- L813 `Thread.sleep(forTimeInterval: 0.05)`
- L816 app-fallback `limit: 90`

`collectMessageInputCandidates` (L825–841):
- L826 `max(200, limit * 4)`

`collectFocusedElementLineageCandidates` (L843–860):
- L848 `hops < 4`
- L852–853 `limit: 8, maxNodes: 48`

`scoreMessageInputCandidate` (L915–951):
- L923 `12_000.0`, L925 `9_000.0`, L928 `6_000.0`, L933 search penalty `8_000.0`, L940 `max(windowFrame.height, 1.0)`, L941 `relativeY > 0.55 ? 1_500.0 : 0.0`, L943 `-6_000.0`, L949 focus `2_000.0`

`forceTypeIntoChatWindow` (L878–891):
- L883 `Thread.sleep(forTimeInterval: 0.12)`
- L889 `Thread.sleep(forTimeInterval: 0.08)`

`isLikelySearchField` (L617–645):
- L643 `relativeY < 0.5`

`isElementLikelyInsideWindow` (L953–956):
- L954 `insetBy(dx: -24, dy: -24)`

> NOTE: `for attempt in 1...2` (L773) is a control-flow bound — LEAVE AS-IS. `attempts:` args throughout are verification-attempt semantics — LEAVE AS-IS. Action/role string literals — LEAVE AS-IS.

- [ ] **Step 1: Add private constant enums to `struct SendCommand`.** Insert immediately before the struct's closing brace, i.e. directly after `isElementLikelyInsideWindow(elementFrame:windowFrame:)` (ends L956) and before the closing `}` on L957. Anchor on the end of `isElementLikelyInsideWindow`:
  ```swift
          let expandedWindow = windowFrame.insetBy(dx: WindowInset.slack, dy: WindowInset.slack)
          return expandedWindow.intersects(elementFrame)
      }

      private enum WindowBudget {
          static let usableFastTimeout: TimeInterval = 1.2
          static let usableRecoveryTimeout: TimeInterval = 3.0
          static let openedChatTimeout: TimeInterval = 0.8
          static let openedChatPoll: TimeInterval = 0.05
      }

      private enum ResultScore {
          static let pressBonus = 10_000
          static let confirmBonus = 8_000
          static let rowBonus = 4_000
          static let cellBonus = 3_000
          static let titleBonus = 500
          static let emptyRolePenalty = -2_000
      }

      private enum OpenConfirmTiming {
          static let directTimeout: TimeInterval = 0.3
          static let selectTimeout: TimeInterval = 0.18
          static let enterTimeout: TimeInterval = 0.28
          static let downEnterSleep: TimeInterval = 0.03
          static let downEnterTimeout: TimeInterval = 0.32
          static let poll: TimeInterval = 0.05
      }

      private enum SearchFieldBudget {
          static let buttonLimit = 24
          static let buttonNodes = 220
          static let buttonPressBatch = 4
          static let buttonRetrySleep: TimeInterval = 0.08
          static let fieldLimit = 8
          static let fieldNodes = 140
          static let resultsTimeout: TimeInterval = 0.4
          static let resultsPoll: TimeInterval = 0.05
          static let candidateRowLimit = 24
          static let candidateCellLimit = 24
          static let candidateNodes = 260
          static let containsTextLimit = 5
          static let containsTextNodes = 48
      }

      private enum InputBudget {
          static let attemptLimit = 36
          static let attemptLimitExpanded = 60
          static let appWideLimit = 60
          static let appFallbackLimit = 90
          static let reactivateSleep: TimeInterval = 0.05
          static let nodeBudgetFloor = 200
          static let nodeBudgetMultiplier = 4
          static let lineageMaxHops = 4
          static let lineageTextLimit = 8
          static let lineageTextNodes = 48
      }

      private enum SendTiming {
          static let raiseSettleSleep: TimeInterval = 0.1
          static let firstEnterReflection: TimeInterval = 0.24
          static let firstEnterRetryDelay: TimeInterval = 0.06
          static let retryEnterReflection: TimeInterval = 0.34
          static let retryEnterRetryDelay: TimeInterval = 0.06
          static let forceRaiseSettleSleep: TimeInterval = 0.12
          static let forceSendSettleSleep: TimeInterval = 0.08
      }

      private enum InputScore {
          static let textAreaScore: Double = 12_000.0
          static let textFieldScore: Double = 9_000.0
          static let editableScore: Double = 6_000.0
          static let searchPenalty: Double = 8_000.0
          static let heightFloor: Double = 1.0
          static let lowerHalfRatio: CGFloat = 0.55
          static let lowerHalfBonus: Double = 1_500.0
          static let outsideWindowPenalty: Double = -6_000.0
          static let focusBonus: Double = 2_000.0
      }

      private enum SearchFieldHeuristic {
          static let topHalfRatio: CGFloat = 0.5
      }

      private enum WindowInset {
          static let slack: CGFloat = -24
      }
  ```
- [ ] **Step 2: Substitute `requireUsableWindow` timeouts (L168, L175).** Anchored inside `private func requireUsableWindow`.
  - L168: `if let usableWindow = kakao.ensureMainWindow(timeout: WindowBudget.usableFastTimeout, mode: .fast, trace: { message in`
  - L175: `if let usableWindow = kakao.ensureMainWindow(timeout: WindowBudget.usableRecoveryTimeout, mode: .recovery, trace: { message in`
- [ ] **Step 3: Substitute search-result score tiers (L259–273) in `scoreSearchResult`.** Anchored on `private func scoreSearchResult`.
  ```swift
          var score = 0
          if supportsAction("AXPress", on: element) {
              score += ResultScore.pressBonus
          }
          if supportsAction("AXConfirm", on: element) {
              score += ResultScore.confirmBonus
          }
          if element.role == kAXRowRole {
              score += ResultScore.rowBonus
          } else if element.role == kAXCellRole {
              score += ResultScore.cellBonus
          }
          if let title = element.title, !title.isEmpty {
              score += ResultScore.titleBonus
          }
          if element.role == nil || element.role?.isEmpty == true {
              score += ResultScore.emptyRolePenalty
          }
          return score
  ```
  > NOTE: original L273 is `score -= 2_000`; with `emptyRolePenalty = -2_000` the call site becomes `score += ResultScore.emptyRolePenalty` (adding a negative = subtracting the positive; arithmetically identical). Stay consistent with the negative-value form (the Step 11 grep assumes it).
- [ ] **Step 4: Substitute open-confirm waits & sleep (L290, L302, L311, L322, L325) in `triggerSearchResultOpen`.** Anchored on `private func triggerSearchResultOpen`.
  - L290: `if runner.waitUntil(label: "search open confirm", timeout: OpenConfirmTiming.directTimeout, pollInterval: OpenConfirmTiming.poll, evaluateAfterTimeout: false, condition: opened) {`
  - L302 (the one-line `if selected && runner.waitUntil(...)`): `if selected && runner.waitUntil(label: "search open confirm", timeout: OpenConfirmTiming.selectTimeout, pollInterval: OpenConfirmTiming.poll, evaluateAfterTimeout: false, condition: opened) {`
  - L311: `if runner.waitUntil(label: "search open confirm", timeout: OpenConfirmTiming.enterTimeout, pollInterval: OpenConfirmTiming.poll, evaluateAfterTimeout: false, condition: opened) {`
  - L322 (between Down arrow and Enter — keep standalone): `Thread.sleep(forTimeInterval: OpenConfirmTiming.downEnterSleep)`
  - L325: `if runner.waitUntil(label: "search open confirm", timeout: OpenConfirmTiming.downEnterTimeout, pollInterval: OpenConfirmTiming.poll, evaluateAfterTimeout: false, condition: opened) {`
- [ ] **Step 5: Substitute button/field BFS budgets in `locateSearchField` (L453, L469, L477).** Anchored on `private func locateSearchField`.
  - L453: `let searchButtons = rootWindow.findAll(role: kAXButtonRole, limit: SearchFieldBudget.buttonLimit, maxNodes: SearchFieldBudget.buttonNodes).filter { button in`
  - L469: `for button in searchButtons.prefix(SearchFieldBudget.buttonPressBatch) {`
  - L477: `Thread.sleep(forTimeInterval: SearchFieldBudget.buttonRetrySleep)`
- [ ] **Step 6: Substitute field BFS budgets in `discoverSearchFieldCandidates` (L490, L492, L495).** Three identical sites. Anchored on `private func discoverSearchFieldCandidates`.
  ```swift
          fields.append(contentsOf: rootWindow.findAll(role: kAXTextFieldRole, limit: SearchFieldBudget.fieldLimit, maxNodes: SearchFieldBudget.fieldNodes))
  ```
  ```swift
              fields.append(contentsOf: focusedWindow.findAll(role: kAXTextFieldRole, limit: SearchFieldBudget.fieldLimit, maxNodes: SearchFieldBudget.fieldNodes))
  ```
  ```swift
              fields.append(contentsOf: mainWindow.findAll(role: kAXTextFieldRole, limit: SearchFieldBudget.fieldLimit, maxNodes: SearchFieldBudget.fieldNodes))
  ```
- [ ] **Step 7: Substitute results wait (L502) in `waitForMatchingSearchResults`.** Anchored on `private func waitForMatchingSearchResults` / `let found = runner.waitUntil(label: "search results", ...`.
  ```swift
          let found = runner.waitUntil(label: "search results", timeout: SearchFieldBudget.resultsTimeout, pollInterval: SearchFieldBudget.resultsPoll) {
  ```
- [ ] **Step 8: Substitute candidate BFS budgets (L525) in `findMatchingSearchResults`.** Anchored on `private func findMatchingSearchResults` / `let candidates = (root.findAll(role: kAXRowRole, ...`.
  ```swift
              let candidates = (root.findAll(role: kAXRowRole, limit: SearchFieldBudget.candidateRowLimit, maxNodes: SearchFieldBudget.candidateNodes) + root.findAll(role: kAXCellRole, limit: SearchFieldBudget.candidateCellLimit, maxNodes: SearchFieldBudget.candidateNodes)).filter { element in
  ```
- [ ] **Step 9: Substitute opened-chat wait (L543) in `waitForOpenedChatWindow`.** Anchored on `private func waitForOpenedChatWindow` / `_ = runner.waitUntil(label: "chat context ready", ...`.
  ```swift
          _ = runner.waitUntil(label: "chat context ready", timeout: WindowBudget.openedChatTimeout, pollInterval: WindowBudget.openedChatPoll, evaluateAfterTimeout: false) {
  ```
- [ ] **Step 10: Substitute static-text BFS budgets (L665) in `containsText`.** Anchored on `private func containsText` / `let staticTexts = element.findAll(role: kAXStaticTextRole, limit: 5, maxNodes: 48)`.
  ```swift
          let staticTexts = element.findAll(role: kAXStaticTextRole, limit: SearchFieldBudget.containsTextLimit, maxNodes: SearchFieldBudget.containsTextNodes)
  ```
- [ ] **Step 11: Substitute send sleeps & enter timeouts (L675, L701–702, L711–712) in `sendMessageToWindow`.** Anchored on `private func sendMessageToWindow`.
  - L675 (after `_ = tryRaiseWindow(window, runner: runner)`): `Thread.sleep(forTimeInterval: SendTiming.raiseSettleSleep)`
  - L697–703 first enter:
    ```swift
          var sendSucceeded = runner.pressEnterWithVerification(
              on: input,
              label: "message input",
              attempts: 1,
              reflectionTimeout: SendTiming.firstEnterReflection,
              retryDelay: SendTiming.firstEnterRetryDelay
          )
    ```
  - L707–713 retry enter:
    ```swift
              sendSucceeded = runner.pressEnterWithVerification(
                  on: input,
                  label: "message input retry",
                  attempts: 1,
                  reflectionTimeout: SendTiming.retryEnterReflection,
                  retryDelay: SendTiming.retryEnterRetryDelay
              )
    ```
- [ ] **Step 12: Substitute attempt-scaled limits, app limits & sleep (L777, L782, L787, L799, L813, L816) in `resolveMessageInputField`.** Anchored on `private func resolveMessageInputField`. Three `attempt == 1 ? 36 : 60` sites:
  - L777: `let focusedWindowCandidates = collectMessageInputCandidates(from: focusedWindow, limit: attempt == 1 ? InputBudget.attemptLimit : InputBudget.attemptLimitExpanded)`
  - L782: `let chatWindowCandidates = collectMessageInputCandidates(from: chatWindow, limit: attempt == 1 ? InputBudget.attemptLimit : InputBudget.attemptLimitExpanded)`
  - L787: `let chatWindowCandidates = collectMessageInputCandidates(from: chatWindow, limit: attempt == 1 ? InputBudget.attemptLimit : InputBudget.attemptLimitExpanded)`
  - L799 (inside `if attempt > 1 {`): `let appCandidates = collectMessageInputCandidates(from: kakao.applicationElement, limit: InputBudget.appWideLimit)`
  - L813 (after `_ = runner.focusWithVerification(chatWindow, label: "chat window", attempts: 1)`): `Thread.sleep(forTimeInterval: InputBudget.reactivateSleep)`
  - L816 (final fallback): `let appCandidates = collectMessageInputCandidates(from: kakao.applicationElement, limit: InputBudget.appFallbackLimit)`
- [ ] **Step 13: Substitute node-budget floor/multiplier (L826) in `collectMessageInputCandidates`.** Anchored on `private func collectMessageInputCandidates` / `let nodeBudget = max(200, limit * 4)`.
  ```swift
          let nodeBudget = max(InputBudget.nodeBudgetFloor, limit * InputBudget.nodeBudgetMultiplier)
  ```
- [ ] **Step 14: Substitute lineage hops & BFS budgets (L848, L852–853) in `collectFocusedElementLineageCandidates`.** Anchored on `private func collectFocusedElementLineageCandidates`.
  ```swift
          while let element = cursor, hops < InputBudget.lineageMaxHops {
              candidates.append(element)
              let textDescendants = element.findAll(where: { node in
                  guard node.isEnabled else { return false }
                  return node.role == kAXTextAreaRole || node.role == kAXTextFieldRole
              }, limit: InputBudget.lineageTextLimit, maxNodes: InputBudget.lineageTextNodes)
  ```
- [ ] **Step 15: Substitute force-typing sleeps (L883, L889) in `forceTypeIntoChatWindow`.** Anchored on `private func forceTypeIntoChatWindow`.
  - L883 (after `_ = tryRaiseWindow(chatWindow, runner: runner)`): `Thread.sleep(forTimeInterval: SendTiming.forceRaiseSettleSleep)`
  - L889 (after `runner.pressEnterKey()`): `Thread.sleep(forTimeInterval: SendTiming.forceSendSettleSleep)`
- [ ] **Step 16: Substitute input-score tiers/ratios (L923–949) in `scoreMessageInputCandidate`.** Anchored on `private func scoreMessageInputCandidate`.
  ```swift
          let role = element.role ?? ""
          let roleScore: Double
          if role == kAXTextAreaRole {
              roleScore = InputScore.textAreaScore
          } else if role == kAXTextFieldRole {
              roleScore = InputScore.textFieldScore
          } else {
              let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
              roleScore = editable ? InputScore.editableScore : 0.0
          }
          let yScore = Double(element.position?.y ?? 0)
          let topPenalty: Double
          if role == kAXTextFieldRole, isLikelySearchField(element, in: window) {
              topPenalty = InputScore.searchPenalty
          } else {
              topPenalty = 0.0
          }
          let locationScore: Double
          if let windowFrame = window.frame, let elementFrame = element.frame {
              if isElementLikelyInsideWindow(elementFrame: elementFrame, windowFrame: windowFrame) {
                  let relativeY = (elementFrame.midY - windowFrame.minY) / max(windowFrame.height, InputScore.heightFloor)
                  locationScore = relativeY > InputScore.lowerHalfRatio ? InputScore.lowerHalfBonus : 0.0
              } else {
                  locationScore = InputScore.outsideWindowPenalty
              }
          } else {
              locationScore = 0.0
          }
          let sizeScore = Double(element.size?.height ?? 0)
          let focusScore = element.isFocused ? InputScore.focusBonus : 0.0
          return roleScore + yScore + sizeScore + focusScore + locationScore - topPenalty
  ```
- [ ] **Step 17: Substitute search-field top-half ratio (L643) in `isLikelySearchField`.** Anchored on `private func isLikelySearchField` / `return relativeY < 0.5`.
  ```swift
          return relativeY < SearchFieldHeuristic.topHalfRatio
  ```
- [ ] **Step 18: Substitute window inset (L954) in `isElementLikelyInsideWindow`.** Anchored on `private func isElementLikelyInsideWindow` / `let expandedWindow = windowFrame.insetBy(dx: -24, dy: -24)`.
  ```swift
          let expandedWindow = windowFrame.insetBy(dx: WindowInset.slack, dy: WindowInset.slack)
  ```
- [ ] **Step 19: Per-constant grep check (values match originals).** Run:
  ```
  grep -nE 'usableFastTimeout: TimeInterval = 1.2|usableRecoveryTimeout: TimeInterval = 3.0|openedChatTimeout: TimeInterval = 0.8|openedChatPoll: TimeInterval = 0.05' Sources/kmsg/Commands/SendCommand.swift
  grep -nE 'pressBonus = 10_000|confirmBonus = 8_000|rowBonus = 4_000|cellBonus = 3_000|titleBonus = 500|emptyRolePenalty = -2_000' Sources/kmsg/Commands/SendCommand.swift
  grep -nE 'directTimeout: TimeInterval = 0.3|selectTimeout: TimeInterval = 0.18|enterTimeout: TimeInterval = 0.28|downEnterSleep: TimeInterval = 0.03|downEnterTimeout: TimeInterval = 0.32|poll: TimeInterval = 0.05' Sources/kmsg/Commands/SendCommand.swift
  grep -nE 'buttonLimit = 24|buttonNodes = 220|buttonPressBatch = 4|buttonRetrySleep: TimeInterval = 0.08|fieldLimit = 8|fieldNodes = 140|resultsTimeout: TimeInterval = 0.4|resultsPoll: TimeInterval = 0.05|candidateRowLimit = 24|candidateCellLimit = 24|candidateNodes = 260|containsTextLimit = 5|containsTextNodes = 48' Sources/kmsg/Commands/SendCommand.swift
  grep -nE 'attemptLimit = 36|attemptLimitExpanded = 60|appWideLimit = 60|appFallbackLimit = 90|reactivateSleep: TimeInterval = 0.05|nodeBudgetFloor = 200|nodeBudgetMultiplier = 4|lineageMaxHops = 4|lineageTextLimit = 8|lineageTextNodes = 48' Sources/kmsg/Commands/SendCommand.swift
  grep -nE 'raiseSettleSleep: TimeInterval = 0.1|firstEnterReflection: TimeInterval = 0.24|firstEnterRetryDelay: TimeInterval = 0.06|retryEnterReflection: TimeInterval = 0.34|retryEnterRetryDelay: TimeInterval = 0.06|forceRaiseSettleSleep: TimeInterval = 0.12|forceSendSettleSleep: TimeInterval = 0.08' Sources/kmsg/Commands/SendCommand.swift
  grep -nE 'textAreaScore: Double = 12_000.0|textFieldScore: Double = 9_000.0|editableScore: Double = 6_000.0|searchPenalty: Double = 8_000.0|heightFloor: Double = 1.0|lowerHalfRatio: CGFloat = 0.55|lowerHalfBonus: Double = 1_500.0|outsideWindowPenalty: Double = -6_000.0|focusBonus: Double = 2_000.0' Sources/kmsg/Commands/SendCommand.swift
  grep -nE 'topHalfRatio: CGFloat = 0.5|slack: CGFloat = -24' Sources/kmsg/Commands/SendCommand.swift
  ```
  Expected counts: 4, 6, 6, 13, 10, 7, 9, 2. Then confirm no orphan numeric `Thread.sleep` / `score -= 2_000` remain:
  ```
  grep -nE 'Thread.sleep\(forTimeInterval: [0-9]' Sources/kmsg/Commands/SendCommand.swift
  grep -n 'score -= 2_000' Sources/kmsg/Commands/SendCommand.swift
  ```
  Expected: both empty.
- [ ] **Step 20: DIFF-DISCIPLINE.** Run:
  ```
  git diff Sources/kmsg/Commands/SendCommand.swift
  ```
  Confirm ONLY: added constant-enum blocks + literal→named substitutions. Verify each `pressEnterWithVerification(... reflectionTimeout:... retryDelay:...)` keeps both labeled args in original order; the L322 Down→Enter `Thread.sleep` stays standalone; every `waitUntil(... evaluateAfterTimeout: false ...)` keeps that flag and is not flattened; `score += ResultScore.emptyRolePenalty` (negative constant) reproduces `score -= 2_000`. No value changed.
- [ ] **Step 21: BUILD GATE.** Run:
  ```
  swift build
  ```
  Expected: `Build complete!` (exit 0); no new warning vs baseline.
- [ ] **Step 22: GOLDEN.** Run:
  ```
  .build/debug/kmsg send "테헤란로 죽돌이" "x" --dry-run > /tmp/check.out 2> /tmp/check.err; diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check.err
  .build/debug/kmsg status --verbose > /tmp/check2.out 2> /tmp/check2.err; diff /tmp/kmsg-golden-baseline/status.out /tmp/check2.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check2.err
  ```
  Expected: empty diffs (byte-identical). Do NOT trigger a live send; `--dry-run` short-circuits before the hot path, so build + structural diff are the substantive gate for the send path.
- [ ] **Step 23: COMMIT.** Run:
  ```
  git add Sources/kmsg/Commands/SendCommand.swift
  git commit -m "refactor(send): name send-path timeouts and scoring tiers"
  ```

---

### Task 3.7: CacheCommand warmup budgets, sleeps & scoring tiers

**Files:**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CacheCommand.swift`
- Verify (golden): `cache_export`, `status`

> CacheCommand's free functions live at file scope (after the command structs). Because there is no enclosing type to nest a `private enum` into without disturbing the file-scoped helpers, add ONE `private enum` block at FILE scope (file-private), placed immediately after the `struct CacheCommand { ... }` declaration block and before `struct CacheStatusCommand`. This keeps it per-file and file-private, matching the file's existing top-level `private func` helper style.

Literals found:

`CacheWarmupCommand.run()` (L105–192):
- L115 `ensureMainWindow(timeout: 1.2, mode: .fast, ...)`
- L117 `ensureMainWindow(timeout: 3.0, mode: .recovery, ...)`
- L144 `waitUntil(... timeout: 0.8, pollInterval: 0.05, ...)`
- L149 `Thread.sleep(forTimeInterval: 0.03)`
- L151 `waitUntil(... timeout: 0.8, pollInterval: 0.05, ...)`

`locateWarmupSearchField` (L205–238):
- L211 buttons BFS `limit: 18, maxNodes: 220`
- L224 `.prefix(3)`
- L231 `Thread.sleep(forTimeInterval: 0.05)`

`discoverWarmupSearchCandidates` (L240–250):
- L242/244/247 `limit: 8, maxNodes: 140`

`locateWarmupMessageInput` (L263–282):
- L270 `collectWarmupInputCandidates(from: root, limit: 70)`
- L272 `collectWarmupInputCandidates(from: focusedWindow, limit: 70)`
- L274 `collectWarmupInputCandidates(from: kakao.applicationElement, limit: 90)`

`collectWarmupInputCandidates` (L284–300):
- L285 `max(200, limit * 4)`

`warmupLooksLikeSearchField` (L348–365):
- L363 `relativeY < 0.45`

`warmupInputScore` (L367–387):
- L375 `12_000.0`, L377 `9_000.0`, L380 `6_000.0`, L385 focus `2_000.0`

> NOTE: `[WINDOW_NOT_READY]` is a failure-code string — LEAVE AS-IS. `Int(PATH_MAX)` and the `realpath`/UTF8 decode buffer logic in `resolvedURL`/`physicalCurrentDirectoryPath` are POSIX path handling, NOT magic budgets — LEAVE AS-IS. `attempts: 1` args — LEAVE AS-IS.

- [ ] **Step 1: Add ONE file-private `WarmupBudget` enum at file scope.** Insert immediately after the closing `}` of `struct CacheCommand { ... }` (ends L19) and before `struct CacheStatusCommand` (L21). Anchor on the `struct CacheCommand` closing brace block:
  ```swift
  private enum WarmupBudget {
      static let usableFastTimeout: TimeInterval = 1.2
      static let usableRecoveryTimeout: TimeInterval = 3.0
      static let chatOpenTimeout: TimeInterval = 0.8
      static let chatOpenPoll: TimeInterval = 0.05
      static let downEnterSleep: TimeInterval = 0.03
      static let buttonLimit = 18
      static let buttonNodes = 220
      static let buttonPressBatch = 3
      static let buttonRetrySleep: TimeInterval = 0.05
      static let fieldLimit = 8
      static let fieldNodes = 140
      static let inputCandidateLimit = 70
      static let appInputCandidateLimit = 90
      static let nodeBudgetFloor = 200
      static let nodeBudgetMultiplier = 4
      static let searchFieldTopRatio: CGFloat = 0.45
  }

  private enum WarmupScore {
      static let textAreaScore: Double = 12_000.0
      static let textFieldScore: Double = 9_000.0
      static let editableScore: Double = 6_000.0
      static let focusBonus: Double = 2_000.0
  }
  ```
- [ ] **Step 2: Substitute `ensureMainWindow` timeouts (L115, L117) in `CacheWarmupCommand.run()`.** Anchored on `guard let usableWindow = kakao.ensureMainWindow(timeout: 1.2, mode: .fast, ...`.
  ```swift
          guard let usableWindow = kakao.ensureMainWindow(timeout: WarmupBudget.usableFastTimeout, mode: .fast, trace: { message in
              runner.log(message)
          }) ?? kakao.ensureMainWindow(timeout: WarmupBudget.usableRecoveryTimeout, mode: .recovery, trace: { message in
  ```
- [ ] **Step 3: Substitute warmup chat-open waits & Down+Enter sleep (L144, L149, L151).** Anchored inside the `if let recipient, !recipient.isEmpty {` block.
  - L144:
    ```swift
                  let openedByEnter = runner.waitUntil(label: "warmup chat open", timeout: WarmupBudget.chatOpenTimeout, pollInterval: WarmupBudget.chatOpenPoll, evaluateAfterTimeout: false) {
    ```
  - L149 (between Down arrow and Enter — keep standalone): `Thread.sleep(forTimeInterval: WarmupBudget.downEnterSleep)`
  - L151:
    ```swift
                      _ = runner.waitUntil(label: "warmup chat open", timeout: WarmupBudget.chatOpenTimeout, pollInterval: WarmupBudget.chatOpenPoll, evaluateAfterTimeout: false) {
    ```
- [ ] **Step 4: Substitute button BFS budgets, batch & sleep (L211, L224, L231) in `locateWarmupSearchField`.** Anchored on `private func locateWarmupSearchField`.
  - L211: `let buttons = rootWindow.findAll(role: kAXButtonRole, limit: WarmupBudget.buttonLimit, maxNodes: WarmupBudget.buttonNodes).filter { button in`
  - L224: `for button in buttons.prefix(WarmupBudget.buttonPressBatch) {`
  - L231: `Thread.sleep(forTimeInterval: WarmupBudget.buttonRetrySleep)`
- [ ] **Step 5: Substitute field BFS budgets in `discoverWarmupSearchCandidates` (L242, L244, L247).** Three identical sites. Anchored on `private func discoverWarmupSearchCandidates`.
  ```swift
      fields.append(contentsOf: rootWindow.findAll(role: kAXTextFieldRole, limit: WarmupBudget.fieldLimit, maxNodes: WarmupBudget.fieldNodes))
  ```
  ```swift
          fields.append(contentsOf: focusedWindow.findAll(role: kAXTextFieldRole, limit: WarmupBudget.fieldLimit, maxNodes: WarmupBudget.fieldNodes))
  ```
  ```swift
          fields.append(contentsOf: mainWindow.findAll(role: kAXTextFieldRole, limit: WarmupBudget.fieldLimit, maxNodes: WarmupBudget.fieldNodes))
  ```
- [ ] **Step 6: Substitute input-candidate limits (L270, L272, L274) in `locateWarmupMessageInput`.** Anchored on `private func locateWarmupMessageInput`.
  - L270: `candidates.append(contentsOf: collectWarmupInputCandidates(from: root, limit: WarmupBudget.inputCandidateLimit))`
  - L272: `candidates.append(contentsOf: collectWarmupInputCandidates(from: focusedWindow, limit: WarmupBudget.inputCandidateLimit))`
  - L274: `candidates.append(contentsOf: collectWarmupInputCandidates(from: kakao.applicationElement, limit: WarmupBudget.appInputCandidateLimit))`
- [ ] **Step 7: Substitute node-budget floor/multiplier (L285) in `collectWarmupInputCandidates`.** Anchored on `private func collectWarmupInputCandidates` / `let nodeBudget = max(200, limit * 4)`.
  ```swift
      let nodeBudget = max(WarmupBudget.nodeBudgetFloor, limit * WarmupBudget.nodeBudgetMultiplier)
  ```
- [ ] **Step 8: Substitute search-field top ratio (L363) in `warmupLooksLikeSearchField`.** Anchored on `private func warmupLooksLikeSearchField` / `return relativeY < 0.45`.
  ```swift
      return relativeY < WarmupBudget.searchFieldTopRatio
  ```
- [ ] **Step 9: Substitute warmup input-score tiers (L375, L377, L380, L385) in `warmupInputScore`.** Anchored on `private func warmupInputScore`.
  ```swift
      let role = element.role ?? ""
      let roleScore: Double
      if role == kAXTextAreaRole {
          roleScore = WarmupScore.textAreaScore
      } else if role == kAXTextFieldRole {
          roleScore = WarmupScore.textFieldScore
      } else {
          let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
          roleScore = editable ? WarmupScore.editableScore : 0.0
      }

      let yScore = Double(element.position?.y ?? 0)
      let sizeScore = Double(element.size?.height ?? 0)
      let focusScore = element.isFocused ? WarmupScore.focusBonus : 0.0
      return roleScore + yScore + sizeScore + focusScore
  ```
- [ ] **Step 10: Per-constant grep check (values match originals).** Run:
  ```
  grep -nE 'usableFastTimeout: TimeInterval = 1.2|usableRecoveryTimeout: TimeInterval = 3.0|chatOpenTimeout: TimeInterval = 0.8|chatOpenPoll: TimeInterval = 0.05|downEnterSleep: TimeInterval = 0.03|buttonLimit = 18|buttonNodes = 220|buttonPressBatch = 3|buttonRetrySleep: TimeInterval = 0.05|fieldLimit = 8|fieldNodes = 140|inputCandidateLimit = 70|appInputCandidateLimit = 90|nodeBudgetFloor = 200|nodeBudgetMultiplier = 4|searchFieldTopRatio: CGFloat = 0.45' Sources/kmsg/Commands/CacheCommand.swift
  grep -nE 'textAreaScore: Double = 12_000.0|textFieldScore: Double = 9_000.0|editableScore: Double = 6_000.0|focusBonus: Double = 2_000.0' Sources/kmsg/Commands/CacheCommand.swift
  ```
  Expected counts: 16, 4 (each constant present once with the original value). Then confirm no orphan numeric `Thread.sleep` remains:
  ```
  grep -nE 'Thread.sleep\(forTimeInterval: [0-9]' Sources/kmsg/Commands/CacheCommand.swift
  ```
  Expected: empty.
- [ ] **Step 11: DIFF-DISCIPLINE.** Run:
  ```
  git diff Sources/kmsg/Commands/CacheCommand.swift
  ```
  Confirm ONLY: two added file-private enums + literal→named substitutions. Verify both `ensureMainWindow(...) ?? ensureMainWindow(...)` calls keep the `??` chain intact; the L149 Down→Enter `Thread.sleep` stays standalone; both warmup `waitUntil(... evaluateAfterTimeout: false ...)` keep that flag and are NOT flattened; `Int(PATH_MAX)` and `resolvedURL`/`physicalCurrentDirectoryPath` are untouched. No value changed.
- [ ] **Step 12: BUILD GATE.** Run:
  ```
  swift build
  ```
  Expected: `Build complete!` (exit 0); no new warning vs baseline.
- [ ] **Step 13: GOLDEN.** Run (cache export does not need a live KakaoTalk session; status confirms the binary still links cleanly):
  ```
  .build/debug/kmsg cache export /tmp/check_cache.json > /tmp/check.out 2> /tmp/check.err; diff /tmp/kmsg-golden-baseline/cache_export.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/cache_export.err /tmp/check.err
  .build/debug/kmsg status --verbose > /tmp/check2.out 2> /tmp/check2.err; diff /tmp/kmsg-golden-baseline/status.out /tmp/check2.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check2.err
  ```
  Expected: empty diffs (byte-identical). (If the golden `cache_export` was captured to a fixed destination path, reuse that exact path so the printed `exported to <path>` line matches byte-for-byte.)
- [ ] **Step 14: COMMIT.** Run:
  ```
  git add Sources/kmsg/Commands/CacheCommand.swift
  git commit -m "refactor(cache): name warmup budgets and scoring tiers"
  ```

---

## Phase 4A — Decompose TranscriptReader & ChatWindowResolver (pure code-move)

**Goal:** Relocate cohesive method groups out of `KakaoTalkTranscriptReader` and `ChatWindowResolver` into `extension <Type>` files in the same module — zero logic edits inside moved bodies — to shrink the two monoliths without changing behavior.

**Aggregate risk:** low

> Convention for every relocation: the moved methods keep their EXACT signatures and bodies (including `private`). Each new file begins with `import ApplicationServices.HIServices` and `import Foundation` (matching the source file's imports) and wraps the moved members in `extension <Type> { ... }`. After deleting the methods from the origin file, `git diff` must show ONLY (a) deletions in the origin file and (b) the new file = imports + wrapper + verbatim method bodies. No signature changes, no token reordering, no value changes. The Phase 1/2 helpers (`isSameElement`, `isTextInputRole`, `isEditable`, `throwIfAXError`, `kAXSecureTextFieldRole`) already exist and are NOT introduced or touched here.

---

### Task 4A.1: Extract TranscriptReader time parsing into `+TimeParsing`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+TimeParsing.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
- Verify: build + read goldens

Methods to MOVE from `KakaoTalkTranscriptReader` (verbatim, including `private`):
- `extractTimeToken(from:)` — lines 551–574 — `private func extractTimeToken(from token: String) -> String?`
- `isForwardTimeProgress(anchorTimeRaw:candidateTimeRaw:)` — lines 711–720 — `private func isForwardTimeProgress(anchorTimeRaw: String?, candidateTimeRaw: String?) -> Bool`
- `minuteOfDay(from:)` — lines 722–766 — `private func minuteOfDay(from timeRaw: String?) -> Int?`
- `logicalTimestamp(for:dateAnchor:referenceDate:)` — lines 768–787 — `private func logicalTimestamp(for timeRaw: String?, dateAnchor: Date?, referenceDate: Date) -> Date?`
- `formattedTime(from:)` — lines 789–795 — `private func formattedTime(from date: Date) -> String`
- `parseSystemDate(from:relativeTo:)` — lines 797–851 — `private func parseSystemDate(from text: String, relativeTo referenceDate: Date) -> Date?`

Steps:

- [ ] **Step 1: Create the new extension file** with the six methods moved verbatim.

```swift
import ApplicationServices.HIServices
import Foundation

extension KakaoTalkTranscriptReader {
    private func extractTimeToken(from token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let meridiemRange = trimmed.range(
            of: #"(오전|오후)\s*([1-9]|1[0-2]):[0-5][0-9]"#,
            options: .regularExpression
        ) {
            return String(trimmed[meridiemRange])
        }

        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        for part in parts {
            let normalized = String(part).trimmingCharacters(in: .punctuationCharacters)
            if normalized.range(
                of: #"^([01]?[0-9]|2[0-3]):[0-5][0-9]$"#,
                options: .regularExpression
            ) != nil {
                return normalized
            }
        }

        return nil
    }

    private func isForwardTimeProgress(anchorTimeRaw: String?, candidateTimeRaw: String?) -> Bool {
        guard
            let anchorMinutes = minuteOfDay(from: anchorTimeRaw),
            let candidateMinutes = minuteOfDay(from: candidateTimeRaw)
        else {
            return true
        }

        return candidateMinutes >= anchorMinutes
    }

    private func minuteOfDay(from timeRaw: String?) -> Int? {
        guard let timeRaw else { return nil }
        let trimmed = timeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let meridiemRange = trimmed.range(
            of: #"(오전|오후)\s*([1-9]|1[0-2]):([0-5][0-9])"#,
            options: .regularExpression
        ) {
            let token = String(trimmed[meridiemRange])
                .replacingOccurrences(of: "오전", with: "")
                .replacingOccurrences(of: "오후", with: "")
                .trimmingCharacters(in: .whitespaces)
            let parts = token.split(separator: ":")
            guard parts.count == 2,
                  let hourPart = Int(parts[0]),
                  let minutePart = Int(parts[1])
            else {
                return nil
            }

            var hour = hourPart % 12
            if trimmed.contains("오후") {
                hour += 12
            }
            return hour * 60 + minutePart
        }

        if let range = trimmed.range(
            of: #"([01]?[0-9]|2[0-3]):([0-5][0-9])"#,
            options: .regularExpression
        ) {
            let token = String(trimmed[range])
            let parts = token.split(separator: ":")
            guard parts.count == 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1])
            else {
                return nil
            }
            return hour * 60 + minute
        }

        return nil
    }

    private func logicalTimestamp(for timeRaw: String?, dateAnchor: Date?, referenceDate: Date) -> Date? {
        guard let messageMinuteOfDay = minuteOfDay(from: timeRaw) else {
            return nil
        }

        let calendar = Calendar.current
        if let dateAnchor {
            let startOfDay = calendar.startOfDay(for: dateAnchor)
            return calendar.date(byAdding: .minute, value: messageMinuteOfDay, to: startOfDay)
        }

        guard let referenceMinuteOfDay = minuteOfDay(from: formattedTime(from: referenceDate)),
              messageMinuteOfDay <= referenceMinuteOfDay
        else {
            return nil
        }

        let startOfDay = calendar.startOfDay(for: referenceDate)
        return calendar.date(byAdding: .minute, value: messageMinuteOfDay, to: startOfDay)
    }

    private func formattedTime(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else {
            return ""
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    private func parseSystemDate(from text: String, relativeTo referenceDate: Date) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let calendar = Calendar.current
        let normalized = trimmed
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")

        if let match = normalized.range(
            of: #"^(\d{4})-(\d{1,2})-(\d{1,2})(?:\s+\S+)?$"#,
            options: .regularExpression
        ) {
            let token = String(normalized[match])
            let parts = token.split(whereSeparator: { $0 == "-" || $0 == " " })
            guard parts.count >= 3,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2])
            else {
                return nil
            }
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }

        if let match = trimmed.range(
            of: #"^(\d{1,2})월\s*(\d{1,2})일(?:\s+\S+)?$"#,
            options: .regularExpression
        ) {
            let token = String(trimmed[match])
            let numbers = token
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            guard numbers.count >= 2 else {
                return nil
            }

            let referenceYear = calendar.component(.year, from: referenceDate)
            let month = numbers[0]
            let day = numbers[1]
            guard var candidate = calendar.date(from: DateComponents(year: referenceYear, month: month, day: day)) else {
                return nil
            }

            if candidate.timeIntervalSince(referenceDate) > 86_400 * 2,
               let adjusted = calendar.date(byAdding: .year, value: -1, to: candidate)
            {
                candidate = adjusted
            }

            return candidate
        }

        return nil
    }
}
```

- [ ] **Step 2: Delete the six moved methods from `TranscriptReader.swift`.** Remove the exact spans for `extractTimeToken(from:)` (551–574), `isForwardTimeProgress` (711–720), `minuteOfDay(from:)` (722–766), `logicalTimestamp` (768–787), `formattedTime(from:)` (789–795), and `parseSystemDate(from:relativeTo:)` (797–851). Anchor on the enclosing signature line of each (e.g. `private func parseSystemDate(from text: String, relativeTo referenceDate: Date) -> Date?`) and remove the full body through its closing brace. Leave all other methods in place; callers (`parseRowMetadata`, `extractMessages`, `isLikelySystemRow`, `resolveAuthorInSegment`) are unaffected because the extension is in the same type/module.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff` and confirm: in `TranscriptReader.swift` only deletions of the six methods; in the new file only imports + `extension KakaoTalkTranscriptReader { }` + the six verbatim bodies. No token reordering, no value changes.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs baseline `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 5: GOLDEN.** Run:
```
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.err
.build/debug/kmsg inspect --depth 5 --debug > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/inspect5_debug.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/inspect5_debug.err /tmp/check.err
```
Expected: empty diff (byte-identical) for all three.

- [ ] **Step 6: COMMIT.** Run:
```
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+TimeParsing.swift
git commit -m "refactor(transcript): extract time parsing into +TimeParsing extension"
```

---

### Task 4A.2: Extract TranscriptReader metadata-token classifiers into `+MetadataTokenClassifier`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+MetadataTokenClassifier.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
- Verify: build + read goldens

Methods to MOVE from `KakaoTalkTranscriptReader` (current line numbers are PRE-Task-4A.1; after Task 4A.1's deletions these methods shift up — anchor on signatures, not numbers):
- `metadataTokens(from:)` — lines 542–549 — `private func metadataTokens(from text: String) -> [String]`
- `isLikelyCountToken(_:)` — lines 576–580 — `private func isLikelyCountToken(_ token: String) -> Bool`
- `isLikelySystemMetadataToken(_:)` — lines 582–597 — `private func isLikelySystemMetadataToken(_ token: String) -> Bool`
- `isLikelyAttachmentMetadataToken(_:)` — lines 599–621 — `private func isLikelyAttachmentMetadataToken(_ token: String) -> Bool`
- `isLikelyAttachmentButtonTitle(_:)` — lines 623–633 — `private func isLikelyAttachmentButtonTitle(_ title: String) -> Bool`

Steps:

- [ ] **Step 1: Create the new extension file** with the five classifiers moved verbatim.

```swift
import ApplicationServices.HIServices
import Foundation

extension KakaoTalkTranscriptReader {
    private func metadataTokens(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func isLikelyCountToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private func isLikelySystemMetadataToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^\d{4}[./-]\d{1,2}[./-]\d{1,2}"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^\d{1,2}월\s*\d{1,2}일"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private func isLikelyAttachmentMetadataToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("expiry") || lowered.hasPrefix("size:") {
            return true
        }
        if lowered.contains("만료") || lowered.contains("용량") {
            return true
        }
        if trimmed == "·" {
            return true
        }
        if lowered.range(
            of: #"\.(pdf|png|jpe?g|gif|webp|zip|hwp|docx?|pptx?|xlsx?)$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return false
    }

    private func isLikelyAttachmentButtonTitle(_ title: String) -> Bool {
        let lowered = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        if lowered == "save" || lowered == "save as" {
            return true
        }
        if lowered == "저장" || lowered == "다른 이름으로 저장" {
            return true
        }
        return false
    }
}
```

- [ ] **Step 2: Delete the five moved methods from `TranscriptReader.swift`.** Anchor on each signature line — `private func metadataTokens(from text: String) -> [String]`, `private func isLikelyCountToken(_ token: String) -> Bool`, `private func isLikelySystemMetadataToken(_ token: String) -> Bool`, `private func isLikelyAttachmentMetadataToken(_ token: String) -> Bool`, `private func isLikelyAttachmentButtonTitle(_ title: String) -> Bool` — and remove each full body through its closing brace. Callers `parseRowMetadata`, `analyzeRow`, `extractRowMetadata`, `isLikelySystemRow` stay in the origin file and continue to compile.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff` and confirm only deletions in origin + verbatim wrapper in the new file. No value changes.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!`, no new warnings vs baseline.

- [ ] **Step 5: GOLDEN.** Run:
```
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.err
```
Expected: empty diff for both.

- [ ] **Step 6: COMMIT.** Run:
```
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+MetadataTokenClassifier.swift
git commit -m "refactor(transcript): extract metadata token classifiers into +MetadataTokenClassifier extension"
```

---

### Task 4A.3: Extract TranscriptReader body/link text normalization into `+BodyContentNormalizer`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+BodyContentNormalizer.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
- Verify: build + read goldens

Methods to MOVE from `KakaoTalkTranscriptReader` (pre-Phase line numbers; anchor on signatures):
- `bestLinkTitle(from:)` — lines 868–876 — `private func bestLinkTitle(from element: UIElement) -> String?`
- `normalizeBodyText(_:)` — lines 878–892 — `private func normalizeBodyText(_ text: String?) -> String`
- `shouldPromoteLinkTitle(for:)` — lines 939–943 — `private func shouldPromoteLinkTitle(for text: String) -> Bool`
- `isURLOnlyText(_:)` — lines 945–948 — `private func isURLOnlyText(_ text: String) -> Bool`
- `scoreBodyCandidate(_:)` — lines 950–963 — `private func scoreBodyCandidate(_ text: String) -> Int`

Steps:

- [ ] **Step 1: Create the new extension file** with the five normalization/scoring helpers moved verbatim.

```swift
import ApplicationServices.HIServices
import Foundation

extension KakaoTalkTranscriptReader {
    private func bestLinkTitle(from element: UIElement) -> String? {
        let links = element.findAll(where: { $0.role == kAXLinkRole }, limit: 4, maxNodes: 120)
        let titles = links.compactMap { link in
            normalizeBodyText(link.title ?? link.stringValue)
        }
        .filter { !$0.isEmpty }

        return titles.max { lhs, rhs in lhs.count < rhs.count }
    }

    private func normalizeBodyText(_ text: String?) -> String {
        guard let text else { return "" }
        let canonical = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = canonical
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let joined = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return joined
    }

    private func shouldPromoteLinkTitle(for text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("http://") || lower.contains("https://") else { return false }
        return text.contains("...")
    }

    private func isURLOnlyText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    private func scoreBodyCandidate(_ text: String) -> Int {
        var score = min(text.count * 10, 500)
        if text.contains("\n") {
            score += 60
        }
        if text.contains(" ") {
            score += 40
        }
        let lower = text.lowercased()
        if lower.contains("http://") || lower.contains("https://") {
            score += 180
        }
        return score
    }
}
```

- [ ] **Step 2: Delete the five moved methods from `TranscriptReader.swift`.** Anchor on signatures `private func bestLinkTitle(from element: UIElement) -> String?`, `private func normalizeBodyText(_ text: String?) -> String`, `private func shouldPromoteLinkTitle(for text: String) -> Bool`, `private func isURLOnlyText(_ text: String) -> Bool`, `private func scoreBodyCandidate(_ text: String) -> Int`, removing each full body. Callers `analyzeRow`, `extractFallbackMessages`, `extractRowMetadata` remain in origin.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff` and confirm pure relocation only.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: `Build complete!`, no new warnings.

- [ ] **Step 5: GOLDEN.** Run:
```
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.err
```
Expected: empty diff for both.

- [ ] **Step 6: COMMIT.** Run:
```
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+BodyContentNormalizer.swift
git commit -m "refactor(transcript): extract body content normalization into +BodyContentNormalizer extension"
```

---

### Task 4A.4: Extract TranscriptReader dedup/ordering helpers into `+DuplicationHelper`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+DuplicationHelper.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
- Verify: build + read goldens

Methods to MOVE from `KakaoTalkTranscriptReader` (pre-Phase line numbers; anchor on signatures):
- `deduplicatePreservingOrder(_:)` — lines 894–907 — `private func deduplicatePreservingOrder(_ values: [String]) -> [String]`
- `deduplicateBodyCandidates(_:)` — lines 909–922 — `private func deduplicateBodyCandidates(_ candidates: [MessageBodyCandidate]) -> [MessageBodyCandidate]`
- `deduplicateMessagesPreservingOrder(_:)` — lines 924–937 — `private func deduplicateMessagesPreservingOrder(_ messages: [TranscriptMessage]) -> [TranscriptMessage]`
- `deduplicateElements(_:)` — lines 965–983 — `private func deduplicateElements(_ elements: [UIElement]) -> [UIElement]`
- `sortElementsByReadingOrder(_:)` — lines 985–996 — `private func sortElementsByReadingOrder(_ elements: [UIElement]) -> [UIElement]`

> Note: `deduplicateMessagesPreservingOrder` references the free function `messageFingerprint(_:)` (file-scope, line 999) which stays where it is — same module, still visible. `deduplicateBodyCandidates` references the file-private `MessageBodyCandidate` struct (line 1008) which is `private` at FILE scope, so it remains visible to the extension only if the extension is in the SAME file. Since `MessageBodyCandidate` is declared `private struct` (file-private), the extension MUST NOT reference it from another file. Therefore `deduplicateBodyCandidates` CANNOT move to a separate file without touching `MessageBodyCandidate`'s access level — which would violate the zero-logic-edit rule. EXCLUDE `deduplicateBodyCandidates(_:)` from this move; it stays in `TranscriptReader.swift`. Move only the other four.

Revised methods to MOVE:
- `deduplicatePreservingOrder(_:)` — `private func deduplicatePreservingOrder(_ values: [String]) -> [String]`
- `deduplicateMessagesPreservingOrder(_:)` — `private func deduplicateMessagesPreservingOrder(_ messages: [TranscriptMessage]) -> [TranscriptMessage]` (references file-scope free func `messageFingerprint`, which is non-private → visible across files in module ✓; `TranscriptMessage` is internal ✓)
- `deduplicateElements(_:)` — `private func deduplicateElements(_ elements: [UIElement]) -> [UIElement]`
- `sortElementsByReadingOrder(_:)` — `private func sortElementsByReadingOrder(_ elements: [UIElement]) -> [UIElement]`

- [ ] **Step 1: Create the new extension file** with the four dedup/ordering helpers moved verbatim.

```swift
import ApplicationServices.HIServices
import Foundation

extension KakaoTalkTranscriptReader {
    private func deduplicatePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(values.count)

        for value in values {
            guard !value.isEmpty else { continue }
            if seen.contains(value) { continue }
            seen.insert(value)
            unique.append(value)
        }

        return unique
    }

    private func deduplicateMessagesPreservingOrder(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
        var seen = Set<String>()
        var unique: [TranscriptMessage] = []
        unique.reserveCapacity(messages.count)

        for message in messages {
            let key = messageFingerprint(message)
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(message)
        }

        return unique
    }

    private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(elements.count)

        var buckets: [CFHashCode: [UIElement]] = [:]
        for element in elements {
            let hash = CFHash(element.axElement)
            let alreadySeen = buckets[hash]?.contains(where: { existing in
                CFEqual(existing.axElement, element.axElement)
            }) ?? false
            if alreadySeen {
                continue
            }
            buckets[hash, default: []].append(element)
            unique.append(element)
        }

        return unique
    }

    private func sortElementsByReadingOrder(_ elements: [UIElement]) -> [UIElement] {
        elements.sorted { lhs, rhs in
            let lhsY = lhs.frame?.minY ?? .greatestFiniteMagnitude
            let rhsY = rhs.frame?.minY ?? .greatestFiniteMagnitude
            if lhsY == rhsY {
                let lhsX = lhs.frame?.minX ?? .greatestFiniteMagnitude
                let rhsX = rhs.frame?.minX ?? .greatestFiniteMagnitude
                return lhsX < rhsX
            }
            return lhsY < rhsY
        }
    }
}
```

- [ ] **Step 2: Delete the four moved methods from `TranscriptReader.swift`.** Anchor on signatures `private func deduplicatePreservingOrder(_ values: [String]) -> [String]`, `private func deduplicateMessagesPreservingOrder(_ messages: [TranscriptMessage]) -> [TranscriptMessage]`, `private func deduplicateElements(_ elements: [UIElement]) -> [UIElement]`, `private func sortElementsByReadingOrder(_ elements: [UIElement]) -> [UIElement]`, removing each full body. LEAVE `deduplicateBodyCandidates(_:)` (lines 909–922) IN PLACE — it references file-private `MessageBodyCandidate`. Callers `parseRowMetadata`, `analyzeRow`, `extractMessages`, `extractFallbackMessages`, `collectTranscriptRows` remain in origin.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff` and confirm: origin shows only deletions of the four methods (with `deduplicateBodyCandidates` untouched and still present); new file = imports + wrapper + four verbatim bodies. No value changes.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: `Build complete!`, no new warnings.

- [ ] **Step 5: GOLDEN.** Run:
```
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.err
```
Expected: empty diff for both.

- [ ] **Step 6: COMMIT.** Run:
```
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+DuplicationHelper.swift
git commit -m "refactor(transcript): extract dedup and reading-order helpers into +DuplicationHelper extension"
```

---

### Task 4A.5: Extract the `FrameCache` type into `TranscriptReader+FrameCache.swift`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+FrameCache.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
- Verify: build + read goldens

Symbol to MOVE: the file-private `FrameCache` final class — lines 1032–1051 — `private final class FrameCache { ... }`.

> This is a TYPE move, not an `extension` (the `+FrameCache` name follows the file-naming convention). Because `FrameCache` is currently declared `private` at file scope, relocating it to a separate file requires its declaration to be visible to `KakaoTalkTranscriptReader`. Changing `private` → `internal` (drop the keyword) IS an access-level edit, which the zero-logic-edit rule forbids. To keep the move pure, declare it `fileprivate`? No — `fileprivate` is also file-bound. The only behavior-preserving option is to drop `private` so the class becomes module-internal. This is the single permitted minimal change for this task (an access-level widening on a type declaration, not a logic edit), and it must be called out explicitly in the diff review. If the orchestrator forbids ANY access-level change, SKIP this task and leave `FrameCache` in `TranscriptReader.swift`.

- [ ] **Step 1: Create the new file** containing the relocated `FrameCache` class, dropping the `private` keyword so it remains visible to its only user `KakaoTalkTranscriptReader` (same module).

```swift
import ApplicationServices.HIServices
import Foundation

final class FrameCache {
    private var entries: [(element: AXUIElement, frame: CGRect?)] = []
    private var buckets: [CFHashCode: [Int]] = [:]

    func frame(of element: UIElement) -> CGRect? {
        let hash = CFHash(element.axElement)
        if let indices = buckets[hash] {
            for idx in indices {
                if CFEqual(entries[idx].element, element.axElement) {
                    return entries[idx].frame
                }
            }
        }
        let frame = element.frame
        let idx = entries.count
        entries.append((element: element.axElement, frame: frame))
        buckets[hash, default: []].append(idx)
        return frame
    }
}
```

- [ ] **Step 2: Delete the `FrameCache` class from `TranscriptReader.swift`** (lines 1032–1051). Anchor on `private final class FrameCache {` and remove through its closing brace. All other file-scope types (`RowMetadata`, `MessageBodyCandidate`, `RowAnalysis`, `MessageSide`) and the free func `messageFingerprint` stay.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff` and confirm exactly: origin removes the `FrameCache` block; new file is identical to the removed block except the leading `private ` keyword is dropped on the class declaration. The bodies of `init`-less class and `frame(of:)` are byte-identical. No other token changes.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: `Build complete!`, no new warnings vs baseline.

- [ ] **Step 5: GOLDEN.** Run:
```
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.err
.build/debug/kmsg inspect --depth 5 --debug > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/inspect5_debug.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/inspect5_debug.err /tmp/check.err
```
Expected: empty diff for all three.

- [ ] **Step 6: COMMIT.** Run:
```
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+FrameCache.swift
git commit -m "refactor(transcript): relocate FrameCache into TranscriptReader+FrameCache"
```

---

### Task 4A.6: Extract TranscriptReader row analysis into `+RowAnalyzer` (HIGHEST COUPLING — LAST)

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+RowAnalyzer.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
- Verify: build + read goldens + inspect

Methods to MOVE from `KakaoTalkTranscriptReader` (pre-Phase line numbers; anchor on signatures):
- `directRowChildren(from:)` — lines 308–310 — `private func directRowChildren(from element: UIElement) -> [UIElement]`
- `extractRowMetadata(from:)` — lines 499–514 — `private func extractRowMetadata(from row: UIElement) -> RowMetadata` (references file-private `RowMetadata` — see note below)
- `parseRowMetadata(tokens:)` — lines 516–540 — `private func parseRowMetadata(tokens: [String]) -> RowMetadata` (references file-private `RowMetadata`)
- `isLikelySystemRow(metadataTokens:buttonTitles:bodyCandidate:referenceDate:)` — lines 635–653 — `private func isLikelySystemRow(...) -> Bool` (references file-private `MessageBodyCandidate`)
- `inferMessageSide(bodyFrame:imageFrames:rowFrame:transcriptRoot:)` — lines 655–685 — `private func inferMessageSide(...) -> MessageSide` (references file-private `MessageSide`)
- `resolveAuthorInSegment(analysis:leftAnchorAuthor:leftAnchorTimeRaw:)` — lines 687–709 — `private func resolveAuthorInSegment(...) -> (author: String?, source: String)` (references file-private `RowAnalysis`)
- `firstAncestor(of:role:maxHops:)` — lines 853–866 — `private func firstAncestor(of element: UIElement, role: String, maxHops: Int) -> UIElement?`
- `analyzeRow(_:transcriptRoot:referenceDate:frameCache:)` — lines 312–441 — `private func analyzeRow(...) -> RowAnalysis` (references `RowAnalysis`, `MessageBodyCandidate`, `MessageSide`, `FrameCache`)

> CRITICAL access-level fact: `analyzeRow`, `extractRowMetadata`, `parseRowMetadata`, `isLikelySystemRow`, `inferMessageSide`, and `resolveAuthorInSegment` all reference the FILE-PRIVATE types `RowMetadata` (line 1003), `MessageBodyCandidate` (line 1008), `RowAnalysis` (line 1013), and/or `MessageSide` (line 1026) — all declared `private struct`/`private enum` at file scope in `TranscriptReader.swift`. Moving these methods to a separate file would make those file-private types invisible, breaking compilation. Relocating the type declarations too (and widening them to internal) would be a multi-symbol move with access-level edits — out of scope for a pure code-move. THEREFORE: `extractRowMetadata`, `parseRowMetadata`, `isLikelySystemRow`, `inferMessageSide`, `resolveAuthorInSegment`, and `analyzeRow` MUST stay in `TranscriptReader.swift`.
>
> Only the two methods that DO NOT touch any file-private type can move cleanly: `directRowChildren(from:)` and `firstAncestor(of:role:maxHops:)`. Both use only `UIElement` (internal) and standard types.

Revised methods to MOVE into `+RowAnalyzer`:
- `directRowChildren(from:)` — `private func directRowChildren(from element: UIElement) -> [UIElement]`
- `firstAncestor(of:role:maxHops:)` — `private func firstAncestor(of element: UIElement, role: String, maxHops: Int) -> UIElement?`

- [ ] **Step 1: Create the new extension file** with the two file-private-type-free row-traversal helpers moved verbatim.

```swift
import ApplicationServices.HIServices
import Foundation

extension KakaoTalkTranscriptReader {
    private func directRowChildren(from element: UIElement) -> [UIElement] {
        element.children.filter { $0.role == kAXRowRole }
    }

    private func firstAncestor(of element: UIElement, role: String, maxHops: Int) -> UIElement? {
        var cursor: UIElement? = element
        var hops = 0

        while let current = cursor, hops <= maxHops {
            if current.role == role {
                return current
            }
            cursor = current.parent
            hops += 1
        }

        return nil
    }
}
```

- [ ] **Step 2: Delete the two moved methods from `TranscriptReader.swift`.** Anchor on `private func directRowChildren(from element: UIElement) -> [UIElement]` (block ~308–310) and `private func firstAncestor(of element: UIElement, role: String, maxHops: Int) -> UIElement?` (block ~853–866); remove each full body. LEAVE `analyzeRow`, `extractRowMetadata`, `parseRowMetadata`, `isLikelySystemRow`, `inferMessageSide`, `resolveAuthorInSegment` IN PLACE (they depend on file-private types). Their callers (`collectTranscriptRows`, `extractFallbackMessages`, `extractMessages`) remain in origin and now call the relocated `directRowChildren`/`firstAncestor` across files in the same type.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff` and confirm: origin removes only `directRowChildren` and `firstAncestor`; the six file-private-type-coupled methods are untouched and still present; new file = imports + wrapper + two verbatim bodies. No value changes.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: `Build complete!`, no new warnings vs baseline.

- [ ] **Step 5: GOLDEN.** Run:
```
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err
.build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.err
.build/debug/kmsg inspect --depth 5 --debug > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/inspect5_debug.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/inspect5_debug.err /tmp/check.err
```
Expected: empty diff for all three.

- [ ] **Step 6: COMMIT.** Run:
```
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader+RowAnalyzer.swift
git commit -m "refactor(transcript): extract row traversal helpers into +RowAnalyzer extension"
```

---

### Task 4A.7: Extract ChatWindowResolver window resolution strategy into `+WindowResolutionStrategy`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver+WindowResolutionStrategy.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
- Verify: build + chats/send_dryrun goldens

Methods to MOVE from `ChatWindowResolver` (anchor on signatures):
- `requireUsableWindow()` — lines 109–139 — `private func requireUsableWindow() throws -> UIElement` (references file-private enum `ChatWindowFailureCode`)
- `attemptQuickOpenDefense(forceOpenEvenIfWindowPresent:)` — lines 141–171 — `private func attemptQuickOpenDefense(forceOpenEvenIfWindowPresent: Bool) -> UIElement?`
- `selectSearchWindow(fallback:)` — lines 173–184 — `private func selectSearchWindow(fallback: UIElement) -> UIElement`
- `waitForOpenedChatWindow(query:fallbackWindow:)` — lines 433–440 — `private func waitForOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement?`
- `resolveOpenedChatWindowFast(query:)` — lines 442–455 — `private func resolveOpenedChatWindowFast(query: String) -> UIElement?`
- `resolveOpenedChatWindow(query:fallbackWindow:)` — lines 457–479 — `private func resolveOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement?`

> Access-level fact: `requireUsableWindow` references `ChatWindowFailureCode` (line 18), declared `private enum` at FILE scope. Moving `requireUsableWindow` to a separate file would make `ChatWindowFailureCode` invisible. To preserve a pure move, EXCLUDE `requireUsableWindow()` — it stays in `ChatWindowResolver.swift`. The remaining five methods reference only internal types (`UIElement`, `KakaoTalkApp`, `AXActionRunner`) and free functions, so they move cleanly. (`openChatViaSearch` and `resolve` also reference `ChatWindowFailureCode` and stay in the main file regardless.)

Revised methods to MOVE:
- `attemptQuickOpenDefense(forceOpenEvenIfWindowPresent:)`
- `selectSearchWindow(fallback:)`
- `waitForOpenedChatWindow(query:fallbackWindow:)`
- `resolveOpenedChatWindowFast(query:)`
- `resolveOpenedChatWindow(query:fallbackWindow:)`

- [ ] **Step 1: Create the new extension file** with the five window-resolution helpers moved verbatim.

```swift
import ApplicationServices.HIServices
import Foundation

extension ChatWindowResolver {
    private func attemptQuickOpenDefense(forceOpenEvenIfWindowPresent: Bool) -> UIElement? {
        runner.log("window: quick-open defense start")

        let hasVisibleWindow = kakao.focusedWindow != nil || kakao.mainWindow != nil || !kakao.windows.isEmpty
        if forceOpenEvenIfWindowPresent || !hasVisibleWindow {
            if KakaoTalkApp.isRunning {
                if hasVisibleWindow && forceOpenEvenIfWindowPresent {
                    runner.log("window: forcing open /Applications/KakaoTalk.app (fast-mode fallback)")
                } else {
                    runner.log("window: no visible windows; forcing open /Applications/KakaoTalk.app")
                }
                _ = KakaoTalkApp.forceOpen(timeout: 0.8)
            } else {
                runner.log("window: KakaoTalk not running; launching")
                _ = KakaoTalkApp.launch(timeout: 0.8)
            }
        } else {
            runner.log("window: quick-open defense skipped (windows already present)")
        }

        kakao.activate()
        if let usableWindow = kakao.ensureMainWindow(timeout: 0.8, mode: .fast, trace: { message in
            runner.log(message)
        }) {
            runner.log("window: quick-open defense succeeded")
            return usableWindow
        }

        runner.log("window: quick-open defense failed")
        return nil
    }

    private func selectSearchWindow(fallback: UIElement) -> UIElement {
        if let chatListWindow = kakao.chatListWindow {
            runner.log("search root selected: chatListWindow")
            return chatListWindow
        }
        if let mainWindow = kakao.mainWindow {
            runner.log("search root selected: mainWindow")
            return mainWindow
        }
        runner.log("search root selected: fallback usable window")
        return fallback
    }

    private func waitForOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement? {
        var resolved: UIElement?
        _ = runner.waitUntil(label: "chat context ready", timeout: 0.8, pollInterval: 0.05, evaluateAfterTimeout: false) {
            resolved = resolveOpenedChatWindowFast(query: query)
            return resolved != nil
        }
        return resolved ?? resolveOpenedChatWindow(query: query, fallbackWindow: fallbackWindow)
    }

    private func resolveOpenedChatWindowFast(query: String) -> UIElement? {
        if let matchedWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            return matchedWindow
        }

        if let focusedWindow = kakao.focusedWindow,
           let title = focusedWindow.title,
           scoreQueryMatch(query: query, candidateText: title) > 0
        {
            return focusedWindow
        }

        return nil
    }

    private func resolveOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement? {
        if let fastWindow = resolveOpenedChatWindowFast(query: query) {
            return fastWindow
        }

        if let matchedWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            return matchedWindow
        }

        if let focusedWindow = kakao.focusedWindow, windowContainsLikelyChatInput(focusedWindow) {
            return focusedWindow
        }

        if windowContainsLikelyChatInput(fallbackWindow) {
            return fallbackWindow
        }

        if let mainWindow = kakao.mainWindow, windowContainsLikelyChatInput(mainWindow) {
            return mainWindow
        }

        return nil
    }
}
```

- [ ] **Step 2: Delete the five moved methods from `ChatWindowResolver.swift`.** Anchor on signatures `private func attemptQuickOpenDefense(forceOpenEvenIfWindowPresent: Bool) -> UIElement?`, `private func selectSearchWindow(fallback: UIElement) -> UIElement`, `private func waitForOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement?`, `private func resolveOpenedChatWindowFast(query: String) -> UIElement?`, `private func resolveOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement?`. LEAVE `requireUsableWindow()` IN PLACE (it references file-private `ChatWindowFailureCode`). Callers `resolve`, `openChatViaSearch` (which references `resolveOpenedChatWindowFast` in its closure) remain in origin.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff` and confirm pure relocation only; `requireUsableWindow` untouched.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: `Build complete!`, no new warnings vs baseline.

- [ ] **Step 5: GOLDEN.** Run:
```
.build/debug/kmsg chats --verbose --limit 20 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.err
.build/debug/kmsg send "테헤란로 죽돌이" "ping" --dry-run > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check.err
```
Expected: empty diff for both.

- [ ] **Step 6: COMMIT.** Run:
```
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver+WindowResolutionStrategy.swift
git commit -m "refactor(resolver): extract window resolution strategy into +WindowResolutionStrategy extension"
```

---

### Task 4A.8: Extract ChatWindowResolver search scan profiling into `+SearchProfiler`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver+SearchProfiler.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
- Verify: build + chats/send_dryrun goldens

Methods to MOVE from `ChatWindowResolver` (anchor on signatures):
- `waitForMatchingSearchResults(query:rootWindow:)` — lines 324–375 — `private func waitForMatchingSearchResults(query: String, rootWindow: UIElement) -> [SearchCandidate]` (references file-private `SearchScanProfile`, `SearchCandidate`)
- `findMatchingSearchResults(query:rootWindow:profile:)` — lines 377–431 — `private func findMatchingSearchResults(query: String, rootWindow: UIElement, profile: SearchScanProfile) -> [SearchCandidate]` (references file-private `SearchScanProfile`, `SearchCandidate`)

> Access-level fact: both methods reference the file-private structs `SearchScanProfile` (line 25) and `SearchCandidate` (line 39). Moving them to a separate file would make those types invisible and break the build. Their only construction/consumption is inside these two methods plus `pickBestSearchResult`/`scoreSearchResult`/`deduplicateSearchCandidates` (Task 4A.9). To keep moves pure (no access-level edits), this task is INFEASIBLE as a clean code-move without widening `SearchScanProfile`/`SearchCandidate` to internal.
>
> DECISION: SKIP this task. `waitForMatchingSearchResults` and `findMatchingSearchResults` STAY in `ChatWindowResolver.swift`. No `+SearchProfiler.swift` file is created. Rationale: the file-private `SearchScanProfile`/`SearchCandidate` coupling cannot be relocated without an access-level edit, which violates the zero-logic-edit / pure-relocation constraint. Recorded here so the orchestrator does not expect the file.

- [ ] **Step 1: No-op.** Confirm no `ChatWindowResolver+SearchProfiler.swift` is created and no methods are moved. No build, golden, or commit step — this task produces zero diff. (If a future phase widens `SearchScanProfile`/`SearchCandidate` to internal, revisit.)

---

### Task 4A.9: Extract ChatWindowResolver text scoring into `+TextScoringEngine`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver+TextScoringEngine.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
- Verify: build + chats/send_dryrun goldens

Methods to MOVE from `ChatWindowResolver` (anchor on signatures):
- `bestQueryMatch(query:in:textLimit:textNodeBudget:)` — lines 693–717 — `private func bestQueryMatch(query: String, in element: UIElement, textLimit: Int, textNodeBudget: Int) -> (score: Int, matchedText: String?)`
- `collectCandidateTexts(from:textLimit:textNodeBudget:)` — lines 719–756 — `private func collectCandidateTexts(from element: UIElement, textLimit: Int, textNodeBudget: Int) -> [String]`
- `scoreQueryMatch(query:candidateText:)` — lines 758–814 — `private func scoreQueryMatch(query: String, candidateText: String) -> Int`
- `normalizeSearchToken(_:)` — lines 816–835 — `private func normalizeSearchToken(_ text: String) -> String`
- `honorificVariants(of:)` — lines 837–847 — `private func honorificVariants(of text: String) -> [String]`
- `deduplicateStringsPreservingOrder(_:)` — lines 883–897 — `private func deduplicateStringsPreservingOrder(_ values: [String]) -> [String]`

> All six reference only internal/standard types (`UIElement`, `String`, `Set`, `CharacterSet`). No file-private type involved → clean move.

- [ ] **Step 1: Create the new extension file** with the six scoring/text helpers moved verbatim.

```swift
import ApplicationServices.HIServices
import Foundation

extension ChatWindowResolver {
    private func bestQueryMatch(
        query: String,
        in element: UIElement,
        textLimit: Int,
        textNodeBudget: Int
    ) -> (score: Int, matchedText: String?) {
        let candidateTexts = collectCandidateTexts(
            from: element,
            textLimit: textLimit,
            textNodeBudget: textNodeBudget
        )
        guard !candidateTexts.isEmpty else { return (0, nil) }

        var bestScore = 0
        var bestText: String?
        for candidateText in candidateTexts {
            let score = scoreQueryMatch(query: query, candidateText: candidateText)
            if score > bestScore {
                bestScore = score
                bestText = candidateText
            }
        }

        return (bestScore, bestText)
    }

    private func collectCandidateTexts(
        from element: UIElement,
        textLimit: Int,
        textNodeBudget: Int
    ) -> [String] {
        var texts: [String] = []

        func appendText(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            texts.append(trimmed)
        }

        appendText(element.title)
        appendText(element.stringValue)
        appendText(element.axDescription)

        let staticTexts = element.findAll(
            role: kAXStaticTextRole,
            limit: textLimit,
            maxNodes: textNodeBudget
        )
        for staticText in staticTexts {
            appendText(staticText.stringValue)
        }

        let textAreas = element.findAll(
            role: kAXTextAreaRole,
            limit: max(2, textLimit / 2),
            maxNodes: textNodeBudget
        )
        for textArea in textAreas {
            appendText(textArea.stringValue)
        }

        return deduplicateStringsPreservingOrder(texts)
    }

    private func scoreQueryMatch(query: String, candidateText: String) -> Int {
        let queryNormalized = normalizeSearchToken(query)
        let candidateNormalized = normalizeSearchToken(candidateText)
        guard !queryNormalized.isEmpty, !candidateNormalized.isEmpty else { return 0 }

        if queryNormalized == candidateNormalized {
            return 12_000
        }
        if candidateNormalized.hasPrefix(queryNormalized) {
            return 10_500
        }
        if candidateNormalized.contains(queryNormalized) {
            return 9_800
        }
        if queryNormalized.contains(candidateNormalized), candidateNormalized.count >= 2 {
            return 8_800
        }

        let queryVariants = honorificVariants(of: queryNormalized)
        let candidateVariants = honorificVariants(of: candidateNormalized)
        var best = 0

        for queryVariant in queryVariants where !queryVariant.isEmpty {
            for candidateVariant in candidateVariants where !candidateVariant.isEmpty {
                if queryVariant == candidateVariant {
                    best = max(best, 8_700)
                    continue
                }
                if candidateVariant.hasPrefix(queryVariant) {
                    best = max(best, 8_400)
                    continue
                }
                if candidateVariant.contains(queryVariant) {
                    best = max(best, 8_200)
                    continue
                }
                if queryVariant.contains(candidateVariant), candidateVariant.count >= 2 {
                    best = max(best, 7_900)
                }
            }
        }

        if best > 0 {
            return best
        }

        let minLength = min(queryNormalized.count, candidateNormalized.count)
        if minLength >= 2 {
            let shortest = queryNormalized.count <= candidateNormalized.count ? queryNormalized : candidateNormalized
            let longest = queryNormalized.count > candidateNormalized.count ? queryNormalized : candidateNormalized
            if longest.contains(shortest) {
                return 6_600
            }
        }

        return 0
    }

    private func normalizeSearchToken(_ text: String) -> String {
        let lowered = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(lowered.unicodeScalars.count)

        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                continue
            }
            scalars.append(scalar)
        }

        return String(scalars)
    }

    private func honorificVariants(of text: String) -> [String] {
        let suffixes = ["선생님", "님", "씨"]
        var variants = Set<String>([text])
        for suffix in suffixes where text.hasSuffix(suffix) {
            let candidate = String(text.dropLast(suffix.count))
            if !candidate.isEmpty {
                variants.insert(candidate)
            }
        }
        return Array(variants)
    }

    private func deduplicateStringsPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(values.count)

        for value in values {
            if seen.contains(value) {
                continue
            }
            seen.insert(value)
            unique.append(value)
        }

        return unique
    }
}
```

- [ ] **Step 2: Delete the six moved methods from `ChatWindowResolver.swift`.** Anchor on signatures `private func bestQueryMatch(`, `private func collectCandidateTexts(`, `private func scoreQueryMatch(query: String, candidateText: String) -> Int`, `private func normalizeSearchToken(_ text: String) -> String`, `private func honorificVariants(of text: String) -> [String]`, `private func deduplicateStringsPreservingOrder(_ values: [String]) -> [String]`, removing each full body. Callers `findMatchingSearchResults`, `resolveOpenedChatWindowFast`, `findMatchingChatWindow` remain in origin (or their own extensions) and resolve these across files in the same type.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff` and confirm pure relocation only.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: `Build complete!`, no new warnings vs baseline.

- [ ] **Step 5: GOLDEN.** Run:
```
.build/debug/kmsg chats --verbose --limit 20 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.err
.build/debug/kmsg send "테헤란로 죽돌이" "ping" --dry-run > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check.err
```
Expected: empty diff for both.

- [ ] **Step 6: COMMIT.** Run:
```
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver+TextScoringEngine.swift
git commit -m "refactor(resolver): extract text scoring into +TextScoringEngine extension"
```

---

### Task 4A.10: Extract ChatWindowResolver AX element utilities into `+AXElementUtilities`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver+AXElementUtilities.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
- Verify: build + chats/send_dryrun goldens

Methods to MOVE from `ChatWindowResolver` (anchor on signatures):
- `supportsAction(_:on:)` — lines 675–678 — `private func supportsAction(_ action: String, on element: UIElement) -> Bool`
- `findMatchingChatWindow(in:query:)` — lines 680–691 — `private func findMatchingChatWindow(in windows: [UIElement], query: String) -> UIElement?`
- `deduplicateSearchCandidates(_:)` — lines 849–866 — `private func deduplicateSearchCandidates(_ candidates: [SearchCandidate]) -> [SearchCandidate]` (references file-private `SearchCandidate` — EXCLUDE)
- `deduplicateElements(_:)` — lines 868–881 — `private func deduplicateElements(_ elements: [UIElement]) -> [UIElement]`
- `activationTarget(for:)` — lines 899–915 — `private func activationTarget(for element: UIElement) -> UIElement`
- `isSearchActivationRole(_:)` — lines 917–924 — `private func isSearchActivationRole(_ role: String?) -> Bool`
- `tryRaiseWindow(_:)` — lines 937–948 — `private func tryRaiseWindow(_ window: UIElement) -> Bool`
- `waitForWindowClosed(_:label:)` — lines 966–972 — `private func waitForWindowClosed(_ window: UIElement, label: String) -> Bool`
- `areSameAXElement(_:_:)` — lines 974–976 — `private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool`
- `isElementLikelyInsideWindow(elementFrame:windowFrame:)` — lines 978–981 — `private func isElementLikelyInsideWindow(elementFrame: CGRect, windowFrame: CGRect) -> Bool`

> Access-level fact: `deduplicateSearchCandidates(_:)` references file-private `SearchCandidate` (line 39). EXCLUDE it — leave in `ChatWindowResolver.swift`. All other listed methods use only internal/standard types and move cleanly. `findMatchingChatWindow` calls `scoreQueryMatch` (moved to `+TextScoringEngine` in Task 4A.9) — same type, resolves fine.

Revised methods to MOVE:
- `supportsAction(_:on:)`
- `findMatchingChatWindow(in:query:)`
- `deduplicateElements(_:)`
- `activationTarget(for:)`
- `isSearchActivationRole(_:)`
- `tryRaiseWindow(_:)`
- `waitForWindowClosed(_:label:)`
- `areSameAXElement(_:_:)`
- `isElementLikelyInsideWindow(elementFrame:windowFrame:)`

- [ ] **Step 1: Create the new extension file** with the nine utilities moved verbatim.

```swift
import ApplicationServices.HIServices
import Foundation

extension ChatWindowResolver {
    private func supportsAction(_ action: String, on element: UIElement) -> Bool {
        guard let actions = try? element.actionNames() else { return false }
        return actions.contains(action)
    }

    private func findMatchingChatWindow(in windows: [UIElement], query: String) -> UIElement? {
        windows.compactMap { window -> (window: UIElement, score: Int)? in
            guard let title = window.title else { return nil }
            let score = scoreQueryMatch(query: query, candidateText: title)
            guard score > 0 else { return nil }
            return (window, score)
        }
        .max(by: { lhs, rhs in
            lhs.score < rhs.score
        })?
        .window
    }

    private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(elements.count)
        for element in elements {
            if unique.contains(where: { existing in
                areSameAXElement(existing, element)
            }) {
                continue
            }
            unique.append(element)
        }

        return unique
    }

    private func activationTarget(for element: UIElement) -> UIElement {
        if isSearchActivationRole(element.role) {
            return element
        }

        var cursor = element.parent
        var hops = 0
        while let current = cursor, hops < 4 {
            if isSearchActivationRole(current.role) {
                return current
            }
            cursor = current.parent
            hops += 1
        }

        return element
    }

    private func isSearchActivationRole(_ role: String?) -> Bool {
        switch role {
        case kAXRowRole, kAXCellRole, kAXButtonRole, kAXGroupRole:
            return true
        default:
            return false
        }
    }

    private func tryRaiseWindow(_ window: UIElement) -> Bool {
        if supportsAction(kAXRaiseAction, on: window) {
            do {
                try window.performAction(kAXRaiseAction)
                runner.log("window: raised via AXRaise")
                return true
            } catch {
                runner.log("window: AXRaise failed (\(error))")
            }
        }
        return false
    }

    private func waitForWindowClosed(_ window: UIElement, label: String) -> Bool {
        runner.waitUntil(label: label, timeout: 0.9, pollInterval: 0.06, evaluateAfterTimeout: false) {
            !kakao.windows.contains { candidate in
                areSameAXElement(candidate, window)
            }
        }
    }

    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }

    private func isElementLikelyInsideWindow(elementFrame: CGRect, windowFrame: CGRect) -> Bool {
        let expandedWindow = windowFrame.insetBy(dx: -24, dy: -24)
        return expandedWindow.intersects(elementFrame)
    }
}
```

- [ ] **Step 2: Delete the nine moved methods from `ChatWindowResolver.swift`.** Anchor on signatures `private func supportsAction(_ action: String, on element: UIElement) -> Bool`, `private func findMatchingChatWindow(in windows: [UIElement], query: String) -> UIElement?`, `private func deduplicateElements(_ elements: [UIElement]) -> [UIElement]`, `private func activationTarget(for element: UIElement) -> UIElement`, `private func isSearchActivationRole(_ role: String?) -> Bool`, `private func tryRaiseWindow(_ window: UIElement) -> Bool`, `private func waitForWindowClosed(_ window: UIElement, label: String) -> Bool`, `private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool`, `private func isElementLikelyInsideWindow(elementFrame: CGRect, windowFrame: CGRect) -> Bool`. LEAVE `deduplicateSearchCandidates(_:)` IN PLACE (references file-private `SearchCandidate`). Callers `closeWindow`, `findMatchingSearchResults`, `scoreSearchResult`, `isLikelySearchField`, `triggerSearchResultOpen`, etc. remain and resolve across files.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff` and confirm only deletions of the nine methods in origin (`deduplicateSearchCandidates` still present); verbatim wrapper in new file. No value changes.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: `Build complete!`, no new warnings vs baseline.

- [ ] **Step 5: GOLDEN.** Run:
```
.build/debug/kmsg chats --verbose --limit 20 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.err
.build/debug/kmsg send "테헤란로 죽돌이" "ping" --dry-run > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check.err
```
Expected: empty diff for both.

- [ ] **Step 6: COMMIT.** Run:
```
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver+AXElementUtilities.swift
git commit -m "refactor(resolver): extract AX element utilities into +AXElementUtilities extension"
```

---

### Task 4A.11: Extract ChatWindowResolver search-field location into `+SearchFieldLocator`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver+SearchFieldLocator.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
- Verify: build + chats/send_dryrun goldens

Methods to MOVE from `ChatWindowResolver` (anchor on signatures):
- `resolveCachedElement(slot:root:validate:)` — lines 232–246 — `private func resolveCachedElement(slot: AXPathSlot, root: UIElement, validate: (UIElement) -> Bool) -> UIElement?`
- `rememberCachedElement(slot:root:element:)` — lines 248–258 — `private func rememberCachedElement(slot: AXPathSlot, root: UIElement, element: UIElement)`
- `locateSearchField(in:)` — lines 260–310 — `private func locateSearchField(in rootWindow: UIElement) -> UIElement?`
- `discoverSearchFieldCandidates(in:)` — lines 312–322 — `private func discoverSearchFieldCandidates(in rootWindow: UIElement) -> [UIElement]`
- `pickSearchField(from:)` — lines 926–935 — `private func pickSearchField(from fields: [UIElement]) -> UIElement?`

> These reference `AXPathSlot`, `AXPathCacheStore` (internal, defined elsewhere in module), `kAXTextFieldRole`/`kAXButtonRole` (constants), and `UIElement` — all internal. No file-private type → clean move.

- [ ] **Step 1: Create the new extension file** with the five search-field helpers moved verbatim.

```swift
import ApplicationServices.HIServices
import Foundation

extension ChatWindowResolver {
    private func resolveCachedElement(
        slot: AXPathSlot,
        root: UIElement,
        validate: (UIElement) -> Bool
    ) -> UIElement? {
        guard useCache else { return nil }
        return AXPathCacheStore.shared.resolve(
            slot: slot,
            root: root,
            validate: validate,
            trace: { message in
                runner.log(message)
            }
        )
    }

    private func rememberCachedElement(slot: AXPathSlot, root: UIElement, element: UIElement) {
        guard useCache else { return }
        AXPathCacheStore.shared.remember(
            slot: slot,
            root: root,
            element: element,
            trace: { message in
                runner.log(message)
            }
        )
    }

    private func locateSearchField(in rootWindow: UIElement) -> UIElement? {
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

        let searchButtons = rootWindow.findAll(role: kAXButtonRole, limit: 24, maxNodes: 220).filter { button in
            let title = (button.title ?? "").lowercased()
            let description = (button.axDescription ?? "").lowercased()
            let identifier = (button.identifier ?? "").lowercased()

            if identifier == "friends" || identifier == "chatrooms" || identifier == "more" {
                return false
            }

            return title.contains("search")
                || title.contains("검색")
                || description.contains("search")
                || description.contains("검색")
                || identifier.contains("search")
        }

        for button in searchButtons.prefix(4) {
            do {
                try button.press()
                runner.log("search: pressed search-like button title='\(button.title ?? "")' id='\(button.identifier ?? "")'")
            } catch {
                runner.log("search: search-like button press failed (\(error))")
            }

            Thread.sleep(forTimeInterval: 0.08)
            let fields = discoverSearchFieldCandidates(in: rootWindow)
            if let field = pickSearchField(from: fields) {
                rememberCachedElement(slot: .searchField, root: rootWindow, element: field)
                return field
            }
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
}
```

- [ ] **Step 2: Delete the five moved methods from `ChatWindowResolver.swift`.** Anchor on signatures `private func resolveCachedElement(`, `private func rememberCachedElement(slot: AXPathSlot, root: UIElement, element: UIElement)`, `private func locateSearchField(in rootWindow: UIElement) -> UIElement?`, `private func discoverSearchFieldCandidates(in rootWindow: UIElement) -> [UIElement]`, `private func pickSearchField(from fields: [UIElement]) -> UIElement?`, removing each full body. Caller `openChatViaSearch` remains in origin.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff` and confirm pure relocation only.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: `Build complete!`, no new warnings vs baseline.

- [ ] **Step 5: GOLDEN.** Run:
```
.build/debug/kmsg chats --verbose --limit 20 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.err
.build/debug/kmsg send "테헤란로 죽돌이" "ping" --dry-run > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check.err
```
Expected: empty diff for both.

- [ ] **Step 6: COMMIT.** Run:
```
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver+SearchFieldLocator.swift
git commit -m "refactor(resolver): extract search field location into +SearchFieldLocator extension"
```

---

### Task 4A.12: Extract ChatWindowResolver chat-window validation into `+ChatWindowValidation`

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver+ChatWindowValidation.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
- Verify: build + chats/send_dryrun goldens

Methods to MOVE from `ChatWindowResolver` (anchor on signatures):
- `windowContainsLikelyChatInput(_:)` — lines 481–492 — `private func windowContainsLikelyChatInput(_ window: UIElement) -> Bool`
- `isLikelyMessageInputElement(_:in:)` — lines 494–508 — `private func isLikelyMessageInputElement(_ element: UIElement, in window: UIElement? = nil) -> Bool`
- `isLikelySearchField(_:in:)` — lines 510–536 — `private func isLikelySearchField(_ element: UIElement, in window: UIElement?) -> Bool`
- `findCloseButton(in:)` — lines 950–964 — `private func findCloseButton(in window: UIElement) -> UIElement?`

> All reference only internal/standard types. `isLikelyMessageInputElement` calls `isLikelySearchField`, `isLikelySearchField` calls `isElementLikelyInsideWindow` (moved to `+AXElementUtilities` in Task 4A.10) — same type, resolves across files. No file-private type → clean move.

- [ ] **Step 1: Create the new extension file** with the four validation helpers moved verbatim.

```swift
import ApplicationServices.HIServices
import Foundation

extension ChatWindowResolver {
    private func windowContainsLikelyChatInput(_ window: UIElement) -> Bool {
        if window.findFirst(where: { element in
            guard element.isEnabled else { return false }
            return element.role == kAXTextAreaRole
        }) != nil {
            return true
        }

        return window.findFirst(where: { element in
            isLikelyMessageInputElement(element, in: window) && element.role != kAXTextFieldRole
        }) != nil
    }

    private func isLikelyMessageInputElement(_ element: UIElement, in window: UIElement? = nil) -> Bool {
        guard element.isEnabled else { return false }
        let role = element.role ?? ""
        if role == kAXTextAreaRole {
            return true
        }

        let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
        guard editable else { return false }
        guard role != kAXStaticTextRole && role != kAXImageRole else { return false }
        if role == kAXTextFieldRole, isLikelySearchField(element, in: window) {
            return false
        }
        return true
    }

    private func isLikelySearchField(_ element: UIElement, in window: UIElement?) -> Bool {
        let role = element.role ?? ""
        guard role == kAXTextFieldRole else { return false }

        let joinedText = [
            element.identifier ?? "",
            element.title ?? "",
            element.axDescription ?? "",
        ]
        .joined(separator: " ")
        .lowercased()

        if joinedText.contains("search") || joinedText.contains("검색") {
            return true
        }

        guard let windowFrame = window?.frame, let elementFrame = element.frame, windowFrame.height > 0 else {
            return false
        }

        if !isElementLikelyInsideWindow(elementFrame: elementFrame, windowFrame: windowFrame) {
            return true
        }

        let relativeY = (elementFrame.midY - windowFrame.minY) / windowFrame.height
        return relativeY < 0.5
    }

    private func findCloseButton(in window: UIElement) -> UIElement? {
        let buttons = window.findAll(role: kAXButtonRole, limit: 6, maxNodes: 80)
        if let match = buttons.first(where: { button in
            let joined = [
                button.identifier ?? "",
                button.title ?? "",
                button.axDescription ?? "",
            ].joined(separator: " ").lowercased()
            return joined.contains("close") || joined.contains("닫기")
        }) {
            return match
        }

        return buttons.first
    }
}
```

- [ ] **Step 2: Delete the four moved methods from `ChatWindowResolver.swift`.** Anchor on signatures `private func windowContainsLikelyChatInput(_ window: UIElement) -> Bool`, `private func isLikelyMessageInputElement(_ element: UIElement, in window: UIElement? = nil) -> Bool`, `private func isLikelySearchField(_ element: UIElement, in window: UIElement?) -> Bool`, `private func findCloseButton(in window: UIElement) -> UIElement?`, removing each full body. Callers `resolveOpenedChatWindow` (in `+WindowResolutionStrategy`) and `closeWindow` (origin) resolve across files.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff` and confirm pure relocation only.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: `Build complete!`, no new warnings vs baseline.

- [ ] **Step 5: GOLDEN.** Run:
```
.build/debug/kmsg chats --verbose --limit 20 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.err
.build/debug/kmsg send "테헤란로 죽돌이" "ping" --dry-run > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check.err
```
Expected: empty diff for both.

- [ ] **Step 6: COMMIT.** Run:
```
git add /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift /Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver+ChatWindowValidation.swift
git commit -m "refactor(resolver): extract chat window validation into +ChatWindowValidation extension"
```

---

> **Stays in `ChatWindowResolver.swift` (high-risk, EXCLUDED from this phase):** `resolve(query:)`, `closeWindow(_:)`, `openChatViaSearch(query:in:fallbackWindow:)`, `requireUsableWindow()` (file-private `ChatWindowFailureCode` coupling), `waitForMatchingSearchResults`/`findMatchingSearchResults` (file-private `SearchScanProfile`/`SearchCandidate` coupling — Task 4A.8 skipped), `deduplicateSearchCandidates(_:)` (file-private `SearchCandidate`), and the entire **SearchResultActivation** region — `triggerSearchResultOpen(_:searchField:opened:)` (lines 576–634), `tryActivateSearchResult(_:label:)` (lines 636–662), `trySelectSearchResult(_:label:)` (lines 664–673), `pickBestSearchResult(from:)` (lines 538–549), `scoreSearchResult(_:)` (lines 551–574) — all remain in the main file by directive.
>
> **Stays in `TranscriptReader.swift`:** the public `readSnapshot` entry points, `collectTranscriptRows`, `extractMessages`, `extractFallbackMessages`, the file-private-type-coupled row methods (`analyzeRow`, `extractRowMetadata`, `parseRowMetadata`, `isLikelySystemRow`, `inferMessageSide`, `resolveAuthorInSegment`, `deduplicateBodyCandidates`), the free func `messageFingerprint`, and the file-scope types `TranscriptMessage`/`TranscriptSnapshot`/`TranscriptReadError`/`RowMetadata`/`MessageBodyCandidate`/`RowAnalysis`/`MessageSide`.

---

## Phase 4B — Decompose SendCommand, MCPServerCommand & KakaoTalkAuthenticator (pure code-move)

**Goal:** Relocate provably logic-free helper groups out of three oversized files into focused new types/files with no behavior change — every moved body is byte-identical, every call site rewires through a thin wrapper or a stored collaborator.

**Aggregate risk: low**

> Cross-phase preconditions (already applied by Phases 1–2, treat as existing): `UIElement.isSameElement(_:)` in `Accessibility/UIElement+Identity.swift`; `UIElement.isTextInputRole` / `UIElement.isEditable` in `Accessibility/UIElement+Roles.swift`; `kAXSecureTextFieldRole` constant in `Accessibility/AXConstants.swift`; `throwIfAXError(_:)` in `Accessibility/AXError+Extension.swift`. This phase does **not** reroute any predicate through `isTextInputRole`/`isEditable` and does **not** migrate any guard to `throwIfAXError` — those substitutions belonged to earlier phases. Phase 4B is purely structural relocation.

---

### Task 4B.1: Extract `MCPJSONRPCFramer` from MCPServerCommand (stdio framing — VERBATIM move)

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/MCPJSONRPCFramer.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/MCPServerCommand.swift`
- Verify: golden `mcp`

The three framing methods in `KmsgMCPServer` (`readMessage` lines 765–798, `readHeaderLine` lines 800–812, `readExact` lines 814–822, `writeMessage` lines 824–836) are pure stdio/JSON plumbing with no reference to instance state (`initialized`, `shutdown`, `runner`, etc.). They move VERBATIM into a stateless helper type. The header/body/`fflush` ordering inside `writeMessage` MUST NOT change.

- [ ] **Step 1: Create the framer file with the four methods moved VERBATIM.** Copy the bodies of `readMessage` (765–798), `readHeaderLine` (800–812), `readExact` (814–822), `writeMessage` (824–836) with zero edits to statement order. Note `readMessage` returns `JSONDict?`; preserve the `private typealias JSONDict = [String: Any]` is file-private to MCPServerCommand.swift, so the new file redeclares its own file-private alias identically.

```swift
import Darwin
import Foundation

private typealias JSONDict = [String: Any]

/// Length-prefixed JSON-RPC stdio framing for the MCP server.
/// Pure stdin/stdout plumbing — no server state. Moved verbatim from KmsgMCPServer.
struct MCPJSONRPCFramer {
    func readMessage() -> JSONDict? {
        var headers: [String: String] = [:]

        while true {
            guard let line = readHeaderLine() else { return nil }
            if line == "\r\n" || line == "\n" {
                break
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }

            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }

        guard let lengthString = headers["content-length"],
              let contentLength = Int(lengthString),
              contentLength > 0,
              let body = readExact(contentLength)
        else {
            return nil
        }

        guard let object = try? JSONSerialization.jsonObject(with: body),
              let dict = object as? JSONDict
        else {
            return nil
        }
        return dict
    }

    private func readHeaderLine() -> String? {
        var bytes: [UInt8] = []
        while true {
            let char = getchar()
            if char == EOF {
                return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(UInt8(char))
            if char == 10 {
                return String(decoding: bytes, as: UTF8.self)
            }
        }
    }

    private func readExact(_ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        let readCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return fread(baseAddress, 1, count, stdin)
        }
        guard readCount == count else { return nil }
        return Data(buffer)
    }

    func writeMessage(_ payload: JSONDict) throws {
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [])
        let header = "Content-Length: \(encoded.count)\r\n\r\n"
        header.utf8CString.withUnsafeBufferPointer { buffer in
            _ = fwrite(buffer.baseAddress, 1, buffer.count - 1, stdout)
        }
        encoded.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                _ = fwrite(baseAddress, 1, encoded.count, stdout)
            }
        }
        fflush(stdout)
    }
}
```

- [ ] **Step 2: Add a stored `framer` instance to `KmsgMCPServer`.** In `MCPServerCommand.swift`, anchor on the existing stored-property block at the top of `final class KmsgMCPServer` (lines 134–141, the `private let runner = KmsgSubprocessRunner()` group). Add the framer beside `runner`:

```swift
    private let protocolVersion = "2024-11-05"
    private let runner = KmsgSubprocessRunner()
    private let framer = MCPJSONRPCFramer()
```

- [ ] **Step 3: Rewire the two read/write call sites in `serveForever()` to the framer.** In `MCPServerCommand.swift`, function `serveForever()` (lines 152–177), replace the bare `readMessage()` and the three `writeMessage(...)` calls with `framer.`-prefixed calls. The body becomes:

```swift
    func serveForever() throws {
        while !shutdown {
            guard let request = framer.readMessage() else { break }
            guard request["method"] != nil else { continue }

            let requestID = request["id"]
            do {
                if let response = try handleRequest(request) {
                    try framer.writeMessage(response)
                }
            } catch let error as KmsgMCPError {
                guard let requestID else { continue }
                try framer.writeMessage(jsonRPCError(id: requestID, code: error.code, message: error.message, data: error.data))
            } catch {
                guard let requestID else { continue }
                try framer.writeMessage(
                    jsonRPCError(
                        id: requestID,
                        code: -32000,
                        message: "Internal server error",
                        data: ["detail": String(describing: error)]
                    )
                )
            }
        }
    }
```

- [ ] **Step 4: Delete the four moved methods from `KmsgMCPServer`.** In `MCPServerCommand.swift`, remove `readMessage()` (765–798), `readHeaderLine()` (800–812), `readExact(_:)` (814–822), and `writeMessage(_:)` (824–836) in their entirety. No other method in `KmsgMCPServer` calls these except `serveForever()`, which was rewired in Step 3 — confirm by checking there are no remaining bare `readMessage(`/`writeMessage(`/`readHeaderLine(`/`readExact(` references in the file.

- [ ] **Step 5: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Commands/MCPServerCommand.swift Sources/kmsg/Commands/MCPJSONRPCFramer.swift` | Confirm the diff is ONLY: (a) verbatim relocation of the four method bodies into the new file (no token reordering inside `writeMessage` — header write, then body write, then `fflush(stdout)` last), (b) the added `framer` property, (c) `framer.` prefix on the 1 read + 3 write call sites. No value, ordering, or logic change.

- [ ] **Step 6: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs baseline at `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 7: GOLDEN (mcp).** Run:
```bash
.build/debug/kmsg mcp-server < /tmp/kmsg-golden-baseline/mcp.in > /tmp/check.out 2> /tmp/check.err; diff /tmp/kmsg-golden-baseline/mcp.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/mcp.err /tmp/check.err
```
Expected: empty diff (byte-identical framed JSON-RPC output). If the saved `mcp` golden was captured by a different invocation form, re-run the exact Phase-0 `mcp` golden command instead — the requirement is byte-identical stdout/stderr vs `/tmp/kmsg-golden-baseline/mcp.out`/`.err`.

- [ ] **Step 8: COMMIT.** Run:
```bash
git add Sources/kmsg/Commands/MCPJSONRPCFramer.swift Sources/kmsg/Commands/MCPServerCommand.swift
git commit -m "refactor(mcp): extract MCPJSONRPCFramer for stdio framing"
```

---

### Task 4B.2: Extract `KmsgErrorMapper` from MCPServerCommand (pure string mapping)

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/KmsgErrorMapper.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/MCPServerCommand.swift`
- Verify: golden `mcp`

`extractErrorCode(_:)` (lines 670–685) and `mapHint(_:)` (lines 687–700) are pure functions over `String` with no instance-state dependency. They move VERBATIM into a stateless type.

- [ ] **Step 1: Create the mapper file with both methods moved VERBATIM.**

```swift
import Foundation

/// Pure mapping from kmsg subprocess output to stable MCP error codes and hints.
/// No server state. Moved verbatim from KmsgMCPServer.
struct KmsgErrorMapper {
    func extractErrorCode(_ combinedText: String) -> String {
        let lowered = combinedText.lowercased()
        if lowered.contains("no such file or directory") || lowered.contains("not found") {
            return "KMSG_BIN_NOT_FOUND"
        }
        if combinedText.contains("WINDOW_NOT_READY") {
            return "KAKAO_WINDOW_UNAVAILABLE"
        }
        if combinedText.contains("SEARCH_MISS") {
            return "CHAT_NOT_FOUND"
        }
        if combinedText.contains("Accessibility") || combinedText.contains("손쉬운 사용") {
            return "ACCESSIBILITY_PERMISSION_DENIED"
        }
        return "UNKNOWN_EXEC_FAILURE"
    }

    func mapHint(_ code: String) -> String {
        switch code {
        case "KMSG_BIN_NOT_FOUND":
            return "Install kmsg and ensure the current binary is executable."
        case "KAKAO_WINDOW_UNAVAILABLE":
            return "KakaoTalk window was not ready. Open KakaoTalk and retry (or enable deep_recovery)."
        case "CHAT_NOT_FOUND":
            return "Chat was not found in search results. Verify chat name spacing and visibility."
        case "ACCESSIBILITY_PERMISSION_DENIED":
            return "Grant Accessibility permission in System Settings > Privacy & Security > Accessibility."
        default:
            return "Check raw_stdout/raw_stderr and rerun with trace_ax=true for details."
        }
    }
}
```

- [ ] **Step 2: Add a stored `errorMapper` instance to `KmsgMCPServer`.** Anchor on the stored-property block updated in Task 4B.1 (the `private let framer = MCPJSONRPCFramer()` line). Add beside it:

```swift
    private let framer = MCPJSONRPCFramer()
    private let errorMapper = KmsgErrorMapper()
```

- [ ] **Step 3: Rewire every `extractErrorCode`/`mapHint` call site through `errorMapper`.** There are exactly 6 call sites across three handlers. Replace each verbatim.

  In `callKmsgRead(_:)`: line 425 `let code = extractErrorCode(combined)`, line 433 `let retryCode = extractErrorCode("\(retry.stdout)\n\(retry.stderr)")`, line 437 `hint: mapHint(retryCode),`, line 447 `hint: mapHint(code),`:
```swift
            let code = errorMapper.extractErrorCode(combined)
```
```swift
                    let retryCode = errorMapper.extractErrorCode("\(retry.stdout)\n\(retry.stderr)")
                    return errorPayload(
                        code: retryCode,
                        message: "kmsg read failed after deep-recovery retry",
                        hint: errorMapper.mapHint(retryCode),
```
```swift
                return errorPayload(
                    code: code,
                    message: "kmsg read failed",
                    hint: errorMapper.mapHint(code),
```

  In `callKmsgSend(_:)`: line 532 `let code = extractErrorCode("\(run.stdout)\n\(run.stderr)")`, line 536 `hint: mapHint(code),`:
```swift
            let code = errorMapper.extractErrorCode("\(run.stdout)\n\(run.stderr)")
            return errorPayload(
                code: code,
                message: "kmsg send failed",
                hint: errorMapper.mapHint(code),
```

  In `callKmsgSendImage(_:)`: line 619 `let code = extractErrorCode("\(run.stdout)\n\(run.stderr)")`, line 622 `hint: mapHint(code),`:
```swift
            let code = errorMapper.extractErrorCode("\(run.stdout)\n\(run.stderr)")
            return errorPayload(
                code: code,
                message: "kmsg send-image failed",
                hint: errorMapper.mapHint(code),
```

- [ ] **Step 4: Delete the two moved methods from `KmsgMCPServer`.** Remove `extractErrorCode(_:)` (670–685) and `mapHint(_:)` (687–700). Confirm no remaining bare `extractErrorCode(`/`mapHint(` references in the file (all 6 now go through `errorMapper.`).

- [ ] **Step 5: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Commands/MCPServerCommand.swift Sources/kmsg/Commands/KmsgErrorMapper.swift` | Confirm ONLY: verbatim relocation of two methods, added `errorMapper` property, `errorMapper.` prefix on the 6 call sites. No string-literal, case-order, or branch change.

- [ ] **Step 6: BUILD GATE.** Run: `swift build` | Expected: `Build complete!` (exit 0), no new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 7: GOLDEN (mcp).** Run:
```bash
.build/debug/kmsg mcp-server < /tmp/kmsg-golden-baseline/mcp.in > /tmp/check.out 2> /tmp/check.err; diff /tmp/kmsg-golden-baseline/mcp.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/mcp.err /tmp/check.err
```
Expected: empty diff.

- [ ] **Step 8: COMMIT.** Run:
```bash
git add Sources/kmsg/Commands/KmsgErrorMapper.swift Sources/kmsg/Commands/MCPServerCommand.swift
git commit -m "refactor(mcp): extract KmsgErrorMapper for error code/hint mapping"
```

---

### Task 4B.3: Extract `KmsgArgumentParser` from MCPServerCommand (pure value coercion)

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/KmsgArgumentParser.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/MCPServerCommand.swift`
- Verify: golden `mcp`

`boolValue(_:defaultValue:)` (lines 702–717), `jsonObject(from:)` (lines 719–727), and `prettyJSONString(_:)` (lines 729–736) are pure value coercion/serialization helpers with no instance-state dependency. They move VERBATIM. `jsonObject`/`prettyJSONString` use the file-private `JSONDict` alias, which the new file redeclares identically.

- [ ] **Step 1: Create the parser file with the three methods moved VERBATIM.**

```swift
import Foundation

private typealias JSONDict = [String: Any]

/// Pure JSON-RPC argument coercion and serialization helpers for the MCP server.
/// No server state. Moved verbatim from KmsgMCPServer.
struct KmsgArgumentParser {
    func boolValue(_ raw: Any?, defaultValue: Bool) -> Bool {
        guard let raw else { return defaultValue }
        if let bool = raw as? Bool { return bool }
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String {
            switch string.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return defaultValue
            }
        }
        return defaultValue
    }

    func jsonObject(from string: String) -> JSONDict? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? JSONDict
        else {
            return nil
        }
        return dict
    }

    func prettyJSONString(_ object: JSONDict) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}
```

- [ ] **Step 2: Add a stored `argumentParser` instance to `KmsgMCPServer`.** Anchor on the property block extended in Task 4B.2 (`private let errorMapper = KmsgErrorMapper()`). Add beside it:

```swift
    private let errorMapper = KmsgErrorMapper()
    private let argumentParser = KmsgArgumentParser()
```

- [ ] **Step 3: Rewire every call site through `argumentParser`.** Enumerated sites:

  `prettyJSONString` — 1 site, in `handleToolsCall(_:)` line 361:
```swift
            "content": [["type": "text", "text": argumentParser.prettyJSONString(resultObject)]],
```

  `jsonObject(from:)` — 1 site, in `callKmsgRead(_:)` line 455:
```swift
        guard let payload = argumentParser.jsonObject(from: first.stdout) else {
```

  `boolValue(_:defaultValue:)` — 10 sites. In `callKmsgRead(_:)` lines 400–402:
```swift
        let deepRecovery = argumentParser.boolValue(arguments["deep_recovery"], defaultValue: deepRecoveryDefault)
        let keepWindow = argumentParser.boolValue(arguments["keep_window"], defaultValue: false)
        let traceAX = argumentParser.boolValue(arguments["trace_ax"], defaultValue: traceDefault)
```
  In `callKmsgSend(_:)` line 487:
```swift
        let confirm = argumentParser.boolValue(arguments["confirm"], defaultValue: false)
```
  In `callKmsgSend(_:)` lines 511–513:
```swift
        let deepRecovery = argumentParser.boolValue(arguments["deep_recovery"], defaultValue: deepRecoveryDefault)
        let keepWindow = argumentParser.boolValue(arguments["keep_window"], defaultValue: false)
        let traceAX = argumentParser.boolValue(arguments["trace_ax"], defaultValue: traceDefault)
```
  In `callKmsgSendImage(_:)` line 563:
```swift
        let confirm = argumentParser.boolValue(arguments["confirm"], defaultValue: false)
```
  In `callKmsgSendImage(_:)` lines 598–600:
```swift
        let deepRecovery = argumentParser.boolValue(arguments["deep_recovery"], defaultValue: deepRecoveryDefault)
        let keepWindow = argumentParser.boolValue(arguments["keep_window"], defaultValue: false)
        let traceAX = argumentParser.boolValue(arguments["trace_ax"], defaultValue: traceDefault)
```

- [ ] **Step 4: Delete the three moved methods from `KmsgMCPServer`.** Remove `boolValue(_:defaultValue:)` (702–717), `jsonObject(from:)` (719–727), `prettyJSONString(_:)` (729–736). Confirm no remaining bare `boolValue(`/`jsonObject(`/`prettyJSONString(` references (all 12 now go through `argumentParser.`).

- [ ] **Step 5: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Commands/MCPServerCommand.swift Sources/kmsg/Commands/KmsgArgumentParser.swift` | Confirm ONLY verbatim relocation, added `argumentParser` property, and `argumentParser.` prefix on the 12 call sites. No coercion-rule, default-value, or serialization-option change.

- [ ] **Step 6: BUILD GATE.** Run: `swift build` | Expected: `Build complete!`, no new warning vs baseline.

- [ ] **Step 7: GOLDEN (mcp).** Run:
```bash
.build/debug/kmsg mcp-server < /tmp/kmsg-golden-baseline/mcp.in > /tmp/check.out 2> /tmp/check.err; diff /tmp/kmsg-golden-baseline/mcp.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/mcp.err /tmp/check.err
```
Expected: empty diff.

- [ ] **Step 8: COMMIT.** Run:
```bash
git add Sources/kmsg/Commands/KmsgArgumentParser.swift Sources/kmsg/Commands/MCPServerCommand.swift
git commit -m "refactor(mcp): extract KmsgArgumentParser for argument coercion"
```

---

### Task 4B.4: Extract `KmsgToolCallHandler` from MCPServerCommand (tool execution unit)

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/KmsgToolCallHandler.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/MCPServerCommand.swift`
- Verify: golden `mcp`

This is the larger of the MCP extracts. The tool-call execution group — `handleToolsCall(_:)` (344–365), `callKmsgRead(_:)` (367–482), `callKmsgSend(_:)` (484–558), `callKmsgSendImage(_:)` (560–645), and `errorPayload(...)` (647–668) — depends only on collaborators (`runner`, `argumentParser`, `errorMapper`) and the two configuration flags (`deepRecoveryDefault`, `traceDefault`) read in `init`. It does NOT touch `initialized`/`shutdown`/`protocolVersion`/`serverVersion`/`framer`. It moves into a dedicated handler that receives its three collaborators by injection.

> Note: `handleToolsCall` references `argumentParser.prettyJSONString` (rewired in 4B.3) and `callKmsg*` reference `errorMapper`/`argumentParser` (rewired in 4B.2/4B.3). Those calls move with the bodies unchanged — the collaborators now live as stored properties on the handler.

- [ ] **Step 1: Create the handler file, moving the five methods VERBATIM and adding an injected initializer.** The `runner` here is `KmsgSubprocessRunner` (the MCP server's subprocess runner, file-private in MCPServerCommand.swift) — see Step 2 for the visibility prerequisite. Bodies are copied unchanged; only the enclosing type and `init` are new.

```swift
import Foundation

private typealias JSONDict = [String: Any]

/// Executes MCP `tools/call` requests by shelling out to the kmsg CLI and shaping payloads.
/// Holds no JSON-RPC transport or lifecycle state. Moved verbatim from KmsgMCPServer.
struct KmsgToolCallHandler {
    private let runner: KmsgSubprocessRunner
    private let argumentParser: KmsgArgumentParser
    private let errorMapper: KmsgErrorMapper
    private let deepRecoveryDefault: Bool
    private let traceDefault: Bool

    init(
        runner: KmsgSubprocessRunner,
        argumentParser: KmsgArgumentParser,
        errorMapper: KmsgErrorMapper,
        deepRecoveryDefault: Bool,
        traceDefault: Bool
    ) {
        self.runner = runner
        self.argumentParser = argumentParser
        self.errorMapper = errorMapper
        self.deepRecoveryDefault = deepRecoveryDefault
        self.traceDefault = traceDefault
    }

    func handleToolsCall(_ params: JSONDict) throws -> JSONDict {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? JSONDict ?? [:]

        let resultObject: JSONDict
        switch name {
        case "kmsg_read":
            resultObject = callKmsgRead(arguments)
        case "kmsg_send":
            resultObject = callKmsgSend(arguments)
        case "kmsg_send_image":
            resultObject = callKmsgSendImage(arguments)
        default:
            throw KmsgMCPError(code: -32601, message: "Unknown tool: \(name)")
        }

        return [
            "content": [["type": "text", "text": argumentParser.prettyJSONString(resultObject)]],
            "isError": !(resultObject["ok"] as? Bool ?? false),
            "structuredContent": resultObject,
        ]
    }

    // ... callKmsgRead, callKmsgSend, callKmsgSendImage, errorPayload moved VERBATIM
    // from MCPServerCommand.swift lines 367-482, 484-558, 560-645, 647-668 respectively.
}
```
  Copy `callKmsgRead(_:)` (367–482), `callKmsgSend(_:)` (484–558), `callKmsgSendImage(_:)` (560–645), and `errorPayload(...)` (647–668) into the handler with NO edits — they already reference `runner.`, `argumentParser.`, `errorMapper.`, `deepRecoveryDefault`, `traceDefault`, all of which are now stored properties or injected here. Mark `callKmsg*`/`errorPayload` `private`.

- [ ] **Step 2: Relax visibility on the collaborator types so the handler can hold them.** `KmsgToolCallHandler` (a separate type) holds `KmsgSubprocessRunner`, `KmsgArgumentParser`, `KmsgErrorMapper`, and constructs/throws `KmsgMCPError`. The Task 4B.2/4B.3 files already declare `KmsgErrorMapper`/`KmsgArgumentParser` at internal visibility (no `private`). `KmsgSubprocessRunner` and `KmsgMCPError` are currently `private` in MCPServerCommand.swift (lines 27 and 15). Change exactly those two declarations from `private final class`/`private struct` to internal by deleting the `private` keyword. In `MCPServerCommand.swift`:
```swift
struct KmsgMCPError: Error, @unchecked Sendable {
```
```swift
final class KmsgSubprocessRunner {
```
  No other tokens on those two lines change. (Both types live in the same module; dropping `private` is a pure visibility widen with no behavioral effect.)

- [ ] **Step 3: Add a stored `toolCallHandler` to `KmsgMCPServer` and construct it in `init`.** In `MCPServerCommand.swift`, add the stored property beside the others (after `private let argumentParser = KmsgArgumentParser()` from Task 4B.3):
```swift
    private let argumentParser = KmsgArgumentParser()
    private let toolCallHandler: KmsgToolCallHandler
```
  Then, inside `init()` (lines 143–150), after the existing assignments to `deepRecoveryDefault`/`traceDefault`/`serverVersion`, construct the handler. The handler needs the SAME `runner`/`argumentParser`/`errorMapper` instances and the resolved flag values:
```swift
        serverVersion = env["KMSG_MCP_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? env["KMSG_MCP_VERSION"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            : BuildVersion.current
        toolCallHandler = KmsgToolCallHandler(
            runner: runner,
            argumentParser: argumentParser,
            errorMapper: errorMapper,
            deepRecoveryDefault: deepRecoveryDefault,
            traceDefault: traceDefault
        )
```
  Behavior note: `deepRecoveryDefault`/`traceDefault` are immutable `let`s assigned once before this point, so the captured values are identical to what the original in-class methods read.

- [ ] **Step 4: Rewire the single `handleToolsCall` call site in `handleRequest(_:)` to the handler.** In `MCPServerCommand.swift`, function `handleRequest(_:)`, the `"tools/call"` case (lines 219–223):
```swift
        case "tools/call":
            try ensureInitialized()
            let params = request["params"] as? JSONDict ?? [:]
            let result = try toolCallHandler.handleToolsCall(params)
            return jsonRPCResult(id: requestID, result: result)
```

- [ ] **Step 5: Delete the five moved methods from `KmsgMCPServer`.** Remove `handleToolsCall(_:)` (344–365), `callKmsgRead(_:)` (367–482), `callKmsgSend(_:)` (484–558), `callKmsgSendImage(_:)` (560–645), `errorPayload(...)` (647–668). Confirm `KmsgMCPServer` retains `errorMapper`/`argumentParser` stored properties only if still used elsewhere — after this task neither is referenced directly by `KmsgMCPServer` (both are passed into the handler in `init`); leave the stored properties in place since `init` references them to construct the handler. Confirm no remaining bare `handleToolsCall(`/`callKmsgRead(`/`callKmsgSend(`/`callKmsgSendImage(`/`errorPayload(` references in `KmsgMCPServer`.

- [ ] **Step 6: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Commands/MCPServerCommand.swift Sources/kmsg/Commands/KmsgToolCallHandler.swift` | Confirm ONLY: verbatim relocation of five methods, the new injected `init`, two `private`-keyword deletions (Step 2), added `toolCallHandler` property + its `init` construction, and `toolCallHandler.` prefix on the one `tools/call` call site. No payload-shape, timeout-value, command-array, or branch change.

- [ ] **Step 7: BUILD GATE.** Run: `swift build` | Expected: `Build complete!`, no new warning vs baseline.

- [ ] **Step 8: GOLDEN (mcp).** Run:
```bash
.build/debug/kmsg mcp-server < /tmp/kmsg-golden-baseline/mcp.in > /tmp/check.out 2> /tmp/check.err; diff /tmp/kmsg-golden-baseline/mcp.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/mcp.err /tmp/check.err
```
Expected: empty diff. (If the `mcp` golden exercises `tools/call` with a live KakaoTalk dependency, run it against the live session per Phase-0 capture conditions; the framed payload shape must remain byte-identical.)

- [ ] **Step 9: COMMIT.** Run:
```bash
git add Sources/kmsg/Commands/KmsgToolCallHandler.swift Sources/kmsg/Commands/MCPServerCommand.swift
git commit -m "refactor(mcp): extract KmsgToolCallHandler for tool execution"
```

---

### Task 4B.5: Extract `SendCommand` output/formatting helpers (logic-free move only)

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand+Scoring.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift`
- Verify: golden `send_dryrun`

**Scope guard — what moves vs. what is DEFERRED:**

- **DEFERRED — MessageInputResolution group** (`resolveMessageInputField` 751–823, `collectMessageInputCandidates` 825–841, `collectFocusedElementLineageCandidates` 843–860, `resolveMessageInputField` cache/focus interplay, `sendMessageToWindow` 671–721, `forceTypeIntoChatWindow` 878–891, `tryRaiseWindow` 893–904): these are timing-coupled (`Thread.sleep`, focus/activate ordering, retry loops, cache slot writes) and observable only through live send. **Not touched in Phase 4B.**
- **DEFERRED — SearchOperations group** (`openChatViaSearch` 196–244, `triggerSearchResultOpen` 279–333, `tryActivateSearchResult` 335–361, `trySelectSearchResult` 363–372, `waitForMatchingSearchResults` 500–512, `findMatchingSearchResults` 514–534, `waitForOpenedChatWindow` 536–548, `locateSearchField` 435–486, `discoverSearchFieldCandidates` 488–498, and the cache helpers `prepareCacheIfNeeded`/`resolveCachedElement`/`rememberCachedElement`/`invalidateCachedSlots`): timing-coupled (`runner.waitUntil`, `Thread.sleep`, escape/activate ordering). **Not touched in Phase 4B.**

This task moves ONLY the provably logic-free, side-effect-free scoring/geometry/predicate helpers that take their inputs as parameters and read no `SendCommand` stored properties (no `chatID`/`message`/`recipient`/`noCache`/`refreshCache`/`keepWindow`/flags). Verified pure against the read of lines 246–669 and 906–956:

- `scoreSearchResult(_:)` — lines 257–277 (calls `supportsAction`, see Step 1a)
- `findMatchingChatWindow(in:query:)` — lines 379–384
- `isLikelyMessageInputElement(_:in:)` — lines 601–615
- `isLikelySearchField(_:in:)` — lines 617–645
- `pickSearchField(from:)` — lines 647–656
- `containsText(_:in:)` — lines 658–669
- `pickMessageInputField(from:in:)` — lines 906–913
- `scoreMessageInputCandidate(_:in:)` — lines 915–951
- `isElementLikelyInsideWindow(elementFrame:windowFrame:)` — lines 953–956

> Closure-dependency check: `scoreSearchResult` calls `supportsAction(_:on:)` (374–377), and `scoreMessageInputCandidate` calls `isLikelyMessageInputElement` + `isLikelySearchField`. `isLikelyMessageInputElement` calls `isLikelySearchField`. To keep this a clean self-contained move, `supportsAction(_:on:)` (374–377) — itself pure, reads no stored property — moves into the same extension so the scoring group has no back-reference into `SendCommand`. `pickBestSearchResult` (246–255) is NOT moved (it takes `runner` and logs — keep it in SendCommand; it calls the moved `scoreSearchResult` via `self`, which still resolves since the extension is on `SendCommand`).
>
> `supportsAction` also has callers that stay in SendCommand (`tryActivateSearchResult` 341/351, `locateSearchField` n/a, `tryRaiseWindow` 894). Because the extension is on `SendCommand` (same type, same module), those callers continue to resolve `self.supportsAction(...)` unchanged — moving the method to an extension of the same type does not break any caller. This is why the extract is an **extension of `SendCommand`**, not a new standalone type: zero call-site churn, pure relocation.

- [ ] **Step 1: Create `SendCommand+Scoring.swift` as an extension of `SendCommand`, moving the ten methods VERBATIM.** All bodies copied unchanged; access level stays `private` (extensions in the same file/module on the same type retain `private`-to-type access — keep `private func` exactly as in the original to avoid widening visibility).

```swift
import ApplicationServices.HIServices
import Foundation

// Pure scoring / geometry / predicate helpers for SendCommand.
// No stored-property or timing dependency — moved verbatim from SendCommand.
extension SendCommand {
    func supportsAction(_ action: String, on element: UIElement) -> Bool {
        guard let actions = try? element.actionNames() else { return false }
        return actions.contains(action)
    }

    func findMatchingChatWindow(in windows: [UIElement], query: String) -> UIElement? {
        windows.first { window in
            guard let title = window.title else { return false }
            return title.localizedCaseInsensitiveContains(query)
        }
    }

    func scoreSearchResult(_ element: UIElement) -> Int {
        var score = 0
        if supportsAction("AXPress", on: element) {
            score += 10_000
        }
        if supportsAction("AXConfirm", on: element) {
            score += 8_000
        }
        if element.role == kAXRowRole {
            score += 4_000
        } else if element.role == kAXCellRole {
            score += 3_000
        }
        if let title = element.title, !title.isEmpty {
            score += 500
        }
        if element.role == nil || element.role?.isEmpty == true {
            score -= 2_000
        }
        return score
    }

    func isLikelyMessageInputElement(_ element: UIElement, in window: UIElement? = nil) -> Bool {
        guard element.isEnabled else { return false }
        let role = element.role ?? ""
        if role == kAXTextAreaRole {
            return true
        }

        let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
        guard editable else { return false }
        guard role != kAXStaticTextRole && role != kAXImageRole else { return false }
        if role == kAXTextFieldRole && isLikelySearchField(element, in: window) {
            return false
        }
        return true
    }

    func isLikelySearchField(_ element: UIElement, in window: UIElement?) -> Bool {
        let role = element.role ?? ""
        guard role == kAXTextFieldRole else { return false }

        let joinedText = [
            element.identifier ?? "",
            element.title ?? "",
            element.axDescription ?? "",
        ]
        .joined(separator: " ")
        .lowercased()

        if joinedText.contains("search") || joinedText.contains("검색") {
            return true
        }

        guard let windowFrame = window?.frame, let elementFrame = element.frame, windowFrame.height > 0 else {
            return false
        }

        // If a text field sits outside the target chat window bounds, treat it as non-chat input.
        // This blocks accidental selection of sidebar/global search fields.
        if !isElementLikelyInsideWindow(elementFrame: elementFrame, windowFrame: windowFrame) {
            return true
        }

        let relativeY = (elementFrame.midY - windowFrame.minY) / windowFrame.height
        return relativeY < 0.5
    }

    func pickSearchField(from fields: [UIElement]) -> UIElement? {
        fields
            .filter { $0.isEnabled }
            .sorted { lhs, rhs in
                let lhsY = lhs.position?.y ?? .greatestFiniteMagnitude
                let rhsY = rhs.position?.y ?? .greatestFiniteMagnitude
                return lhsY < rhsY
            }
            .first
    }

    func containsText(_ text: String, in element: UIElement) -> Bool {
        if let title = element.title, title.localizedCaseInsensitiveContains(text) {
            return true
        }
        if let value = element.stringValue, value.localizedCaseInsensitiveContains(text) {
            return true
        }
        let staticTexts = element.findAll(role: kAXStaticTextRole, limit: 5, maxNodes: 48)
        return staticTexts.contains { item in
            (item.stringValue ?? "").localizedCaseInsensitiveContains(text)
        }
    }

    func pickMessageInputField(from fields: [UIElement], in window: UIElement) -> UIElement? {
        fields.sorted { lhs, rhs in
            let lhsScore = scoreMessageInputCandidate(lhs, in: window)
            let rhsScore = scoreMessageInputCandidate(rhs, in: window)
            return lhsScore > rhsScore
        }
        .first
    }

    func scoreMessageInputCandidate(_ element: UIElement, in window: UIElement) -> Double {
        if !isLikelyMessageInputElement(element, in: window) {
            return -Double.greatestFiniteMagnitude
        }

        let role = element.role ?? ""
        let roleScore: Double
        if role == kAXTextAreaRole {
            roleScore = 12_000.0
        } else if role == kAXTextFieldRole {
            roleScore = 9_000.0
        } else {
            let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
            roleScore = editable ? 6_000.0 : 0.0
        }
        let yScore = Double(element.position?.y ?? 0)
        let topPenalty: Double
        if role == kAXTextFieldRole, isLikelySearchField(element, in: window) {
            topPenalty = 8_000.0
        } else {
            topPenalty = 0.0
        }
        let locationScore: Double
        if let windowFrame = window.frame, let elementFrame = element.frame {
            if isElementLikelyInsideWindow(elementFrame: elementFrame, windowFrame: windowFrame) {
                let relativeY = (elementFrame.midY - windowFrame.minY) / max(windowFrame.height, 1.0)
                locationScore = relativeY > 0.55 ? 1_500.0 : 0.0
            } else {
                locationScore = -6_000.0
            }
        } else {
            locationScore = 0.0
        }
        let sizeScore = Double(element.size?.height ?? 0)
        let focusScore = element.isFocused ? 2_000.0 : 0.0
        return roleScore + yScore + sizeScore + focusScore + locationScore - topPenalty
    }

    func isElementLikelyInsideWindow(elementFrame: CGRect, windowFrame: CGRect) -> Bool {
        let expandedWindow = windowFrame.insetBy(dx: -24, dy: -24)
        return expandedWindow.intersects(elementFrame)
    }
}
```

  Visibility note: the originals are `private func`. When moved to an extension in a **separate file**, `private` would hide them from the primary `SendCommand` file. Use `func` (internal) — NOT `private` — for the ten moved methods so callers remaining in `SendCommand.swift` still resolve them. This is the one unavoidable visibility widen (private→internal, same module), required by the file split; it changes no behavior. The code block above already uses `func` (no `private`) for exactly this reason.

- [ ] **Step 2: Delete the ten moved methods from `SendCommand.swift`.** Remove `findMatchingChatWindow(in:query:)` (379–384), `scoreSearchResult(_:)` (257–277), `supportsAction(_:on:)` (374–377), `isLikelyMessageInputElement(_:in:)` (601–615), `isLikelySearchField(_:in:)` (617–645), `pickSearchField(from:)` (647–656), `containsText(_:in:)` (658–669), `pickMessageInputField(from:in:)` (906–913), `scoreMessageInputCandidate(_:in:)` (915–951), `isElementLikelyInsideWindow(elementFrame:windowFrame:)` (953–956). Leave `pickBestSearchResult` (246–255) in place — it stays and still calls `scoreSearchResult` via the extension.

- [ ] **Step 3: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Commands/SendCommand.swift Sources/kmsg/Commands/SendCommand+Scoring.swift` | Confirm the diff is ONLY: (a) verbatim removal of the ten method bodies from `SendCommand.swift`, (b) the same ten bodies appearing verbatim in `SendCommand+Scoring.swift` with `private` → `func` visibility widen and no other token change, (c) no call-site edits anywhere (all callers use `self.`-implicit calls that resolve unchanged). No scoring constant, comparison operator, or geometry value changed.

- [ ] **Step 4: BUILD GATE.** Run: `swift build` | Expected: `Build complete!` (exit 0), no new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 5: GOLDEN (send_dryrun).** The `--dry-run` path (lines 98–110) never touches the moved scoring helpers, so dry-run output is the safe behavior-preservation witness for this code-move (the helpers compile-link into the same binary). Run:
```bash
.build/debug/kmsg send "테헤란로 죽돌이" "golden check" --dry-run > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check.err
```
Expected: empty diff (byte-identical). If the saved `send_dryrun` golden used a different recipient/message, re-run the exact Phase-0 `send_dryrun` command instead and diff against `/tmp/kmsg-golden-baseline/send_dryrun.out`/`.err`.

- [ ] **Step 6: COMMIT.** Run:
```bash
git add Sources/kmsg/Commands/SendCommand+Scoring.swift Sources/kmsg/Commands/SendCommand.swift
git commit -m "refactor(send): extract pure scoring/predicate helpers to SendCommand+Scoring"
```

---

### Task 4B.6: Extract `UIElementSearchUtilities` from KakaoTalkAuthenticator (root-collection + text plumbing)

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/UIElementSearchUtilities.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/KakaoTalkAuthenticator.swift`
- Verify: build + diff (login path is not dry-run-verifiable; `status` golden covers the `isAuthenticated`-adjacent read path)

`appendUnique(_:to:)` (343–347), `appendFocusedElementAncestorChain(from:to:)` (349–357), and `normalizedText(_:)` (783–788) are pure utilities. `appendUnique` already uses `CFEqual($0.axElement, candidate.axElement)` — this task replaces that inline `CFEqual` with the Phase-1 `isSameElement` helper (an identifier-substitution that is in-scope here because it is the canonical helper, and `axElement` is non-optional per CONFIRMED FACTS). `normalizedText` and the two append helpers move into a stateless utility type; the authenticator gets a stored instance.

> Caller inventory (must all rewire): `appendUnique` is called at 306–308, 309 (via chain), 313 (via chain), 316, 321, 324, 343 (recursive—stays internal to the moved method), 345 (its own body), 536–538, 545, 549, and inside `resolveSubmitButton(near:)` 447 and `collectLoginButtons` 477. `appendFocusedElementAncestorChain` is called at 309, 313, 539, 543. `normalizedText` is called at 394, 403, 421–426 (within closure), 455, 514, 569 (within `collectPostLoginAcknowledgementText`)… — see Step 3 for the FULL enumerated list; do not abbreviate.

- [ ] **Step 1: Create `UIElementSearchUtilities.swift` with the three methods, using `isSameElement` in `appendUnique`.** `normalizedText` and `appendFocusedElementAncestorChain` move VERBATIM; `appendUnique`'s only change is `CFEqual($0.axElement, candidate.axElement)` → `$0.isSameElement(candidate)`.

```swift
import ApplicationServices.HIServices
import Foundation

/// Stateless UIElement collection / text-normalization helpers for authentication search.
/// Moved from KakaoTalkAuthenticator; appendUnique now routes through the canonical
/// UIElement.isSameElement helper (Phase 1) instead of inline CFEqual.
struct UIElementSearchUtilities {
    func appendUnique(_ candidate: UIElement?, to roots: inout [UIElement]) {
        guard let candidate else { return }
        guard !roots.contains(where: { $0.isSameElement(candidate) }) else { return }
        roots.append(candidate)
    }

    func appendFocusedElementAncestorChain(from element: UIElement?, to roots: inout [UIElement]) {
        var current = element
        var remaining = 8
        while let candidate = current, remaining > 0 {
            appendUnique(candidate, to: &roots)
            current = candidate.parent
            remaining -= 1
        }
    }

    func normalizedText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
```

- [ ] **Step 2: Add a stored `searchUtilities` instance to `KakaoTalkAuthenticator`.** Anchor on the stored-property block (lines 47–48, `private let kakao` / `private let runner`):
```swift
    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner
    private let searchUtilities = UIElementSearchUtilities()
```

- [ ] **Step 3: Rewire EVERY call site through `searchUtilities`.** Full enumeration (file + enclosing symbol + current line):

  `appendUnique(...)` call sites:
  - `collectLoginSearchRoots()` line 306: `appendUnique(kakao.focusedWindow, to: &roots)` → `searchUtilities.appendUnique(kakao.focusedWindow, to: &roots)`
  - `collectLoginSearchRoots()` line 307: `appendUnique(kakao.mainWindow, to: &roots)` → `searchUtilities.appendUnique(kakao.mainWindow, to: &roots)`
  - `collectLoginSearchRoots()` line 308: `appendUnique(kakao.applicationElement.focusedUIElement, to: &roots)` → `searchUtilities.appendUnique(kakao.applicationElement.focusedUIElement, to: &roots)`
  - `collectLoginSearchRoots()` line 312: `appendUnique(systemWide.focusedUIElement, to: &roots)` → `searchUtilities.appendUnique(systemWide.focusedUIElement, to: &roots)`
  - `collectLoginSearchRoots()` line 317 (inside `for window` loop): `appendUnique(window, to: &roots)` → `searchUtilities.appendUnique(window, to: &roots)`
  - `collectLoginSearchRoots()` line 321 (inside `for window in discoveredWindows`): `appendUnique(window, to: &roots)` → `searchUtilities.appendUnique(window, to: &roots)`
  - `collectLoginSearchRoots()` line 324: `appendUnique(kakao.applicationElement, to: &roots)` → `searchUtilities.appendUnique(kakao.applicationElement, to: &roots)`
  - `resolveSubmitButton(near:)` line 446 (inside nested loop): `appendUnique(button, to: &buttons)` → `searchUtilities.appendUnique(button, to: &buttons)`
  - `collectLoginButtons(primaryRoot:)` line 477: `appendUnique(button, to: &buttons)` → `searchUtilities.appendUnique(button, to: &buttons)`
  - `collectPostLoginAcknowledgementRoots()` line 536: `appendUnique(kakao.focusedWindow, to: &roots)` → `searchUtilities.appendUnique(kakao.focusedWindow, to: &roots)`
  - `collectPostLoginAcknowledgementRoots()` line 537: `appendUnique(kakao.mainWindow, to: &roots)` → `searchUtilities.appendUnique(kakao.mainWindow, to: &roots)`
  - `collectPostLoginAcknowledgementRoots()` line 538: `appendUnique(kakao.applicationElement.focusedUIElement, to: &roots)` → `searchUtilities.appendUnique(kakao.applicationElement.focusedUIElement, to: &roots)`
  - `collectPostLoginAcknowledgementRoots()` line 542: `appendUnique(systemWide.focusedUIElement, to: &roots)` → `searchUtilities.appendUnique(systemWide.focusedUIElement, to: &roots)`
  - `collectPostLoginAcknowledgementRoots()` line 546 (inside `for window`): `appendUnique(window, to: &roots)` → `searchUtilities.appendUnique(window, to: &roots)`
  - `collectPostLoginAcknowledgementRoots()` line 549: `appendUnique(kakao.applicationElement, to: &roots)` → `searchUtilities.appendUnique(kakao.applicationElement, to: &roots)`

  `appendFocusedElementAncestorChain(...)` call sites:
  - `collectLoginSearchRoots()` line 309: → `searchUtilities.appendFocusedElementAncestorChain(from: kakao.applicationElement.focusedUIElement, to: &roots)`
  - `collectLoginSearchRoots()` line 313: → `searchUtilities.appendFocusedElementAncestorChain(from: systemWide.focusedUIElement, to: &roots)`
  - `collectPostLoginAcknowledgementRoots()` line 539: → `searchUtilities.appendFocusedElementAncestorChain(from: kakao.applicationElement.focusedUIElement, to: &roots)`
  - `collectPostLoginAcknowledgementRoots()` line 543: → `searchUtilities.appendFocusedElementAncestorChain(from: systemWide.focusedUIElement, to: &roots)`

  `normalizedText(...)` call sites:
  - `loginWindowScore(_:)` line 394: `if let title = window.title.map(normalizedText),` → `if let title = window.title.map(searchUtilities.normalizedText),`
  - `isLikelyLoginWindow(_:)` line 403: `let title = normalizedText(window.title ?? "")` → `let title = searchUtilities.normalizedText(window.title ?? "")`
  - `isLikelyLoginWindow(_:)` line 422 (inside `.map` closure on buttons): `normalizedText([` → `searchUtilities.normalizedText([`
  - `resolveQRCodeResetButton(in:)` line 455: `let text = normalizedText([` → `let text = searchUtilities.normalizedText([`
  - `collectLoginMarkerText(from:)` line 514: `return normalizedText(tokens.map {` → `return searchUtilities.normalizedText(tokens.map {`
  - `collectPostLoginAcknowledgementText(from:)` line 578: `return normalizedText(tokens.map {` → `return searchUtilities.normalizedText(tokens.map {`
  - `looksLikePasswordField(_:)` line 637: `let metadata = normalizedText([` → `let metadata = searchUtilities.normalizedText([`
  - `buttonTextCandidates(_:)` line 751: `.map(normalizedText)` → `.map(searchUtilities.normalizedText)`

  (Total: 15 `appendUnique`, 4 `appendFocusedElementAncestorChain`, 8 `normalizedText`. No other occurrences exist — the recursive `appendUnique` inside `appendFocusedElementAncestorChain` and the self-call inside `appendUnique` are now internal to the moved methods and do NOT get the prefix.)

- [ ] **Step 4: Delete the three moved methods from `KakaoTalkAuthenticator`.** Remove `appendUnique(_:to:)` (343–347), `appendFocusedElementAncestorChain(from:to:)` (349–357), `normalizedText(_:)` (783–788). Confirm no remaining bare `appendUnique(`/`appendFocusedElementAncestorChain(`/`normalizedText(` references in `KakaoTalkAuthenticator` (all now `searchUtilities.`-prefixed).

- [ ] **Step 5: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Auth/KakaoTalkAuthenticator.swift Sources/kmsg/Auth/UIElementSearchUtilities.swift` | Confirm ONLY: (a) verbatim relocation of `normalizedText` + `appendFocusedElementAncestorChain`, (b) `appendUnique` relocated with the single `CFEqual(...)`→`isSameElement(...)` identifier substitution (semantically identical per CONFIRMED FACTS: `axElement` non-optional, `isSameElement` wraps the same `CFEqual`), (c) `searchUtilities.` prefix on the 27 enumerated call sites, (d) added `searchUtilities` property. No traversal-limit, `maxNodes`, folding-option, or remaining-count change.

- [ ] **Step 6: BUILD GATE.** Run: `swift build` | Expected: `Build complete!` (exit 0), no new warning vs baseline.

- [ ] **Step 7: GOLDEN (status).** Login itself cannot be dry-run-verified, so rely on build + diff-discipline (Step 5) plus the `status` golden, which exercises the authenticator's `isAuthenticated`/window-read path without performing a login. Run:
```bash
.build/debug/kmsg status --verbose > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/status.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check.err
```
Expected: empty diff. (If the saved `status` golden was captured WITHOUT `--verbose`, re-run the exact Phase-0 `status` command form instead and diff against `/tmp/kmsg-golden-baseline/status.out`/`.err`.)

- [ ] **Step 8: COMMIT.** Run:
```bash
git add Sources/kmsg/Auth/UIElementSearchUtilities.swift Sources/kmsg/Auth/KakaoTalkAuthenticator.swift
git commit -m "refactor(auth): extract UIElementSearchUtilities for root collection"
```

---

### Task 4B.7: Extract `ButtonScoringAndResolution` from KakaoTalkAuthenticator (pure scoring + text predicates)

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/AuthButtonScoring.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/KakaoTalkAuthenticator.swift`
- Verify: build + diff (+ `status` golden)

The button scoring/text-predicate group is pure: `scoreButton(_:relativeTo:)` (691–720), `scoreAcknowledgementButton(_:)` (722–738), `buttonTextCandidates(_:)` (740–754), `isExactLoginButtonLabel(_:)` (756–764), `containsAccountLoginMarker(_:)` (766–773), `containsQRCodeMarker(_:)` (775–781). These read no `kakao`/`runner` state; `buttonTextCandidates` calls `normalizedText` (now `searchUtilities.normalizedText` after 4B.6). To keep this group self-contained, the new type holds its OWN `UIElementSearchUtilities` for the `normalizedText` call.

> Dependency check after 4B.6: `buttonTextCandidates` (740) calls `normalizedText` → becomes `searchUtilities.normalizedText` in 4B.6. When this group moves to a new type in 4B.7, `buttonTextCandidates` needs `normalizedText` access. Inject a `UIElementSearchUtilities` into the new scorer type (cheap, stateless) rather than back-referencing the authenticator. `scoreButton` calls `buttonTextCandidates`, `isExactLoginButtonLabel`, `containsAccountLoginMarker`, `containsQRCodeMarker` — all in this same group, so they resolve internally. `containsAccountLoginMarker` calls `containsQRCodeMarker` — also internal.

- [ ] **Step 1: Create `AuthButtonScoring.swift` with the six methods moved VERBATIM, holding an injected `UIElementSearchUtilities`.** The only edit to any body is inside `buttonTextCandidates`, where the `.map(normalizedText)` becomes `.map(searchUtilities.normalizedText)` (matching the 4B.6 rewrite — this keeps the call resolving to the same canonical helper).

```swift
import ApplicationServices.HIServices
import Foundation

/// Pure login/acknowledgement button scoring and text predicates.
/// No kakao/runner state. Moved verbatim from KakaoTalkAuthenticator.
struct AuthButtonScoring {
    private let searchUtilities: UIElementSearchUtilities

    init(searchUtilities: UIElementSearchUtilities) {
        self.searchUtilities = searchUtilities
    }

    func scoreButton(_ button: UIElement, relativeTo referenceFrame: CGRect? = nil) -> Int {
        let texts = buttonTextCandidates(button)
        var score = 0
        if texts.contains(where: isExactLoginButtonLabel) {
            score += 220
        }
        if texts.contains(where: containsAccountLoginMarker) {
            score += 120
        }
        if texts.contains(where: containsQRCodeMarker) {
            score -= 260
        }
        if button.isEnabled {
            score += 20
        }
        if let referenceFrame, let buttonFrame = button.frame {
            let deltaY = buttonFrame.midY - referenceFrame.midY
            if deltaY >= -12 && deltaY <= 180 {
                score += 30
            } else if deltaY < -12 {
                score -= 20
            }

            let deltaX = abs(buttonFrame.midX - referenceFrame.midX)
            if deltaX <= max(referenceFrame.width, buttonFrame.width) {
                score += 20
            }
        }
        return score
    }

    func scoreAcknowledgementButton(_ button: UIElement) -> Int {
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

    func buttonTextCandidates(_ button: UIElement) -> [String] {
        Array(
            Set(
                [
                    button.title,
                    button.axDescription,
                    button.identifier,
                    button.stringValue,
                ]
                .compactMap { $0 }
                .map(searchUtilities.normalizedText)
                .filter { !$0.isEmpty }
            )
        )
    }

    func isExactLoginButtonLabel(_ text: String) -> Bool {
        [
            "login",
            "log in",
            "signin",
            "sign in",
            "로그인",
        ].contains(text)
    }

    func containsAccountLoginMarker(_ text: String) -> Bool {
        guard !containsQRCodeMarker(text) else { return false }
        return text.contains("로그인") ||
            text.contains("login") ||
            text.contains("log in") ||
            text.contains("signin") ||
            text.contains("sign in")
    }

    func containsQRCodeMarker(_ text: String) -> Bool {
        text.contains("qr") ||
            text.contains("qrcode") ||
            text.contains("qr code") ||
            text.contains("큐알") ||
            text.contains("qr코드")
    }
}
```

- [ ] **Step 2: Add a stored `buttonScoring` instance to `KakaoTalkAuthenticator`, wired to the same `searchUtilities`.** Anchor on the property block extended in 4B.6 (`private let searchUtilities = UIElementSearchUtilities()`):
```swift
    private let searchUtilities = UIElementSearchUtilities()
    private let buttonScoring = AuthButtonScoring(searchUtilities: searchUtilities)
```
  Note: referencing `searchUtilities` in a property initializer of the same type is legal here because `UIElementSearchUtilities()` is a stateless value; if the Swift initializer-ordering rule rejects the cross-property reference, fall back to `private let buttonScoring = AuthButtonScoring(searchUtilities: UIElementSearchUtilities())` — behaviorally identical (the utility is stateless, so a second instance is indistinguishable). Prefer the shared form; use the inline-construction form only if the build fails on property-init ordering.

- [ ] **Step 3: Rewire EVERY call site through `buttonScoring`.** Full enumeration:

  `scoreButton(...)`:
  - `bestScoredLoginButton(from:near:)` line 487: `(button: button, score: scoreButton(button, relativeTo: referenceFrame))` → `(button: button, score: buttonScoring.scoreButton(button, relativeTo: referenceFrame))`

  `scoreAcknowledgementButton(...)`:
  - `resolvePostLoginAcknowledgement(in:)` line 560: `guard let button = buttons.max(by: { scoreAcknowledgementButton($0) < scoreAcknowledgementButton($1) }),` → `guard let button = buttons.max(by: { buttonScoring.scoreAcknowledgementButton($0) < buttonScoring.scoreAcknowledgementButton($1) }),`
  - `resolvePostLoginAcknowledgement(in:)` line 561: `scoreAcknowledgementButton(button) > 0` → `buttonScoring.scoreAcknowledgementButton(button) > 0`

  `buttonTextCandidates(...)`:
  - `bestScoredLoginButton(from:near:)` line 491: `let metadata = buttonTextCandidates(candidate.button).joined(separator: " | ")` → `let metadata = buttonScoring.buttonTextCandidates(candidate.button).joined(separator: " | ")`

  (Note: `scoreButton` internally calls `buttonTextCandidates`/`isExactLoginButtonLabel`/`containsAccountLoginMarker`/`containsQRCodeMarker`, and `containsAccountLoginMarker` calls `containsQRCodeMarker`; all are now intra-type calls inside `AuthButtonScoring` and require NO prefix. The only external callers in `KakaoTalkAuthenticator` are the 4 sites above.)

- [ ] **Step 4: Delete the six moved methods from `KakaoTalkAuthenticator`.** Remove `scoreButton(_:relativeTo:)` (691–720), `scoreAcknowledgementButton(_:)` (722–738), `buttonTextCandidates(_:)` (740–754), `isExactLoginButtonLabel(_:)` (756–764), `containsAccountLoginMarker(_:)` (766–773), `containsQRCodeMarker(_:)` (775–781). Confirm no remaining bare references to any of the six in `KakaoTalkAuthenticator`.

- [ ] **Step 5: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Auth/KakaoTalkAuthenticator.swift Sources/kmsg/Auth/AuthButtonScoring.swift` | Confirm ONLY: verbatim relocation of six methods (with the single `.map(normalizedText)` → `.map(searchUtilities.normalizedText)` inside `buttonTextCandidates`, matching the 4B.6 helper routing), the new injected `init`, added `buttonScoring` property, and `buttonScoring.` prefix on the 4 enumerated call sites. No scoring constant (220/120/260/20/30/180/-12/140/100), marker-string, or operator change.

- [ ] **Step 6: BUILD GATE.** Run: `swift build` | Expected: `Build complete!` (exit 0), no new warning vs baseline.

- [ ] **Step 7: GOLDEN (status).** Login is not dry-run-verifiable; rely on build + diff-discipline plus `status`. Run:
```bash
.build/debug/kmsg status --verbose > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/status.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check.err
```
Expected: empty diff.

- [ ] **Step 8: COMMIT.** Run:
```bash
git add Sources/kmsg/Auth/AuthButtonScoring.swift Sources/kmsg/Auth/KakaoTalkAuthenticator.swift
git commit -m "refactor(auth): extract AuthButtonScoring for login button scoring"
```

---

### Task 4B.8: Extract `LoginFormResolver` from KakaoTalkAuthenticator (form discovery + window classification)

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/LoginFormResolver.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/KakaoTalkAuthenticator.swift`
- Verify: build + diff (+ `status` golden)

This task moves the **logic-free** members of the login-form-resolution group: the input/window classification predicates that read no `kakao`/`runner` state. It does **NOT** move `findLoginForm()` (263–302, contains `Thread.sleep`, `KakaoTalkApp.forceOpen`, deadline loop — timing-coupled) nor `collectLoginSearchRoots()` (304–341, reads `kakao`/`runner`, logs) nor `collectLoginButtons` (464–482, reads `kakao`) nor `resolveSubmitButton`/`resolveQRCodeResetButton`/`bestScoredLoginButton` (read `kakao`/`runner`). It moves the pure classifiers:

- `buildLoginForm(from:)` — 359–387 (pure: reads only the passed `window`, sorts, constructs `LoginForm`; calls `looksLikePasswordField`)
- `loginWindowScore(_:)` — 389–400 (pure: reads passed `window`; calls `isLikelyLoginWindow`, `searchUtilities.normalizedText`)
- `isLikelyLoginWindow(_:)` — 402–436 (pure: reads passed `window`; calls `searchUtilities.normalizedText`, `collectLoginMarkerText`, `containsLoginMarkers`, `looksLikePasswordField`)
- `collectLoginMarkerText(from:)` — 505–522 (pure: reads passed `root`; calls `searchUtilities.normalizedText`)
- `containsLoginMarkers(_:)` — 588–600 (pure string predicate)
- `looksLikePasswordField(_:)` — 631–651 (pure: reads passed `element`; calls `searchUtilities.normalizedText`)

> Cross-type access: `LoginForm` is `private struct` in `KakaoTalkAuthenticator.swift` (34–38). `buildLoginForm` constructs and returns `LoginForm`, and `KakaoTalkAuthenticator.findLoginForm()`/`performLogin` consume it. Moving `buildLoginForm` to a separate type requires `LoginForm` to be visible to that type. Step 2 widens `LoginForm` from `private struct` to internal `struct`. The resolver also uses `searchUtilities.normalizedText`, so it holds an injected `UIElementSearchUtilities` (same pattern as 4B.7).

- [ ] **Step 1: Create `LoginFormResolver.swift` with the six methods moved VERBATIM, holding an injected `UIElementSearchUtilities`.** The only body edit is `normalizedText` → `searchUtilities.normalizedText` (3 occurrences inside `loginWindowScore`/`isLikelyLoginWindow`/`collectLoginMarkerText`/`looksLikePasswordField`, matching 4B.6 routing). Predicate `AXSecureTextField` string literals stay as-is (the authenticator keeps its OWN superset predicate per CONFIRMED FACTS — do NOT introduce `kAXSecureTextFieldRole` constant or `isTextInputRole` here; this is a verbatim move).

```swift
import ApplicationServices.HIServices
import Foundation

/// Pure login-form discovery and window classification.
/// Reads only the UIElements passed in — no kakao/runner state.
/// Moved verbatim from KakaoTalkAuthenticator.
struct LoginFormResolver {
    private let searchUtilities: UIElementSearchUtilities

    init(searchUtilities: UIElementSearchUtilities) {
        self.searchUtilities = searchUtilities
    }

    func buildLoginForm(from window: UIElement) -> LoginForm? {
        let inputFields = window.findAll(where: { element in
            let role = element.role ?? ""
            return element.isEnabled && (role == kAXTextFieldRole || role == kAXTextAreaRole || role == "AXSecureTextField")
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

    func loginWindowScore(_ window: UIElement) -> Int {
        var score = 0
        if isLikelyLoginWindow(window) {
            score += 100
        }
        if let title = window.title.map(searchUtilities.normalizedText),
           title.contains("login") || title.contains("log in") || title.contains("로그인")
        {
            score += 40
        }
        return score
    }

    func isLikelyLoginWindow(_ window: UIElement) -> Bool {
        let title = searchUtilities.normalizedText(window.title ?? "")
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
            searchUtilities.normalizedText([
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

    func collectLoginMarkerText(from root: UIElement) -> String {
        let roles: Set<String> = [kAXButtonRole, kAXStaticTextRole, kAXCheckBoxRole]
        let found = root.findAll(roles: roles, roleLimits: [
            kAXButtonRole: 12,
            kAXStaticTextRole: 12,
            kAXCheckBoxRole: 6,
        ], maxNodes: 260)

        let tokens = (found[kAXButtonRole] ?? []) + (found[kAXStaticTextRole] ?? []) + (found[kAXCheckBoxRole] ?? [])
        return searchUtilities.normalizedText(tokens.map {
            [
                $0.title,
                $0.axDescription,
                $0.stringValue,
                $0.identifier,
            ].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: " "))
    }

    func containsLoginMarkers(_ text: String) -> Bool {
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

    func looksLikePasswordField(_ element: UIElement) -> Bool {
        let role = element.role ?? ""
        if role == "AXSecureTextField" {
            return true
        }

        let metadata = searchUtilities.normalizedText([
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
}
```

- [ ] **Step 2: Widen `LoginForm` visibility from `private` to internal.** In `KakaoTalkAuthenticator.swift`, line 34:
```swift
struct LoginForm {
```
  (Delete the `private` keyword only. `PostLoginAcknowledgement` at line 40 is NOT touched in this task — it stays `private` since 4B is not extracting the acknowledgement resolver in this pass; see deferral note below.) No other tokens on line 34 change.

- [ ] **Step 3: Add a stored `loginFormResolver` instance to `KakaoTalkAuthenticator`, wired to the shared `searchUtilities`.** Anchor on the property block (after `private let buttonScoring = ...` from 4B.7):
```swift
    private let buttonScoring = AuthButtonScoring(searchUtilities: searchUtilities)
    private let loginFormResolver = LoginFormResolver(searchUtilities: searchUtilities)
```
  (Same property-init-ordering caveat as 4B.7 Step 2: if the build rejects the cross-property reference, use `LoginFormResolver(searchUtilities: UIElementSearchUtilities())` — behaviorally identical.)

- [ ] **Step 4: Rewire EVERY call site through `loginFormResolver`.** Full enumeration of EXTERNAL callers (intra-group calls like `isLikelyLoginWindow`→`collectLoginMarkerText` are now internal to the resolver and need no prefix):

  `buildLoginForm(from:)`:
  - `findLoginForm()` line 274: `if let form = buildLoginForm(from: root) {` → `if let form = loginFormResolver.buildLoginForm(from: root) {`

  `isLikelyLoginWindow(_:)`:
  - `isAuthenticated()` line 226: `if let chatListWindow = kakao.chatListWindow, !isLikelyLoginWindow(chatListWindow) {` → `if let chatListWindow = kakao.chatListWindow, !loginFormResolver.isLikelyLoginWindow(chatListWindow) {`
  - `isAuthenticated()` line 235: `let loginLike = isLikelyLoginWindow(usableWindow)` → `let loginLike = loginFormResolver.isLikelyLoginWindow(usableWindow)`

  `loginWindowScore(_:)`:
  - `collectLoginSearchRoots()` line 326: `let lhsScore = loginWindowScore(lhs)` → `let lhsScore = loginFormResolver.loginWindowScore(lhs)`
  - `collectLoginSearchRoots()` line 327: `let rhsScore = loginWindowScore(rhs)` → `let rhsScore = loginFormResolver.loginWindowScore(rhs)`
  - `collectLoginSearchRoots()` line 337 (inside the per-root log interpolation): `score=\(loginWindowScore(root))` → `score=\(loginFormResolver.loginWindowScore(root))`

  `looksLikePasswordField(_:)`:
  - No remaining external caller in `KakaoTalkAuthenticator` after the group moves — it is called only by `buildLoginForm` and `isLikelyLoginWindow`, both of which moved into `LoginFormResolver`. Confirm zero bare `looksLikePasswordField(` references remain in `KakaoTalkAuthenticator.swift` after deletion.

  `collectLoginMarkerText(from:)` / `containsLoginMarkers(_:)`:
  - No external caller in `KakaoTalkAuthenticator` — both are called only by `isLikelyLoginWindow` (moved). Confirm zero bare references remain.

- [ ] **Step 5: Delete the six moved methods from `KakaoTalkAuthenticator`.** Remove `buildLoginForm(from:)` (359–387), `loginWindowScore(_:)` (389–400), `isLikelyLoginWindow(_:)` (402–436), `collectLoginMarkerText(from:)` (505–522), `containsLoginMarkers(_:)` (588–600), `looksLikePasswordField(_:)` (631–651). Confirm no remaining bare references to any of the six in `KakaoTalkAuthenticator`.

- [ ] **Step 6: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Auth/KakaoTalkAuthenticator.swift Sources/kmsg/Auth/LoginFormResolver.swift` | Confirm ONLY: verbatim relocation of six methods (with `normalizedText` → `searchUtilities.normalizedText` routing matching 4B.6), `LoginForm` `private`-keyword deletion, the new injected `init`, added `loginFormResolver` property, and `loginFormResolver.` prefix on the 6 enumerated call sites. The `"AXSecureTextField"` string literal, the `CFEqual(candidate.axElement, usernameField.axElement)` inside `buildLoginForm` (left as-is — this is the authenticator's own superset predicate path, not routed through `isSameElement` to keep the move verbatim), all `findAll` limits/`maxNodes`, marker lists, and `>= 2` thresholds are unchanged.

  > Note on `CFEqual` inside `buildLoginForm` (line 381): unlike `appendUnique` (4B.6), this `CFEqual` is left VERBATIM rather than swapped to `isSameElement`. Rationale: 4B is a pure code-move and `isSameElement` substitution was only mandated for the canonical `appendUnique` site; substituting here would be an extra identifier change beyond the move. Keep it byte-identical.

- [ ] **Step 7: BUILD GATE.** Run: `swift build` | Expected: `Build complete!` (exit 0), no new warning vs baseline.

- [ ] **Step 8: GOLDEN (status).** `isAuthenticated()` (which calls `isLikelyLoginWindow`, now `loginFormResolver.isLikelyLoginWindow`) is exercised by `status`. Login itself is not dry-run-verifiable; rely on build + diff + `status`. Run:
```bash
.build/debug/kmsg status --verbose > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/status.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check.err
```
Expected: empty diff.

- [ ] **Step 9: COMMIT.** Run:
```bash
git add Sources/kmsg/Auth/LoginFormResolver.swift Sources/kmsg/Auth/KakaoTalkAuthenticator.swift
git commit -m "refactor(auth): extract LoginFormResolver for form/window classification"
```

---

### Task 4B.9: Extract `PostLoginAcknowledgementHandler` from KakaoTalkAuthenticator (pure detection)

**Files:**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/PostLoginAcknowledgementHandler.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/KakaoTalkAuthenticator.swift`
- Verify: build + diff (+ `status` golden)

This task moves ONLY the **pure detection** members of the acknowledgement group. The two members that read `kakao`/`runner` or perform side effects stay in the authenticator:
- **STAYS — `dismissPostLoginAcknowledgementIfPresent()`** (245–261): calls `runner.clickWithRetry`, `runner.log`, `Thread.sleep` — side-effecting/timing-coupled.
- **STAYS — `resolvePostLoginAcknowledgement()`** (524–532): iterates `collectPostLoginAcknowledgementRoots()` which reads `kakao`. Keep; it delegates to the moved per-root resolver.
- **STAYS — `collectPostLoginAcknowledgementRoots()`** (534–551): reads `kakao` (already rewired through `searchUtilities` in 4B.6).

Moved (pure, parameterized on a passed root):
- `resolvePostLoginAcknowledgement(in:)` — 553–567 (reads passed `root`; calls `collectPostLoginAcknowledgementText`, `containsPostLoginAcknowledgementMarkers`, `buttonScoring.scoreAcknowledgementButton`, constructs `PostLoginAcknowledgement`)
- `collectPostLoginAcknowledgementText(from:)` — 569–586 (reads passed `root`; calls `searchUtilities.normalizedText`)
- `containsPostLoginAcknowledgementMarkers(_:)` — 602–629 (pure string predicate)

> Cross-type access: `PostLoginAcknowledgement` is `private struct` (40–44). `resolvePostLoginAcknowledgement(in:)` constructs it and the authenticator's surviving `resolvePostLoginAcknowledgement()` returns it. Step 2 widens it to internal. The new type needs `searchUtilities` (for `normalizedText`) and `buttonScoring` (for `scoreAcknowledgementButton`) — inject both.

- [ ] **Step 1: Create `PostLoginAcknowledgementHandler.swift` with the three methods moved VERBATIM, holding injected `UIElementSearchUtilities` + `AuthButtonScoring`.** Body edits: `normalizedText` → `searchUtilities.normalizedText` (1 site in `collectPostLoginAcknowledgementText`) and `scoreAcknowledgementButton` → `buttonScoring.scoreAcknowledgementButton` (2 sites in `resolvePostLoginAcknowledgement(in:)`), matching the routing established in 4B.6/4B.7.

```swift
import ApplicationServices.HIServices
import Foundation

/// Pure detection of the post-login "already logged in" acknowledgement dialog
/// within a single passed-in root. No kakao/runner state.
/// Moved verbatim from KakaoTalkAuthenticator.
struct PostLoginAcknowledgementHandler {
    private let searchUtilities: UIElementSearchUtilities
    private let buttonScoring: AuthButtonScoring

    init(searchUtilities: UIElementSearchUtilities, buttonScoring: AuthButtonScoring) {
        self.searchUtilities = searchUtilities
        self.buttonScoring = buttonScoring
    }

    func resolvePostLoginAcknowledgement(in root: UIElement) -> PostLoginAcknowledgement? {
        let message = collectPostLoginAcknowledgementText(from: root)
        guard containsPostLoginAcknowledgementMarkers(message) else {
            return nil
        }

        let buttons = root.findAll(role: kAXButtonRole, limit: 8, maxNodes: 220)
        guard let button = buttons.max(by: { buttonScoring.scoreAcknowledgementButton($0) < buttonScoring.scoreAcknowledgementButton($1) }),
              buttonScoring.scoreAcknowledgementButton(button) > 0
        else {
            return nil
        }

        return PostLoginAcknowledgement(root: root, button: button, message: message)
    }

    func collectPostLoginAcknowledgementText(from root: UIElement) -> String {
        let roles: Set<String> = [kAXButtonRole, kAXStaticTextRole, kAXGroupRole]
        let found = root.findAll(roles: roles, roleLimits: [
            kAXButtonRole: 8,
            kAXStaticTextRole: 16,
            kAXGroupRole: 6,
        ], maxNodes: 260)

        let tokens = (found[kAXStaticTextRole] ?? []) + (found[kAXButtonRole] ?? []) + (found[kAXGroupRole] ?? [])
        return searchUtilities.normalizedText(tokens.map {
            [
                $0.title,
                $0.axDescription,
                $0.stringValue,
                $0.identifier,
            ].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: " "))
    }

    func containsPostLoginAcknowledgementMarkers(_ text: String) -> Bool {
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
}
```

- [ ] **Step 2: Widen `PostLoginAcknowledgement` visibility from `private` to internal.** In `KakaoTalkAuthenticator.swift`, line 40:
```swift
struct PostLoginAcknowledgement {
```
  (Delete the `private` keyword only; no other tokens on line 40 change.)

- [ ] **Step 3: Add a stored `acknowledgementHandler` instance to `KakaoTalkAuthenticator`, wired to the shared collaborators.** Anchor on the property block (after `private let loginFormResolver = ...` from 4B.8):
```swift
    private let loginFormResolver = LoginFormResolver(searchUtilities: searchUtilities)
    private let acknowledgementHandler = PostLoginAcknowledgementHandler(
        searchUtilities: searchUtilities,
        buttonScoring: buttonScoring
    )
```
  (Same property-init-ordering caveat: if the build rejects cross-property references in the initializer, construct fresh stateless collaborators inline — `PostLoginAcknowledgementHandler(searchUtilities: UIElementSearchUtilities(), buttonScoring: AuthButtonScoring(searchUtilities: UIElementSearchUtilities()))` — behaviorally identical. Prefer the shared form.)

- [ ] **Step 4: Rewire the single external call site through `acknowledgementHandler`.** In `KakaoTalkAuthenticator.swift`, the surviving `resolvePostLoginAcknowledgement()` (524–532), line 526:
```swift
    private func resolvePostLoginAcknowledgement() -> PostLoginAcknowledgement? {
        for root in collectPostLoginAcknowledgementRoots() {
            guard let acknowledgement = acknowledgementHandler.resolvePostLoginAcknowledgement(in: root) else {
                continue
            }
            return acknowledgement
        }
        return nil
    }
```
  (The intra-group calls `collectPostLoginAcknowledgementText`→`searchUtilities.normalizedText` and `resolvePostLoginAcknowledgement(in:)`→`containsPostLoginAcknowledgementMarkers` are now internal to the handler and need no prefix.)

- [ ] **Step 5: Delete the three moved methods from `KakaoTalkAuthenticator`.** Remove `resolvePostLoginAcknowledgement(in:)` (553–567), `collectPostLoginAcknowledgementText(from:)` (569–586), `containsPostLoginAcknowledgementMarkers(_:)` (602–629). Keep `resolvePostLoginAcknowledgement()` (no-arg, 524–532), `dismissPostLoginAcknowledgementIfPresent()` (245–261), and `collectPostLoginAcknowledgementRoots()` (534–551). Confirm no remaining bare `collectPostLoginAcknowledgementText(`/`containsPostLoginAcknowledgementMarkers(` references, and that the only remaining `resolvePostLoginAcknowledgement(in:` reference is the rewired `acknowledgementHandler.`-prefixed one.

- [ ] **Step 6: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Auth/KakaoTalkAuthenticator.swift Sources/kmsg/Auth/PostLoginAcknowledgementHandler.swift` | Confirm ONLY: verbatim relocation of three methods (with `normalizedText`/`scoreAcknowledgementButton` routed through the injected collaborators), `PostLoginAcknowledgement` `private`-keyword deletion, the new injected `init`, added `acknowledgementHandler` property, and the single `acknowledgementHandler.`-prefixed call site. No marker-string-list, `findAll` limit/`maxNodes`, or boolean-combinator (`&&`/`||`) change.

- [ ] **Step 7: BUILD GATE.** Run: `swift build` | Expected: `Build complete!` (exit 0), no new warning vs baseline.

- [ ] **Step 8: GOLDEN (status).** `isAuthenticated()` → `dismissPostLoginAcknowledgementIfPresent()` → `resolvePostLoginAcknowledgement()` → `acknowledgementHandler.resolvePostLoginAcknowledgement(in:)` is on the `status` read path. Login is not dry-run-verifiable; rely on build + diff + `status`. Run:
```bash
.build/debug/kmsg status --verbose > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/status.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/status.err /tmp/check.err
```
Expected: empty diff.

- [ ] **Step 9: COMMIT.** Run:
```bash
git add Sources/kmsg/Auth/PostLoginAcknowledgementHandler.swift Sources/kmsg/Auth/KakaoTalkAuthenticator.swift
git commit -m "refactor(auth): extract PostLoginAcknowledgementHandler detection"
```

---

### Deferred extracts (explicitly NOT performed in Phase 4B, with reasons)

- **SendCommand — MessageInputResolution group** (`resolveMessageInputField`, `collectMessageInputCandidates`, `collectFocusedElementLineageCandidates`, `sendMessageToWindow`, `forceTypeIntoChatWindow`, `tryRaiseWindow`, `deduplicateCandidates`/`areSameAXElement`): **DEFERRED** — timing-coupled (`Thread.sleep`, focus/activate/raise ordering, retry loops, cache-slot read/write side effects) and observable only via live send. Behavior preservation cannot be witnessed by `send_dryrun`.
- **SendCommand — SearchOperations group** (`openChatViaSearch`, `triggerSearchResultOpen`, `tryActivateSearchResult`, `trySelectSearchResult`, `waitForMatchingSearchResults`, `findMatchingSearchResults`, `waitForOpenedChatWindow`, `resolveOpenedChatWindow(Fast)`, `locateSearchField`, `discoverSearchFieldCandidates`, and cache helpers `prepareCacheIfNeeded`/`resolveCachedElement`/`rememberCachedElement`/`invalidateCachedSlots`/`closeWindowsIfNeeded`): **DEFERRED** — timing-dense (`runner.waitUntil`, `Thread.sleep`, escape/activate sequencing) and side-effecting; live-send-only verification.
- **KakaoTalkAuthenticator — BlindLoginSequence** (`performBlindLogin`, `pressBlindSubmitSequence`, `BlindSubmitStep`, plus the live-submit helpers `performLogin`, `clickPreferredLoginButton`, `resolveSubmitButton(in:near:)`/`resolveSubmitButton(near:)`, `bestScoredLoginButton`, `collectLoginButtons`, `resolveQRCodeResetButton`, `findLoginForm`, `collectLoginSearchRoots`, `clearFieldBestEffort`, `setTextWithoutReflection`, `typeTextWithoutReflection`, `dismissPostLoginAcknowledgementIfPresent`): **DEFERRED** — timing-dense keyboard-traversal/`Thread.sleep`/`runner.waitUntil` sequences and live-AX side effects; login cannot be dry-run-verified, so these must not be relocated without a live-login harness.

---

## Phase 5 — Dedup family + metadata/regex tokenizer consolidation

**Goal:** Collapse the duplicated AX-identity dedup scans, String-keyed order-preserving dedup, and the metadata/regex tokenizer logic into shared helpers without altering any observable output (CRLF normalization, empty-filtering, and dedup ordering preserved exactly).

**Aggregate risk:** low

---

### Task 5.1: Add `[UIElement].deduplicatedByAXIdentity()` and route the 4 linear-scan sites through it

**Files**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Support/UIElement+Dedup.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/MessageContextResolver.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatListScanner.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift`
- Verify: golden `read`, `chats`, `chats_json`, `send_dryrun`

> NOTE — SCOPE DECISION: the prompt lists "5 sites" including `TranscriptReader.deduplicateElements`. But that function (TranscriptReader.swift:965-983) is a **CFHash-bucketed** variant, NOT the `result.contains(where:)` linear O(n²) scan that the other 4 use. Replacing it with the linear helper would silently change its internal algorithm (O(n) bucketed → O(n²) linear). The dedup *result* (first-seen order, CFEqual identity) is provably identical, but to stay strictly behavior-preserving AND honor "KEEP O(n²)/CFEqual — never Set/Hashable", this Task migrates ONLY the 4 already-linear sites. TranscriptReader's bucketed dedup is handled separately in **Task 5.2** (kept as-is; not forced onto the linear helper). The linear helper below is byte-identical to those 4 sites.

- [ ] **Step 1: Create the shared linear-scan dedup helper (exact O(n²) `contains(where:)` + `isSameElement`).**
  The body is the exact linear scan currently in `MessageContextResolver.deduplicateElements` / `ChatWindowResolver.deduplicateElements` / `SendCommand.deduplicateCandidates` (`reserveCapacity` + `contains(where:)`), with the CFEqual comparison expressed via the Phase-1 `isSameElement` helper.

  ```swift
  import ApplicationServices.HIServices

  extension Array where Element == UIElement {
      /// O(n^2) first-seen dedup by AX identity (CFEqual). Never uses Set/Hashable.
      func deduplicatedByAXIdentity() -> [UIElement] {
          var unique: [UIElement] = []
          unique.reserveCapacity(count)
          for candidate in self {
              if unique.contains(where: { $0.isSameElement(candidate) }) {
                  continue
              }
              unique.append(candidate)
          }
          return unique
      }
  }
  ```

- [ ] **Step 2: `MessageContextResolver` — replace the body of `deduplicateElements(_:)` (MessageContextResolver.swift:463-473) with a delegation to the helper.**
  Anchor: the `private func deduplicateElements(_ candidates: [UIElement]) -> [UIElement]` whose loop uses `areSameAXElement($0, candidate)`. The 3 call sites (lines 92, 105, 134) keep calling `deduplicateElements(...)` unchanged.

  ```swift
  private func deduplicateElements(_ candidates: [UIElement]) -> [UIElement] {
      candidates.deduplicatedByAXIdentity()
  }
  ```

- [ ] **Step 3: `ChatListScanner` — replace the body of `deduplicateElements(_:)` (ChatListScanner.swift:282-296) with a delegation to the helper.**
  Anchor: the `private func deduplicateElements(_ elements: [UIElement]) -> [UIElement]` whose loop uses the inline `CFEqual(existing.axElement, element.axElement)`. Call sites (lines 157, 162, 166) unchanged.

  ```swift
  private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
      elements.deduplicatedByAXIdentity()
  }
  ```

- [ ] **Step 4: `ChatWindowResolver` — replace the body of `deduplicateElements(_:)` (ChatWindowResolver.swift:868-881) with a delegation to the helper.**
  Anchor: the `private func deduplicateElements(_ elements: [UIElement]) -> [UIElement]` whose loop uses `areSameAXElement(existing, element)`. Leave `areSameAXElement` (974-976), `deduplicateSearchCandidates` (849-866, `SearchCandidate`-keyed — out of scope), and `deduplicateStringsPreservingOrder` (883-897, handled in Task 5.2) untouched. Call sites (lines 392, 406) unchanged.

  ```swift
  private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
      elements.deduplicatedByAXIdentity()
  }
  ```

- [ ] **Step 5: `SendCommand` — replace the body of `deduplicateCandidates(_:)` (SendCommand.swift:862-872) with a delegation to the helper.**
  Anchor: the `private func deduplicateCandidates(_ candidates: [UIElement]) -> [UIElement]` whose loop uses `areSameAXElement($0, candidate)`. Leave `areSameAXElement` (874-876) untouched (still used by `closeWindowsIfNeeded` line 741). Call sites (lines 804, 818) unchanged.

  ```swift
  private func deduplicateCandidates(_ candidates: [UIElement]) -> [UIElement] {
      candidates.deduplicatedByAXIdentity()
  }
  ```

- [ ] **Step 6: DIFF-DISCIPLINE — run `git diff` and confirm only relocation/delegation.**
  ```bash
  git -C /Volumes/990EVO+/workspace/chann/kmsg diff
  ```
  Expected: new file `Support/UIElement+Dedup.swift`; each of the 4 modified functions now has a one-line body delegating to `.deduplicatedByAXIdentity()`. No call-site signature changes, no token reordering, no value changes, no other functions touched.

- [ ] **Step 7: BUILD GATE.**
  ```bash
  swift build 2>&1 | tee /tmp/kmsg-phase5-build.log; tail -1 /tmp/kmsg-phase5-build.log
  ```
  Expected: ends `Build complete!` (exit 0). Diff warnings vs baseline:
  ```bash
  diff /tmp/kmsg-golden-baseline/warnings.txt <(grep warning: /tmp/kmsg-phase5-build.log || true)
  ```
  Expected: no NEW warnings vs baseline.

- [ ] **Step 8: GOLDEN — re-run every command touching these dedup paths and diff byte-for-byte.**
  ```bash
  .build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.read.out 2> /tmp/check.read.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.read.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.read.err
  .build/debug/kmsg chats --verbose --limit 20 > /tmp/check.chats.out 2> /tmp/check.chats.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.chats.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.chats.err
  .build/debug/kmsg chats --json --limit 20 > /tmp/check.chatsj.out 2> /tmp/check.chatsj.err && diff /tmp/kmsg-golden-baseline/chats_json.out /tmp/check.chatsj.out && diff /tmp/kmsg-golden-baseline/chats_json.err /tmp/check.chatsj.err
  .build/debug/kmsg send "테헤란로 죽돌이" "ping" --dry-run > /tmp/check.send.out 2> /tmp/check.send.err && diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check.send.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check.send.err
  ```
  Expected: every diff empty (byte-identical). (`send_dryrun` exercises arg parsing only, but `read`/`chats`/`chats_json` exercise the live dedup paths in MessageContextResolver/ChatListScanner; `send` non-dry-run search dedup is covered by manual `send` if a live golden exists — `send_dryrun` short-circuits before `ChatWindowResolver`/`SendCommand` dedup, so additionally confirm a non-dry-run send against the known chat shows the same `✓ Message sent` / window-close trace if a live send golden is captured.)

- [ ] **Step 9: COMMIT.**
  ```bash
  git -C /Volumes/990EVO+/workspace/chann/kmsg add \
    Sources/kmsg/Support/UIElement+Dedup.swift \
    Sources/kmsg/KakaoTalk/MessageContextResolver.swift \
    Sources/kmsg/KakaoTalk/ChatListScanner.swift \
    Sources/kmsg/KakaoTalk/ChatWindowResolver.swift \
    Sources/kmsg/Commands/SendCommand.swift
  git -C /Volumes/990EVO+/workspace/chann/kmsg commit -m "refactor(dedup): extract [UIElement].deduplicatedByAXIdentity for linear-scan sites"
  ```

---

### Task 5.2: Add String-keyed `dedupedPreservingOrder(by:)` and route the String dedup variants through it (empty-filter divergence preserved)

**Files**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Support/UIElement+Dedup.swift` (append a `String`-array helper — keeping all dedup helpers in one Support file)
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/InspectCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/ChatWindowResolver.swift`
- Verify: golden `read`, `read_json`, `inspect5`, `inspect5_debug`, `chats`

> NOTE — DIVERGENCE MAP (must be preserved EXACTLY):
> - `TranscriptReader.deduplicatePreservingOrder` (894-907): Set<String> + reserveCapacity + **`guard !value.isEmpty`** → uses `dropEmpty: true`.
> - `InspectCommand.deduplicate` (395-407): Set<String> + reserveCapacity + **`guard !value.isEmpty`** → uses `dropEmpty: true`.
> - `ChatWindowResolver.deduplicateStringsPreservingOrder` (883-897): Set<String> + reserveCapacity, **NO empty filter** → uses `dropEmpty: false`.
> - EXCLUDED: `TranscriptReader.deduplicateMessagesPreservingOrder` (924-937) is `TranscriptMessage`-keyed via `messageFingerprint`, NOT `String`-keyed, and has NO empty filter — it stays a separate function (Task 5.3 only relocates element dedup, never this). Do not touch it here.

- [ ] **Step 1: Append the String-keyed order-preserving dedup helper with a `dropEmpty` flag (default preserves the no-filter behavior).**
  Append to `Support/UIElement+Dedup.swift`. The flag encodes the single divergence between the two empty-filtering variants and the non-filtering variant; bodies are otherwise byte-identical (Set + reserveCapacity + first-seen append).

  ```swift
  extension Array where Element == String {
      /// First-seen order-preserving String dedup. `dropEmpty: true` skips empty
      /// strings before deduping (TranscriptReader/InspectCommand behavior);
      /// `dropEmpty: false` keeps them (ChatWindowResolver behavior).
      func dedupedPreservingOrder(dropEmpty: Bool = false) -> [String] {
          var seen = Set<String>()
          var unique: [String] = []
          unique.reserveCapacity(count)
          for value in self {
              if dropEmpty, value.isEmpty { continue }
              if seen.contains(value) { continue }
              seen.insert(value)
              unique.append(value)
          }
          return unique
      }
  }
  ```

  > NOTE: the prompt's canonical signature is `dedupedPreservingOrder(by:)`. There is no per-element *key projection* needed here (all three call sites dedup the `String` value by itself, not by a derived key), so a `by:` key closure would be dead parameterization (violates "No abstractions for single-use code"). The behavioral axis that actually differs across the three sites is the empty-filter, so the parameter is `dropEmpty:`. If the orchestrator strictly requires the literal name `by:`, rename the label to `by:` taking the `dropEmpty` Bool — but `dropEmpty:` is the honest descriptor. Flagging this naming deviation explicitly.

- [ ] **Step 2: `TranscriptReader` — replace the body of `deduplicatePreservingOrder(_:)` (TranscriptReader.swift:894-907) with the `dropEmpty: true` helper.**
  Anchor: `private func deduplicatePreservingOrder(_ values: [String]) -> [String]` containing `guard !value.isEmpty else { continue }`. Call sites (lines 417, 418, 517) unchanged. Leave `deduplicateBodyCandidates` (909-922) and `deduplicateMessagesPreservingOrder` (924-937) untouched.

  ```swift
  private func deduplicatePreservingOrder(_ values: [String]) -> [String] {
      values.dedupedPreservingOrder(dropEmpty: true)
  }
  ```

- [ ] **Step 3: `InspectCommand` — replace the body of `deduplicate(_:)` (InspectCommand.swift:395-407) with the `dropEmpty: true` helper.**
  Anchor: `private func deduplicate(_ values: [String]) -> [String]` containing `guard !value.isEmpty else { continue }`. Call sites (lines 323, 324, 346, 347) unchanged.

  ```swift
  private func deduplicate(_ values: [String]) -> [String] {
      values.dedupedPreservingOrder(dropEmpty: true)
  }
  ```

- [ ] **Step 4: `ChatWindowResolver` — replace the body of `deduplicateStringsPreservingOrder(_:)` (ChatWindowResolver.swift:883-897) with the `dropEmpty: false` helper.**
  Anchor: `private func deduplicateStringsPreservingOrder(_ values: [String]) -> [String]` with NO empty guard. Call site (line 755, inside `collectCandidateTexts`) unchanged. This is the ONLY String-dedup site that must keep empties.

  ```swift
  private func deduplicateStringsPreservingOrder(_ values: [String]) -> [String] {
      values.dedupedPreservingOrder(dropEmpty: false)
  }
  ```

- [ ] **Step 5: DIFF-DISCIPLINE — run `git diff` and confirm only delegation + correct flag value per site.**
  ```bash
  git -C /Volumes/990EVO+/workspace/chann/kmsg diff
  ```
  Expected: `Support/UIElement+Dedup.swift` gains the `[String]` extension; the two empty-filtering functions delegate with `dropEmpty: true`; `deduplicateStringsPreservingOrder` delegates with `dropEmpty: false`. `deduplicateMessagesPreservingOrder` and `deduplicateBodyCandidates` are NOT in the diff.

- [ ] **Step 6: BUILD GATE.**
  ```bash
  swift build 2>&1 | tee /tmp/kmsg-phase5-build.log; tail -1 /tmp/kmsg-phase5-build.log
  diff /tmp/kmsg-golden-baseline/warnings.txt <(grep warning: /tmp/kmsg-phase5-build.log || true)
  ```
  Expected: `Build complete!` (exit 0); no NEW warnings vs baseline.

- [ ] **Step 7: GOLDEN — diff the read/inspect/chats outputs (CRLF + empty-token edge cases live in these paths).**
  ```bash
  .build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.read.out 2> /tmp/check.read.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.read.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.read.err
  .build/debug/kmsg read "테헤란로 죽돌이" --json --limit 50 > /tmp/check.readj.out 2> /tmp/check.readj.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.readj.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.readj.err
  .build/debug/kmsg inspect --depth 5 > /tmp/check.i5.out 2> /tmp/check.i5.err && diff /tmp/kmsg-golden-baseline/inspect5.out /tmp/check.i5.out && diff /tmp/kmsg-golden-baseline/inspect5.err /tmp/check.i5.err
  .build/debug/kmsg inspect --depth 5 --debug-layout --row-summary > /tmp/check.i5d.out 2> /tmp/check.i5d.err && diff /tmp/kmsg-golden-baseline/inspect5_debug.out /tmp/check.i5d.out && diff /tmp/kmsg-golden-baseline/inspect5_debug.err /tmp/check.i5d.err
  .build/debug/kmsg chats --verbose --limit 20 > /tmp/check.chats.out 2> /tmp/check.chats.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.chats.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.chats.err
  ```
  Expected: every diff empty. `read`/`read_json` exercise `deduplicatePreservingOrder` (author/time token dedup → output authors/times). `inspect5_debug` `--row-summary` exercises `InspectCommand.deduplicate` (timeCandidates/authorCandidates/buttonTitles). `chats` exercises `ChatWindowResolver.deduplicateStringsPreservingOrder` only on a live search path; if `chats` doesn't hit it, confirm via a live `send` (search) against the known chat that the `search: best result … matched=` trace is unchanged.

  > Reconcile the `inspect5_debug` invocation flags with the actual Phase-0 capture command; the exact flag string MUST match whatever produced `/tmp/kmsg-golden-baseline/inspect5_debug.out` (re-run the recorded Phase-0 command verbatim rather than guessing flags).

- [ ] **Step 8: COMMIT.**
  ```bash
  git -C /Volumes/990EVO+/workspace/chann/kmsg add \
    Sources/kmsg/Support/UIElement+Dedup.swift \
    Sources/kmsg/KakaoTalk/TranscriptReader.swift \
    Sources/kmsg/Commands/InspectCommand.swift \
    Sources/kmsg/KakaoTalk/ChatWindowResolver.swift
  git -C /Volumes/990EVO+/workspace/chann/kmsg commit -m "refactor(dedup): share String dedupedPreservingOrder with explicit empty-filter flag"
  ```

---

### Task 5.3: Extract shared `MessageMetadataTokenizer` (CRLF-normalization divergence preserved via `replacingNewlines:` flag)

**Files**
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Support/MessageMetadataTokenizer.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/InspectCommand.swift`
- Verify: golden `read`, `read_json`, `inspect5`, `inspect5_debug`

> NOTE — BYTE-IDENTITY MAP across the two files:
> - `metadataTokens(from:)`: TranscriptReader (542-549) **normalizes CRLF→LF first** then splits; InspectCommand (388-393) **splits directly** (its caller `normalizeText` already CRLF-normalized). DIVERGENCE → `replacingNewlines:` flag. TranscriptReader passes `replacingNewlines: true`; InspectCommand passes `replacingNewlines: false`.
> - `extractTimeToken(from:)`: TranscriptReader (551-574) vs InspectCommand (409-432) — byte-identical (same meridiem regex `#"(오전|오후)\s*([1-9]|1[0-2]):[0-5][0-9]"#`, same 24h regex `#"^([01]?[0-9]|2[0-3]):[0-5][0-9]$"#`, same punctuation trim).
> - `isLikelyCountToken(_:)`: TranscriptReader (576-580) vs InspectCommand (434-438) — byte-identical.
> - `isLikelySystemMetadataToken(_:)`: TranscriptReader (582-597) vs InspectCommand (440-454) — byte-identical (3 regexes; note InspectCommand has no trailing blank line before `return false`, behavior identical).

- [ ] **Step 1: Create the shared tokenizer enum with the four functions, `metadataTokens` taking the CRLF flag.**
  The regex literals are folded into named constants here (this also satisfies Task 5.4 for the time/date literals shared by these functions). `metadataTokens` performs the CRLF normalization ONLY when `replacingNewlines` is true, exactly reproducing each caller's current preprocessing.

  ```swift
  import Foundation

  /// Shared metadata-token parsing for chat-row static text.
  /// Byte-identical logic previously duplicated in TranscriptReader and InspectCommand.
  enum MessageMetadataTokenizer {
      // Time/date regex literals (character-identical to the originals).
      static let meridiemTimePattern = #"(오전|오후)\s*([1-9]|1[0-2]):[0-5][0-9]"#
      static let clockTimePattern = #"^([01]?[0-9]|2[0-3]):[0-5][0-9]$"#
      static let isoDatePrefixPattern = #"^\d{4}-\d{2}-\d{2}"#
      static let numericDatePrefixPattern = #"^\d{4}[./-]\d{1,2}[./-]\d{1,2}"#
      static let koreanDatePrefixPattern = #"^\d{1,2}월\s*\d{1,2}일"#

      /// Split static-text into trimmed non-empty line tokens.
      /// `replacingNewlines: true` normalizes CRLF/CR→LF before splitting
      /// (TranscriptReader, which passes raw `stringValue`); `false` splits
      /// directly (InspectCommand, whose caller already normalized).
      static func metadataTokens(from text: String, replacingNewlines: Bool) -> [String] {
          let source: String
          if replacingNewlines {
              source = text
                  .replacingOccurrences(of: "\r\n", with: "\n")
                  .replacingOccurrences(of: "\r", with: "\n")
          } else {
              source = text
          }
          return source
              .split(separator: "\n", omittingEmptySubsequences: true)
              .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
              .filter { !$0.isEmpty }
      }

      static func extractTimeToken(from token: String) -> String? {
          let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return nil }

          if let meridiemRange = trimmed.range(
              of: meridiemTimePattern,
              options: .regularExpression
          ) {
              return String(trimmed[meridiemRange])
          }

          let parts = trimmed.split(whereSeparator: \.isWhitespace)
          for part in parts {
              let normalized = String(part).trimmingCharacters(in: .punctuationCharacters)
              if normalized.range(
                  of: clockTimePattern,
                  options: .regularExpression
              ) != nil {
                  return normalized
              }
          }

          return nil
      }

      static func isLikelyCountToken(_ token: String) -> Bool {
          let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return false }
          return trimmed.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
      }

      static func isLikelySystemMetadataToken(_ token: String) -> Bool {
          let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return false }

          if trimmed.range(of: isoDatePrefixPattern, options: .regularExpression) != nil {
              return true
          }
          if trimmed.range(of: numericDatePrefixPattern, options: .regularExpression) != nil {
              return true
          }
          if trimmed.range(of: koreanDatePrefixPattern, options: .regularExpression) != nil {
              return true
          }
          return false
      }
  }
  ```

- [ ] **Step 2: `TranscriptReader` — delete the four private methods and route through the shared tokenizer (preserving CRLF normalization with `replacingNewlines: true`).**
  Delete `metadataTokens(from:)` (542-549), `extractTimeToken(from:)` (551-574), `isLikelyCountToken(_:)` (576-580), `isLikelySystemMetadataToken(_:)` (582-597). Their call sites are inside `analyzeRow` (line 374), `extractRowMetadata` (line 509), and `parseRowMetadata` (lines 522, 527, 528). Update each call site to the `MessageMetadataTokenizer.` form. Leave `isLikelyAttachmentMetadataToken` (599-621), `isLikelyAttachmentButtonTitle` (623-633), and `parseSystemDate` (797-851) untouched — those are NOT shared with InspectCommand.

  Call-site edit in `analyzeRow` (TranscriptReader.swift:374), anchored on the `for staticText in staticTexts {` loop that calls `normalizeBodyText(staticText.stringValue)`:
  ```swift
              for staticText in staticTexts {
                  let normalized = normalizeBodyText(staticText.stringValue)
                  guard !normalized.isEmpty else { continue }
                  metadataTokensBuffer.append(contentsOf: MessageMetadataTokenizer.metadataTokens(from: normalized, replacingNewlines: true))
              }
  ```

  > NOTE: `normalizeBodyText` (878-892) ALREADY CRLF-normalizes its input before this call, so feeding its output back through `replacingNewlines: true` is idempotent (no `\r` remains) — byte-identical to today, where `metadataTokens` also re-normalized. Keep `replacingNewlines: true` to mirror the original `TranscriptReader.metadataTokens` exactly rather than relying on the upstream normalization.

  Call-site edit in `extractRowMetadata` (TranscriptReader.swift:509), anchored on `let staticTexts = container.findAll(role: kAXStaticTextRole, limit: 12, maxNodes: 240)`:
  ```swift
              for staticText in staticTexts {
                  let normalized = normalizeBodyText(staticText.stringValue)
                  guard !normalized.isEmpty else { continue }
                  tokens.append(contentsOf: MessageMetadataTokenizer.metadataTokens(from: normalized, replacingNewlines: true))
              }
  ```

  Call-site edits in `parseRowMetadata` (TranscriptReader.swift:521-532), anchored on `for token in uniqueTokens {`:
  ```swift
          for token in uniqueTokens {
              if let parsedTime = MessageMetadataTokenizer.extractTimeToken(from: token) {
                  timeRaw = parsedTime
                  continue
              }

              if MessageMetadataTokenizer.isLikelyCountToken(token)
                  || MessageMetadataTokenizer.isLikelySystemMetadataToken(token)
                  || isLikelyAttachmentMetadataToken(token)
              {
                  continue
              }

              if author == nil {
                  author = token
              }
          }
  ```

- [ ] **Step 3: `InspectCommand` — delete the four private methods and route through the shared tokenizer (NO CRLF normalization with `replacingNewlines: false`).**
  Delete `metadataTokens(from:)` (388-393), `extractTimeToken(from:)` (409-432), `isLikelyCountToken(_:)` (434-438), `isLikelySystemMetadataToken(_:)` (440-454). Leave `normalizeText` (380-386) and `deduplicate` (395-407) untouched. Call sites are in `summarizeRow` (lines 305, 329, 333).

  Call-site edit in `summarizeRow` (InspectCommand.swift:302-306), anchored on the `for staticText in staticTexts {` loop that calls `normalizeText(staticText.stringValue)`:
  ```swift
              for staticText in staticTexts {
                  let normalized = normalizeText(staticText.stringValue)
                  guard !normalized.isEmpty else { continue }
                  tokens.append(contentsOf: MessageMetadataTokenizer.metadataTokens(from: normalized, replacingNewlines: false))
              }
  ```

  Call-site edits in `summarizeRow` (InspectCommand.swift:328-337), anchored on `for token in uniqueTokens {`:
  ```swift
          for token in uniqueTokens {
              if let time = MessageMetadataTokenizer.extractTimeToken(from: token) {
                  timeCandidates.append(time)
                  continue
              }
              if MessageMetadataTokenizer.isLikelyCountToken(token) || MessageMetadataTokenizer.isLikelySystemMetadataToken(token) {
                  continue
              }
              authorCandidates.append(token)
          }
  ```

  > CRLF TRAP PRESERVED: InspectCommand keeps `replacingNewlines: false`. Its `normalizeText` (380-386) uses `.trimmingCharacters(in: .whitespacesAndNewlines)` (NOT a per-line split) after CRLF→LF, so any embedded `\n` survives into `metadataTokens` and is split there — exactly as today. Passing `replacingNewlines: false` reproduces the original `InspectCommand.metadataTokens` which never re-normalized. This is the divergence the golden `inspect5_debug` must confirm.

- [ ] **Step 4: DIFF-DISCIPLINE — run `git diff` and confirm pure relocation + literal→named-constant swap.**
  ```bash
  git -C /Volumes/990EVO+/workspace/chann/kmsg diff
  ```
  Expected: new file `Support/MessageMetadataTokenizer.swift`; TranscriptReader and InspectCommand each lose 4 private functions and gain `MessageMetadataTokenizer.` prefixes at the call sites with the correct `replacingNewlines:` value; no regex-literal text changed (only relocated into `static let` constants of identical character content); no other logic touched.

- [ ] **Step 5: BUILD GATE.**
  ```bash
  swift build 2>&1 | tee /tmp/kmsg-phase5-build.log; tail -1 /tmp/kmsg-phase5-build.log
  diff /tmp/kmsg-golden-baseline/warnings.txt <(grep warning: /tmp/kmsg-phase5-build.log || true)
  ```
  Expected: `Build complete!` (exit 0); no NEW warnings vs baseline.

- [ ] **Step 6: GOLDEN — diff read/inspect outputs; this is the primary CRLF-trap verification.**
  ```bash
  .build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.read.out 2> /tmp/check.read.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.read.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.read.err
  .build/debug/kmsg read "테헤란로 죽돌이" --json --limit 50 > /tmp/check.readj.out 2> /tmp/check.readj.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.readj.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.readj.err
  .build/debug/kmsg inspect --depth 5 > /tmp/check.i5.out 2> /tmp/check.i5.err && diff /tmp/kmsg-golden-baseline/inspect5.out /tmp/check.i5.out && diff /tmp/kmsg-golden-baseline/inspect5.err /tmp/check.i5.err
  .build/debug/kmsg inspect --depth 5 --debug-layout --row-summary > /tmp/check.i5d.out 2> /tmp/check.i5d.err && diff /tmp/kmsg-golden-baseline/inspect5_debug.out /tmp/check.i5d.out && diff /tmp/kmsg-golden-baseline/inspect5_debug.err /tmp/check.i5d.err
  ```
  Expected: every diff empty. `read`/`read_json` validate TranscriptReader's `replacingNewlines: true` path (author/time parsing). `inspect5_debug --row-summary` validates InspectCommand's `replacingNewlines: false` path (time/authorCandidates token output). If either diffs, the CRLF flag is wrong for that caller — revert and re-check the flag mapping before proceeding.

  > Re-run the `inspect5_debug` capture with the verbatim Phase-0 flag string; do not assume `--debug-layout --row-summary` if Phase 0 recorded different flags.

- [ ] **Step 7: COMMIT.**
  ```bash
  git -C /Volumes/990EVO+/workspace/chann/kmsg add \
    Sources/kmsg/Support/MessageMetadataTokenizer.swift \
    Sources/kmsg/KakaoTalk/TranscriptReader.swift \
    Sources/kmsg/Commands/InspectCommand.swift
  git -C /Volumes/990EVO+/workspace/chann/kmsg commit -m "refactor(tokenizer): share MessageMetadataTokenizer with CRLF-normalization flag"
  ```

---

### Task 5.4: Fold remaining time/date regex literals in TranscriptReader into named constants (character-identical)

**Files**
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/KakaoTalk/TranscriptReader.swift`
- Verify: golden `read`, `read_json`

> NOTE — Task 5.3 already named the 5 literals shared with InspectCommand (now on `MessageMetadataTokenizer`). This task covers the time/date regex literals that remain INSIDE TranscriptReader and are NOT shared (so they belong on the reader, not the tokenizer). Each constant value is the verbatim character content of the original inline literal. The `parseSystemDate` date-shape literals and the `minuteOfDay` time literals are TranscriptReader-only.

- [ ] **Step 1: Add a private constants holder for TranscriptReader's non-shared time/date patterns.**
  Add near the bottom of `TranscriptReader.swift`, alongside the existing private structs (after `messageFingerprint`, before `private struct RowMetadata` at line 1003). Values are character-identical to the inline literals at lines 728, 751, 807, 823.

  ```swift
  private enum TranscriptTimePatterns {
      // minuteOfDay parsing (capturing groups differ from the tokenizer's clock pattern).
      static let meridiemTime = #"(오전|오후)\s*([1-9]|1[0-2]):([0-5][0-9])"#
      static let clockTime = #"([01]?[0-9]|2[0-3]):([0-5][0-9])"#
      // parseSystemDate shapes.
      static let isoDate = #"^(\d{4})-(\d{1,2})-(\d{1,2})(?:\s+\S+)?$"#
      static let koreanDate = #"^(\d{1,2})월\s*(\d{1,2})일(?:\s+\S+)?$"#
  }
  ```

  > NOTE: these are deliberately NOT shared with the tokenizer — `minuteOfDay`'s patterns carry **capturing groups** (`([0-5][0-9])`) that `MessageMetadataTokenizer.clockTimePattern` lacks (`[0-5][0-9]`), and the anchors differ (`^…$` vs none). Merging them would change match semantics. Keeping them TranscriptReader-local preserves byte-identity.

- [ ] **Step 2: Replace the inline literal in `minuteOfDay` meridiem branch (TranscriptReader.swift:727-730).**
  Anchor: inside `private func minuteOfDay(from timeRaw: String?) -> Int?`, the `if let meridiemRange = trimmed.range(` whose body strips `오전`/`오후`.
  ```swift
          if let meridiemRange = trimmed.range(
              of: TranscriptTimePatterns.meridiemTime,
              options: .regularExpression
          ) {
  ```

- [ ] **Step 3: Replace the inline literal in `minuteOfDay` 24h branch (TranscriptReader.swift:750-753).**
  Anchor: in the same function, the `if let range = trimmed.range(` immediately preceding `let token = String(trimmed[range])`.
  ```swift
          if let range = trimmed.range(
              of: TranscriptTimePatterns.clockTime,
              options: .regularExpression
          ) {
  ```

- [ ] **Step 4: Replace the inline literal in `parseSystemDate` ISO branch (TranscriptReader.swift:806-809).**
  Anchor: inside `private func parseSystemDate(from text: String, relativeTo referenceDate: Date) -> Date?`, the `if let match = normalized.range(` (operates on `normalized`, the `.`/`/`→`-` substituted string).
  ```swift
          if let match = normalized.range(
              of: TranscriptTimePatterns.isoDate,
              options: .regularExpression
          ) {
  ```

- [ ] **Step 5: Replace the inline literal in `parseSystemDate` Korean-date branch (TranscriptReader.swift:822-825).**
  Anchor: in the same function, the `if let match = trimmed.range(` (operates on `trimmed`, NOT `normalized` — preserve that distinction).
  ```swift
          if let match = trimmed.range(
              of: TranscriptTimePatterns.koreanDate,
              options: .regularExpression
          ) {
  ```

- [ ] **Step 6: DIFF-DISCIPLINE — run `git diff` and confirm literal→named-constant swap only.**
  ```bash
  git -C /Volumes/990EVO+/workspace/chann/kmsg diff Sources/kmsg/KakaoTalk/TranscriptReader.swift
  ```
  Expected: one new `private enum TranscriptTimePatterns`; four `of: #"…"#` arguments replaced with `of: TranscriptTimePatterns.<name>`; the constant string content matches the removed literals character-for-character (verify `meridiemTime`/`clockTime` still carry their capturing groups, `isoDate`/`koreanDate` still carry `^…$` anchors and `(?:\s+\S+)?`). No surrounding parsing logic changed; `normalized` vs `trimmed` receiver of each `.range(` unchanged.

- [ ] **Step 7: BUILD GATE.**
  ```bash
  swift build 2>&1 | tee /tmp/kmsg-phase5-build.log; tail -1 /tmp/kmsg-phase5-build.log
  diff /tmp/kmsg-golden-baseline/warnings.txt <(grep warning: /tmp/kmsg-phase5-build.log || true)
  ```
  Expected: `Build complete!` (exit 0); no NEW warnings vs baseline.

- [ ] **Step 8: GOLDEN — diff read outputs (time parsing + system-date anchoring feed `time_raw` and message ordering).**
  ```bash
  .build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.read.out 2> /tmp/check.read.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.read.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.read.err
  .build/debug/kmsg read "테헤란로 죽돌이" --json --limit 50 > /tmp/check.readj.out 2> /tmp/check.readj.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.readj.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.readj.err
  ```
  Expected: both diffs empty. `minuteOfDay` and `parseSystemDate` drive `time_raw`, `logicalTimestamp`, and the left-chain author time guard — any regex drift would surface as reordered/relabeled messages in `read`/`read_json`.

- [ ] **Step 9: COMMIT.**
  ```bash
  git -C /Volumes/990EVO+/workspace/chann/kmsg add Sources/kmsg/KakaoTalk/TranscriptReader.swift
  git -C /Volumes/990EVO+/workspace/chann/kmsg commit -m "refactor(read): fold TranscriptReader time/date regex literals into named constants"
  ```

---

## Phase 6 — Command bootstrap & JSON-output helpers

Goal: Extract three shared helpers (`ensureAccessibilityOrExit()`, `setupCommand(traceAX:deepRecovery:)`, `JSONOutputFormatter.encode<T>(_:escapingSlashes:)`) and route the duplicated permission-guard / runner-kakao-resolver setup / JSON-encoder boilerplate through them, with byte-identical behavior.

Aggregate risk: low

### Task 6.1: Add `ensureAccessibilityOrExit()` and migrate the 8 throwing-guard command files

Files:
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Accessibility/AccessibilityPermission+Ensure.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/ReadCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/ChatsCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendImageCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/WatchCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CacheCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/InspectCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/AuthCommand.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/StatusCommand.swift` (must remain UNTOUCHED — uses `ensureGranted()` as a plain Bool, not a throwing guard)

- [ ] **Step 1: Create the helper file.** It wraps the exact current guard body (including the `ExitCode.failure` throw and `printInstructions()` call) verbatim. `import ArgumentParser` is required for `ExitCode`.

```swift
import ArgumentParser

extension AccessibilityPermission {
    /// Verify accessibility permission, printing instructions and throwing `ExitCode.failure` when not granted.
    static func ensureAccessibilityOrExit() throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }
    }
}
```

- [ ] **Step 2: ReadCommand — migrate guard.** In `ReadCommand.run()` (file `ReadCommand.swift`), the block currently at lines 53-56 opens `func run() throws {` immediately followed by the guard. Replace:

```swift
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
```

with:

```swift
        try AccessibilityPermission.ensureAccessibilityOrExit()

        let runner = AXActionRunner(traceEnabled: traceAX)
```

- [ ] **Step 3: ChatsCommand — migrate guard.** In `ChatsCommand.run()` (file `ChatsCommand.swift`), block at lines 31-34 (the guard is immediately followed by `let runner = AXActionRunner(traceEnabled: traceAX)` at line 36). Replace:

```swift
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
```

with:

```swift
        try AccessibilityPermission.ensureAccessibilityOrExit()

        let runner = AXActionRunner(traceEnabled: traceAX)
```

- [ ] **Step 4: SendImageCommand — migrate guard.** In `SendImageCommand.run()` (file `SendImageCommand.swift`), block at lines 30-33, immediately followed by `let runner = AXActionRunner(traceEnabled: traceAX)` (line 35). Replace:

```swift
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        let imageURL = URL(fileURLWithPath: imagePath)
```

with:

```swift
        try AccessibilityPermission.ensureAccessibilityOrExit()

        let runner = AXActionRunner(traceEnabled: traceAX)
        let imageURL = URL(fileURLWithPath: imagePath)
```

- [ ] **Step 5: SendCommand — migrate guard ONLY (preserve dryRun fast-path above it).** In `SendCommand.run()` (file `SendCommand.swift`), the dryRun block occupies lines 98-110 and `return`s before the guard. The guard is at lines 112-115, immediately followed by `let runner = AXActionRunner(traceEnabled: traceAX)` (line 117). Do NOT touch the dryRun block. Replace:

```swift
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)

        prepareCacheIfNeeded(runner: runner)
```

with:

```swift
        try AccessibilityPermission.ensureAccessibilityOrExit()

        let runner = AXActionRunner(traceEnabled: traceAX)

        prepareCacheIfNeeded(runner: runner)
```

- [ ] **Step 6: WatchCommand — migrate guard.** In `WatchCommand.run()` (file `WatchCommand.swift`), block at lines 69-72, immediately followed by `let watchStartedAt = Date()` (line 74). Replace:

```swift
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let watchStartedAt = Date()
```

with:

```swift
        try AccessibilityPermission.ensureAccessibilityOrExit()

        let watchStartedAt = Date()
```

- [ ] **Step 7: CacheCommand — migrate guard (only in `CacheWarmupCommand.run()`).** In `CacheWarmupCommand.run()` (file `CacheCommand.swift`), block at lines 106-109, immediately followed by `let runner = AXActionRunner(traceEnabled: traceAX)` (line 111). The other Cache subcommands (`CacheStatusCommand`, `CacheClearCommand`, `CacheExportCommand`, `CacheImportCommand`) have NO permission guard — leave them untouched. Replace:

```swift
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let windowResolver = ChatWindowResolver(kakao: kakao, runner: runner)
```

with:

```swift
        try AccessibilityPermission.ensureAccessibilityOrExit()

        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let windowResolver = ChatWindowResolver(kakao: kakao, runner: runner)
```

- [ ] **Step 8: InspectCommand — migrate guard.** In `InspectCommand.run()` (file `InspectCommand.swift`), block at lines 44-47, immediately followed by `let kakao = try KakaoTalkApp()` (line 49). Replace:

```swift
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let kakao = try KakaoTalkApp()
```

with:

```swift
        try AccessibilityPermission.ensureAccessibilityOrExit()

        let kakao = try KakaoTalkApp()
```

- [ ] **Step 9: AuthCommand — migrate guard (in `AuthLoginCommand.run()`).** In `AuthLoginCommand.run()` (file `AuthCommand.swift`), block at lines 28-31, immediately followed by `let kakao = try KakaoTalkApp()` (line 33). The parent `AuthCommand` has no `run()`/guard — leave it untouched. Replace:

```swift
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let kakao = try KakaoTalkApp()
        let runner = AXActionRunner(traceEnabled: traceAX)
```

with:

```swift
        try AccessibilityPermission.ensureAccessibilityOrExit()

        let kakao = try KakaoTalkApp()
        let runner = AXActionRunner(traceEnabled: traceAX)
```

- [ ] **Step 10: Confirm StatusCommand is untouched.** Run: `git diff --name-only -- Sources/kmsg/Commands/StatusCommand.swift` | Expected: empty output (no change). `StatusCommand.run()` line 17 uses `let hasPermission = AccessibilityPermission.ensureGranted()` as a Bool then branches/`return`s — it is NOT a throwing guard and MUST NOT be migrated.

- [ ] **Step 11: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Commands/ReadCommand.swift Sources/kmsg/Commands/ChatsCommand.swift Sources/kmsg/Commands/SendImageCommand.swift Sources/kmsg/Commands/SendCommand.swift Sources/kmsg/Commands/WatchCommand.swift Sources/kmsg/Commands/CacheCommand.swift Sources/kmsg/Commands/InspectCommand.swift Sources/kmsg/Commands/AuthCommand.swift` | Expected: each hunk is ONLY the 4-line guard collapsed to a single `try AccessibilityPermission.ensureAccessibilityOrExit()` line — no other tokens moved, no value changes, the dryRun block in SendCommand and the cache subcommands without guards all unchanged.

- [ ] **Step 12: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs baseline at `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 13: GOLDEN — permission/no-op behavior preserved.** Re-run the goldens for touched commands and confirm byte-identical (permission is already granted in the live session, so the success path is exercised):
  ```
  .build/debug/kmsg chats > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.err
  .build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err
  .build/debug/kmsg inspect --depth 5 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/inspect5.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/inspect5.err /tmp/check.err
  ```
  Expected: empty diff (byte-identical) for each.

- [ ] **Step 14: COMMIT.** Run:
  ```
  git add Sources/kmsg/Accessibility/AccessibilityPermission+Ensure.swift Sources/kmsg/Commands/ReadCommand.swift Sources/kmsg/Commands/ChatsCommand.swift Sources/kmsg/Commands/SendImageCommand.swift Sources/kmsg/Commands/SendCommand.swift Sources/kmsg/Commands/WatchCommand.swift Sources/kmsg/Commands/CacheCommand.swift Sources/kmsg/Commands/InspectCommand.swift Sources/kmsg/Commands/AuthCommand.swift
  git commit -m "refactor(commands): extract ensureAccessibilityOrExit permission guard"
  ```

### Task 6.2: Add `setupCommand(traceAX:deepRecovery:)` factory and route the runner/kakao/resolver triple through it

Files:
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CommandSetup.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/ReadCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/WatchCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/SendImageCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/ChatsCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/CacheCommand.swift`

Note on the contract: the six current call sites build `runner = AXActionRunner(traceEnabled: traceAX)`, `kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)`, then a `ChatWindowResolver` with varying initializer arguments. The factory must return all three in the same order they are constructed today and pass the resolver's `useCache`/`deepRecoveryEnabled` exactly as each site does. Read/Chats do NOT pass `useCache`; Send/SendImage pass `useCache: !noCache`. Chats/Cache do NOT pass `deepRecoveryEnabled`. To preserve each site verbatim, the factory takes `useCache: Bool = true` and `deepRecoveryEnabled: Bool = false` (matching `ChatWindowResolver`'s own defaults) so omitted arguments resolve identically.

- [ ] **Step 1: Create the factory file.** Mirror the construction order and the resolver's default arguments so each migrated site is behavior-identical.

```swift
import Foundation

/// Shared command bootstrap: builds the runner, authenticated app handle, and chat window resolver
/// used by the interactive AX commands (read/chats/send/send-image/watch/cache warmup).
enum CommandSetup {
    static func setupCommand(
        traceAX: Bool,
        deepRecovery: Bool = false,
        useCache: Bool = true
    ) throws -> (runner: AXActionRunner, kakao: KakaoTalkApp, resolver: ChatWindowResolver) {
        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let resolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            useCache: useCache,
            deepRecoveryEnabled: deepRecovery
        )
        return (runner, kakao, resolver)
    }
}
```

- [ ] **Step 2: ReadCommand — route through factory.** In `ReadCommand.run()`, after the `try AccessibilityPermission.ensureAccessibilityOrExit()` line (from Task 6.1), the original lines 58-65 construct the triple (resolver passes `deepRecoveryEnabled: deepRecovery`, no `useCache`). Replace:

```swift
        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let chatWindowResolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            deepRecoveryEnabled: deepRecovery
        )
        let transcriptReader = KakaoTalkTranscriptReader(kakao: kakao, runner: runner)
```

with:

```swift
        let (runner, kakao, chatWindowResolver) = try CommandSetup.setupCommand(
            traceAX: traceAX,
            deepRecovery: deepRecovery
        )
        let transcriptReader = KakaoTalkTranscriptReader(kakao: kakao, runner: runner)
```

- [ ] **Step 3: WatchCommand — route through factory.** In `WatchCommand.run()`, original lines 78-84 construct the triple (resolver passes `deepRecoveryEnabled: deepRecovery`, no `useCache`), followed by `messageContextResolver`/`transcriptReader`. Replace:

```swift
        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let chatWindowResolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            deepRecoveryEnabled: deepRecovery
        )
        let messageContextResolver = MessageContextResolver(kakao: kakao, runner: runner)
```

with:

```swift
        let (runner, kakao, chatWindowResolver) = try CommandSetup.setupCommand(
            traceAX: traceAX,
            deepRecovery: deepRecovery
        )
        let messageContextResolver = MessageContextResolver(kakao: kakao, runner: runner)
```

- [ ] **Step 4: SendCommand — route through factory, PRESERVING the dryRun fast-path and `prepareCacheIfNeeded`.** In `SendCommand.run()`, the dryRun block (original lines 98-110) returns BEFORE setup and must NOT change. The original lines 117-126 are `let runner = ...` then `prepareCacheIfNeeded(runner: runner)` then `kakao`/resolver (resolver passes `useCache: !noCache, deepRecoveryEnabled: deepRecovery`). Because `prepareCacheIfNeeded` must run AFTER `runner` exists but BEFORE auth, the runner stays inline and only the kakao+resolver pair routes through the factory — so we cannot fold `runner` into the factory here without reordering. Instead, keep `runner` and `prepareCacheIfNeeded` inline and DO NOT migrate this site to the factory; leave SendCommand as Task 6.1 left it. Confirm by running: `git diff -- Sources/kmsg/Commands/SendCommand.swift` after Task 6.1 commit shows only the guard collapse, and this step makes NO further edit to SendCommand.

  Rationale (behavior preservation): the factory builds `runner` then immediately calls `AuthBootstrap.requireAuthenticated`, but Send must run `prepareCacheIfNeeded(runner:)` between those two. Routing Send through the factory would move the cache-prep relative to auth — a behavior change. Send is therefore intentionally EXCLUDED from the factory (consistent with the dryRun fast-path exclusion).

- [ ] **Step 5: SendImageCommand — route through factory (kakao + resolver only, runner already built earlier).** In `SendImageCommand.run()`, `runner` is built at line 35, then `imageURL` + file-existence guard (lines 36-41) run BEFORE auth, then lines 43-49 build `kakao` and the resolver (resolver passes `useCache: !noCache, deepRecoveryEnabled: deepRecovery`). The `runner` and file-existence guard must stay where they are (auth must not move before the file check), so this site keeps `runner` inline and uses the factory ONLY if it does not reorder. Since the factory rebuilds `runner` and auths immediately, migrating SendImage would move auth before the file-existence guard — a behavior change. Therefore SendImage is EXCLUDED from the factory; make NO edit here beyond Task 6.1's guard collapse. Confirm with: `git diff -- Sources/kmsg/Commands/SendImageCommand.swift` shows only the guard collapse.

- [ ] **Step 6: ChatsCommand — route through factory.** In `ChatsCommand.run()`, original lines 36-38 build `runner`, `kakao`, then `chatWindowResolver = ChatWindowResolver(kakao: kakao, runner: runner)` (no `useCache`, no `deepRecoveryEnabled`), followed at line 39 by `let windowsBefore = kakao.windows`. Replace:

```swift
        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let chatWindowResolver = ChatWindowResolver(kakao: kakao, runner: runner)
        let windowsBefore = kakao.windows
```

with:

```swift
        let (runner, kakao, chatWindowResolver) = try CommandSetup.setupCommand(traceAX: traceAX)
        let windowsBefore = kakao.windows
```

- [ ] **Step 7: CacheWarmupCommand — route through factory.** In `CacheWarmupCommand.run()` (file `CacheCommand.swift`), original lines 111-113 build `runner`, `kakao`, then `windowResolver = ChatWindowResolver(kakao: kakao, runner: runner)` (no `useCache`, no `deepRecoveryEnabled`), followed at line 115 by the `guard let usableWindow = kakao.ensureMainWindow(...)`. Replace:

```swift
        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let windowResolver = ChatWindowResolver(kakao: kakao, runner: runner)

        guard let usableWindow = kakao.ensureMainWindow(timeout: 1.2, mode: .fast, trace: { message in
```

with:

```swift
        let (runner, kakao, windowResolver) = try CommandSetup.setupCommand(traceAX: traceAX)

        guard let usableWindow = kakao.ensureMainWindow(timeout: 1.2, mode: .fast, trace: { message in
```

- [ ] **Step 8: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Commands/ReadCommand.swift Sources/kmsg/Commands/WatchCommand.swift Sources/kmsg/Commands/ChatsCommand.swift Sources/kmsg/Commands/CacheCommand.swift` | Expected: each migrated site replaces the verbatim `runner`+`kakao`+resolver construction with a single tuple-binding `try CommandSetup.setupCommand(...)` call passing exactly the arguments that match the original resolver initializer (Read/Watch pass `deepRecovery:`; Chats/Cache pass neither). Confirm SendCommand.swift and SendImageCommand.swift show NO change in this task's diff.

- [ ] **Step 9: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 10: GOLDEN — factory call sites behavior preserved.** Re-run goldens for the migrated commands plus the Send short-circuit (to prove Send was NOT routed through the factory and still dry-runs before any permission/auth):
  ```
  .build/debug/kmsg read "테헤란로 죽돌이" --limit 50 > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read.err /tmp/check.err
  .build/debug/kmsg chats > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats.err /tmp/check.err
  .build/debug/kmsg send "테헤란로 죽돌이" "hello" --dry-run > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/send_dryrun.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/send_dryrun.err /tmp/check.err
  ```
  Expected: empty diff (byte-identical) for each. The `send_dryrun` diff in particular proves the dryRun fast-path still exits before permission/auth.

- [ ] **Step 11: COMMIT.** Run:
  ```
  git add Sources/kmsg/Commands/CommandSetup.swift Sources/kmsg/Commands/ReadCommand.swift Sources/kmsg/Commands/WatchCommand.swift Sources/kmsg/Commands/ChatsCommand.swift Sources/kmsg/Commands/CacheCommand.swift
  git commit -m "refactor(commands): extract setupCommand runner/kakao/resolver factory"
  ```

### Task 6.3: Add `JSONOutputFormatter.encode<T>(_:escapingSlashes:)` and route the encoder boilerplate through it

Files:
- Create: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/JSONOutputFormatter.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/ReadCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/WatchCommand.swift`
- Modify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Commands/ChatsCommand.swift`
- Verify: `/Volumes/990EVO+/workspace/chann/kmsg/Sources/kmsg/Auth/CredentialStore.swift` (CredentialStore keeps its OWN cached encoder — it must NOT be routed through this helper)

Note on flag preservation: the encoder base is `[.prettyPrinted, .sortedKeys]` at every site. Read (`printMessagesAsJSON`, line 160) and Watch (`emitJSON`, line 373) additionally set `.withoutEscapingSlashes`; Chats (`printChatsAsJSON`, line 120) does NOT. The helper exposes `escapingSlashes: Bool` (default `true` = standard JSON behavior of escaping `/`). When `false`, `.withoutEscapingSlashes` is added — preserving Read/Watch. Output mechanism stays per-site: Read/Watch keep their `FileHandle.standardOutput.write` byte writes (and their distinct trailing-byte sequences), Chats keeps `print(String)`.

- [ ] **Step 1: Create the formatter file.** Returns encoded `Data`; callers own how they emit it. `escapingSlashes` defaults to `true` so omitting it matches `JSONEncoder`'s standard slash-escaping (Chats/CredentialStore behavior).

```swift
import Foundation

/// Shared JSON encoding for command output. Base formatting is pretty-printed + sorted keys;
/// set `escapingSlashes: false` to add `.withoutEscapingSlashes` (Read/Watch JSON output).
enum JSONOutputFormatter {
    static func encode<T: Encodable>(_ value: T, escapingSlashes: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = escapingSlashes
            ? [.prettyPrinted, .sortedKeys]
            : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
```

- [ ] **Step 2: ReadCommand — route encoder, KEEP FileHandle byte-write and trailing `0x0A`.** In `ReadCommand.printMessagesAsJSON(_:)`, original lines 159-163. Replace:

```swift
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
```

with:

```swift
        let data = try JSONOutputFormatter.encode(payload, escapingSlashes: false)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
```

- [ ] **Step 3: WatchCommand — route encoder, KEEP FileHandle byte-write and trailing `0x0A, 0x0A`.** In `WatchCommand.emitJSON(message:chat:detectedAt:)`, original lines 372-376. Replace:

```swift
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A, 0x0A]))
```

with:

```swift
        let data = try JSONOutputFormatter.encode(payload, escapingSlashes: false)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A, 0x0A]))
```

- [ ] **Step 4: ChatsCommand — route encoder (slashes ESCAPED), KEEP `print(String)` output.** In `ChatsCommand.printChatsAsJSON(_:)`, original lines 118-124. The base flags `[.prettyPrinted, .sortedKeys]` map to the default `escapingSlashes: true`, so the call OMITS the parameter. Replace:

```swift
        let response = ChatsJSONResponse(count: chats.count, chats: chats)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
```

with:

```swift
        let response = ChatsJSONResponse(count: chats.count, chats: chats)
        let data = try JSONOutputFormatter.encode(response)
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
```

- [ ] **Step 5: Confirm CredentialStore is untouched.** Run: `git diff --name-only -- Sources/kmsg/Auth/CredentialStore.swift` | Expected: empty output. `CredentialStore` builds its encoder ONCE in `init` (lines 51-54) with `[.prettyPrinted, .sortedKeys]` plus `dateEncodingStrategy = .iso8601`, stores it as `self.encoder`, and reuses it in `save(...)` (line 116). It is a cached, date-strategy-configured instance — NOT a per-call helper match — and MUST NOT be routed through `JSONOutputFormatter`.

- [ ] **Step 6: DIFF-DISCIPLINE.** Run: `git diff -- Sources/kmsg/Commands/ReadCommand.swift Sources/kmsg/Commands/WatchCommand.swift Sources/kmsg/Commands/ChatsCommand.swift` | Expected: each hunk replaces the 3-line `JSONEncoder()`+`outputFormatting`+`encode` sequence with one `try JSONOutputFormatter.encode(...)` line; Read/Watch pass `escapingSlashes: false` and keep their exact `FileHandle.standardOutput.write` lines and trailing-byte `Data([...])`; Chats omits the parameter and keeps `print(string)`. No payload/response construction or trailing bytes changed.

- [ ] **Step 7: BUILD GATE.** Run: `swift build` | Expected: ends `Build complete!` (exit 0), NO new warning vs `/tmp/kmsg-golden-baseline/warnings.txt`.

- [ ] **Step 8: GOLDEN — JSON output (slash-escaping) byte-identical.** Re-run the JSON goldens to verify Read/Watch still emit unescaped slashes and Chats still escapes them, plus `cache_export` to confirm cache export JSON is unaffected:
  ```
  .build/debug/kmsg read "테헤란로 죽돌이" --limit 50 --json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/read_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/read_json.err /tmp/check.err
  .build/debug/kmsg chats --json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/chats_json.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/chats_json.err /tmp/check.err
  .build/debug/kmsg cache export /tmp/cache_export_check.json > /tmp/check.out 2> /tmp/check.err && diff /tmp/kmsg-golden-baseline/cache_export.out /tmp/check.out && diff /tmp/kmsg-golden-baseline/cache_export.err /tmp/check.err
  ```
  Expected: empty diff (byte-identical) for each. (The `watch` golden, if captured, exercises `emitJSON`; re-run it the same way against `/tmp/kmsg-golden-baseline/watch.*` if present and confirm empty diff.)

- [ ] **Step 9: COMMIT.** Run:
  ```
  git add Sources/kmsg/Commands/JSONOutputFormatter.swift Sources/kmsg/Commands/ReadCommand.swift Sources/kmsg/Commands/WatchCommand.swift Sources/kmsg/Commands/ChatsCommand.swift
  git commit -m "refactor(commands): consolidate JSON encoder setup into JSONOutputFormatter"
  ```

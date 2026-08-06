import Foundation

/// 발송 직전에 "지금 연 이 창이 정말 그 방인가"를 확인한다.
///
/// chat id 는 `chat_` + sha256(정규화된 표시이름)[:12] 라서 방의 고유 id 가 아니다.
/// 이름이 바뀌면 따라 바뀌고, 이름이 같은 두 친구는 실행마다 흔들리는 접미사로만
/// 갈리며, 정규화 규칙이 바뀌면 기존 id 가 다른 방으로 재배치된다. 이름 검색은 기호뿐인
/// 이름에서 아예 동작하지 않는다. 카카오톡 AX 트리에 대체할 고유 식별자도 없다 —
/// 채팅 목록 행이 들고 있는 고유 정보는 표시 이름과 미리보기 텍스트뿐이다.
///
/// 즉 **주소가 맞았는지는 주소로 증명할 수 없다.** 증명할 수 있는 건 그 방의 대화 내용
/// 뿐이고, 그건 호출자(서버)가 알고 있다. 그래서 호출자가 최근 메시지 몇 개를 앵커로
/// 넘기고, 여기서 열린 창의 전사 꼬리와 맞춰본다.
///
/// 확인이 실패하면 **한 글자도 타이핑하지 않고** 중단한다. 그러면 오배송이 미발송으로
/// 바뀌는데, 미발송만 되돌릴 수 있다.
///
/// 호출자는 **이미 잡은 창 핸들**을 넘겨야 한다. 여기서 창을 다시 해석하면 확인한 방과
/// 타이핑하는 방이 달라질 수 있고, 그 틈이 바로 이 검증이 막으려는 것이다.
struct ChatIdentityVerifier {
    /// 앵커가 맞지 않았다. 이 창은 그 방이 아니다.
    static let mismatchCode = "IDENTITY_MISMATCH"
    /// 전사를 읽지 못해 확인 자체를 못 했다. 방이 틀렸다는 뜻은 아니지만, 확인 없이
    /// 보내지는 않는다. 두 코드를 나누는 이유는 대응이 다르기 때문이다 — 전자는
    /// 바인딩을 고쳐야 하고 후자는 리더가 깨진 것이다(2026-07-17 에 9시간을 날린 부류).
    static let unverifiedCode = "IDENTITY_UNVERIFIED"

    /// 꼬리를 이만큼 읽는다. 우리가 앵커를 고른 뒤 상대가 몇 마디 더 했을 수 있으므로
    /// 마지막 한 건만 보면 정상 대화가 계속 실패한다.
    static let defaultTranscriptLimit = 12

    let kakao: KakaoTalkApp
    let runner: AXActionRunner
    var interactionMode: ChatWindowInteractionMode = .allowUIAutomation

    func verify(
        window: UIElement,
        fallbackChatTitle: String,
        anchors: [String],
        minimumMatches: Int,
        transcriptLimit: Int = ChatIdentityVerifier.defaultTranscriptLimit
    ) throws {
        let usable = ChatAnchor.usable(anchors)
        // 앵커가 없으면 확인하지 않는다. 이 플래그를 안 쓰는 호출자(구버전 브릿지, 사람이
        // 직접 치는 CLI)의 동작은 그대로 둔다.
        guard !usable.isEmpty else { return }
        let required = max(1, min(minimumMatches, usable.count))

        let reader = KakaoTalkTranscriptReader(kakao: kakao, runner: runner, interactionMode: interactionMode)
        let snapshot: TranscriptSnapshot
        do {
            snapshot = try reader.readSnapshot(
                from: window,
                fallbackChatTitle: fallbackChatTitle,
                limit: transcriptLimit
            )
        } catch {
            throw KakaoTalkError.actionFailed(
                "[\(Self.unverifiedCode)] could not read the transcript to confirm this is the right chat: \(error)"
            )
        }

        let bodies = snapshot.messages.map(\.body)
        let matched = ChatAnchor.matchCount(anchors: anchors, inTranscriptBodies: bodies)

        guard matched >= required else {
            throw KakaoTalkError.actionFailed(
                "[\(Self.mismatchCode)] '\(snapshot.chat)' does not look like the expected chat — "
                    + "matched \(matched) of \(usable.count) anchors in its last \(bodies.count) messages, needed \(required). "
                    + "Refusing to type into it."
            )
        }
        runner.log("identity: confirmed '\(snapshot.chat)' (\(matched)/\(usable.count) anchors)")
    }
}

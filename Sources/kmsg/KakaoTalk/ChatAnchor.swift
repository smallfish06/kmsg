import Foundation

/// 방의 신원을 증명하는 "최근에 그 방에서 오간 말" 한 조각.
///
/// 이 타입은 의존성이 없다 — AX 도, KakaoTalk 도 모른다. 판정 규칙만 들고 있어서
/// 따로 컴파일해 실행할 수 있고, tests/test_chat_anchor_matching.py 가 그렇게 한다.
/// 규칙이 조용히 틀리면 남의 대화로 메시지가 가는 자리라, 소스를 읽는 계약 테스트만으로는
/// 부족하다.
enum ChatAnchor {
    /// 이보다 짧은 앵커는 쓰지 않는다. 맞장구("ㅇㅇ", "응 ㅋㅋ")는 어느 방에나 있어서
    /// 일치해도 아무것도 증명하지 못한다.
    static let minimumLength = 8

    /// 유니코드 정규형과 공백 정리까지만 한다.
    ///
    /// `ChatTextNormalizer.normalize` 를 쓰면 안 된다 — 그건 구두점과 기호를 통째로
    /// 버려서 서로 다른 메시지를 같게 만든다. 같은 처리가 표시이름에 적용돼 '~.~' 가
    /// 빈 문자열이 된 것이 2026-08-06 1차 사고다.
    ///
    /// AX 가 돌려주는 문자열은 자모 분리형일 수 있어 NFC 를 맞춰야 같은 한글이 같게
    /// 비교된다.
    static func normalize(_ text: String) -> String {
        let composed = text.precomposedStringWithCanonicalMapping
        return composed
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// 구별력 있는 앵커만 남기고 중복을 없앤다.
    static func usable(_ anchors: [String]) -> [String] {
        var seen = Set<String>()
        var usable: [String] = []
        for anchor in anchors {
            let normalized = normalize(anchor)
            guard normalized.count >= minimumLength, seen.insert(normalized).inserted else { continue }
            usable.append(normalized)
        }
        return usable
    }

    /// 전사 꼬리에서 몇 개의 앵커가 확인됐는지 센다.
    ///
    /// 앵커가 호출자 쪽에서 잘려 왔을 수 있으므로 앞부분 일치로 본다. 전사는 채팅 목록
    /// 미리보기와 달리 본문 전체라, 반대 방향(전사가 잘려서 못 맞는 경우)은 생기지 않는다.
    static func matchCount(anchors: [String], inTranscriptBodies bodies: [String]) -> Int {
        let normalizedBodies = bodies.map(normalize).filter { !$0.isEmpty }
        return usable(anchors).filter { anchor in
            normalizedBodies.contains { $0.hasPrefix(anchor) }
        }.count
    }
}

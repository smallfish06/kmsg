import Foundation

/// 방의 신원을 증명하는 "최근에 그 방에서 오간 말" 한 조각.
///
/// 이 타입은 의존성이 없다 — AX 도, KakaoTalk 도 모른다. 판정 규칙만 들고 있어서
/// 따로 컴파일해 실행할 수 있고, tests/test_chat_anchor_matching.py 가 그렇게 한다.
/// 규칙이 조용히 틀리면 남의 대화로 메시지가 가는 자리라, 소스를 읽는 계약 테스트만으로는
/// 부족하다.
enum ChatAnchor {
    /// 앵커로 쓰려면 "내용 글자"가 이만큼은 있어야 한다. 내용 글자는 한글 음절·문자·숫자이고,
    /// 자모(ㅋ, ㅠ, ㅇ)·기호·이모지·공백은 세지 않는다. `ㅋㅋㅋ`·`ㅇㅇ`·`?` 는 어느 방에나 있어서
    /// 일치해도 아무것도 증명하지 못하고, `응` 한 글자도 마찬가지다.
    ///
    /// 길이 하한(8자)을 쓰지 않는 이유: 길이는 구별력의 대리지표일 뿐이고, 그 하한이 짧게
    /// 말하는 사람을 교착에 빠뜨렸다 (2026-08-22 소영 — `안녕`·`민준아 뭐해?`·`민준아 ㅜ`
    /// 가 전부 8자 미만이라 앵커가 못 되고, 우리 말풍선은 발송이 막혀 방에 없어 영영 2개를
    /// 못 맞췄다). 낱개 줄의 구별력은 호출자가 **여러 개 일치**를 요구하는 것으로 대신한다
    /// — 짧은 줄 서넛이 한 방의 꼬리 12행에 같이 있는 조합은 다른 방에 없다.
    static let minimumContentCharacters = 2

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

    /// 정규화된 문자열의 내용 글자 수.
    static func contentCharacterCount(_ normalized: String) -> Int {
        var count = 0
        for scalar in normalized.unicodeScalars {
            if isHangulJamo(scalar) { continue }
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                count += 1
            }
        }
        return count
    }

    /// 이 줄이 방의 신원을 증명하는 데 쓸 만한가.
    static func isDistinctive(_ normalized: String) -> Bool {
        contentCharacterCount(normalized) >= minimumContentCharacters
    }

    /// 한글 자모 블록 — 초성·중성·종성과 호환 자모. 유니코드는 이것들을 문자(Alphabetic)로
    /// 치지만 카톡에서 `ㅋㅋㅋ`·`ㅠㅠ` 는 글자가 아니라 추임새다.
    private static func isHangulJamo(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xD7B0...0xD7FF:
            return true
        default:
            return false
        }
    }

    /// 구별력 있는 앵커만 남기고 중복을 없앤다.
    static func usable(_ anchors: [String]) -> [String] {
        var seen = Set<String>()
        var usable: [String] = []
        for anchor in anchors {
            let normalized = normalize(anchor)
            guard isDistinctive(normalized), seen.insert(normalized).inserted else { continue }
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
